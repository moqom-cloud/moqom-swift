import Foundation
import Testing

@testable import MoqomCore
@testable import MoqomKit
@testable import MoqomLoopback

/// Poll until `condition` holds, so a test does not depend on how many task
/// hops an announcement takes to propagate.
///
/// The default is generous on purpose. Waiting for something that will happen
/// costs only how long it actually takes — the loop returns on the first true —
/// so the timeout is not a budget for the fast path, it is the point at which a
/// test gives up and calls a hang a failure. Two seconds was tight enough that a
/// busy machine failed "the relay never sees plaintext, and the receiver does" on
/// a single frame that had not finished encoding, which reports load as a bug.
///
/// Tests that mean a deadline rather than an outcome pass their own, and the ones
/// that want to watch nothing happen for a while have to: for them the timeout is
/// the whole measurement.
func eventually(
    timeout: Duration = .seconds(10),
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await condition()
}

/// How many frames a publication has encoded, once it has stopped encoding.
///
/// For the tests that mute something and then claim nothing more was encoded.
/// Reading the count the moment the first frame appears measures a pipeline in
/// flight: a submission puts several frames in the source, the pump takes them
/// one at a time, and the encoder holds each for a while. Frames submitted
/// before the mute are still on their way through all of that, and they land
/// afterwards — so the assertion failed on a busy machine and passed on an idle
/// one, while the behaviour under test was identical in both.
func framesEncodedOnceSettled(_ broadcast: Broadcast) async -> Int {
    var last = await broadcast.stats.framesEncoded
    for _ in 0 ..< 100 {
        try? await Task.sleep(for: .milliseconds(20))
        let now = await broadcast.stats.framesEncoded
        if now == last { return now }
        last = now
    }
    return last
}

/// Credentials for a loopback session.
///
/// The token is shaped like a compact JWS, as a minted one is. In the clear
/// by default (``EncryptionPolicy/plaintextForTesting``, which no token or
/// application can ask for), because most suites here are about something
/// other than encryption and inspect media bytes on the loopback relay; the
/// suites that are about encryption pass `.required` or `nil` and say so.
func credentials(
    _ name: String,
    device: String = "iphone-0001",
    e2ee: EncryptionPolicy? = .plaintextForTesting
) -> DeviceCredentials {
    var credentials = DeviceCredentials(
        identity: identity(name, device: device),
        token: testToken(subject: name, e2ee: e2ee == nil ? nil : .required),
        deviceKey: nil
    )
    credentials.plaintextForTesting = e2ee == .plaintextForTesting
    credentials.authorityKeys = [testAuthority.verificationKey]
    return credentials
}

/// The room authority every test room trusts, from a fixed seed.
let testAuthority = try! RoomLogSigner(seed: Data(repeating: 0xA7, count: 32))

/// An unsigned token carrying the claims the SDK reads. The loopback relay
/// verifies nothing, so the signature segment is a placeholder.
func testToken(subject: String, e2ee: EncryptionPolicy?, publish: Bool? = nil) -> Data {
    var claims = #"{"sub":"\#(subject)""#
    if let e2ee { claims += #","e2ee":"\#(e2ee.rawValue)""# }
    if let publish { claims += #","moqt":{"room":"room-42","pub":\#(publish ? 1 : 0)}"# }
    claims += "}"
    let header = Data(#"{"alg":"EdDSA","typ":"MOQT"}"#.utf8).base64URLEncodedString
    return Data((header + "." + Data(claims.utf8).base64URLEncodedString + ".sig").utf8)
}

@Suite("Loopback transport")
struct LoopbackTransportTests {
    private let endpoint = RelayEndpoint(host: "loopback", alpn: ["moqt-19"])

    @Test("objects written to a track reach everyone subscribed to it")
    func objectsFanOut() async throws {
        let relay = LoopbackRelay()
        let transport = LoopbackTransport(relay: relay)
        let publisher = try await transport.connect(to: endpoint, credentials: credentials("alice"))
        let viewer = try await transport.connect(to: endpoint, credentials: credentials("bob"))

        let track = try FullTrackName(
            namespace: MoqomNamespaces.participant(
                tenant: "acme", room: "room-42", identity: identity("alice")
            ),
            name: TrackName("video/360p")
        )

        let subscription = try await viewer.subscribe(SubscribeRequest(track: track, priority: 16))
        let writer = try await publisher.publish(track, priority: 64)

        try await writer.write(
            TrackObject(group: 0, object: 0, payload: Data([1, 2, 3]), isKeyFrame: true)
        )
        try await writer.write(TrackObject(group: 0, object: 1, payload: Data([4])))

        var received: [TrackObject] = []
        for await object in subscription.objects {
            received.append(object)
            if received.count == 2 { break }
        }

        #expect(received.map(\.object) == [0, 1])
        #expect(received[0].isKeyFrame)
    }

    @Test("a late subscriber to a prefix still sees who is already there")
    func lateJoinerSeesExistingAnnouncements() async throws {
        // The roster is namespace announcement, so a client that joins after
        // the host must receive the announcements that already happened or the
        // room would look empty until the next person arrived.
        let relay = LoopbackRelay()
        let transport = LoopbackTransport(relay: relay)
        let host = try await transport.connect(to: endpoint, credentials: credentials("alice"))
        let prefix = try MoqomNamespaces.room(tenant: "acme", room: "room-42")

        _ = try await host.announce(
            MoqomNamespaces.participant(
                tenant: "acme", room: "room-42", identity: identity("alice")
            )
        )

        let viewer = try await transport.connect(to: endpoint, credentials: credentials("bob"))
        let stream = try await viewer.announcements(matching: prefix)

        var first: AnnouncementEvent?
        for await event in stream {
            first = event
            break
        }

        let expected = try MoqomNamespaces.participant(
            tenant: "acme", room: "room-42", identity: identity("alice")
        )
        #expect(first == .announced(expected))
    }

    @Test("withdrawal reaches watchers and removes the announcement for late joiners")
    func withdrawalPropagates() async throws {
        let relay = LoopbackRelay()
        let transport = LoopbackTransport(relay: relay)
        let host = try await transport.connect(to: endpoint, credentials: credentials("alice"))
        let prefix = try MoqomNamespaces.room(tenant: "acme", room: "room-42")

        let handle = try await host.announce(
            MoqomNamespaces.participant(
                tenant: "acme", room: "room-42", identity: identity("alice")
            )
        )
        #expect(await relay.announcements(under: prefix).count == 1)

        await handle.withdraw()
        #expect(await relay.announcements(under: prefix).isEmpty)
    }

    @Test("a connection failure surfaces as a typed transport error")
    func connectionFailure() async {
        let transport = LoopbackTransport(failure: .unreachable)
        await #expect(throws: MoqomError.self) {
            _ = try await transport.connect(
                to: RelayEndpoint(host: "loopback"),
                credentials: credentials("alice")
            )
        }
    }
}

@Suite("Rooms over loopback")
struct RoomSessionIntegrationTests {
    private let endpoint = RelayEndpoint(host: "loopback")

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

    @Test("going live puts the broadcaster in every other client's roster")
    func broadcastingPopulatesTheRoster() async throws {
        let relay = LoopbackRelay()
        let host = try await session("alice", relay: relay)
        let viewer = try await session("bob", relay: relay)

        let hostRoom = try await host.join(room: "room-42")
        let viewerRoom = try await viewer.join(room: "room-42")

        let source = FrameRelay(
            format: CaptureFormat(size: PixelSize(width: 1280, height: 720), frameRate: 30)
        )
        _ = try await hostRoom.startBroadcast(from: source)

        let appeared = await eventually {
            await viewerRoom.roster.count == 1
        }
        #expect(appeared)

        let roster = await viewerRoom.roster
        #expect(roster.participants.first?.username.value == "alice")
        #expect(roster.participants.first?.slot.isBackstage == false)
    }

    @Test("a backstage guest is invisible to the room prefix viewers watch")
    func backstageDoesNotReachTheAudience() async throws {
        let relay = LoopbackRelay()
        let guest = try await session("guest", relay: relay)
        let viewer = try await session("bob", relay: relay)

        let guestRoom = try await guest.join(room: "room-42")
        let viewerRoom = try await viewer.join(room: "room-42")

        let source = FrameRelay(
            format: CaptureFormat(size: PixelSize(width: 1280, height: 720), frameRate: 30)
        )
        _ = try await guestRoom.startBroadcast(from: source, backstage: true)

        // Give any announcement a chance to arrive before asserting absence.
        try await Task.sleep(for: .milliseconds(50))
        #expect(await viewerRoom.roster.count == 0)
    }

    @Test("stopping the broadcast withdraws the announcement and empties the roster")
    func stoppingRemovesTheParticipant() async throws {
        let relay = LoopbackRelay()
        let host = try await session("alice", relay: relay)
        let viewer = try await session("bob", relay: relay)
        let hostRoom = try await host.join(room: "room-42")

        // A withdrawal holds the seat by default, on the grounds that a session
        // ending is not the same as a person leaving -- see `SeatPolicy`. This
        // test is about the withdrawal reaching the roster at all, so it opts
        // out of the wait rather than sleeping through one.
        let viewerRoom = try await viewer.join(room: "room-42", seatPolicy: .immediate)

        let source = FrameRelay(
            format: CaptureFormat(size: PixelSize(width: 1280, height: 720), frameRate: 30)
        )
        _ = try await hostRoom.startBroadcast(from: source)
        _ = await eventually { await viewerRoom.roster.count == 1 }

        await hostRoom.stopBroadcast()

        #expect(await eventually { await viewerRoom.roster.count == 0 })
    }

    @Test("frames submitted from a render loop become published objects")
    func framesBecomeObjects() async throws {
        let relay = LoopbackRelay()
        let host = try await session("alice", relay: relay)
        let hostRoom = try await host.join(room: "room-42")

        // Deeper than the default, because this test hands over a burst without
        // ever yielding and the shallow default would legitimately drop most of
        // it. Backpressure has its own test below.
        let source = FrameRelay(
            format: CaptureFormat(size: PixelSize(width: 1280, height: 720), frameRate: 30),
            depth: 16
        )
        let ladder = LayerLadder(rungs: [
            VideoLayer(
                id: "video/360p",
                size: PixelSize(width: 640, height: 360),
                frameRate: 30,
                bitrate: 600_000
            ),
        ])
        let broadcast = try await hostRoom.startBroadcast(
            from: source,
            configuration: BroadcastConfiguration(
                ladder: ladder,
                // Synthetic frames carry no pixels, so a hardware encoder would
                // correctly refuse every one of them. What is under test is the
                // path from encoder output to published object, and that path
                // does not care whether the bytes decode.
                encoderFactory: { SyntheticEncoder(configuration: $0) }
            )
        )

        for index in 0 ..< 5 {
            source.submit(
                VideoFrame(
                    timestamp: FrameTimestamp(nanoseconds: UInt64(index) * 33_000_000),
                    size: PixelSize(width: 1280, height: 720),
                    surface: .synthetic(byteCount: 1280 * 720 * 3 / 2),
                    forcesKeyFrame: index == 0
                )
            )
        }

        #expect(await eventually { await broadcast.stats.objectsPublished == 5 })
        let stats = await broadcast.stats
        #expect(stats.framesSubmitted == 5)
        #expect(stats.framesDropped == 0)
    }

    @Test("the frame buffer drops the oldest rather than blocking the render loop")
    func backpressureDropsOldestFrames() async {
        // A submit that could block would stall the display. Under pressure the
        // frames worth keeping are the recent ones, because a frame past its
        // deadline is not late but worthless.
        let source = FrameRelay(
            format: CaptureFormat(size: PixelSize(width: 640, height: 360), frameRate: 30),
            depth: 2
        )
        for index in 0 ..< 100 {
            source.submit(
                VideoFrame(
                    timestamp: FrameTimestamp(nanoseconds: UInt64(index)),
                    size: PixelSize(width: 640, height: 360),
                    surface: .synthetic(byteCount: 0)
                )
            )
        }
        source.stop()

        var timestamps: [UInt64] = []
        for await frame in source.frames() {
            timestamps.append(frame.timestamp.nanoseconds)
        }

        #expect(timestamps.count == 2)
        #expect(timestamps == [98, 99])
    }

    @Test("a publisher does not subscribe to its own catalog")
    func catalogIsNotSelfSubscribed() async throws {
        // Announcing is what puts somebody in the roster, and this device
        // announces itself — so the roster contains the local participant and
        // the obvious loop subscribes to their catalog too. That is a round trip
        // to be told what this session just published, and it is invisible in a
        // bandwidth graph because a catalog is a few hundred bytes, which is
        // exactly why it needs a test rather than a review.
        let relay = LoopbackRelay()
        let host = try await session("alice", relay: relay)
        let hostRoom = try await host.join(room: "room-42")

        let source = FrameRelay(
            format: CaptureFormat(size: PixelSize(width: 1280, height: 720), frameRate: 30)
        )
        _ = try await hostRoom.startBroadcast(from: source)
        _ = await eventually { await hostRoom.roster.count == 1 }

        // Long enough for a subscription to have been made if one were going to
        // be. Asserting an absence needs a window, and this is the same one the
        // backstage test uses.
        try await Task.sleep(for: .milliseconds(50))

        // The room's control track is a legitimate subscription and every session
        // makes it; what must not appear is a subscription under this
        // participant's own namespace.
        let log = await relay.log
        let ownNamespace = try MoqomNamespaces.participant(
            tenant: "acme", room: "room-42", identity: identity("alice")
        )
        let selfSubscribed = log.contains {
            guard case let .subscribed(track, _) = $0 else { return false }
            return track.namespace == ownNamespace
        }
        #expect(!selfSubscribed, "subscribed to itself: \(log)")

        // And the catalog is still readable, because it is published from here
        // rather than fetched from the relay.
        #expect(await hostRoom.catalog(of: identity("alice")) != nil)
    }

    @Test("per-viewer mute asks nobody and costs the publisher nothing")
    func localMuteIsPurelyLocal() async throws {
        // Because the relay forwards rather than mixes, one viewer silencing
        // one cohost is an unsubscribe. Sending a control message would turn a
        // bandwidth saving into a round-trip for nothing.
        let relay = LoopbackRelay()
        let host = try await session("alice", relay: relay)
        let viewer = try await session("bob", relay: relay)
        let hostRoom = try await host.join(room: "room-42")
        let viewerRoom = try await viewer.join(room: "room-42")

        let source = FrameRelay(
            format: CaptureFormat(size: PixelSize(width: 1280, height: 720), frameRate: 30)
        )
        _ = try await hostRoom.startBroadcast(from: source)
        _ = await eventually { await viewerRoom.roster.count == 1 }

        // The roster filling is not the last thing joining does. Learning about
        // a participant is what triggers the subscription to their catalog, and
        // that reaches the relay a few hops later — so clearing the log on the
        // roster alone leaves it inside the window under test, and the assertion
        // below then fails for a reason that has nothing to do with mute.
        //
        // Waited for on the viewer rather than in the relay log, because the log
        // does not record who asked: the host subscribes to its own catalog too,
        // and matching that would let this proceed while the viewer's request is
        // still in flight, which is the race this is here to close.
        _ = await eventually { await viewerRoom.catalog(of: identity("alice")) != nil }

        await relay.clearLog()
        await viewerRoom.localMute(identity("alice"), .audio)
        try await Task.sleep(for: .milliseconds(20))

        // Nothing but an unsubscribe. In particular no publish, no write, and
        // no announcement: there is no message here that the publisher or any
        // other viewer could observe, and nothing that could be refused.
        let log = await relay.log
        #expect(
            log.allSatisfy {
                if case .unsubscribed = $0 { return true }
                return false
            },
            "local mute produced \(log)"
        )

        let muted = await viewerRoom.roster[identity("alice")]?.mute
        #expect(muted?.localToMe == .audio)
        #expect(muted?.reason(for: .audio) == .localToMe)
    }

    @Test("a layout update issues subscriptions sized to the boxes")
    func layoutDrivesSubscriptions() async throws {
        let relay = LoopbackRelay()
        let host = try await session("alice", relay: relay)
        let viewer = try await session("bob", relay: relay)
        let hostRoom = try await host.join(room: "room-42")
        let viewerRoom = try await viewer.join(room: "room-42")

        let source = FrameRelay(
            format: CaptureFormat(size: PixelSize(width: 1280, height: 720), frameRate: 30)
        )
        _ = try await hostRoom.startBroadcast(from: source)
        _ = await eventually { await viewerRoom.roster.count == 1 }

        await relay.clearLog()
        let changes = await viewerRoom.updateLayout([
            identity("alice"): RenderBox(width: 160, height: 90, scale: 3),
        ])

        #expect(changes.count == 1)
        guard case let .subscribe(_, layer, _) = changes[0] else {
            Issue.record("expected a subscribe")
            return
        }
        #expect(layer == "video/360p")

        let subscribed = await relay.recorded { interaction in
            if case let .subscribed(track, _) = interaction {
                return track.name.value == "video/360p"
            }
            return false
        }
        #expect(subscribed)
    }

    @Test("a box reported for your own tile does not subscribe you to yourself")
    func selfLayoutIsIgnored() async throws {
        // A self tile is a tile, so an application reports its size like any
        // other. Acting on it would download this device's own upload — invisible
        // on screen and doubled on the bill.
        let relay = LoopbackRelay()
        let host = try await session("alice", relay: relay)
        let hostRoom = try await host.join(room: "room-42")

        let source = FrameRelay(
            format: CaptureFormat(size: PixelSize(width: 1280, height: 720), frameRate: 30)
        )
        _ = try await hostRoom.startBroadcast(from: source)
        _ = await eventually { await hostRoom.roster.count == 1 }

        let changes = await hostRoom.updateLayout([
            identity("alice"): RenderBox(width: 320, height: 180, scale: 3),
        ])

        #expect(changes.isEmpty)
    }

    @Test("moderation is refused locally when the capability is absent")
    func moderationIsCheckedBeforeTheRoundTrip() async throws {
        let relay = LoopbackRelay()
        let viewer = try await session("bob", relay: relay)
        let room = try await viewer.join(room: "room-42")

        await #expect(throws: MoqomError.self) {
            try await room.moderate(.kick(identity("alice")), as: Grants())
        }
    }

    @Test("a recorder is attached with watchdog verbs and stays out of the roster")
    func watchdogsUseTheirOwnVerbs() async throws {
        let relay = LoopbackRelay()
        let host = try await session("alice", relay: relay)
        let room = try await host.join(room: "room-42")

        let source = FrameRelay(
            format: CaptureFormat(size: PixelSize(width: 1280, height: 720), frameRate: 30)
        )
        _ = try await room.startBroadcast(from: source)
        _ = await eventually { await room.roster.count == 1 }

        try await room.manageWatchdog(
            .attach(
                WatchdogRequest(
                    kind: .recording,
                    operatedBy: .tenant,
                    descriptor: "Recording",
                    scope: room.namespace,
                    pinnedLayer: "video/1080p"
                )
            ),
            as: Grants(moderation: .owner, isOwner: true)
        )

        #expect(await room.watchdogs.count == 1)
        #expect(await room.roster.count == 1)
        #expect(await room.currentState.isRecording)
    }

    @Test("managing watchdogs needs its own capability, not a moderation one")
    func watchdogManagementIsItsOwnGrant() async throws {
        let relay = LoopbackRelay()
        let host = try await session("alice", relay: relay)
        let room = try await host.join(room: "room-42")

        await #expect(throws: MoqomError.self) {
            try await room.manageWatchdog(
                .detach("rec-1"),
                as: Grants(moderation: .superModerator)
            )
        }
    }

    @Test("joining the same room twice returns the same session")
    func joinIsIdempotent() async throws {
        let relay = LoopbackRelay()
        let client = try await session("alice", relay: relay)
        let first = try await client.join(room: "room-42")
        let second = try await client.join(room: "room-42")

        #expect(first === second)
    }

    @Test("joining before connecting is a typed state error")
    func joinRequiresAConnection() async {
        let client = MoqomSession(
            transport: LoopbackTransport(),
            credentials: credentials("alice"),
            tenant: "acme"
        )

        await #expect(throws: MoqomError.self) {
            _ = try await client.join(room: "room-42")
        }
    }
}
