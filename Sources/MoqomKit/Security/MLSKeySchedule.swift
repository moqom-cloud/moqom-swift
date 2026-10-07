// The RFC 9420 §8 key schedule, and the RFC 9605 §5.2 bridge from it to SFrame.
//
// This file is the part of the MLS subset that is meant to be bit-exact with
// the RFC, and the tests hold it to that against the working group's
// `key-schedule.json` vectors: GroupContext serialisation, every epoch-derived
// secret, the init-secret chain across epochs, and the exporter. What feeds it
// — where the commit secret comes from, what the tree hash covers — is MOQOM's
// simplification and is documented in `MLSGroup.swift`.
//
// Old epochs are not kept. An `MLSEpochSecrets` is replaced, not appended to,
// which is what forward secrecy across epochs rests on: once a member has moved
// on, nothing in memory can derive the previous epoch's keys.

import CryptoKit
import Foundation

/// `GroupContext`, RFC 9420 §8.1.
///
/// The cipher suite is part of it, so every signature over a commit or a
/// GroupInfo, and every secret the key schedule derives, is bound to the suite
/// the group was founded with.
public struct MLSGroupContext: Hashable, Sendable {
    public let cipherSuite: MLSCipherSuite
    public let groupID: Data
    public let epoch: UInt64
    public let treeHash: Data
    public let confirmedTranscriptHash: Data

    public init(
        cipherSuite: MLSCipherSuite,
        groupID: Data,
        epoch: UInt64,
        treeHash: Data,
        confirmedTranscriptHash: Data
    ) {
        self.cipherSuite = cipherSuite
        self.groupID = groupID
        self.epoch = epoch
        self.treeHash = treeHash
        self.confirmedTranscriptHash = confirmedTranscriptHash
    }

    /// The serialised form. Extensions are always empty: none are implemented.
    public var encoded: Data {
        var writer = MLSWriter()
        writer.uint16(MLSCipherSuite.version)
        writer.uint16(cipherSuite.identifier)
        writer.vector(groupID)
        writer.uint64(epoch)
        writer.vector(treeHash)
        writer.vector(confirmedTranscriptHash)
        writer.vector(Data())
        return writer.bytes
    }

    static func read(from reader: inout MLSReader) throws(MLSError) -> MLSGroupContext {
        let suite = try reader.cipherSuite()
        let groupID = try reader.vector()
        let epoch = try reader.uint64()
        let treeHash = try reader.vector()
        let confirmed = try reader.vector()
        guard try reader.vector().isEmpty else { throw MLSError.unsupported }
        return MLSGroupContext(
            cipherSuite: suite,
            groupID: groupID,
            epoch: epoch,
            treeHash: treeHash,
            confirmedTranscriptHash: confirmed
        )
    }
}

/// Everything one epoch of the key schedule produces.
public struct MLSEpochSecrets: Sendable {
    public let joinerSecret: Data
    public let welcomeSecret: Data
    public let epochSecret: Data
    public let senderDataSecret: Data
    public let encryptionSecret: Data
    public let exporterSecret: Data
    public let externalSecret: Data
    public let confirmationKey: Data
    public let membershipKey: Data
    public let resumptionPSK: Data
    public let epochAuthenticator: Data
    /// The next epoch's `init_secret`.
    public let initSecret: Data

    /// One epoch, from the previous epoch's init secret and this commit's secret.
    public static func derive(
        initSecret previous: Data,
        commitSecret: Data,
        pskSecret: Data = Data(count: MLSCipherSuite.hashLength),
        context: MLSGroupContext
    ) -> MLSEpochSecrets {
        let joiner = MLSCipherSuite.expandWithLabel(
            MLSCipherSuite.extract(salt: previous, ikm: commitSecret),
            label: "joiner",
            context: context.encoded,
            length: MLSCipherSuite.hashLength
        )
        return derive(joinerSecret: joiner, pskSecret: pskSecret, context: context)
    }

    /// One epoch from its joiner secret, which is where a member arriving by
    /// Welcome starts.
    public static func derive(
        joinerSecret joiner: Data,
        pskSecret: Data = Data(count: MLSCipherSuite.hashLength),
        context: MLSGroupContext
    ) -> MLSEpochSecrets {
        let member = MLSCipherSuite.extract(salt: joiner, ikm: pskSecret)
        let epoch = MLSCipherSuite.expandWithLabel(
            member,
            label: "epoch",
            context: context.encoded,
            length: MLSCipherSuite.hashLength
        )
        func derived(_ label: String) -> Data { MLSCipherSuite.deriveSecret(epoch, label: label) }
        return MLSEpochSecrets(
            joinerSecret: joiner,
            welcomeSecret: MLSCipherSuite.deriveSecret(member, label: "welcome"),
            epochSecret: epoch,
            senderDataSecret: derived("sender data"),
            encryptionSecret: derived("encryption"),
            exporterSecret: derived("exporter"),
            externalSecret: derived("external"),
            confirmationKey: derived("confirm"),
            membershipKey: derived("membership"),
            resumptionPSK: derived("resumption"),
            epochAuthenticator: derived("authentication"),
            initSecret: derived("init")
        )
    }

    /// The welcome secret for a joiner secret, without deriving the epoch.
    static func welcomeSecret(
        joinerSecret: Data,
        pskSecret: Data = Data(count: MLSCipherSuite.hashLength)
    ) -> Data {
        MLSCipherSuite.deriveSecret(
            MLSCipherSuite.extract(salt: joinerSecret, ikm: pskSecret),
            label: "welcome"
        )
    }

    /// `MLS-Exporter`, RFC 9420 §8.5.
    public func export(label: Data, context: Data, length: Int) -> Data {
        MLSCipherSuite.expandWithLabel(
            MLSCipherSuite.deriveSecret(exporterSecret, rawLabel: label),
            label: "exported",
            context: MLSCipherSuite.hash(context),
            length: length
        )
    }

    public func export(label: String, context: Data = Data(), length: Int) -> Data {
        export(label: Data(label.utf8), context: context, length: length)
    }
}

/// SFrame keys from an MLS epoch, RFC 9605 §5.2.
///
/// One `base_key` per epoch, shared by every member, and nothing derived per
/// sender on top of it. What separates senders is the KID: SFrame's own key
/// derivation (§4.4.2) puts the KID into the labels its key and salt come from,
/// so two members holding the same base key still encrypt under different keys
/// and nonces. An earlier version of this file expanded a per-leaf base key
/// first; RFC 9605 has no such step and a peer following the RFC would have
/// derived different keys.
///
/// The KID is `(leaf << E) | (epoch mod 2^E)` with context 0 — one SFrame
/// context per member, which is all a MOQOM session needs since a device has
/// one leaf. E = 4: a receiver holds the current epoch and, briefly, the one
/// before it, so sixteen distinguishable epochs is far more than is live at
/// once.
public enum MLSSFrameKeys {
    public static let epochBits: UInt64 = 4

    /// `base_key = MLS-Exporter("SFrame 1.0 Base Key", "", AEAD.Nk)`.
    public static func baseKey(
        _ secrets: MLSEpochSecrets,
        suite: SFrameCipherSuite
    ) -> Data {
        secrets.export(label: "SFrame 1.0 Base Key", length: suite.keyLength)
    }

    /// `KID = (context << (S + E)) + (index << E) + (epoch % (1 << E))`, context 0.
    public static func keyID(leaf: UInt32, epoch: UInt64) -> UInt64 {
        (UInt64(leaf) << epochBits) | (epoch & ((1 << epochBits) - 1))
    }

    /// The low bits of an epoch as a KID carries them.
    public static func epochTag(ofKeyID keyID: UInt64) -> UInt64 {
        keyID & ((1 << epochBits) - 1)
    }

    public static func key(
        _ secrets: MLSEpochSecrets,
        leaf: UInt32,
        epoch: UInt64,
        suite: SFrameCipherSuite
    ) -> SFrameKey {
        key(baseKey: baseKey(secrets, suite: suite), leaf: leaf, epoch: epoch, suite: suite)
    }

    /// From a base key already exported, so a whole roster can be keyed with
    /// one export.
    public static func key(
        baseKey: Data,
        leaf: UInt32,
        epoch: UInt64,
        suite: SFrameCipherSuite
    ) -> SFrameKey {
        SFrameKey(keyID: keyID(leaf: leaf, epoch: epoch), baseKey: baseKey, suite: suite)
    }
}
