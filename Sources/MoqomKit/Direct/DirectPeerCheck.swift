// Checking a direct peer's MOQOM credentials exactly as a relay would.
//
// A direct path skips the relay for media and must not skip its checks, so this
// is the relay's admission (`moqom_relay::direct::PeerCheck`): the token
// verified by `MoqomToken` and the proof checked by `MoqomProof`, the libraries
// the relay verifies with, then the relay's own rules in `identity.rs` on top,
// with the same order, the same limits and the same refusals. A rule that
// differs here is a peer one SDK admits and the other refuses.
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

import Foundation
import MoqomProof
import MoqomToken

/// A public key tokens and tickets are signed with: ML-DSA-65, as the control
/// plane mints and relays sign, or Ed25519 for what was signed before the move.
public struct DirectVerificationKey: Hashable, Sendable {
    /// What a key verifies with. A property of the key, not of what it checks:
    /// a token or ticket must name its key's algorithm, so neither can be made
    /// to verify with the other's.
    public enum Algorithm: Hashable, Sendable {
        case mlDSA65
        case ed25519

        /// The JOSE `alg` a JWS signed with this key carries.
        public var jose: String {
            switch self {
            case .mlDSA65: "ML-DSA-65"
            case .ed25519: "EdDSA"
            }
        }
    }

    /// The `kid` naming it.
    public let id: String
    /// The raw public key: 1,952 bytes for ML-DSA-65, 32 for Ed25519.
    public let key: Data
    /// What it verifies with.
    public let algorithm: Algorithm

    public init(id: String, key: Data, algorithm: Algorithm) {
        self.id = id
        self.key = key
        self.algorithm = algorithm
    }

    init(_ key: MoqomToken.PublicKey) {
        self.init(
            id: key.id,
            key: key.rawRepresentation,
            algorithm: key.algorithm == .mlDSA65 ? .mlDSA65 : .ed25519
        )
    }

    /// The same key, as `MoqomToken` verifies with it.
    var tokenKey: MoqomToken.PublicKey {
        MoqomToken.PublicKey(
            id: id,
            algorithm: algorithm == .mlDSA65 ? .mlDSA65 : .ed25519,
            rawRepresentation: key
        )
    }

    /// Whether `signature` is this key's over `message`, by its own algorithm.
    func verifies(_ signature: Data, for message: Data) -> Bool {
        tokenKey.isValidSignature(signature, for: message)
    }

    /// Read the JWK set the control plane serves and a relay is configured
    /// with, as a bare array or wrapped in `{"keys": [...]}`.
    ///
    /// - Throws: ``DirectPeerRefusal/unverifiable`` naming what was wrong,
    ///   since a key set that does not parse verifies nobody.
    public static func parseSet(_ document: Data) throws(DirectPeerRefusal) -> [DirectVerificationKey] {
        do {
            return try MoqomToken.PublicKey.parseSet(document).map(DirectVerificationKey.init)
        } catch {
            throw .unverifiable
        }
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
    case lifetime
    case wrongIssuer
    case incomplete
    case proofMissing
    case malformedProof(String)
    case unsupportedProof
    case proofBadSignature
    case proofWrongKey
    case proofWrongToken
    case proofWrongRelay
    case proofExpired
    case proofNotYetValid
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
        case .lifetime: "token lifetime is out of range"
        case .wrongIssuer: "token was issued by another deployment"
        case .incomplete: "token does not name a complete identity"
        case .proofMissing: "no proof of possession was presented"
        case let .malformedProof(why): "proof is malformed: \(why)"
        case .unsupportedProof: "proof algorithm or type is not supported"
        case .proofBadSignature: "proof signature does not verify"
        case .proofWrongKey: "proof is signed by a key the token was not issued to"
        case .proofWrongToken: "proof was made for a different token"
        case .proofWrongRelay: "proof was made for another relay"
        case .proofExpired: "proof was made too long ago"
        case .proofNotYetValid: "proof is dated in the future"
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
    /// Matches `DEVICE_ID_LENGTH` in the relay and `DeviceID(thumbprint:)`.
    static let deviceIDLength = 16
    /// Every capability bit the relay knows (`scope::capability::KNOWN`). A
    /// token with any other bit is refused rather than read as granting less.
    static let knownCapabilities: UInt32 = 0x0000_001F | 0x0000_7F00 | 0x003F_0000 | 0x0700_0000

    private let tokens: MoqomToken.Verifier
    private let proofs = Checker(store: MemoryNonceStore())

    /// - Parameter keys: the deployment's verification keys, the same set its
    ///   relays hold; see ``DirectVerificationKey/parseSet(_:)``.
    /// - Parameter issuer: the `iss` every token must carry. Empty accepts any,
    ///   which is for tests, as on the relay.
    public init(keys: [DirectVerificationKey], issuer: String = "") {
        tokens = MoqomToken.Verifier(issuer: issuer, keys: keys.map(\.tokenKey))
    }

    public func verify(
        token: Data,
        proof: Data?,
        localCertificate: String,
        now: Date
    ) throws(DirectPeerRefusal) -> VerifiedDirectPeer {
        if tokens.isEmpty { throw .unverifiable }
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

    private func verifyToken(_ token: Data, now: Date) throws(DirectPeerRefusal) -> Admitted {
        let claims: MoqomToken.Claims
        do {
            claims = try tokens.verify(token, now: now)
        } catch {
            throw switch error {
            case let .malformed(why): .malformedToken(why)
            case .unsupported: .unsupportedToken
            case .unknownKey: .unknownKey
            case .badSignature: .badSignature
            case .expired: .expired
            case .notYetValid: .notYetValid
            case .lifetime: .lifetime
            case .wrongIssuer: .wrongIssuer
            // No tenant is pinned here; ``directAdmissible`` compares it.
            case .wrongTenant: .anotherRoom
            case .incomplete: .incomplete
            case .thumbprint: .malformedToken("thumbprint")
            }
        }
        if claims.grant.capabilities & ~Self.knownCapabilities != 0 { throw .unsupportedToken }

        return Admitted(
            peer: VerifiedDirectPeer(
                tenant: claims.tenant,
                user: claims.subject,
                device: String(claims.thumbprint.prefix(Self.deviceIDLength)),
                room: claims.grant.room.isEmpty ? nil : claims.grant.room,
                mayPublish: claims.grant.publish != 0
            ),
            thumbprint: claims.thumbprint,
            expires: claims.expiresDate
        )
    }

    // MARK: - The proof (`possession.rs`, `Possession::check` in `Required` mode)

    private func checkPossession(
        token: Data,
        proof: Data?,
        thumbprint: String,
        binding: String,
        expires: Date,
        now: Date
    ) throws(DirectPeerRefusal) {
        guard let proof else { throw .proofMissing }
        // A binding that does not decode can match no proof.
        guard let certificate = Data(base64URLEncoded: binding) else { throw .proofWrongRelay }
        do {
            try proofs.check(
                proof,
                token: token,
                certificateHash: certificate,
                thumbprint: thumbprint,
                now: now,
                until: expires
            )
        } catch {
            throw switch error {
            case let .malformed(why): .malformedProof(why)
            case .unsupported, .notSigned: .unsupportedProof
            case .badSignature: .proofBadSignature
            case .wrongKey: .proofWrongKey
            case .wrongToken: .proofWrongToken
            case .wrongCertificate: .proofWrongRelay
            case .expired: .proofExpired
            case .notYetValid: .proofNotYetValid
            case .replayed: .proofReplayed
            case .overloaded: .proofOverloaded
            }
        }
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
