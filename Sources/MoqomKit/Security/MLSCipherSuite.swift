// The RFC 9420 primitives MOQOM's group key management is built from.
//
// One cipher suite, MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519 (0x0001), the
// one every MLS implementation must support. Each function here is the RFC's
// definition and nothing more, and each is checked against the MLS working
// group's published test vectors (`crypto-basics.json`), which is the only
// basis on which this file claims to match the RFC. What is built on top of
// these primitives is MOQOM's own and is described in `MLSGroup.swift`.
//
// Everything is CryptoKit. HPKE (RFC 9180) is CryptoKit's, composed from the
// KEM, KDF and AEAD this suite names; there is no hand-rolled cryptography
// below this line, only encodings.

import CryptoKit
import Foundation

/// The single MLS cipher suite implemented.
public enum MLSCipherSuite {
    /// `MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519`.
    public static let identifier: UInt16 = 0x0001

    /// The protocol version, `mls10`.
    public static let version: UInt16 = 0x0001

    /// Hash output length, `KDF.Nh`.
    public static let hashLength = 32

    /// AEAD key and nonce lengths for AES-128-GCM.
    static let aeadKeyLength = 16
    static let aeadNonceLength = 12

    static let hpke = HPKE.Ciphersuite(
        kem: .Curve25519_HKDF_SHA256,
        kdf: .HKDF_SHA256,
        aead: .AES_GCM_128
    )

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

    /// `MAC`, which for this suite is HMAC-SHA256.
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

    // MARK: - Public-key encryption

    private static func encryptContext(label: String, context: Data) -> Data {
        var info = MLSWriter()
        info.vector(Data("MLS 1.0 \(label)".utf8))
        info.vector(context)
        return info.bytes
    }

    /// `EncryptWithLabel`, RFC 9420 §5.1.3: HPKE base mode, empty AAD.
    static func encryptWithLabel(
        _ publicKey: Data,
        label: String,
        context: Data,
        plaintext: Data
    ) throws(MLSError) -> HPKECiphertext {
        do {
            let recipient = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)
            var sender = try HPKE.Sender(
                recipientKey: recipient,
                ciphersuite: hpke,
                info: encryptContext(label: label, context: context)
            )
            let ciphertext = try sender.seal(plaintext, authenticating: Data())
            return HPKECiphertext(kemOutput: sender.encapsulatedKey, ciphertext: ciphertext)
        } catch {
            throw MLSError.cryptoFailure
        }
    }

    /// `DecryptWithLabel`, RFC 9420 §5.1.3.
    static func decryptWithLabel(
        _ privateKey: Curve25519.KeyAgreement.PrivateKey,
        label: String,
        context: Data,
        ciphertext: HPKECiphertext
    ) throws(MLSError) -> Data {
        do {
            var recipient = try HPKE.Recipient(
                privateKey: privateKey,
                ciphersuite: hpke,
                info: encryptContext(label: label, context: context),
                encapsulatedKey: ciphertext.kemOutput
            )
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
    /// The cipher suite or version is not the one implemented.
    case unsupported
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
}
