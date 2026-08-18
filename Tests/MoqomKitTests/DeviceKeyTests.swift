// The client half of proof of possession, checked the way the relay checks it.
//
// These tests verify a proof rather than merely producing one, and the
// distinction is the whole value of the file. A test that asserted the proof has
// three segments and a `jti` would pass against a signature over the wrong
// bytes, a coordinate encoded with padding, or a DER signature where the relay
// wants a fixed one — every mistake that is expensive precisely because it fails
// in Rust, at connect time, with nothing on this side to say why.
//
// So the assertions below re-implement `moqom-relay/src/possession.rs`: split
// the JWS, verify the signature under the key the header carries, recompute the
// RFC 7638 thumbprint canonically, and compare the claims. Where the two
// implementations must agree exactly the value is pinned to the specification
// rather than to either of them.

import CryptoKit
import Foundation
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

    /// Pinned against RFC 7638, which is the only way to know this agrees with
    /// every other implementation rather than only with itself. The same key and
    /// the same expected digest appear in the relay's own test, so a change to
    /// either side that broke the agreement would fail here and there.
    @Test("the thumbprint follows RFC 7638")
    func thumbprintIsSpecified() {
        #expect(
            DeviceKey.thumbprint(
                x: "MKBCTNIcKUSDii11ySs3526iDZ8AiTo7Tu6KPAqv7D4",
                y: "4Etl6SRW2YiLUrN5vfvVHuhp7x8PxltmWWlbbM4IFyM"
            ) == "cn-I_WNMClehiVp51i_0VpOENW1upEerA8sEam5hn-s"
        )
    }

    /// The coordinates are the fixed width the curve defines, unpadded, and the
    /// thumbprint is over exactly those. A key whose `x` happened to have a
    /// leading zero byte is the case that catches an implementation that trims,
    /// and it is why this asserts the length rather than eyeballing a value.
    @Test("a key is rendered as two fixed-width base64url coordinates")
    func coordinatesAreCanonical() throws {
        let key = DeviceKey.ephemeral()

        for coordinate in [key.x, key.y] {
            #expect(!coordinate.contains("="), "base64url in a JWS carries no padding")
            #expect(!coordinate.contains("+") && !coordinate.contains("/"))
            #expect(
                Data(base64URL: coordinate)?.count == 32,
                "a P-256 coordinate is 32 bytes however small the number is"
            )
        }

        #expect(
            key.thumbprint == DeviceKey.thumbprint(x: key.x, y: key.y),
            "the stored thumbprint must be the one the canonical form produces"
        )
        #expect(key.publicKeyJWK == #"{"crv":"P-256","kty":"EC","x":"\#(key.x)","y":"\#(key.y)"}"#)
    }

    // MARK: - The proof

    @Test("a proof verifies under the key it carries, and names its token and relay")
    func proofVerifies() throws {
        let key = DeviceKey.ephemeral()
        let token = Data("a.token".utf8)

        let proof = try Proof(try key.proof(over: token, for: Self.relay))

        #expect(proof.header.alg == "ES256")
        #expect(proof.header.typ == "MOQT-POP", "a token from this deployment must not pass as one")

        // The signature first, before any claim is read, which is the order the
        // relay uses and for the same reason: a claim from an unverified proof
        // is attacker-controlled input.
        let carried = try P256.Signing.PublicKey(rawRepresentation:
            #require(Data(base64URL: proof.header.jwk.x)) + #require(Data(base64URL: proof.header.jwk.y))
        )
        #expect(
            carried.isValidSignature(
                try P256.Signing.ECDSASignature(rawRepresentation: proof.signature),
                for: proof.signed
            ),
            "the signature must be fixed-width r||s over the two encoded segments"
        )

        #expect(
            DeviceKey.thumbprint(x: proof.header.jwk.x, y: proof.header.jwk.y) == key.thumbprint,
            "a proof signed by some key is worthless unless it is the key the token names"
        )
        #expect(proof.claims.ath == Data(SHA256.hash(data: token)).base64URLEncodedString)
        #expect(proof.claims.rel == Self.relay)
        #expect(!proof.claims.jti.isEmpty)
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
        struct Jwk: Decodable {
            let kty: String
            let crv: String
            let x: String
            let y: String
        }

        struct Header: Decodable {
            let alg: String
            let typ: String
            let jwk: Jwk
        }

        struct Claims: Decodable {
            let ath: String
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
