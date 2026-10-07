// The RFC 9420 primitives MOQOM's group key management is built from.
//
// Two cipher suites, which differ only in their KEM:
//
// - `MLS_128_MLKEM768X25519_AES128GCM_SHA256_Ed25519`, the default for every
//   group founded by this SDK. draft-ietf-mls-pq-ciphersuites-06 §3.1 defines
//   it as its first suite (HPKE KEM 0x647a, which draft-ietf-hpke-pq-05 names
//   MLKEM768-X25519 and which is the X-Wing KEM of
//   draft-connolly-cfrg-xwing-kem; HKDF-SHA256; AES-128-GCM; Ed25519). The
//   draft's value is still "TBD1", so the identifier below is one from RFC 9420
//   §17.1's private-use range and has to change to the IANA value once one is
//   assigned. A peer that implements the draft would not recognise it.
// - `MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519` (0x0001), the one every MLS
//   implementation must support, kept so that groups founded with it still
//   work.
//
// Everything a group derives — the key schedule, the exporter, and so SFrame
// keys — depends on the hash, KDF and AEAD, which are the same in both, and on
// the secrets the KEM carries, which is the only place the suites differ. The
// hybrid KEM is what makes those secrets post-quantum: a commit secret or a
// joiner secret sealed to X-Wing stays secret unless both ML-KEM-768 and
// X25519 are broken. Signatures are Ed25519 in both, as the draft's suite
// specifies; they authenticate members and are not post-quantum.
//
// Each function here is the RFC's definition and nothing more. Suite 0x0001 is
// checked against the MLS working group's published test vectors
// (`crypto-basics.json`); the hybrid KEM inside HPKE is checked against the
// HPKE working group's vectors for KEM 0x647a (draft-ietf-hpke-pq), which is
// the only basis on which this file claims to match either draft. What is
// built on top of these primitives is MOQOM's own and is described in
// `MLSGroup.swift`.
//
// Everything is CryptoKit. HPKE (RFC 9180) is CryptoKit's, composed from the
// KEM, KDF and AEAD each suite names; there is no hand-rolled cryptography
// below this line, only encodings.

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

    private enum KEM: Hashable, Sendable {
        case x25519
        case xWing
    }

    private init(identifier: UInt16, kem: KEM) {
        self.identifier = identifier
        self.kem = kem
    }

    /// `MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519`, RFC 9420's mandatory suite.
    public static let mls128DHKEMX25519 = MLSCipherSuite(identifier: 0x0001, kem: .x25519)

    /// `MLS_128_MLKEM768X25519_AES128GCM_SHA256_Ed25519`, draft-ietf-mls-pq-ciphersuites' "TBD1".
    ///
    /// 0xF0A1 is a private-use value (RFC 9420 §17.1), standing in until IANA
    /// assigns one. Only MOQOM's own SDK and control plane know it.
    public static let mls128MLKEM768X25519 = MLSCipherSuite(identifier: 0xF0A1, kem: .xWing)

    /// The suite a newly founded group uses.
    public static let `default` = mls128MLKEM768X25519

    /// Every suite implemented, the default first.
    public static let supported: [MLSCipherSuite] = [.mls128MLKEM768X25519, .mls128DHKEMX25519]

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
        }
    }

    public var description: String {
        "\(name) (0x\(String(identifier, radix: 16, uppercase: true)))"
    }

    /// Whether the KEM, and so every secret a commit or Welcome carries, is
    /// meant to resist a quantum computer. Signatures are classical either way.
    public var hasPostQuantumKEM: Bool { kem == .xWing }

    /// The protocol version, `mls10`.
    public static let version: UInt16 = 0x0001

    // MARK: - Shared by both suites

    // HKDF-SHA256, HMAC-SHA256, AES-128-GCM and Ed25519 are the same in every
    // suite implemented, so they are not per-suite. A suite that differed in
    // any of them would have to move them onto the value.

    /// Hash output length, `KDF.Nh`.
    public static let hashLength = 32

    /// AEAD key and nonce lengths for AES-128-GCM.
    static let aeadKeyLength = 16
    static let aeadNonceLength = 12

    /// Ed25519 public key length.
    static let signatureKeyLength = 32

    static func hash(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    /// `KDF.Extract(salt, ikm)`.
    static func extract(salt: Data, ikm: Data) -> Data {
        let prk = HKDF<SHA256>.extract(inputKeyMaterial: SymmetricKey(data: ikm), salt: salt)
        return Data(prk)
    }

    /// `KDF.Expand(secret, info, length)`.
    static func expand(_ secret: Data, info: Data, length: Int) -> Data {
        HKDF<SHA256>.expand(
            pseudoRandomKey: SymmetricKey(data: secret),
            info: info,
            outputByteCount: length
        ).withUnsafeBytes { Data($0) }
    }

    /// `ExpandWithLabel`, RFC 9420 §5.1.3.
    static func expandWithLabel(_ secret: Data, label: String, context: Data, length: Int) -> Data {
        var info = MLSWriter()
        info.uint16(UInt16(length))
        info.vector(Data("MLS 1.0 \(label)".utf8))
        info.vector(context)
        return expand(secret, info: info.bytes, length: length)
    }

    /// `DeriveSecret`, RFC 9420 §5.1.3.
    static func deriveSecret(_ secret: Data, label: String) -> Data {
        expandWithLabel(secret, label: label, context: Data(), length: hashLength)
    }

    /// `DeriveSecret` with a label that is not UTF-8 text, for the exporter.
    static func deriveSecret(_ secret: Data, rawLabel: Data) -> Data {
        var info = MLSWriter()
        info.uint16(UInt16(hashLength))
        info.vector(Data("MLS 1.0 ".utf8) + rawLabel)
        info.vector(Data())
        return expand(secret, info: info.bytes, length: hashLength)
    }

    /// `RefHash`, RFC 9420 §5.2.
    static func refHash(label: String, value: Data) -> Data {
        var input = MLSWriter()
        input.vector(Data(label.utf8))
        input.vector(value)
        return hash(input.bytes)
    }

    /// `MAC`, which for both suites is HMAC-SHA256.
    static func mac(key: Data, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    // MARK: - Signatures

    private static func signContent(label: String, content: Data) -> Data {
        var tbs = MLSWriter()
        tbs.vector(Data("MLS 1.0 \(label)".utf8))
        tbs.vector(content)
        return tbs.bytes
    }

    /// `SignWithLabel`, RFC 9420 §5.1.2.
    static func signWithLabel(
        _ key: Curve25519.Signing.PrivateKey,
        label: String,
        content: Data
    ) throws(MLSError) -> Data {
        do {
            return try key.signature(for: signContent(label: label, content: content))
        } catch {
            throw MLSError.cryptoFailure
        }
    }

    /// `VerifyWithLabel`, RFC 9420 §5.1.2.
    static func verifyWithLabel(
        _ publicKey: Data,
        label: String,
        content: Data,
        signature: Data
    ) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else {
            return false
        }
        return key.isValidSignature(signature, for: signContent(label: label, content: content))
    }

    // MARK: - Per suite: the KEM

    /// The HPKE suite `EncryptWithLabel` uses.
    var hpke: HPKE.Ciphersuite {
        switch kem {
        case .x25519: HPKE.Ciphersuite(kem: .Curve25519_HKDF_SHA256, kdf: .HKDF_SHA256, aead: .AES_GCM_128)
        case .xWing: HPKE.Ciphersuite(kem: .XWingMLKEM768X25519, kdf: .HKDF_SHA256, aead: .AES_GCM_128)
        }
    }

    /// `Npk`: an init key's or leaf encryption key's length. 32 for X25519,
    /// 1216 for X-Wing (ML-KEM-768's 1184 then X25519's 32).
    public var publicKeyLength: Int {
        switch kem {
        case .x25519: 32
        case .xWing: 1216
        }
    }

    /// `Nenc`: the KEM output in every HPKE ciphertext. 32 for X25519, 1120
    /// for X-Wing (ML-KEM-768's 1088 then X25519's 32).
    public var encapsulationLength: Int {
        switch kem {
        case .x25519: 32
        case .xWing: 1120
        }
    }

    /// A fresh KEM key pair: the private half as this type stores it (the
    /// X25519 scalar, or X-Wing's 32-byte seed) and the public half as it
    /// travels.
    func generateKeyPair() throws(MLSError) -> (privateKey: Data, publicKey: Data) {
        switch kem {
        case .x25519:
            let key = Curve25519.KeyAgreement.PrivateKey()
            return (key.rawRepresentation, key.publicKey.rawRepresentation)
        case .xWing:
            do {
                let key = try XWingMLKEM768X25519.PrivateKey.generate()
                return (key.seedRepresentation, key.publicKey.rawRepresentation)
            } catch {
                throw MLSError.cryptoFailure
            }
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
                sender = try HPKE.Sender(recipientKey: recipient, ciphersuite: hpke, info: info)
            case .xWing:
                let recipient = try XWingMLKEM768X25519.PublicKey(rawRepresentation: publicKey)
                sender = try HPKE.Sender(recipientKey: recipient, ciphersuite: hpke, info: info)
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
                    ciphersuite: hpke, info: info, encapsulatedKey: ciphertext.kemOutput
                )
            case .xWing:
                recipient = try HPKE.Recipient(
                    privateKey: try XWingMLKEM768X25519.PrivateKey(seedRepresentation: privateKey, publicKey: nil),
                    ciphersuite: hpke, info: info, encapsulatedKey: ciphertext.kemOutput
                )
            }
            return try recipient.open(ciphertext.ciphertext, authenticating: Data())
        } catch {
            throw MLSError.decryptionFailed
        }
    }

    // MARK: - Symmetric

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

    static func randomSecret(_ count: Int = hashLength) -> Data {
        SymmetricKey(size: SymmetricKeySize(bitCount: count * 8)).withUnsafeBytes { Data($0) }
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
