// The proof format, pinned across the three implementations that must agree.
//
// `DeviceKeyTests` verifies a proof against a verifier written beside it, in the
// same language, from the same understanding — which catches a mistake in one
// half of this file and not a disagreement between repositories. The
// disagreement is the expensive failure: both sides were written from the same
// description, so they agree on everything except the detail nobody wrote down,
// and it presents as a handshake refused at connect time with the reason in
// somebody else's log.
//
// So this writes what the relay reads. A device key with fixed material, proofs
// over fixed tokens, and thumbprint vectors that include the cases an
// implementation gets wrong quietly — a coordinate with a leading zero byte, one
// whose high bit is set — committed into the engine repository next to the
// verifier. `moqom-relay`'s own tests check every proof here verifies and every
// thumbprint here is the one it computes; the Go control plane checks the
// thumbprints too, because it is the side that derives `cnf.jkt` and a
// disagreement there would mint tokens naming a device that does not exist.
//
// Regenerate with MOQOM_WRITE_FIXTURES=1. Note what does *not* survive that:
// ECDSA signs with a fresh random nonce, so regenerating produces different
// signature bytes for the same key over the same input. The fixture pins the
// encoding, the claims and the key — not the bytes of the signature — and a diff
// showing only the third segment changed is a regeneration rather than a change.

import CryptoKit
import Foundation
import Testing

@testable import MoqomKit

@Suite("Proof interop fixture")
struct ProofInteropTests {
    // MARK: - The fixture

    private struct Fixture: Codable {
        /// The relay digest every proof in `proofs` is bound to.
        let relay: String
        let keys: [Key]
        let proofs: [Proof]

        struct Jwk: Codable {
            let kty: String
            let crv: String
            let x: String
            let y: String
        }

        struct Key: Codable {
            let name: String
            let jwk: Jwk
            let thumbprint: String
        }

        struct Proof: Codable {
            let name: String

            /// The token the proof commits to, as the bytes that travel — a
            /// compact JWS is ASCII, so a string here is the wire form and not a
            /// rendering of it.
            let token: String

            /// The thumbprint the relay will compare against, standing in for
            /// the `cnf.jkt` of a token this fixture does not need to mint.
            let thumbprint: String

            /// The compact JWS the client sends.
            let proof: String
        }
    }

    /// The device this fixture speaks for.
    ///
    /// A fixed scalar, so regeneration names the same device. Small and
    /// repetitive rather than plausible-looking: a value that looked like real
    /// key material would invite somebody to wonder whether it was.
    private static func device() throws -> DeviceKey {
        try DeviceKey.material(Data(repeating: 0x07, count: 32))
    }

    /// Stands in for a relay's certificate digest. Nothing here verifies it; it
    /// has to be carried intact and compared, which is the whole of the binding.
    private static let relay = "cGludGhpc3JlbGF5c2NlcnRpZmljYXRlaGFzaA"

    /// Where the verifier reads it from.
    ///
    /// Committed in the engine repository beside the code that consumes it, for
    /// the reason the token fixture gives: the Rust test then needs no Swift
    /// toolchain and runs on every `cargo test` rather than only where a harness
    /// is set up. `#filePath` rather than the working directory, which SwiftPM
    /// does not promise.
    private static var path: URL {
        if let root = ProcessInfo.processInfo.environment["MOQOM_ENGINE_ROOT"] {
            return URL(filePath: root).appending(path: Self.under)
        }
        // Tests/MoqomKitTests/this.swift -> the package -> its parent.
        let package = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return package
            .deletingLastPathComponent()
            .appending(path: "moqom-engine")
            .appending(path: Self.under)
    }

    private static let under = "moqom-relay/tests/testdata/possession.json"

    // MARK: - Building it

    /// Thumbprint vectors, in the order they are worth having.
    ///
    /// The first is the anchor: RFC 7638's canonicalisation applied to the EC key
    /// from RFC 7517 §A.1, which is the only vector here whose expected value
    /// comes from outside this codebase. The rest are pinned to each other, and
    /// exist because they are the coordinates an implementation mishandles
    /// without noticing — a leading zero byte that a big-integer encoder would
    /// trim, and a high bit set, which is where a signed representation grows a
    /// pad byte.
    private func keys() -> [Fixture.Key] {
        var vectors: [(String, String, String)] = [
            (
                "rfc 7517 §a.1, thumbprinted per rfc 7638",
                "MKBCTNIcKUSDii11ySs3526iDZ8AiTo7Tu6KPAqv7D4",
                "4Etl6SRW2YiLUrN5vfvVHuhp7x8PxltmWWlbbM4IFyM"
            )
        ]

        // Synthetic points rather than real ones, because a thumbprint is a hash
        // of four strings and never touches the curve — so these exercise the
        // encoding without needing to be points at all, and a real key with a
        // leading zero coordinate would take a few thousand generations to find.
        var leadingZero = Data(repeating: 0x5A, count: 32)
        leadingZero[0] = 0x00
        var highBit = Data(repeating: 0x11, count: 32)
        highBit[0] = 0xFF
        vectors.append((
            "a coordinate whose first byte is zero",
            leadingZero.base64URLEncodedString,
            highBit.base64URLEncodedString
        ))
        vectors.append((
            "a coordinate whose high bit is set",
            highBit.base64URLEncodedString,
            leadingZero.base64URLEncodedString
        ))

        return vectors.map { name, x, y in
            Fixture.Key(
                name: name,
                jwk: Fixture.Jwk(kty: "EC", crv: "P-256", x: x, y: y),
                thumbprint: DeviceKey.thumbprint(x: x, y: y)
            )
        }
    }

    private func proofs(from key: DeviceKey) throws -> [Fixture.Proof] {
        // The second token is shaped like a real one, dots and all, because the
        // proof commits to the token's bytes and a hash of "a.token" would pass
        // on an implementation that hashed only up to the first separator.
        let tokens = [
            ("a short token", "a.token"),
            (
                "a token shaped like the compact jws it is",
                "eyJhbGciOiJFZERTQSIsImtpZCI6ImZpeHR1cmUifQ"
                    + ".eyJpc3MiOiJodHRwczovL2FwaS5tb3FvbS5jbG91ZCJ9"
                    + ".c2lnbmF0dXJlLWJ5dGVzLXdoaWNoLW5vdGhpbmctaGVyZS12ZXJpZmllcw"
            ),
        ]

        var built: [Fixture.Proof] = []
        for (name, token) in tokens {
            built.append(
                Fixture.Proof(
                    name: name,
                    token: token,
                    thumbprint: key.thumbprint,
                    proof: String(
                        decoding: try key.proof(over: Data(token.utf8), for: Self.relay),
                        as: UTF8.self
                    )
                )
            )
        }

        // Two proofs over one token, which must both be accepted. The relay
        // spends identifiers rather than tokens, and an implementation that
        // remembered the token instead would pass every test above and refuse
        // the second session of every pair.
        built.append(
            Fixture.Proof(
                name: "a second proof over the first token",
                token: tokens[0].1,
                thumbprint: key.thumbprint,
                proof: String(
                    decoding: try key.proof(over: Data(tokens[0].1.utf8), for: Self.relay),
                    as: UTF8.self
                )
            )
        )
        return built
    }

    // MARK: - The test

    @Test("the committed fixture is what this build produces and reads")
    func fixtureAgrees() throws {
        let key = try Self.device()
        let built = Fixture(relay: Self.relay, keys: keys(), proofs: try proofs(from: key))

        if ProcessInfo.processInfo.environment["MOQOM_WRITE_FIXTURES"] == "1" {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            var encoded = try encoder.encode(built)
            encoded.append(UInt8(ascii: "\n"))
            try FileManager.default.createDirectory(
                at: Self.path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encoded.write(to: Self.path)
        }

        // A missing fixture means the engine repository is not checked out,
        // which is an ordinary state for somebody working on the SDK alone — so
        // it skips. That would be a quiet way to lose the only check that the
        // two proof implementations agree, so CI sets MOQOM_REQUIRE_INTEROP and
        // turns the skip back into a failure.
        guard let raw = try? Data(contentsOf: Self.path) else {
            let required = ProcessInfo.processInfo.environment["MOQOM_REQUIRE_INTEROP"] == "1"
            #expect(!required, "no fixture at \(Self.path.path()); set MOQOM_ENGINE_ROOT")
            return
        }
        let committed = try JSONDecoder().decode(Fixture.self, from: raw)

        #expect(committed.relay == built.relay)

        // The thumbprints, byte for byte. This is the half of the fixture that
        // is deterministic on both sides, so it is compared rather than merely
        // recomputed — a committed vector that this build no longer reproduces
        // is a change to `DeviceKey.thumbprint`, and every token already minted
        // against the old value is one the relay would refuse.
        #expect(committed.keys.count == built.keys.count)
        for (mine, theirs) in zip(built.keys, committed.keys) {
            #expect(mine.name == theirs.name)
            #expect(mine.jwk.x == theirs.jwk.x)
            #expect(mine.jwk.y == theirs.jwk.y)
            #expect(
                DeviceKey.thumbprint(x: theirs.jwk.x, y: theirs.jwk.y) == theirs.thumbprint,
                "\(theirs.name): the committed thumbprint is not what this build computes"
            )
        }

        // The proofs cannot be compared byte for byte — see the file note on
        // ECDSA's nonce — so what is checked is that each committed proof still
        // verifies here, under the key it carries, over the token it names.
        #expect(!committed.proofs.isEmpty)
        for proof in committed.proofs {
            let parts = try Signed(proof.proof)

            #expect(parts.header.alg == "ES256", "\(proof.name)")
            #expect(parts.header.typ == "MOQT-POP", "\(proof.name)")
            #expect(
                DeviceKey.thumbprint(x: parts.header.jwk.x, y: parts.header.jwk.y)
                    == proof.thumbprint,
                "\(proof.name): the proof is signed by a key the fixture does not name"
            )

            let carried = try P256.Signing.PublicKey(rawRepresentation:
                #require(Data(base64URL: parts.header.jwk.x))
                    + #require(Data(base64URL: parts.header.jwk.y))
            )
            #expect(
                carried.isValidSignature(
                    try P256.Signing.ECDSASignature(rawRepresentation: parts.signature),
                    for: parts.signed
                ),
                "\(proof.name): the committed signature no longer verifies here"
            )

            #expect(
                parts.claims.ath
                    == Data(SHA256.hash(data: Data(proof.token.utf8))).base64URLEncodedString,
                "\(proof.name): the proof does not commit to the token beside it"
            )
            #expect(parts.claims.rel == committed.relay, "\(proof.name)")
            #expect(!parts.claims.jti.isEmpty, "\(proof.name)")
        }

        // Distinct, or the relay's replay cache would refuse the second of them
        // and a fleet would see every other connection fail.
        let identifiers = try committed.proofs.map { try Signed($0.proof).claims.jti }
        #expect(Set(identifiers).count == identifiers.count)
    }

    // MARK: - Reading a proof back

    /// A compact JWS taken apart, as `possession.rs` takes one apart.
    private struct Signed {
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

        /// The bytes covered by the signature, taken from the original rather
        /// than rebuilt: a round trip through base64 and JSON does not reproduce
        /// them byte for byte, and the signature is over bytes.
        let signed: Data
        let signature: Data

        init(_ compact: String) throws {
            let segments = compact.split(separator: ".", omittingEmptySubsequences: false)
            guard segments.count == 3 else { throw Malformed.segments }

            let decoder = JSONDecoder()
            header = try decoder.decode(Header.self, from: try Self.decode(segments[0]))
            claims = try decoder.decode(Claims.self, from: try Self.decode(segments[1]))
            signed = Data("\(segments[0]).\(segments[1])".utf8)
            signature = try Self.decode(segments[2])
        }

        private static func decode(_ segment: Substring) throws -> Data {
            guard let bytes = Data(base64URL: String(segment)) else { throw Malformed.encoding }
            return bytes
        }

        enum Malformed: Error {
            case segments
            case encoding
        }
    }
}
