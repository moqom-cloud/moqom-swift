// Group membership for small end-to-end encrypted rooms: a deliberately small
// subset of MLS (RFC 9420).
//
// # What is RFC 9420 and what is not
//
// The primitives (`MLSCipherSuite.swift`) and the key schedule
// (`MLSKeySchedule.swift`) are RFC 9420 and are tested against its vectors. The
// group protocol below borrows the RFC's structure — epochs, a commit that
// carries proposals and a fresh commit secret, a Welcome that hands a joiner
// the joiner secret, signed content, confirmed and interim transcript hashes,
// a confirmation tag — and replaces two things to stay small:
//
// - **No ratchet tree.** Members are a flat list of leaves. A commit encrypts
//   its commit secret to every remaining member's leaf key directly, which is
//   what TreeKEM degenerates to when every parent node is blank. That costs one
//   HPKE seal per member per commit, linear rather than logarithmic, which is
//   the right trade for rooms of tens and the reason large rooms use sender
//   keys instead. The "tree hash" in the GroupContext is a hash of this list.
// - **MOQOM's own framing.** Messages are TLS-encoded like the RFC's but are
//   not its `MLSMessage`, `PublicMessage`, `KeyPackage` or `Welcome` structures,
//   so nothing here interoperates with another MLS implementation.
//
// Not implemented at all: the ratchet tree and parent hashes, the secret tree
// and `PrivateMessage` (application data is SFrame, keyed from the exporter as
// RFC 9605 §5.2 says), PSKs, external commits and external proposals, ReInit,
// extensions, credentials other than a bare identity, key package lifetimes,
// and every cipher suite but the three in `MLSCipherSuite.swift`. Do not
// describe this as RFC 9420 conformant; it is not.
//
// Proposals are Add and Remove, always carried by value inside the commit
// that applies them. There is no standalone Update proposal: in this design a
// member refreshes its own leaf key by committing — an empty
// ``MLSGroup/commit(adding:removing:)`` — which is what an RFC 9420 commit
// with an UpdatePath does for its sender, and it means there is never a
// proposal sitting unapplied that a committer has to remember to include.
//
// # Cipher suites
//
// A group has one suite for its whole life, fixed when it is founded and
// carried in its GroupContext; new groups use
// MLS_192_MLKEM768_AES256GCM_SHA384_MLDSA65 (see `MLSCipherSuite.swift`), and
// no other. Every key package names its suite, a commit refuses to add a
// package in another, and a joiner refuses a Welcome whose group is in
// another. There is no migrating a group between suites: a room that should
// change suite founds a new group.
//
// ML-KEM-768 because a commit secret or joiner secret recorded today is
// otherwise only as safe as X25519, and everything later in the epoch, SFrame
// keys included, is derived from those secrets. ML-DSA-65 because the
// signatures are what say which member sent a commit and who is in the group:
// classical signatures would let whoever can break them later forge history,
// and, while a call is live, would be the one part of the group a quantum
// attacker could impersonate.
//
// # Why software keys, and not the Secure Enclave
//
// The MLS signature key signs every commit and GroupInfo this member makes and
// is thrown away with the session, so it is a CryptoKit software key (ML-DSA-65
// for new groups, Ed25519 in the older suites), not the enclave key, which is
// the device's one long-lived identity. Binding the two is the delivery
// service's job instead:
// it accepts a key package only from a token whose subject and device are the
// identity inside it, and that token is itself bound to the enclave key.
//
// # What it guarantees
//
// - A member removed in a commit cannot derive that epoch or any later one:
//   the new commit secret is encrypted to everyone but them.
// - A member who joins cannot derive earlier epochs: a Welcome carries only the
//   new epoch's joiner secret.
// - Every commit refreshes the committer's leaf key and mixes fresh randomness
//   into the key schedule, so a compromise of the committer heals at its next
//   commit and a compromise of any member's epoch secrets heals at the next
//   commit by anyone. A member's own leaf key refreshes only when that member
//   commits; ``MLSGroup/commit(adding:removing:)`` with nothing to add or
//   remove is how a member rotates it.
// - Commits and group information are signed by the committer's signature key
//   (ML-DSA-65 in new groups) and bound to the epoch's GroupContext, and a confirmation tag proves every
//   member derived the same epoch.
//
// What it does not guarantee: that the identity in a key package belongs to
// the person it names. That binding is the delivery service's, which is to say
// MOQOM's control plane admits a device and the group takes its word. A
// compromised operator could therefore add a device; every member would see it
// in ``MLSGroup/members``, and ``MLSGroup/epochAuthenticator`` is the value two
// people compare out of band to rule that out.

import CryptoKit
import Foundation

/// One member, as the group knows them.
public struct MLSLeaf: Hashable, Sendable {
    /// The MOQOM identity, `username/device`, as UTF-8.
    public let identity: Data
    public let signatureKey: Data
    public let encryptionKey: Data

    public var identityString: String { String(decoding: identity, as: UTF8.self) }

    func write(to writer: inout MLSWriter) {
        writer.vector(identity)
        writer.vector(signatureKey)
        writer.vector(encryptionKey)
    }

    static func read(from reader: inout MLSReader) throws(MLSError) -> MLSLeaf {
        MLSLeaf(
            identity: try reader.vector(),
            signatureKey: try reader.vector(),
            encryptionKey: try reader.vector()
        )
    }
}

/// What a device publishes so that it can be added.
///
/// Signed by its own signature key, and naming its cipher suite, which is the
/// only suite of group it can join. Two KEM keys of that suite, as in the RFC:
/// the init key is used once, to receive a Welcome, and the encryption key
/// becomes the leaf key a member's commit secrets are encrypted to.
///
/// In the hybrid suite each of the two keys is 1,216 bytes, so a package is
/// about 2.5 KB against about 200 bytes in suite 0x0001.
public struct MLSKeyPackage: Hashable, Sendable {
    public let cipherSuite: MLSCipherSuite
    public let identity: Data
    public let signatureKey: Data
    public let initKey: Data
    public let encryptionKey: Data
    public let signature: Data

    init(
        cipherSuite: MLSCipherSuite,
        identity: Data,
        signatureKey: Data,
        initKey: Data,
        encryptionKey: Data,
        signature: Data
    ) {
        self.cipherSuite = cipherSuite
        self.identity = identity
        self.signatureKey = signatureKey
        self.initKey = initKey
        self.encryptionKey = encryptionKey
        self.signature = signature
    }

    var toBeSigned: Data {
        var writer = MLSWriter()
        writer.uint16(MLSCipherSuite.version)
        writer.uint16(cipherSuite.identifier)
        writer.vector(identity)
        writer.vector(signatureKey)
        writer.vector(initKey)
        writer.vector(encryptionKey)
        return writer.bytes
    }

    public var encoded: Data {
        var writer = MLSWriter()
        writer.raw(toBeSigned)
        writer.vector(signature)
        return writer.bytes
    }

    /// Refuses, as ``MLSError/unsupported``, a package in a suite this SDK
    /// does not implement.
    public static func decode(_ data: Data) throws(MLSError) -> MLSKeyPackage {
        var reader = MLSReader(data)
        let package = MLSKeyPackage(
            cipherSuite: try reader.cipherSuite(),
            identity: try reader.vector(),
            signatureKey: try reader.vector(),
            initKey: try reader.vector(),
            encryptionKey: try reader.vector(),
            signature: try reader.vector()
        )
        try reader.finish()
        return package
    }

    /// Whether the package is signed by the key it carries, and its keys are
    /// the size its suite says.
    public var isValid: Bool {
        signatureKey.count == cipherSuite.signatureKeyLength
            && initKey.count == cipherSuite.publicKeyLength
            && encryptionKey.count == cipherSuite.publicKeyLength
            && initKey != encryptionKey
            && cipherSuite.verifyWithLabel(
                signatureKey, label: "KeyPackageTBS", content: toBeSigned, signature: signature
            )
    }

    /// `KeyPackageRef`, RFC 9420 §5.2.
    public var reference: Data {
        cipherSuite.refHash(label: "MLS 1.0 KeyPackage Reference", value: encoded)
    }

    public var identityString: String { String(decoding: identity, as: UTF8.self) }

    var leaf: MLSLeaf {
        MLSLeaf(identity: identity, signatureKey: signatureKey, encryptionKey: encryptionKey)
    }
}

/// A key package and the private keys behind it.
///
/// Fresh per session. Never leaves the device; nothing in MOQOM stores it.
public struct MLSKeyPackageBundle: Sendable {
    public let keyPackage: MLSKeyPackage
    let initPrivate: Data
    let encryptionPrivate: Data
    let signaturePrivate: Data

    /// A key package for `identity` in `cipherSuite`, which is the only suite
    /// of group it can be added to.
    public static func generate(
        identity: String,
        cipherSuite: MLSCipherSuite = .default
    ) throws(MLSError) -> MLSKeyPackageBundle {
        let signing = try cipherSuite.generateSignatureKeyPair()
        let initKey = try cipherSuite.generateKeyPair()
        let encryption = try cipherSuite.generateKeyPair()
        let unsigned = MLSKeyPackage(
            cipherSuite: cipherSuite,
            identity: Data(identity.utf8),
            signatureKey: signing.publicKey,
            initKey: initKey.publicKey,
            encryptionKey: encryption.publicKey,
            signature: Data()
        )
        let signature = try cipherSuite.signWithLabel(
            signing.privateKey, label: "KeyPackageTBS", content: unsigned.toBeSigned
        )
        return MLSKeyPackageBundle(
            keyPackage: MLSKeyPackage(
                cipherSuite: cipherSuite,
                identity: unsigned.identity,
                signatureKey: unsigned.signatureKey,
                initKey: unsigned.initKey,
                encryptionKey: unsigned.encryptionKey,
                signature: signature
            ),
            initPrivate: initKey.privateKey,
            encryptionPrivate: encryption.privateKey,
            signaturePrivate: signing.privateKey
        )
    }
}

/// A change a commit makes to who is in the group.
enum MLSProposal: Hashable, Sendable {
    case add(MLSKeyPackage)
    case remove(UInt32)

    func write(to writer: inout MLSWriter) {
        switch self {
        case let .add(package):
            writer.uint16(1)
            writer.vector(package.encoded)
        case let .remove(leaf):
            writer.uint16(3)
            writer.uint32(leaf)
        }
    }

    static func read(from reader: inout MLSReader) throws(MLSError) -> MLSProposal {
        switch try reader.uint16() {
        case 1: return .add(try MLSKeyPackage.decode(try reader.vector()))
        case 3: return .remove(try reader.uint32())
        default: throw MLSError.unsupported
        }
    }
}

/// The list of leaves, with blanks where members were removed.
struct MLSMembers: Hashable, Sendable {
    var leaves: [MLSLeaf?]

    var encoded: Data {
        var writer = MLSWriter()
        writer.uint32(UInt32(leaves.count))
        for leaf in leaves {
            if let leaf {
                writer.uint8(1)
                leaf.write(to: &writer)
            } else {
                writer.uint8(0)
            }
        }
        return writer.bytes
    }

    static func read(from reader: inout MLSReader) throws(MLSError) -> MLSMembers {
        let count = try reader.uint32()
        guard count <= 1 << 16 else { throw MLSError.malformed }
        var leaves: [MLSLeaf?] = []
        for _ in 0 ..< count {
            switch try reader.uint8() {
            case 0: leaves.append(nil)
            case 1: leaves.append(try MLSLeaf.read(from: &reader))
            default: throw MLSError.malformed
            }
        }
        return MLSMembers(leaves: leaves)
    }

    /// The GroupContext's `tree_hash` slot. Not the RFC's tree hash, since
    /// there is no tree; a hash of the whole member list in its place.
    func hash(in suite: MLSCipherSuite) -> Data {
        suite.refHash(label: "MOQOM 1.0 Member List", value: encoded)
    }

    func leaf(_ index: UInt32) -> MLSLeaf? {
        Int(index) < leaves.count ? leaves[Int(index)] : nil
    }

    /// Apply removes, then adds into the leftmost blank, then trim trailing
    /// blanks — in that order on every member, which is what keeps leaf
    /// indices agreed without sending them.
    mutating func apply(
        _ proposals: [MLSProposal],
        suite: MLSCipherSuite
    ) throws(MLSError) -> [(leaf: UInt32, package: MLSKeyPackage)] {
        for case let .remove(index) in proposals {
            guard leaf(index) != nil else { throw MLSError.invalidProposal }
            leaves[Int(index)] = nil
        }
        var added: [(UInt32, MLSKeyPackage)] = []
        for case let .add(package) in proposals {
            guard package.cipherSuite == suite else {
                throw MLSError.cipherSuiteMismatch(group: suite.identifier, other: package.cipherSuite.identifier)
            }
            guard package.isValid else { throw MLSError.badSignature }
            let clash = leaves.contains {
                $0?.signatureKey == package.signatureKey || $0?.encryptionKey == package.encryptionKey
                    || $0?.identity == package.identity
            }
            guard !clash else { throw MLSError.invalidProposal }
            let slot = leaves.firstIndex(where: { $0 == nil }) ?? leaves.count
            if slot == leaves.count { leaves.append(nil) }
            leaves[slot] = package.leaf
            added.append((UInt32(slot), package))
        }
        while let last = leaves.last, last == nil { leaves.removeLast() }
        return added
    }
}

/// A commit, signed and confirmed, as it travels.
public struct MLSCommitMessage: Hashable, Sendable {
    public let groupID: Data
    public let epoch: UInt64
    public let sender: UInt32
    let commit: Data
    let signature: Data
    let confirmationTag: Data

    /// The FramedContent: what is signed (after the GroupContext) and what the
    /// confirmed transcript hash covers (before the signature).
    var content: Data {
        var writer = MLSWriter()
        writer.vector(groupID)
        writer.uint64(epoch)
        writer.uint32(sender)
        writer.vector(commit)
        return writer.bytes
    }

    public var encoded: Data {
        var writer = MLSWriter()
        writer.raw(content)
        writer.vector(signature)
        writer.vector(confirmationTag)
        return writer.bytes
    }

    public static func decode(_ data: Data) throws(MLSError) -> MLSCommitMessage {
        var reader = MLSReader(data)
        let message = MLSCommitMessage(
            groupID: try reader.vector(),
            epoch: try reader.uint64(),
            sender: try reader.uint32(),
            commit: try reader.vector(),
            signature: try reader.vector(),
            confirmationTag: try reader.vector()
        )
        try reader.finish()
        return message
    }
}

/// The body of a commit.
struct MLSCommit: Sendable {
    var proposals: [MLSProposal]
    /// The committer's new leaf key, which is the whole of the "path" here.
    var committerEncryptionKey: Data
    /// The commit secret, encrypted to each remaining member by leaf.
    var secrets: [(leaf: UInt32, ciphertext: HPKECiphertext)]

    var encoded: Data {
        var writer = MLSWriter()
        writer.uint32(UInt32(proposals.count))
        for proposal in proposals { proposal.write(to: &writer) }
        writer.vector(committerEncryptionKey)
        writer.uint32(UInt32(secrets.count))
        for entry in secrets {
            writer.uint32(entry.leaf)
            entry.ciphertext.write(to: &writer)
        }
        return writer.bytes
    }

    static func decode(_ data: Data) throws(MLSError) -> MLSCommit {
        var reader = MLSReader(data)
        let proposalCount = try reader.uint32()
        guard proposalCount <= 1 << 12 else { throw MLSError.malformed }
        var proposals: [MLSProposal] = []
        for _ in 0 ..< proposalCount { proposals.append(try MLSProposal.read(from: &reader)) }
        let key = try reader.vector()
        let secretCount = try reader.uint32()
        guard secretCount <= 1 << 16 else { throw MLSError.malformed }
        var secrets: [(UInt32, HPKECiphertext)] = []
        for _ in 0 ..< secretCount {
            secrets.append((try reader.uint32(), try HPKECiphertext.read(from: &reader)))
        }
        try reader.finish()
        return MLSCommit(proposals: proposals, committerEncryptionKey: key, secrets: secrets)
    }
}

/// How a joiner enters: the joiner secret for each new member, and the group
/// as it now is, encrypted under the welcome secret.
public struct MLSWelcome: Hashable, Sendable {
    let secrets: [(reference: Data, ciphertext: HPKECiphertext)]
    let encryptedGroupInfo: Data

    public static func == (lhs: MLSWelcome, rhs: MLSWelcome) -> Bool { lhs.encoded == rhs.encoded }
    public func hash(into hasher: inout Hasher) { hasher.combine(encoded) }

    public var encoded: Data {
        var writer = MLSWriter()
        writer.uint32(UInt32(secrets.count))
        for entry in secrets {
            writer.vector(entry.reference)
            entry.ciphertext.write(to: &writer)
        }
        writer.vector(encryptedGroupInfo)
        return writer.bytes
    }

    public static func decode(_ data: Data) throws(MLSError) -> MLSWelcome {
        var reader = MLSReader(data)
        let count = try reader.uint32()
        guard count <= 1 << 16 else { throw MLSError.malformed }
        var secrets: [(Data, HPKECiphertext)] = []
        for _ in 0 ..< count {
            secrets.append((try reader.vector(), try HPKECiphertext.read(from: &reader)))
        }
        let info = try reader.vector()
        try reader.finish()
        return MLSWelcome(secrets: secrets, encryptedGroupInfo: info)
    }

    /// Whether this Welcome carries a secret for the given key package.
    public func isAddressed(to package: MLSKeyPackage) -> Bool {
        let reference = package.reference
        return secrets.contains { $0.reference == reference }
    }
}

/// A commit that has been built and not yet accepted.
///
/// The group does not move until the delivery service orders this commit
/// first for its epoch; ``next`` is the state to adopt when it does, and
/// discarding this value is how a commit that lost the race is abandoned.
public struct MLSPendingCommit: Sendable {
    public let message: MLSCommitMessage
    public let welcome: MLSWelcome?
    /// The identities this commit adds, which are who the Welcome is for.
    public let joiners: [MLSKeyPackage]
    public let next: MLSGroup
}

/// What processing a commit did.
public enum MLSCommitOutcome: Sendable {
    case advanced(MLSGroup)
    /// This member was removed. The group cannot be followed any further.
    case removed
}

/// One member's view of a group at one epoch.
///
/// A value: every transition returns a new one and the old one can be dropped,
/// which is where forward secrecy comes from — nothing derived from a previous
/// epoch survives the caller letting go of it.
public struct MLSGroup: Sendable {
    public let groupID: Data
    public let ownLeaf: UInt32
    let members: MLSMembers
    let context: MLSGroupContext
    let secrets: MLSEpochSecrets
    let interimTranscriptHash: Data
    let encryptionPrivate: Data
    let signaturePrivate: Data

    public var epoch: UInt64 { context.epoch }

    /// The suite the group was founded with, which every member uses.
    public var cipherSuite: MLSCipherSuite { context.cipherSuite }

    /// Occupied leaves, by index.
    public var roster: [(leaf: UInt32, member: MLSLeaf)] {
        members.leaves.enumerated().compactMap { index, leaf in
            leaf.map { (UInt32(index), $0) }
        }
    }

    public var memberCount: Int { roster.count }

    /// RFC 9420's `epoch_authenticator`: equal on every member's device for the
    /// same epoch, and something two people can compare to know nobody is in
    /// the group that the other cannot see.
    public var epochAuthenticator: Data { secrets.epochAuthenticator }

    /// `MLS-Exporter`, RFC 9420 §8.5, for this epoch.
    public func export(label: String, context: Data = Data(), length: Int) -> Data {
        secrets.export(label: label, context: context, length: length)
    }

    /// The leaf a given identity occupies, if any.
    public func leaf(of identity: String) -> UInt32? {
        let bytes = Data(identity.utf8)
        return roster.first { $0.member.identity == bytes }?.leaf
    }

    /// The SFrame key one member sends under in this epoch.
    public func sframeKey(for leaf: UInt32, suite: SFrameCipherSuite) -> SFrameKey {
        MLSSFrameKeys.key(secrets, leaf: leaf, epoch: epoch, suite: suite)
    }

    /// Every current member's SFrame key for this epoch, from one export.
    /// The epoch's SFrame base key, from which every member's key derives.
    /// What a broadcast's viewers are sealed; see ``AudienceKeys``.
    func sframeBaseKey(suite: SFrameCipherSuite) -> Data {
        MLSSFrameKeys.baseKey(secrets, suite: suite)
    }

    public func sframeKeys(suite: SFrameCipherSuite) -> [SFrameKey] {
        let base = MLSSFrameKeys.baseKey(secrets, suite: suite)
        return roster.map { MLSSFrameKeys.key(baseKey: base, leaf: $0.leaf, epoch: epoch, suite: suite) }
    }

    /// Start a group with one member, in the suite of that member's key package.
    public static func create(
        groupID: Data,
        bundle: MLSKeyPackageBundle
    ) throws(MLSError) -> MLSGroup {
        guard bundle.keyPackage.isValid else { throw MLSError.badSignature }
        let suite = bundle.keyPackage.cipherSuite
        let members = MLSMembers(leaves: [bundle.keyPackage.leaf])
        let context = MLSGroupContext(
            cipherSuite: suite,
            groupID: groupID, epoch: 0, treeHash: members.hash(in: suite), confirmedTranscriptHash: Data()
        )
        let secrets = MLSEpochSecrets.derive(
            initSecret: suite.randomSecret(),
            commitSecret: suite.randomSecret(),
            context: context
        )
        let tag = suite.mac(key: secrets.confirmationKey, data: Data())
        return MLSGroup(
            groupID: groupID,
            ownLeaf: 0,
            members: members,
            context: context,
            secrets: secrets,
            interimTranscriptHash: Self.interim(confirmed: Data(), tag: tag, suite: suite),
            encryptionPrivate: bundle.encryptionPrivate,
            signaturePrivate: bundle.signaturePrivate
        )
    }

    private static func interim(confirmed: Data, tag: Data, suite: MLSCipherSuite) -> Data {
        var writer = MLSWriter()
        writer.raw(confirmed)
        writer.vector(tag)
        return suite.hash(writer.bytes)
    }

    private func confirmed(content: Data, signature: Data) -> Data {
        var writer = MLSWriter()
        writer.raw(interimTranscriptHash)
        writer.raw(content)
        writer.vector(signature)
        return cipherSuite.hash(writer.bytes)
    }

    // MARK: - Committing

    /// Build a commit that adds and removes members and refreshes this
    /// member's leaf key. With nothing to add or remove it is a pure key
    /// rotation.
    ///
    /// Throws ``MLSError/cipherSuiteMismatch(group:other:)`` for a package in
    /// a suite other than the group's.
    public func commit(
        adding packages: [MLSKeyPackage] = [],
        removing leaves: [UInt32] = []
    ) throws(MLSError) -> MLSPendingCommit {
        guard !leaves.contains(ownLeaf) else { throw MLSError.invalidProposal }
        let proposals = leaves.sorted().map(MLSProposal.remove) + packages.map(MLSProposal.add)

        var next = members
        let added = try next.apply(proposals, suite: cipherSuite)
        let joinerLeaves = Set(added.map(\.leaf))

        let encryption = try cipherSuite.generateKeyPair()
        guard let own = next.leaf(ownLeaf) else { throw MLSError.removed }
        next.leaves[Int(ownLeaf)] = MLSLeaf(
            identity: own.identity,
            signatureKey: own.signatureKey,
            encryptionKey: encryption.publicKey
        )

        let commitSecret = cipherSuite.randomSecret()
        let provisional = MLSGroupContext(
            cipherSuite: cipherSuite,
            groupID: groupID,
            epoch: epoch + 1,
            treeHash: next.hash(in: cipherSuite),
            confirmedTranscriptHash: context.confirmedTranscriptHash
        )
        var sealed: [(UInt32, HPKECiphertext)] = []
        for (index, leaf) in next.leaves.enumerated() {
            guard let leaf, UInt32(index) != ownLeaf, !joinerLeaves.contains(UInt32(index)) else {
                continue
            }
            sealed.append((
                UInt32(index),
                try cipherSuite.encryptWithLabel(
                    leaf.encryptionKey,
                    label: "UpdatePathNode",
                    context: provisional.encoded,
                    plaintext: commitSecret
                )
            ))
        }

        let body = MLSCommit(
            proposals: proposals,
            committerEncryptionKey: encryption.publicKey,
            secrets: sealed
        )
        let unsigned = MLSCommitMessage(
            groupID: groupID, epoch: epoch, sender: ownLeaf,
            commit: body.encoded, signature: Data(), confirmationTag: Data()
        )
        let signature = try cipherSuite.signWithLabel(
            signaturePrivate, label: "FramedContentTBS", content: context.encoded + unsigned.content
        )

        let confirmed = confirmed(content: unsigned.content, signature: signature)
        let newContext = MLSGroupContext(
            cipherSuite: cipherSuite,
            groupID: groupID, epoch: epoch + 1, treeHash: next.hash(in: cipherSuite), confirmedTranscriptHash: confirmed
        )
        let newSecrets = MLSEpochSecrets.derive(
            initSecret: secrets.initSecret, commitSecret: commitSecret, context: newContext
        )
        let tag = cipherSuite.mac(key: newSecrets.confirmationKey, data: confirmed)

        let message = MLSCommitMessage(
            groupID: groupID, epoch: epoch, sender: ownLeaf,
            commit: body.encoded, signature: signature, confirmationTag: tag
        )
        let advanced = MLSGroup(
            groupID: groupID,
            ownLeaf: ownLeaf,
            members: next,
            context: newContext,
            secrets: newSecrets,
            interimTranscriptHash: Self.interim(confirmed: confirmed, tag: tag, suite: cipherSuite),
            encryptionPrivate: encryption.privateKey,
            signaturePrivate: signaturePrivate
        )

        let welcome: MLSWelcome? = added.isEmpty
            ? nil
            : try advanced.welcome(for: added.map(\.package), tag: tag)

        return MLSPendingCommit(
            message: message,
            welcome: welcome,
            joiners: added.map(\.package),
            next: advanced
        )
    }

    private func groupInfoToBeSigned(tag: Data) -> Data {
        var writer = MLSWriter()
        writer.raw(context.encoded)
        writer.raw(members.encoded)
        writer.vector(tag)
        writer.uint32(ownLeaf)
        return writer.bytes
    }

    private static func welcomeKeys(
        _ welcomeSecret: Data,
        suite: MLSCipherSuite
    ) -> (key: Data, nonce: Data) {
        (
            suite.expandWithLabel(
                welcomeSecret, label: "key", context: Data(), length: suite.aeadKeyLength
            ),
            suite.expandWithLabel(
                welcomeSecret, label: "nonce", context: Data(), length: MLSCipherSuite.aeadNonceLength
            )
        )
    }

    private func welcome(for packages: [MLSKeyPackage], tag: Data) throws(MLSError) -> MLSWelcome {
        let tbs = groupInfoToBeSigned(tag: tag)
        var info = MLSWriter()
        info.raw(tbs)
        info.vector(try cipherSuite.signWithLabel(signaturePrivate, label: "GroupInfoTBS", content: tbs))

        let (key, nonce) = Self.welcomeKeys(secrets.welcomeSecret, suite: cipherSuite)
        let encrypted = try MLSCipherSuite.aeadSeal(
            key: key, nonce: nonce, plaintext: info.bytes, aad: Data()
        )
        var entries: [(Data, HPKECiphertext)] = []
        for package in packages {
            entries.append((
                package.reference,
                try cipherSuite.encryptWithLabel(
                    package.initKey,
                    label: "Welcome",
                    context: encrypted,
                    plaintext: secrets.joinerSecret
                )
            ))
        }
        return MLSWelcome(secrets: entries, encryptedGroupInfo: encrypted)
    }

    // MARK: - Following

    /// Apply a commit somebody else made.
    public func process(_ message: MLSCommitMessage) throws(MLSError) -> MLSCommitOutcome {
        guard message.groupID == groupID else { throw MLSError.wrongGroup }
        guard message.epoch == epoch else {
            throw MLSError.wrongEpoch(expected: epoch, got: message.epoch)
        }
        guard message.sender != ownLeaf, let sender = members.leaf(message.sender) else {
            throw MLSError.unknownSender
        }
        guard cipherSuite.verifyWithLabel(
            sender.signatureKey,
            label: "FramedContentTBS",
            content: context.encoded + message.content,
            signature: message.signature
        ) else { throw MLSError.badSignature }

        let body = try MLSCommit.decode(message.commit)
        // A committer cannot remove itself: a member leaving is removed by
        // somebody who stays, so that the new secret has someone to come from.
        for case let .remove(leaf) in body.proposals where leaf == message.sender {
            throw MLSError.invalidProposal
        }
        guard body.committerEncryptionKey.count == cipherSuite.publicKeyLength else {
            throw MLSError.malformed
        }
        var next = members
        _ = try next.apply(body.proposals, suite: cipherSuite)
        guard next.leaf(ownLeaf) != nil else { return .removed }
        next.leaves[Int(message.sender)] = MLSLeaf(
            identity: sender.identity,
            signatureKey: sender.signatureKey,
            encryptionKey: body.committerEncryptionKey
        )

        let provisional = MLSGroupContext(
            cipherSuite: cipherSuite,
            groupID: groupID,
            epoch: epoch + 1,
            treeHash: next.hash(in: cipherSuite),
            confirmedTranscriptHash: context.confirmedTranscriptHash
        )
        guard let mine = body.secrets.first(where: { $0.leaf == ownLeaf }) else {
            throw MLSError.notAddressed
        }
        let commitSecret = try cipherSuite.decryptWithLabel(
            encryptionPrivate, label: "UpdatePathNode", context: provisional.encoded, ciphertext: mine.ciphertext
        )

        let confirmed = confirmed(content: message.content, signature: message.signature)
        let newContext = MLSGroupContext(
            cipherSuite: cipherSuite,
            groupID: groupID, epoch: epoch + 1, treeHash: next.hash(in: cipherSuite), confirmedTranscriptHash: confirmed
        )
        let newSecrets = MLSEpochSecrets.derive(
            initSecret: secrets.initSecret, commitSecret: commitSecret, context: newContext
        )
        let tag = cipherSuite.mac(key: newSecrets.confirmationKey, data: confirmed)
        guard tag == message.confirmationTag else { throw MLSError.confirmationMismatch }

        return .advanced(MLSGroup(
            groupID: groupID,
            ownLeaf: ownLeaf,
            members: next,
            context: newContext,
            secrets: newSecrets,
            interimTranscriptHash: Self.interim(confirmed: confirmed, tag: tag, suite: cipherSuite),
            encryptionPrivate: encryptionPrivate,
            signaturePrivate: signaturePrivate
        ))
    }

    /// Enter a group from a Welcome addressed to this bundle's key package.
    ///
    /// The group must be in the key package's suite; a Welcome into any other
    /// is refused with ``MLSError/cipherSuiteMismatch(group:other:)``.
    public static func join(
        _ welcome: MLSWelcome,
        bundle: MLSKeyPackageBundle
    ) throws(MLSError) -> MLSGroup {
        let suite = bundle.keyPackage.cipherSuite
        let reference = bundle.keyPackage.reference
        guard let entry = welcome.secrets.first(where: { $0.reference == reference }) else {
            throw MLSError.notAddressed
        }
        let joinerSecret = try suite.decryptWithLabel(
            bundle.initPrivate, label: "Welcome", context: welcome.encryptedGroupInfo, ciphertext: entry.ciphertext
        )
        let (key, nonce) = welcomeKeys(
            MLSEpochSecrets.welcomeSecret(joinerSecret: joinerSecret, suite: suite), suite: suite
        )
        let info = try MLSCipherSuite.aeadOpen(
            key: key, nonce: nonce, ciphertext: welcome.encryptedGroupInfo, aad: Data()
        )

        var reader = MLSReader(info)
        let context = try MLSGroupContext.read(from: &reader)
        guard context.cipherSuite == suite else {
            throw MLSError.cipherSuiteMismatch(group: context.cipherSuite.identifier, other: suite.identifier)
        }
        let members = try MLSMembers.read(from: &reader)
        let tag = try reader.vector()
        let signer = try reader.uint32()
        let signature = try reader.vector()
        try reader.finish()

        guard let signerLeaf = members.leaf(signer) else { throw MLSError.unknownSender }
        var tbs = MLSWriter()
        tbs.raw(context.encoded)
        tbs.raw(members.encoded)
        tbs.vector(tag)
        tbs.uint32(signer)
        guard suite.verifyWithLabel(
            signerLeaf.signatureKey, label: "GroupInfoTBS", content: tbs.bytes, signature: signature
        ) else { throw MLSError.badSignature }
        guard members.hash(in: suite) == context.treeHash else { throw MLSError.confirmationMismatch }

        let secrets = MLSEpochSecrets.derive(joinerSecret: joinerSecret, context: context)
        guard suite.mac(
            key: secrets.confirmationKey, data: context.confirmedTranscriptHash
        ) == tag else { throw MLSError.confirmationMismatch }

        guard let own = members.leaves.firstIndex(where: { $0 == bundle.keyPackage.leaf }) else {
            throw MLSError.notAddressed
        }
        return MLSGroup(
            groupID: context.groupID,
            ownLeaf: UInt32(own),
            members: members,
            context: context,
            secrets: secrets,
            interimTranscriptHash: interim(confirmed: context.confirmedTranscriptHash, tag: tag, suite: suite),
            encryptionPrivate: bundle.encryptionPrivate,
            signaturePrivate: bundle.signaturePrivate
        )
    }
}
