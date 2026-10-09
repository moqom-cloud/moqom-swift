// Fetching a credential from the application's backend, and the ways that goes wrong.
//
// The parsing is worth testing rather than eyeballing because both halves of it
// are cross-language agreements that fail quietly. The expiry is written by Go's
// encoding/json and read by Foundation, and a fraction of a second in the format
// that one side omits and the other requires produces a date of 1970 — which
// reads as "expired" and sends a client into a refresh loop against a token that
// was perfectly good. The publish grant decides which side of a room's keys a
// device stands on, and a grant misread as "not stated" or the other way round
// puts a viewer in the group or a guest in the audience. The error mapping
// decides whether a phone retries, stops, or asks somebody to sign in again.

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

    private static let endpoint = URL(string: "https://tokens.example/v1/token")!

    private func service(_ answers: Stub.Answer) -> (TokenService, URLSession) {
        Stub.answer = answers
        return (TokenService(url: Self.endpoint, authorization: "enrollment-secret"), Self.stubbed())
    }

    private static func stubbed() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        return URLSession(configuration: configuration)
    }

    @Test("a token comes back with the moment it dies")
    func issued() async throws {
        let (service, session) = self.service(.ok("""
        {"token":"opaque-sealed-bytes",
         "expiresAt":"2026-08-05T18:15:00.123456789Z",
         "room":"handsync","username":"ada","keyId":"abc",
         "device":"\(key.thumbprint)","publish":["audio","video"],"tenant":"moqom"}
        """))

        let issued = try await service.token(
            username: "ada", room: "handsync", device: key, session: session
        )

        #expect(issued.token == Data("opaque-sealed-bytes".utf8))
        #expect(issued.username == "ada")
        #expect(issued.room == "handsync")
        #expect(issued.device == key.thumbprint)
        #expect(issued.tenant == "moqom")
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
        {"token":"t","expiresAt":"2026-08-05T18:15:00Z","room":"r","username":"u"}
        """))

        let issued = try await service.token(
            username: "u", room: "r", device: key, session: session
        )
        #expect(issued.expiresAt.timeIntervalSince1970 == 1_785_953_700)
        #expect(issued.direct == .default)
    }

    @Test("the publish grant is read from the response, and silence is not a grant")
    func publishGrant() async throws {
        let (full, session) = self.service(.ok("""
        {"token":"t","expiresAt":"2026-08-05T18:15:00Z",
         "publish":["audio","video","screen_share","data"]}
        """))
        let guest = try await full.token(username: "u", room: "r", device: key, session: session)
        #expect(guest.publish == .full)
        #expect(guest.mayPublish)

        let (empty, again) = self.service(.ok(#"{"token":"t","expiresAt":"2026-08-05T18:15:00Z","publish":[]}"#))
        let viewer = try await empty.token(username: "u", room: "r", device: key, session: again)
        #expect(viewer.publish == PublishScope.none)
        #expect(!viewer.mayPublish)

        // Not stated, which is a different answer from an empty list: the
        // session keeps a device whose grant nobody stated in the group.
        let (silent, third) = self.service(.ok(#"{"token":"t","expiresAt":"2026-08-05T18:15:00Z"}"#))
        let unknown = try await silent.token(username: "u", room: "r", device: key, session: third)
        #expect(unknown.publish == nil)
        #expect(!unknown.mayPublish)
        // Defaulted to the key that was sent, which is the key it is bound to.
        #expect(unknown.device == key.thumbprint)

        // A kind this build has never heard of is dropped, not fatal.
        let (newer, fourth) = self.service(.ok(#"{"token":"t","expiresAt":"2026-08-05T18:15:00Z","publish":["audio","hologram"]}"#))
        #expect(try await newer.token(username: "u", room: "r", device: key, session: fourth).publish == .audioOnly)
    }

    @Test("a grant in a shape that is not a list is a fault, not a guess")
    func publishMalformed() async {
        let (service, session) = self.service(.ok(#"{"token":"t","expiresAt":"2026-08-05T18:15:00Z","publish":15}"#))
        await #expect(throws: TokenServiceError.self) {
            try await service.token(username: "u", room: "r", device: key, session: session)
        }
    }

    @Test("the room's direct policy comes back with the token")
    func directPolicy() async throws {
        let (service, session) = self.service(.ok("""
        {"token":"t","expiresAt":"2026-08-05T18:15:00Z","room":"r","username":"u",
         "direct":{"allowed":true,"maxParticipants":2}}
        """))
        let issued = try await service.token(username: "u", room: "r", device: key, session: session)
        #expect(issued.direct == DirectRoomPolicy(allowed: true, maximumParticipants: 2))

        let (refusing, again) = self.service(.ok("""
        {"token":"t","expiresAt":"2026-08-05T18:15:00Z","direct":{"allowed":false}}
        """))
        let relayOnly = try await refusing.token(username: "u", room: "r", device: key, session: again)
        #expect(!relayOnly.direct.allowed)
        #expect(DirectRoomPolicy(allowed: true, maximumParticipants: 40).maximumParticipants == 4)
        #expect(issued.direct.stun == nil)
    }

    @Test("the relays' STUN server comes back with the token")
    func stunServer() async throws {
        let (service, session) = self.service(.ok("""
        {"token":"t","expiresAt":"2026-08-05T18:15:00Z","room":"r","username":"u",
         "direct":{"allowed":true,"maxParticipants":4,"stun":{"host":"relay.moqom.cloud","port":3478}}}
        """))
        let issued = try await service.token(username: "u", room: "r", device: key, session: session)
        #expect(issued.direct.stun == DirectSTUNServer(host: "relay.moqom.cloud", port: 3478))

        // Nothing a device could dial is no server at all.
        for stun in [#"{"host":"","port":3478}"#, #"{"host":"r","port":0}"#, #"{"host":"r","port":70000}"#, #"{"host":"r"}"#] {
            #expect(DirectRoomPolicy(json: try JSONSerialization.jsonObject(with: Data(#"{"stun":\#(stun)}"#.utf8))).stun == nil)
        }
    }

    @Test("what the device asks for is what it sends, to the backend it was given")
    func requestBody() async throws {
        let (service, session) = self.service(.ok(#"{"token":"t","room":"r","username":"u"}"#))
        _ = try await service.token(username: "Ada", room: "handsync", device: key, session: session)

        let sent = try #require(Stub.received)
        #expect(sent.httpMethod == "POST")
        #expect(sent.url == Self.endpoint)
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/json")
        // The session goes in a header and never in the URL. A secret in a
        // query string is a secret in every access log between here and the
        // backend.
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer enrollment-secret")

        let body = try #require(Stub.body)
        let decoded = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(Set(decoded.keys) == ["key", "device", "room", "username"])
        #expect(decoded["username"] as? String == "Ada")
        #expect(decoded["room"] as? String == "handsync")

        // The key, not just its name. The control plane derives `cnf.jkt` from
        // what is sent here, so a request that carried only the thumbprint would
        // get a token bound to a claim rather than to a key — and this assertion
        // is the one that notices if that regresses.
        let sentKey = try #require(decoded["key"] as? [String: String])
        #expect(sentKey == key.jwk.members)
        #expect(sentKey == ["kty": "AKP", "alg": "ML-DSA-87", "pub": try #require(key.jwk.pub)])

        // Truncated the way a namespace field is, since that is what the device
        // announces under and what the control plane checks the key against.
        #expect(decoded["device"] as? String == String(key.thumbprint.prefix(16)))
    }

    @Test("an address that is not https is refused before anything is sent")
    func notHTTPS() async {
        Stub.received = nil
        let plain = TokenService(url: URL(string: "http://tokens.example/v1/token")!, authorization: "s")
        await #expect(throws: TokenServiceError.notAnAddress) {
            try await plain.token(username: "u", room: "r", device: key, session: Self.stubbed())
        }
        #expect(Stub.received == nil)
    }

    @Test("a sign-in sends the identity token and the key, and returns an enrollment")
    func signIn() async throws {
        Stub.answer = .ok("""
        {"token":"first","expiresAt":"2026-08-05T18:15:00.5Z","room":"demo","username":"apple-7f3a",
         "device":"\(key.thumbprint)","keyId":"k1","publish":[],
         "enrollment":"durable-secret","enrollmentExpiresAt":"2026-11-05T18:15:00Z"}
        """)
        let url = URL(string: "https://tokens.example/v1/sign-in")!

        let signedIn = try await TokenService.signIn(
            url: url, identityToken: "apple.identity.jwt", room: "demo", device: key, session: Self.stubbed()
        )

        let sent = try #require(Stub.received)
        #expect(sent.url == url)
        #expect(sent.httpMethod == "POST")
        // Nothing to present yet: the identity token is the credential.
        #expect(sent.value(forHTTPHeaderField: "Authorization") == nil)
        let body = try #require(Stub.body)
        let decoded = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(Set(decoded.keys) == ["identityToken", "key", "room"])
        #expect(decoded["identityToken"] as? String == "apple.identity.jwt")
        #expect(decoded["room"] as? String == "demo")
        #expect(decoded["key"] as? [String: String] == key.jwk.members)

        #expect(signedIn.enrollment == "durable-secret")
        #expect(signedIn.enrollmentExpiresAt.timeIntervalSince1970 == 1_793_902_500)
        #expect(signedIn.issued.token == Data("first".utf8))
        #expect(signedIn.issued.username == "apple-7f3a")
        #expect(signedIn.issued.publish == PublishScope.none)
        #expect(abs(signedIn.issued.expiresAt.timeIntervalSince1970 - 1_785_953_700.5) < 0.01)
    }

    @Test("a sign-in that returns no enrollment is a fault")
    func signInWithoutEnrollment() async {
        Stub.answer = .ok(#"{"token":"first","expiresAt":"2026-08-05T18:15:00Z"}"#)
        await #expect(throws: TokenServiceError.self) {
            try await TokenService.signIn(
                url: URL(string: "https://tokens.example/v1/sign-in")!,
                identityToken: "x", room: "demo", device: key, session: Self.stubbed()
            )
        }
    }

    @Test("a refusal keeps the reason, because somebody has to read it")
    func refused() async throws {
        let (service, session) = self.service(.status(404, "room not found"))

        do {
            _ = try await service.token(username: "ada", room: "r", device: key, session: session)
            Issue.record("a refusal produced a token")
        } catch {
            guard case let .refused(status, reason) = error else {
                Issue.record("a 404 became \(error)")
                return
            }
            #expect(status == 404)
            #expect(reason == "room not found")
            // Nothing about this changes on a retry, and a client that retries a
            // permanent refusal is a spinner that never stops.
            #expect(!error.isWorthRetrying)
            #expect(!error.needsSignIn)
        }
    }

    @Test("a 401 says the device has to sign in again")
    func signInAgain() async {
        let (service, session) = self.service(.status(401, "enrollment revoked"))
        do {
            _ = try await service.token(username: "ada", room: "r", device: key, session: session)
            Issue.record("a revoked enrollment produced a token")
        } catch {
            #expect(error.needsSignIn)
            #expect(!error.isWorthRetrying)
            #expect(error.errorDescription?.contains("Sign in again") == true)
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
        } catch {
            guard case .unreachable = error else {
                Issue.record("an unreachable service became \(error)")
                return
            }
            #expect(error.isWorthRetrying)
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
        } catch {
            guard case .malformed = error else {
                Issue.record("a bodyless response became \(error)")
                return
            }
        }
    }

    @Test("a token about to expire is not worth presenting")
    func margin() {
        let now = Date()
        let issued = { (seconds: TimeInterval) in
            IssuedToken(
                token: Data("t".utf8),
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

    @Test("a renewal that does not restate the grant keeps the one already known")
    func renewalKeepsGrant() {
        var credentials = DeviceCredentials(identity: identity("bob"), token: Data("a".utf8), deviceKey: nil)
        #expect(credentials.publish == nil)

        let viewer = IssuedToken(token: Data("b".utf8), expiresAt: Date(), username: "bob", room: "r", publish: [])
        credentials = credentials.replacing(with: viewer)
        #expect(credentials.publish == PublishScope.none)

        let silent = IssuedToken(token: Data("c".utf8), expiresAt: Date(), username: "bob", room: "r")
        credentials = credentials.replacing(with: silent)
        #expect(credentials.publish == PublishScope.none)

        let promoted = IssuedToken(token: Data("d".utf8), expiresAt: Date(), username: "bob", room: "r", publish: .camera)
        #expect(credentials.replacing(with: promoted).publish == .camera)
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
