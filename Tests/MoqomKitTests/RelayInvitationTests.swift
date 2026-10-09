// Reading a link that carries an address, a certificate and a place to sign in.
//
// The interesting cases are all refusals. A link that parses to something
// partial is worse than one that fails: the phone keeps whatever it already had
// for the fields the link did not supply, and dials a mixture of two relays that
// nobody ever configured — which is a connection failure with no bad value
// anywhere on screen to explain it. And the one thing a link never yields is
// something that authorises, whatever an old one has in it.

import Foundation
import Testing

@testable import MoqomKit

@Suite("Relay invitations")
struct RelayInvitationTests {
    private let hash = "polQTlHHCA5xpWTb02GZUdgIJoX5b0rUh0sy+VNWUto="
    private let deliveryHash = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

    @Test("a link survives being written and read back")
    func roundTrip() throws {
        let invitation = RelayInvitation(
            endpoint: RelayEndpoint(host: "35.235.101.37", port: 443),
            certificateHashes: [hash],
            tokenServer: URL(string: "https://tokens.example.com"),
            keyDeliveryEndpoint: RelayEndpoint(host: "34.94.176.34", port: 8444),
            keyDeliveryCertificateHashes: [deliveryHash],
            room: "demo"
        )

        let url = try #require(invitation.url(scheme: "moqom"))
        let read = try #require(RelayInvitation(url))

        #expect(read == invitation)
        // The one worth asserting on its own. Base64 has `+`, `/` and `=` in it,
        // all of which mean something in a query string, and a hash that comes
        // back differing by one character is a relay that cannot be connected to
        // for a reason nothing reports.
        #expect(read.certificateHashes == [hash])
        // The two hashes stay apart. They are certificates on different machines,
        // and a link that crossed them would pin each connection to the other's.
        #expect(read.keyDeliveryCertificateHashes == [deliveryHash])
        #expect(read.keyDelivery?.endpoint == RelayEndpoint(host: "34.94.176.34", port: 8444))
    }

    @Test("a written link carries nothing that authorises")
    func noSecrets() throws {
        let url = try #require(RelayInvitation(
            endpoint: RelayEndpoint(host: "r.example", port: 443),
            tokenServer: URL(string: "https://tokens.example.com")
        ).url(scheme: "moqom"))
        let names = Set(try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems).map(\.name))
        #expect(names == ["relay", "tokens"])
    }

    @Test("an old link's token and credential are dropped, and its join listener is the delivery service")
    func legacyLink() throws {
        let url = URL(string: "moqom://join?relay=r.example&cert=\(hash)&token=header.payload.signature"
            + "&join=c.example:8444&joincert=\(deliveryHash)&key=0f1e2d3c")!
        let read = try #require(RelayInvitation(url))

        #expect(read.endpoint == RelayEndpoint(host: "r.example", port: 443))
        #expect(read.keyDeliveryEndpoint == RelayEndpoint(host: "c.example", port: 8444))
        #expect(read.keyDeliveryCertificateHashes == [deliveryHash])
        #expect(read.tokenServer == nil)

        // And written back without either.
        let rewritten = try #require(read.url(scheme: "moqom")?.absoluteString)
        #expect(!rewritten.contains("token="))
        #expect(!rewritten.contains("key="))
        #expect(!rewritten.contains("0f1e2d3c"))
    }

    @Test("a link with no relay in it is refused")
    func noRelay() {
        #expect(RelayInvitation(URL(string: "moqom://join?token=abc")!) == nil)
        #expect(RelayInvitation(URL(string: "moqom://join?tokens=https://tokens.example.com")!) == nil)
        #expect(RelayInvitation(URL(string: "moqom://join")!) == nil)
        #expect(RelayInvitation(URL(string: "moqom://join?relay=")!) == nil)
    }

    @Test("a port that is not a port is refused rather than ignored")
    func badPort() {
        // Ignoring it would silently mean 443, and a relay listening on 4443
        // would be dialled at the wrong one — which from the phone is a relay
        // that is down.
        #expect(RelayInvitation(URL(string: "moqom://join?relay=relay.example:https")!) == nil)
        #expect(RelayInvitation(URL(string: "moqom://join?relay=relay.example:99999")!) == nil)
    }

    @Test("a relay with no port named gets the usual one")
    func defaultPort() throws {
        let read = try #require(RelayInvitation(URL(string: "moqom://join?relay=relay.example")!))
        #expect(read.endpoint.host == "relay.example")
        #expect(read.endpoint.port == 443)
        #expect(read.tokenServer == nil)
        #expect(read.keyDeliveryEndpoint == nil)
        #expect(read.room == nil)
    }

    @Test("an address keeps its colons when they belong to it")
    func addressWithColons() throws {
        // Split from the right and only outside brackets, so a v6 literal
        // arrives as an address rather than as a host called `[2001` on some
        // port that will not parse.
        let read = try #require(RelayInvitation(URL(string: "moqom://join?relay=[2001:db8::1]")!))
        #expect(read.endpoint.host == "[2001:db8::1]")
        #expect(read.endpoint.port == 443)
    }

    @Test("more than one certificate can be trusted, for a rotation")
    func severalHashes() throws {
        let second = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
        let url = URL(string: "moqom://join?relay=r.example&cert=\(hash)&cert=\(second)")!
        let read = try #require(RelayInvitation(url))
        #expect(read.certificateHashes.count == 2)
    }

    @Test("a token server that is named has to be an https URL")
    func badTokenServer() {
        // Refused rather than read as "no server", because a link that mentions
        // one and is quietly read as having none produces a phone with nowhere
        // to sign in.
        #expect(RelayInvitation(URL(string: "moqom://join?relay=r.example&tokens=http://tokens.example.com")!) == nil)
        #expect(RelayInvitation(URL(string: "moqom://join?relay=r.example&tokens=tokens.example.com")!) == nil)
    }

    @Test("a delivery service that is named has to parse")
    func badDelivery() {
        #expect(RelayInvitation(URL(string: "moqom://join?relay=r.example&mls=c.example:https")!) == nil)
        #expect(RelayInvitation(URL(string: "moqom://join?relay=r.example&join=c.example:https")!) == nil)
    }

    @Test("a delivery service with no port named gets the control plane's listener port")
    func deliveryDefaultPort() throws {
        let read = try #require(RelayInvitation(URL(string: "moqom://join?relay=r.example&mls=c.example")!))
        #expect(read.keyDeliveryEndpoint?.port == 8444)
    }

    @Test("the scheme is the application's to choose, not the framework's")
    func anyScheme() throws {
        let read = try #require(RelayInvitation(URL(string: "https://moqom.cloud/j?relay=r.example:8443")!))
        #expect(read.endpoint.port == 8443)
    }
}
