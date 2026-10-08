// Fetching a credential, and the three ways that goes wrong.
//
// The parsing is worth testing rather than eyeballing because both halves of it
// are cross-language agreements that fail quietly. The expiry is written by Go's
// encoding/json and read by Foundation, and a fraction of a second in the format
// that one side omits and the other requires produces a date of 1970 — which
// reads as "expired" and sends a client into a refresh loop against a token that
// was perfectly good. The error mapping decides whether a phone retries or stops,
// and getting it backwards means either a spinner forever or a Join button that
// gives up on a network blip.

import Foundation
import Testing

@testable import MoqomKit

// Serialized because the stand-in for the network below is reached through
// URLProtocol, which the loading system instantiates itself and which therefore
// has nowhere to keep per-test state but a static. Run in parallel, the tests
// answer each other's requests — which failed as eight assertion failures with
// eight different-looking causes.
@Suite("The token service", .serialized)
struct TokenServiceTests {
    /// The key a token would be bound to. Held once per test rather than
    /// generated per call, because a device has one and the request carries it.
    private let key = DeviceKey.ephemeral()

    private func service(_ answers: Stub.Answer) -> (TokenService, URLSession) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        Stub.answer = answers
        return (
            TokenService(
                endpoint: RelayEndpoint(host: "control.example", port: 8444),
                credential: "device-secret",
                tenant: "demo"
            ),
            URLSession(configuration: configuration)
        )
    }

    @Test("a token comes back with the moment it dies")
    func issued() async throws {
        let (service, session) = self.service(.ok("""
        {"token":"header.payload.signature",
         "expiresAt":"2026-08-05T18:15:00.123456789Z",
         "room":"handsync","username":"ada","keyId":"abc"}
        """))

        let issued = try await service.token(
            username: "ada", room: "handsync", device: key, session: session
        )

        #expect(issued.token == Data("header.payload.signature".utf8))
        #expect(issued.username == "ada")
        #expect(issued.room == "handsync")
        // The assertion that matters: a date that did not parse comes back as
        // 1970 or as now, and both of those are wrong in a way that only shows up
        // as a client refusing to use a token it just fetched.
        let expected = Date(timeIntervalSince1970: 1_785_953_700)
        #expect(abs(issued.expiresAt.timeIntervalSince(expected)) < 1)
    }

    @Test("an expiry with no fraction of a second still parses")
    func secondsOnly() async throws {
        // Go omits the fraction when it happens to be zero, so this is not a
        // hypothetical format — it is the same service on a different second.
        let (service, session) = self.service(.ok("""
        {"token":"a.b.c","expiresAt":"2026-08-05T18:15:00Z","room":"r","username":"u"}
        """))

        let issued = try await service.token(
            username: "u", room: "r", device: key, session: session
        )
        #expect(issued.expiresAt.timeIntervalSince1970 == 1_785_953_700)
        #expect(issued.direct == .default)
    }

    @Test("the room's direct policy comes back with the token")
    func directPolicy() async throws {
        let (service, session) = self.service(.ok("""
        {"token":"a.b.c","expiresAt":"2026-08-05T18:15:00Z","room":"r","username":"u",
         "direct":{"allowed":true,"maxParticipants":2}}
        """))
        let issued = try await service.token(username: "u", room: "r", device: key, session: session)
        #expect(issued.direct == DirectRoomPolicy(allowed: true, maximumParticipants: 2))

        let (refusing, again) = self.service(.ok("""
        {"token":"a.b.c","expiresAt":"2026-08-05T18:15:00Z","direct":{"allowed":false}}
        """))
        let relayOnly = try await refusing.token(username: "u", room: "r", device: key, session: again)
        #expect(!relayOnly.direct.allowed)
        #expect(DirectRoomPolicy(allowed: true, maximumParticipants: 40).maximumParticipants == 4)
    }

    @Test("what the device asks for is what it sends")
    func requestBody() async throws {
        let (service, session) = self.service(.ok(#"{"token":"a.b.c","room":"r","username":"u"}"#))
        _ = try await service.token(username: "Ada", room: "handsync", device: key, session: session)

        let sent = try #require(Stub.received)
        #expect(sent.httpMethod == "POST")
        #expect(sent.url?.absoluteString == "https://control.example:8444/join")
        // The credential goes in a header and never in the URL. A credential in a
        // query string is a credential in every access log between here and the
        // control plane.
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer device-secret")

        let body = try #require(Stub.body)
        let decoded = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(decoded["username"] as? String == "Ada")
        #expect(decoded["room"] as? String == "handsync")
        #expect(decoded["tenant"] as? String == "demo")

        // The key, not just its name. The control plane derives `cnf.jkt` from
        // what is sent here, so a request that carried only the thumbprint would
        // get a token bound to a claim rather than to a key — and this assertion
        // is the one that notices if that regresses.
        let sentKey = try #require(decoded["key"] as? [String: String])
        #expect(sentKey == ["kty": "AKP", "alg": "ML-DSA-65", "pub": try #require(key.jwk.pub)])

        // Truncated the way a namespace field is, since that is what the device
        // announces under and what the endpoint checks the key against.
        #expect(decoded["device"] as? String == String(key.thumbprint.prefix(16)))
    }

    @Test("a refusal keeps the reason, because somebody has to read it")
    func refused() async throws {
        let (service, session) = self.service(.status(403, "account join-backend cannot mint publish rights it does not hold"))

        await #expect(throws: TokenServiceError.self) {
            try await service.token(username: "ada", room: "r", device: key, session: session)
        }

        do {
            _ = try await service.token(username: "ada", room: "r", device: key, session: session)
        } catch let error as TokenServiceError {
            guard case let .refused(status, reason) = error else {
                Issue.record("a 403 became \(error)")
                return
            }
            #expect(status == 403)
            #expect(reason.contains("publish rights"))
            // Nothing about this changes on a retry, and a client that retries a
            // permanent refusal is a spinner that never stops.
            #expect(!error.isWorthRetrying)
        }
    }

    @Test("the refusals worth retrying are told apart from the ones that are not")
    func retryable() {
        #expect(TokenServiceError.unreachable("offline").isWorthRetrying)
        #expect(TokenServiceError.refused(status: 429, reason: "too many requests").isWorthRetrying)
        #expect(TokenServiceError.refused(status: 503, reason: "unready").isWorthRetrying)
        #expect(!TokenServiceError.refused(status: 404, reason: "no such room").isWorthRetrying)
        #expect(!TokenServiceError.refused(status: 401, reason: "invalid credentials").isWorthRetrying)
        #expect(!TokenServiceError.malformed("nonsense").isWorthRetrying)
    }

    @Test("a service that cannot be reached is not the same as one that said no")
    func unreachable() async {
        let (service, session) = self.service(.failure)

        do {
            _ = try await service.token(username: "ada", room: "r", device: key, session: session)
            Issue.record("a dead service produced a token")
        } catch let error as TokenServiceError {
            guard case .unreachable = error else {
                Issue.record("an unreachable service became \(error)")
                return
            }
            #expect(error.isWorthRetrying)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test("a body with no token in it is a fault rather than an empty credential")
    func malformed() async {
        // The failure this prevents is the quiet one: an empty token is a
        // configuration a relay accepts, admitting the session as nobody and
        // permitting it nothing.
        let (service, session) = self.service(.ok(#"{"expiresAt":"2026-08-05T18:15:00Z"}"#))

        do {
            _ = try await service.token(username: "ada", room: "r", device: key, session: session)
            Issue.record("a response with no token produced one")
        } catch let error as TokenServiceError {
            guard case .malformed = error else {
                Issue.record("a bodyless response became \(error)")
                return
            }
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test("a token about to expire is not worth presenting")
    func margin() {
        let now = Date()
        let issued = { (seconds: TimeInterval) in
            IssuedToken(
                token: Data("a.b.c".utf8),
                expiresAt: now.addingTimeInterval(seconds),
                username: "ada", room: "r"
            )
        }

        #expect(issued(15 * 60).isUsable(at: now))
        #expect(!issued(-1).isUsable(at: now))
        // The case the margin exists for. Valid when checked, expired by the time
        // the relay verifies it, and the failure is a session admitted as nobody
        // with nothing on either side saying why.
        #expect(!issued(5).isUsable(at: now))
    }
}

/// A stand-in for the network, so these tests exercise the parsing rather than a
/// deployment.
private final class Stub: URLProtocol {
    enum Answer {
        case ok(String)
        case status(Int, String)
        case failure
    }

    // Static because URLProtocol instances are made by the loading system, which
    // takes no arguments. Safe only because the suite is serialized; see above.
    nonisolated(unsafe) static var answer: Answer = .failure
    nonisolated(unsafe) static var received: URLRequest?
    nonisolated(unsafe) static var body: Data?

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Stub.received = request
        // URLSession moves the body to a stream by the time a protocol sees it,
        // so reading it back is the only way to assert what was sent.
        Stub.body = request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open()
            var collected = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                collected.append(contentsOf: buffer[0 ..< read])
            }
            stream.close()
            return collected
        }

        switch Stub.answer {
        case let .ok(json):
            respond(200, Data(json.utf8))
        case let .status(code, reason):
            respond(code, Data(reason.utf8))
        case .failure:
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
        }
    }

    private func respond(_ code: Int, _ data: Data) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
