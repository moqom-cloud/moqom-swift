// Reconnection, end to end rather than as a state machine.
//
// `SessionStateMachineTests` covers the transitions in isolation and always did.
// What was missing is everything either side of them: a carrier noticing it had
// died, a session turning that into an event, the session redialling, and a room
// coming back onto the new connection with its subscriptions and its publication
// intact. Those are the parts that were modelled and not wired, so these are the
// tests that would have passed against a state machine talking to nothing.

import Foundation
import Testing

@testable import MoqomCore
@testable import MoqomKit
@testable import MoqomLoopback

@Suite("Carrier loss")
struct CarrierLossTests {
    /// Both ends at once. SETUP is a handshake, so a dialler awaited before the
    /// accepter exists waits for a reply nobody is there to send.
    private func connectedPair(
        _ client: MemoryCarrier,
        _ server: MemoryCarrier
    ) async throws -> (dialled: MoqtSession, accepted: MoqtSession) {
        async let accepted = MoqtSession.accept(over: server)
        async let dialled = MoqtSession.connect(over: client, credentials: credentials("alice"))
        return try await (dialled, accepted)
    }

    @Test("a dropped carrier interrupts the session")
    func dropIsReported() async throws {
        let (client, server) = MemoryCarrier.pair()
        let (session, _) = try await connectedPair(client, server)

        await client.drop()

        var reported: TransportFailure?
        for await failure in session.interruptions {
            reported = failure
            break
        }
        #expect(reported == .idleTimeout)
    }

    @Test("both ends of a dropped connection learn about it")
    func dropReachesThePeer() async throws {
        // A path that goes away is not one-sided, and a peer that only learned
        // when it next tried to write would hold a dead session open for as long
        // as it happened to have nothing to say.
        let (client, server) = MemoryCarrier.pair()
        let (dialled, accepted) = try await connectedPair(client, server)

        await server.drop(.unreachable)

        var atDialler: TransportFailure?
        for await failure in dialled.interruptions {
            atDialler = failure
            break
        }
        var atAccepter: TransportFailure?
        for await failure in accepted.interruptions {
            atAccepter = failure
            break
        }
        #expect(atDialler == .unreachable)
        #expect(atAccepter == .unreachable)
    }

    @Test("closing a session deliberately is not an interruption")
    func closeIsNotLoss() async throws {
        // The distinction the whole reconnect path rests on. A close that
        // reported itself would have every clean disconnect immediately redial
        // the relay it was just told to leave.
        let (client, server) = MemoryCarrier.pair()
        let (session, _) = try await connectedPair(client, server)

        await session.close(code: 0, reason: "done")

        var reported: [TransportFailure] = []
        for await failure in session.interruptions { reported.append(failure) }
        #expect(reported.isEmpty)
    }
}

@Suite("Reconnecting a session")
struct SessionReconnectionTests {
    private let endpoint = RelayEndpoint(host: "loopback", alpn: ["moqt-19"])

    /// A session whose backoff costs nothing.
    ///
    /// The delay is the state machine's business and is unit-tested there; making
    /// these tests wait it out would only measure `Task.sleep`. A millisecond
    /// rather than zero because a retry against a relay that is deliberately
    /// refusing needs to yield, or the loop starves everything else in the test.
    private func session(
        _ name: String,
        transport: LoopbackTransport
    ) async throws -> MoqomSession {
        let session = MoqomSession(
            transport: transport,
            credentials: credentials(name),
            tenant: "acme",
            clock: { .zero },
            sleeper: { _ in try? await Task.sleep(for: .milliseconds(1)) }
        )
        try await session.connect(to: endpoint)
        return session
    }

    private func connectionCount(
        _ relay: LoopbackRelay,
        _ who: ParticipantIdentity
    ) async -> Int {
        await relay.log.count { $0 == .connected(who) }
    }

    @Test("a dropped session redials and comes back established")
    func reconnects() async throws {
        let relay = LoopbackRelay()
        let session = try await session("bob", transport: LoopbackTransport(relay: relay))
        let who = identity("bob")
        #expect(await session.state == .established)
        #expect(await connectionCount(relay, who) == 1)

        await relay.drop(who)

        // A second connection on the fabric is the assertion. The state coming
        // back to established says the machine agrees, but only the relay's log
        // says a socket was actually opened again.
        #expect(await eventually { await connectionCount(relay, who) == 2 })
        #expect(await eventually { await session.state == .established })

        await session.close()
    }

    @Test("closing during a pending reconnect does not resurrect the session")
    func closeBeatsReconnect() async throws {
        let relay = LoopbackRelay()
        let session = try await session("bob", transport: LoopbackTransport(relay: relay))
        let who = identity("bob")

        await relay.setAcceptingConnections(false)
        await relay.drop(who)
        #expect(await eventually { await session.state != .established })

        await relay.setAcceptingConnections(true)
        await session.close()

        // The retry in flight is allowed to finish losing. What it must not do is
        // install a connection into a session that has been closed, which would
        // leak it and put the state back.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await connectionCount(relay, who) == 1)
    }

    @Test("a session keeps retrying until the relay comes back")
    func retriesUntilTheRelayReturns() async throws {
        let relay = LoopbackRelay()
        let session = try await session("bob", transport: LoopbackTransport(relay: relay))
        let who = identity("bob")

        await relay.setAcceptingConnections(false)
        await relay.drop(who)

        // Still trying, and not established. A failed retry is not a new
        // disconnection, so this must not resolve itself by giving up.
        #expect(await eventually { await session.state != .established })

        await relay.setAcceptingConnections(true)
        #expect(await eventually { await session.state == .established })
        #expect(await connectionCount(relay, who) == 2)

        await session.close()
    }

    @Test("a session that was never connected does not redial on its own")
    func noEndpointNoRetry() async throws {
        // `transportLost` is public and an application may call it. Without an
        // endpoint there is nowhere to go, and inventing one is worse than
        // waiting.
        let relay = LoopbackRelay()
        let session = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: credentials("bob"),
            tenant: "acme",
            clock: { .zero },
            sleeper: { _ in }
        )
        await session.transportLost(at: .zero)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(await connectionCount(relay, identity("bob")) == 0)
    }
}

@Suite("Reconnecting a room")
struct RoomReconnectionTests {
    private let endpoint = RelayEndpoint(host: "loopback", alpn: ["moqt-19"])

    private let rung = VideoLayer(
        id: "video/360p",
        size: PixelSize(width: 640, height: 360),
        frameRate: 30,
        bitrate: 600_000
    )

    private func session(
        _ name: String,
        relay: LoopbackRelay
    ) async throws -> MoqomSession {
        let session = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: credentials(name),
            tenant: "acme",
            clock: { .zero },
            sleeper: { _ in try? await Task.sleep(for: .milliseconds(1)) }
        )
        try await session.connect(to: endpoint)
        return session
    }

    private func subscribeCount(_ relay: LoopbackRelay, to name: String) async -> Int {
        await relay.log.count {
            guard case let .subscribed(track, _) = $0 else { return false }
            return track.name.value == name
        }
    }

    @Test("a room restores its subscriptions without the application laying out again")
    func subscriptionsComeBack() async throws {
        let relay = LoopbackRelay()
        let host = try await session("alice", relay: relay)
        let hostRoom = try await host.join(room: "room-42")
        let source = FrameRelay(format: CaptureFormat(size: rung.size, frameRate: 30), depth: 16)
        _ = try await hostRoom.startBroadcast(
            from: source,
            configuration: BroadcastConfiguration(
                ladder: LayerLadder(rungs: [rung]),
                encoderFactory: { SyntheticEncoder(configuration: $0) }
            )
        )

        let viewer = try await session("bob", relay: relay)
        let viewerRoom = try await viewer.join(room: "room-42")
        let who = identity("alice")
        #expect(await eventually { await viewerRoom.roster[who] != nil })

        await viewerRoom.updateLayout(
            [who: RenderBox(width: 640, height: 360, scale: 1)],
            linkBitrate: 5_000_000
        )
        #expect(await eventually { await subscribeCount(relay, to: "video/360p") == 1 })

        await relay.drop(identity("bob"))

        // The roster is rebuilt from the new session's announcements, and the
        // subscription follows from the layout the room kept — with no second
        // `updateLayout` anywhere in this test.
        #expect(await eventually { await viewerRoom.roster[who] != nil })
        #expect(await eventually { await subscribeCount(relay, to: "video/360p") == 2 })

        await host.close()
        await viewer.close()
    }

    @Test("a broadcast keeps publishing across the host's reconnect")
    func broadcastSurvives() async throws {
        // The writers were streams on the dead session. Without rebinding them
        // the camera keeps running, the encoder keeps producing, and every object
        // goes nowhere — which is the worst version of this failure, because
        // nothing reports an error.
        let relay = LoopbackRelay()
        let host = try await session("alice", relay: relay)
        let hostRoom = try await host.join(room: "room-42")
        let source = FrameRelay(format: CaptureFormat(size: rung.size, frameRate: 30), depth: 16)
        _ = try await hostRoom.startBroadcast(
            from: source,
            configuration: BroadcastConfiguration(
                ladder: LayerLadder(rungs: [rung]),
                encoderFactory: { SyntheticEncoder(configuration: $0) }
            )
        )

        source.submit(
            VideoFrame(
                timestamp: FrameTimestamp(nanoseconds: 0),
                size: rung.size,
                surface: .synthetic(byteCount: 512),
                forcesKeyFrame: true
            )
        )
        #expect(
            await eventually {
                let published = await relay.objects(onTrackNamed: "video/360p")
                return !published.isEmpty
            }
        )
        let before = await relay.objects(onTrackNamed: "video/360p").count

        await relay.drop(identity("alice"))
        #expect(
            await eventually { await relay.log.count { $0 == .connected(identity("alice")) } == 2 }
        )

        for index in 1 ..< 4 {
            source.submit(
                VideoFrame(
                    timestamp: FrameTimestamp(nanoseconds: UInt64(index) * 33_000_000),
                    size: rung.size,
                    surface: .synthetic(byteCount: 512),
                    forcesKeyFrame: false
                )
            )
        }

        #expect(
            await eventually {
                let published = await relay.objects(onTrackNamed: "video/360p")
                return published.count > before
            }
        )

        await host.close()
    }

    @Test("a rung whose writer will not reopen is retried until it does")
    func aRefusedReopenIsRetried() async throws {
        // Found on two phones after thirty-seven minutes. A reconnect happened, reopening the
        // one rung failed, and the publication was left with no writer for the rest of the
        // call: the camera ran at a perfect thirty frames a second, the encoder compressed
        // every frame, and each one was discarded on the way to the wire. Nothing was logged
        // and nothing was counted — submitted climbed, encoded froze, dropped stayed at zero.
        //
        // What makes it worth a test is that the happy path already had one. Rebinding works
        // when opening the track works, and the failure only appears when it does not.
        let relay = LoopbackRelay()
        let host = try await session("alice", relay: relay)
        let hostRoom = try await host.join(room: "room-42")
        let source = FrameRelay(format: CaptureFormat(size: rung.size, frameRate: 30), depth: 16)
        _ = try await hostRoom.startBroadcast(
            from: source,
            configuration: BroadcastConfiguration(
                ladder: LayerLadder(rungs: [rung]),
                encoderFactory: { SyntheticEncoder(configuration: $0) }
            )
        )

        source.submit(
            VideoFrame(
                timestamp: FrameTimestamp(nanoseconds: 0),
                size: rung.size,
                surface: .synthetic(byteCount: 512),
                forcesKeyFrame: true
            )
        )
        #expect(
            await eventually { !(await relay.objects(onTrackNamed: "video/360p")).isEmpty }
        )
        let before = await relay.objects(onTrackNamed: "video/360p").count

        // The catalog track is opened on the way back too, so refuse enough attempts to be
        // sure the media track is among them.
        await relay.refusePublishes(3)
        await relay.drop(identity("alice"))
        #expect(
            await eventually { await relay.log.count { $0 == .connected(identity("alice")) } == 2 }
        )

        // Frames the whole time, as a camera would. Before the fix every one of these was
        // counted as submitted and then silently discarded.
        for index in 1 ..< 40 {
            source.submit(
                VideoFrame(
                    timestamp: FrameTimestamp(nanoseconds: UInt64(index) * 33_000_000),
                    size: rung.size,
                    surface: .synthetic(byteCount: 512),
                    forcesKeyFrame: false
                )
            )
            try? await Task.sleep(for: .milliseconds(20))
        }

        // Asserted on the track being opened a second time rather than on objects arriving,
        // and the distinction is not pedantry: a loopback writer holds the relay directly and
        // keeps delivering after its session is dropped, so objects continue to arrive here
        // whether or not the publisher ever reopened anything. That is also why this bug
        // survived a suite that already tested reconnecting publishers — the double cannot
        // express a dead stream, so the only observable difference is the reopen itself.
        #expect(
            await eventually(timeout: .seconds(10)) {
                await relay.log.count {
                    guard case let .published(track) = $0 else { return false }
                    return track.name.value == "video/360p"
                } == 2
            },
            "a refused reopen should be retried, not skipped for the rest of the call"
        )

        // And nothing was quietly discarded on the way.
        #expect(await relay.objects(onTrackNamed: "video/360p").count > before)

        await host.close()
    }

    @Test("a reconnected publisher re-announces and republishes its catalog")
    func announcementAndCatalogComeBack() async throws {
        // Both were held by the dead session: the announcement was a stream, and
        // the catalog's writer was one too. A publisher that came back without
        // them would be invisible in every other client's roster while cheerfully
        // sending media nobody has subscribed to.
        let relay = LoopbackRelay()
        let host = try await session("alice", relay: relay)
        let hostRoom = try await host.join(room: "room-42")
        let source = FrameRelay(format: CaptureFormat(size: rung.size, frameRate: 30), depth: 16)
        _ = try await hostRoom.startBroadcast(
            from: source,
            configuration: BroadcastConfiguration(
                ladder: LayerLadder(rungs: [rung]),
                encoderFactory: { SyntheticEncoder(configuration: $0) }
            )
        )

        let namespace = try MoqomNamespaces.participant(
            tenant: "acme",
            room: "room-42",
            identity: identity("alice")
        )
        #expect(await eventually { await !relay.announcements(under: namespace).isEmpty })
        let announcements = await relay.log.count { $0 == .announced(namespace) }

        await relay.drop(identity("alice"))

        #expect(
            await eventually { await relay.log.count { $0 == .announced(namespace) } > announcements }
        )
        #expect(await !relay.announcements(under: namespace).isEmpty)

        // A viewer arriving after the reconnect finds the publisher through the
        // roster and finds a catalog to build a decoder from.
        let viewer = try await session("carol", relay: relay)
        let viewerRoom = try await viewer.join(room: "room-42")
        #expect(await eventually { await viewerRoom.roster[identity("alice")] != nil })
        #expect(
            await eventually {
                await viewerRoom.catalog(of: identity("alice"))?.track(named: "video/360p") != nil
            }
        )

        await host.close()
        await viewer.close()
    }
}
