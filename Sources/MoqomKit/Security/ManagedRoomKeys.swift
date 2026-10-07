// MLS-managed SFrame keys for one room, so an application never handles a key.
//
// # Who commits
//
// Somebody has to turn "a device is waiting to be added" and "a member has
// gone" into a commit, and two members doing it at once is harmless but
// wasteful: the delivery service orders one and refuses the other as stale.
// The rule is the lowest leaf index among members the service has heard from
// recently. It is deterministic — every member computes the same answer from
// the same snapshot without talking to anybody — and it is self-healing: a
// committer that crashes stops syncing, drops out of the service's list of
// members it has heard from, and the next lowest takes over with no election.
// A committer that is alive but wedged is covered by a fallback: the member at
// rank r also commits once the same work has been outstanding for r steps.
//
// External commits — the joiner adding itself — were the alternative. They
// need no online member, which matters for a group nobody is in, and that case
// does not arise here: a room with nobody online has its group dropped, and the
// next device to arrive founds a new one. Against that they need the service to
// hold a current GroupInfo and the external-init HPKE path, which is more MLS
// for no case MOQOM has.
//
// # Epochs and media
//
// A sender moves to the new epoch's key the moment its group does — its own
// commit accepted, or somebody else's processed — so a removed member's last
// key stops being used as soon as the removal is ordered. Receivers install the
// new epoch's keys at the same moment and keep the previous epoch's for a few
// seconds, for frames that were in flight when the sender switched. The
// opposite race, a frame under the new epoch reaching a receiver that has not
// processed the commit yet, is absorbed by the unprotector holding that frame
// until the key arrives; see ``MediaUnprotector/keyHold``. Neither direction
// drops a frame across an ordinary epoch change.
//
// # Cipher suites
//
// A device founds in its own suite, the hybrid one unless it was built to do
// otherwise, and joins in whichever suite the room's group is in. It publishes
// key packages in its own suite before it knows; when a snapshot shows a group
// in another suite it implements, it replaces them with packages in that one,
// and is added on the committer's next pass. A group in a suite this build
// does not implement cannot be joined, and the device waits for it to be
// dropped rather than asking to be added.

import Foundation
import MoqomCore

/// Where a room's managed group stands.
public struct GroupKeyStatus: Sendable, Hashable {
    /// The MLS epoch media is currently sent under.
    public let epoch: UInt64

    /// The suite the group was founded in.
    public let cipherSuite: MLSCipherSuite

    /// Every device in the group, as `username/device`.
    public let members: [String]

    /// Equal on every member's device for the same epoch. Two people who read
    /// the same value to each other know that nobody is in the group that one
    /// of them cannot see — including anybody a compromised server added.
    public let epochAuthenticator: Data

    /// The key direct-path candidate offers are sealed under for this epoch.
    ///
    /// Exported rather than taken from ``epochAuthenticator``, which is meant
    /// to be read aloud and so is not a secret.
    let directOfferSecret: Data
}

actor ManagedRoomKeys {
    /// How long a sync waits on the service for something to happen.
    static let pollWait: Duration = .seconds(10)

    /// The least time between two syncs that brought nothing, so a member
    /// watching work another member is about to do does not spin on it.
    static let idleGap: Duration = .milliseconds(300)

    /// How long the previous epoch's keys stay loaded after a change.
    static let retention: Duration = .seconds(5)

    /// How long an object may wait for its epoch's key.
    static let keyHold: Duration = .milliseconds(750)

    /// How long outstanding work waits per rank before a non-lowest member does it.
    static let fallbackStep: Duration = .seconds(3)

    /// One-time key packages uploaded alongside the last-resort one.
    static let oneTimePackages = 2

    nonisolated let identity: String
    nonisolated let encryption: RoomEncryption
    nonisolated let unprotector: MediaUnprotector
    private let delivery: any MLSDeliveryService
    private let token: @Sendable () async -> Data
    private let suite: SFrameCipherSuite
    private let foundingSuite: MLSCipherSuite
    private let logger: MoqomLogger
    private let sleep: @Sendable (Duration) async -> Void

    private var bundles: [Data: MLSKeyPackageBundle] = [:]
    private var lastResort: Data?
    /// The suite of the key packages in ``bundles``.
    private var packageSuite: MLSCipherSuite
    /// A group suite already reported as not implemented, so it is said once.
    private var refusedSuite: UInt16?
    private var group: MLSGroup?
    private var cursor: UInt64 = 0
    private var currentKeys: Set<UInt64> = []
    private var previousKeys: Set<UInt64> = []
    private var retiring: Task<Void, Never>?
    private var workSince: ContinuousClock.Instant?
    private var loop: Task<Void, Never>?

    init(
        identity: ParticipantIdentity,
        delivery: any MLSDeliveryService,
        token: @escaping @Sendable () async -> Data,
        suite: SFrameCipherSuite = .aes256GcmSha512,
        cipherSuite: MLSCipherSuite = .default,
        logger: MoqomLogger = .silent,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.identity = Self.name(of: identity)
        self.delivery = delivery
        self.token = token
        self.suite = suite
        foundingSuite = cipherSuite
        packageSuite = cipherSuite
        self.logger = logger
        self.sleep = sleep
        let receiver = SFrameReceiver()
        encryption = RoomEncryption(sender: SFrameSender(), receiver: receiver)
        unprotector = MediaUnprotector(receiver: receiver, keyHold: Self.keyHold)
    }

    /// The identity a device has inside the group, matching the control plane's
    /// `username/device`.
    static func name(of identity: ParticipantIdentity) -> String {
        "\(identity.username.value)/\(identity.device.value)"
    }

    var status: GroupKeyStatus? {
        guard let group else { return nil }
        return GroupKeyStatus(
            epoch: group.epoch,
            cipherSuite: group.cipherSuite,
            members: group.roster.map(\.member.identityString),
            epochAuthenticator: group.epochAuthenticator,
            directOfferSecret: group.export(label: "MOQOM direct offer", length: 32)
        )
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in await self?.run() }
    }

    /// - Parameter leaving: tell the service, so the next commit removes this
    ///   device at once. `false` is a process dying, for tests.
    func stop(leaving: Bool = true) async {
        loop?.cancel()
        loop = nil
        retiring?.cancel()
        retiring = nil
        forget()
        // Best effort. A member that could not say it was leaving is removed
        // anyway once the service stops hearing from it; this only makes that
        // prompt.
        if leaving { try? await delivery.leave(token: token()) }
    }

    // MARK: - The loop

    private func run() async {
        var backoff: Duration = .seconds(1)
        while !Task.isCancelled {
            do {
                if bundles.isEmpty { try await publishPackages(in: packageSuite) }
                let snapshot = try await delivery.sync(
                    after: cursor, wait: Self.pollWait, token: token()
                )
                guard !Task.isCancelled else { return }
                try await apply(snapshot)
                backoff = .seconds(1)
                if snapshot.messages.isEmpty { await sleep(Self.idleGap) }
            } catch {
                guard !Task.isCancelled else { return }
                logger.warning(.room, "group key sync failed", [LogField("error", .text("\(error)"))])
                await sleep(backoff)
                backoff = min(backoff * 2, .seconds(30))
            }
        }
    }

    func apply(_ snapshot: MLSDeliverySnapshot) async throws {
        if snapshot.cursor < cursor {
            // The service's log is behind where this device has read to, which
            // only happens when it lost its state. Read it again from the start.
            cursor = 0
            if group != nil { try await requestRejoin() }
            return
        }
        guard let current = snapshot.group else {
            // Nobody has a group here, or the one there was has been dropped
            // because nobody in it was left. Found one.
            if group != nil { forget() }
            try await found()
            return
        }
        if let group, group.groupID != current.id {
            // The room's group was dropped and founded again while this device
            // was away. Nothing it holds applies.
            forget()
            try await requestRejoin()
            return
        }

        for message in snapshot.messages {
            cursor = max(cursor, message.sequence)
            switch message.kind {
            case .welcome:
                guard group == nil else { continue }
                accept(welcome: message.data)
            case .commit:
                guard group != nil else { continue }
                let following = try await follow(commit: message.data)
                if !following { return }
            }
        }
        cursor = max(cursor, snapshot.cursor)

        guard let group else {
            guard let roomSuite = MLSCipherSuite(identifier: current.cipherSuite) else {
                if refusedSuite != current.cipherSuite {
                    refusedSuite = current.cipherSuite
                    logger.warning(.room, "the room's encryption group uses a cipher suite this build does not implement", [
                        LogField("suite", .number(Int(current.cipherSuite))),
                    ])
                }
                return
            }
            if roomSuite != packageSuite {
                // Packages in another suite can never be added to this group.
                // Replaced, so the committer finds ones it can use.
                try await publishPackages(in: roomSuite)
                return
            }
            // Counted as a member and holding nothing to be one with: the
            // Welcome was for a key package whose private half this process
            // never had, or did not open. Ask to be added again.
            if snapshot.members.contains(identity) { try await requestRejoin() }
            return
        }
        try await commitIfDue(group, snapshot)
    }

    // MARK: - Joining

    /// Replace this device's key packages with fresh ones in `cipherSuite`.
    private func publishPackages(in cipherSuite: MLSCipherSuite) async throws {
        var fresh: [Data: MLSKeyPackageBundle] = [:]
        var oneTime: [Data] = []
        for _ in 0 ..< Self.oneTimePackages {
            let bundle = try MLSKeyPackageBundle.generate(identity: identity, cipherSuite: cipherSuite)
            fresh[bundle.keyPackage.reference] = bundle
            oneTime.append(bundle.keyPackage.encoded)
        }
        let last = try MLSKeyPackageBundle.generate(identity: identity, cipherSuite: cipherSuite)
        fresh[last.keyPackage.reference] = last
        try await delivery.publishKeyPackages(oneTime, lastResort: last.keyPackage.encoded, token: token())
        bundles = fresh
        lastResort = last.keyPackage.reference
        packageSuite = cipherSuite
    }

    private func found() async throws {
        let bundle = try MLSKeyPackageBundle.generate(identity: identity, cipherSuite: foundingSuite)
        let id = MLSCipherSuite.randomSecret(16)
        let founded = try MLSGroup.create(groupID: id, bundle: bundle)
        guard try await delivery.createGroup(id, cipherSuite: foundingSuite, token: token()) else { return }
        adopt(founded)
        logger.info(.room, "founded the room's encryption group", [
            LogField("suite", .number(Int(foundingSuite.identifier))),
        ])
    }

    private func accept(welcome data: Data) {
        guard let welcome = try? MLSWelcome.decode(data) else { return }
        guard let (reference, bundle) = bundles.first(where: { welcome.isAddressed(to: $0.value.keyPackage) })
            .map({ ($0.key, $0.value) })
        else { return }
        do {
            let joined = try MLSGroup.join(welcome, bundle: bundle)
            // One-time means one time: the private half is not kept for a
            // second Welcome to the same package.
            if reference != lastResort { bundles[reference] = nil }
            adopt(joined)
            logger.info(.room, "joined the room's encryption group", [
                LogField("epoch", .number(Int(joined.epoch))),
            ])
        } catch {
            logger.warning(.room, "could not open a Welcome", [LogField("error", .text("\(error)"))])
        }
    }

    private func requestRejoin() async throws {
        let suite = group?.cipherSuite ?? packageSuite
        forget()
        bundles.removeAll()
        try await publishPackages(in: suite)
        try await delivery.rejoin(token: token())
    }

    // MARK: - Following

    /// Apply one ordered commit. `false` when this device can no longer follow.
    private func follow(commit data: Data) async throws -> Bool {
        guard let current = group else { return true }
        let message: MLSCommitMessage
        do {
            message = try MLSCommitMessage.decode(data)
        } catch {
            return true
        }
        // Already applied: this device's own commit, adopted when it was
        // accepted, or one from before this device joined.
        if message.epoch < current.epoch { return true }
        do {
            switch try current.process(message) {
            case let .advanced(next):
                adopt(next)
                return true
            case .removed:
                logger.info(.room, "removed from the room's encryption group")
                try await requestRejoin()
                return false
            }
        } catch {
            // A commit every other member accepted and this one cannot is a
            // fork, and the only way back is to be added afresh.
            logger.warning(.room, "could not follow a commit", [LogField("error", .text("\(error)"))])
            try await requestRejoin()
            return false
        }
    }

    // MARK: - Committing

    private func commitIfDue(_ group: MLSGroup, _ snapshot: MLSDeliverySnapshot) async throws {
        let online = Set(snapshot.members)
        let pending = Set(snapshot.pending).subtracting([identity])
        let roster = group.roster

        // Gone, or back with a new key package and so with a leaf that is stale.
        let leaving = roster.filter {
            let who = $0.member.identityString
            return who != identity && (!online.contains(who) || pending.contains(who))
        }
        guard !leaving.isEmpty || !pending.isEmpty else {
            workSince = nil
            return
        }

        let committers = roster
            .filter { online.contains($0.member.identityString) && !pending.contains($0.member.identityString) }
            .map(\.leaf)
            .sorted()
        guard let rank = committers.firstIndex(of: group.ownLeaf) else { return }
        let now = ContinuousClock.now
        let since = workSince ?? now
        workSince = since
        guard rank == 0 || now - since >= Self.fallbackStep * rank else { return }

        var packages: [MLSKeyPackage] = []
        for who in pending.sorted() {
            // A package in another suite is skipped, not an error: its device
            // replaces it once it sees the group's suite.
            guard
                let data = try? await delivery.claimKeyPackage(for: who, token: token()),
                let package = try? MLSKeyPackage.decode(data),
                package.cipherSuite == group.cipherSuite,
                package.isValid, package.identityString == who
            else { continue }
            packages.append(package)
        }
        let removing = leaving.filter { leaf in
            // A returning device is only removed alongside its re-add, so a
            // package that could not be claimed does not take it out early.
            !pending.contains(leaf.member.identityString)
                || packages.contains { $0.identityString == leaf.member.identityString }
        }
        guard !packages.isEmpty || !removing.isEmpty else { return }

        let built = try group.commit(adding: packages, removing: removing.map(\.leaf))
        let receipt = try await delivery.submitCommit(
            MLSDeliveryCommit(
                epoch: group.epoch,
                commit: built.message.encoded,
                welcome: built.welcome?.encoded,
                joiners: built.joiners.map(\.identityString),
                removed: removing.map(\.member.identityString)
            ),
            token: token()
        )
        switch receipt {
        case .accepted:
            // Adopted now rather than when it comes back in the log, so this
            // device stops sending under the old key as soon as the change is
            // ordered. The echo is skipped by its epoch.
            guard self.group?.epoch == group.epoch else { return }
            workSince = nil
            adopt(built.next)
            logger.info(.room, "committed a membership change", [
                LogField("epoch", .number(Int(built.next.epoch))),
                LogField("added", .number(packages.count)),
                LogField("removed", .number(removing.count)),
            ])
        case .stale:
            // Somebody else's commit was ordered first; it arrives on the next
            // sync and the decision is made again from there.
            break
        }
    }

    // MARK: - Keys

    private func adopt(_ next: MLSGroup) {
        group = next
        let keys = next.sframeKeys(suite: suite)
        let receiver = encryption.receiver
        let fresh = Set(keys.map(\.keyID))
        // Anything still loaded from two epochs back goes now; the epoch just
        // left keeps its keys for frames already in flight under them. A KID
        // the new epoch reuses — its low epoch bits wrapped, as RFC 9605 §5.2
        // says receivers must handle — is overwritten by the add below.
        retiring?.cancel()
        for keyID in previousKeys.subtracting(fresh) { receiver.remove(keyID: keyID) }
        let previous = currentKeys.subtracting(fresh)
        for key in keys { receiver.add(key) }
        currentKeys = fresh
        previousKeys = previous
        if let own = keys.first(where: { $0.keyID == MLSSFrameKeys.keyID(leaf: next.ownLeaf, epoch: next.epoch) }) {
            encryption.sender.rekey(own)
        }
        if !previous.isEmpty {
            let sleep = sleep
            retiring = Task { [weak self] in
                await sleep(Self.retention)
                guard !Task.isCancelled else { return }
                await self?.retire(previous)
            }
        }
        let unprotector = unprotector
        Task { await unprotector.keysChanged() }
    }

    private func retire(_ keyIDs: Set<UInt64>) {
        for keyID in keyIDs.intersection(previousKeys).subtracting(currentKeys) {
            encryption.receiver.remove(keyID: keyID)
        }
        previousKeys.subtract(keyIDs)
    }

    /// Drop the group and every key it produced.
    private func forget() {
        group = nil
        workSince = nil
        retiring?.cancel()
        retiring = nil
        for keyID in currentKeys.union(previousKeys) { encryption.receiver.remove(keyID: keyID) }
        currentKeys.removeAll()
        previousKeys.removeAll()
        encryption.sender.clearKey()
    }
}
