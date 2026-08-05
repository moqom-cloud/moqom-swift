// Reading a link that carries an address, a certificate and a credential.
//
// The interesting cases are all refusals. A link that parses to something
// partial is worse than one that fails: the phone keeps whatever it already had
// for the fields the link did not supply, and dials a mixture of two relays that
// nobody ever configured — which is a connection failure with no bad value
// anywhere on screen to explain it.

import Foundation
import Testing

@testable import MoqomKit

@Suite("Relay invitations")
struct RelayInvitationTests {
    private let hash = "polQTlHHCA5xpWTb02GZUdgIJoX5b0rUh0sy+VNWUto="

    @Test("a link survives being written and read back")
    func roundTrip() throws {
        let invitation = RelayInvitation(
            endpoint: RelayEndpoint(host: "35.235.101.37", port: 443),
            certificateHashes: [hash],
            token: Data("header.payload.signature".utf8)
        )

        let url = try #require(invitation.url(scheme: "moqom"))
        let read = try #require(RelayInvitation(url))

        #expect(read.endpoint.host == invitation.endpoint.host)
        #expect(read.endpoint.port == invitation.endpoint.port)
        #expect(read.token == invitation.token)

        // The one worth asserting on its own. Base64 has `+`, `/` and `=` in it,
        // all of which mean something in a query string, and a hash that comes
        // back differing by one character is a relay that cannot be connected to
        // for a reason nothing reports.
        #expect(read.certificateHashes == [hash])
    }

    @Test("a link with no relay in it is refused")
    func noRelay() {
        #expect(RelayInvitation(URL(string: "moqom://join?token=abc")!) == nil)
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

    @Test("a link with no credential is a link to a relay that asks for none")
    func noToken() throws {
        // Legitimate rather than malformed: a relay holding no verification keys
        // admits anyone, which is every relay on a desk.
        let read = try #require(RelayInvitation(URL(string: "moqom://join?relay=r.example")!))
        #expect(read.token.isEmpty)
        #expect(read.url(scheme: "moqom")?.absoluteString.contains("token") == false)
    }

    @Test("a link can enrol a device rather than hand it one credential")
    func carriesAService() throws {
        let invitation = RelayInvitation(
            endpoint: RelayEndpoint(host: "35.235.101.37", port: 443),
            certificateHashes: [hash],
            tokenService: TokenService(
                endpoint: RelayEndpoint(host: "34.94.176.34", port: 8444),
                certificateHashes: ["AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="],
                credential: "0f1e2d3c"
            )
        )

        let url = try #require(invitation.url(scheme: "moqom"))
        let read = try #require(RelayInvitation(url))
        let service = try #require(read.tokenService)

        #expect(service.endpoint.host == "34.94.176.34")
        #expect(service.endpoint.port == 8444)
        #expect(service.credential == "0f1e2d3c")
        // The two hashes stay apart. They are certificates on different machines,
        // and a link that crossed them would pin each connection to the other's —
        // two failures with nothing wrong on screen.
        #expect(service.certificateHashes == ["AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="])
        #expect(read.certificateHashes == [hash])
    }

    @Test("a service that is named has to parse")
    func badService() {
        // Refused rather than read as "no service", because a link that mentions
        // one and is quietly read as having none produces a phone that asks nobody
        // for a token and then joins as nobody.
        #expect(RelayInvitation(URL(string: "moqom://join?relay=r.example&join=c.example:https")!) == nil)
    }

    @Test("a service with no port named gets the join listener's own")
    func serviceDefaultPort() throws {
        let read = try #require(RelayInvitation(URL(string: "moqom://join?relay=r.example&join=c.example")!))
        #expect(read.tokenService?.endpoint.port == 8444)
    }

    @Test("the scheme is the application's to choose, not the framework's")
    func anyScheme() throws {
        let read = try #require(RelayInvitation(URL(string: "https://moqom.cloud/j?relay=r.example:8443")!))
        #expect(read.endpoint.port == 8443)
    }
}
