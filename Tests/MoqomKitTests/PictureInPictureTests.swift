import Foundation
import Testing

@testable import MoqomCore
@testable import MoqomKit
@testable import MoqomLoopback

private let prefix = try! MoqomNamespaces.room(tenant: "acme", room: "room-42")

private func member(
    _ name: String,
    role: ParticipantRole = .guest,
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
        : prefix

    var participant = Participant(
        slot: ParticipantSlot(announced: namespace, under: under, isBackstage: backstage)!
    )
    participant.grants = switch role {
    case .owner: Grants(publish: .camera, moderation: .owner, isOwner: true)
    case .cohost: Grants(publish: .camera, moderation: .superModerator)
    case .guest: Grants(publish: .camera)
    case .moderator: Grants(publish: .none, moderation: .moderator)
    case .viewer: Grants()
    }
    return participant
}

private actor Flag {
    private(set) var isRaised = false
    func raise() { isRaised = true }
}

private func room(
    _ participants: [Participant],
    lifecycle: RoomLifecycle = .live
) -> RoomState {
    var roster = Roster()
    for participant in participants { roster.insert(participant) }
    return RoomState(
        tenant: "acme",
        room: "room-42",
        namespace: prefix,
        roster: roster,
        lifecycle: lifecycle
    )
}

@Suite("Picture in Picture cast")
struct PictureInPictureCastTests {
    @Test("the host cast is the owner and nobody else")
    func hostIsTheOwner() {
        let owner = member("ana", role: .owner)
        let cohost = member("bo", role: .cohost)
        let guest = member("cy", role: .guest)

        #expect(PictureInPictureCast.host.admits(owner))
        #expect(!PictureInPictureCast.host.admits(cohost))
        #expect(!PictureInPictureCast.host.admits(guest))
    }

    @Test("the host cast follows the room when a cohost is holding it")
    func hostFollowsSuccession() {
        // Succession grants the job without granting ownership, so the acting
        // host's derived role is still `cohost`. A cast that went by role alone
        // would black the window out for exactly as long as the owner was in a
        // lift — which is the stretch of the broadcast somebody watching in a
        // corner of their screen most wants to see.
        let standing = member("bo", role: .cohost)
        #expect(!PictureInPictureCast.host.admits(standing))
        #expect(PictureInPictureCast.host.admits(standing, isActingHost: true))
    }

    @Test("cohosts and guests excludes the owner")
    func cohostsAndGuestsLeaveTheHostOut() {
        #expect(!PictureInPictureCast.cohostsAndGuests.admits(member("ana", role: .owner)))
        #expect(PictureInPictureCast.cohostsAndGuests.admits(member("bo", role: .cohost)))
        #expect(PictureInPictureCast.cohostsAndGuests.admits(member("cy", role: .guest)))
    }

    @Test("roles and identities compose into any combination")
    func castsCompose() {
        let pinned = member("cy", role: .viewer)
        let cast = PictureInPictureCast.host
            .including(.cohost)
            .including(pinned.id)

        #expect(cast.admits(member("ana", role: .owner)))
        #expect(cast.admits(member("bo", role: .cohost)))
        #expect(cast.admits(pinned))
        #expect(!cast.admits(member("dee", role: .guest)))
    }

    @Test("exclusion beats every other reason to be admitted")
    func exclusionWins() {
        // The case that matters is a viewer who locally muted somebody. Having
        // them reappear in the corner of the Home Screen because they started
        // talking would read as the mute not working.
        let loud = member("bo", role: .cohost)
        let cast = PictureInPictureCast.stage
            .followingSpeaker()
            .including(loud.id)
            .excluding(loud.id)

        #expect(!cast.admits(loud, isVocal: true))
    }

    @Test("only() admits exactly the people named")
    func onlyIsLiteral() {
        let chosen = member("cy", role: .guest)
        let cast = PictureInPictureCast.only([chosen.id])

        #expect(cast.admits(chosen))
        #expect(!cast.admits(member("ana", role: .owner)))
    }

    @Test("a backstage guest is never cast, whatever the rule says")
    func backstageIsNeverCast() {
        // They are published under a prefix the viewer is not subscribed to, so
        // a tile for them would be a tile that can never fill in.
        let waiting = member("dee", role: .guest, backstage: true)
        #expect(!PictureInPictureCast.stage.admits(waiting))
        #expect(!PictureInPictureCast.only([waiting.id]).admits(waiting))
    }

    @Test("the default cast works before any grants have arrived")
    func stageDoesNotWaitForGrants() {
        // A participant is in the roster because they announced a namespace,
        // so they are publishing by construction — but their role comes from
        // grants, which arrive later on the room control track. Until then
        // everyone reads as a viewer. A default cast spelled out as
        // [.owner, .cohost, .guest] would therefore show an empty window for
        // the first few hundred milliseconds of every room, and permanently in
        // a room with no control authority.
        let unknown = Participant(
            slot: ParticipantSlot(
                announced: try! MoqomNamespaces.participant(
                    tenant: "acme", room: "room-42", identity: identity("ana")
                ),
                under: prefix
            )!
        )
        #expect(unknown.role == .viewer)

        #expect(PictureInPictureCast.stage.admits(unknown))
        #expect(!PictureInPictureCast.cohostsAndGuests.admits(unknown))
    }

    @Test("the window will not draw more tiles than can be seen in it")
    func capacityIsBounded() {
        #expect(PictureInPictureCast.stage.showing(atMost: 9).capacity == 4)
        #expect(PictureInPictureCast.stage.showing(atMost: 0).capacity == 1)
        #expect(PictureInPictureCast.host.capacity == 1)
    }
}

@Suite("Picture in Picture stage")
struct PictureInPictureStageTests {
    private let me = identity("me")

    @Test("the viewer never occupies their own window")
    func viewerIsNotDrawn() {
        // Their camera is a self view drawn from the capture session. A tile
        // for it would be paying to download their own upload, round trip and
        // compression artefacts included.
        var stage = PictureInPictureStage(cast: .stage, viewer: me)
        stage.update(
            room([member("me", role: .cohost), member("ana", role: .owner)]),
            speakers: ActiveSpeakers(),
            at: .seconds(1)
        )

        #expect(stage.order == [identity("ana")])
    }

    @Test("a cast of cohosts and guests seats them and nobody else")
    func castDecidesOccupancy() {
        var stage = PictureInPictureStage(cast: .cohostsAndGuests, viewer: me)
        stage.update(
            room([
                member("ana", role: .owner),
                member("bo", role: .cohost),
                member("cy", role: .guest),
            ]),
            speakers: ActiveSpeakers(),
            at: .seconds(1)
        )

        #expect(Set(stage.order) == [identity("bo"), identity("cy")])
        #expect(stage.silentPartners.isEmpty)
    }

    @Test("everyone beyond four tiles overflows, and keeps their audio")
    func overflowIsBoundedAtFour() {
        var stage = PictureInPictureStage(cast: .stage, viewer: me)
        let crowd = (0 ..< 7).map { member("user\($0)", role: .guest) }
        stage.update(room(crowd), speakers: ActiveSpeakers(), at: .seconds(1))

        #expect(stage.slots.count == 4)
        #expect(stage.silentPartners.count == 3)
    }

    @Test("a speaker-following window does not go dark between sentences")
    func speechHoldsThroughAPause() {
        // The bug this exists for: admission on the rising edge of speech and
        // refusal on the falling one. `Gallery`'s dwell cannot help, because
        // somebody the cast has stopped admitting has not been displaced — they
        // have left the room as far as the layout is concerned — so their tile
        // is freed the instant they stop talking. In a one-tile window that is
        // the whole window going black in every gap between sentences.
        var stage = PictureInPictureStage(cast: .speaker, viewer: me)
        let host = member("ana", role: .owner)
        let guest = member("cy", role: .guest)
        let state = room([host, guest])

        var speakers = ActiveSpeakers()
        speakers.heard(voiced: true, from: guest.id, at: .seconds(1))
        stage.update(state, speakers: speakers, at: .seconds(1))
        #expect(stage.order == [guest.id])

        // Speech expires, and the guest is silent. The window should still be
        // showing them a second later.
        _ = speakers.refresh(at: .seconds(3))
        stage.update(state, speakers: speakers, at: .seconds(3))
        #expect(stage.order == [guest.id])

        // Long enough after, and the window falls back to the host.
        _ = speakers.refresh(at: .seconds(30))
        stage.update(state, speakers: speakers, at: .seconds(30))
        #expect(stage.order == [host.id])
    }

    @Test("a new speaker does not steal the only tile mid-sentence")
    func dwellSurvivesAnInterruption() {
        var stage = PictureInPictureStage(cast: .speaker, viewer: me)
        let host = member("ana", role: .owner)
        let guest = member("cy", role: .guest)
        let state = room([host, guest])

        var speakers = ActiveSpeakers()
        speakers.heard(voiced: true, from: host.id, at: .seconds(1))
        stage.update(state, speakers: speakers, at: .seconds(1))
        #expect(stage.order == [host.id])

        // The guest interrupts half a second later. Swapping the window's only
        // tile costs an unsubscribe, a subscribe and a wait for a keyframe, so
        // a room where two people talk over each other would spend the
        // conversation black.
        speakers.heard(voiced: true, from: guest.id, at: .milliseconds(1500))
        stage.update(state, speakers: speakers, at: .milliseconds(1500))
        #expect(stage.order == [host.id])
    }

    @Test("the room keeps the window's occupancy in step with the roster")
    func roomDrivesTheWindow() async throws {
        let relay = LoopbackRelay()
        let host = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: credentials("ana"),
            tenant: "acme"
        )
        let viewer = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: credentials("bob"),
            tenant: "acme"
        )
        try await host.connect(to: RelayEndpoint(host: "loopback"))
        try await viewer.connect(to: RelayEndpoint(host: "loopback"))

        let hostRoom = try await host.join(room: "room-42")
        let viewerRoom = try await viewer.join(room: "room-42")

        await viewerRoom.setPictureInPictureCast(PictureInPictureCast.stage)
        #expect(await viewerRoom.pictureInPictureSlots.isEmpty)

        let source = FrameRelay(
            format: CaptureFormat(size: PixelSize(width: 1280, height: 720), frameRate: 30)
        )
        _ = try await hostRoom.startBroadcast(from: source)

        #expect(await eventually { await viewerRoom.pictureInPictureSlots.count == 1 })
        #expect(await viewerRoom.pictureInPictureSlots.first?.identity.username.value == "ana")
    }

    @Test("the window's stream does not take events from the application's")
    func theWindowHasItsOwnStream() async throws {
        // `AsyncStream` splits between consumers rather than fanning out, so a
        // window that watched `events` would take room events the application
        // never sees. The symptom is a roster that updates roughly half the
        // time, and nothing about it points at Picture in Picture.
        let relay = LoopbackRelay()
        let host = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: credentials("ana"),
            tenant: "acme"
        )
        let viewer = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: credentials("bob"),
            tenant: "acme"
        )
        try await host.connect(to: RelayEndpoint(host: "loopback"))
        try await viewer.connect(to: RelayEndpoint(host: "loopback"))

        let hostRoom = try await host.join(room: "room-42")
        let viewerRoom = try await viewer.join(room: "room-42")
        await viewerRoom.setPictureInPictureCast(PictureInPictureCast.stage)

        let joined = Flag()
        let application = Task {
            for await event in viewerRoom.events {
                guard case .participantJoined = event else { continue }
                await joined.raise()
                return
            }
        }
        let window = Task {
            for await slots in await viewerRoom.pictureInPictureUpdates()
                where !slots.isEmpty
            {
                return slots
            }
            return []
        }

        let source = FrameRelay(
            format: CaptureFormat(size: PixelSize(width: 1280, height: 720), frameRate: 30)
        )
        _ = try await hostRoom.startBroadcast(from: source)

        #expect(await window.value.count == 1)
        await application.value
        #expect(await joined.isRaised)
    }

    @Test("widening the cast reseats without waiting for the next speech change")
    func castChangesTakeEffectImmediately() {
        var stage = PictureInPictureStage(cast: .host, viewer: me)
        let state = room([
            member("ana", role: .owner),
            member("bo", role: .cohost),
            member("cy", role: .guest),
        ])
        stage.update(state, speakers: ActiveSpeakers(), at: .seconds(1))
        #expect(stage.order == [identity("ana")])

        stage.cast = .stage
        stage.update(state, speakers: ActiveSpeakers(), at: .milliseconds(1100))
        #expect(stage.slots.count == 3)
    }
}

@Suite("Layout takeover")
@MainActor
struct LayoutTakeoverTests {
    /// The room and the session that owns it.
    ///
    /// Both, because ``LayoutObserver`` holds its room weakly — it is owned by
    /// a view hierarchy and must not keep a session alive past the screen that
    /// created it — so a test that let either go out of scope would be
    /// asserting against an observer with nothing to report to.
    private func room() async throws -> (MoqomSession, RoomSession) {
        let relay = LoopbackRelay()
        let session = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: credentials("bob"),
            tenant: "acme"
        )
        try await session.connect(to: RelayEndpoint(host: "loopback"))
        return (session, try await session.join(room: "room-42"))
    }

    private let ana = identity("ana")
    private let cy = identity("cy")

    @Test("the window replaces the grid's geometry rather than adding to it")
    func takeoverReplaces() async throws {
        // The bug this prevents costs money rather than frames. Backgrounding
        // an app does not tear its views down, so every `GeometryReader` in the
        // grid still holds the size it had when the user swiped home. A window
        // that merely added its own four small boxes would leave nine large
        // ones in place and go on paying for full-size video to draw
        // thumbnails, with the screen off, where nothing looks wrong.
        let (session, room) = try await room()
        let observer = LayoutObserver(room: room)
        observer.report(RenderBox(width: 390, height: 220, scale: 3), for: ana)
        observer.report(RenderBox(width: 390, height: 220, scale: 3), for: cy)
        await observer.flushNow()
        #expect(observer.lastReported.count == 2)

        observer.takeOver([ana: RenderBox(width: 80, height: 45, scale: 3)])
        await observer.flushNow()

        #expect(observer.lastReported.count == 1)
        #expect(observer.lastReported[ana]?.width == 80)
        #expect(observer.lastReported[cy] == nil)
        withExtendedLifetime(session) {}
    }

    @Test("the grid comes back in one pass, without waiting for a layout")
    func restoreIsImmediate() async throws {
        // The app is still in the background when the window closes, so there
        // is no layout pass coming to re-report the grid. Keeping the
        // hierarchy's boxes underneath is what lets the full-size subscriptions
        // resume before the user is looking at them, instead of a second later.
        let (session, room) = try await room()
        let observer = LayoutObserver(room: room)
        observer.report(RenderBox(width: 390, height: 220, scale: 3), for: ana)
        await observer.flushNow()

        observer.takeOver([ana: RenderBox(width: 80, height: 45, scale: 3)])
        await observer.flushNow()
        observer.restore()
        await observer.flushNow()

        #expect(observer.lastReported[ana]?.width == 390)
        #expect(observer.takenOver == nil)
        withExtendedLifetime(session) {}
    }
}
