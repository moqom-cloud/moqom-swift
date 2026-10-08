// Direct paths: who may use one, the offers that set one up, and the merge that
// lets one fail without the viewer noticing.
//
// The selector is tested as a value with time passed in, because every race
// between two paths is one line to state there. The offer tests pin the bytes to
// the vector `moqom_client::direct` checks, so an offer sealed by either SDK
// opens in the other. The rest check the wiring: offers through a relay that
// cannot read them, and the merge as an actor over two subscriptions.

import CryptoKit
import Foundation
import Testing

@testable import MoqomCore
@testable import MoqomKit
@testable import MoqomLoopback

private func object(_ group: UInt64, _ index: UInt64 = 0) -> TrackObject {
    TrackObject(group: group, object: index, payload: Data("g\(group)-\(index)".utf8))
}

private func keys(_ deliveries: [DirectDelivery]) -> [String] {
    deliveries.map { "\($0.object.group).\($0.object.object)@\($0.path == .direct ? "d" : "r")" }
}

private func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

@Suite("Choosing between the relay and a direct path")
struct DirectPathSelectorTests {
    private let start = ContinuousClock.now

    private func selector(settle: Duration = .zero, stall: Duration = .milliseconds(100)) -> DirectPathSelector {
        var selector = DirectPathSelector(settings: DirectPathSettings(settle: settle, stall: stall, held: 8))
        selector.attachDirect()
        return selector
    }

    @Test("without a direct path the relay is simply passed through")
    func relayOnly() {
        var selector = DirectPathSelector(settings: DirectPathSettings())
        #expect(keys(selector.relay(object(0), at: start)) == ["0.0@r"])
        #expect(keys(selector.direct(object(1), at: start)).isEmpty)
        #expect(selector.path == .relay)
    }

    @Test("the direct path takes over once it has kept up, and the relay copy is dropped")
    func settles() {
        var selector = selector(settle: .milliseconds(50))
        #expect(keys(selector.direct(object(0), at: start)) == ["0.0@d"])
        #expect(selector.path == .relay, "still on probation")
        #expect(keys(selector.relay(object(0), at: start + .milliseconds(10))).isEmpty)
        #expect(keys(selector.direct(object(1), at: start + .milliseconds(60))) == ["1.0@d"])
        #expect(selector.path == .direct)
        #expect(selector.switches == 1)
        #expect(keys(selector.relay(object(1), at: start + .milliseconds(70))).isEmpty)
    }

    @Test("an object only the relay delivers is released after the stall bound, and the direct path is dropped")
    func fallsBack() {
        var selector = selector()
        _ = selector.direct(object(0), at: start)
        #expect(selector.path == .direct)
        #expect(keys(selector.relay(object(1), at: start + .milliseconds(5))).isEmpty, "held")
        #expect(keys(selector.expire(at: start + .milliseconds(50))).isEmpty, "not yet")
        #expect(selector.deadline == start + .milliseconds(105))
        #expect(keys(selector.expire(at: start + .milliseconds(105))) == ["1.0@r"])
        #expect(selector.path == .relay)
        #expect(!selector.hasDirect)
        #expect(selector.switches == 2)
        #expect(keys(selector.direct(object(2), at: start + .milliseconds(110))).isEmpty, "a dropped path is ignored")
    }

    @Test("a gap the direct path skipped is filled from the relay, in order, ahead of what it skipped to")
    func fillsGaps() {
        var selector = selector()
        _ = selector.direct(object(0), at: start)
        _ = selector.relay(object(1), at: start)
        _ = selector.relay(object(2), at: start)
        #expect(keys(selector.direct(object(3), at: start + .milliseconds(1))) == ["1.0@r", "2.0@r", "3.0@d"])
        #expect(selector.path == .direct)
    }

    @Test("a direct path that drops an object on probation starts its probation again")
    func probationRestarts() {
        var selector = selector(settle: .milliseconds(50))
        _ = selector.direct(object(0), at: start)
        #expect(keys(selector.relay(object(1), at: start + .milliseconds(10))) == ["1.0@r"])
        _ = selector.expire(at: start + .milliseconds(110))
        #expect(selector.hasDirect, "probation restarts rather than ending")
        #expect(keys(selector.direct(object(2), at: start + .milliseconds(120))) == ["2.0@d"])
        #expect(selector.path == .relay, "the clock started again at the last direct object")
    }

    @Test("a network change returns to the relay with what it was holding")
    func networkChange() {
        var selector = selector()
        _ = selector.direct(object(0), at: start)
        _ = selector.relay(object(2), at: start)
        _ = selector.relay(object(1), at: start)
        #expect(keys(selector.fallBack()) == ["1.0@r", "2.0@r"])
        #expect(selector.path == .relay)
    }
}

@Suite("Who may use a direct path")
struct DirectEligibilityTests {
    private let small = DirectEligibility(endToEndEncrypted: true, participants: 2, everyoneOptedIn: true)

    @Test("a small encrypted room where everybody agreed is allowed")
    func allowed() throws {
        try small.check()
        var four = small
        four.participants = DirectEligibility.maximumParticipants
        try four.check()
    }

    @Test("each reason to refuse is reported, viewers first")
    func refused() {
        func reason(_ change: (inout DirectEligibility) -> Void) -> DirectIneligibility? {
            var room = small
            change(&room)
            do throws(DirectIneligibility) {
                try room.check()
                return nil
            } catch {
                return error
            }
        }
        #expect(reason { $0.audience = true; $0.endToEndEncrypted = false } == .audience)
        #expect(reason { $0.endToEndEncrypted = false } == .notEncrypted)
        #expect(reason { $0.watchdogRequired = true } == .watchdogRequired)
        #expect(reason { $0.participants = 1 } == .alone)
        #expect(reason { $0.participants = 5 } == .tooManyParticipants(5))
        #expect(reason { $0.limit = 2; $0.participants = 3 } == .tooManyParticipants(3))
        #expect(reason { $0.limit = 2; $0.participants = 2 } == nil)
        #expect(reason { $0.limit = 40; $0.participants = 5 } == .tooManyParticipants(5))
        #expect(reason { $0.everyoneOptedIn = false } == .notEveryoneOptedIn)
        #expect(DirectIneligibility.audience.description == "viewers never use direct paths")
    }
}

@Suite("Candidate offers")
struct CandidateOfferTests {
    /// What `moqom_client::direct::CandidateOffer` seals for the same offer,
    /// secret, room, and nonce.
    private static let vector = "4d514431030303030303030303030303c830f752e602077e6902cf60202483a4477a576bb7baac25fe0cbc9ddd1f24a64841c7fdeb7dbb33374c7920c42d5e2a46ce6520940c91af81fc6d85bb163c934fcccfb8aad2913266668ceb2d5877401d8ea0c6ce5808c27997bc0452de5fb6"

    private let secret = try! DirectRoomSecret(secret: Data(repeating: 1, count: 32), room: "acme/room-42")

    private let offer = CandidateOffer(
        from: "ada/dev-a",
        to: "bob/dev-b",
        certificate: Data(repeating: 9, count: 32),
        candidates: [
            DirectCandidate(host: "192.0.2.1", port: 4433)!,
            DirectCandidate(host: "2001:db8::1", port: 4433)!,
        ]
    )

    @Test("the sealed bytes are the Rust SDK's, and open back to the offer")
    func sharedVector() throws {
        let nonce = try AES.GCM.Nonce(data: Data(repeating: 3, count: 12))
        let sealed = try offer.sealed(with: secret, nonce: nonce)
        #expect(hex(sealed) == Self.vector)
        #expect(try CandidateOffer(opening: sealed, with: secret, for: "bob/dev-b") == offer)
    }

    @Test("an offer opens only for its addressee, its room, and unaltered")
    func refusals() throws {
        let sealed = try offer.sealed(with: secret)
        #expect(throws: DirectOfferError.addressedToSomebodyElse) {
            try CandidateOffer(opening: sealed, with: secret, for: "eve/dev-e")
        }
        let elsewhere = try DirectRoomSecret(secret: Data(repeating: 1, count: 32), room: "acme/room-43")
        #expect(throws: DirectOfferError.doesNotOpen) {
            try CandidateOffer(opening: sealed, with: elsewhere, for: "bob/dev-b")
        }
        var tampered = sealed
        tampered[tampered.count - 20] ^= 1
        #expect(throws: DirectOfferError.doesNotOpen) {
            try CandidateOffer(opening: tampered, with: secret, for: "bob/dev-b")
        }
        #expect(throws: DirectOfferError.notAnOffer) {
            try CandidateOffer(opening: Data("nope".utf8), with: secret, for: "bob/dev-b")
        }
        #expect(throws: DirectOfferError.shortSecret) {
            try DirectRoomSecret(secret: Data(repeating: 1, count: 8), room: "room")
        }
    }

    @Test("candidates read and print both address families")
    func candidates() {
        #expect(DirectCandidate(host: "192.0.2.1", port: 1)?.description == "192.0.2.1:1")
        #expect(DirectCandidate(host: "2001:db8::1", port: 2)?.description == "[2001:db8::1]:2")
        #expect(DirectCandidate(host: "example.com", port: 3) == nil)
        #expect(DirectCandidate(address: [1, 2, 3], port: 4) == nil)
    }
}

@Suite("Exchanging offers through the room")
struct DirectOffersTests {
    private let endpoint = RelayEndpoint(host: "loopback", alpn: ["moqt-19"])
    private let ada = identity("ada", device: "phone-1")
    private let bob = identity("bob", device: "phone-2")
    private let eve = identity("eve", device: "phone-3")

    private func offers(_ who: ParticipantIdentity, on relay: LoopbackRelay, room: String = "room-42") async throws -> DirectOffers {
        let connection = try await LoopbackTransport(relay: relay).connect(
            to: endpoint,
            credentials: DeviceCredentials(identity: who, token: Data("token".utf8), deviceKey: nil)
        )
        return DirectOffers(
            tenant: "acme",
            room: "room-42",
            identity: who,
            connection: connection,
            secret: try DirectRoomSecret(secret: Data(repeating: 5, count: 32), room: "acme/\(room)")
        )
    }

    private func offer(from: DirectOffers, to: DirectOffers, port: UInt16) -> CandidateOffer {
        CandidateOffer(
            from: from.me,
            to: to.me,
            certificate: Data(repeating: 7, count: 32),
            candidates: [DirectCandidate(host: "192.0.2.7", port: port)!]
        )
    }

    @Test("a peer reads what is addressed to it and nothing else, and the relay carries only ciphertext")
    func exchange() async throws {
        let relay = LoopbackRelay()
        let atAda = try await offers(ada, on: relay)
        let atBob = try await offers(bob, on: relay)
        let atEve = try await offers(eve, on: relay)

        try await atAda.send(offer(from: atAda, to: atEve, port: 1))
        try await atAda.send(offer(from: atAda, to: atBob, port: 2))

        var received = try await atBob.offers(from: ada).makeAsyncIterator()
        let first = await received.next()
        #expect(first?.candidates.first?.port == 2)
        #expect(first?.from == "ada/phone-1")

        try await atAda.send(offer(from: atAda, to: atBob, port: 3))
        let second = await received.next()
        #expect(second?.candidates.first?.port == 3)

        let carried = await relay.objects(onTrackNamed: DirectOffers.trackName)
        #expect(!carried.isEmpty)
        for object in carried {
            #expect(object.payload.prefix(4) == Data("MQD1".utf8))
            #expect(!object.payload.contains(Data("bob/phone-2".utf8)))
        }
        await atAda.close()
    }

    @Test("an offer sealed under another room's secret is skipped")
    func otherRoom() async throws {
        let relay = LoopbackRelay()
        let atAda = try await offers(ada, on: relay, room: "room-99")
        let atBob = try await offers(bob, on: relay)
        try await atAda.send(offer(from: atAda, to: atBob, port: 1))

        let stream = try await atBob.offers(from: ada)
        let reader = Task { await stream.first { _ in true } }
        try await Task.sleep(for: .milliseconds(200))
        reader.cancel()
        #expect(await reader.value == nil)
    }
}

/// A subscription the test feeds by hand.
private final class Fed: SubscriptionHandle, @unchecked Sendable {
    let track: FullTrackName
    let objects: AsyncStream<TrackObject>
    let feed: AsyncStream<TrackObject>.Continuation
    private let lock = NSLock()
    private var cancelled = false

    init() {
        track = try! FullTrackName(
            namespace: MoqomNamespaces.participant(tenant: "acme", room: "room-42", identity: identity("ada")),
            name: TrackName("camera")
        )
        (objects, feed) = AsyncStream.makeStream(of: TrackObject.self)
    }

    private var forwardingRequests: [Bool] = []

    var wasCancelled: Bool { lock.withLock { cancelled } }

    /// Every FORWARD value asked for, in order.
    var forwarding: [Bool] { lock.withLock { forwardingRequests } }

    func updatePriority(_: UInt8) async {}

    func updateForwarding(_ forward: Bool) async {
        lock.withLock { forwardingRequests.append(forward) }
    }

    func cancel() async {
        lock.withLock { cancelled = true }
        feed.finish()
    }
}

@Suite("Reading one track over both paths")
struct DualSubscriptionTests {
    @Test("objects arrive once each, the direct path takes over, and the relay covers its loss")
    func handsOverAndBack() async throws {
        let relay = Fed()
        let direct = Fed()
        let dual = DualSubscription(
            relay: relay,
            settings: DirectPathSettings(settle: .zero, stall: .milliseconds(100), held: 64)
        )
        var deliveries = dual.deliveries.makeAsyncIterator()
        await dual.attachDirect(direct)

        direct.feed.yield(object(0))
        let first = await deliveries.next()
        #expect(first?.path == .direct)
        #expect(await eventually { await dual.path == .direct })
        relay.feed.yield(object(0))

        relay.feed.yield(object(1))
        let recovered = await deliveries.next()
        #expect(recovered?.object.group == 1, "the relay's group 0 is not repeated")
        #expect(recovered?.path == .relay)
        #expect(await dual.path == .relay)
        #expect(await dual.switches == 2)
        #expect(await eventually { direct.wasCancelled }, "an abandoned path is closed")

        relay.feed.yield(object(2))
        let alone = await deliveries.next()
        #expect(alone?.object.group == 2)
        await dual.cancel()
        #expect(relay.wasCancelled)
        let end = await deliveries.next()
        #expect(end == nil)
    }

    @Test("a direct subscription ending falls back at once")
    func directEnds() async throws {
        let relay = Fed()
        let direct = Fed()
        let dual = DualSubscription(relay: relay, settings: DirectPathSettings(settle: .zero, stall: .seconds(30)))
        var deliveries = dual.deliveries.makeAsyncIterator()
        await dual.attachDirect(direct)
        direct.feed.yield(object(0))
        _ = await deliveries.next()
        relay.feed.yield(object(1))
        try await Task.sleep(for: .milliseconds(20))
        direct.feed.finish()
        let recovered = await deliveries.next()
        #expect(recovered?.object.group == 1)
        #expect(await dual.hasDirect == false)
    }

    @Test("the relay is asked to stop forwarding once the direct path takes over, and to resume on fallback")
    func pausesRelay() async throws {
        let relay = Fed()
        let direct = Fed()
        let dual = DualSubscription(relay: relay, settings: DirectPathSettings(settle: .zero, quiet: .seconds(30)))
        var deliveries = dual.deliveries.makeAsyncIterator()
        await dual.attachDirect(direct)
        direct.feed.yield(object(0))
        _ = await deliveries.next()
        #expect(await eventually { relay.forwarding == [false] })
        #expect(await dual.isRelayPaused)

        direct.feed.yield(object(1))
        _ = await deliveries.next()
        #expect(relay.forwarding == [false], "asked once, not per object")

        direct.feed.finish()
        #expect(await eventually { relay.forwarding == [false, true] })
        #expect(await dual.isRelayPaused == false)
        await dual.cancel()
        #expect(relay.forwarding == [false, true], "not resumed again on the way out")
    }

    @Test("a quiet direct path resumes the relay, and delivering again pauses it")
    func quietResumes() async throws {
        let relay = Fed()
        let direct = Fed()
        let dual = DualSubscription(
            relay: relay,
            settings: DirectPathSettings(settle: .zero, stall: .seconds(30), quiet: .milliseconds(50))
        )
        var deliveries = dual.deliveries.makeAsyncIterator()
        await dual.attachDirect(direct)
        direct.feed.yield(object(0))
        _ = await deliveries.next()
        #expect(await eventually { relay.forwarding == [false, true] })
        #expect(await dual.path == .direct, "quiet is not a fallback; the relay copy is what judges one")

        direct.feed.yield(object(1))
        _ = await deliveries.next()
        #expect(await eventually { relay.forwarding.prefix(3) == [false, true, false] })
        await dual.cancel()
    }

    @Test("with pausing off the relay is never asked to stop")
    func pausingOff() async throws {
        let relay = Fed()
        let direct = Fed()
        let dual = DualSubscription(relay: relay, settings: DirectPathSettings(settle: .zero, pausesRelay: false))
        var deliveries = dual.deliveries.makeAsyncIterator()
        await dual.attachDirect(direct)
        direct.feed.yield(object(0))
        _ = await deliveries.next()
        #expect(await dual.path == .direct)
        try await Task.sleep(for: .milliseconds(20))
        #expect(relay.forwarding.isEmpty)
        await dual.cancel()
    }

    @Test("the relay ending ends the subscription, direct path or not")
    func relayEnds() async throws {
        let relay = Fed()
        let dual = DualSubscription(relay: relay)
        var deliveries = dual.deliveries.makeAsyncIterator()
        await dual.attachDirect(Fed())
        relay.feed.finish()
        let end = await deliveries.next()
        #expect(end == nil)
    }
}
