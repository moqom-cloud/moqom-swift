import Foundation
import Testing

@testable import MoqomCore
@testable import MoqomKit
@testable import MoqomLoopback

private let roomPrefix = try! MoqomNamespaces.room(tenant: "acme", room: "room-42")

private func person(
    _ name: String,
    presence: Presence = .connected,
    spotlighted: Bool = false,
    backstage: Bool = false
) -> Participant {
    let who = identity(name)
    let namespace = backstage
        ? try! MoqomNamespaces.backstageParticipant(
            tenant: "acme", room: "room-42", identity: who
        )
        : try! MoqomNamespaces.participant(tenant: "acme", room: "room-42", identity: who)
    let under = backstage
        ? try! MoqomNamespaces.backstage(tenant: "acme", room: "room-42")
        : roomPrefix

    var participant = Participant(
        slot: ParticipantSlot(announced: namespace, under: under, isBackstage: backstage)!
    )
    participant.presence = presence
    participant.isSpotlighted = spotlighted
    return participant
}

private func people(_ count: Int) -> [Participant] {
    (0 ..< count).map { person("user\(String(format: "%02d", $0))") }
}

private func roster(_ participants: [Participant]) -> Roster {
    var roster = Roster()
    for participant in participants { roster.insert(participant) }
    return roster
}

@Suite("Active speakers")
struct ActiveSpeakersTests {
    private let alice = identity("alice")
    private let bob = identity("bob")

    @Test("a voiced packet starts speech and reports the transition")
    func voicedPacketStartsSpeech() {
        var speakers = ActiveSpeakers()
        let changed = speakers.heard(voiced: true, from: alice, at: .seconds(1))

        #expect(changed == [alice])
        #expect(speakers.isSpeaking(alice))
    }

    @Test("speech ends without a packet arriving, because DTX means silence is not sent")
    func hangoverExpiresWithoutPackets() {
        // The failure this covers: a state machine driven only by arriving
        // packets leaves the last person to talk in a silent room lit up
        // forever, because a publisher that stops talking stops sending.
        var speakers = ActiveSpeakers()
        speakers.heard(voiced: true, from: alice, at: .seconds(1))

        #expect(speakers.refresh(at: .milliseconds(1200)).isEmpty)
        #expect(speakers.isSpeaking(alice))

        #expect(speakers.refresh(at: .seconds(2)) == [alice])
        #expect(!speakers.isSpeaking(alice))
    }

    @Test("silent packets keep arriving without extending the speech they follow")
    func silencePacketsDoNotHold() {
        // A publisher that does not use DTX sends its silence, and treating any
        // arriving packet as evidence of speech would light the ring for as long
        // as somebody stayed connected.
        var speakers = ActiveSpeakers()
        speakers.heard(voiced: true, from: alice, at: .seconds(1))

        speakers.heard(voiced: false, from: alice, at: .milliseconds(1300))
        #expect(speakers.isSpeaking(alice))

        speakers.heard(voiced: false, from: alice, at: .milliseconds(1500))
        #expect(!speakers.isSpeaking(alice))
    }

    @Test("recency survives the speech ending, because it is what orders a quiet room")
    func recencyOutlivesSpeech() {
        var speakers = ActiveSpeakers()
        speakers.heard(voiced: true, from: alice, at: .seconds(1))
        speakers.heard(voiced: true, from: bob, at: .seconds(2))
        speakers.refresh(at: .seconds(10))

        #expect(!speakers.isSpeaking(alice))
        #expect(speakers.lastSpoke(alice) == .seconds(1))
        #expect(speakers.lastSpoke(bob) == .seconds(2))
    }

    @Test("two speakers are ordered most recent first")
    func concurrentSpeakersAreOrdered() {
        var speakers = ActiveSpeakers()
        speakers.heard(voiced: true, from: alice, at: .milliseconds(1000))
        speakers.heard(voiced: true, from: bob, at: .milliseconds(1100))

        #expect(speakers.speaking == [bob, alice])
    }

    @Test("a participant who leaves does not keep a claim on a tile after rejoining")
    func removalForgetsHistory() {
        var speakers = ActiveSpeakers()
        speakers.heard(voiced: true, from: alice, at: .seconds(1))
        speakers.remove(alice)

        #expect(!speakers.isSpeaking(alice))
        #expect(speakers.lastSpoke(alice) == nil)
    }
}

@Suite("Gallery grid")
struct GalleryGridTests {
    @Test("one participant is one tile")
    func single() {
        let grid = GalleryGrid.fitting(count: 1, in: (width: 390, height: 700))
        #expect(grid == GalleryGrid(columns: 1, rows: 1))
    }

    @Test("two tiles stack across a wide container and down a tall one")
    func twoFollowsTheContainer() {
        let wide = GalleryGrid.fitting(count: 2, in: (width: 1200, height: 400))
        let tall = GalleryGrid.fitting(count: 2, in: (width: 400, height: 1200))

        #expect(wide == GalleryGrid(columns: 2, rows: 1))
        #expect(tall == GalleryGrid(columns: 1, rows: 2))
    }

    @Test("sixteen 16:9 tiles on a portrait phone want two columns, not four")
    func sixteenUpOnAPhone() {
        // The result that makes the arithmetic worth having: a 4x4 grid looks
        // like the obvious answer and wastes most of the screen, because each
        // cell is taller than it is wide and 16:9 video letterboxes inside it.
        // Two columns of eight gives each tile roughly two and a half times the
        // visible pixels, which is also a rung on the ladder.
        let grid = GalleryGrid.fitting(count: 16, in: (width: 390, height: 700), spacing: 4)
        #expect(grid.columns == 2)
        #expect(grid.rows == 8)
    }

    @Test("square seats want more columns than 16:9 tiles in the same space")
    func squareSeatsSpreadWider() {
        // The audio-room case, and the reason aspect is a parameter rather than a
        // constant. On a phone with room to spare vertically, a square seat is
        // limited by the width it is given, so three columns of 125pt beats both
        // two columns that cannot use the height and four that are too narrow.
        let seats = GalleryGrid.fitting(
            count: 16,
            in: (width: 390, height: 700),
            aspect: 1,
            spacing: 8
        )
        let video = GalleryGrid.fitting(
            count: 16,
            in: (width: 390, height: 700),
            aspect: 16.0 / 9.0,
            spacing: 8
        )

        #expect(seats.columns == 3)
        #expect(seats.columns > video.columns)
    }

    @Test("tiles divide the container, spacing included")
    func tileSizeAccountsForSpacing() {
        let grid = GalleryGrid(columns: 3, rows: 2)
        let tile = grid.tile(in: (width: 320, height: 220), spacing: 10)

        #expect(tile.width == 100)
        #expect(tile.height == 105)
    }

    @Test("a partly filled last row is short rather than stretched")
    func rowsChunkEvenly() {
        let grid = GalleryGrid(columns: 3, rows: 2)
        #expect(grid.rows(of: Array(1 ... 5)) == [[1, 2, 3], [4, 5]])
        #expect(grid.rows(of: [Int]()).isEmpty)
    }
}

@Suite("Gallery occupancy")
struct GalleryTests {
    @Test("sixteen is the ceiling on video tiles however many the caller asks for")
    func videoCapacityIsClamped() {
        #expect(Gallery.Policy.grid(boxes: 32).capacity == Gallery.maximumVideoBoxes)
        #expect(Gallery.Policy.grid(boxes: 16).capacity == 16)
        #expect(Gallery.Policy.grid(boxes: 4).capacity == 4)
    }

    @Test("an audio room seats more than sixteen, because an avatar is not a decoder")
    func audioCapacityIsNotClamped() {
        #expect(Gallery.Policy.audioRoom(seats: 24).capacity == 24)
    }

    @Test("everyone is seated when there is room for everyone")
    func everyoneFits() {
        var gallery = Gallery(policy: .grid(boxes: 16))
        let room = people(9)
        gallery.update(roster(room), speakers: ActiveSpeakers(), at: .zero)

        #expect(gallery.slots.count == 9)
        #expect(gallery.overflow.isEmpty)
    }

    @Test("a speaker at the end of the alphabet gets a tile")
    func speechBeatsTheAlphabet() {
        // The defect this exists for: with twenty cohosts and sixteen boxes, an
        // implementation that ranks by roster order or by drawn area leaves out
        // the last four usernames and keeps leaving them out while they talk.
        var gallery = Gallery(policy: .grid(boxes: 16))
        let room = people(20)
        var speakers = ActiveSpeakers()
        speakers.heard(voiced: true, from: room[19].id, at: .seconds(1))

        gallery.update(roster(room), speakers: speakers, at: .seconds(1))

        #expect(gallery.slots.count == 16)
        #expect(gallery.order.contains(room[19].id))
        #expect(gallery.overflow.count == 4)
        #expect(!gallery.overflow.contains(room[19].id))
    }

    @Test("an utterance from the overflow waits for the dwell before it moves a tile")
    func dwellBoundsChurn() {
        // Without this, a room where four people are interrupting each other
        // rearranges on every syllable, and each move costs an unsubscribe, a
        // subscribe and a wait for a keyframe.
        var gallery = Gallery(policy: .grid(boxes: 4))
        let room = people(5)
        var speakers = ActiveSpeakers()

        gallery.update(roster(room), speakers: speakers, at: .zero)
        #expect(gallery.overflow == [room[4].id])

        speakers.heard(voiced: true, from: room[4].id, at: .seconds(1))
        let early = gallery.update(roster(room), speakers: speakers, at: .seconds(1))

        #expect(!early)
        #expect(gallery.overflow == [room[4].id])

        speakers.heard(voiced: true, from: room[4].id, at: .seconds(4))
        gallery.update(roster(room), speakers: speakers, at: .seconds(4))

        #expect(gallery.order.contains(room[4].id))
        #expect(gallery.overflow == [room[3].id])
    }

    @Test("a tile does not move because somebody else started talking")
    func positionsAreStableWhileHeld() {
        var gallery = Gallery(policy: .grid(boxes: 4))
        let room = people(4)
        var speakers = ActiveSpeakers()

        gallery.update(roster(room), speakers: speakers, at: .zero)
        let before = gallery.order

        speakers.heard(voiced: true, from: room[3].id, at: .seconds(1))
        let changed = gallery.update(roster(room), speakers: speakers, at: .seconds(1))

        // The speaking state changed, so a ring needs redrawing; the order did
        // not, so no face jumps position and no subscription moves.
        #expect(changed)
        #expect(gallery.order == before)
        #expect(gallery.slots.last?.isSpeaking == true)
    }

    @Test("a spotlight moves to the front and holds a tile it would not have earned")
    func spotlightLeads() {
        var gallery = Gallery(policy: .grid(boxes: 4))
        var room = people(5)
        room[4].isSpotlighted = true

        gallery.update(roster(room), speakers: ActiveSpeakers(), at: .zero)

        #expect(gallery.order.first == room[4].id)
        #expect(gallery.slots.first?.isFeatured == true)
        #expect(gallery.overflow == [room[3].id])
    }

    @Test("a pin takes effect immediately rather than waiting out the dwell")
    func pinningDoesNotWait() {
        var gallery = Gallery(policy: .grid(boxes: 4))
        let room = people(5)

        gallery.update(roster(room), speakers: ActiveSpeakers(), at: .zero)
        #expect(gallery.overflow == [room[4].id])

        gallery.pin(room[4].id)
        gallery.update(roster(room), speakers: ActiveSpeakers(), at: .milliseconds(100))

        #expect(gallery.order.first == room[4].id)
        #expect(gallery.overflow == [room[3].id])
    }

    @Test("a cohost who drops keeps their tile, and is the first to lose it")
    func absentHoldsThenYields() {
        var gallery = Gallery(policy: .grid(boxes: 4))
        var room = people(4)
        var speakers = ActiveSpeakers()

        gallery.update(roster(room), speakers: speakers, at: .zero)
        room[1].presence = .reconnecting
        gallery.update(roster(room), speakers: speakers, at: .seconds(1))

        // The room persists through a cohost walking into a lift: the tile stays
        // and says so, rather than the grid reflowing around a gap.
        #expect(gallery.order.contains(room[1].id))

        let arrival = person("user04")
        speakers.heard(voiced: true, from: arrival.id, at: .seconds(5))
        gallery.update(roster(room + [arrival]), speakers: speakers, at: .seconds(5))

        #expect(gallery.overflow == [room[1].id])
    }

    @Test("a departure frees its tile without waiting for the dwell")
    func departureIsImmediate() {
        var gallery = Gallery(policy: .grid(boxes: 4))
        let room = people(5)

        gallery.update(roster(room), speakers: ActiveSpeakers(), at: .zero)
        #expect(gallery.overflow == [room[4].id])

        gallery.update(
            roster(Array(room.dropFirst())),
            speakers: ActiveSpeakers(),
            at: .milliseconds(100)
        )

        #expect(gallery.overflow.isEmpty)
        #expect(gallery.order.contains(room[4].id))
    }

    @Test("shrinking the layout drops tiles immediately, dwell or not")
    func capacityIsAHardBound() {
        var gallery = Gallery(policy: .grid(boxes: 6))
        let room = people(6)

        gallery.update(roster(room), speakers: ActiveSpeakers(), at: .zero)
        #expect(gallery.slots.count == 6)

        gallery.policy = .grid(boxes: 2)
        gallery.update(roster(room), speakers: ActiveSpeakers(), at: .milliseconds(100))

        #expect(gallery.slots.count == 2)
        #expect(gallery.overflow.count == 4)
    }

    @Test("backstage is not seated, because a guest waiting to go live is not on air")
    func backstageIsNotSeated() {
        var gallery = Gallery(policy: .grid(boxes: 16))
        let room = people(2) + [person("guest", backstage: true)]

        gallery.update(roster(room), speakers: ActiveSpeakers(), at: .zero)

        #expect(gallery.slots.count == 2)
        #expect(gallery.overflow.isEmpty)
    }

    @Test("the local participant is excluded, because a self view is not a subscription")
    func exclusionHolds() {
        var gallery = Gallery(policy: .grid(boxes: 16))
        let room = people(4)
        gallery.excluded = [room[0].id]

        gallery.update(roster(room), speakers: ActiveSpeakers(), at: .zero)

        #expect(gallery.slots.count == 3)
        #expect(!gallery.order.contains(room[0].id))
    }

    @Test("an update that changes nothing reports nothing")
    func idempotence() {
        var gallery = Gallery(policy: .grid(boxes: 4))
        let room = people(3)

        let first = gallery.update(roster(room), speakers: ActiveSpeakers(), at: .zero)
        let second = gallery.update(roster(room), speakers: ActiveSpeakers(), at: .seconds(1))

        #expect(first)
        #expect(!second)
    }

    @Test("an audio room seats twenty speakers and keeps its order steady")
    func audioRoomSeatsEveryone() {
        var gallery = Gallery(policy: .audioRoom(seats: 24))
        let room = people(20)
        var speakers = ActiveSpeakers()

        gallery.update(roster(room), speakers: speakers, at: .zero)
        let before = gallery.order

        speakers.heard(voiced: true, from: room[17].id, at: .seconds(1))
        gallery.update(roster(room), speakers: speakers, at: .seconds(1))

        #expect(gallery.slots.count == 20)
        #expect(gallery.overflow.isEmpty)
        #expect(gallery.order == before)
    }
}

@Suite("Gallery over loopback")
struct GalleryIntegrationTests {
    private func voice(_ index: Int) -> AudioFrame {
        let step = 2 * Double.pi * 300 / 48000
        let offset = Double(index * 960)
        return AudioFrame(
            timestamp: FrameTimestamp(nanoseconds: UInt64(index) * 20_000_000),
            format: .voice,
            samples: (0 ..< 960).map { 0.5 * Float(sin((offset + Double($0)) * step)) }
        )
    }

    @Test("a viewer's gallery seats a cohost, and lights them up when they talk")
    func speechReachesTheGallery() async throws {
        // The whole path in one test: the publisher's voice-activity detector
        // sets a flag, the flag survives the wire as an object property, and the
        // subscriber turns it back into a speaking tile — with no server having
        // looked at the audio, which is what makes it work under E2EE.
        let relay = LoopbackRelay()

        let host = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: credentials("alice"),
            tenant: "acme"
        )
        try await host.connect(to: RelayEndpoint(host: "loopback"))
        let hostRoom = try await host.join(room: "room-42")

        let viewer = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: credentials("bob"),
            tenant: "acme"
        )
        try await viewer.connect(to: RelayEndpoint(host: "loopback"))
        let viewerRoom = try await viewer.join(room: "room-42")

        let source = AudioRelay(depth: 64)
        _ = try await hostRoom.startAudio(
            from: source,
            configuration: AudioPublicationConfiguration(
                encoderFactory: { SyntheticAudioEncoder(configuration: $0) }
            )
        )

        let who = identity("alice")

        // Seated on arrival. A cohost who has not said anything yet still has a
        // tile, and the claim says why.
        #expect(await eventually { await viewerRoom.galleryLayout.count == 1 })
        #expect(await viewerRoom.galleryLayout.first?.claim == .present)
        #expect(await viewerRoom.galleryOverflow.isEmpty)

        for index in 0 ..< 24 { source.submit(voice(index)) }

        #expect(await eventually { await viewerRoom.isSpeaking(who) })
        let slot = try #require(await viewerRoom.galleryLayout.first)
        #expect(slot.identity == who)
        #expect(slot.isSpeaking)
        #expect(slot.claim == .speaking)
    }

    @Test("speech ends on its own when the packets stop")
    func speechExpiresWithoutPackets() async throws {
        // Under DTX there is nothing to notice: a publisher that stops talking
        // stops sending. Something has to expire it, and this is that something
        // running for real rather than a hangover computed against a fixture.
        let relay = LoopbackRelay()

        let host = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: credentials("carol"),
            tenant: "acme"
        )
        try await host.connect(to: RelayEndpoint(host: "loopback"))
        let hostRoom = try await host.join(room: "room-42")

        let viewer = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: credentials("dave"),
            tenant: "acme"
        )
        try await viewer.connect(to: RelayEndpoint(host: "loopback"))
        let viewerRoom = try await viewer.join(room: "room-42")

        let source = AudioRelay(depth: 64)
        _ = try await hostRoom.startAudio(
            from: source,
            configuration: AudioPublicationConfiguration(
                encoderFactory: { SyntheticAudioEncoder(configuration: $0) }
            )
        )

        let who = identity("carol")
        #expect(await eventually { await viewerRoom.galleryLayout.count == 1 })

        for index in 0 ..< 24 { source.submit(voice(index)) }
        #expect(await eventually { await viewerRoom.isSpeaking(who) })

        #expect(await eventually(timeout: .seconds(3)) { await !viewerRoom.isSpeaking(who) })

        // Still seated, and still ranked above somebody who never spoke.
        let slot = try #require(await viewerRoom.galleryLayout.first)
        #expect(!slot.isSpeaking)
        if case .spoke = slot.claim {} else {
            Issue.record("expected a recency claim, got \(slot.claim)")
        }
    }
}
