// The token client against a real control plane, over real TLS.
//
// Everything else about ``TokenService`` is tested against a stubbed protocol,
// which is the right way to test parsing and cannot test the part most likely to
// be wrong: the pinning. A URLSession decides trust in a delegate callback, the
// certificate has to be pulled out of a `SecTrust` and hashed, and a mistake
// anywhere in that produces either a connection that fails for no visible reason
// or — much worse — a pin that is never actually checked. Neither is visible from
// a stub, because a stub never presents a certificate.
//
// Skipped unless pointed at something, so this is not a test that needs a
// deployment to pass. To run it:
//
//     MOQOM_JOIN_HOST=127.0.0.1:18444 \
//     MOQOM_JOIN_CERT_HASH="$(cat /tmp/joincheck/tls.hash)" \
//     MOQOM_JOIN_CREDENTIAL=devicesecret \
//     swift test --filter TokenServiceLiveTests
//
// A self-signed certificate and a control plane on a laptop are enough; see
// `deploy/tools/sync-secrets.sh` for the deployed equivalents.

import Foundation
import Testing

@testable import MoqomKit

// Disabled rather than failed when there is nothing to point at. A `#require` on
// the environment inside each test reports "no endpoint configured" as two
// failures, which is a suite that cries wolf on every ordinary run and gets
// ignored — including on the runs where it is telling the truth.
@Suite(
    "The token service, live",
    .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["MOQOM_JOIN_HOST"] != nil,
        "set MOQOM_JOIN_HOST and MOQOM_JOIN_CREDENTIAL to run these"
    )
)
struct TokenServiceLiveTests {
    private struct Target {
        var endpoint: RelayEndpoint
        var hash: String
        var credential: String
    }

    private static var target: Target? {
        let environment = ProcessInfo.processInfo.environment
        guard
            let address = environment["MOQOM_JOIN_HOST"],
            let credential = environment["MOQOM_JOIN_CREDENTIAL"]
        else { return nil }

        let parts = address.split(separator: ":")
        return Target(
            endpoint: RelayEndpoint(
                host: String(parts[0]),
                port: parts.count > 1 ? UInt16(parts[1]) ?? 8444 : 8444
            ),
            hash: environment["MOQOM_JOIN_CERT_HASH"] ?? "",
            credential: credential
        )
    }

    @Test("a real endpoint issues a real token to a pinned client")
    func issues() async throws {
        let target = try #require(Self.target, "set MOQOM_JOIN_HOST and MOQOM_JOIN_CREDENTIAL")

        // No tenant, which asks for the credential's own. Naming one here made this
        // test a check on whether the deployment happened to be called `demo`: it
        // was, locally, and is `moqom` in the cluster, so the first live run against
        // the cluster failed with a refusal that had nothing to do with the client.
        let service = TokenService(
            endpoint: target.endpoint,
            certificateHashes: target.hash.isEmpty ? [] : [target.hash],
            credential: target.credential
        )

        let issued = try await service.token(
            username: "ada", room: "handsync", device: DeviceKey.ephemeral()
        )

        #expect(!issued.token.isEmpty)
        #expect(issued.room == "handsync")
        #expect(issued.isUsable())
        // Between one and fifteen minutes. The upper bound is the control plane's
        // cap and the lower one catches a date that failed to parse, which would
        // otherwise look like a token that arrived already dead.
        let remaining = issued.expiresAt.timeIntervalSinceNow
        #expect(remaining > 60)
        #expect(remaining <= 15 * 60 + 5)
    }

    @Test("the wrong certificate is refused rather than trusted")
    func pinning() async throws {
        let target = try #require(Self.target, "set MOQOM_JOIN_HOST and MOQOM_JOIN_CREDENTIAL")
        try #require(!target.hash.isEmpty, "needs MOQOM_JOIN_CERT_HASH to have something to get wrong")

        // A syntactically valid hash of the right length that belongs to nothing.
        // The failure being checked for is the silent one: a pin that is computed,
        // compared, and then not acted on connects perfectly happily, and this is
        // the only test that can tell.
        let wrong = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
        let service = TokenService(
            endpoint: target.endpoint,
            certificateHashes: [wrong],
            credential: target.credential
        )

        do {
            _ = try await service.token(
                username: "ada", room: "handsync", device: DeviceKey.ephemeral()
            )
            Issue.record("the client trusted a certificate it was not pinned to")
        } catch let error as TokenServiceError {
            // Named as a pin failure rather than as a network one. The platform
            // reports both as "A TLS error caused the secure connection to fail",
            // and a phone shown that sentence for a wrong pin sends somebody to
            // look at the network for as long as it takes them to doubt it.
            guard case let .untrusted(offered, expected) = error else {
                Issue.record("a rejected certificate became \(error)")
                return
            }
            #expect(offered == target.hash, "the message should name what was offered")
            #expect(expected == [wrong], "and what this client would have accepted")
        }
    }
}
