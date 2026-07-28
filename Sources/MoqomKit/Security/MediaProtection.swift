// Putting SFrame on the media path.
//
// The interesting decision is what goes in the authenticated metadata, and the
// answer is: everything the relay is allowed to read. Group, object, priority,
// capture time, and temporal layer all stay in the clear so the relay can
// schedule and shed, and all of them are bound into the AEAD tag so it cannot
// change any of them.
//
// That binding is doing real work. Without it a relay could take an object from
// group 5 and re-label it as group 2, and the receiver would decrypt it happily
// and render a frame out of order. It could take a low-priority enhancement
// layer object and present it as a base layer one. Neither attack requires
// breaking any cryptography — they only require that the position not be
// authenticated. So it is.
//
// The decorator shape matters too. Encryption wraps a ``TrackWriter`` rather
// than living inside the publish path, which means the publish path cannot
// accidentally bypass it: there is no code path from a frame to the wire that
// goes around the wrapper, because the wrapper *is* the writer as far as
// everything upstream is concerned.

import Foundation
import MoqomCore
import MoqomWire

/// The canonical bytes an object's position and metadata authenticate as.
///
/// Canonical because both ends must produce identical bytes from the same
/// object or nothing decrypts. Fixed field order, varints throughout, and the
/// same parameter encoding the wire uses — deriving it from the wire encoding
/// rather than inventing a second format is what keeps the two from drifting.
public enum SFrameMetadata {
    public static func encode(
        group: UInt64,
        object: UInt64,
        priority: UInt8,
        properties: ObjectProperties
    ) -> Data {
        var writer = WireWriter(capacity: 32)
        writer.varInt(group)
        writer.varInt(object)
        writer.byte(priority)
        properties.parameters.writeCounted(to: &writer)
        return writer.bytes
    }

    public static func encode(for object: TrackObject) -> Data {
        encode(
            group: object.group,
            object: object.object,
            priority: object.priority,
            properties: object.properties
        )
    }
}

/// A track writer that encrypts everything passing through it.
public final class ProtectedTrackWriter: TrackWriter {
    private let inner: any TrackWriter
    private let sender: SFrameSender

    public init(wrapping writer: any TrackWriter, sender: SFrameSender) {
        inner = writer
        self.sender = sender
    }

    public var track: FullTrackName { inner.track }

    public func startGroup(_ group: UInt64) async throws(MoqomError) {
        try await inner.startGroup(group)
    }

    public func write(_ object: TrackObject) async throws(MoqomError) {
        let metadata = SFrameMetadata.encode(for: object)
        let sealed: Data
        do {
            sealed = try sender.protect(object.payload, metadata: metadata)
        } catch {
            // Publishing plaintext because encryption failed would be the worst
            // possible recovery: the caller asked for end-to-end encryption and
            // would get a stream that silently is not.
            throw MoqomError.encryptionFailed(error)
        }

        try await inner.write(
            TrackObject(
                group: object.group,
                object: object.object,
                priority: object.priority,
                payload: sealed,
                isKeyFrame: object.isKeyFrame,
                properties: object.properties
            )
        )
    }

    public func finish() async {
        await inner.finish()
    }
}

/// Decrypts objects arriving on a subscription.
///
/// Failures drop the object rather than ending the stream. A forged or
/// corrupted frame is a thing that happens on a public network and must not be
/// able to end a call; the counters are surfaced so the condition is visible
/// rather than silent.
public actor MediaUnprotector {
    private let receiver: SFrameReceiver

    public private(set) var objectsDecrypted = 0
    public private(set) var objectsRejected = 0

    /// Objects held because their key has not arrived yet.
    ///
    /// Key distribution and media are separate channels and can race, so a
    /// frame that arrives just before its key is normal rather than an attack.
    public private(set) var objectsAwaitingKey = 0

    public init(receiver: SFrameReceiver) {
        self.receiver = receiver
    }

    public func unprotect(_ object: TrackObject) -> TrackObject? {
        let metadata = SFrameMetadata.encode(for: object)
        do {
            let plaintext = try receiver.unprotect(object.payload, metadata: metadata)
            objectsDecrypted += 1
            return TrackObject(
                group: object.group,
                object: object.object,
                priority: object.priority,
                payload: plaintext,
                isKeyFrame: object.isKeyFrame,
                properties: object.properties
            )
        } catch let SFrameError.unknownKey(keyID) {
            _ = keyID
            objectsAwaitingKey += 1
            return nil
        } catch {
            objectsRejected += 1
            return nil
        }
    }

    /// The same stream, decrypted, with undecryptable objects removed.
    public nonisolated func stream(
        _ objects: AsyncStream<TrackObject>
    ) -> AsyncStream<TrackObject> {
        AsyncStream { continuation in
            let task = Task {
                for await object in objects {
                    if let plain = await self.unprotect(object) {
                        continuation.yield(plain)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// End-to-end encryption for a room.
///
/// Both halves are needed together in practice — a participant both sends and
/// receives — but they are separate objects because the key material is
/// different: one key of your own to send under, and everyone else's to receive
/// with.
public struct RoomEncryption: Sendable {
    public let sender: SFrameSender
    public let receiver: SFrameReceiver

    public init(sender: SFrameSender, receiver: SFrameReceiver) {
        self.sender = sender
        self.receiver = receiver
    }

    /// A room where every participant shares one base key.
    ///
    /// The simplest thing that is genuinely end to end, and it is honest about
    /// its limit: a shared key means any member can impersonate any other, and
    /// removing a member requires rekeying everyone. That is fine for a small
    /// trusted call and wrong for a large room, which is what the MLS path in
    /// RFC 9605 §5.2 exists for.
    public static func sharedKey(
        _ baseKey: Data,
        keyID: UInt64,
        suite: SFrameCipherSuite = .aes256GcmSha512
    ) -> RoomEncryption {
        let key = SFrameKey(keyID: keyID, baseKey: baseKey, suite: suite)
        let receiver = SFrameReceiver()
        receiver.add(key)
        return RoomEncryption(sender: SFrameSender(key: key), receiver: receiver)
    }
}
