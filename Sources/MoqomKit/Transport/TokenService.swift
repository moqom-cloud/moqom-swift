// Asking the application's own backend for a token, immediately before dialling.
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
// the application's backend, never MOQOM. The backend knows who signed in; it
// calls the control plane's `MintClientToken` with a key that lives on the
// server, and hands back a token bound to this device's key. MOQOM never sees a
// secret on the device and the device never holds one that can mint: what it
// presents here is whatever session the backend gave it — the reference token
// server's enrollment, a cookie's worth of bearer, an OAuth access token — and
// what that is worth is the backend's decision, made with knowledge of the user
// that MOQOM does not have.
//
// This replaces the control plane's `POST /join`, which answered the same
// question for anybody holding a device credential compiled into an app. A
// credential in an app is a credential anybody can extract, and that one could
// mint a token for any name in its tenant.
//
// Nothing in a token is read here, or anywhere else in the SDK. Tokens are
// sealed (AES-256-GCM) and opaque to the device that holds them; everything a
// client needs to know about one — when it dies, who it names, what it may
// publish — is in the response beside it, as stated by the backend that asked
// for it. A client that decoded its token would break the day the format
// changed, and the format has already changed once.

import Foundation
import MoqomCore
import os

#if canImport(Security)
    import Security
#endif
#if canImport(DeviceCheck)
    import DeviceCheck
#endif
#if canImport(CryptoKit)
    import CryptoKit
#endif

/// A credential, and enough about it to know when to ask again.
public struct IssuedToken: Sendable, Hashable {
    /// The token itself, as it goes on the wire. Opaque: nothing in the SDK
    /// reads it, and nothing in an application should.
    public var token: Data

    /// When it stops being accepted.
    ///
    /// Reported by the service rather than read out of the token, because the
    /// token cannot be read. A client that has to parse the credential to
    /// schedule its own refresh is a client that gets it wrong once and then
    /// caches the mistake.
    public var expiresAt: Date

    /// The name the token was actually minted for.
    ///
    /// Worth returning because it can differ from what was asked — a username
    /// is normalised on the way in, and a backend that knows who signed in may
    /// ignore the request's name altogether. A device that displays what it
    /// requested while the room displays what was issued is a device showing
    /// the wrong person's name.
    public var username: String

    public var room: String

    /// What the room allows of direct paths. ``DirectRoomPolicy/default``
    /// when the service does not say.
    public var direct: DirectRoomPolicy

    /// What the token permits this device to publish, as the service stated
    /// it; `nil` when it did not say.
    ///
    /// The relay enforces the grant whatever this says. What it decides on the
    /// device is which side of the room's keys to stand on — a member of the
    /// MLS group or a viewer sealed its keys — and what an interface offers.
    /// `nil` cannot be resolved by looking at the token, so it is left to the
    /// caller: ``mayPublish`` reads it as no, and a ``MoqomSession`` reads it as
    /// a member, as every device was before viewers were keyed apart.
    public var publish: PublishScope?

    /// The device key the token is bound to, as the full RFC 7638 thumbprint.
    /// Empty when unknown.
    public var device: String

    /// The tenant the token was minted in, which a session's namespaces must
    /// be under. Empty when the service did not say.
    public var tenant: String

    public init(
        token: Data,
        expiresAt: Date,
        username: String,
        room: String,
        direct: DirectRoomPolicy = .default,
        publish: PublishScope? = nil,
        device: String = "",
        tenant: String = ""
    ) {
        self.token = token
        self.expiresAt = expiresAt
        self.username = username
        self.room = room
        self.direct = direct
        self.publish = publish
        self.device = device
        self.tenant = tenant
    }

    /// Whether the service said this token may publish anything at all.
    ///
    /// `false` when it did not say, which is the answer that cannot put a
    /// button on screen the relay will then refuse.
    public var mayPublish: Bool { publish.map { !$0.isEmpty } ?? false }

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

/// Where to ask for a token, and what to present when asking: the
/// application's backend, and this device's session with it.
///
/// The request is `POST url` with `Authorization: Bearer <authorization>` and
/// the body `{"key": <device JWK>, "device": <truncated thumbprint>, "room": …,
/// "username": …}`. The answer is `{"token", "expiresAt", "tenant", "room",
/// "username", "device", "publish", "direct"}`, with `expiresAt` in RFC 3339 and `publish`
/// a subset of `audio`, `video`, `screen_share` and `data`. A backend that
/// answers that shape is all this needs; MOQOM's reference token server is one.
public struct TokenService: Sendable, Hashable {
    /// The backend's token endpoint, in full: `https://tokens.example.com/v1/token`.
    ///
    /// HTTPS only. The request carries this device's session with the backend
    /// in a header, and in the clear that is a session for whoever is listening.
    public var url: URL

    /// SHA-256 hashes of certificates to accept, base64.
    ///
    /// Empty means ordinary platform validation, which is what a backend behind
    /// a publicly trusted certificate wants and what almost every one is.
    /// Pinning is for a backend that issues its own.
    public var certificateHashes: [String]

    /// This device's session with the backend, sent as `Bearer`.
    ///
    /// Whatever the backend issued when the user signed in — the reference
    /// server's enrollment, from ``signIn(url:identityToken:room:device:certificateHashes:session:)``.
    /// It is a secret, and belongs in the keychain. What bounds it is what the
    /// backend lets it buy, which is the backend's to decide: the reference
    /// server binds it to one user and one device key and lets it be revoked.
    public var authorization: String

    /// The App Attest key to sign each request with, for a service that wants
    /// proof every token is asked for by the genuine app on the same device:
    /// MOQOM's hosted Apple sign-in. The assertion covers the SHA-256 of the
    /// exact body and goes in `X-Moqom-Assertion`. `nil` sends none.
    public var appAttestKeyID: String?

    public init(
        url: URL,
        authorization: String,
        certificateHashes: [String] = [],
        appAttestKeyID: String? = nil
    ) {
        self.url = url
        self.authorization = authorization
        self.certificateHashes = certificateHashes
        self.appAttestKeyID = appAttestKeyID
    }

    /// Ask for a token for this name, in this room, on this device.
    ///
    /// - Parameters:
    ///   - username: what the device would like to be called. A backend that
    ///     knows who signed in may ignore it; ``IssuedToken/username`` is what
    ///     was actually minted.
    ///   - device: The key this token is to be bound to. The public half is
    ///     sent and the control plane derives `cnf.jkt` from it rather than
    ///     accepting a thumbprint, because a thumbprint from a client is a claim
    ///     about which key it holds and the relay will later demand a signature
    ///     from whatever the claim names. Sending the key is what makes those two
    ///     the same key by construction rather than by agreement.
    ///   - session: for tests; `nil` makes one that pins ``certificateHashes``.
    public func token(
        username: String,
        room: String,
        device: DeviceKey,
        session: URLSession? = nil
    ) async throws(TokenServiceError) -> IssuedToken {
        let data = try await Self.post(
            [
                "key": device.jwk.members,
                // The truncated form this device announces under. The control
                // plane checks it against what the key actually hashes to, so a
                // client whose namespace and whose key disagree is told here
                // rather than at a relay.
                "device": DeviceID.field(of: device.thumbprint),
                "room": room,
                "username": username,
            ],
            to: url,
            authorization: authorization,
            assertingWith: appAttestKeyID,
            pinning: certificateHashes,
            session: session
        )
        return try Self.read(Self.object(data), room: room, username: username, device: device)
    }

    /// What a sign-in returns: a first token, and the session to ask for the
    /// next one with.
    public struct SignIn: Sendable, Hashable {
        public var issued: IssuedToken

        /// The value for ``TokenService/authorization``. A secret, and the
        /// durable one: keep it in the keychain.
        public var enrollment: String

        /// When the backend stops accepting ``enrollment``, after which the
        /// user signs in again.
        public var enrollmentExpiresAt: Date

        /// The App Attest key attested at sign-in, for
        /// ``TokenService/appAttestKeyID``. `nil` for a backend that does not
        /// use App Attest. Not a secret: the key never leaves the Secure
        /// Enclave, but keep it beside the enrollment.
        public var appAttestKeyID: String?

        public init(
            issued: IssuedToken,
            enrollment: String,
            enrollmentExpiresAt: Date,
            appAttestKeyID: String? = nil
        ) {
            self.issued = issued
            self.enrollment = enrollment
            self.enrollmentExpiresAt = enrollmentExpiresAt
            self.appAttestKeyID = appAttestKeyID
        }

        /// The service to ask for every later token with.
        public func tokenService(url: URL, certificateHashes: [String] = []) -> TokenService {
            TokenService(
                url: url,
                authorization: enrollment,
                certificateHashes: certificateHashes,
                appAttestKeyID: appAttestKeyID
            )
        }
    }

    /// Exchange a Sign in with Apple identity token for a first token and an
    /// enrollment, at a backend speaking the reference token server's
    /// `POST /v1/sign-in`.
    ///
    /// The Apple authorization request's `nonce` must be ``DeviceKey/thumbprint``
    /// of `device`, untruncated. The backend checks that the identity token's
    /// nonce is the thumbprint of the key in this request, which is what binds
    /// the sign-in to this device: an identity token lifted off one phone is
    /// refused alongside any other phone's key. Asking for no scopes is enough;
    /// the backend needs the stable subject, not a name or an address.
    ///
    /// The interface half — `ASAuthorizationController`, or SwiftUI's
    /// `SignInWithAppleButton` — belongs to the application, which owns its
    /// windows.
    ///
    /// - Parameter url: the sign-in endpoint in full,
    ///   `https://tokens.example.com/v1/sign-in`.
    public static func signIn(
        url: URL,
        identityToken: String,
        room: String,
        device: DeviceKey,
        certificateHashes: [String] = [],
        session: URLSession? = nil
    ) async throws(TokenServiceError) -> SignIn {
        let data = try await post(
            ["identityToken": identityToken, "key": device.jwk.members, "room": room],
            to: url,
            authorization: nil,
            pinning: certificateHashes,
            session: session
        )
        return try signedIn(data, room: room, device: device, appAttestKeyID: nil)
    }

    #if canImport(DeviceCheck) && canImport(CryptoKit)
        /// Sign in with Apple sign-in hosted by MOQOM, for an app with no
        /// backend of its own.
        ///
        /// The tenant turns it on with the admin API's `SetAppleSignIn`, naming
        /// the app, the rooms and what a signed-in person may publish. Besides
        /// the identity token, whose `nonce` must be ``DeviceKey/thumbprint``, a
        /// fresh App Attest key is attested over the SHA-256 of the identity
        /// token, so the control plane knows the request comes from the genuine
        /// app on a real device. Renew with ``SignIn/tokenService(url:certificateHashes:)``
        /// at `https://<control plane host>/v1/apple/token`, which signs every
        /// renewal with the same App Attest key.
        ///
        /// - Parameter url: `https://<control plane host>/v1/apple/sign-in`.
        @available(iOS 14.0, macOS 11.0, tvOS 15.0, visionOS 1.0, *)
        public static func appleSignIn(
            url: URL,
            tenant: String,
            identityToken: String,
            room: String,
            device: DeviceKey,
            certificateHashes: [String] = [],
            session: URLSession? = nil
        ) async throws(TokenServiceError) -> SignIn {
            let attest = DCAppAttestService.shared
            guard attest.isSupported else {
                throw .malformed("App Attest is not available on this device")
            }
            let keyID: String
            let attestation: Data
            do {
                keyID = try await attest.generateKey()
                attestation = try await attest.attestKey(
                    keyID, clientDataHash: Data(SHA256.hash(data: Data(identityToken.utf8))))
            } catch {
                throw .unreachable("App Attest could not attest a key: \(error.localizedDescription)")
            }
            let data = try await post(
                [
                    "tenant": tenant,
                    "identityToken": identityToken,
                    "attestation": attestation.base64EncodedString(),
                    "attestKeyId": keyID,
                    "key": device.jwk.members,
                    "room": room,
                ],
                to: url,
                authorization: nil,
                pinning: certificateHashes,
                session: session
            )
            return try signedIn(data, room: room, device: device, appAttestKeyID: keyID)
        }
    #endif

    private static func signedIn(
        _ data: Data,
        room: String,
        device: DeviceKey,
        appAttestKeyID: String?
    ) throws(TokenServiceError) -> SignIn {
        let body = try object(data)
        let issued = try read(body, room: room, username: "", device: device)
        guard let enrollment = body["enrollment"] as? String, !enrollment.isEmpty else {
            throw .malformed("no enrollment in the sign-in response")
        }
        return SignIn(
            issued: issued,
            enrollment: enrollment,
            enrollmentExpiresAt: (body["enrollmentExpiresAt"] as? String).flatMap(instant) ?? issued.expiresAt,
            appAttestKeyID: appAttestKeyID
        )
    }

    private static func post(
        _ fields: [String: Any],
        to url: URL,
        authorization: String?,
        assertingWith appAttestKeyID: String? = nil,
        pinning hashes: [String],
        session: URLSession?
    ) async throws(TokenServiceError) -> Data {
        guard url.scheme?.lowercased() == "https", url.host?.isEmpty == false else {
            throw .notAnAddress
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let authorization {
            request.setValue("Bearer \(authorization)", forHTTPHeaderField: "Authorization")
        }
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: fields)
        } catch {
            throw .malformed("could not write the request: \(error)")
        }
        if let appAttestKeyID, let body = request.httpBody {
            try await request.setValue(
                assertion(over: body, keyID: appAttestKeyID).base64EncodedString(),
                forHTTPHeaderField: "X-Moqom-Assertion")
        }
        // Short, because this sits in front of a connection somebody is waiting
        // for. A token service that hangs for the platform's default of sixty
        // seconds is a Join button that does nothing for a minute, which is
        // indistinguishable from a Join button that is broken.
        request.timeoutInterval = 10

        let pinned = session.map { Pinned(session: $0, trust: nil) } ?? Self.session(pinning: hashes)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await pinned.session.data(for: request)
        } catch {
            throw whyThatFailed(error, pinned, expected: hashes)
        }

        guard let status = (response as? HTTPURLResponse)?.statusCode else {
            throw .malformed("not an HTTP response")
        }
        guard status == 200 else {
            // The body, because the backend puts something actionable in it and
            // this is the message a person will be shown: a room that does not
            // exist, a session that has to sign in again, too many attempts.
            let reason = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw .refused(status: status, reason: reason)
        }
        return data
    }

    private static func assertion(over body: Data, keyID: String) async throws(TokenServiceError) -> Data {
        #if canImport(DeviceCheck) && canImport(CryptoKit)
            if #available(iOS 14.0, macOS 11.0, tvOS 15.0, visionOS 1.0, *) {
                do {
                    return try await DCAppAttestService.shared.generateAssertion(
                        keyID, clientDataHash: Data(SHA256.hash(data: body)))
                } catch {
                    throw .unreachable("App Attest could not sign the request: \(error.localizedDescription)")
                }
            }
        #endif
        throw .malformed("App Attest is not available on this platform")
    }

    private static func object(_ data: Data) throws(TokenServiceError) -> [String: Any] {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw .malformed("the response is not a JSON object")
        }
        return body
    }

    static func read(
        _ body: [String: Any],
        room: String,
        username: String,
        device: DeviceKey
    ) throws(TokenServiceError) -> IssuedToken {
        guard let token = body["token"] as? String, !token.isEmpty else {
            throw .malformed("no token in the response")
        }

        // RFC 3339 with fractional seconds, which is what Go's encoding/json
        // writes for a time.Time. Parsed leniently — both with and without the
        // fraction — because a service that starts omitting a zero fraction
        // should not become a client that cannot read its own credential.
        let expires = (body["expiresAt"] as? String).flatMap(Self.instant) ?? Date()

        // Absent is "not stated" and stays distinct from an empty list, which
        // is a viewer. Present and not a list of names is the service's bug,
        // and reading it as either would be guessing at a grant.
        var publish: PublishScope?
        if let stated = body["publish"], !(stated is NSNull) {
            guard let names = stated as? [String] else {
                throw .malformed("publish is not a list of media kinds")
            }
            publish = PublishScope(names: names)
        }

        return IssuedToken(
            token: Data(token.utf8),
            expiresAt: expires,
            username: body["username"] as? String ?? username,
            room: body["room"] as? String ?? room,
            direct: DirectRoomPolicy(json: body["direct"]),
            publish: publish,
            device: body["device"] as? String ?? device.thumbprint,
            tenant: body["tenant"] as? String ?? ""
        )
    }

    static func instant(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    /// A session and the pin it is enforcing, so the failure can be explained.
    struct Pinned {
        var session: URLSession
        var trust: PinnedTrust?
    }

    /// A session that trusts exactly these certificates, or the platform's.
    ///
    /// Shared with ``HTTPMLSDelivery``, which pins its own endpoint the same way.
    static func session(pinning hashes: [String]) -> Pinned {
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

extension PublishScope {
    /// The names a token service states a grant in: `audio`, `video`,
    /// `screen_share` and `data`. Names this build does not know are dropped,
    /// so a service that grants something new is read as granting the rest.
    init(names: [String]) {
        self = names.reduce(into: []) { scope, name in
            switch name {
            case "audio": scope.insert(.audio)
            case "video": scope.insert(.video)
            case "screen_share": scope.insert(.screenShare)
            case "data": scope.insert(.data)
            default: break
            }
        }
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
    /// the address, or another service's hash pasted where this one's belongs.
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

    /// Whether the backend no longer accepts this device's session, and the
    /// user has to sign in again before another token can be had.
    public var needsSignIn: Bool {
        if case .refused(401, _) = self { true } else { false }
    }
}

extension TokenServiceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notAnAddress:
            "The token service address is not usable; it has to be an https URL."
        case let .unreachable(reason):
            "Could not reach the token service: \(reason)"
        case let .refused(status, reason):
            // The status alone is not a sentence anybody can act on, and the
            // reason alone loses whether this is worth trying again.
            status == 401
                ? "The token service no longer accepts this device. Sign in again."
                    + (reason.isEmpty ? "" : " (\(reason))")
                : reason.isEmpty ? "The token service refused the request (\(status))."
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

/// Certificate pinning for the token request and the MLS delivery service.
///
/// The same policy as the media path's, applied through a different mechanism
/// because a URLSession decides trust in a delegate callback rather than through
/// a QUIC parameter. Written out here rather than reaching for
/// `allowsAnySSLCertificate`-shaped shortcuts: these connections carry a bearer
/// secret in a header, so accepting any certificate on them is handing that
/// secret to whoever answers the address.
final class PinnedTrust: NSObject, URLSessionDelegate, Sendable {
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
