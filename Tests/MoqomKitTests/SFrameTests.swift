// SFrame, checked against RFC 9605's own test vectors.
//
// The vectors are the point of this file. A round-trip test only proves we can
// read what we wrote, which is exactly what a subtly wrong key derivation also
// passes — and a subtly wrong key derivation is invisible until the day
// something that is not us tries to decrypt our media.

import CryptoKit
import Foundation
import Testing

@testable import MoqomCore
@testable import MoqomKit
@testable import MoqomLoopback

private func hex(_ string: String) -> Data {
    var bytes = Data()
    var index = string.startIndex
    while index < string.endIndex {
        let next = string.index(index, offsetBy: 2)
        bytes.append(UInt8(string[index ..< next], radix: 16)!)
        index = next
    }
    return bytes
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

@Suite("SFrame header")
struct SFrameHeaderTests {
    @Test("small values ride inside the config byte")
    func compactForm() throws {
        // One byte total. This is the case that matters for audio, where the
        // payload is sixty bytes and a five-byte header would be eight percent
        // of the packet.
        let header = SFrameHeader(keyID: 3, counter: 5)
        #expect(header.encoded == Data([0x35]))

        let (parsed, length) = try SFrameHeader.read(from: header.encoded)
        #expect(parsed == header)
        #expect(length == 1)
    }

    @Test("the RFC's example header encodes to the RFC's bytes")
    func rfcHeader() throws {
        // KID 0x123 and CTR 0x4567 both need two bytes, so both extension flags
        // are set and both length fields read one, meaning two bytes.
        let header = SFrameHeader(keyID: 0x0123, counter: 0x4567)
        #expect(header.encoded == hex("990123456 7".replacingOccurrences(of: " ", with: "")))

        let (parsed, length) = try SFrameHeader.read(from: header.encoded)
        #expect(parsed == header)
        #expect(length == 5)
    }

    @Test("each combination of extension flags round-trips")
    func allFourForms() throws {
        let cases = [
            SFrameHeader(keyID: 0, counter: 0),
            SFrameHeader(keyID: 7, counter: 7),
            SFrameHeader(keyID: 7, counter: 8),
            SFrameHeader(keyID: 8, counter: 7),
            SFrameHeader(keyID: 0xDEAD_BEEF, counter: UInt64.max),
        ]
        for header in cases {
            let (parsed, length) = try SFrameHeader.read(from: header.encoded)
            #expect(parsed == header)
            #expect(length == header.encoded.count)
        }
    }

    @Test("a truncated header is refused rather than read past its end")
    func truncatedHeader() {
        // Claims a four-byte KID and supplies one.
        #expect(throws: SFrameError.malformedHeader) {
            _ = try SFrameHeader.read(from: Data([0xB8, 0x01]))
        }
        #expect(throws: SFrameError.malformedHeader) {
            _ = try SFrameHeader.read(from: Data())
        }
    }
}

@Suite("SFrame vectors")
struct SFrameVectorTests {
    private let baseKey = hex("000102030405060708090a0b0c0d0e0f")
    private let keyID: UInt64 = 0x0123
    private let counter: UInt64 = 0x4567
    private let metadata = hex("4945544620534672616d65205747")
    private let plaintext = hex("64726166742d696574662d736672616d652d656e63")

    @Test("AES-128-GCM-SHA256 matches RFC 9605 Appendix C.3")
    func suite0004() throws {
        let key = SFrameKey(keyID: keyID, baseKey: baseKey, suite: .aes128GcmSha256)
        #expect(key.key.withUnsafeBytes { Data($0) }.hexString == "d34f547f4ca4f9a7447006fe7fcbf768")
        #expect(key.salt.hexString == "75234edefe07819026751816")
        #expect(key.nonce(counter: counter).hexString == "75234edefe07819026755d71")

        let header = SFrameHeader(keyID: keyID, counter: counter).encoded
        let ciphertext = try key.seal(plaintext, counter: counter, aad: header + metadata)
        #expect(
            (header + ciphertext).hexString
                == "9901234567b7412c2513a1b66dbb48841bbaf17f598751176ad847681a69c6d0b091c07018ce4adb34eb"
        )
    }

    @Test("AES-256-GCM-SHA512 matches RFC 9605 Appendix C.3")
    func suite0005() throws {
        let key = SFrameKey(keyID: keyID, baseKey: baseKey, suite: .aes256GcmSha512)
        #expect(
            key.key.withUnsafeBytes { Data($0) }.hexString
                == "d3e27b0d4a5ae9e55df01a70e6d4d28d969b246e2936f4b7a5d9b494da6b9633"
        )
        #expect(key.salt.hexString == "84991c167b8cd23c93708ec7")
        #expect(key.nonce(counter: counter).hexString == "84991c167b8cd23c9370cba0")

        let header = SFrameHeader(keyID: keyID, counter: counter).encoded
        let ciphertext = try key.seal(plaintext, counter: counter, aad: header + metadata)
        #expect(
            (header + ciphertext).hexString
                == "990123456794f509d36e9beacb0e261d99c7d1e972f1fed787d4049f17ca21353c1cc24d56ceabced279"
        )
    }

    @Test("the RFC's ciphertext decrypts back to the RFC's plaintext")
    func decryptsTheVector() throws {
        let receiver = SFrameReceiver()
        receiver.add(SFrameKey(keyID: keyID, baseKey: baseKey, suite: .aes256GcmSha512))
        let ciphertext = hex(
            "990123456794f509d36e9beacb0e261d99c7d1e972f1fed787d4049f17ca21353c1cc24d56ceabced279"
        )
        #expect(try receiver.unprotect(ciphertext, metadata: metadata) == plaintext)
    }
}

@Suite("SFrame protection")
struct SFrameProtectionTests {
    private func pair(
        keyID: UInt64 = 1,
        suite: SFrameCipherSuite = .aes256GcmSha512
    ) -> (SFrameSender, SFrameReceiver) {
        let key = SFrameKey(keyID: keyID, baseKey: Data(repeating: 0x2A, count: 32), suite: suite)
        let receiver = SFrameReceiver()
        receiver.add(key)
        return (SFrameSender(key: key), receiver)
    }

    @Test("a protected frame comes back exactly")
    func roundTrip() throws {
        let (sender, receiver) = pair()
        let payload = Data((0 ..< 4096).map { UInt8($0 & 0xFF) })
        let sealed = try sender.protect(payload, metadata: Data([0x01, 0x02]))
        #expect(sealed != payload)
        #expect(try receiver.unprotect(sealed, metadata: Data([0x01, 0x02])) == payload)
    }

    @Test("every frame gets its own counter")
    func countersNeverRepeat() throws {
        // A repeated GCM nonce does not weaken the ciphertext, it breaks it:
        // two frames under one nonce leak their XOR and the authentication
        // subkey. This is why the counter is not something a caller can supply.
        let (sender, receiver) = pair()
        var counters: Set<UInt64> = []
        for index in 0 ..< 200 {
            let sealed = try sender.protect(Data([UInt8(index & 0xFF)]))
            let (header, _) = try SFrameHeader.read(from: sealed)
            counters.insert(header.counter)
            _ = try receiver.unprotect(sealed)
        }
        #expect(counters.count == 200)
        #expect(sender.issuedCounters == 200)
    }

    @Test("altered metadata fails authentication even though it is not encrypted")
    func metadataIsAuthenticated() throws {
        // This is the property that lets a relay read the scheduling metadata:
        // it can see group, object, and timing, and it cannot change any of
        // them without the receiver noticing.
        let (sender, receiver) = pair()
        let sealed = try sender.protect(Data([0xAB]), metadata: Data([0x00, 0x0A]))
        #expect(throws: SFrameError.authenticationFailure) {
            _ = try receiver.unprotect(sealed, metadata: Data([0x00, 0x0B]))
        }
    }

    @Test("a flipped bit anywhere in the ciphertext fails")
    func tamperingFails() throws {
        let (sender, receiver) = pair()
        let sealed = try sender.protect(Data(repeating: 0x11, count: 64))
        for index in 1 ..< sealed.count {
            var damaged = sealed
            damaged[damaged.startIndex + index] ^= 0x01
            #expect(throws: SFrameError.self) {
                _ = try receiver.unprotect(damaged)
            }
        }
    }

    @Test("a replayed frame is rejected the second time")
    func replayIsRejected() throws {
        let (sender, receiver) = pair()
        let sealed = try sender.protect(Data([0x01]))
        _ = try receiver.unprotect(sealed)
        #expect(throws: SFrameError.self) {
            _ = try receiver.unprotect(sealed)
        }
    }

    @Test("reordering within the window is accepted, because networks reorder")
    func reorderingIsFine() throws {
        let (sender, receiver) = pair()
        let frames = try (0 ..< 8).map { try sender.protect(Data([UInt8($0)])) }
        for index in [3, 1, 0, 7, 2, 6, 4, 5] {
            #expect(try receiver.unprotect(frames[index]) == Data([UInt8(index)]))
        }
    }

    @Test("a frame for a key we do not have says so, rather than failing opaquely")
    func unknownKeyIsDistinguishable() throws {
        // Distinguishable *to us*: key distribution and media are separate
        // channels and can race, so the caller is allowed to buffer and retry.
        // An authentication failure is never recoverable and must not be
        // treated the same way.
        let key = SFrameKey(keyID: 9, baseKey: Data(repeating: 0x01, count: 32))
        let sender = SFrameSender(key: key)
        let sealed = try sender.protect(Data([0x01]))

        let receiver = SFrameReceiver()
        #expect(throws: SFrameError.unknownKey(9)) {
            _ = try receiver.unprotect(sealed)
        }

        receiver.add(key)
        #expect(try receiver.unprotect(sealed) == Data([0x01]))
    }

    @Test("removing a key stops anything still in flight under it")
    func removingAKeyRevokes() throws {
        let (sender, receiver) = pair(keyID: 4)
        let sealed = try sender.protect(Data([0x01]))
        receiver.remove(keyID: 4)
        #expect(throws: SFrameError.unknownKey(4)) {
            _ = try receiver.unprotect(sealed)
        }
    }

    @Test("both suites work end to end")
    func bothSuites() throws {
        for suite in SFrameCipherSuite.allCases {
            let (sender, receiver) = pair(suite: suite)
            let sealed = try sender.protect(Data([0xFE, 0xED]))
            #expect(try receiver.unprotect(sealed) == Data([0xFE, 0xED]))
        }
    }
}

@Suite("Encrypted media path")
struct EncryptedMediaTests {
    @Test("the relay never sees plaintext, and the receiver does")
    func relaySeesOnlyCiphertext() async throws {
        let relay = LoopbackRelay()
        let session = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: credentials("alice"),
            tenant: "acme"
        )
        try await session.connect(to: RelayEndpoint(host: "loopback"))
        let room = try await session.join(room: "room-42")

        let encryption = RoomEncryption.sharedKey(
            Data(repeating: 0x5A, count: 32), keyID: 1
        )
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
        let plain = try #require(await unprotector.unprotect(sealed))
        #expect(plain.payload.count > 10_000)
        #expect(Set(plain.payload.dropFirst(4)).count == 1)
    }

    @Test("an object moved to another group by the relay fails to decrypt")
    func positionIsAuthenticated() async throws {
        // This is why the metadata is in the AAD. Relabelling an object costs
        // an attacker nothing and breaks no cryptography — unless the position
        // is bound into the tag, which it is.
        let encryption = RoomEncryption.sharedKey(Data(repeating: 0x11, count: 32), keyID: 2)
        let unprotector = MediaUnprotector(receiver: encryption.receiver)

        let original = TrackObject(
            group: 5,
            object: 2,
            priority: 64,
            payload: Data(repeating: 0xEE, count: 128),
            properties: ObjectProperties(captureTime: FrameTimestamp(nanoseconds: 1000))
        )
        let sealed = try encryption.sender.protect(
            original.payload,
            metadata: SFrameMetadata.encode(for: original)
        )

        let honest = TrackObject(
            group: 5, object: 2, priority: 64, payload: sealed, properties: original.properties
        )
        #expect(await unprotector.unprotect(honest)?.payload == original.payload)

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
            #expect(await unprotector.unprotect(tampered) == nil)
        }
        #expect(await unprotector.objectsRejected == 4)
    }

    @Test("a participant without the key gets nothing, and is not told why")
    func withoutTheKeyThereIsNoMedia() async throws {
        let encryption = RoomEncryption.sharedKey(Data(repeating: 0x22, count: 32), keyID: 3)
        let outsider = MediaUnprotector(receiver: SFrameReceiver())

        let object = TrackObject(group: 0, object: 0, payload: Data([0x01, 0x02, 0x03]))
        let sealed = try encryption.sender.protect(
            object.payload, metadata: SFrameMetadata.encode(for: object)
        )
        let onTheWire = TrackObject(group: 0, object: 0, payload: sealed)

        #expect(await outsider.unprotect(onTheWire) == nil)
        #expect(await outsider.objectsAwaitingKey == 1)
        #expect(await outsider.objectsRejected == 0)
    }
}

@Suite("Replay window")
struct ReplayWindowTests {
    @Test("anything ahead of the window is new")
    func forwardIsAlwaysNew() {
        var window = ReplayWindow(size: 64)
        #expect(window.accepts(0))
        window.record(0)
        #expect(!window.accepts(0))
        #expect(window.accepts(1))
        #expect(window.accepts(1_000_000))
    }

    @Test("a counter older than the window is refused")
    func tooOldIsRefused() {
        // The window is what bounds how much reordering is tolerated. Past it,
        // there is no way to tell a very late frame from a replayed one, and
        // the safe answer is to refuse.
        var window = ReplayWindow(size: 8)
        window.record(100)
        #expect(window.accepts(95))
        #expect(!window.accepts(90))
    }

    @Test("a jump forward clears the old bits rather than keeping stale state")
    func largeJumpResetsTheBitmap() {
        var window = ReplayWindow(size: 64)
        window.record(1)
        window.record(500)
        #expect(window.accepts(499))
        #expect(!window.accepts(500))
    }
}
