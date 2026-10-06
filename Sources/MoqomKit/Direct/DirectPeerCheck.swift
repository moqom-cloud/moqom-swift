// Checking a direct peer's MOQOM credentials exactly as a relay would.
//
// A direct path skips the relay for media and must not skip its checks, so this
// is a port of the relay's admission (`moqom_relay::direct::PeerCheck`): the
// token verification in `identity.rs` and the possession check in
// `possession.rs`, with the same order, the same limits and the same refusals.
// The two are meant to be read side by side; a rule that differs here is a peer
// one SDK admits and the other refuses.
//
// What differs from a relay's admission is the relay's own `direct.rs` list:
//
// - A proof of possession is required, never observed or bearer.
// - A peer with no verified token is refused rather than admitted with no
//   permission, because a direct path has no later point at which to refuse
//   anything.
// - The proof is bound to this endpoint's ephemeral certificate rather than a
//   relay's.
//
// And on top of a token that verified, the direct-path rules: same tenant and
// room, publishing granted, and naming the participant whose offer was accepted.

import CryptoKit
import Foundation

/// A public key tokens are signed with: Ed25519, as the control plane mints.
public struct DirectVerificationKey: Hashable, Sendable {
    /// The `kid` naming it.
    public let id: String
    /// The raw 32-byte public key.
    public let key: Data

    public init(id: String, key: Data) {
        self.id = id
        self.key = key
    }

    /// Read the JWK set the control plane serves and a relay is configured
    /// with, as a bare array or wrapped in `{"keys": [...]}`.
    ///
    /// - Throws: ``DirectPeerRefusal/unverifiable`` naming what was wrong,
    ///   since a key set that does not parse verifies nobody.
    public static func parseSet(_ document: Data) throws(DirectPeerRefusal) -> [DirectVerificationKey] {
        struct JWK: Decodable { let kty: String; let crv: String; let kid: String; let x: String }
        struct Wrapped: Decodable { let keys: [JWK] }
        let decoder = JSONDecoder()
        let jwks: [JWK]
        if let wrapped = try? decoder.decode(Wrapped.self, from: document) {
            jwks = wrapped.keys
        } else if let bare = try? decoder.decode([JWK].self, from: document) {
            jwks = bare
        } else {
            throw .unverifiable
        }
        var keys: [DirectVerificationKey] = []
        for jwk in jwks {
            guard jwk.kty == "OKP", jwk.crv == "Ed25519",
                  let bytes = Data(base64URLEncoded: jwk.x), bytes.count == 32
            else { throw .unverifiable }
            keys.append(DirectVerificationKey(id: jwk.kid, key: bytes))
        }
        return keys
    }
}

/// Who a peer's verified token says they are.
public struct VerifiedDirectPeer: Hashable, Sendable {
    /// The customer, from the token's audience.
    public let tenant: String
    /// The person.
    public let user: String
    /// The device: the first sixteen characters of the token's key thumbprint.
    public let device: String
    /// The room the token admits them to.
    public let room: String?
    /// Whether the token grants any publishing. A viewer's does not.
    public let mayPublish: Bool

    /// `user/device`, as offers are addressed.
    public var participant: String { "\(user)/\(device)" }
}

/// Why a direct peer was refused.
///
/// The ``description`` is sent to the peer as the close reason, so it says no
/// more than a relay's own refusals do, and the token and proof cases use the
/// relay's wording so a log reads the same whichever side refused.
public enum DirectPeerRefusal: Error, Hashable, Sendable, CustomStringConvertible {
    /// No keys to verify with, so nobody can be admitted.
    case unverifiable
    /// The peer presented no token.
    case anonymous
    case malformedToken(String)
    case unsupportedToken
    case unknownKey
    case badSignature
    case expired
    case notYetValid
    case wrongIssuer
    case incomplete
    case proofMissing
    case malformedProof(String)
    case unsupportedProof
    case proofBadSignature
    case proofWrongKey
    case proofWrongToken
    case proofWrongRelay
    case proofReplayed
    case proofOverloaded
    /// The token verified and is for another tenant or room.
    case anotherRoom
    /// The token verified and grants no publishing.
    case viewer
    /// The token verified and names somebody other than the offer's sender.
    case wrongParticipant

    public var description: String {
        switch self {
        case .unverifiable: "no keys to verify the peer's token with"
        case .anonymous: "a direct session needs a MOQOM token"
        case let .malformedToken(why): "token is malformed: \(why)"
        case .unsupportedToken: "token algorithm or type is not supported"
        case .unknownKey: "token was signed by an unknown key"
        case .badSignature: "token signature does not verify"
        case .expired: "token has expired"
        case .notYetValid: "token is not valid yet"
        case .wrongIssuer: "token was issued by another deployment"
        case .incomplete: "token does not name a complete identity"
        case .proofMissing: "no proof of possession was presented"
        case let .malformedProof(why): "proof is malformed: \(why)"
        case .unsupportedProof: "proof algorithm or type is not supported"
        case .proofBadSignature: "proof signature does not verify"
        case .proofWrongKey: "proof is signed by a key the token was not issued to"
        case .proofWrongToken: "proof was made for a different token"
        case .proofWrongRelay: "proof was made for another relay"
        case .proofReplayed: "proof has already been presented"
        case .proofOverloaded: "this relay is tracking too many proofs to accept another"
        case .anotherRoom: "the peer's token is for another room"
        case .viewer: "viewers never use direct paths"
        case .wrongParticipant: "the peer's token names a different participant than its offer"
        }
    }
}

/// Checks a direct peer's token and proof of possession.
///
/// A protocol so a test, or an app that already runs the relay's check
/// elsewhere, can stand in for ``DirectPeerCheck``.
public protocol DirectPeerVerifying: Sendable {
    /// Verify a peer's `token` and `proof`, the proof bound to
    /// `localCertificate` (base64url SHA-256 of this endpoint's certificate).
    func verify(token: Data, proof: Data?, localCertificate: String, now: Date) throws(DirectPeerRefusal) -> VerifiedDirectPeer
}

/// The relay's admission check, for one direct endpoint.
///
/// One per endpoint, as on the relay: the spent-proof set is per binding, and a
/// binding is one endpoint's certificate.
public final class DirectPeerCheck: DirectPeerVerifying, @unchecked Sendable {
    /// Matches the relay's `CLOCK_SKEW`: a token from slightly in the future is
    /// a clock, an expired one is a boundary and is not extended.
    static let clockSkew: TimeInterval = 30
    /// The relay's `MAX_TOKEN_BYTES` and `MAX_PROOF_BYTES`, checked before any
    /// parsing so the work stays proportional to an honest input.
    static let maximumTokenBytes = 4096
    static let maximumProofBytes = 2048
    /// The relay's `MAX_REMEMBERED`.
    static let maximumRemembered = 100_000
    /// Matches `DEVICE_ID_LENGTH` in the relay and `DeviceID(thumbprint:)`.
    static let deviceIDLength = 16
    /// Every capability bit the relay knows (`scope::capability::KNOWN`). A
    /// token with any other bit is refused rather than read as granting less.
    static let knownCapabilities: UInt32 = 0x0000_001F | 0x0000_7F00 | 0x003F_0000 | 0x0700_0000

    private let keys: [String: Data]
    private let issuer: String
    private let lock = NSLock()
    private var spent: [String: Date] = [:]

    /// - Parameter keys: the deployment's verification keys, the same set its
    ///   relays hold; see ``DirectVerificationKey/parseSet(_:)``.
    /// - Parameter issuer: the `iss` every token must carry. Empty accepts any,
    ///   which is for tests, as on the relay.
    public init(keys: [DirectVerificationKey], issuer: String = "") {
        var byID: [String: Data] = [:]
        for key in keys { byID[key.id] = key.key }
        self.keys = byID
        self.issuer = issuer
    }

    public func verify(
        token: Data,
        proof: Data?,
        localCertificate: String,
        now: Date
    ) throws(DirectPeerRefusal) -> VerifiedDirectPeer {
        if keys.isEmpty { throw .unverifiable }
        if token.isEmpty { throw .anonymous }
        let admitted = try verifyToken(token, now: now)
        try checkPossession(
            token: token,
            proof: proof,
            thumbprint: admitted.thumbprint,
            binding: localCertificate,
            expires: admitted.expires,
            now: now
        )
        return admitted.peer
    }

    // MARK: - The token (`identity.rs`, `Keys::verify`)

    private struct Admitted {
        let peer: VerifiedDirectPeer
        let thumbprint: String
        let expires: Date
    }

    private struct TokenHeader: Decodable { let alg: String; let typ: String; let kid: String }

    private struct Claims: Decodable {
        var iss = ""
        var sub = ""
        var aud = ""
        var iat: Int64 = 0
        var exp: Int64 = 0
        var jkt = ""
        var moqt = Scope()

        private enum Keys: String, CodingKey { case iss, sub, aud, iat, exp, cnf, moqt }
        private enum Confirmation: String, CodingKey { case jkt }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            iss = try container.decodeIfPresent(String.self, forKey: .iss) ?? ""
            sub = try container.decodeIfPresent(String.self, forKey: .sub) ?? ""
            aud = try container.decodeIfPresent(String.self, forKey: .aud) ?? ""
            iat = try container.decodeIfPresent(Int64.self, forKey: .iat) ?? 0
            exp = try container.decodeIfPresent(Int64.self, forKey: .exp) ?? 0
            if container.contains(.cnf) {
                let cnf = try container.nestedContainer(keyedBy: Confirmation.self, forKey: .cnf)
                jkt = try cnf.decodeIfPresent(String.self, forKey: .jkt) ?? ""
            }
            moqt = try container.decodeIfPresent(Scope.self, forKey: .moqt) ?? Scope()
        }
    }

    /// The `moqt` claim, strict as the relay's is: a field this build does not
    /// know might narrow the grant, so a scope it cannot fully read is refused.
    private struct Scope: Decodable {
        var room = ""
        var publish: UInt8 = 0
        var capabilities: UInt32 = 0

        init() {}

        private struct Key: CodingKey {
            let stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { nil }
            init?(intValue _: Int) { nil }
        }

        private static let known: Set<String> = ["room", "pub", "cap", "own", "bs", "age"]

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            for key in container.allKeys where !Self.known.contains(key.stringValue) {
                throw DecodingError.dataCorruptedError(
                    forKey: key, in: container, debugDescription: "unknown scope field"
                )
            }
            func key(_ name: String) -> Key { Key(stringValue: name)! }
            room = try container.decodeIfPresent(String.self, forKey: key("room")) ?? ""
            publish = try container.decodeIfPresent(UInt8.self, forKey: key("pub")) ?? 0
            capabilities = try container.decodeIfPresent(UInt32.self, forKey: key("cap")) ?? 0
            // Parsed so a wrong type is refused as the relay refuses it, and not
            // otherwise read: none decides anything on a direct path.
            _ = try container.decodeIfPresent(Bool.self, forKey: key("own"))
            _ = try container.decodeIfPresent(Bool.self, forKey: key("bs"))
            _ = try container.decodeIfPresent(Bool.self, forKey: key("age"))
        }
    }

    private func verifyToken(_ token: Data, now: Date) throws(DirectPeerRefusal) -> Admitted {
        guard token.count <= Self.maximumTokenBytes else {
            throw .malformedToken("token length is out of range")
        }
        guard let (headerSegment, claimsSegment, signed, signature) = Self.split(token) else {
            throw .malformedToken("expected three segments")
        }
        guard let signature = Data(base64URLEncoded: signature) else {
            throw .malformedToken("signature is not base64url")
        }
        guard let headerBytes = Data(base64URLEncoded: headerSegment) else {
            throw .malformedToken("header is not base64url")
        }
        guard let header = try? JSONDecoder().decode(TokenHeader.self, from: headerBytes) else {
            throw .malformedToken("header is not JSON")
        }
        guard header.alg == "EdDSA", header.typ == "MOQT" else { throw .unsupportedToken }
        guard let raw = keys[header.kid] else { throw .unknownKey }

        // The signature before any claim is read, for the relay's reason: a
        // verifier that acts on unverified claims is a parser an attacker reaches.
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
              key.isValidSignature(signature, for: signed)
        else { throw .badSignature }

        guard let claimsBytes = Data(base64URLEncoded: claimsSegment) else {
            throw .malformedToken("claims are not base64url")
        }
        guard let claims = try? JSONDecoder().decode(Claims.self, from: claimsBytes) else {
            throw .malformedToken("claims are not JSON")
        }

        if !issuer.isEmpty, claims.iss != issuer { throw .wrongIssuer }
        if claims.exp == 0 { throw .malformedToken("no expiry") }
        let expires = Date(timeIntervalSince1970: TimeInterval(claims.exp))
        if now.addingTimeInterval(-Self.clockSkew) > expires { throw .expired }
        if claims.iat != 0,
           now.addingTimeInterval(Self.clockSkew) < Date(timeIntervalSince1970: TimeInterval(claims.iat)) {
            throw .notYetValid
        }
        let device = String(claims.jkt.prefix(Self.deviceIDLength))
        if claims.aud.isEmpty || claims.sub.isEmpty || device.isEmpty { throw .incomplete }
        if claims.moqt.capabilities & ~Self.knownCapabilities != 0 { throw .unsupportedToken }

        return Admitted(
            peer: VerifiedDirectPeer(
                tenant: claims.aud,
                user: claims.sub,
                device: device,
                room: claims.moqt.room.isEmpty ? nil : claims.moqt.room,
                mayPublish: claims.moqt.publish != 0
            ),
            thumbprint: claims.jkt,
            expires: expires
        )
    }

    // MARK: - The proof (`possession.rs`, `Possession::check` in `Required` mode)

    private struct ProofHeader: Decodable {
        let alg: String
        let typ: String
        let jwk: JWK
        struct JWK: Decodable { let kty: String; let crv: String; let x: String; let y: String }
    }

    private struct ProofClaims: Decodable {
        var ath = ""
        var jti = ""
        var rel = ""
        private enum Keys: String, CodingKey { case ath, jti, rel }
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            ath = try container.decodeIfPresent(String.self, forKey: .ath) ?? ""
            jti = try container.decodeIfPresent(String.self, forKey: .jti) ?? ""
            rel = try container.decodeIfPresent(String.self, forKey: .rel) ?? ""
        }
    }

    private func checkPossession(
        token: Data,
        proof: Data?,
        thumbprint: String,
        binding: String,
        expires: Date,
        now: Date
    ) throws(DirectPeerRefusal) {
        guard let proof else { throw .proofMissing }
        guard !proof.isEmpty, proof.count <= Self.maximumProofBytes else {
            throw .malformedProof("proof length is out of range")
        }
        guard let (headerSegment, claimsSegment, signed, signatureSegment) = Self.split(proof) else {
            throw .malformedProof("expected three segments")
        }
        guard let signature = Data(base64URLEncoded: signatureSegment) else {
            throw .malformedProof("signature is not base64url")
        }
        guard let headerBytes = Data(base64URLEncoded: headerSegment) else {
            throw .malformedProof("header is not base64url")
        }
        guard let header = try? JSONDecoder().decode(ProofHeader.self, from: headerBytes) else {
            throw .malformedProof("header is not JSON, or carries no key")
        }
        guard header.alg == "ES256", header.typ == "MOQT-POP" else { throw .unsupportedProof }
        guard header.jwk.kty == "EC", header.jwk.crv == "P-256" else { throw .unsupportedProof }
        guard let x = Data(base64URLEncoded: header.jwk.x), let y = Data(base64URLEncoded: header.jwk.y) else {
            throw .malformedProof("key coordinate is not base64url")
        }
        guard x.count == 32, y.count == 32 else { throw .malformedProof("key coordinate is not 32 bytes") }

        guard let key = try? P256.Signing.PublicKey(rawRepresentation: x + y),
              let ecdsa = try? P256.Signing.ECDSASignature(rawRepresentation: signature),
              key.isValidSignature(ecdsa, for: signed)
        else { throw .proofBadSignature }

        // Re-encoded from the decoded coordinates, never copied, so a padded
        // spelling of one key cannot produce a second thumbprint.
        let canonical = DeviceKey.thumbprint(x: x.base64URLEncodedString, y: y.base64URLEncodedString)
        guard constantTimeEqual(Data(thumbprint.utf8), Data(canonical.utf8)) else { throw .proofWrongKey }

        guard let claimsBytes = Data(base64URLEncoded: claimsSegment),
              let claims = try? JSONDecoder().decode(ProofClaims.self, from: claimsBytes)
        else { throw .malformedProof("claims are not JSON") }
        let tokenHash = Data(SHA256.hash(data: token)).base64URLEncodedString
        guard constantTimeEqual(Data(claims.ath.utf8), Data(tokenHash.utf8)) else { throw .proofWrongToken }
        guard constantTimeEqual(Data(claims.rel.utf8), Data(binding.utf8)) else { throw .proofWrongRelay }
        guard !claims.jti.isEmpty else { throw .malformedProof("no identifier to spend") }

        try spend(claims.jti, until: expires, now: now)
    }

    /// Spent only after every check passed, so a corrupted proof cannot burn a
    /// legitimate one's identifier; full means refused, never evicted.
    private func spend(_ id: String, until expires: Date, now: Date) throws(DirectPeerRefusal) {
        lock.lock()
        defer { lock.unlock() }
        if spent.count >= Self.maximumRemembered {
            spent = spent.filter { $0.value > now }
        }
        if spent.count >= Self.maximumRemembered { throw .proofOverloaded }
        if spent[id] != nil { throw .proofReplayed }
        spent[id] = expires
    }

    /// A compact JWS's segments, with the signed bytes taken verbatim from the
    /// input: the signature is over bytes, and a round trip would not keep them.
    private static func split(_ jws: Data) -> (Data, Data, Data, Data)? {
        let bytes = [UInt8](jws)
        guard let first = bytes.firstIndex(of: UInt8(ascii: ".")) else { return nil }
        let rest = bytes[(first + 1)...]
        guard let second = rest.firstIndex(of: UInt8(ascii: ".")) else { return nil }
        let signature = bytes[(second + 1)...]
        guard !signature.contains(UInt8(ascii: ".")) else { return nil }
        return (
            Data(bytes[..<first]),
            Data(bytes[(first + 1) ..< second]),
            Data(bytes[..<second]),
            Data(signature)
        )
    }
}

/// The direct-path rules on top of a token that verified: this tenant and
/// room, publishing granted, and the participant whose offer was accepted.
func directAdmissible(
    _ peer: VerifiedDirectPeer,
    tenant: String,
    room: String,
    participant: String
) throws(DirectPeerRefusal) {
    if peer.tenant != tenant || peer.room != room { throw .anotherRoom }
    if !peer.mayPublish { throw .viewer }
    if peer.participant != participant { throw .wrongParticipant }
}

extension Data {
    /// Strict base64url without padding, as the relay's `URL_SAFE_NO_PAD`
    /// decodes: padding or a character outside the alphabet is refused.
    init?(base64URLEncoded text: Data) {
        guard let string = String(data: text, encoding: .ascii) else { return nil }
        self.init(base64URLEncoded: string)
    }

    init?(base64URLEncoded string: String) {
        let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        guard string.allSatisfy(alphabet.contains), string.count % 4 != 1 else { return nil }
        var standard = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        standard += String(repeating: "=", count: (4 - standard.count % 4) % 4)
        guard let decoded = Data(base64Encoded: standard) else { return nil }
        self = decoded
    }
}
