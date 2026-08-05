// Asking for a credential instead of being configured with one.
//
// A token is capped at fifteen minutes, because it is a bearer credential and
// its lifetime is the window a stolen one is useful for. That cap is correct and
// it makes a token useless as configuration. Every way of putting one on a device
// by hand — a launch argument, a pasted string, a scanned code — produces a phone
// that works for a quarter of an hour and is then refused, with the reason sealed
// inside a credential nobody can read. Measured in this project: the most common
// failure of a two-phone session was an expired token, and the symptom was a
// session that connected and carried nothing.
//
// So the device asks, immediately before it dials, every time. What it asks is
// not the control plane's admin API — that surface can mint moderators and is
// reached over mutual TLS from inside a private network. It is one route that
// exists to answer this one question; see `internal/server/join.go`.
//
// What this is not is authentication. The credential below says which deployment
// and which tenant this device belongs to, and nothing about who is holding it: a
// device that can ask for a token for one name can ask for a token for another.
// An application with real users puts its own server here, which knows who signed
// in, and this is the thing that stands where that server would be.

import Foundation
import MoqomCore
import os

#if canImport(Security)
    import Security
#endif

/// A credential, and enough about it to know when to ask again.
public struct IssuedToken: Sendable, Hashable {
    /// The token itself, as it goes on the wire.
    public var token: Data

    /// When it stops being accepted.
    ///
    /// Reported by the service rather than read out of the token, so a client
    /// does not have to decode a JWS to find out. A client that has to parse the
    /// credential to schedule its own refresh is a client that gets it wrong once
    /// and then caches the mistake.
    public var expiresAt: Date

    /// The name the token was actually minted for, after normalisation.
    ///
    /// Worth returning because it can differ from what was asked. A username is
    /// normalised on the way in, and a device that displays what it requested
    /// while the room displays what was issued is a device showing the wrong
    /// person's name.
    public var username: String

    public var room: String

    public init(token: Data, expiresAt: Date, username: String, room: String) {
        self.token = token
        self.expiresAt = expiresAt
        self.username = username
        self.room = room
    }

    /// Whether this is worth presenting, allowing for the walk to the relay.
    ///
    /// A margin rather than a comparison against now, because a token that is
    /// valid at the moment it is checked and expired at the moment it is verified
    /// fails in the least legible way available: the connection is made, the
    /// session is admitted as nobody, and nothing on either side says why.
    public func isUsable(at moment: Date = Date(), margin: TimeInterval = 30) -> Bool {
        expiresAt.timeIntervalSince(moment) > margin
    }
}

/// Where to ask for a token, and what to present when asking.
public struct TokenService: Sendable, Hashable {
    /// The join listener's address. Not the relay's, and not the admin API's.
    public var endpoint: RelayEndpoint

    /// SHA-256 hashes of certificates to accept, base64.
    ///
    /// Pinned for the same reason the relay's is: a deployment issues its own
    /// certificates, and this endpoint serves the one the control plane already
    /// holds. Empty means ordinary platform validation, which is what a
    /// deployment behind a publicly trusted certificate wants.
    ///
    /// This matters more here than it does for media. A relay reached through the
    /// wrong certificate is an eavesdropper on a broadcast; a token service
    /// reached through the wrong certificate is handed this device's credential.
    public var certificateHashes: [String]

    /// The long-lived credential this device holds.
    ///
    /// Long-lived is the point and also the cost. It is what lets a phone ask for
    /// a fresh token months after it was set up, and it is a secret on a device,
    /// which means it belongs in the keychain and not in a defaults database. What
    /// bounds it is what it can buy: joining rooms in one tenant, with no
    /// moderation and no ownership, whatever the request says. See the endpoint.
    public var credential: String

    /// Which tenant to ask about. Empty asks for the credential's own.
    public var tenant: String

    public init(
        endpoint: RelayEndpoint,
        certificateHashes: [String] = [],
        credential: String,
        tenant: String = ""
    ) {
        self.endpoint = endpoint
        self.certificateHashes = certificateHashes
        self.credential = credential
        self.tenant = tenant
    }

    /// Ask for a token for this name, in this room, on this device.
    ///
    /// - Parameter device: A thumbprint of a key this device holds, which the
    ///   token is bound to by its `cnf` claim. Recorded rather than proven today;
    ///   what it buys already is that a stolen token names a device, so it can be
    ///   banned without banning the person.
    public func token(
        username: String,
        room: String,
        device: String,
        session: URLSession? = nil
    ) async throws -> IssuedToken {
        var components = URLComponents()
        components.scheme = "https"
        components.host = endpoint.host
        components.port = Int(endpoint.port)
        components.path = "/join"
        guard let url = components.url else { throw TokenServiceError.notAnAddress }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "tenant": tenant,
            "username": username,
            "room": room,
            "device": device,
        ])
        // Short, because this sits in front of a connection somebody is waiting
        // for. A token service that hangs for the platform's default of sixty
        // seconds is a Join button that does nothing for a minute, which is
        // indistinguishable from a Join button that is broken.
        request.timeoutInterval = 10

        let pinned = session.map { Pinned(session: $0, trust: nil) }
            ?? Self.session(pinning: certificateHashes)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await pinned.session.data(for: request)
        } catch {
            throw Self.whyThatFailed(error, pinned, expected: certificateHashes)
        }

        guard let status = (response as? HTTPURLResponse)?.statusCode else {
            throw TokenServiceError.malformed("not an HTTP response")
        }
        guard status == 200 else {
            // The body, because the endpoint puts something actionable in it and
            // this is the message a person will be shown: a room that has ended,
            // a name that will not normalise, a credential that may not publish.
            let reason = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw TokenServiceError.refused(status: status, reason: reason)
        }

        return try Self.read(data, room: room, username: username)
    }

    private static func read(_ data: Data, room: String, username: String) throws -> IssuedToken {
        guard
            let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let token = body["token"] as? String, !token.isEmpty
        else { throw TokenServiceError.malformed("no token in the response") }

        // ISO 8601 with fractional seconds, which is what Go's encoding/json
        // writes for a time.Time. Parsed leniently — both with and without the
        // fraction — because a service that starts omitting a zero fraction
        // should not become a client that cannot read its own credential.
        let expires = (body["expiresAt"] as? String).flatMap(Self.instant) ?? Date()

        return IssuedToken(
            token: Data(token.utf8),
            expiresAt: expires,
            username: body["username"] as? String ?? username,
            room: body["room"] as? String ?? room
        )
    }

    private static func instant(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    /// A session and the pin it is enforcing, so the failure can be explained.
    fileprivate struct Pinned {
        var session: URLSession
        var trust: PinnedTrust?
    }

    /// A session that trusts exactly these certificates, or the platform's.
    fileprivate static func session(pinning hashes: [String]) -> Pinned {
        guard !hashes.isEmpty else {
            return Pinned(session: URLSession(configuration: .ephemeral), trust: nil)
        }
        let trust = PinnedTrust(hashes: hashes.compactMap { Data(base64Encoded: $0) })
        return Pinned(
            session: URLSession(configuration: .ephemeral, delegate: trust, delegateQueue: nil),
            trust: trust
        )
    }

    /// Turn a URLSession failure into something worth putting on a screen.
    ///
    /// Everything a pinned connection can do wrong arrives as one error: a
    /// cancelled trust challenge is reported as `NSURLErrorSecureConnectionFailed`,
    /// which is also what an unreachable address and a service that is not
    /// listening look like. The delegate saw which of those happened, so it is
    /// asked rather than guessed at.
    fileprivate static func whyThatFailed(
        _ error: any Error,
        _ pinned: Pinned,
        expected: [String]
    ) -> TokenServiceError {
        // The domain and code as well as the sentence. "A TLS error caused the secure
        // connection to fail" is what the platform says for a handshake that failed
        // for any reason at all; -1200 against -1202 against -9836 is the difference
        // between a certificate the platform rejected, one it distrusted, and a
        // protocol it would not speak.
        let what = error as NSError
        let detail = "\(error.localizedDescription) [\(what.domain) \(what.code)]"

        guard let trust = pinned.trust else {
            return .unreachable(detail)
        }
        guard let offered = trust.whatHappened.offered else {
            // No certificate was ever offered, so the pin is not what stopped this.
            // Worth saying out loud: an address with a pin on it invites the reading
            // that the pin is always the suspect, and that reading has cost hours.
            return .unreachable(detail + " — no certificate was offered, so the pin is not the cause")
        }
        let seen = offered.base64EncodedString()
        guard !expected.contains(seen) else {
            // Offered, matched, accepted, and the connection failed anyway, which
            // means the platform overruled the pin rather than disagreeing with it.
            return .unreachable(detail + " — the pinned certificate matched and the platform refused it anyway")
        }
        return .untrusted(offered: seen, expected: expected)
    }
}

/// Why a token could not be had.
///
/// Three cases and not one, because a person can act on the difference and an
/// application should say which it is. Unreachable is a network or a wrong
/// address and is worth retrying; refused is a decision that will be made the
/// same way next time; malformed is this deployment's bug.
public enum TokenServiceError: Error, Sendable, Hashable {
    case notAnAddress
    case unreachable(String)
    case refused(status: Int, reason: String)
    case malformed(String)

    /// The certificate offered is not one this device pins.
    ///
    /// Its own case because it is the one failure whose fix is a configuration
    /// change on this device rather than anything about the network, and because
    /// the two hashes are the whole of the diagnosis: a certificate rotated behind
    /// the address, or the relay's hash pasted where the control plane's belongs.
    case untrusted(offered: String, expected: [String])

    /// Whether asking again shortly is likely to help.
    public var isWorthRetrying: Bool {
        switch self {
        case .unreachable: true
        case let .refused(status, _): status == 429 || status >= 500
        // Retrying pins the same hash against the same certificate.
        case .notAnAddress, .malformed, .untrusted: false
        }
    }
}

extension TokenServiceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notAnAddress:
            "The token service address is not usable."
        case let .unreachable(reason):
            "Could not reach the token service: \(reason)"
        case let .refused(status, reason):
            // The status alone is not a sentence anybody can act on, and the
            // reason alone loses whether this is worth trying again.
            reason.isEmpty ? "The token service refused the request (\(status))."
                : "The token service refused the request: \(reason)"
        case let .malformed(what):
            "The token service answered with something unreadable: \(what)"
        case let .untrusted(offered, expected):
            // Both hashes, because which one is wrong is not knowable from here and
            // is obvious to anybody holding the deployment's output.
            expected.isEmpty
                ? "The token service offered a certificate (\(offered)) and this device pins none."
                : "The token service offered a certificate this device does not pin."
                + " It offered \(offered); this device trusts \(expected.joined(separator: ", "))."
        }
    }
}

/// Certificate pinning for the token request.
///
/// The same policy as the media path's, applied through a different mechanism
/// because a URLSession decides trust in a delegate callback rather than through
/// a QUIC parameter. Written out here rather than reaching for
/// `allowsAnySSLCertificate`-shaped shortcuts: this connection carries the
/// device's long-lived credential in a header, so accepting any certificate on it
/// is handing that credential to whoever answers the address.
private final class PinnedTrust: NSObject, URLSessionDelegate, Sendable {
    let hashes: [Data]

    /// What the handshake actually offered, for the error message.
    ///
    /// A cancelled trust challenge reaches the caller as `NSURLErrorSecureConnectionFailed`
    /// -- "A TLS error caused the secure connection to fail" -- which is the same
    /// sentence a phone shows when the address is wrong, when the service is not
    /// listening, and when the pin does not match. Three different things to go and
    /// do, one sentence. So the outcome is recorded here and read back by whoever
    /// catches the failure.
    struct Outcome: Sendable {
        /// The leaf the server presented, hashed the way a pin is written.
        var offered: Data?
        /// Whether a certificate was seen at all. False means the connection never
        /// got as far as one being offered, which is a different fault entirely.
        var wasOffered: Bool { offered != nil }
    }

    private let outcome = OSAllocatedUnfairLock(initialState: Outcome())

    var whatHappened: Outcome { outcome.withLock { $0 } }

    init(hashes: [Data]) { self.hashes = hashes }

    func urlSession(
        _: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        #if canImport(Security)
            guard
                challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                let trust = challenge.protectionSpace.serverTrust,
                let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                let leaf = chain.first
            else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }

            // The platform's own evaluation is deliberately not consulted. The
            // certificate being pinned is one this deployment issued itself, so
            // asking the platform would fail every time — and an implementation
            // that asks and then ignores the answer is one where the pin is
            // decoration.
            let der = SecCertificateCopyData(leaf) as Data
            let digest = RelayTrust.hash(of: der)
            outcome.withLock { $0.offered = digest }
            guard let digest, hashes.contains(digest) else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
        #else
            // A platform with no way to inspect a certificate has no way to pin
            // one, and falling back to whatever it does trust would turn the
            // stricter policy into a looser one silently.
            completionHandler(.cancelAuthenticationChallenge, nil)
        #endif
    }
}
