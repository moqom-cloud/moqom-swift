// The RFC 9420 primitives MOQOM's group key management is built from.
//
// Three cipher suites:
//
// - `MLS_192_MLKEM768_AES256GCM_SHA384_MLDSA65`, the suite every group founded
//   by this SDK uses. draft-ietf-mls-pq-ciphersuites-06 §3.1 defines it as
//   "TBD10": HPKE KEM 0x0041 (pure ML-KEM-768, draft-ietf-hpke-pq-05),
//   HKDF-SHA384, AES-256-GCM, and ML-DSA-65 signatures (FIPS 204, as
//   draft-ietf-tls-mldsa uses it: pure, empty context). Both the secrets a
//   group carries and the signatures that say who sent them are post-quantum.
//   The draft's value is not assigned yet, so the identifier below is from
//   RFC 9420 §17.1's private-use range and has to change to the IANA value
//   once there is one. A peer that implements the draft would not recognise
//   it.
// - `MLS_128_MLKEM768X25519_AES128GCM_SHA256_Ed25519`, the draft's "TBD1"
//   (X-Wing, HKDF-SHA256, AES-128-GCM, Ed25519), also private-use. Groups
//   founded with it before the ML-DSA suite existed still work; no new group
//   uses it. Its secrets are post-quantum, its signatures are not.
// - `MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519` (0x0001), the one every MLS
//   implementation must support, kept so that groups founded with it still
//   work and so the working group's vectors keep checking the code below.
//
// Everything a group derives — the key schedule, the exporter, and so SFrame
// keys — goes through the suite's hash and KDF, so every function here is a
// method on the suite rather than a constant.
//
// Each function is the RFC's definition and nothing more. Suite 0x0001 is
// checked against the MLS working group's published test vectors
// (`crypto-basics.json`); the X-Wing KEM against the HPKE working group's
// vectors for KEM 0x647a; HPKE over pure ML-KEM-768, and ML-DSA-65 signing,
// against Go's `crypto/hpke` and `crypto/mldsa`, which is the only basis on
// which this file claims to match either draft. What is built on top of these
// primitives is MOQOM's own and is described in `MLSGroup.swift`.
//
// Everything is CryptoKit. HPKE (RFC 9180) is CryptoKit's for the two KEMs it
// offers. CryptoKit has no HPKE KEM for pure ML-KEM, so for 0x0041 the RFC 9180
// key schedule is composed below from CryptoKit's ML-KEM-768, HKDF-SHA384 and
// AES-256-GCM: no primitive is hand-rolled, only the schedule that joins them.

import CryptoKit
import Foundation

/// An MLS cipher suite this SDK implements.
///
/// A value carried by every key package and every group, never a setting: a
/// group's suite is the one it was founded with, every member uses it, and a
/// key package in any other suite is refused rather than added.
public struct MLSCipherSuite: Hashable, Sendable, CustomStringConvertible {
    /// The suite's two-byte identifier, as it appears on the wire.
    public let identifier: UInt16

    private let kem: KEM
    private let symmetric: Symmetric
    private let signer: Signer

    private enum KEM: Hashable, Sendable {
        case x25519
        case xWing
        case mlKEM768
    }

    /// The hash, KDF, MAC and AEAD, which the draft's suites pair.
    private enum Symmetric: Hashable, Sendable {
        case aes128SHA256
        case aes256SHA384
    }

    private enum Signer: Hashable, Sendable {
        case ed25519
        case mlDSA65
    }

    private init(identifier: UInt16, kem: KEM, symmetric: Symmetric, signer: Signer) {
        self.identifier = identifier
        self.kem = kem
        self.symmetric = symmetric
        self.signer = signer
    }

    /// `MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519`, RFC 9420's mandatory suite.
    public static let mls128DHKEMX25519 = MLSCipherSuite(
        identifier: 0x0001, kem: .x25519, symmetric: .aes128SHA256, signer: .ed25519
    )

    /// `MLS_128_MLKEM768X25519_AES128GCM_SHA256_Ed25519`, draft-ietf-mls-pq-ciphersuites' "TBD1".
    ///
    /// 0xF0A1 is a private-use value (RFC 9420 §17.1), standing in until IANA
    /// assigns one. Only MOQOM's own SDK and control plane know it.
    public static let mls128MLKEM768X25519 = MLSCipherSuite(
        identifier: 0xF0A1, kem: .xWing, symmetric: .aes128SHA256, signer: .ed25519
    )

    /// `MLS_192_MLKEM768_AES256GCM_SHA384_MLDSA65`, draft-ietf-mls-pq-ciphersuites' "TBD10".
    ///
    /// 0xF0AA is a private-use value (RFC 9420 §17.1), standing in until IANA
    /// assigns one. Only MOQOM's own SDK and control plane know it.
    public static let mls192MLKEM768MLDSA65 = MLSCipherSuite(
        identifier: 0xF0AA, kem: .mlKEM768, symmetric: .aes256SHA384, signer: .mlDSA65
    )

    /// The suite a newly founded group uses. There is no other choice: a group
    /// is founded post-quantum in both its secrets and its signatures.
    public static let `default` = mls192MLKEM768MLDSA65

    /// Every suite implemented, the default first.
    public static let supported: [MLSCipherSuite] = [
        .mls192MLKEM768MLDSA65, .mls128MLKEM768X25519, .mls128DHKEMX25519,
    ]

    /// The suite with this identifier, or `nil` if it is not one implemented here.
    public init?(identifier: UInt16) {
        guard let suite = Self.supported.first(where: { $0.identifier == identifier }) else { return nil }
        self = suite
    }

    /// The registered name.
    public var name: String {
        switch kem {
        case .x25519: "MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519"
        case .xWing: "MLS_128_MLKEM768X25519_AES128GCM_SHA256_Ed25519"
        case .mlKEM768: "MLS_192_MLKEM768_AES256GCM_SHA384_MLDSA65"
        }
    }

    public var description: String {
        "\(name) (0x\(String(identifier, radix: 16, uppercase: true)))"
    }

    /// Whether the KEM, and so every secret a commit or Welcome carries, is
    /// meant to resist a quantum computer.
    public var hasPostQuantumKEM: Bool { kem != .x25519 }

    /// Whether signatures, and so who a commit or key package says it is from,
    /// are meant to resist a quantum computer.
    public var hasPostQuantumSignatures: Bool { signer == .mlDSA65 }

    /// The protocol version, `mls10`.
    public static let version: UInt16 = 0x0001

    // MARK: - Hash, KDF and MAC

    /// Hash output length, `KDF.Nh`: 32 for SHA-256, 48 for SHA-384.
    public var hashLength: Int {
        switch symmetric {
        case .aes128SHA256: 32
        case .aes256SHA384: 48
        }
    }

    /// AEAD key length, `AEAD.Nk`: 16 for AES-128-GCM, 32 for AES-256-GCM.
    var aeadKeyLength: Int {
        switch symmetric {
        case .aes128SHA256: 16
        case .aes256SHA384: 32
        }
    }

    /// AEAD nonce length, `AEAD.Nn`, the same for both AES-GCM sizes.
    static let aeadNonceLength = 12

    func hash(_ data: Data) -> Data {
        switch symmetric {
        case .aes128SHA256: Data(SHA256.hash(data: data))
        case .aes256SHA384: Data(SHA384.hash(data: data))
        }
    }

    /// `KDF.Extract(salt, ikm)`.
    func extract(salt: Data, ikm: Data) -> Data {
        let ikm = SymmetricKey(data: ikm)
        switch symmetric {
        case .aes128SHA256: return Data(HKDF<SHA256>.extract(inputKeyMaterial: ikm, salt: salt))
        case .aes256SHA384: return Data(HKDF<SHA384>.extract(inputKeyMaterial: ikm, salt: salt))
        }
    }

    /// `KDF.Expand(secret, info, length)`.
    func expand(_ secret: Data, info: Data, length: Int) -> Data {
        let prk = SymmetricKey(data: secret)
        let key = switch symmetric {
        case .aes128SHA256: HKDF<SHA256>.expand(pseudoRandomKey: prk, info: info, outputByteCount: length)
        case .aes256SHA384: HKDF<SHA384>.expand(pseudoRandomKey: prk, info: info, outputByteCount: length)
        }
        return key.withUnsafeBytes { Data($0) }
    }

    /// `ExpandWithLabel`, RFC 9420 §5.1.3.
    func expandWithLabel(_ secret: Data, label: String, context: Data, length: Int) -> Data {
        var info = MLSWriter()
        info.uint16(UInt16(length))
        info.vector(Data("MLS 1.0 \(label)".utf8))
        info.vector(context)
        return expand(secret, info: info.bytes, length: length)
    }

    /// `DeriveSecret`, RFC 9420 §5.1.3.
    func deriveSecret(_ secret: Data, label: String) -> Data {
        expandWithLabel(secret, label: label, context: Data(), length: hashLength)
    }

    /// `DeriveSecret` with a label that is not UTF-8 text, for the exporter.
    func deriveSecret(_ secret: Data, rawLabel: Data) -> Data {
        var info = MLSWriter()
        info.uint16(UInt16(hashLength))
        info.vector(Data("MLS 1.0 ".utf8) + rawLabel)
        info.vector(Data())
        return expand(secret, info: info.bytes, length: hashLength)
    }

    /// `RefHash`, RFC 9420 §5.2.
    func refHash(label: String, value: Data) -> Data {
        var input = MLSWriter()
        input.vector(Data(label.utf8))
        input.vector(value)
        return hash(input.bytes)
    }

    /// `MAC`: HMAC with the suite's hash.
    func mac(key: Data, data: Data) -> Data {
        let key = SymmetricKey(data: key)
        switch symmetric {
        case .aes128SHA256: return Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
        case .aes256SHA384: return Data(HMAC<SHA384>.authenticationCode(for: data, using: key))
        }
    }

    /// A fresh secret of the hash's length, which is what a commit secret,
    /// an init secret and a path secret are.
    func randomSecret() -> Data { Self.randomSecret(hashLength) }

    // MARK: - Signatures

    /// A signature public key's length: 32 for Ed25519, 1952 for ML-DSA-65.
    public var signatureKeyLength: Int {
        switch signer {
        case .ed25519: 32
        case .mlDSA65: 1952
        }
    }

    /// A fresh signature key pair: the private half as this type stores it
    /// (Ed25519's 32-byte key, or ML-DSA-65's 32-byte FIPS 204 seed) and the
    /// public half as it travels.
    func generateSignatureKeyPair() throws(MLSError) -> (privateKey: Data, publicKey: Data) {
        switch signer {
        case .ed25519:
            let key = Curve25519.Signing.PrivateKey()
            return (key.rawRepresentation, key.publicKey.rawRepresentation)
        case .mlDSA65:
            do {
                let key = try MLDSA65.PrivateKey()
                return (key.seedRepresentation, key.publicKey.rawRepresentation)
            } catch {
                throw MLSError.cryptoFailure
            }
        }
    }

    private static func signContent(label: String, content: Data) -> Data {
        var tbs = MLSWriter()
        tbs.vector(Data("MLS 1.0 \(label)".utf8))
        tbs.vector(content)
        return tbs.bytes
    }

    /// `SignWithLabel`, RFC 9420 §5.1.2, with a private key as
    /// ``generateSignatureKeyPair()`` returns it.
    func signWithLabel(_ privateKey: Data, label: String, content: Data) throws(MLSError) -> Data {
        let message = Self.signContent(label: label, content: content)
        do {
            switch signer {
            case .ed25519:
                return try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey).signature(for: message)
            case .mlDSA65:
                return try MLDSA65.PrivateKey(seedRepresentation: privateKey, publicKey: nil)
                    .signature(for: message)
            }
        } catch {
            throw MLSError.cryptoFailure
        }
    }

    /// `VerifyWithLabel`, RFC 9420 §5.1.2.
    func verifyWithLabel(_ publicKey: Data, label: String, content: Data, signature: Data) -> Bool {
        guard publicKey.count == signatureKeyLength else { return false }
        let message = Self.signContent(label: label, content: content)
        switch signer {
        case .ed25519:
            guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
            return key.isValidSignature(signature, for: message)
        case .mlDSA65:
            guard let key = try? MLDSA65.PublicKey(rawRepresentation: publicKey) else { return false }
            return key.isValidSignature(signature, for: message)
        }
    }

    // MARK: - The KEM

    /// CryptoKit's HPKE suite, for the two KEMs CryptoKit implements. `nil`
    /// for pure ML-KEM-768, which ``MLKEMHPKE`` composes instead.
    var hpke: HPKE.Ciphersuite? {
        switch kem {
        case .x25519: HPKE.Ciphersuite(kem: .Curve25519_HKDF_SHA256, kdf: .HKDF_SHA256, aead: .AES_GCM_128)
        case .xWing: HPKE.Ciphersuite(kem: .XWingMLKEM768X25519, kdf: .HKDF_SHA256, aead: .AES_GCM_128)
        case .mlKEM768: nil
        }
    }

    /// `Npk`: an init key's or leaf encryption key's length. 32 for X25519,
    /// 1216 for X-Wing (ML-KEM-768's 1184 then X25519's 32), 1184 for
    /// ML-KEM-768.
    public var publicKeyLength: Int {
        switch kem {
        case .x25519: 32
        case .xWing: 1216
        case .mlKEM768: 1184
        }
    }

    /// `Nenc`: the KEM output in every HPKE ciphertext. 32 for X25519, 1120
    /// for X-Wing (ML-KEM-768's 1088 then X25519's 32), 1088 for ML-KEM-768.
    public var encapsulationLength: Int {
        switch kem {
        case .x25519: 32
        case .xWing: 1120
        case .mlKEM768: 1088
        }
    }

    /// A fresh KEM key pair: the private half as this type stores it (the
    /// X25519 scalar, X-Wing's 32-byte seed, or ML-KEM-768's 64-byte seed)
    /// and the public half as it travels.
    func generateKeyPair() throws(MLSError) -> (privateKey: Data, publicKey: Data) {
        do {
            switch kem {
            case .x25519:
                let key = Curve25519.KeyAgreement.PrivateKey()
                return (key.rawRepresentation, key.publicKey.rawRepresentation)
            case .xWing:
                let key = try XWingMLKEM768X25519.PrivateKey.generate()
                return (key.seedRepresentation, key.publicKey.rawRepresentation)
            case .mlKEM768:
                let key = try MLKEM768.PrivateKey.generate()
                return (key.seedRepresentation, key.publicKey.rawRepresentation)
            }
        } catch {
            throw MLSError.cryptoFailure
        }
    }

    private static func encryptContext(label: String, context: Data) -> Data {
        var info = MLSWriter()
        info.vector(Data("MLS 1.0 \(label)".utf8))
        info.vector(context)
        return info.bytes
    }

    /// `EncryptWithLabel`, RFC 9420 §5.1.3: HPKE base mode, empty AAD.
    func encryptWithLabel(
        _ publicKey: Data,
        label: String,
        context: Data,
        plaintext: Data
    ) throws(MLSError) -> HPKECiphertext {
        guard publicKey.count == publicKeyLength else { throw MLSError.malformed }
        let info = Self.encryptContext(label: label, context: context)
        do {
            var sender: HPKE.Sender
            switch kem {
            case .x25519:
                let recipient = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)
                sender = try HPKE.Sender(recipientKey: recipient, ciphersuite: hpke!, info: info)
            case .xWing:
                let recipient = try XWingMLKEM768X25519.PublicKey(rawRepresentation: publicKey)
                sender = try HPKE.Sender(recipientKey: recipient, ciphersuite: hpke!, info: info)
            case .mlKEM768:
                return try MLKEMHPKE.seal(to: publicKey, info: info, plaintext: plaintext)
            }
            let ciphertext = try sender.seal(plaintext, authenticating: Data())
            return HPKECiphertext(kemOutput: sender.encapsulatedKey, ciphertext: ciphertext)
        } catch {
            throw MLSError.cryptoFailure
        }
    }

    /// `DecryptWithLabel`, RFC 9420 §5.1.3, with a private key as
    /// ``generateKeyPair()`` returns it.
    func decryptWithLabel(
        _ privateKey: Data,
        label: String,
        context: Data,
        ciphertext: HPKECiphertext
    ) throws(MLSError) -> Data {
        guard ciphertext.kemOutput.count == encapsulationLength else { throw MLSError.decryptionFailed }
        let info = Self.encryptContext(label: label, context: context)
        do {
            var recipient: HPKE.Recipient
            switch kem {
            case .x25519:
                recipient = try HPKE.Recipient(
                    privateKey: try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey),
                    ciphersuite: hpke!, info: info, encapsulatedKey: ciphertext.kemOutput
                )
            case .xWing:
                recipient = try HPKE.Recipient(
                    privateKey: try XWingMLKEM768X25519.PrivateKey(seedRepresentation: privateKey, publicKey: nil),
                    ciphersuite: hpke!, info: info, encapsulatedKey: ciphertext.kemOutput
                )
            case .mlKEM768:
                return try MLKEMHPKE.open(ciphertext, seed: privateKey, info: info)
            }
            return try recipient.open(ciphertext.ciphertext, authenticating: Data())
        } catch {
            throw MLSError.decryptionFailed
        }
    }

    // MARK: - Symmetric

    // AES-GCM takes its size from the key, so these serve both AEADs.

    static func aeadSeal(key: Data, nonce: Data, plaintext: Data, aad: Data) throws(MLSError) -> Data {
        do {
            let box = try AES.GCM.seal(
                plaintext,
                using: SymmetricKey(data: key),
                nonce: AES.GCM.Nonce(data: nonce),
                authenticating: aad
            )
            return box.ciphertext + box.tag
        } catch {
            throw MLSError.cryptoFailure
        }
    }

    static func aeadOpen(key: Data, nonce: Data, ciphertext: Data, aad: Data) throws(MLSError) -> Data {
        guard ciphertext.count >= 16 else { throw MLSError.decryptionFailed }
        let split = ciphertext.index(ciphertext.endIndex, offsetBy: -16)
        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonce),
                ciphertext: ciphertext[..<split],
                tag: ciphertext[split...]
            )
            return try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: aad)
        } catch {
            throw MLSError.decryptionFailed
        }
    }

    static func randomSecret(_ count: Int) -> Data {
        SymmetricKey(size: SymmetricKeySize(bitCount: count * 8)).withUnsafeBytes { Data($0) }
    }
}

/// HPKE (RFC 9180) base mode for KEM 0x0041, KDF 0x0002, AEAD 0x0002:
/// ML-KEM-768, HKDF-SHA384, AES-256-GCM.
///
/// draft-ietf-hpke-pq-05 makes ML-KEM an HPKE KEM unchanged: `Encap` is
/// ML-KEM's encapsulation, the shared secret is ML-KEM's 32 bytes, and `enc`
/// is its 1088-byte ciphertext. What follows is RFC 9180 §5.1's key schedule
/// over that secret, for one message (sequence number 0), which is all
/// `EncryptWithLabel` sends.
enum MLKEMHPKE {
    /// `suite_id = "HPKE" || I2OSP(kem_id, 2) || I2OSP(kdf_id, 2) || I2OSP(aead_id, 2)`.
    private static let suiteID = Data("HPKE".utf8) + Data([0x00, 0x41, 0x00, 0x02, 0x00, 0x02])

    private static func labeledExtract(salt: Data, label: String, ikm: Data) -> Data {
        let labeled = Data("HPKE-v1".utf8) + suiteID + Data(label.utf8) + ikm
        return Data(HKDF<SHA384>.extract(inputKeyMaterial: SymmetricKey(data: labeled), salt: salt))
    }

    private static func labeledExpand(_ prk: Data, label: String, info: Data, length: Int) -> Data {
        let labeled = Data([UInt8(length >> 8), UInt8(length & 0xFF)])
            + Data("HPKE-v1".utf8) + suiteID + Data(label.utf8) + info
        return HKDF<SHA384>.expand(
            pseudoRandomKey: SymmetricKey(data: prk), info: labeled, outputByteCount: length
        ).withUnsafeBytes { Data($0) }
    }

    /// `KeySchedule(mode_base, shared_secret, info, "", "")`: the key and base nonce.
    static func keySchedule(sharedSecret: Data, info: Data) -> (key: Data, nonce: Data) {
        let pskIDHash = labeledExtract(salt: Data(), label: "psk_id_hash", ikm: Data())
        let infoHash = labeledExtract(salt: Data(), label: "info_hash", ikm: info)
        let context = Data([0x00]) + pskIDHash + infoHash
        let secret = labeledExtract(salt: sharedSecret, label: "secret", ikm: Data())
        return (
            labeledExpand(secret, label: "key", info: context, length: 32),
            labeledExpand(secret, label: "base_nonce", info: context, length: MLSCipherSuite.aeadNonceLength)
        )
    }

    static func seal(to publicKey: Data, info: Data, plaintext: Data) throws -> HPKECiphertext {
        let encapsulation = try MLKEM768.PublicKey(rawRepresentation: publicKey).encapsulate()
        let shared = encapsulation.sharedSecret.withUnsafeBytes { Data($0) }
        let (key, nonce) = keySchedule(sharedSecret: shared, info: info)
        let ciphertext = try MLSCipherSuite.aeadSeal(key: key, nonce: nonce, plaintext: plaintext, aad: Data())
        return HPKECiphertext(kemOutput: encapsulation.encapsulated, ciphertext: ciphertext)
    }

    static func open(_ ciphertext: HPKECiphertext, seed: Data, info: Data) throws -> Data {
        let key = try MLKEM768.PrivateKey(seedRepresentation: seed, publicKey: nil)
        let shared = try key.decapsulate(ciphertext.kemOutput).withUnsafeBytes { Data($0) }
        let schedule = keySchedule(sharedSecret: shared, info: info)
        return try MLSCipherSuite.aeadOpen(
            key: schedule.key, nonce: schedule.nonce, ciphertext: ciphertext.ciphertext, aad: Data()
        )
    }
}

/// `HPKECiphertext`, RFC 9420 §5.1.3.
public struct HPKECiphertext: Hashable, Sendable {
    public let kemOutput: Data
    public let ciphertext: Data

    func write(to writer: inout MLSWriter) {
        writer.vector(kemOutput)
        writer.vector(ciphertext)
    }

    static func read(from reader: inout MLSReader) throws(MLSError) -> HPKECiphertext {
        HPKECiphertext(kemOutput: try reader.vector(), ciphertext: try reader.vector())
    }
}

/// What went wrong in group key management.
public enum MLSError: Error, Hashable, Sendable {
    /// Bytes that do not parse.
    case malformed
    /// A signature did not verify.
    case badSignature
    /// A confirmation tag or membership check did not match.
    case confirmationMismatch
    /// HPKE or AEAD refused to open something.
    case decryptionFailed
    /// A primitive failed where it should not be able to.
    case cryptoFailure
    /// A message for a different group or epoch than the one held.
    case wrongEpoch(expected: UInt64, got: UInt64)
    case wrongGroup
    /// A proposal names a member that is not there, or adds one twice.
    case invalidProposal
    /// The message is from someone who is not a member.
    case unknownSender
    /// This member has been removed and can no longer follow the group.
    case removed
    /// Nothing in the message was addressed to this member.
    case notAddressed
    /// The cipher suite or version is not one implemented.
    case unsupported
    /// A key package or Welcome in a different cipher suite from the group's.
    /// A group never mixes suites: a device in another suite publishes new key
    /// packages in the group's before it can be added.
    case cipherSuiteMismatch(group: UInt16, other: UInt16)
}

// MARK: - Encoding

/// The TLS presentation language as RFC 9420 §2.1 uses it: big-endian
/// integers and vectors prefixed with the RFC's variable-length size.
struct MLSWriter {
    private(set) var bytes = Data()

    mutating func uint8(_ value: UInt8) { bytes.append(value) }

    mutating func uint16(_ value: UInt16) {
        bytes.append(contentsOf: withUnsafeBytes(of: value.bigEndian) { Array($0) })
    }

    mutating func uint32(_ value: UInt32) {
        bytes.append(contentsOf: withUnsafeBytes(of: value.bigEndian) { Array($0) })
    }

    mutating func uint64(_ value: UInt64) {
        bytes.append(contentsOf: withUnsafeBytes(of: value.bigEndian) { Array($0) })
    }

    /// RFC 9420 §2.1.2: one, two or four bytes, the top two bits giving which.
    mutating func length(_ count: Int) {
        precondition(count < 1 << 30, "MLS vectors are limited to 2^30 bytes")
        if count < 1 << 6 {
            uint8(UInt8(count))
        } else if count < 1 << 14 {
            uint16(UInt16(count) | 0x4000)
        } else {
            uint32(UInt32(count) | 0x8000_0000)
        }
    }

    mutating func vector(_ data: Data) {
        length(data.count)
        bytes.append(data)
    }

    mutating func raw(_ data: Data) { bytes.append(data) }
}

struct MLSReader {
    private let data: Data
    private var offset: Data.Index

    init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    var isAtEnd: Bool { offset == data.endIndex }

    private mutating func take(_ count: Int) throws(MLSError) -> Data {
        guard count >= 0, data.endIndex - offset >= count else { throw MLSError.malformed }
        let slice = data[offset ..< offset + count]
        offset += count
        return Data(slice)
    }

    mutating func uint8() throws(MLSError) -> UInt8 {
        try take(1).first!
    }

    mutating func uint16() throws(MLSError) -> UInt16 {
        try take(2).reduce(0) { ($0 << 8) | UInt16($1) }
    }

    mutating func uint32() throws(MLSError) -> UInt32 {
        try take(4).reduce(0) { ($0 << 8) | UInt32($1) }
    }

    mutating func uint64() throws(MLSError) -> UInt64 {
        try take(8).reduce(0) { ($0 << 8) | UInt64($1) }
    }

    mutating func length() throws(MLSError) -> Int {
        let first = try uint8()
        switch first >> 6 {
        case 0:
            return Int(first)
        case 1:
            let second = try uint8()
            let value = (Int(first & 0x3F) << 8) | Int(second)
            // Minimum-length encoding is required by the RFC.
            guard value >= 1 << 6 else { throw MLSError.malformed }
            return value
        case 2:
            let rest = try take(3)
            let value = rest.reduce(Int(first & 0x3F)) { ($0 << 8) | Int($1) }
            guard value >= 1 << 14 else { throw MLSError.malformed }
            return value
        default:
            throw MLSError.malformed
        }
    }

    mutating func vector() throws(MLSError) -> Data {
        try take(try length())
    }

    mutating func finish() throws(MLSError) {
        guard isAtEnd else { throw MLSError.malformed }
    }

    /// The suite a structure names, refusing one not implemented.
    mutating func cipherSuite() throws(MLSError) -> MLSCipherSuite {
        guard try uint16() == MLSCipherSuite.version,
              let suite = MLSCipherSuite(identifier: try uint16())
        else { throw MLSError.unsupported }
        return suite
    }
}
