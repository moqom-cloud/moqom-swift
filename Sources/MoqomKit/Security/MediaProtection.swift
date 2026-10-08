// Putting SFrame on the media path.
//
// The cryptography, and the choice of what an object authenticates as, is
// MoqomSFrame's. What lives here is the MoQ-session side: the decorator that
// seals every object a track writer is given, and the receive path that opens
// them, holds an object briefly for a key still in flight, and counts what it
// drops.
//
// The decorator shape matters. Encryption wraps a ``TrackWriter`` rather than
// living inside the publish path, which means the publish path cannot
// accidentally bypass it: there is no code path from a frame to the wire that
// goes around the wrapper, because the wrapper *is* the writer as far as
// everything upstream is concerned.

import Foundation
import MoqomCore
@_exported import MoqomSFrame
import MoqomWire

extension SFrameTrack {
    /// A full track name as SFrame binds it: the same UTF-8 fields the wire
    /// carries.
    public init(_ track: FullTrackName) {
        self.init(namespace: track.namespace.fields, name: track.name.value)
    }
}

extension SFrameMetadata {
    /// A track object's track, position and properties, as SFrame binds them.
    public init(_ object: TrackObject, on track: FullTrackName) {
        self.init(
            track: track,
            group: object.group,
            object: object.object,
            priority: object.priority,
            properties: object.properties
        )
    }

    public init(
        track: FullTrackName,
        group: UInt64,
        object: UInt64,
        priority: UInt8,
        properties: ObjectProperties
    ) {
        self.init(
            track: SFrameTrack(track),
            group: group,
            object: object,
            priority: priority,
            properties: properties.parameters.items.map {
                switch $0.value {
                case let .integer(value): .integer($0.type, value)
                case let .bytes(value): .bytes($0.type, value)
                }
            }
        )
    }

    /// The canonical bytes an object's track, position and metadata
    /// authenticate as.
    ///
    /// Every field here came off, or is going onto, the wire, so it is always
    /// in range; failing to encode is a bug rather than bad input.
    public static func encode(for object: TrackObject, on track: FullTrackName) -> Data {
        do {
            return try SFrameMetadata(object, on: track).encoded()
        } catch {
            preconditionFailure("object metadata out of wire range")
        }
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
        let metadata = SFrameMetadata(object, on: inner.track)
        let sealed: Data
        do {
            sealed = try sender.protect(object.payload, metadata: metadata)
        } catch SFrameError.noKey {
            // A managed group that has not formed yet. Nobody holds a key that
            // could open this frame, so it is dropped rather than failing the
            // publication: the first commit or Welcome is a round trip away, and
            // ending a broadcast for the length of one would make every join
            // start with an error.
            return
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

    /// How long one object may wait for its key before it is dropped.
    ///
    /// Zero for a key the application supplied, which never changes and so is
    /// never late. Non-zero under managed keys, where a sender moves to a new
    /// epoch the moment its commit is ordered and a receiver a few milliseconds
    /// behind on the same commit would otherwise drop the first frames of every
    /// epoch — a keyframe among them, and with it a second of video.
    ///
    /// The wait happens inline in the participant's pump, so objects behind the
    /// held one queue in their subscription rather than overtaking it: order is
    /// preserved without a reorder buffer.
    let keyHold: Duration

    /// KIDs that have already been waited for once and did not arrive.
    ///
    /// Not waited for again until some key does arrive. A KID that never comes —
    /// a sender in a group this device is not in — would otherwise cost every
    /// one of its objects the full hold and back the pump up behind it.
    private var abandoned: Set<UInt64> = []
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    public init(receiver: SFrameReceiver) {
        self.receiver = receiver
        keyHold = .zero
    }

    init(receiver: SFrameReceiver, keyHold: Duration) {
        self.receiver = receiver
        self.keyHold = keyHold
    }

    /// Keys were added to the receiver; anything waiting for one tries again.
    func keysChanged() {
        abandoned.removeAll()
        let waiting = waiters
        waiters.removeAll()
        for continuation in waiting.values { continuation.resume() }
    }

    /// An object that arrived on `track`, decrypted, or `nil` if it does not
    /// open. One sealed for another track fails authentication.
    public func unprotect(_ object: TrackObject, on track: FullTrackName) async -> TrackObject? {
        let metadata = SFrameMetadata(object, on: track)
        let deadline = ContinuousClock.now.advanced(by: keyHold)
        while true {
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
                let now = ContinuousClock.now
                guard now < deadline, !abandoned.contains(keyID) else {
                    objectsAwaitingKey += 1
                    return nil
                }
                await waitForKeys(until: deadline)
                if ContinuousClock.now >= deadline, !receiver.keyIDs.contains(keyID) {
                    abandoned.insert(keyID)
                }
            } catch {
                objectsRejected += 1
                return nil
            }
        }
    }

    private func waitForKeys(until deadline: ContinuousClock.Instant) async {
        let id = UUID()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters[id] = continuation
            Task { [weak self] in
                try? await Task.sleep(until: deadline, clock: .continuous)
                await self?.release(id)
            }
        }
    }

    private func release(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume()
    }

    /// The same stream of `track`'s objects, decrypted, with undecryptable
    /// objects removed.
    public nonisolated func stream(
        _ objects: AsyncStream<TrackObject>,
        on track: FullTrackName
    ) -> AsyncStream<TrackObject> {
        AsyncStream { continuation in
            let task = Task {
                for await object in objects {
                    if let plain = await self.unprotect(object, on: track) {
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
    ///
    /// Each call sends under a fresh random 64-bit KID, and receives under any
    /// KID by deriving its key from the same base key. A key is fixed by its
    /// base key and KID and every sender counts from 0, so two participants, or
    /// one participant before and after a restart, sending under one KID would
    /// repeat nonces; random KIDs make that a 2⁻⁶⁴ event per pair.
    ///
    /// - Throws: ``SFrameError/invalidBaseKey`` unless `baseKey` is the suite's
    ///   key length.
    public static func sharedKey(
        _ baseKey: Data,
        suite: SFrameCipherSuite = .aes256GcmSha512
    ) throws(SFrameError) -> RoomEncryption {
        let key = try SFrameKey(keyID: .random(in: .min ... .max), baseKey: baseKey, suite: suite)
        let receiver = SFrameReceiver()
        receiver.add(key)
        receiver.setResolver { try? SFrameKey(keyID: $0, baseKey: baseKey, suite: suite) }
        return RoomEncryption(sender: SFrameSender(key: key), receiver: receiver)
    }
}
