// Everything a device needs to find a relay, in one thing that fits in a QR code.
//
// The facts have to arrive together and none of them can be typed. An address
// can just about be read off a screen; a certificate hash is forty-four
// characters of base64 where a single transposition produces a connection that
// fails with no explanation. Handing those over one at a time is how a phone
// ends up pinned to the right certificate on the wrong port.
//
// What a link does not carry is anything that authorises. Not a token: a token
// is bound to the key of the device it was minted for, so one in a link is
// useless to whichever phone scans it. And not a long-lived credential: a link
// is designed to be pointed at with a camera, and anything durable in it is
// durable for whoever photographs it. A link says where the application's
// token server is; the person holding the phone signs in there, and the token
// that comes back is bound to that phone.
//
// Older links carried both — `token=`, and a device credential as `key=` beside
// the control plane's join listener as `join=`. They still parse: the relay and
// its hashes are read, the join listener is read as the MLS delivery service it
// also was, and the token and the credential are dropped without being looked at.
//
// > Important: A link chooses which relay to trust, so accepting one is a trust
// > decision and not a convenience. An application should show where it has been
// > asked to connect and let somebody agree to it, rather than acting on a URL
// > that arrived from somewhere unknown. The SDK parses; it does not consent.

import Foundation

/// Where to dial, what to trust there, and where to sign in.
public struct RelayInvitation: Hashable, Sendable {
    public var endpoint: RelayEndpoint

    /// SHA-256 hashes of certificates to accept, base64, as the relay prints them.
    ///
    /// Empty means ordinary platform validation, which is what a relay holding a
    /// certificate from a public authority wants.
    public var certificateHashes: [String]

    /// The application's token server, as a base URL (`https://tokens.example.com`),
    /// if the link names one.
    ///
    /// Where the device signs in and then asks for a token every time it dials;
    /// the routes under it are the server's to define. HTTPS only, because the
    /// session the device is given there travels in a header.
    public var tokenServer: URL?

    /// The MLS delivery service, if the link names one: an address of its own,
    /// with its own certificate.
    ///
    /// Named apart from the relay because it is a different machine. A link that
    /// reused the relay's hashes for both would pin each to the other's, and the
    /// symptom is two connections that fail with nothing wrong on screen.
    public var keyDeliveryEndpoint: RelayEndpoint?

    /// The hashes to pin ``keyDeliveryEndpoint`` to. Empty means platform trust.
    public var keyDeliveryCertificateHashes: [String]

    /// The room the link is for, or `nil` to leave the choice to the person.
    public var room: String?

    public init(
        endpoint: RelayEndpoint,
        certificateHashes: [String] = [],
        tokenServer: URL? = nil,
        keyDeliveryEndpoint: RelayEndpoint? = nil,
        keyDeliveryCertificateHashes: [String] = [],
        room: String? = nil
    ) {
        self.endpoint = endpoint
        self.certificateHashes = certificateHashes
        self.tokenServer = tokenServer
        self.keyDeliveryEndpoint = keyDeliveryEndpoint
        self.keyDeliveryCertificateHashes = keyDeliveryCertificateHashes
        self.room = room
    }

    /// The delivery service the link names, pinned as it says.
    public var keyDelivery: HTTPMLSDelivery? {
        keyDeliveryEndpoint.map { HTTPMLSDelivery(endpoint: $0, certificateHashes: keyDeliveryCertificateHashes) }
    }

    // The query names. Short, because every character is another module in the
    // QR code.
    private enum Key {
        static let relay = "relay"
        static let certificate = "cert"
        static let tokens = "tokens"
        static let delivery = "mls"
        static let deliveryCertificate = "mlscert"
        static let room = "room"

        // What older links called the delivery service, when it shared the
        // control plane's join listener. Read, never written.
        static let legacyDelivery = "join"
        static let legacyDeliveryCertificate = "joincert"
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
    ///
    /// `token=` and `key=` are ignored. See the file comment.
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
        room = values(Key.room).first

        // Optional and, when named, has to parse. A link that mentions a token
        // server and is silently read as having none produces a phone that has
        // nowhere to sign in and joins as nobody.
        tokenServer = nil
        if let named = values(Key.tokens).first {
            guard
                let server = URL(string: named),
                server.scheme?.lowercased() == "https",
                server.host?.isEmpty == false
            else { return nil }
            tokenServer = server
        }

        keyDeliveryEndpoint = nil
        keyDeliveryCertificateHashes = []
        if let named = values(Key.delivery).first {
            guard let delivery = Self.endpoint(named, defaultPort: 8444) else { return nil }
            keyDeliveryEndpoint = delivery
            keyDeliveryCertificateHashes = values(Key.deliveryCertificate)
        } else if let named = values(Key.legacyDelivery).first {
            guard let delivery = Self.endpoint(named, defaultPort: 8444) else { return nil }
            keyDeliveryEndpoint = delivery
            keyDeliveryCertificateHashes = values(Key.legacyDeliveryCertificate)
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
        if let tokenServer {
            items.append(URLQueryItem(name: Key.tokens, value: tokenServer.absoluteString))
        }
        if let delivery = keyDeliveryEndpoint {
            items.append(URLQueryItem(name: Key.delivery, value: "\(delivery.host):\(delivery.port)"))
            for hash in keyDeliveryCertificateHashes {
                items.append(URLQueryItem(name: Key.deliveryCertificate, value: hash))
            }
        }
        if let room, !room.isEmpty {
            items.append(URLQueryItem(name: Key.room, value: room))
        }

        components.queryItems = items
        return components.url
    }
}
