// The client half of proof of possession, checked the way the relay checks it.
//
// These tests verify a proof rather than merely producing one, and the
// distinction is the whole value of the file. A test that asserted the proof has
// three segments and a `jti` would pass against a signature over the wrong
// bytes, a coordinate encoded with padding, or a DER signature where the relay
// wants a fixed one — every mistake that is expensive precisely because it fails
// in Rust, at connect time, with nothing on this side to say why.
//
// So the assertions below run `MoqomProof`'s checker, the one the relay runs in
// Rust and the control plane in Go, and read the claims back. Where the
// implementations must agree exactly the value is pinned to the specification
// rather than to any of them.

import CryptoKit
import Foundation
import MoqomProof
import Testing

@testable import MoqomCore
@testable import MoqomKit
@testable import MoqomLoopback
import MoqomWire

@Suite("Device key and proof of possession")
struct DeviceKeyTests {
    /// A stand-in for the relay's certificate digest. Nothing verifies it here;
    /// it only has to travel intact.
    private static let relay = "cGludGhpc3JlbGF5c2NlcnRpZmljYXRlaGFzaA"

    // MARK: - The thumbprint

    /// A new key is ML-DSA-87, sent as an `AKP` JWK whose canonical form is
    /// exactly `alg`, `kty`, `pub`, and the thumbprint is over those bytes.
    @Test("a new key is ML-DSA-87, rendered as a canonical AKP JWK")
    func newKeysAreMLDSA() throws {
        let key = DeviceKey.ephemeral()

        #expect(key.algorithm == .mlDSA87)
        #expect(key.jwk.kty == "AKP")
        #expect(key.jwk.alg == "ML-DSA-87")
        let pub = try #require(key.jwk.pub)
        #expect(!pub.contains("=") && !pub.contains("+") && !pub.contains("/"))
        #expect(Data(base64URL: pub)?.count == 2592)
        #expect(key.publicKeyJWK == #"{"alg":"ML-DSA-87","kty":"AKP","pub":"\#(pub)"}"#)
        #expect(
            key.thumbprint == Data(SHA256.hash(data: Data(key.publicKeyJWK.utf8))).base64URLEncodedString,
            "the stored thumbprint must be the one the canonical form produces"
        )
    }

    // MARK: - The proof

    /// Checked by `MoqomProof`'s checker, the same check the relay runs.
    @Test("a proof is accepted by the relay's check, and names its token and relay",
          arguments: [ProofAlgorithm.mlDSA87])
    func proofVerifies(_ algorithm: ProofAlgorithm) throws {
        let key = DeviceKey.ephemeral(algorithm)
        let token = Data("a.token".utf8)
        let now = Date()

        let bytes = try key.proof(over: token, for: Self.relay, at: now)
        let proof = try Proof(bytes)

        #expect(proof.header.alg == algorithm.rawValue)
        #expect(proof.header.typ == "MOQT-POP", "a token from this deployment must not pass as one")
        #expect(proof.claims.ath == Data(SHA256.hash(data: token)).base64URLEncodedString)
        #expect(proof.claims.rel == Self.relay)
        #expect(proof.claims.iat == Int64(now.timeIntervalSince1970))
        #expect(!proof.claims.jti.isEmpty)

        let checker = Checker(store: MemoryNonceStore())
        try checker.check(
            bytes,
            token: token,
            certificateHash: try #require(Data(base64URL: Self.relay)),
            thumbprint: key.thumbprint,
            now: now,
            until: now.addingTimeInterval(600)
        )
    }

    /// The enclave's own ML-DSA-87 key, where there is one: the key a device
    /// actually gets, and not only the software stand-in the other tests use.
    @Test("a Secure Enclave key proves possession", .enabled(if: SecureEnclave.isAvailable))
    func enclaveKeyProves() throws {
        let label = "cloud.moqom.device-key.test.\(UUID().uuidString)"
        defer { DeviceKey.forget(label: label) }
        let key = try DeviceKey.installed(label: label)
        #expect(key.algorithm == .mlDSA87)

        let again = try DeviceKey.installed(label: label)
        #expect(again.thumbprint == key.thumbprint, "a stored key must be read back, not replaced")

        let token = Data("a.token".utf8)
        let now = Date()
        try Checker(store: MemoryNonceStore()).check(
            try key.proof(over: token, for: Self.relay, at: now),
            token: token,
            certificateHash: try #require(Data(base64URL: Self.relay)),
            thumbprint: key.thumbprint,
            now: now,
            until: now.addingTimeInterval(600)
        )
    }

    /// The relay accepts an identifier exactly once, so two proofs that shared
    /// one would mean the second connection of every pair being refused as a
    /// replay of the first.
    @Test("every proof has its own identifier")
    func identifiersAreFresh() throws {
        let key = DeviceKey.ephemeral()
        let token = Data("a.token".utf8)

        let first = try Proof(try key.proof(over: token, for: Self.relay))
        let second = try Proof(try key.proof(over: token, for: Self.relay))

        #expect(first.claims.jti != second.claims.jti)
    }

    /// A proof commits to one token by hash, which is what stops a renewal from
    /// laundering a proven credential into an unproven one.
    @Test("a proof for one token does not describe another")
    func proofsAreBoundToTheirToken() throws {
        let key = DeviceKey.ephemeral()

        let proof = try Proof(try key.proof(over: Data("one.token".utf8), for: Self.relay))
        let other = Data(SHA256.hash(data: Data("another.token".utf8))).base64URLEncodedString

        #expect(proof.claims.ath != other)
    }

    // MARK: - On the wire

    @Test("a session presents a proof beside its token at setup")
    func setupCarriesAProof() async throws {
        let key = DeviceKey.ephemeral()
        let (clientCarrier, serverCarrier) = MemoryCarrier.pair(certificate: Self.relay)

        async let server = MoqtSession.accept(over: serverCarrier)
        async let client = MoqtSession.connect(
            over: clientCarrier,
            credentials: DeviceCredentials(
                identity: identity("alice"),
                token: Data("token-alice".utf8),
                deviceKey: key
            )
        )
        let (dialled, accepted) = try await (client, server)

        let options = await accepted.peerSetupOptions
        let proof = try Proof(try #require(options.bytes(SetupOption.authorizationProof)))

        #expect(
            proof.claims.ath
                == Data(SHA256.hash(data: Data("token-alice".utf8))).base64URLEncodedString
        )
        #expect(proof.claims.rel == Self.relay, "the proof must name the relay it was sent to")

        await dialled.close(code: 0, reason: "done")
        await accepted.close(code: 0, reason: "done")
    }

    /// A carrier with no TLS under it has no certificate to bind to. The proof
    /// still goes out, with an empty binding, which a relay that knows its own
    /// certificate refuses — the honest outcome, and the one that stops an
    /// unbound proof from looking like a bound one.
    @Test("a session with no certificate to bind to says so rather than inventing one")
    func setupWithoutACertificate() async throws {
        let (clientCarrier, serverCarrier) = MemoryCarrier.pair()

        async let server = MoqtSession.accept(over: serverCarrier)
        async let client = MoqtSession.connect(
            over: clientCarrier,
            credentials: DeviceCredentials(
                identity: identity("alice"),
                token: Data("token-alice".utf8),
                deviceKey: DeviceKey.ephemeral()
            )
        )
        let (dialled, accepted) = try await (client, server)

        let options = await accepted.peerSetupOptions
        let proof = try Proof(try #require(options.bytes(SetupOption.authorizationProof)))
        #expect(proof.claims.rel.isEmpty)

        await dialled.close(code: 0, reason: "done")
        await accepted.close(code: 0, reason: "done")
    }

    /// A credential with no key presents no proof, rather than an empty one that
    /// a relay would have to distinguish from a malformed proof.
    @Test("a session with no device key presents no proof at all")
    func setupWithoutAKey() async throws {
        let (clientCarrier, serverCarrier) = MemoryCarrier.pair(certificate: Self.relay)

        async let server = MoqtSession.accept(over: serverCarrier)
        async let client = MoqtSession.connect(
            over: clientCarrier,
            credentials: credentials("alice")
        )
        let (dialled, accepted) = try await (client, server)

        let options = await accepted.peerSetupOptions
        #expect(options.bytes(SetupOption.authorizationToken) != nil)
        #expect(options.bytes(SetupOption.authorizationProof) == nil)

        await dialled.close(code: 0, reason: "done")
        await accepted.close(code: 0, reason: "done")
    }

    /// The proof at SETUP commits to the token it arrived with and has been
    /// spent, so a renewal that reused it would be refused as a replay. This is
    /// the assertion that the fresh token gets a fresh proof.
    @Test("a renewal carries a proof over the new token")
    func renewalCarriesAProof() async throws {
        let key = DeviceKey.ephemeral()
        let (clientCarrier, serverCarrier) = MemoryCarrier.pair(certificate: Self.relay)
        let heard = Renewals()
        let relay = recordingRelay(on: serverCarrier, into: heard)
        defer { relay.cancel() }

        let client = try await MoqtSession.connect(
            over: clientCarrier,
            credentials: DeviceCredentials(
                identity: identity("alice"),
                token: Data("token-alice".utf8),
                deviceKey: key
            )
        )
        _ = try await client.announcements(
            matching: MoqomNamespaces.room(tenant: "acme", room: "room-42")
        )

        let fresh = Data("the-fresh-one".utf8)
        try await client.renewCredential(fresh)

        let renewal = try #require(await heard.first(within: .seconds(2)))
        #expect(renewal.token == fresh)

        let proof = try Proof(try #require(renewal.proof))
        #expect(
            proof.claims.ath == Data(SHA256.hash(data: fresh)).base64URLEncodedString,
            "a proof over the old token would be refused as a replay"
        )
        #expect(proof.claims.rel == Self.relay)

        await client.close(code: 0, reason: "done")
    }

    // MARK: - Reading a proof back

    /// A compact JWS, taken apart the way the relay takes one apart.
    private struct Proof {
        struct Header: Decodable {
            let alg: String
            let typ: String
            let jwk: ProofJWK
        }

        struct Claims: Decodable {
            let ath: String
            let iat: Int64
            let jti: String
            let rel: String
        }

        let header: Header
        let claims: Claims

        /// The bytes the signature covers, taken from the original rather than
        /// rebuilt: a round trip through base64 and JSON does not reproduce them
        /// byte for byte, and the signature is over bytes.
        let signed: Data
        let signature: Data

        init(_ proof: Data) throws {
            let segments = proof.split(separator: UInt8(ascii: "."), omittingEmptySubsequences: false)
            guard segments.count == 3 else {
                throw ProofFormat.expectedThreeSegments
            }

            let decoder = JSONDecoder()
            header = try decoder.decode(
                Header.self, from: try Self.decode(segments[0], "header")
            )
            claims = try decoder.decode(
                Claims.self, from: try Self.decode(segments[1], "claims")
            )
            signed = proof.prefix(segments[0].count + 1 + segments[1].count)
            signature = try Self.decode(segments[2], "signature")
        }

        private static func decode(_ segment: some Sequence<UInt8>, _ what: String) throws -> Data {
            guard let bytes = Data(base64URL: String(decoding: Data(segment), as: UTF8.self)) else {
                throw ProofFormat.notBase64URL(what)
            }
            return bytes
        }
    }

    private enum ProofFormat: Error {
        case expectedThreeSegments
        case notBase64URL(String)
    }

    // MARK: - A relay that listens for renewals

    private struct Renewal: Sendable {
        let token: Data
        let proof: Data?
    }

    private actor Renewals {
        private var seen: [Renewal] = []

        func record(_ renewal: Renewal) { seen.append(renewal) }

        func first(within limit: Duration) async -> Renewal? {
            let deadline = ContinuousClock.now.advanced(by: limit)
            while ContinuousClock.now < deadline {
                if let first = seen.first { return first }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return seen.first
        }
    }

    /// Completes SETUP and notes the credential on every `REQUEST_UPDATE`.
    ///
    /// Hand-rolled rather than a second `MoqtSession`, which has no credential
    /// to renew and would neither read the parameters nor care.
    private func recordingRelay(
        on carrier: MemoryCarrier,
        into heard: Renewals
    ) -> Task<Void, Never> {
        Task {
            for await stream in carrier.incomingBidirectionalStreams {
                Task {
                    var framer = StreamFramer()
                    while let chunk = try? await stream.read() {
                        framer.append(chunk)
                        while let frame = try? framer.next() {
                            switch frame.type {
                            case .setup:
                                var writer = WireWriter()
                                try? ControlFrame.write(Setup(), to: &writer)
                                try? await stream.write(writer.bytes)
                            case .requestUpdate:
                                var body = WireReader(frame.body)
                                guard let update = try? RequestUpdate.read(from: &body),
                                      let token = update.parameters
                                      .bytes(RequestParameter.authorizationToken)
                                else { break }
                                await heard.record(
                                    Renewal(
                                        token: token,
                                        proof: update.parameters
                                            .bytes(RequestParameter.authorizationProof)
                                    )
                                )
                            default:
                                break
                            }
                        }
                    }
                }
            }
        }
    }
}

extension Data {
    /// Decode base64url without padding, which is what a JWS carries.
    ///
    /// Strict about padding on the way in: a value that arrived with `=` on it
    /// is not the value the sender signed over, and accepting both spellings
    /// here would hide exactly the encoding bug these tests exist to catch.
    init?(base64URL: String) {
        guard !base64URL.contains("=") else { return nil }
        var standard = base64URL
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        standard += String(repeating: "=", count: (4 - standard.count % 4) % 4)
        guard let decoded = Data(base64Encoded: standard) else { return nil }
        self = decoded
    }
}
