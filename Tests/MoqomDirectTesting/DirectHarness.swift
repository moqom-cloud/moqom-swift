// What the direct-path suites share: tokens minted with the Rust suite's test
// key (an ML-DSA-87 seed of sevens, kid `test-key`) and the same claims, so a
// vector that passes in one SDK's tests is one the other's would mint; devices
// holding them; and two endpoints establishing at once, each on the backend a
// test names.

import CryptoKit
import Foundation
import MoqomCore
import MoqomKit
import MoqomToken

// MARK: - Minting

public enum DirectTokens {
    public static let signer = try! MLDSA87.PrivateKey(seedRepresentation: Data(repeating: 7, count: 32), publicKey: nil)
    public static let keys = [DirectVerificationKey(id: "test-key", key: signer.publicKey.rawRepresentation, algorithm: .mlDSA87)]

    public static func jws(_ header: [String: Any], _ claims: [String: Any], sign: (Data) -> Data) -> Data {
        func segment(_ object: [String: Any]) -> String {
            let json = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return base64URL(json)
        }
        let signed = segment(header) + "." + segment(claims)
        return Data((signed + "." + base64URL(sign(Data(signed.utf8)))).utf8)
    }

    /// A token as the control plane mints one, through `MoqomToken`, with any
    /// claim overridable.
    ///
    /// Claims the library refuses to sign (an incomplete identity, an expiry
    /// before issue, a grant field it does not know) are signed as they are, so
    /// that what a test sees refused is the verifier refusing them.
    public static func mint(
        user: String,
        key: DeviceKey,
        tenant: String = "acme",
        room: String = "room-42",
        publish: Int = 0x0F,
        capabilities: Int = 0,
        expires: Date = Date().addingTimeInterval(600),
        issued: Date? = Date(),
        kid: String = "test-key",
        signer: MLDSA87.PrivateKey = DirectTokens.signer,
        extraScope: [String: Any] = [:]
    ) -> Data {
        let claims = MoqomToken.Claims(
            subject: user,
            tenant: tenant,
            issuedAt: issued.map { Int64($0.timeIntervalSince1970) } ?? 0,
            expires: Int64(expires.timeIntervalSince1970),
            thumbprint: key.thumbprint,
            grant: MoqomToken.Grant(room: room, publish: UInt8(publish), capabilities: UInt32(capabilities), owner: true)
        )
        if extraScope.isEmpty, let token = try? MoqomToken.Signer(privateKey: signer, keyID: kid).sign(claims) {
            return Data(token.utf8)
        }
        var scope: [String: Any] = ["room": room, "pub": publish, "cap": capabilities, "own": true, "bs": false]
        scope.merge(extraScope) { $1 }
        var raw: [String: Any] = [
            "sub": user,
            "aud": tenant,
            "exp": claims.expires,
            "cnf": ["jkt": key.thumbprint],
            "moqt": scope,
        ]
        if claims.issuedAt != 0 { raw["iat"] = claims.issuedAt }
        return jws(["alg": "ML-DSA-87", "typ": "MOQT", "kid": kid], raw) { try! signer.signature(for: $0) }
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// One person's device, as a direct path sees it.
public struct DirectDevice: Sendable {
    public let user: String
    public let key = DeviceKey.ephemeral()

    public init(user: String) {
        self.user = user
    }

    public var name: String { "\(user)/\(key.thumbprint.prefix(16))" }

    public func credentials(_ token: Data? = nil) throws -> DeviceCredentials {
        DeviceCredentials(
            identity: ParticipantIdentity(username: try Username(user), device: try DeviceID(thumbprint: key.thumbprint)),
            token: token ?? DirectTokens.mint(user: user, key: key),
            deviceKey: key
        )
    }
}

// MARK: - Two endpoints

public enum DirectPair {
    public static let eligible = DirectEligibility(endToEndEncrypted: true, participants: 2, everyoneOptedIn: true)

    public typealias Outcome = Result<DirectSession, DirectEndpointError>

    /// An endpoint for `device` on loopback.
    public static func endpoint(
        _ device: DirectDevice,
        patience: Duration = .seconds(4),
        backend: DirectBackend = .networkFramework
    ) async throws -> DirectEndpoint {
        var configuration = DirectConfiguration(tenant: "acme", room: "room-42", me: device.name)
        configuration.advertisedHost = "127.0.0.1"
        configuration.patience = patience
        return try await DirectEndpoint.bind(
            configuration,
            eligibility: eligible,
            exposure: .peersWillLearnMyIPAddresses(),
            backend: backend
        )
    }

    /// Both sides establishing at once, as they would after trading offers.
    public static func establish(
        alice: DirectDevice,
        bob: DirectDevice,
        aliceBackend: DirectBackend = .networkFramework,
        bobBackend: DirectBackend = .networkFramework,
        aliceToken: Data? = nil,
        bobToken: Data? = nil,
        offerToAlice: (CandidateOffer) -> CandidateOffer = { $0 },
        patience: Duration = .seconds(4),
        aliceDials: Bool? = nil
    ) async throws -> (alice: Outcome, bob: Outcome) {
        let b = try await endpoint(bob, patience: patience, backend: bobBackend)
        // The lower fingerprint dials, and fingerprints are random, so a test
        // that cares which side dials binds again until the dice agree.
        var bound = try await endpoint(alice, patience: patience, backend: aliceBackend)
        while let aliceDials,
              bound.certificateFingerprint.lexicographicallyPrecedes(b.certificateFingerprint) != aliceDials {
            bound.close()
            bound = try await endpoint(alice, patience: patience, backend: aliceBackend)
        }
        let a = bound
        let toBob = a.offer(to: bob.name)
        let toAlice = offerToAlice(b.offer(to: alice.name))
        let aliceCredentials = try alice.credentials(aliceToken)
        let bobCredentials = try bob.credentials(bobToken)
        let keys = DirectTokens.keys

        func outcome(_ body: () async throws -> DirectSession) async -> Outcome {
            do { return .success(try await body()) } catch { return .failure(error as! DirectEndpointError) }
        }
        async let fromAlice = outcome {
            try await a.establish(offer: toAlice, credentials: aliceCredentials, verifier: DirectPeerCheck(keys: keys))
        }
        async let fromBob = outcome {
            try await b.establish(offer: toBob, credentials: bobCredentials, verifier: DirectPeerCheck(keys: keys))
        }
        let outcome = await (fromAlice, fromBob)
        a.close()
        b.close()
        return outcome
    }
}

public extension Result {
    var failure: Failure? {
        if case let .failure(error) = self { return error }
        return nil
    }
}
