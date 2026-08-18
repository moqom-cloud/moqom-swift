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
// # ES256, which is not the fastest thing available
//
// P-256 with SHA-256, because the enclave does P-256 and nothing else.
// `CryptoKit` offers Ed25519, it verifies about twice as quickly, and it holds
// its private key in ordinary memory — where it can be dumped alongside the
// token by precisely the attacker this exists to stop. A faster check of a
// weaker claim is not a saving. The relay pins the same choice for the same
// reason.

import CryptoKit
import Foundation
import MoqomCore
import Security

/// Why a device key could not be produced or used.
public enum DeviceKeyError: Error, Sendable {
    /// The Keychain refused to store or return the key material.
    case keychain(OSStatus)

    /// Neither the Secure Enclave nor a software key could be created.
    case notCreated

    /// Something was stored under this label, but it is not a key.
    case corrupt

    /// The key exists and refused to sign.
    case notSigned
}

/// The non-exportable P-256 key this installation is identified by.
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

    /// The two key types have no common protocol worth naming — one signs in
    /// hardware and one in software, and that is the entire difference — so this
    /// is an enum rather than an existential.
    private enum Held: Sendable {
        case enclave(SecureEnclave.P256.Signing.PrivateKey)
        case software(P256.Signing.PrivateKey)
    }

    private let held: Held

    public let storage: Storage

    /// The `x` coordinate, base64url, as a JWK carries it.
    public let x: String

    /// The `y` coordinate, base64url.
    public let y: String

    /// The RFC 7638 thumbprint of the public half, base64url, untruncated.
    ///
    /// What a token's `cnf.jkt` must equal, and what ``DeviceID`` is a prefix
    /// of. Computed once here rather than at each use so that the value on
    /// screen, the value in the namespace and the value the relay compares
    /// against cannot drift apart.
    public let thumbprint: String

    private init(held: Held, storage: Storage, publicKey: P256.Signing.PublicKey) {
        self.held = held
        self.storage = storage

        // `rawRepresentation` is the two coordinates and nothing else, in the
        // order and the fixed width the curve defines, which is what a JWK
        // wants. The x9.63 form would need its leading 0x04 stripped and gives
        // no benefit here.
        let raw = publicKey.rawRepresentation
        x = raw.prefix(32).base64URLEncodedString
        y = raw.suffix(32).base64URLEncodedString
        thumbprint = Self.thumbprint(x: x, y: y)
    }

    // MARK: - Installing

    /// The default Keychain label, namespaced so an app can hold others.
    public static let defaultLabel = "cloud.moqom.device-key"

    /// The key this installation already has, or a new one stored under `label`.
    ///
    /// Idempotent, and it has to be: the thumbprint is the device's identity, so
    /// a call that generated a fresh key whenever it was convenient would give
    /// the device a new name and orphan every token issued to the old one.
    ///
    /// - Throws: ``DeviceKeyError`` when no key can be created or read back. Not
    ///   recoverable by retrying — a device that cannot hold a key cannot prove
    ///   possession, and the caller's choice is to run unproven or not at all.
    public static func installed(label: String = defaultLabel) throws(DeviceKeyError) -> DeviceKey {
        if let stored = try load(label: label) { return stored }
        return try create(label: label)
    }

    /// A key held only for as long as the caller holds it.
    ///
    /// For tests and for a caller that wants possession within one session
    /// without leaving anything behind. Always software: the enclave's value is
    /// in surviving, and a key that is discarded has nothing to survive.
    public static func ephemeral() -> DeviceKey {
        let key = P256.Signing.PrivateKey()
        return DeviceKey(held: .software(key), storage: .software, publicKey: key.publicKey)
    }

    /// A key from material the caller already holds.
    ///
    /// Deliberately not public. Anything that can supply a P-256 scalar has
    /// already given up the property the enclave exists to provide, so the only
    /// legitimate caller is the interop fixture — which has to name the same
    /// device on every regeneration, or its diff would be noise instead of a
    /// signal that an encoding changed.
    ///
    /// - Throws: ``DeviceKeyError/corrupt`` if the material is not a valid
    ///   P-256 private key.
    static func material(_ raw: Data) throws(DeviceKeyError) -> DeviceKey {
        guard let key = try? P256.Signing.PrivateKey(rawRepresentation: raw) else {
            throw DeviceKeyError.corrupt
        }
        return DeviceKey(held: .software(key), storage: .software, publicKey: key.publicKey)
    }

    private static func create(label: String) throws(DeviceKeyError) -> DeviceKey {
        // Tried first and unconditionally, rather than behind
        // `SecureEnclave.isAvailable`. The property answers for the hardware and
        // not for this process's entitlements, so a build that cannot use the
        // enclave for some other reason would still be told it can; letting the
        // generation attempt be the test means the fallback is chosen by what
        // actually failed.
        if SecureEnclave.isAvailable,
           let enclave = try? SecureEnclave.P256.Signing.PrivateKey(
               accessControl: accessControl()
           ) {
            try store(enclave.dataRepresentation, label: label, storage: .secureEnclave)
            return DeviceKey(
                held: .enclave(enclave),
                storage: .secureEnclave,
                publicKey: enclave.publicKey
            )
        }

        let software = P256.Signing.PrivateKey()
        try store(software.rawRepresentation, label: label, storage: .software)
        return DeviceKey(
            held: .software(software),
            storage: .software,
            publicKey: software.publicKey
        )
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
    /// raw P-256 scalar are both just bytes and guessing wrong means handing the
    /// enclave's ciphertext to the software initialiser and calling the result
    /// corrupt. The tag also means a device whose enclave key was written by an
    /// older build is read back as an enclave key.
    private enum Tag: UInt8 {
        case secureEnclave = 1
        case software = 2

        init(_ storage: Storage) {
            self = storage == .secureEnclave ? .secureEnclave : .software
        }
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
        storage: Storage
    ) throws(DeviceKeyError) {
        var item = query(label: label)
        item[kSecValueData as String] = Data([Tag(storage).rawValue]) + material
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

        let material = stored.dropFirst()
        switch Tag(rawValue: first) {
        case .secureEnclave:
            guard let enclave = try? SecureEnclave.P256.Signing.PrivateKey(
                dataRepresentation: Data(material)
            ) else {
                throw DeviceKeyError.corrupt
            }
            return DeviceKey(
                held: .enclave(enclave),
                storage: .secureEnclave,
                publicKey: enclave.publicKey
            )
        case .software:
            guard let software = try? P256.Signing.PrivateKey(
                rawRepresentation: Data(material)
            ) else {
                throw DeviceKeyError.corrupt
            }
            return DeviceKey(
                held: .software(software),
                storage: .software,
                publicKey: software.publicKey
            )
        case nil:
            throw DeviceKeyError.corrupt
        }
    }

    /// Forget the stored key.
    ///
    /// The device gets a new identity next time one is installed, and every
    /// token bound to the old thumbprint becomes unusable — which is the point
    /// on a signed-out or wiped install, and a mistake anywhere else.
    public static func forget(label: String = defaultLabel) {
        SecItemDelete(query(label: label) as CFDictionary)
    }

    // MARK: - The public half

    /// The public key as a JWK, in RFC 7638 canonical form.
    ///
    /// What the control plane is given at join so it can derive `cnf.jkt`
    /// itself. It derives rather than accepts: a thumbprint supplied by the
    /// client is a claim about which key it holds, and the whole point is not to
    /// take that on trust.
    ///
    /// Assembled by hand rather than encoded, because canonical means exactly
    /// four members, ordered lexicographically, with no whitespace — and a
    /// `JSONEncoder` promises none of that. The values interpolated are
    /// base64url, whose alphabet contains nothing JSON escapes.
    public var publicKeyJWK: String {
        #"{"crv":"P-256","kty":"EC","x":"\#(x)","y":"\#(y)"}"#
    }

    /// The RFC 7638 thumbprint of an EC public key.
    ///
    /// Over the canonical form above, which is the specification's whole
    /// content: same key, same bytes, same hash, in any implementation. The
    /// relay computes this independently in Rust and the Go control plane in Go;
    /// `Tests/MoqomKitTests/DeviceKeyTests.swift` pins the RFC's worked example
    /// so that the three cannot drift.
    static func thumbprint(x: String, y: String) -> String {
        let canonical = #"{"crv":"P-256","kty":"EC","x":"\#(x)","y":"\#(y)"}"#
        return Data(SHA256.hash(data: Data(canonical.utf8))).base64URLEncodedString
    }

    // MARK: - Proving

    /// The proof type, so a JWS minted for anything else — including a token
    /// from this same deployment — cannot be presented as one.
    private static let proofType = "MOQT-POP"

    /// A proof that this key holds `token`, for the relay identified by `relay`.
    ///
    /// A compact JWS over two claims and no timestamps. The freshness argument
    /// is the relay's to make and is written out in `possession.rs`: the proof
    /// commits to one token by hash, the token expires in minutes, and the
    /// proof's own identifier is accepted exactly once. So there is no clock
    /// here to disagree with anybody about, and no round trip spent fetching a
    /// nonce before a client that speaks first can speak.
    ///
    /// - Parameter relay: base64url SHA-256 of the relay's leaf certificate.
    ///   Empty where the carrier could not see one, which a relay that knows its
    ///   own certificate will refuse — deliberately. A proof that omitted the
    ///   binding would be replayable by any relay it was presented to, and the
    ///   attack the binding answers is a compromised relay in a fleet of them.
    ///
    /// - Throws: ``DeviceKeyError/notSigned`` if the key refuses. Signing is a
    ///   call into the enclave and can fail for reasons outside this process.
    public func proof(over token: Data, for relay: String) throws(DeviceKeyError) -> Data {
        let header = #"{"alg":"ES256","typ":"\#(Self.proofType)","jwk":\#(publicKeyJWK)}"#
        let claims = #"{"ath":"\#(Self.digest(of: token))","jti":"\#(Self.identifier())","rel":"\#(relay)"}"#
        let signed = "\(Data(header.utf8).base64URLEncodedString)."
            + Data(claims.utf8).base64URLEncodedString

        guard let signature = try? signature(over: Data(signed.utf8)) else {
            throw DeviceKeyError.notSigned
        }
        return Data("\(signed).\(signature.base64URLEncodedString)".utf8)
    }

    /// ES256 over `message`: SHA-256, then P-256, as the fixed `r || s` pair.
    ///
    /// `rawRepresentation` rather than `derRepresentation`, which is the
    /// difference between what the relay's verifier accepts and a signature it
    /// reads as malformed. `ECDSA_P256_SHA256_FIXED` there means fixed-width;
    /// DER would be the `_ASN1` variant.
    private func signature(over message: Data) throws -> Data {
        switch held {
        case let .enclave(key): try key.signature(for: message).rawRepresentation
        case let .software(key): try key.signature(for: message).rawRepresentation
        }
    }

    private static func digest(of token: Data) -> String {
        Data(SHA256.hash(data: token)).base64URLEncodedString
    }

    /// A proof's single-use identifier.
    ///
    /// 128 bits from the system's CSPRNG, which is what makes the relay's replay
    /// set correct: two honest clients must never pick the same one, or the
    /// second is refused as a replay of the first.
    private static func identifier() -> String {
        SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }.base64URLEncodedString
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
