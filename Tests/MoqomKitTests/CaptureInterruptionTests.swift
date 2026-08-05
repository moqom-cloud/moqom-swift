// A camera taken away by the phone, and whether the room finds out.
//
// Measured on two phones before any of this existed: Picture in Picture started
// when both apps went to the background, iOS took the cameras and left the
// microphones, and both tiles held a still frame for a hundred and four seconds.
// Audio never stopped. Every counter on the publishing side reported the outage
// the entire time — `interrupted=4 (sharing the screen)`, `NOTHING FOR 104s` —
// and none of it reached the other phone, because there was no field in which to
// say it.
//
// What is asserted here is that the silence is noticed by the publisher, that a
// silence somebody asked for is never mistaken for it, and that the fact arrives
// at the other end as a reason rather than as an absence.

import Foundation
import MoqomCore
import Testing

@testable import MoqomKit
@testable import MoqomLoopback

@Suite("A camera taken away")
struct CaptureInterruptionTests {
    private let endpoint = RelayEndpoint(host: "loopback")

    private let rung = VideoLayer(
        id: "video/360p",
        size: PixelSize(width: 640, height: 360),
        frameRate: 30,
        bitrate: 600_000
    )

    /// Short enough to test against, long enough that the polling inside the
    /// publication still gets several looks within it.
    private let noticesAfter = Duration.milliseconds(200)

    private func session(_ name: String, relay: LoopbackRelay) async throws -> MoqomSession {
        let session = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: credentials(name),
            tenant: "acme"
        )
        try await session.connect(to: endpoint)
        return session
    }

    private func submit(_ source: FrameRelay, count: Int, from offset: Int = 0) {
        for index in offset ..< (offset + count) {
            source.submit(
                VideoFrame(
                    timestamp: FrameTimestamp(nanoseconds: UInt64(index) * 33_000_000),
                    size: rung.size,
                    surface: .synthetic(byteCount: 1024),
                    forcesKeyFrame: index == 0
                )
            )
        }
    }

    private func broadcasting(
        _ name: String,
        relay: LoopbackRelay
    ) async throws -> (MoqomSession, RoomSession, Broadcast, FrameRelay) {
        let session = try await session(name, relay: relay)
        let room = try await session.join(room: "room-stall")
        let source = FrameRelay(format: CaptureFormat(size: rung.size, frameRate: 30), depth: 32)
        let broadcast = try await room.startBroadcast(
            from: source,
            configuration: BroadcastConfiguration(
                ladder: LayerLadder(rungs: [rung]),
                stallReportedAfter: noticesAfter,
                encoderFactory: { SyntheticEncoder(configuration: $0) }
            )
        )
        await broadcast.start()
        return (session, room, broadcast, source)
    }

    @Test("capture that stops without being asked to is noticed")
    func aStallIsNoticed() async throws {
        let relay = LoopbackRelay()
        let (session, _, broadcast, source) = try await broadcasting("ada", relay: relay)

        submit(source, count: 4)
        #expect(await eventually { await broadcast.stats.framesEncoded > 0 })
        #expect(await broadcast.stats.captureStalled == false)

        // Nothing further submitted, which is exactly what the phone did.
        #expect(
            await eventually { await broadcast.stats.captureStalled },
            "capture went quiet and the publication never noticed"
        )
        #expect(await broadcast.stats.captureStalls == 1)
        withExtendedLifetime(session) {}
    }

    @Test("a frame arriving ends it at once, rather than at the next check")
    func recoveryIsImmediate() async throws {
        let relay = LoopbackRelay()
        let (session, _, broadcast, source) = try await broadcasting("bob", relay: relay)

        submit(source, count: 4)
        #expect(await eventually { await broadcast.stats.captureStalled })

        submit(source, count: 1, from: 100)

        // No `eventually`: the point of clearing this from the frame's own path
        // is that the room stops being told something the viewer can see is
        // untrue, and a quarter second of that is a quarter second too long.
        #expect(
            await eventually(timeout: .milliseconds(120)) {
                await broadcast.stats.captureStalled == false
            },
            "the picture came back and the caption stayed up"
        )

        // Counted, though. The outage happened, and a phone that does this
        // every few minutes should be legible afterwards.
        #expect(await broadcast.stats.captureStalls == 1)
        withExtendedLifetime(session) {}
    }

    @Test("a mute is a silence somebody asked for, and is not reported as a fault")
    func mutingIsNotAnInterruption() async throws {
        let relay = LoopbackRelay()
        let (session, room, broadcast, source) = try await broadcasting("cleo", relay: relay)

        submit(source, count: 4)
        #expect(await eventually { await broadcast.stats.framesEncoded > 0 })

        // Muted, and then the source stops too — which is what a sample app
        // that turns the camera off along with the mute actually does.
        await room.setSelfMuted(.video)

        #expect(
            await eventually(timeout: .milliseconds(600)) {
                await broadcast.stats.captureStalled
            } == false,
            "a mute was reported to the room as a hardware interruption"
        )
        withExtendedLifetime(session) {}
    }

    @Test("a force-mute closes the camera on purpose, and is not reported as a fault")
    func forceMutingIsNotAnInterruption() async throws {
        let relay = LoopbackRelay()
        let (session, _, broadcast, source) = try await broadcasting("dara", relay: relay)

        submit(source, count: 4)
        #expect(await eventually { await broadcast.stats.framesEncoded > 0 })

        // The relay closing the hardware. The frames stop because they were
        // stopped, and the person already has a banner telling them so.
        await broadcast.setCaptureRestricted(true)

        #expect(
            await eventually(timeout: .milliseconds(600)) {
                await broadcast.stats.captureStalled
            } == false,
            "a force-mute was reported to the room as a hardware interruption"
        )
        withExtendedLifetime(session) {}
    }

    @Test("the room is told, and told that nobody chose it")
    func theRoomFindsOut() async throws {
        let relay = LoopbackRelay()
        let (host, _, _, source) = try await broadcasting("erin", relay: relay)
        let watcher = try await session("finn", relay: relay)
        let viewerRoom = try await watcher.join(room: "room-stall")

        let who = identity("erin")
        submit(source, count: 4)
        #expect(await eventually { await viewerRoom.roster[who] != nil })
        #expect(
            await eventually { await viewerRoom.roster[who]?.mute.interrupted == [] },
            "started out looking interrupted"
        )

        #expect(
            await eventually(timeout: .seconds(2)) {
                await viewerRoom.roster[who]?.mute.interrupted == .video
            },
            "the viewer was left watching a still frame with no explanation"
        )

        let mute = try #require(await viewerRoom.roster[who]?.mute)

        // The distinction the whole thing exists for. Both draw the same empty
        // tile; only one of them is a statement about the person.
        #expect(mute.selfMuted == [])
        #expect(mute.effective.contains(.video))
        #expect(mute.reason(for: .video) == .interrupted)

        withExtendedLifetime(host) {}
        withExtendedLifetime(watcher) {}
    }

    @Test("the room is told when it comes back")
    func theRoomFindsOutItRecovered() async throws {
        let relay = LoopbackRelay()
        let (host, _, _, source) = try await broadcasting("gus", relay: relay)
        let watcher = try await session("hana", relay: relay)
        let viewerRoom = try await watcher.join(room: "room-stall")

        let who = identity("gus")
        submit(source, count: 4)
        #expect(
            await eventually(timeout: .seconds(2)) {
                await viewerRoom.roster[who]?.mute.interrupted == .video
            }
        )

        submit(source, count: 4, from: 100)
        #expect(
            await eventually(timeout: .seconds(2)) {
                await viewerRoom.roster[who]?.mute.interrupted == []
            },
            "the caption outlived the outage"
        )

        withExtendedLifetime(host) {}
        withExtendedLifetime(watcher) {}
    }

    @Test("a deliberate mute is the reason shown, even while the hardware is also gone")
    func aChoiceOutranksAnAccident() {
        // Both true at once is ordinary: mute yourself, then put the phone in
        // your pocket. What the room should say is that you muted yourself.
        let mute = MuteState(selfMuted: .video, interrupted: .video)
        #expect(mute.reason(for: .video) == .selfChosen)

        let moderated = MuteState(forcedForEveryone: .video, interrupted: .video)
        #expect(moderated.reason(for: .video) == .moderator)

        let onlyTheHardware = MuteState(interrupted: .video)
        #expect(onlyTheHardware.reason(for: .video) == .interrupted)
    }

    @Test("a catalog from a build that predates this decodes as nothing wrong")
    func anOlderCatalogIsNotInterrupted() throws {
        // The field is absent from every catalog published before it existed,
        // and refusing those would take the whole participant off the stage
        // over a missing key.
        let older = """
        {"tracks":[],"version":1}
        """
        let catalog = try Catalog.decode(Data(older.utf8))
        #expect(catalog.interrupted == [])
        #expect(catalog.muted == [])
    }

    @Test("what the publisher says travels in the catalog")
    func theCatalogCarriesIt() throws {
        let catalog = Catalog(muted: .audio, interrupted: .video, tracks: [])
        let decoded = try Catalog.decode(catalog.encoded())

        // Separately, and both. Folding them together would make a phone that
        // was muted and then interrupted indistinguishable from one that was
        // interrupted and then muted, which are different sentences.
        #expect(decoded.muted == .audio)
        #expect(decoded.interrupted == .video)
    }
}
