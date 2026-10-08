// SFrame on the MoQ media path.
//
// The SFrame implementation itself, and RFC 9605's vectors, are tested in
// MoqomSFrame. What is tested here is the session glue: that every object is
// sealed on the way out, opened on the way in, and bound to its track and
// position.

import Foundation
import MoqomSFrame
import Testing

@testable import MoqomCore
@testable import MoqomKit
@testable import MoqomLoopback
@testable import MoqomWire

@Suite("SFrame metadata")
struct SFrameMetadataTests {
    @Test("an object binds the same bytes as its wire encoding")
    func matchesTheWire() throws {
        // The canonical form is defined as the MOQT encoding of the same fields,
        // so a receiver on another stack derives it from what it parsed.
        let track = TrackObjectFixture.track
        let objects = [
            TrackObject(group: 0, object: 0, payload: Data()),
            TrackObject(
                group: 5,
                object: 2,
                priority: 64,
                payload: Data(),
                properties: ObjectProperties(captureTime: FrameTimestamp(nanoseconds: 1_000_000_000), temporalLayer: 1)
            ),
            TrackObject(
                group: 70000,
                object: 16384,
                priority: 255,
                payload: Data(),
                properties: ObjectProperties(
                    captureTime: FrameTimestamp(nanoseconds: 33_366_000),
                    configuration: Data(repeating: 0x42, count: 300),
                    isSilence: true
                )
            ),
        ]
        for object in objects {
            var writer = WireWriter(capacity: 32)
            track.write(to: &writer)
            writer.varInt(object.group)
            writer.varInt(object.object)
            writer.byte(object.priority)
            object.properties.parameters.writeCounted(to: &writer)
            #expect(SFrameMetadata.encode(for: object, on: track) == writer.bytes)
            #expect(try SFrameMetadata(object, on: track).encoded() == writer.bytes)
        }
    }
}

@Suite("Encrypted media path")
struct EncryptedMediaTests {
    @Test("the relay never sees plaintext, and the receiver does")
    func relaySeesOnlyCiphertext() async throws {
        let relay = LoopbackRelay()
        // No e2ee claim, which is the default a room is in: required.
        let session = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: credentials("alice", e2ee: nil),
            tenant: "acme"
        )
        try await session.connect(to: RelayEndpoint(host: "loopback"))
        let room = try await session.join(room: "room-42")

        let encryption = try RoomEncryption.sharedKey(Data(repeating: 0x5A, count: 32))
        await room.useEncryption(encryption)

        let source = FrameRelay(
            format: CaptureFormat(size: PixelSize(width: 640, height: 360), frameRate: 30),
            depth: 16
        )
        let broadcast = try await room.startBroadcast(
            from: source,
            configuration: BroadcastConfiguration(
                ladder: LayerLadder(rungs: [
                    VideoLayer(
                        id: "video/360p",
                        size: PixelSize(width: 640, height: 360),
                        frameRate: 30,
                        bitrate: 600_000
                    ),
                ]),
                encoderFactory: { SyntheticEncoder(configuration: $0) }
            )
        )

        source.submit(
            VideoFrame(
                timestamp: FrameTimestamp(nanoseconds: 0),
                size: PixelSize(width: 640, height: 360),
                surface: .synthetic(byteCount: 1024),
                forcesKeyFrame: true
            )
        )
        #expect(await eventually { await broadcast.stats.objectsPublished == 1 })

        let objects = await relay.objects(onTrackNamed: "video/360p")
        let sealed = try #require(objects.first)

        // The synthetic encoder fills its output with one repeated byte. If any
        // of that pattern survived to the relay, the payload was not encrypted.
        let counts = Set(sealed.payload.dropFirst(8))
        #expect(counts.count > 32)

        // Scheduling metadata is still in the clear, which is the whole point:
        // the relay can prioritise and shed without being able to read a frame.
        #expect(sealed.group == 0)
        #expect(sealed.isKeyFrame)
        #expect(sealed.properties.captureTime?.nanoseconds == 0)

        let unprotector = MediaUnprotector(receiver: encryption.receiver)
        let track = try FullTrackName(
            namespace: MoqomNamespaces.participant(tenant: "acme", room: "room-42", identity: identity("alice")),
            name: TrackName("video/360p")
        )
        let plain = try #require(await unprotector.unprotect(sealed, on: track))
        #expect(plain.payload.count > 10_000)
        #expect(Set(plain.payload.dropFirst(4)).count == 1)
    }

    @Test("an object moved to another group by the relay fails to decrypt")
    func positionIsAuthenticated() async throws {
        // This is why the metadata is in the AAD. Relabelling an object costs
        // an attacker nothing and breaks no cryptography — unless the position
        // is bound into the tag, which it is.
        let encryption = try RoomEncryption.sharedKey(Data(repeating: 0x11, count: 32))
        let unprotector = MediaUnprotector(receiver: encryption.receiver)
        let track = TrackObjectFixture.track

        let original = TrackObject(
            group: 5,
            object: 2,
            priority: 64,
            payload: Data(repeating: 0xEE, count: 128),
            properties: ObjectProperties(captureTime: FrameTimestamp(nanoseconds: 1000))
        )
        let sealed = try encryption.sender.protect(
            original.payload,
            metadata: SFrameMetadata(original, on: track)
        )

        let honest = TrackObject(
            group: 5, object: 2, priority: 64, payload: sealed, properties: original.properties
        )
        #expect(await unprotector.unprotect(honest, on: track)?.payload == original.payload)

        for tampered in [
            TrackObject(
                group: 2, object: 2, priority: 64, payload: sealed, properties: original.properties
            ),
            TrackObject(
                group: 5, object: 9, priority: 64, payload: sealed, properties: original.properties
            ),
            TrackObject(
                group: 5, object: 2, priority: 200, payload: sealed, properties: original.properties
            ),
            TrackObject(
                group: 5,
                object: 2,
                priority: 64,
                payload: sealed,
                properties: ObjectProperties(captureTime: FrameTimestamp(nanoseconds: 2000))
            ),
        ] {
            #expect(await unprotector.unprotect(tampered, on: track) == nil)
        }
        #expect(await unprotector.objectsRejected == 4)
    }

    @Test("an object moved to another track by the relay fails to decrypt")
    func trackIsAuthenticated() async throws {
        // Two of one participant's layers, or the same layer of two
        // participants sharing a key, carry objects at the same positions. A
        // relay forwarding one track's object as the other's must not get it
        // past the tag.
        let encryption = try RoomEncryption.sharedKey(Data(repeating: 0x11, count: 32))
        let unprotector = MediaUnprotector(receiver: encryption.receiver)
        let alice = TrackObjectFixture.track
        let others = try [
            FullTrackName(namespace: alice.namespace, name: TrackName("video/180p")),
            FullTrackName(namespace: TrackNamespace(["moqom", "room", "bob"]), name: alice.name),
        ]

        let object = TrackObject(group: 5, object: 2, payload: Data(repeating: 0xEE, count: 64))
        let sealed = TrackObject(
            group: 5,
            object: 2,
            payload: try encryption.sender.protect(object.payload, metadata: SFrameMetadata(object, on: alice))
        )
        for other in others {
            #expect(await unprotector.unprotect(sealed, on: other) == nil)
        }
        #expect(await unprotector.unprotect(sealed, on: alice)?.payload == object.payload)
        #expect(await unprotector.objectsRejected == 2)
    }

    @Test("participants sharing a key send under different key IDs, and open each other")
    func sharedKeySendersDiffer() async throws {
        // Every sender counts from 0, so two senders under one key ID would
        // seal with the same nonces.
        let base = Data(repeating: 0x5A, count: 32)
        let alice = try RoomEncryption.sharedKey(base)
        let bob = try RoomEncryption.sharedKey(base)
        let aliceKey = try #require(alice.sender.key?.keyID)
        let bobKey = try #require(bob.sender.key?.keyID)
        #expect(aliceKey != bobKey)

        let object = TrackObject(group: 0, object: 0, payload: Data("hi".utf8))
        let track = TrackObjectFixture.track
        let sealed = try alice.sender.protect(object.payload, metadata: SFrameMetadata(object, on: track))
        let opened = await MediaUnprotector(receiver: bob.receiver)
            .unprotect(TrackObject(group: 0, object: 0, payload: sealed), on: track)
        #expect(opened?.payload == object.payload)

        #expect(throws: SFrameError.invalidBaseKey) { _ = try RoomEncryption.sharedKey(Data(count: 16)) }
    }

    @Test("a participant without the key gets nothing, and is not told why")
    func withoutTheKeyThereIsNoMedia() async throws {
        let encryption = try RoomEncryption.sharedKey(Data(repeating: 0x22, count: 32))
        let outsider = MediaUnprotector(receiver: SFrameReceiver())
        let track = TrackObjectFixture.track

        let object = TrackObject(group: 0, object: 0, payload: Data([0x01, 0x02, 0x03]))
        let sealed = try encryption.sender.protect(
            object.payload, metadata: SFrameMetadata(object, on: track)
        )
        let onTheWire = TrackObject(group: 0, object: 0, payload: sealed)

        #expect(await outsider.unprotect(onTheWire, on: track) == nil)
        #expect(await outsider.objectsAwaitingKey == 1)
        #expect(await outsider.objectsRejected == 0)
    }
}
