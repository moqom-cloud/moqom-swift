// The key that makes a stolen token worthless.
//
// A token names a device in its `cnf.jkt` claim. Until this file existed that
// was a label rather than a check on the client side too: the SDK passed a
// constant string where a thumbprint belonged, so the claim named something no
// key could answer for and possession of the token was the whole of
// authorisation. Anything that could read the token — a Keychain dump, a log, a
// pasted shell variable, a compromised backend — could use it from anywhere
// until it expired.
//
// What closes that is a signature from a key the device cannot export, made
// over the token it accompanies. The relay checks it in `possession.rs`; this is
// the other half.
//
// # Why the Secure Enclave, and why there is a fallback at all
//
// The enclave is the only storage on these devices where "cannot be exported" is
// enforced by hardware rather than by policy. A key generated there never has a
// representation the CPU can read, so the blob this file persists is useless on
// any other device — which is exactly the property that makes the token not
// worth stealing.
//
// It is not always there. The simulator has none, and a key that cannot be
// created at all would mean the SDK could not run where most of its tests do. So
// there is a software fallback, and the important thing about it is that it is
// *recorded*: ``DeviceKey/storage`` says which one answered, the join flow logs
// it, and a deployment that thinks it is enforcing hardware-backed possession
// can tell whether it actually is. A silent fallback would be the same code with
// none of the guarantee and no way to notice.
//
// # ML-DSA-87 only
//
// ML-DSA-87, because the enclave holds it from the 26 releases and a device key
// outlives every token bound to it: a key made today is one a quantum attacker
// would be forging proofs for years from now. Nothing accepts an ES256 or an
// ML-DSA-65 proof, so a P-256 or ML-DSA-65 key left by an older build is
// replaced, and the device signs in again under its new thumbprint.
//
// `CryptoKit` offers Ed25519, it verifies quickly, and it holds its private key
// in ordinary memory — where it can be dumped alongside the token by precisely
// the attacker this exists to stop. A faster check of a weaker claim is not a
// saving. The relay pins the same choice for the same reason.
//
// The proof format and its check are `MoqomProof`'s, shared with the relay and
// the control plane, so this file decides where the key lives and nothing about
// what a proof looks like.

import CryptoKit
import Foundation
import MoqomCore
import MoqomProof
import Security

/// Why a device key could not be produced or used.
public enum DeviceKeyError: Error, Sendable {
    /// The Keychain refused to store or return the key material.
    case keychain(OSStatus)

    /// Neither the Secure Enclave nor a software key could be created.
    case notCreated

    /// Something was stored under this label, but it is not a key.
    case corrupt

    /// The key exists and refused to sign, or the certificate it was asked to
    /// bind a proof to is not a base64url digest.
    case notSigned
}

/// The non-exportable key this installation is identified by.
///
/// One per install. It outlives every token, because a token is bound to it: the
/// control plane puts this key's thumbprint in `cnf.jkt` and the relay refuses a
/// session that cannot sign for it.
public struct DeviceKey: Sendable {
    /// Where the private half actually lives.
    ///
    /// Worth surfacing rather than hiding, for the reason the file note gives: a
    /// software key satisfies every check in this file and none of the promise.
    public enum Storage: String, Sendable, CustomStringConvertible {
        /// Hardware. The key has no representation outside the enclave, so the
        /// blob on disk is worthless anywhere else.
        case secureEnclave

        /// Software. ``installed(label:)`` keeps it in the Keychain, marked
        /// this-device-only, which is the best available and is not the same
        /// promise: anything that can read the Keychain item has the key.
        case software

        public var description: String {
            switch self {
            case .secureEnclave: "Secure Enclave"
            case .software: "software key"
            }
        }
    }

    private let prover: Prover

    public let storage: Storage

    /// The RFC 7638 thumbprint of the public half, base64url, untruncated.
    ///
    /// What a token's `cnf.jkt` must equal, and what ``DeviceID`` is a prefix
    /// of. Computed once here rather than at each use so that the value on
    /// screen, the value in the namespace and the value the relay compares
    /// against cannot drift apart.
    public let thumbprint: String

    private init(_ key: Prover.Key, storage: Storage) {
        prover = Prover(key)
        self.storage = storage
        thumbprint = prover.thumbprint
    }

    /// What this key signs with: ML-DSA-87.
    public var algorithm: ProofAlgorithm { prover.algorithm }

    /// The public key as a JWK: `AKP` with `alg` ML-DSA-87.
    ///
    /// What the control plane is given at join so it can derive `cnf.jkt`
    /// itself. It derives rather than accepts: a thumbprint supplied by the
    /// client is a claim about which key it holds, and the whole point is not to
    /// take that on trust.
    public var jwk: ProofJWK { prover.jwk }

    /// ``jwk`` in RFC 7638 canonical form: the exact bytes the thumbprint is
    /// the hash of.
    public var publicKeyJWK: String { (try? prover.jwk.canonical()) ?? "" }

    // MARK: - Installing

    /// The default Keychain label, namespaced so an app can hold others.
    public static let defaultLabel = "cloud.moqom.device-key"

    /// The key this installation already has, or a new one stored under `label`.
    ///
    /// Idempotent, and it has to be: the thumbprint is the device's identity, so
    /// a call that generated a fresh key whenever it was convenient would give
    /// the device a new name and orphan every token issued to the old one. The
    /// one exception is a P-256 or ML-DSA-65 key from an older build, which
    /// nothing accepts a proof from any more.
    ///
    /// - Throws: ``DeviceKeyError`` when no key can be created or read back. Not
    ///   recoverable by retrying — a device that cannot hold a key cannot prove
    ///   possession, and the caller's choice is to run unproven or not at all.
    public static func installed(label: String = defaultLabel) throws(DeviceKeyError) -> DeviceKey {
        if let stored = try load(label: label) { return stored }
        forget(label: label)
        return try create(label: label)
    }

    /// A key held only for as long as the caller holds it.
    ///
    /// For tests and for a caller that wants possession within one session
    /// without leaving anything behind. Always software: the enclave's value is
    /// in surviving, and a key that is discarded has nothing to survive.
    public static func ephemeral(_ algorithm: ProofAlgorithm = .mlDSA87) -> DeviceKey {
        switch algorithm {
        case .mlDSA87:
            // Software ML-DSA key generation fails only if the system CSPRNG
            // does, and nothing can run without that.
            DeviceKey(.mlDSA87(try! MLDSA87.PrivateKey()), storage: .software)
        }
    }

    /// A key from material the caller already holds: a 32-byte ML-DSA-87 seed.
    ///
    /// Deliberately not public. Anything that can supply key material has
    /// already given up the property the enclave exists to provide, so the only
    /// legitimate caller is the interop fixture — which has to name the same
    /// device on every regeneration, or its diff would be noise instead of a
    /// signal that an encoding changed.
    ///
    /// - Throws: ``DeviceKeyError/corrupt`` if the material is not a valid key.
    static func material(_ raw: Data, algorithm: ProofAlgorithm = .mlDSA87) throws(DeviceKeyError) -> DeviceKey {
        switch algorithm {
        case .mlDSA87:
            guard let key = try? MLDSA87.PrivateKey(seedRepresentation: raw, publicKey: nil) else {
                throw .corrupt
            }
            return DeviceKey(.mlDSA87(key), storage: .software)
        }
    }

    private static func create(label: String) throws(DeviceKeyError) -> DeviceKey {
        // `SecureEnclave.isAvailable` answers for the hardware and not for this
        // process's entitlements, so the generation attempt is the real test and
        // the fallback is chosen by what actually failed.
        if SecureEnclave.isAvailable,
           let enclave = try? SecureEnclave.MLDSA87.PrivateKey(accessControl: accessControl()) {
            try store(enclave.dataRepresentation, label: label, tag: .secureEnclaveMLDSA87)
            return DeviceKey(.secureEnclaveMLDSA87(enclave), storage: .secureEnclave)
        }

        guard let software = try? MLDSA87.PrivateKey() else { throw .notCreated }
        try store(software.seedRepresentation, label: label, tag: .softwareMLDSA87)
        return DeviceKey(.mlDSA87(software), storage: .software)
    }

    /// The access policy for both kinds of stored key.
    ///
    /// `AfterFirstUnlockThisDeviceOnly`, and each half of that is load-bearing.
    /// `ThisDeviceOnly` keeps the key out of a backup and out of iCloud
    /// Keychain, without which "the device holds a key nobody can copy" would be
    /// false by restore. `AfterFirstUnlock` rather than `WhenUnlocked` because a
    /// session renews its credential while the phone is in a pocket, and a proof
    /// that could not be signed then would end the call at the lock screen.
    ///
    /// No biometric requirement. A prompt on every renewal would be a prompt in
    /// the middle of a call, and the property being defended is that the key
    /// cannot leave the device — not that a person is watching each use of it.
    private static func accessControl() -> SecAccessControl {
        // Force-unwrapped because the arguments are constants: this cannot fail
        // for reasons that vary at runtime, and a throwing path here would be
        // one nothing could ever take.
        SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            [],
            nil
        )!
    }

    // MARK: - Persistence

    /// The stored form: one byte saying which kind, then the material.
    ///
    /// Tagged rather than inferred from length, because an enclave blob and a
    /// raw key are both just bytes and guessing wrong means handing the
    /// enclave's ciphertext to the software initialiser and calling the result
    /// corrupt. 1 and 2 were P-256 keys and 3 and 4 ML-DSA-65 keys, from
    /// before ML-DSA-87; ``load(label:)`` reads them as no key, so
    /// ``installed(label:)`` makes a new one.
    private enum Tag: UInt8 {
        case retiredSecureEnclaveES256 = 1
        case retiredSoftwareES256 = 2
        case retiredSecureEnclaveMLDSA65 = 3
        case retiredSoftwareMLDSA65 = 4
        case secureEnclaveMLDSA87 = 5
        case softwareMLDSA87 = 6
    }

    private static func query(label: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "cloud.moqom.device-key",
            kSecAttrAccount as String: label,
        ]
    }

    private static func store(
        _ material: Data,
        label: String,
        tag: Tag
    ) throws(DeviceKeyError) {
        var item = query(label: label)
        item[kSecValueData as String] = Data([tag.rawValue]) + material
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        SecItemDelete(query(label: label) as CFDictionary)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw DeviceKeyError.keychain(status) }
    }

    private static func load(label: String) throws(DeviceKeyError) -> DeviceKey? {
        var item = query(label: label)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let stored = result as? Data, let first = stored.first else {
            throw DeviceKeyError.keychain(status)
        }

        let material = Data(stored.dropFirst())
        let key: DeviceKey?
        switch Tag(rawValue: first) {
        case .secureEnclaveMLDSA87:
            key = (try? SecureEnclave.MLDSA87.PrivateKey(dataRepresentation: material))
                .map { DeviceKey(.secureEnclaveMLDSA87($0), storage: .secureEnclave) }
        case .softwareMLDSA87:
            key = (try? MLDSA87.PrivateKey(seedRepresentation: material, publicKey: nil))
                .map { DeviceKey(.mlDSA87($0), storage: .software) }
        case .retiredSecureEnclaveES256, .retiredSoftwareES256,
             .retiredSecureEnclaveMLDSA65, .retiredSoftwareMLDSA65:
            return nil
        case nil:
            key = nil
        }
        guard let key else { throw DeviceKeyError.corrupt }
        return key
    }

    /// Forget the stored key.
    ///
    /// The device gets a new identity next time one is installed, and every
    /// token bound to the old thumbprint becomes unusable — which is the point
    /// on a signed-out or wiped install, and a mistake anywhere else.
    public static func forget(label: String = defaultLabel) {
        SecItemDelete(query(label: label) as CFDictionary)
    }

    // MARK: - Proving

    /// A proof that this key holds `token`, for the relay identified by `relay`.
    ///
    /// A `MoqomProof` proof: a compact JWS committing to the token by hash, to
    /// the relay's certificate, to a fresh single-use identifier and to the time
    /// it was made. The freshness argument is the relay's to make and is written
    /// out in `possession.rs`; there is no round trip spent fetching a nonce
    /// before a client that speaks first can speak.
    ///
    /// - Parameter relay: base64url SHA-256 of the relay's leaf certificate.
    ///   Empty where the carrier could not see one, which a relay that knows its
    ///   own certificate will refuse — deliberately. A proof that omitted the
    ///   binding would be replayable by any relay it was presented to, and the
    ///   attack the binding answers is a compromised relay in a fleet of them.
    ///
    /// - Throws: ``DeviceKeyError/notSigned`` if the key refuses, which an
    ///   enclave can for reasons outside this process, or if `relay` is not
    ///   base64url.
    public func proof(over token: Data, for relay: String, at now: Date = Date()) throws(DeviceKeyError) -> Data {
        guard let certificate = Data(base64URLEncoded: relay) else { throw .notSigned }
        do {
            return try prover.prove(token: token, certificateHash: certificate, nonce: Prover.nonce(), issuedAt: now)
        } catch {
            throw .notSigned
        }
    }
}

extension DataProtocol {
    /// base64url without padding, per RFC 4648 §5.
    ///
    /// The encoding every value in a JWS uses, and not the one
    /// `base64EncodedString()` produces. The difference is three characters, all
    /// of which matter: `+` and `/` are not URL-safe and `=` is padding a JWS
    /// forbids, so a token, thumbprint or coordinate spelled the standard way is
    /// a value the relay decodes to something else or refuses outright.
    var base64URLEncodedString: String {
        Data(self).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
