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

    public init(endpoint: RelayEndpoint, certificateHashes: [String] = [], token: Data = Data()) {
        self.endpoint = endpoint
        self.certificateHashes = certificateHashes
        self.token = token
    }

    // The query names. Short, because every character is another module in the
    // QR code, and a credential is already four hundred of them.
    private enum Key {
        static let relay = "relay"
        static let certificate = "cert"
        static let token = "token"
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

        guard let address = values(Key.relay).first else { return nil }

        // Split from the right, so an IPv6 literal in brackets keeps its colons.
        let host: String
        var port: UInt16 = 443
        if let colon = address.lastIndex(of: ":"), !address.hasSuffix("]") {
            host = String(address[address.startIndex ..< colon])
            guard let given = UInt16(address[address.index(after: colon)...]) else { return nil }
            port = given
        } else {
            host = address
        }
        guard !host.isEmpty else { return nil }

        endpoint = RelayEndpoint(host: host, port: port)
        certificateHashes = values(Key.certificate)
        token = Data((values(Key.token).first ?? "").utf8)
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
        components.queryItems =
            [URLQueryItem(name: Key.relay, value: "\(endpoint.host):\(endpoint.port)")]
            + certificateHashes.map { URLQueryItem(name: Key.certificate, value: $0) }
            + (token.isEmpty
                ? []
                : [URLQueryItem(name: Key.token, value: String(decoding: token, as: UTF8.self))])
        return components.url
    }
}
