import Foundation
import Testing

@testable import MoqomCore
@testable import MoqomKit

/// What end-to-end encryption actually costs, measured rather than asserted.
///
/// The question this exists to answer is whether turning encryption on makes a
/// call laggier, and the honest answer has two halves that point in opposite
/// directions. The cipher is free — hardware AES-GCM runs at gigabytes a second
/// and a frame is kilobytes — but there is a fixed per-object cost that has
/// nothing to do with the cipher, and a fixed per-object *byte* cost that is
/// almost invisible on video and substantial on audio.
///
/// Timings print rather than assert, because a number that fails on a loaded CI
/// runner teaches people to ignore the suite. The assertions here are the two
/// things that are genuinely deterministic: the byte overhead, and a ceiling
/// loose enough that only a structural regression trips it.
@Suite("Encryption cost", .serialized)
struct EncryptionCostTests {
    private func measure(_ iterations: Int, _ body: () throws -> Void) rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0 ..< iterations { try body() }
        let end = DispatchTime.now().uptimeNanoseconds
        return Double(end - start) / Double(iterations)
    }

    @Test("sealing and opening an object, at the sizes that actually occur")
    func costPerObject() throws {
        let encryption = RoomEncryption.sharedKey(Data(repeating: 0x11, count: 32), keyID: 1)
        let metadata = SFrameMetadata.encode(
            group: 42,
            object: 7,
            priority: 64,
            properties: ObjectProperties(
                captureTime: FrameTimestamp(nanoseconds: 1),
                temporalLayer: 0
            )
        )

        let sizes = [
            ("opus 20ms", 60),
            ("video delta", 2_048),
            ("720p key", 40_000),
            ("1080p key", 200_000),
        ]

        for (label, size) in sizes {
            let payload = Data(repeating: 0xAB, count: size)

            // Scaled so the largest payload does not need half a gigabyte of
            // pre-sealed objects to measure.
            let iterations = max(100, min(2_000, 20_000_000 / size))

            _ = try measure(100) { _ = try encryption.sender.protect(payload, metadata: metadata) }
            let seal = try measure(iterations) {
                _ = try encryption.sender.protect(payload, metadata: metadata)
            }

            // Each object opened exactly once. The receiver keeps a replay
            // window, so a loop over one sealed object measures the replay
            // rejection path and reads as encryption being far cheaper than it
            // is — which is how this test was wrong the first time.
            var batch: [Data] = []
            batch.reserveCapacity(iterations)
            for _ in 0 ..< iterations {
                batch.append(try encryption.sender.protect(payload, metadata: metadata))
            }
            var index = 0
            let open = try measure(iterations) {
                _ = try encryption.receiver.unprotect(batch[index], metadata: metadata)
                index += 1
            }

            let overhead = batch[0].count - size
            print(
                String(
                    format: "%@ %7d B  seal %7.1f µs  open %7.1f µs  overhead %d B",
                    label.padding(toLength: 12, withPad: " ", startingAt: 0),
                    size,
                    seal / 1000,
                    open / 1000,
                    overhead
                )
            )

            // Three bytes of SFrame header for this key and counter, plus the
            // sixteen-byte GCM tag. Constant per object, which is why it is
            // noise on a keyframe and a third of the packet on Opus.
            #expect(overhead == 19)

            // Two orders of magnitude above what this measures, so it survives a
            // contended runner and still catches the regression that matters:
            // deriving the key per object instead of per key, which is a
            // one-line mistake and roughly a hundredfold slowdown.
            #expect(seal < 1_000_000, "sealing \(size) B took \(seal / 1000) µs")
            #expect(open < 1_000_000, "opening \(size) B took \(open / 1000) µs")
        }
    }

    @Test("reordering is not mistaken for a replay")
    func reorderingSurvives() throws {
        // The receive path decrypts objects in arrival order, and MOQT carries
        // subgroups on separate QUIC streams, so arrival order is not send
        // order. A strict "counter must increase" rule would turn ordinary
        // reordering into dropped media that looks like packet loss.
        let encryption = RoomEncryption.sharedKey(Data(repeating: 0x33, count: 32), keyID: 1)
        let metadata = SFrameMetadata.encode(
            group: 1, object: 1, priority: 64, properties: ObjectProperties()
        )
        let payload = Data(repeating: 0xEE, count: 512)

        var sealed: [Data] = []
        for _ in 0 ..< 64 {
            sealed.append(try encryption.sender.protect(payload, metadata: metadata))
        }

        // Backwards is the worst case a window has to survive, and it is not far
        // off what a burst arriving on several streams at once produces.
        for object in sealed.reversed() {
            #expect(throws: Never.self) {
                try encryption.receiver.unprotect(object, metadata: metadata)
            }
        }

        // And a genuine duplicate is still refused, which is the property the
        // window exists for in the first place.
        #expect(throws: SFrameError.self) {
            try encryption.receiver.unprotect(sealed[0], metadata: metadata)
        }
    }

    @Test("what the actor boundary adds on top of the cipher")
    func actorHop() async throws {
        // Every object crosses into `MediaUnprotector` on the receive path, and
        // an actor hop is not free. Worth knowing separately from the cipher,
        // because it is the part that would scale with participant count if it
        // were large.
        let encryption = RoomEncryption.sharedKey(Data(repeating: 0x22, count: 32), keyID: 1)
        let unprotector = MediaUnprotector(receiver: encryption.receiver)

        let payload = Data(repeating: 0xCD, count: 2_048)
        let metadata = SFrameMetadata.encode(
            group: 1, object: 1, priority: 64, properties: ObjectProperties()
        )

        let warmup = 200
        let iterations = 5_000
        var objects: [TrackObject] = []
        objects.reserveCapacity(warmup + iterations)
        for _ in 0 ..< (warmup + iterations) {
            objects.append(
                TrackObject(
                    group: 1,
                    object: 1,
                    priority: 64,
                    payload: try encryption.sender.protect(payload, metadata: metadata),
                    isKeyFrame: false
                )
            )
        }

        for index in 0 ..< warmup { _ = await unprotector.unprotect(objects[index]) }

        let start = DispatchTime.now().uptimeNanoseconds
        for index in warmup ..< objects.count { _ = await unprotector.unprotect(objects[index]) }
        let end = DispatchTime.now().uptimeNanoseconds

        print(
            String(
                format: "through the actor: %.1f µs per object",
                Double(end - start) / Double(iterations) / 1000
            )
        )

        // Everything decrypted. If the replay window had rejected any of it this
        // would be timing the reject path, which is faster.
        #expect(await unprotector.objectsRejected == 0)
        #expect(await unprotector.objectsDecrypted == objects.count)
    }
}
