// Everything a device needs to dial a relay, in one thing that fits in a QR code.
//
// Three facts have to arrive together and none of them can be typed. An address
// can just about be read off a screen; a certificate hash is forty-four
// characters of base64 where a single transposition produces a connection that
// fails with no explanation; and a token is four hundred characters that expire
// in fifteen minutes. Handing those over one at a time is how a phone ends up
// pinned to the right certificate on the wrong port, or holding yesterday's
// credential for today's relay.
//
// Fifteen minutes is also what makes putting a credential in a link acceptable
// rather than reckless. This is a bearer token — see the control plane's
// `MaxLifetime` — so a link is worth exactly as much as the time left on it, and
// anyone photographing one over a shoulder has a quarter of an hour to use it.
// A longer-lived credential does not belong in something designed to be pointed
// at with a camera.
//
// > Important: A link chooses which relay to trust, so accepting one is a trust
// > decision and not a convenience. An application should show where it has been
// > asked to connect and let somebody agree to it, rather than acting on a URL
// > that arrived from somewhere unknown. The SDK parses; it does not consent.

import Foundation

/// Where to dial, what to trust there, and what to present on arrival.
public struct RelayInvitation: Hashable, Sendable {
    public var endpoint: RelayEndpoint

    /// SHA-256 hashes of certificates to accept, base64, as the relay prints them.
    ///
    /// Empty means ordinary platform validation, which is what a relay holding a
    /// certificate from a public authority wants.
    public var certificateHashes: [String]

    /// The credential to present, or empty for none.
    public var token: Data

    /// Where the device may fetch its own credentials, if it is allowed to.
    ///
    /// The field that changes what a link is worth. A link carrying a token is
    /// good for fifteen minutes and then it is litter; a link carrying a service
    /// works tomorrow, because the phone fetches a fresh token every time it
    /// dials. That is the entire reason this exists — a code printed for somebody
    /// to scan was expiring between being printed and being scanned.
    ///
    /// It is also a real weakening, stated plainly because it should not be
    /// discovered later. A device credential does not expire on its own, so a link
    /// carrying one is durable access to joining rooms in that tenant until
    /// somebody rotates it. Against that: it grants only joining — never
    /// moderation, never ownership, and only in one tenant — and the alternative
    /// in practice was people mailing each other tokens and wondering why they
    /// stopped working.
    public var tokenService: TokenService?

    public init(
        endpoint: RelayEndpoint,
        certificateHashes: [String] = [],
        token: Data = Data(),
        tokenService: TokenService? = nil
    ) {
        self.endpoint = endpoint
        self.certificateHashes = certificateHashes
        self.token = token
        self.tokenService = tokenService
    }

    // The query names. Short, because every character is another module in the
    // QR code, and a credential is already four hundred of them.
    private enum Key {
        static let relay = "relay"
        static let certificate = "cert"
        static let token = "token"

        // The token service's three, named apart from the relay's because they
        // describe a different machine with a different certificate. A link that
        // reused `cert` for both would pin each to the other's hash, and the
        // symptom is two connections that fail with nothing wrong on screen.
        static let service = "join"
        static let serviceCertificate = "joincert"
        static let credential = "key"
    }

    /// Read a link, or refuse it.
    ///
    /// The scheme is not checked, because which scheme belongs to the
    /// application is the application's business and a framework guessing at it
    /// is a framework that has to be reconfigured to be used. What is checked is
    /// that the thing describes a relay: a link with no address, or with a port
    /// that is not a port, is refused rather than half-applied. Half-applying it
    /// is worse than refusing — the phone keeps whichever fields the link did
    /// not mention, and dials a mixture of two relays that nobody configured.
    public init?(_ url: URL) {
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let items = components.queryItems
        else { return nil }

        func values(_ name: String) -> [String] {
            items.filter { $0.name == name }.compactMap(\.value).filter { !$0.isEmpty }
        }

        guard
            let address = values(Key.relay).first,
            let relay = Self.endpoint(address, defaultPort: 443)
        else { return nil }

        endpoint = relay
        certificateHashes = values(Key.certificate)
        token = Data((values(Key.token).first ?? "").utf8)

        // The service is optional and, when named, has to parse. A link that
        // mentions one and is silently read as having none produces a phone that
        // asks nobody for a token and joins as nobody, which is the failure this
        // field was added to remove.
        if let named = values(Key.service).first {
            guard let service = Self.endpoint(named, defaultPort: 8444) else { return nil }
            tokenService = TokenService(
                endpoint: service,
                certificateHashes: values(Key.serviceCertificate),
                credential: values(Key.credential).first ?? ""
            )
        }
    }

    /// `host`, `host:port`, or `[v6]:port`.
    ///
    /// Split from the right and only outside brackets, so an IPv6 literal keeps
    /// its colons. A port that will not parse is a refusal rather than a fallback
    /// to the default: dialling 443 when the link said 4443 is, from the phone, a
    /// relay that is down.
    private static func endpoint(_ address: String, defaultPort: UInt16) -> RelayEndpoint? {
        var host = address
        var port = defaultPort
        if let colon = address.lastIndex(of: ":"), !address.hasSuffix("]") {
            host = String(address[address.startIndex ..< colon])
            guard let given = UInt16(address[address.index(after: colon)...]) else { return nil }
            port = given
        }
        guard !host.isEmpty else { return nil }
        return RelayEndpoint(host: host, port: port)
    }

    /// Write the link, under the application's own scheme.
    ///
    /// The hash goes in as the relay prints it, padding and slashes and all, and
    /// is percent-encoded on the way. Re-encoding it into some URL-friendlier
    /// alphabet would mean the string in the link and the string in the
    /// deployment's own output no longer match, and the first thing anybody does
    /// with two hashes is compare them by eye.
    public func url(scheme: String, host: String = "join") -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        var items = [URLQueryItem(name: Key.relay, value: "\(endpoint.host):\(endpoint.port)")]
        for hash in certificateHashes {
            items.append(URLQueryItem(name: Key.certificate, value: hash))
        }
        if !token.isEmpty {
            items.append(
                URLQueryItem(name: Key.token, value: String(decoding: token, as: UTF8.self))
            )
        }
        if let service = tokenService {
            let address = "\(service.endpoint.host):\(service.endpoint.port)"
            items.append(URLQueryItem(name: Key.service, value: address))
            for hash in service.certificateHashes {
                items.append(URLQueryItem(name: Key.serviceCertificate, value: hash))
            }
            if !service.credential.isEmpty {
                items.append(URLQueryItem(name: Key.credential, value: service.credential))
            }
        }

        components.queryItems = items
        return components.url
    }
}
