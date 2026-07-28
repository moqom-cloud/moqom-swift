//! What happens to somebody's place in the room when their session ends.
//!
//! The behaviour under test is the difference between a withdrawal and a
//! departure. Every test here produces the same event at the transport -- a
//! namespace going away -- and asserts a different outcome depending on what
//! else the room knows, which is the whole substance of `SeatPolicy`.

import Foundation
import Testing

@testable import MoqomCore
@testable import MoqomKit
@testable import MoqomLoopback

@Suite("Holding a seat")
struct SeatHoldingTests {
    private let endpoint = RelayEndpoint(host: "loopback", alpn: ["moqt-19"])

    private func session(
        _ name: String,
        relay: LoopbackRelay,
        device: String = "iphone-0001"
    ) async throws -> MoqomSession {
        let session = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: credentials(name, device: device),
            tenant: "acme"
        )
        try await session.connect(to: endpoint)
        return session
    }

    private func broadcaster() -> FrameRelay {
        FrameRelay(
            format: CaptureFormat(size: PixelSize(width: 1280, height: 720), frameRate: 30)
        )
    }

    /// A room with alice broadcasting and bob watching, bob's view returned.
    private func room(
        _ relay: LoopbackRelay,
        seatPolicy: SeatPolicy
    ) async throws -> (host: MoqomSession, viewer: MoqomSession, viewing: RoomSession) {
        let host = try await session("alice", relay: relay)
        let viewer = try await session("bob", relay: relay)
        let hosting = try await host.join(room: "room-42")
        let viewing = try await viewer.join(room: "room-42", seatPolicy: seatPolicy)

        _ = try await hosting.startBroadcast(from: broadcaster())
        #expect(await eventually { await viewing.roster.count == 1 })

        return (host, viewer, viewing)
    }

    @Test("a session that vanishes keeps its seat rather than leaving the room")
    func vanishingHoldsTheSeat() async throws {
        let relay = LoopbackRelay()
        let (host, viewer, viewing) = try await room(
            relay,
            // Long enough that the assertions below cannot pass by the timer
            // firing early.
            seatPolicy: SeatPolicy(viewer: .seconds(30))
        )
        let alice = identity("alice")

        await relay.drop(alice)

        // Still there, and visibly not well. This is the property the whole
        // design exists for: the tile stays, the grid does not reflow, and an
        // application has something honest to render over it.
        #expect(
            await eventually { await viewing.roster[alice]?.presence == .reconnecting }
        )
        #expect(await viewing.roster.count == 1)

        withExtendedLifetime((host, viewer)) {}
    }

    /// The counterpart, and the reason the withdrawal reason exists at all.
    ///
    /// Identical to the test above from the roster's side -- a namespace goes
    /// away under the room prefix, with the same policy in force -- and the
    /// opposite outcome, because the relay says this one was deliberate. Held for
    /// the same thirty seconds it would leave a tile of somebody who has plainly
    /// finished, which is the cost of not being able to tell them apart.
    @Test("a publisher who stops on purpose leaves at once, however long the window")
    func stoppingSkipsTheWindow() async throws {
        let relay = LoopbackRelay()
        let host = try await session("alice", relay: relay)
        let viewer = try await session("bob", relay: relay)
        let hosting = try await host.join(room: "room-42")
        let viewing = try await viewer.join(
            room: "room-42",
            seatPolicy: SeatPolicy(viewer: .seconds(30))
        )

        let broadcast = try await hosting.startBroadcast(from: broadcaster())
        let alice = identity("alice")
        #expect(await eventually { await viewing.roster.count == 1 })

        let departures = Departures()
        let watching = Task { [events = viewing.events] in
            for await event in events {
                if case let .participantLeft(who, reason) = event {
                    await departures.record(who, reason)
                }
            }
        }

        // Withdrawn rather than dropped: the announcement is closed on purpose,
        // which is what pressing stop does.
        await broadcast.stop()

        #expect(await eventually { await viewing.roster[alice] == nil })

        // `left`, not `timedOut`. Nothing timed out -- the room was told, and the
        // difference is what an application puts on screen.
        #expect(await departures.reason(for: alice) == .left)

        watching.cancel()
        withExtendedLifetime((host, viewer)) {}
    }

    @Test("a seat is released once the policy runs out")
    func expiryReleasesTheSeat() async throws {
        let relay = LoopbackRelay()
        let (host, viewer, viewing) = try await room(
            relay,
            seatPolicy: SeatPolicy(viewer: .milliseconds(150))
        )
        let alice = identity("alice")

        let departures = Departures()
        let watching = Task { [events = viewing.events] in
            for await event in events {
                if case let .participantLeft(who, reason) = event {
                    await departures.record(who, reason)
                }
            }
        }

        await relay.drop(alice)

        #expect(await eventually { await viewing.roster[alice] == nil })

        // The reason matters as much as the removal. "Their phone died and never
        // came back" and "they pressed leave" leave the same empty seat and want
        // different words on screen.
        #expect(await eventually { await departures.reason(for: alice) == .timedOut })

        watching.cancel()
        withExtendedLifetime((host, viewer)) {}
    }

    @Test("coming back inside the window resumes without a rejoin")
    func returningRestoresTheSeat() async throws {
        let relay = LoopbackRelay()
        let host = try await session("alice", relay: relay)
        let viewer = try await session("bob", relay: relay)
        let hosting = try await host.join(room: "room-42")
        let viewing = try await viewer.join(
            room: "room-42",
            seatPolicy: SeatPolicy(viewer: .seconds(30))
        )

        _ = try await hosting.startBroadcast(from: broadcaster())
        #expect(await eventually { await viewing.roster.count == 1 })

        let alice = identity("alice")

        // Nobody may leave the roster over the course of this test. Watched from
        // the start, because the assertion is about an event that must never
        // arrive -- checking the roster afterwards would not catch a removal
        // that was followed by a rejoin.
        let departures = Departures()
        let watching = Task { [events = viewing.events] in
            for await event in events {
                if case let .participantLeft(who, reason) = event {
                    await departures.record(who, reason)
                }
            }
        }

        await relay.drop(alice)
        #expect(
            await eventually { await viewing.roster[alice]?.presence == .reconnecting }
        )

        // Alice's session comes back and announces again, which is what a real
        // reconnect looks like from here.
        let returning = try await session("alice", relay: relay)
        let rejoined = try await returning.join(room: "room-42")
        _ = try await rejoined.startBroadcast(from: broadcaster())

        #expect(await eventually { await viewing.roster[alice]?.presence == .connected })
        #expect(await departures.count == 0, "the seat was released and re-taken")

        watching.cancel()
        withExtendedLifetime((host, viewer, returning)) {}
    }

    @Test("the window is longer for a host than for a viewer")
    func graceFollowsTheRole() {
        let policy = SeatPolicy.default

        // Not an arbitrary ordering. Dropping the owner early ends everybody
        // else's broadcast, and dropping a viewer late bills somebody for a
        // seat nobody is in.
        #expect(policy.grace(for: .owner) > policy.grace(for: .cohost))
        #expect(policy.grace(for: .cohost) >= policy.grace(for: .guest))
        #expect(policy.grace(for: .guest) > policy.grace(for: .viewer))
    }

    /// The case no transport timeout can reach: the connection is fine, the
    /// participant is present, and the pictures have stopped.
    @Test("a frozen publisher reads as stalled without the connection dropping")
    func stalledMediaOnAHealthyConnection() async throws {
        let relay = LoopbackRelay()
        let host = try await session("alice", relay: relay)
        let viewer = try await session("bob", relay: relay)
        let hosting = try await host.join(room: "room-42")
        let viewing = try await viewer.join(room: "room-42")

        let rung = VideoLayer(
            id: "video/360p",
            size: PixelSize(width: 640, height: 360),
            frameRate: 30,
            bitrate: 600_000
        )
        let source = FrameRelay(
            format: CaptureFormat(size: rung.size, frameRate: 30),
            depth: 32
        )
        _ = try await hosting.startBroadcast(
            from: source,
            configuration: BroadcastConfiguration(
                ladder: LayerLadder(rungs: [rung]),
                encoderFactory: { SyntheticEncoder(configuration: $0) }
            )
        )

        let alice = identity("alice")
        #expect(await eventually { await viewing.roster[alice] != nil })

        // Subscribed, so objects actually reach this client. Without a layout
        // there is no subscription, and the silence would be this viewer's own
        // doing rather than the publisher's.
        await viewing.updateLayout(
            [alice: RenderBox(width: 640, height: 360, scale: 1)],
            linkBitrate: 5_000_000
        )
        _ = await eventually { await viewing.codec(of: alice) != nil }

        for index in 0 ..< 4 {
            source.submit(
                VideoFrame(
                    timestamp: FrameTimestamp(nanoseconds: UInt64(index) * 33_000_000),
                    size: rung.size,
                    surface: .synthetic(byteCount: 1024),
                    forcesKeyFrame: index == 0
                )
            )
        }

        // Media arriving is what starts the clock, so this waits for an object
        // rather than for the subscription that will carry it.
        #expect(
            await eventually {
                await viewing.statistics.participants[alice]?.silentFor != nil
            }
        )

        // While it is running, it is not stalled.
        let live = try #require(await viewing.statistics.participants[alice])
        #expect(!live.isStalled(after: .milliseconds(150)))

        // The camera freezes -- nothing more is submitted. Nothing else changes:
        // no drop, no withdrawal, and the roster still says they are connected,
        // which is precisely why the transport cannot help here.

        #expect(
            await eventually {
                await viewing.statistics.participants[alice]?
                    .isStalled(after: .milliseconds(120)) == true
            }
        )

        // Still there, still connected. The stall is about their media, not
        // about their membership, and conflating the two is what produces a
        // participant who vanishes from the room because their camera hiccuped.
        #expect(await viewing.roster[alice]?.presence == .connected)

        withExtendedLifetime((host, viewer)) {}
    }

    @Test("opting out removes on withdrawal, with no window at all")
    func immediateSkipsTheWindow() async throws {
        let relay = LoopbackRelay()
        let (host, viewer, viewing) = try await room(relay, seatPolicy: .immediate)
        let alice = identity("alice")

        await relay.drop(alice)

        #expect(await eventually { await viewing.roster[alice] == nil })

        withExtendedLifetime((host, viewer)) {}
    }
}

/// Collects departures off the event stream.
private actor Departures {
    private var seen: [ParticipantIdentity: DepartureReason] = [:]

    func record(_ who: ParticipantIdentity, _ reason: DepartureReason) {
        seen[who] = reason
    }

    func reason(for who: ParticipantIdentity) -> DepartureReason? { seen[who] }
    var count: Int { seen.count }
}
