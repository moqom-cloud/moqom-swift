// Sender keys: how a viewer in a large broadcast decrypts without being in the
// group.
//
// A room's MLS group holds the devices that may publish, and its agents. A
// viewer — a token with no publish grant — is not added: at broadcast scale
// every commit would carry a ciphertext per viewer and every arrival would be a
// commit. Instead each viewer makes an ML-KEM-1024 key pair when it enters, keeps
// the private half in memory, and posts the public half to the delivery
// service. The group's committer, by the same lowest-leaf rule that decides who
// commits, seals each epoch's SFrame base key to every viewer that lacks it,
// with HPKE over ML-KEM-1024. From the base key and the key ID in a frame the
// viewer derives that publisher's key exactly as a member does (RFC 9605 §5.2),
// so publishers change nothing about how they send.
//
// While the group has an audience the committer rotates the epoch every five
// minutes, and a viewer that has left is not
// sealed the next one. That bounds how long a departed viewer can keep reading
// to one rotation, rather than for as long as the publishers stay.
//
// What a viewer gives up against a member: it cannot see who else holds the
// keys. Members see each other's leaves and confirm it with the epoch
// authenticator; viewers are a list the delivery service hands the committer.
// So a compromised control plane could add a viewer nobody sees — which is the
// same power it has over who it issues a viewing token to, and the reason
// anybody who may publish is a member instead.

import Foundation
import MoqomCore

/// Where a viewer's keys stand.
public struct AudienceKeyStatus: Sendable, Hashable {
    /// The group and epoch whose base key this device holds.
    public let groupID: Data
    public let epoch: UInt64
}

/// The base keys a viewer holds, by the epoch tag a key ID carries. Read by the
/// receiver's resolver from whatever thread is decrypting.
private final class BaseKeys: @unchecked Sendable {
    private let lock = NSLock()
    private var byTag: [UInt64: Data] = [:]

    func key(forTag tag: UInt64) -> Data? { lock.withLock { byTag[tag] } }

    /// Keep `key` for `tag`, and of the rest only `keeping`.
    func set(_ key: Data, tag: UInt64, keeping: UInt64?) {
        lock.withLock {
            byTag = byTag.filter { $0.key == keeping }
            byTag[tag] = key
        }
    }

    func removeAll() { lock.withLock { byTag.removeAll() } }
}

actor AudienceKeys {
    /// How long a request waits on the service for a new epoch key.
    static let pollWait: Duration = .seconds(20)

    nonisolated let identity: String
    nonisolated let encryption: RoomEncryption
    nonisolated let unprotector: MediaUnprotector
    private let delivery: any MLSDeliveryService
    private let token: @Sendable () async -> Data
    private let suite: SFrameCipherSuite
    private let logger: MoqomLogger
    private let sleep: @Sendable (Duration) async -> Void
    private let keyPair: (privateKey: Data, publicKey: Data)
    private let bases = BaseKeys()
    private var current: MLSEpochRef?
    private var loop: Task<Void, Never>?

    init(
        identity: ParticipantIdentity,
        delivery: any MLSDeliveryService,
        token: @escaping @Sendable () async -> Data,
        suite: SFrameCipherSuite = .aes256GcmSha512,
        logger: MoqomLogger = .silent,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) throws(MLSError) {
        self.identity = ManagedRoomKeys.name(of: identity)
        self.delivery = delivery
        self.token = token
        self.suite = suite
        self.logger = logger
        self.sleep = sleep
        keyPair = try MLSAudience.generateKeyPair()
        let receiver = SFrameReceiver()
        // A viewer sends nothing, so its sender never has a key.
        encryption = RoomEncryption(sender: SFrameSender(), receiver: receiver)
        unprotector = MediaUnprotector(receiver: receiver, keyHold: ManagedRoomKeys.keyHold)
        let bases = bases
        receiver.setResolver { keyID in
            bases.key(forTag: MLSSFrameKeys.epochTag(ofKeyID: keyID)).flatMap {
                try? SFrameKey(keyID: keyID, baseKey: $0, suite: suite)
            }
        }
    }

    var status: AudienceKeyStatus? {
        current.map { AudienceKeyStatus(groupID: $0.groupID, epoch: $0.epoch) }
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in await self?.run() }
    }

    func stop(leaving: Bool = true) async {
        loop?.cancel()
        loop = nil
        forget()
        if leaving { try? await delivery.leaveAudience(token: token()) }
    }

    private func run() async {
        var backoff: Duration = .seconds(1)
        while !Task.isCancelled {
            do {
                let envelope = try await delivery.joinAudience(
                    publicKey: keyPair.publicKey, have: current, wait: Self.pollWait, token: token()
                )
                guard !Task.isCancelled else { return }
                if let envelope { install(envelope) }
                backoff = .seconds(1)
            } catch {
                guard !Task.isCancelled else { return }
                logger.warning(.room, "audience key sync failed", [LogField("error", .text("\(error)"))])
                await sleep(backoff)
                backoff = min(backoff * 2, .seconds(30))
            }
        }
    }

    func install(_ envelope: MLSAudienceEnvelope) {
        let base: Data
        do {
            base = try MLSAudience.open(
                envelope.data, privateKey: keyPair.privateKey,
                groupID: envelope.epoch.groupID, epoch: envelope.epoch.epoch
            )
        } catch {
            logger.warning(.room, "could not open an audience key", [LogField("error", .text("\(error)"))])
            return
        }
        guard base.count == suite.keyLength else { return }
        let tag = envelope.epoch.epoch & ((1 << MLSSFrameKeys.epochBits) - 1)
        // The epoch before stays readable for frames in flight across the
        // change. A new group starts its epochs again, so nothing of an old
        // group's is kept.
        let keeping: UInt64? = current.flatMap { previous in
            previous.groupID == envelope.epoch.groupID ? previous.epoch & ((1 << MLSSFrameKeys.epochBits) - 1) : nil
        }
        bases.set(base, tag: tag, keeping: keeping == tag ? nil : keeping)
        // Keys the receiver resolved earlier under a tag now meaning something
        // else, or no longer held, are dropped so the next frame resolves again.
        let receiver = encryption.receiver
        for keyID in receiver.keyIDs {
            let held = MLSSFrameKeys.epochTag(ofKeyID: keyID)
            if held == tag || held != keeping { receiver.remove(keyID: keyID) }
        }
        current = envelope.epoch
        let unprotector = unprotector
        Task { await unprotector.keysChanged() }
        logger.info(.room, "holding the broadcast's keys as a viewer", [
            LogField("epoch", .number(Int(envelope.epoch.epoch))),
        ])
    }

    private func forget() {
        bases.removeAll()
        current = nil
        let receiver = encryption.receiver
        for keyID in receiver.keyIDs { receiver.remove(keyID: keyID) }
    }
}