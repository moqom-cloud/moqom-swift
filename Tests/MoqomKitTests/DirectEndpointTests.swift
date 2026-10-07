// Direct paths for real: two endpoints on this machine, real QUIC through
// Network.framework, real certificates, real tokens signed and checked the way
// a relay checks them.
//
// The tokens are minted with the Rust suite's test key and the same claims; see
// MoqomDirectTesting, which MoqomDirectRustTests shares.

import CryptoKit
import Foundation
import Testing

@testable import MoqomCore
import MoqomDirectTesting
@testable import MoqomKit
@testable import MoqomLoopback
import MoqomWire

// MARK: - The relay's checks, in Swift

@Suite("Checking a direct peer as a relay would")
struct DirectPeerCheckTests {
    let binding = "local-certificate-identity"
    let alice = DirectDevice(user: "alice")

    func proof(_ token: Data, for binding: String? = nil, key: DeviceKey? = nil) throws -> Data {
        try (key ?? alice.key).proof(over: token, for: binding ?? self.binding)
    }

    func verify(
        _ token: Data,
        proof: Data?,
        check: DirectPeerCheck = DirectPeerCheck(keys: DirectTokens.keys),
        now: Date = Date()
    ) -> Result<VerifiedDirectPeer, DirectPeerRefusal> {
        Result { () throws(DirectPeerRefusal) in
            try check.verify(token: token, proof: proof, localCertificate: binding, now: now)
        }
    }

    @Test("a good token and proof name the peer, its device, room and grant")
    func admits() throws {
        let token = DirectTokens.mint(user: "alice", key: alice.key)
        let peer = try verify(token, proof: try proof(token)).get()
        #expect(peer.tenant == "acme")
        #expect(peer.user == "alice")
        #expect(peer.participant == alice.name)
        #expect(peer.room == "room-42")
        #expect(peer.mayPublish)
    }

    @Test("every way a token is wrong is refused, with the relay's reason")
    func tokenRefusals() throws {
        let other = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 9, count: 32))
        let cases: [(Data, DirectPeerRefusal)] = [
            (DirectTokens.mint(user: "alice", key: alice.key, kid: "nope"), .unknownKey),
            (DirectTokens.mint(user: "alice", key: alice.key, signer: other), .badSignature),
            (DirectTokens.mint(user: "alice", key: alice.key, expires: Date().addingTimeInterval(-60)), .expired),
            (DirectTokens.mint(user: "alice", key: alice.key, issued: Date().addingTimeInterval(120)), .notYetValid),
            (DirectTokens.mint(user: "", key: alice.key), .incomplete),
            (DirectTokens.mint(user: "alice", key: alice.key, capabilities: 0x0800_0000), .unsupportedToken),
            (DirectTokens.mint(user: "alice", key: alice.key, extraScope: ["new": 1]), .malformedToken("claims are not JSON")),
            (Data("a.b".utf8), .malformedToken("expected three segments")),
        ]
        for (token, refusal) in cases {
            #expect(verify(token, proof: try proof(token)) == .failure(refusal), "\(refusal)")
        }
        // Within the clock skew either way is not a refusal.
        let skewed = DirectTokens.mint(user: "alice", key: alice.key, expires: Date().addingTimeInterval(-20))
        #expect((try? verify(skewed, proof: try proof(skewed)).get()) != nil)
    }

    @Test("every way a proof is wrong is refused, and a refused proof is not spent")
    func proofRefusals() throws {
        let token = DirectTokens.mint(user: "alice", key: alice.key)
        let other = DirectTokens.mint(user: "alice", key: alice.key, room: "room-43")
        let check = DirectPeerCheck(keys: DirectTokens.keys)

        #expect(verify(token, proof: nil, check: check) == .failure(.proofMissing))
        #expect(verify(token, proof: try proof(token, for: "another"), check: check) == .failure(.proofWrongRelay))
        #expect(verify(token, proof: try proof(other), check: check) == .failure(.proofWrongToken))
        #expect(
            verify(token, proof: try proof(token, key: DeviceKey.ephemeral()), check: check)
                == .failure(.proofWrongKey)
        )
        var tampered = [UInt8](try proof(token))
        tampered[tampered.count - 3] ^= 0x01
        #expect(verify(token, proof: Data(tampered), check: check) == .failure(.proofBadSignature))

        let good = try proof(token)
        #expect((try? verify(token, proof: good, check: check).get()) != nil)
        #expect(verify(token, proof: good, check: check) == .failure(.proofReplayed))
    }

    @Test("no keys verify nobody, and no token is refused rather than admitted")
    func nothingToCheck() throws {
        let token = DirectTokens.mint(user: "alice", key: alice.key)
        #expect(verify(token, proof: try proof(token), check: DirectPeerCheck(keys: [])) == .failure(.unverifiable))
        #expect(verify(Data(), proof: nil) == .failure(.anonymous))
    }

    @Test("the direct-path rules: same tenant and room, publishing, and the offer's sender")
    func admissible() throws {
        func peer(tenant: String = "acme", room: String? = "room-42", publish: Bool = true, user: String = "alice")
            -> VerifiedDirectPeer {
            VerifiedDirectPeer(tenant: tenant, user: user, device: "0123456789abcdef", room: room, mayPublish: publish)
        }
        let me = (tenant: "acme", room: "room-42", from: "alice/0123456789abcdef")
        func admit(_ peer: VerifiedDirectPeer) -> DirectPeerRefusal? {
            do throws(DirectPeerRefusal) {
                try directAdmissible(peer, tenant: me.tenant, room: me.room, participant: me.from)
                return nil
            } catch { return error }
        }
        #expect(admit(peer()) == nil)
        #expect(admit(peer(tenant: "other")) == .anotherRoom)
        #expect(admit(peer(room: "room-43")) == .anotherRoom)
        #expect(admit(peer(room: nil)) == .anotherRoom)
        #expect(admit(peer(publish: false)) == .viewer)
        #expect(admit(peer(user: "mallory")) == .wrongParticipant)
        #expect(DirectPeerRefusal.viewer.description == "viewers never use direct paths")
    }

    @Test("a JWK set reads as the relay's does")
    func keySet() throws {
        let x = DirectTokens.signer.publicKey.rawRepresentation.base64URLEncodedString
        let document = Data(#"{"keys":[{"kty":"OKP","crv":"Ed25519","kid":"test-key","x":"\#(x)"}]}"#.utf8)
        #expect(try DirectVerificationKey.parseSet(document) == DirectTokens.keys)
        let wrongCurve = Data(#"[{"kty":"OKP","crv":"X25519","kid":"k","x":"\#(x)"}]"#.utf8)
        #expect(throws: DirectPeerRefusal.unverifiable) { try DirectVerificationKey.parseSet(wrongCurve) }
    }
}

// MARK: - Certificates and STUN

@Suite("Direct endpoint parts")
struct DirectPartsTests {
    @Test("a certificate is fresh each time, and identified by the hash of its DER")
    func certificate() throws {
        let one = try DirectCertificate.generate()
        let two = try DirectCertificate.generate()
        #expect(one.fingerprint != two.fingerprint)
        #expect(one.fingerprint == Data(SHA256.hash(data: one.der)))
        #expect(one.identity == one.fingerprint.base64URLEncodedString)
        #expect(SecCertificateCreateWithData(nil, one.der as CFData) != nil)
    }

    @Test("a STUN response reads back to the address it names, in both families")
    func stun() throws {
        let transaction = [UInt8](0 ..< 12)
        for address in [DirectCandidate(host: "203.0.113.7", port: 40000)!, DirectCandidate(host: "2001:db8::7", port: 3478)!] {
            let response = DirectSTUN.response(transaction: transaction, from: address)
            #expect(DirectSTUN.parse(response, transaction: transaction) == address)
            #expect(DirectSTUN.parse(response, transaction: [UInt8](repeating: 0, count: 12)) == nil)
        }
        #expect(DirectSTUN.request(transaction: transaction).count == 20)
    }
}

// MARK: - Two endpoints

@Suite("Direct sessions between two endpoints on this machine", .serialized)
struct DirectEndpointTests {
    let alice = DirectDevice(user: "alice")
    let bob = DirectDevice(user: "bob")

    func endpoint(_ device: DirectDevice, patience: Duration = .seconds(4)) async throws -> DirectEndpoint {
        try await DirectPair.endpoint(device, patience: patience)
    }

    typealias Outcome = DirectPair.Outcome

    /// Both sides establishing at once, as they would after trading offers.
    func establish(
        aliceToken: Data? = nil,
        bobToken: Data? = nil,
        offerToAlice: (CandidateOffer) -> CandidateOffer = { $0 },
        patience: Duration = .seconds(4)
    ) async throws -> (alice: Outcome, bob: Outcome) {
        try await DirectPair.establish(
            alice: alice,
            bob: bob,
            aliceToken: aliceToken,
            bobToken: bobToken,
            offerToAlice: offerToAlice,
            patience: patience
        )
    }

    func track(_ publisher: DirectDevice) throws -> FullTrackName {
        try FullTrackName(
            namespace: MoqomNamespaces.participant(
                tenant: "acme",
                room: "room-42",
                identity: ParticipantIdentity(
                    username: try Username(publisher.user),
                    device: try DeviceID(thumbprint: publisher.key.thumbprint)
                )
            ),
            name: try TrackName("camera")
        )
    }

    /// Objects one way over a direct session pair.
    func exchange(from publisher: MoqtSession, to subscriber: MoqtSession, track: FullTrackName) async throws -> [String] {
        let writer = try await publisher.publish(track, priority: 64)
        let subscription = try await subscriber.subscribe(SubscribeRequest(track: track))
        let received = Collector<TrackObject>()
        let reader = Task { for await object in subscription.objects { await received.append(object) } }
        #expect(await eventually { await publisher.hasSubscriber(for: track) })
        for index in 0 ..< 3 {
            try await writer.write(TrackObject(group: 0, object: UInt64(index), payload: Data("frame-\(index)".utf8)))
        }
        _ = await eventually { await received.items.count == 3 }
        reader.cancel()
        await subscription.cancel()
        return await received.items.sorted { $0.object < $1.object }.map { String(decoding: $0.payload, as: UTF8.self) }
    }

    @Test("two endpoints connect, verify each other, and carry media both ways")
    func connectsAndCarriesMedia() async throws {
        let (fromAlice, fromBob) = try await establish()
        let atAlice = try fromAlice.get()
        let atBob = try fromBob.get()

        #expect(atAlice.peer.participant == bob.name)
        #expect(atBob.peer.participant == alice.name)
        #expect(atAlice.peer.room == "room-42")

        let frames = ["frame-0", "frame-1", "frame-2"]
        #expect(try await exchange(from: atAlice.session, to: atBob.session, track: track(alice)) == frames)
        #expect(try await exchange(from: atBob.session, to: atAlice.session, track: track(bob)) == frames)

        #expect(atAlice.usage.bytesSent > 0)
        #expect(atAlice.usage.bytesReceived > 0)
        #expect(atBob.usage.bytesReceived > 0)

        await atAlice.session.close(code: 0, reason: "done")
        await atBob.session.close(code: 0, reason: "done")
    }

    @Test("a viewer's token is refused, and the viewer keeps no session")
    func refusesViewer() async throws {
        let viewer = DirectTokens.mint(user: "bob", key: bob.key, publish: 0)
        let (fromAlice, fromBob) = try await establish(bobToken: viewer)
        #expect(fromAlice.failure == .peerUnverified(.viewer))
        #expect(fromBob.failure == .peerRejected, "\(String(describing: fromBob.failure))")
    }

    @Test("a token for another room is refused")
    func refusesAnotherRoom() async throws {
        let elsewhere = DirectTokens.mint(user: "bob", key: bob.key, room: "room-99")
        let (fromAlice, fromBob) = try await establish(bobToken: elsewhere)
        #expect(fromAlice.failure == .peerUnverified(.anotherRoom))
        #expect(fromBob.failure == .peerRejected)
    }

    @Test("a token naming somebody other than the offer's sender is refused")
    func refusesImpostor() async throws {
        let carol = DirectTokens.mint(user: "carol", key: bob.key)
        let (fromAlice, fromBob) = try await establish(bobToken: carol)
        #expect(fromAlice.failure == .peerUnverified(.wrongParticipant))
        #expect(fromBob.failure == .peerRejected)
    }

    @Test("a certificate other than the offered one never completes a handshake")
    func refusesWrongCertificate() async throws {
        let (fromAlice, fromBob) = try await establish(
            offerToAlice: { offer in
                var forged = offer
                forged.certificate = Data(SHA256.hash(data: Data("someone else".utf8)))
                return forged
            },
            patience: .seconds(2)
        )
        // Alice never accepts Bob's certificate. Bob's own check of Alice's
        // passes, so where he dials, his side of the handshake completes
        // before hers refuses it, and he reads that as being refused.
        #expect(fromAlice.failure == .unreachable)
        #expect(fromBob.failure == .unreachable || fromBob.failure == .peerRejected)
        #expect((try? fromAlice.get()) == nil && (try? fromBob.get()) == nil)
    }

    @Test("an offer for somebody else, or our own, is refused before any packet")
    func refusesOffers() async throws {
        let a = try await endpoint(alice)
        defer { a.close() }
        let credentials = try alice.credentials()
        let check = DirectPeerCheck(keys: DirectTokens.keys)
        await #expect(throws: DirectEndpointError.offer("addressed to another participant")) {
            try await a.establish(offer: a.offer(to: "carol/x"), credentials: credentials, verifier: check)
        }
        var own = a.offer(to: alice.name)
        own.from = bob.name
        await #expect(throws: DirectEndpointError.offer("this is our own offer")) {
            try await a.establish(offer: own, credentials: credentials, verifier: check)
        }
    }

    /// The whole arrangement: a relay subscription, a direct one beside it, the
    /// direct path taking over, and the relay carrying on when it goes.
    @Test("the direct path takes over from the relay and hands back when it is lost")
    func fallsBackToRelay() async throws {
        let (fromAlice, fromBob) = try await establish()
        let atAlice = try fromAlice.get()
        let atBob = try fromBob.get()
        let track = try track(alice)

        let relay = LoopbackRelay()
        let transport = LoopbackTransport(relay: relay)
        let endpoint = RelayEndpoint(host: "relay.test")
        let alicesRelay = try await transport.connect(to: endpoint, credentials: alice.credentials())
        let bobsRelay = try await transport.connect(to: endpoint, credentials: bob.credentials())

        let relayWriter = try await alicesRelay.publish(track, priority: 64)
        let directWriter = try await atAlice.session.publish(track, priority: 64)
        let dual = DualSubscription(
            relay: try await bobsRelay.subscribe(SubscribeRequest(track: track)),
            settings: DirectPathSettings(settle: .zero, stall: .milliseconds(200), held: 64)
        )
        await dual.attachDirect(try await atBob.session.subscribe(SubscribeRequest(track: track)))
        #expect(await eventually { await atAlice.session.hasSubscriber(for: track) })

        let delivered = Collector<DirectDelivery>()
        let reader = Task { for await delivery in dual.deliveries { await delivered.append(delivery) } }

        func send(_ group: UInt64, direct: Bool) async throws {
            let object = TrackObject(group: group, object: 0, payload: Data("g\(group)".utf8))
            if direct { try await directWriter.write(object) }
            if group > 0 { try await relayWriter.startGroup(group) }
            try await relayWriter.write(object)
        }

        try await send(0, direct: true)
        #expect(await eventually { await dual.path == .direct })

        // The direct session goes away, as when the peer walks out of Wi-Fi.
        await atAlice.session.close(code: 0, reason: "gone")
        #expect(await eventually { await dual.path == .relay })

        for group in 1 ... 3 { try await send(UInt64(group), direct: false) }
        #expect(await eventually { await delivered.items.count == 4 })
        let groups = await delivered.items.map(\.object.group)
        #expect(groups == [0, 1, 2, 3], "each object once, in order")
        #expect(await delivered.items.dropFirst().allSatisfy { $0.path == .relay })

        reader.cancel()
        await dual.cancel()
        await atBob.session.close(code: 0, reason: "done")
    }
}
