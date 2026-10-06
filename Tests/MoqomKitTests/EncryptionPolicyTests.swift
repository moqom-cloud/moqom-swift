import Foundation
import Testing

@testable import MoqomCore
@testable import MoqomKit
@testable import MoqomLoopback

@Suite("Encryption policy from the token")
struct EncryptionPolicyClaimTests {
    @Test("a token with no e2ee claim requires encryption")
    func absentClaimIsRequired() {
        #expect(EncryptionPolicy(token: testToken(subject: "alice", e2ee: nil)) == .required)
    }

    @Test("only an exact optional claim relaxes it")
    func onlyOptionalRelaxes() {
        #expect(EncryptionPolicy(token: testToken(subject: "alice", e2ee: .optional)) == .optional)
        #expect(EncryptionPolicy(token: testToken(subject: "alice", e2ee: .required)) == .required)

        // A value this build does not know — a stricter mode a newer control
        // plane invented, or a typo — must not read as permission.
        let header = Data(#"{"alg":"EdDSA"}"#.utf8).base64URLEncodedString
        for value in ["OPTIONAL", "off", "", "none"] {
            let claims = Data(#"{"e2ee":"\#(value)"}"#.utf8).base64URLEncodedString
            let token = Data("\(header).\(claims).sig".utf8)
            #expect(EncryptionPolicy(token: token) == .required, "\(value)")
        }
    }

    @Test("a token that is not a compact JWS requires encryption")
    func unreadableTokensFailClosed() {
        for raw in ["", "token-alice", "a.b.c", "a.b", "a.!!!.c"] {
            #expect(EncryptionPolicy(token: Data(raw.utf8)) == .required, "\(raw)")
        }
    }
}

@Suite("Encryption policy on the media path")
struct EncryptionPolicyMediaTests {
    private let rung = VideoLayer(
        id: "video/360p",
        size: PixelSize(width: 640, height: 360),
        frameRate: 30,
        bitrate: 600_000
    )

    private func join(
        _ name: String,
        e2ee: EncryptionPolicy?,
        relay: LoopbackRelay
    ) async throws -> RoomSession {
        let session = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: credentials(name, e2ee: e2ee),
            tenant: "acme"
        )
        try await session.connect(to: RelayEndpoint(host: "loopback"))
        return try await session.join(room: "room-42")
    }

    private func broadcast(
        from room: RoomSession,
        source: FrameRelay
    ) async throws(MoqomError) -> Broadcast {
        try await room.startBroadcast(
            from: source,
            configuration: BroadcastConfiguration(
                ladder: LayerLadder(rungs: [rung]),
                encoderFactory: { SyntheticEncoder(configuration: $0) }
            )
        )
    }

    private func submit(_ count: Int, to source: FrameRelay) {
        for index in 0 ..< count {
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

    @Test("a room with no claim refuses to publish video without a key, and opens nothing")
    func refusesToPublishVideoWithoutKey() async throws {
        let relay = LoopbackRelay()
        let room = try await join("alice", e2ee: nil, relay: relay)
        #expect(await room.encryptionPolicy == .required)

        let source = FrameRelay(format: CaptureFormat(size: rung.size, frameRate: 30), depth: 16)
        await #expect {
            try await broadcast(from: room, source: source)
        } throws: { error in
            guard case MoqomError.encryptionRequired = error else { return false }
            return true
        }

        // Refused before the announcement: nobody is put in the roster for a
        // publication that is not going to happen.
        let prefix = try MoqomNamespaces.room(tenant: "acme", room: "room-42")
        #expect(await relay.announcements(under: prefix).isEmpty)
        #expect(await relay.objects(onTrackNamed: "video/360p").isEmpty)
    }

    @Test("a required room refuses to publish audio without a key")
    func refusesToPublishAudioWithoutKey() async throws {
        let relay = LoopbackRelay()
        let room = try await join("alice", e2ee: .required, relay: relay)

        await #expect {
            try await room.startAudio(
                from: AudioRelay(depth: 8),
                configuration: AudioPublicationConfiguration(
                    encoderFactory: { SyntheticAudioEncoder(configuration: $0) }
                )
            )
        } throws: { error in
            guard case MoqomError.encryptionRequired = error else { return false }
            return true
        }
        #expect(await relay.objects(onTrackNamed: "audio").isEmpty)
    }

    @Test("a required room publishes once a key is configured, and only ciphertext")
    func publishesWithKey() async throws {
        let relay = LoopbackRelay()
        let room = try await join("alice", e2ee: nil, relay: relay)
        await room.useEncryption(.sharedKey(Data(repeating: 0x5A, count: 32), keyID: 1))
        #expect(await room.isEncrypted)

        let source = FrameRelay(format: CaptureFormat(size: rung.size, frameRate: 30), depth: 16)
        let live = try await broadcast(from: room, source: source)
        submit(1, to: source)
        #expect(await eventually { await live.stats.objectsPublished == 1 })

        let sealed = try #require(await relay.objects(onTrackNamed: "video/360p").first)
        #expect(Set(sealed.payload.dropFirst(8)).count > 32)
    }

    @Test("unencrypted media is dropped by a required room with no key, and it says so")
    func unencryptedIncomingRefusedWithoutKey() async throws {
        let relay = LoopbackRelay()
        let hostRoom = try await join("alice", e2ee: .optional, relay: relay)
        let viewerRoom = try await join("bob", e2ee: .required, relay: relay)

        let who = identity("alice")
        let refused = Task {
            for await event in viewerRoom.events {
                if case let .encryptionRequired(from) = event, from == who { return true }
            }
            return false
        }

        let source = FrameRelay(format: CaptureFormat(size: rung.size, frameRate: 30), depth: 16)
        let live = try await broadcast(from: hostRoom, source: source)
        #expect(await eventually { await viewerRoom.roster[who] != nil })
        await viewerRoom.updateLayout(
            [who: RenderBox(width: 640, height: 360, scale: 1)],
            linkBitrate: 5_000_000
        )
        let objects = try #require(await viewerRoom.media(from: who))

        submit(6, to: source)
        #expect(await eventually { await live.stats.objectsPublished >= 4 })
        #expect(await relay.objects(onTrackNamed: "video/360p").count >= 4)

        #expect(await refused.value)

        // The plaintext reached this device's transport and went no further.
        let delivered = Task {
            var count = 0
            for await _ in objects { count += 1 }
            return count
        }
        try await Task.sleep(for: .milliseconds(200))
        delivered.cancel()
        #expect(await delivered.value == 0)
        #expect(await viewerRoom.videoStatistics(for: who)?.framesProduced ?? 0 == 0)
    }

    @Test("unencrypted media fails authentication in a room holding a key")
    func unencryptedIncomingRejectedWithKey() async throws {
        let relay = LoopbackRelay()
        let hostRoom = try await join("alice", e2ee: .optional, relay: relay)
        let viewerRoom = try await join("bob", e2ee: .required, relay: relay)
        await viewerRoom.useEncryption(.sharedKey(Data(repeating: 0x5A, count: 32), keyID: 1))

        let who = identity("alice")
        let source = FrameRelay(format: CaptureFormat(size: rung.size, frameRate: 30), depth: 16)
        _ = try await broadcast(from: hostRoom, source: source)
        #expect(await eventually { await viewerRoom.roster[who] != nil })
        await viewerRoom.updateLayout(
            [who: RenderBox(width: 640, height: 360, scale: 1)],
            linkBitrate: 5_000_000
        )

        submit(6, to: source)
        #expect(
            await eventually {
                let stats = await viewerRoom.decryptionStatistics
                return (stats?.objectsRejected ?? 0) + (stats?.objectsAwaitingKey ?? 0) >= 4
            }
        )
        #expect(await viewerRoom.decryptionStatistics?.objectsDecrypted == 0)
        #expect(await viewerRoom.videoStatistics(for: who)?.framesProduced ?? 0 == 0)
    }

    @Test("an optional room carries media in the clear between sessions with no key")
    func optionalPolicyAllowsClear() async throws {
        let relay = LoopbackRelay()
        let hostRoom = try await join("alice", e2ee: .optional, relay: relay)
        let viewerRoom = try await join("bob", e2ee: .optional, relay: relay)
        #expect(await hostRoom.encryptionPolicy == .optional)

        let who = identity("alice")
        let source = FrameRelay(format: CaptureFormat(size: rung.size, frameRate: 30), depth: 16)
        _ = try await broadcast(from: hostRoom, source: source)
        #expect(await eventually { await viewerRoom.roster[who] != nil })
        await viewerRoom.updateLayout(
            [who: RenderBox(width: 640, height: 360, scale: 1)],
            linkBitrate: 5_000_000
        )
        let frames = try #require(await viewerRoom.frames(from: who))

        submit(6, to: source)
        var received = 0
        for await _ in frames {
            received += 1
            if received == 3 { break }
        }
        #expect(received == 3)

        // In the clear on the relay, which is what optional means.
        let object = try #require(await relay.objects(onTrackNamed: "video/360p").first)
        #expect(Set(object.payload.dropFirst(4)).count == 1)
    }

    @Test("a policy tightened mid-call stops a publication going out in the clear")
    func tighteningStopsClearPublication() async throws {
        let relay = LoopbackRelay()
        let room = try await join("alice", e2ee: .optional, relay: relay)
        let me = identity("alice")
        let told = Task {
            for await event in room.events {
                if case let .encryptionRequired(who) = event, who == me { return true }
            }
            return false
        }

        let source = FrameRelay(format: CaptureFormat(size: rung.size, frameRate: 30), depth: 16)
        _ = try await broadcast(from: room, source: source)

        await room.applyEncryptionPolicy(.required)
        #expect(await room.encryptionPolicy == .required)
        #expect(await told.value)

        // And the next attempt is refused rather than quietly resumed.
        await #expect {
            try await broadcast(from: room, source: source)
        } throws: { error in
            guard case MoqomError.encryptionRequired = error else { return false }
            return true
        }
    }
}
