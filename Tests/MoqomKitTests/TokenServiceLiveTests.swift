// The token client against a real token server, over real TLS.
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
// deployment to pass. To run it against the reference token server, with an
// enrollment from a sign-in and the key that sign-in was bound to:
//
//     MOQOM_TOKEN_URL=https://127.0.0.1:18443/v1/token \
//     MOQOM_TOKEN_CERT_HASH="$(cat /tmp/tokencheck/tls.hash)" \
//     MOQOM_TOKEN_AUTHORIZATION=<enrollment> \
//     swift test --filter TokenServiceLiveTests
//
// An enrollment is bound to one device key, which these tests cannot hold, so
// against the reference server the issuing test expects a refusal naming the
// key rather than a token; a backend of your own that does not bind may issue.
// The pinning test is meaningful either way.

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
        if: ProcessInfo.processInfo.environment["MOQOM_TOKEN_URL"] != nil,
        "set MOQOM_TOKEN_URL and MOQOM_TOKEN_AUTHORIZATION to run these"
    )
)
struct TokenServiceLiveTests {
    private struct Target {
        var url: URL
        var hash: String
        var authorization: String
    }

    private static var target: Target? {
        let environment = ProcessInfo.processInfo.environment
        guard
            let address = environment["MOQOM_TOKEN_URL"].flatMap(URL.init(string:)),
            let authorization = environment["MOQOM_TOKEN_AUTHORIZATION"]
        else { return nil }
        return Target(url: address, hash: environment["MOQOM_TOKEN_CERT_HASH"] ?? "", authorization: authorization)
    }

    @Test("a real endpoint answers a pinned client")
    func answers() async throws {
        let target = try #require(Self.target, "set MOQOM_TOKEN_URL and MOQOM_TOKEN_AUTHORIZATION")
        let service = TokenService(
            url: target.url,
            authorization: target.authorization,
            certificateHashes: target.hash.isEmpty ? [] : [target.hash]
        )

        do {
            let issued = try await service.token(
                username: "ada", room: "demo", device: DeviceKey.ephemeral()
            )
            #expect(!issued.token.isEmpty)
            #expect(issued.isUsable())
            // Between one and fifteen minutes. The upper bound is the control plane's
            // cap and the lower one catches a date that failed to parse, which would
            // otherwise look like a token that arrived already dead.
            let remaining = issued.expiresAt.timeIntervalSinceNow
            #expect(remaining > 60)
            #expect(remaining <= 15 * 60 + 5)
        } catch {
            // Reached, and refused for a reason: what a binding server says to a
            // key it did not enrol. A transport or pin failure is the bug.
            guard case .refused = error else {
                Issue.record("the service could not be asked: \(error)")
                return
            }
        }
    }

    @Test("the wrong certificate is refused rather than trusted")
    func pinning() async throws {
        let target = try #require(Self.target, "set MOQOM_TOKEN_URL and MOQOM_TOKEN_AUTHORIZATION")
        try #require(!target.hash.isEmpty, "needs MOQOM_TOKEN_CERT_HASH to have something to get wrong")

        // A syntactically valid hash of the right length that belongs to nothing.
        // The failure being checked for is the silent one: a pin that is computed,
        // compared, and then not acted on connects perfectly happily, and this is
        // the only test that can tell.
        let wrong = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
        let service = TokenService(url: target.url, authorization: target.authorization, certificateHashes: [wrong])

        do {
            _ = try await service.token(
                username: "ada", room: "demo", device: DeviceKey.ephemeral()
            )
            Issue.record("the client trusted a certificate it was not pinned to")
        } catch {
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
