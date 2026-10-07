// Direct tickets: the check against the relay's, and a peer holding the other
// to them over a real direct session.
//
// Tickets are minted here as the Rust relay's tests mint them (an ML-DSA-65 seed
// of elevens, kid `ticket-test`), with the same header and claims.

import CryptoKit
import Foundation
import Testing

@testable import MoqomCore
import MoqomDirectTesting
@testable import MoqomKit
@testable import MoqomLoopback

enum DirectTickets {
    static let signer = try! MLDSA65.PrivateKey(seedRepresentation: Data(repeating: 11, count: 32), publicKey: nil)
    static let keys = [DirectVerificationKey(id: "ticket-test", key: signer.publicKey.rawRepresentation, algorithm: .mlDSA65)]

    static func mint(
        holder: DirectDevice,
        peer: DirectDevice,
        tenant: String = "acme",
        room: String = "room-42",
        issued: Date = Date(),
        lifetime: TimeInterval = 90,
        typ: String = DirectTicketCheck.type,
        kid: String = "ticket-test",
        signer: MLDSA65.PrivateKey = DirectTickets.signer
    ) -> Data {
        DirectTokens.jws(
            ["alg": "ML-DSA-65", "typ": typ, "kid": kid],
            [
                "ten": tenant,
                "room": room,
                "sub": holder.user,
                "dev": String(holder.key.thumbprint.prefix(16)),
                "peer": peer.name,
                "iat": Int(issued.timeIntervalSince1970),
                "exp": Int(issued.addingTimeInterval(lifetime).timeIntervalSince1970),
            ]
        ) { try! signer.signature(for: $0) }
    }

    /// The relay's ticket object for a ticket, as `moqom-relay` writes it.
    static func object(_ ticket: Data, expires: Date) -> Data {
        let key = signer.publicKey.rawRepresentation.base64URLEncodedString
        let keys: [[String: Any]] = [["kty": "AKP", "alg": "ML-DSA-65", "kid": "ticket-test", "pub": key]]
        let object: [String: Any] = [
            "version": 1,
            "ticket": String(decoding: ticket, as: UTF8.self),
            "expires": Int(expires.timeIntervalSince1970),
            "keys": keys,
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    static func ticket(holder: DirectDevice, peer: DirectDevice, lifetime: TimeInterval = 90) -> DirectTicket {
        let issued = Date()
        let compact = mint(holder: holder, peer: peer, issued: issued, lifetime: lifetime)
        return try! DirectTicket(object: object(compact, expires: issued.addingTimeInterval(lifetime)))
    }
}

extension DirectDevice {
    /// As a direct session's verified peer.
    var verified: VerifiedDirectPeer {
        VerifiedDirectPeer(
            tenant: "acme",
            user: user,
            device: String(key.thumbprint.prefix(16)),
            room: "room-42",
            mayPublish: true
        )
    }
}

@Suite("Checking a direct ticket as the relay would")
struct DirectTicketCheckTests {
    let alice = DirectDevice(user: "alice")
    let bob = DirectDevice(user: "bob")

    func verify(_ ticket: Data, now: Date = Date()) -> Result<Date, DirectTicketRefusal> {
        Result { () throws(DirectTicketRefusal) in
            try DirectTicketCheck.verify(ticket, keys: DirectTickets.keys, holder: alice.verified, me: bob.name, now: now)
        }
    }

    @Test("the relay's ticket object reads back to the ticket, its expiry and the ticket keys")
    func object() throws {
        let ticket = DirectTickets.ticket(holder: alice, peer: bob, lifetime: 90)
        #expect(ticket.keys == DirectTickets.keys)
        #expect(abs(ticket.expires.timeIntervalSinceNow - 90) < 2)
        #expect(throws: DirectTicketRefusal.malformed) { try DirectTicket(object: Data("{}".utf8)) }
        #expect(throws: DirectTicketRefusal.malformed) {
            try DirectTicket(object: Data(#"{"version":2,"ticket":"a","expires":1,"keys":[]}"#.utf8))
        }
    }

    @Test("a good ticket verifies, and every way one is wrong is refused")
    func refusals() throws {
        let good = DirectTickets.mint(holder: alice, peer: bob)
        #expect(verify(good).map { abs($0.timeIntervalSinceNow - 90) < 2 } == .success(true))

        let other = try MLDSA65.PrivateKey(seedRepresentation: Data(repeating: 9, count: 32), publicKey: nil)
        let carol = DirectDevice(user: "carol")
        var tampered = [UInt8](good)
        tampered[tampered.count - 3] = tampered[tampered.count - 3] == UInt8(ascii: "A") ? UInt8(ascii: "B") : UInt8(ascii: "A")
        let cases: [(Data, DirectTicketRefusal)] = [
            (DirectTickets.mint(holder: alice, peer: bob, signer: other), .badSignature),
            (Data(tampered), .badSignature),
            (DirectTickets.mint(holder: alice, peer: bob, kid: "test-key"), .unknownKey),
            (DirectTokens.mint(user: "alice", key: alice.key), .unsupported),
            (DirectTickets.mint(holder: alice, peer: bob, issued: Date().addingTimeInterval(-200)), .expired),
            (DirectTickets.mint(holder: alice, peer: bob, issued: Date().addingTimeInterval(120)), .notYetValid),
            (DirectTickets.mint(holder: alice, peer: bob, room: "room-43"), .wrongHolder),
            (DirectTickets.mint(holder: alice, peer: bob, tenant: "other"), .wrongHolder),
            (DirectTickets.mint(holder: carol, peer: bob), .wrongHolder),
            (DirectTickets.mint(holder: alice, peer: carol), .wrongPeer),
            (Data("a.b".utf8), .malformed),
            (Data(repeating: 0x61, count: 4096), .malformed),
        ]
        for (ticket, refusal) in cases {
            #expect(verify(ticket) == .failure(refusal), "\(refusal)")
        }
        // Within the clock skew of its expiry a ticket is still good.
        let lapsed = DirectTickets.mint(holder: alice, peer: bob, issued: Date().addingTimeInterval(-100))
        #expect((try? verify(lapsed).get()) != nil)
    }

    @Test("a ticket is checked only against the ticket keys, never the token keys")
    func separateKeys() {
        let ticket = DirectTickets.mint(holder: alice, peer: bob, kid: "test-key", signer: DirectTokens.signer)
        #expect(
            Result { () throws(DirectTicketRefusal) in
                try DirectTicketCheck.verify(ticket, keys: DirectTickets.keys, holder: alice.verified, me: bob.name)
            } == .failure(.unknownKey)
        )
    }
}

@Suite("Holding a direct peer to its tickets", .serialized)
struct DirectTicketGuardTests {
    let endpoints = DirectEndpointTests()
    var alice: DirectDevice { endpoints.alice }
    var bob: DirectDevice { endpoints.bob }

    static let quick = DirectTicketSettings(grace: .seconds(1), represent: .milliseconds(100), skew: .zero)

    /// A relay's ticket feed, driven by the test.
    func feed() -> (AsyncStream<DirectTicket>, AsyncStream<DirectTicket>.Continuation) {
        AsyncStream.makeStream(of: DirectTicket.self)
    }

    func guarded(
        _ direct: DirectSession,
        me: DirectDevice,
        tickets: AsyncStream<DirectTicket>,
        ended: Collector<DirectTicketRefusal>
    ) -> DirectTicketGuard {
        DirectTicketGuard(direct: direct, me: me.name, tickets: tickets, settings: Self.quick) { reason in
            await ended.append(reason)
        }
    }

    @Test("renewed tickets keep the direct path up, and it ends when they stop")
    func renewalKeepsItUp() async throws {
        let (fromAlice, fromBob) = try await endpoints.establish()
        let atAlice = try fromAlice.get()
        let atBob = try fromBob.get()
        let (aliceTickets, aliceRelay) = feed()
        let (bobTickets, bobRelay) = feed()
        let aliceEnded = Collector<DirectTicketRefusal>()
        let bobEnded = Collector<DirectTicketRefusal>()
        let atAliceGuard = guarded(atAlice, me: alice, tickets: aliceTickets, ended: aliceEnded)
        let atBobGuard = guarded(atBob, me: bob, tickets: bobTickets, ended: bobEnded)

        // Three-second tickets, renewed every second: well past the first
        // ones' expiry and the grace period, nobody is cut off.
        for _ in 0 ..< 4 {
            aliceRelay.yield(DirectTickets.ticket(holder: alice, peer: bob, lifetime: 3))
            bobRelay.yield(DirectTickets.ticket(holder: bob, peer: alice, lifetime: 3))
            try await Task.sleep(for: .seconds(1))
        }
        #expect(await atAliceGuard.ended == nil)
        #expect(await atBobGuard.ended == nil)
        #expect(await atBobGuard.peerTicketExpires != nil)
        let frames = ["frame-0", "frame-1", "frame-2"]
        #expect(try await endpoints.exchange(from: atAlice.session, to: atBob.session, track: endpoints.track(alice)) == frames)

        // Alice's relay stops issuing. Bob's are still good, so only Bob,
        // holding Alice to hers, ends the path.
        bobRelay.yield(DirectTickets.ticket(holder: bob, peer: alice, lifetime: 60))
        #expect(await eventually(timeout: .seconds(5)) { await bobEnded.items == [.expired] })
        #expect(await atAliceGuard.ended == nil)

        aliceRelay.finish()
        bobRelay.finish()
        await atAliceGuard.stop()
        await atAlice.session.close(code: 0, reason: "done")
    }

    @Test("a peer that presents no ticket loses the direct path, and the relay carries on")
    func missingTicketFallsBack() async throws {
        let (fromAlice, fromBob) = try await endpoints.establish()
        let atAlice = try fromAlice.get()
        let atBob = try fromBob.get()
        let track = try endpoints.track(alice)

        let relay = LoopbackRelay()
        let transport = LoopbackTransport(relay: relay)
        let endpoint = RelayEndpoint(host: "relay.test")
        let alicesRelay = try await transport.connect(to: endpoint, credentials: alice.credentials())
        let bobsRelay = try await transport.connect(to: endpoint, credentials: bob.credentials())
        let relayWriter = try await alicesRelay.publish(track, priority: 64)
        let directWriter = try await atAlice.session.publish(track, priority: 64)
        let dual = DualSubscription(
            relay: try await bobsRelay.subscribe(SubscribeRequest(track: track)),
            settings: DirectPathSettings(settle: .zero, stall: .seconds(5), held: 64, quiet: .seconds(30))
        )
        await dual.attachDirect(try await atBob.session.subscribe(SubscribeRequest(track: track)))
        #expect(await eventually { await atAlice.session.hasSubscriber(for: track) })

        // Alice is a modified app: media over the direct path, no tickets.
        let (bobTickets, bobRelay) = feed()
        bobRelay.yield(DirectTickets.ticket(holder: bob, peer: alice))
        let bobEnded = Collector<DirectTicketRefusal>()
        _ = guarded(atBob, me: bob, tickets: bobTickets, ended: bobEnded)

        let object = TrackObject(group: 0, object: 0, payload: Data("g0".utf8))
        try await directWriter.write(object)
        try await relayWriter.write(object)
        #expect(await eventually { await dual.path == .direct })
        #expect(await eventually { await dual.isRelayPaused })

        #expect(await eventually(timeout: .seconds(5)) { await bobEnded.items == [.missing] })
        #expect(await eventually { await dual.path == .relay })
        #expect(await eventually { await !dual.isRelayPaused }, "the relay forwards again")

        bobRelay.finish()
        await dual.cancel()
        await atAlice.session.close(code: 0, reason: "done")
    }

    @Test("a forged ticket ends the direct path at once")
    func forgedTicketEndsIt() async throws {
        let (fromAlice, fromBob) = try await endpoints.establish()
        let atAlice = try fromAlice.get()
        let atBob = try fromBob.get()
        let (aliceTickets, aliceRelay) = feed()
        let (bobTickets, bobRelay) = feed()
        let bobEnded = Collector<DirectTicketRefusal>()
        let patient = DirectTicketSettings(grace: .seconds(10), represent: .milliseconds(100), skew: .zero)
        let atAliceGuard = DirectTicketGuard(direct: atAlice, me: alice.name, tickets: aliceTickets, settings: patient)
        _ = DirectTicketGuard(direct: atBob, me: bob.name, tickets: bobTickets, settings: patient) { reason in
            await bobEnded.append(reason)
        }

        // Alice's app signs its own, with a key of its choosing and the ticket
        // keys' kid. Bob takes his keys from his relay, not from Alice.
        let forger = try MLDSA65.PrivateKey(seedRepresentation: Data(repeating: 3, count: 32), publicKey: nil)
        let forged = DirectTickets.mint(holder: alice, peer: bob, signer: forger)
        aliceRelay.yield(DirectTicket(compact: forged, expires: Date().addingTimeInterval(90), keys: DirectTickets.keys))
        bobRelay.yield(DirectTickets.ticket(holder: bob, peer: alice))

        #expect(await eventually(timeout: .seconds(5)) { await bobEnded.items == [.badSignature] })
        #expect(await eventually { await atAliceGuard.ended == nil })

        aliceRelay.finish()
        bobRelay.finish()
        await atAliceGuard.stop()
        await atAlice.session.close(code: 0, reason: "done")
    }
}
