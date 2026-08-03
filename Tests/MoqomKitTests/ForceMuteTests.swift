// Being muted by somebody else.
//
// The claims worth testing are the ones a participant can check without a
// debugger. The camera actually closes, so the indicator goes out. The relay
// lifting the mute does not reopen it, because a server that could open a
// camera is a different product. And an audience mute — which is a change of
// who receives the media, not of whether it is produced — leaves the hardware
// exactly where it was.
//
// The policy arrives the way the real relay sends it: pushed at a session that
// asked for nothing, on a `.policy` track under the participant's own slot.

import Foundation
import MoqomCore
import Testing

@testable import MoqomKit
@testable import MoqomLoopback

/// A frame source that records whether its hardware is open.
///
/// ``FrameRelay`` cannot answer the question — it has no device, so its
/// ``FrameSource/suspend()`` is correctly a no-op — and the question is the
/// whole point of the feature.
private final class WatchedCamera: FrameSource, @unchecked Sendable {
    private let relay: FrameRelay
    private let lock = NSLock()
    private var open = true
    private var suspensions = 0

    init(format: CaptureFormat) {
        relay = FrameRelay(format: format, depth: 32)
    }

    var captureFormat: CaptureFormat { relay.captureFormat }

    func frames() -> AsyncStream<VideoFrame> { relay.frames() }

    func stop() { relay.stop() }

    func suspend() {
        lock.withLock {
            open = false
            suspensions += 1
        }
    }

    func resume() {
        lock.withLock { open = true }
    }

    /// Whether the device is powered, which is what the indicator reports.
    var isOpen: Bool { lock.withLock { open } }

    /// How many times it has been closed, so a second mute can be told from a
    /// mute that was never lifted.
    var timesClosed: Int { lock.withLock { suspensions } }

    func submit(_ count: Int, from offset: Int = 0) {
        for index in offset ..< (offset + count) {
            relay.submit(
                VideoFrame(
                    timestamp: FrameTimestamp(nanoseconds: UInt64(index) * 33_000_000),
                    size: captureFormat.size,
                    surface: .synthetic(byteCount: 1024),
                    forcesKeyFrame: index == offset
                )
            )
        }
    }
}

@Suite("Being force-muted")
struct ForceMuteTests {
    private let endpoint = RelayEndpoint(host: "loopback")
    private let tenant: TenantID = "acme"
    private let roomID: RoomID = "room-moderated"

    private let rung = VideoLayer(
        id: "video/360p",
        size: PixelSize(width: 640, height: 360),
        frameRate: 30,
        bitrate: 600_000
    )

    private func broadcasting(
        _ name: String,
        relay: LoopbackRelay
    ) async throws -> (MoqomSession, RoomSession, Broadcast, WatchedCamera) {
        let session = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: credentials(name),
            tenant: tenant
        )
        try await session.connect(to: endpoint)
        let room = try await session.join(room: roomID)
        let camera = WatchedCamera(format: CaptureFormat(size: rung.size, frameRate: 30))
        let broadcast = try await room.startBroadcast(
            from: camera,
            configuration: BroadcastConfiguration(
                ladder: LayerLadder(rungs: [rung]),
                encoderFactory: { SyntheticEncoder(configuration: $0) }
            )
        )
        await broadcast.start()
        return (session, room, broadcast, camera)
    }

    /// Where the relay publishes one participant's restrictions.
    private func policyTrack(for name: String) throws -> FullTrackName {
        try FullTrackName(
            namespace: MoqomNamespaces.participant(
                tenant: tenant,
                room: roomID,
                identity: identity(name)
            ),
            name: TrackName(ParticipantPolicy.trackName)
        )
    }

    private func enforce(
        _ policy: ParticipantPolicy,
        on name: String,
        through relay: LoopbackRelay
    ) async throws {
        try await relay.push(
            policy.encoded(),
            on: policyTrack(for: name),
            to: identity(name)
        )
    }

    @Test("a force-mute closes the camera rather than only the encoder")
    func forceMuteStopsCapture() async throws {
        let relay = LoopbackRelay()
        let (session, room, broadcast, camera) = try await broadcasting("olga", relay: relay)

        camera.submit(4)
        _ = await eventually { await broadcast.stats.framesEncoded > 0 }
        let encodedBefore = await broadcast.stats.framesEncoded

        try await enforce(
            ParticipantPolicy(mutedForEveryone: .video),
            on: "olga",
            through: relay
        )

        #expect(await eventually { camera.isOpen == false })
        #expect(await room.forceMuted == .video)
        #expect(await broadcast.isRestricted)

        // A source that kept producing anyway — a scene renderer, a modified
        // build — still publishes nothing. The device closing is what the user
        // can see; this is what the room can.
        camera.submit(6, from: 4)
        _ = await eventually(timeout: .milliseconds(300)) {
            await broadcast.stats.framesMuted >= 6
        }
        #expect(await broadcast.stats.framesEncoded == encodedBefore)

        withExtendedLifetime(session) {}
    }

    @Test("lifting a force-mute does not turn the camera back on")
    func liftingDoesNotResumeCapture() async throws {
        let relay = LoopbackRelay()
        let (session, room, broadcast, camera) = try await broadcasting("peter", relay: relay)

        try await enforce(
            ParticipantPolicy(mutedForEveryone: .video),
            on: "peter",
            through: relay
        )
        #expect(await eventually { camera.isOpen == false })

        try await enforce(ParticipantPolicy(), on: "peter", through: relay)
        #expect(await eventually { await room.resumableAfterForceMute == .video })

        // Given time to be wrong. The failure this guards against is a camera
        // that comes back a moment after the lift, which no immediate assertion
        // would catch.
        try? await Task.sleep(for: .milliseconds(150))
        #expect(camera.isOpen == false, "the relay reopened a camera it had closed")
        #expect(await room.forceMuted == [])
        #expect(await broadcast.isRestricted)

        // Only the person in front of it.
        let resumed = await room.resumeAfterForceMute()
        #expect(resumed == .video)
        #expect(camera.isOpen)
        #expect(await broadcast.isRestricted == false)
        #expect(await room.resumableAfterForceMute == [])

        camera.submit(4, from: 100)
        #expect(await eventually { await broadcast.stats.framesEncoded > 0 })

        withExtendedLifetime(session) {}
    }

    @Test("resuming while still muted does nothing")
    func resumingUnderAMuteIsRefused() async throws {
        let relay = LoopbackRelay()
        let (session, room, _, camera) = try await broadcasting("quinn", relay: relay)

        try await enforce(
            ParticipantPolicy(mutedForEveryone: [.audio, .video]),
            on: "quinn",
            through: relay
        )
        #expect(await eventually { camera.isOpen == false })

        let resumed = await room.resumeAfterForceMute()
        #expect(resumed == [])
        #expect(camera.isOpen == false)

        withExtendedLifetime(session) {}
    }

    @Test("an audience mute leaves the camera running")
    func audienceMuteDoesNotStopCapture() async throws {
        // The hosts are still watching. Closing the device would take the
        // participant off their screens as well, which is the opposite of what
        // an audience-scoped mute means.
        let relay = LoopbackRelay()
        let (session, room, broadcast, camera) = try await broadcasting("rosa", relay: relay)

        camera.submit(4)
        _ = await eventually { await broadcast.stats.framesEncoded > 0 }

        try await enforce(
            ParticipantPolicy(mutedForAudience: .video),
            on: "rosa",
            through: relay
        )

        #expect(
            await eventually {
                await room.currentState.roster[identity("rosa")]?.mute.forcedForAudience == .video
            }
        )
        #expect(camera.isOpen)
        #expect(await broadcast.isRestricted == false)
        #expect(await room.resumableAfterForceMute == [])

        let encodedBefore = await broadcast.stats.framesEncoded
        camera.submit(4, from: 4)
        #expect(await eventually { await broadcast.stats.framesEncoded > encodedBefore })

        withExtendedLifetime(session) {}
    }

    @Test("a second mute after a lift closes the camera again")
    func aMuteAfterALiftIsEnforced() async throws {
        // The re-offer case. Every mute is its own PUBLISH, and a client that
        // read only the first one would enforce a mute that had been lifted and
        // ignore the one it is under.
        let relay = LoopbackRelay()
        let (session, room, _, camera) = try await broadcasting("sara", relay: relay)

        try await enforce(
            ParticipantPolicy(mutedForEveryone: .video),
            on: "sara",
            through: relay
        )
        #expect(await eventually { camera.timesClosed == 1 })

        try await enforce(ParticipantPolicy(), on: "sara", through: relay)
        #expect(await eventually { await room.resumableAfterForceMute == .video })
        _ = await room.resumeAfterForceMute()

        try await enforce(
            ParticipantPolicy(mutedForEveryone: .video),
            on: "sara",
            through: relay
        )
        #expect(await eventually { camera.timesClosed == 2 })
        #expect(camera.isOpen == false)

        withExtendedLifetime(session) {}
    }

    @Test("a policy from a newer version is not read as an empty one")
    func unknownVersionsHoldTheMute() async throws {
        let relay = LoopbackRelay()
        let (session, room, _, camera) = try await broadcasting("tomas", relay: relay)

        try await enforce(
            ParticipantPolicy(mutedForEveryone: .video),
            on: "tomas",
            through: relay
        )
        #expect(await eventually { camera.isOpen == false })

        try await enforce(
            ParticipantPolicy(version: 2, mutedForEveryone: []),
            on: "tomas",
            through: relay
        )
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await room.forceMuted == .video)
        #expect(camera.isOpen == false)

        withExtendedLifetime(session) {}
    }

    @Test("the wire format is the relay's")
    func policyDecodesWhatTheRelayWrites() throws {
        // Byte for byte what `policy_payload` in the relay produces. A decoder
        // written against the Swift encoder alone would pass while disagreeing
        // with the only thing that ever sends this.
        let payload = Data(#"{"version":1,"mutedForEveryone":3,"mutedForAudience":2}"#.utf8)
        let policy = try ParticipantPolicy.decode(payload)

        #expect(policy.version == 1)
        #expect(policy.mutedForEveryone == [.audio, .video])
        #expect(policy.mutedForAudience == .video)
        #expect(policy.isEmpty == false)
        #expect(try ParticipantPolicy.decode(ParticipantPolicy().encoded()).isEmpty)
    }
}
