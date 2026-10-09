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
// So this writes what the relay reads. ML-DSA-87 device keys with fixed
// material, proofs over fixed tokens made at a fixed time, and their
// thumbprints, committed into the engine repository next to the verifier. `moqom-relay`'s own tests check every proof here verifies and every
// thumbprint here is the one it computes; the Go control plane checks the
// thumbprints too, because it is the side that derives `cnf.jkt` and a
// disagreement there would mint tokens naming a device that does not exist.
//
// Regenerate with MOQOM_WRITE_FIXTURES=1. Note what does *not* survive that:
// ML-DSA signs with fresh randomness, and every proof has a fresh
// identifier, so regenerating produces different claims and signature bytes for
// the same key over the same input. The fixture pins the encoding, the token
// binding and the keys — not the bytes of a proof — and a diff showing only
// proofs changed is a regeneration rather than a change.

import CryptoKit
import Foundation
import MoqomProof
import Testing

@testable import MoqomKit

@Suite("Proof interop fixture")
struct ProofInteropTests {
    // MARK: - The fixture

    private struct Fixture: Codable {
        /// The relay digest every proof in `proofs` is bound to.
        let relay: String
        /// When every proof in `proofs` was made, in Unix seconds: their `iat`.
        let now: Int64
        let keys: [Key]
        let proofs: [Proof]

        struct Key: Codable {
            let name: String
            let jwk: ProofJWK
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

    /// The devices this fixture speaks for: two ML-DSA-87 keys, so a verifier
    /// that cached the first key it saw would refuse the second.
    ///
    /// Fixed material, so regeneration names the same devices. Small and
    /// repetitive rather than plausible-looking: a value that looked like real
    /// key material would invite somebody to wonder whether it was.
    private static func devices() throws -> [(String, DeviceKey)] {
        [
            ("ml-dsa-87", try DeviceKey.material(Data(repeating: 0x07, count: 32))),
            ("second ml-dsa-87", try DeviceKey.material(Data(repeating: 0x08, count: 32))),
        ]
    }

    /// Stands in for a relay's certificate digest. Nothing here verifies it; it
    /// has to be carried intact and compared, which is the whole of the binding.
    private static let relay = "cGludGhpc3JlbGF5c2NlcnRpZmljYXRlaGFzaA"

    /// When the proofs are made, so a reader checks them at a time they are fresh.
    private static let now: Int64 = 1_700_000_000

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

    /// The devices' keys and the thumbprints the relay and the control plane
    /// must compute for them.
    private func keys(_ devices: [(String, DeviceKey)]) throws -> [Fixture.Key] {
        try devices.map { name, device in
            Fixture.Key(name: "the \(name) device key", jwk: device.jwk, thumbprint: try device.jwk.thumbprint())
        }
    }

    private func proofs(_ devices: [(String, DeviceKey)]) throws -> [Fixture.Proof] {
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
        let made = Date(timeIntervalSince1970: TimeInterval(Self.now))

        func proof(_ name: String, _ token: String, by key: DeviceKey) throws -> Fixture.Proof {
            Fixture.Proof(
                name: name,
                token: token,
                thumbprint: key.thumbprint,
                proof: String(
                    decoding: try key.proof(over: Data(token.utf8), for: Self.relay, at: made),
                    as: UTF8.self
                )
            )
        }

        var built: [Fixture.Proof] = []
        for (device, key) in devices {
            for (name, token) in tokens {
                built.append(try proof("\(device): \(name)", token, by: key))
            }
        }

        // Two proofs over one token, which must both be accepted. The relay
        // spends identifiers rather than tokens, and an implementation that
        // remembered the token instead would pass every test above and refuse
        // the second session of every pair.
        built.append(try proof("a second proof over the first token", tokens[0].1, by: devices[0].1))
        return built
    }

    // MARK: - The test

    @Test("the committed fixture is what this build produces and reads")
    func fixtureAgrees() throws {
        let devices = try Self.devices()
        let built = Fixture(relay: Self.relay, now: Self.now, keys: try keys(devices), proofs: try proofs(devices))

        if ProcessInfo.processInfo.environment["MOQOM_WRITE_FIXTURES"] == "1" {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
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
        // is a change to the thumbprint, and every token already minted against
        // the old value is one the relay would refuse.
        #expect(committed.keys.count == built.keys.count)
        for (mine, theirs) in zip(built.keys, committed.keys) {
            #expect(mine.name == theirs.name)
            #expect(mine.jwk == theirs.jwk)
            #expect(
                try theirs.jwk.thumbprint() == theirs.thumbprint,
                "\(theirs.name): the committed thumbprint is not what this build computes"
            )
        }

        // The proofs cannot be compared byte for byte — see the file note — so
        // what is checked is that each committed proof passes the relay's check
        // here, under the key the fixture names, over the token beside it.
        #expect(!committed.proofs.isEmpty)
        let made = Date(timeIntervalSince1970: TimeInterval(committed.now))
        let certificate = try #require(Data(base64URL: committed.relay))
        var algorithms: Set<String> = []
        for proof in committed.proofs {
            try Checker(store: MemoryNonceStore()).check(
                Data(proof.proof.utf8),
                token: Data(proof.token.utf8),
                certificateHash: certificate,
                thumbprint: proof.thumbprint,
                now: made,
                until: made.addingTimeInterval(600)
            )
            algorithms.insert(try Header(proof.proof).alg)
        }
        #expect(algorithms == ["ML-DSA-87"], "every proof is ML-DSA-87")

        // Distinct, or the relay's replay cache would refuse the second of them
        // and a fleet would see every other connection fail.
        let store = MemoryNonceStore()
        for proof in committed.proofs {
            try Checker(store: store).check(
                Data(proof.proof.utf8),
                token: Data(proof.token.utf8),
                certificateHash: certificate,
                thumbprint: proof.thumbprint,
                now: made,
                until: made.addingTimeInterval(600)
            )
        }
    }

    /// A proof's protected header, which is all this needs to read itself.
    private struct Header: Decodable {
        let alg: String

        init(_ compact: String) throws {
            let segment = String(compact.prefix { $0 != "." })
            guard let bytes = Data(base64URL: segment) else { throw CocoaError(.coderReadCorrupt) }
            self = try JSONDecoder().decode(Self.self, from: bytes)
        }
    }
}
