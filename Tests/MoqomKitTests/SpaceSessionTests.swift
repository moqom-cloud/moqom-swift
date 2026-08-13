// A shared space between two devices, over the loopback relay.
//
// The interesting cases here are all about the authority: nobody has one, two
// devices want one, and somebody who has one is asked for something by somebody
// who does not. Everything else — encoding, folding a delta in — is covered by
// the state and wire suites, which do not need a relay.

import Foundation
import Testing

@testable import MoqomCore
@testable import MoqomKit
@testable import MoqomLoopback

/// A world where an entity can be put in and taken out on request.
///
/// Deliberately not a game. The simulation under test is the *replication*, and
/// a fixture with rules of its own would put its own bugs in the way of that.
private final class Sandbox: SpaceSimulation, @unchecked Sendable {
    /// Entities the authority creates as soon as it has the space.
    let initial: [SpaceEntity]

    /// Every intent this simulation was asked to apply, in order.
    private(set) var asked: [(SpaceIntent, ParticipantIdentity)] = []

    /// Ticks since it took over, published as a fact so the wire carries
    /// something on an otherwise still board.
    private var ticks = 0

    init(initial: [SpaceEntity] = []) {
        self.initial = initial
    }

    func opening(_ state: inout SpaceSnapshot, at _: Timecode) {
        for entity in initial { state.entities[entity.id] = entity }
    }

    func step(_ state: inout SpaceSnapshot, at _: Timecode, since _: Duration) {
        ticks += 1
        state.facts["ticks"] = .number(Int64(ticks))
    }

    func apply(
        _ intent: SpaceIntent,
        from who: ParticipantIdentity,
        to state: inout SpaceSnapshot,
        at _: Timecode
    ) {
        asked.append((intent, who))
        guard let subject = intent.subject else { return }
        switch intent.verb {
        case "remove": state.entities.removeValue(forKey: subject)
        case "add": state.entities[subject] = SpaceEntity(id: subject, kind: "thing")
        default: break
        }
    }
}

@Suite("A shared space")
struct SpaceSessionTests {
    private let endpoint = RelayEndpoint(host: "loopback", alpn: ["moqt-19"])

    private func connect(
        _ who: ParticipantIdentity,
        to relay: LoopbackRelay
    ) async throws -> any TransportSession {
        try await LoopbackTransport(relay: relay).connect(
            to: endpoint,
            credentials: DeviceCredentials(
                identity: who,
                token: Data("token".utf8),
                proofSigner: { $0 }
            )
        )
    }

    private func space(
        _ who: ParticipantIdentity,
        on relay: LoopbackRelay,
        simulation: any SpaceSimulation,
        mayLead: Bool = true,
        quiet: Duration = .milliseconds(60)
    ) async throws -> SpaceSession {
        try SpaceSession(
            tenant: "acme",
            room: "room-42",
            identity: who,
            connection: try await connect(who, to: relay),
            simulation: simulation,
            configuration: SpaceSession.Configuration(
                tickRate: 60,
                groupLength: 10,
                quiet: quiet,
                mayLead: mayLead
            )
        )
    }

    private let ada = identity("ada", device: "phone-1")
    private let grace = identity("grace", device: "phone-2")

    @Test("a device alone in a room takes the space rather than waiting for one")
    func claimsAnEmptySpace() async throws {
        let relay = LoopbackRelay()
        let session = try await space(ada, on: relay, simulation: Sandbox())
        await session.start()

        #expect(await eventually { await session.role == .leading })
        #expect(await session.authority == ada)
        await session.stop()
    }

    @Test("what the authority simulates arrives at everybody watching")
    func stateReachesAFollower() async throws {
        let relay = LoopbackRelay()
        let ball = SpaceEntity(id: "ball", kind: "sphere")
        let leader = try await space(ada, on: relay, simulation: Sandbox(initial: [ball]))
        await leader.start()
        #expect(await eventually { await leader.role == .leading })

        // Never leads, so this is unambiguously the replicated copy rather than
        // a second simulation arriving at the same answer.
        let follower = try await space(grace, on: relay, simulation: Sandbox(), mayLead: false)
        await follower.start()

        #expect(await eventually { await follower.state.entities["ball"] != nil })
        #expect(await follower.authority == ada)
        await leader.stop()
        await follower.stop()
    }

    @Test("a follower's intent reaches the simulation and comes back as state")
    func intentsTravelUpstream() async throws {
        let relay = LoopbackRelay()
        let brick = SpaceEntity(id: "brick", kind: "cube")
        let rules = Sandbox(initial: [brick])
        let leader = try await space(ada, on: relay, simulation: rules)
        await leader.start()
        #expect(await eventually { await leader.role == .leading })

        let follower = try await space(grace, on: relay, simulation: Sandbox(), mayLead: false)
        await follower.start()
        #expect(await eventually { await follower.state.entities["brick"] != nil })

        await follower.act(verb: "remove", subject: "brick")

        // Gone on the authority, which is the decision, and gone on the
        // follower, which is the decision having been replicated back.
        #expect(await eventually { await leader.state.entities["brick"] == nil })
        #expect(await eventually { await follower.state.entities["brick"] == nil })
        #expect(rules.asked.map(\.1) == [grace])
        await leader.stop()
        await follower.stop()
    }

    /// The case a quiet interval and two phones makes likely rather than rare.
    @Test("two devices claiming at once end up with one of them leading")
    func twoClaimantsSettle() async throws {
        let relay = LoopbackRelay()
        let first = try await space(ada, on: relay, simulation: Sandbox())
        let second = try await space(grace, on: relay, simulation: Sandbox())

        await first.start()
        await second.start()

        let settled = await eventually(timeout: .seconds(4)) {
            let roles = [await first.role, await second.role]
            guard roles.filter({ $0 == .leading }).count == 1 else { return false }
            // And they agree about which one it is, which is the half a bare
            // role check would miss: one of them standing down while the other
            // never hears about it is two devices with one authority and no
            // shared state.
            let mine = await first.authority
            let theirs = await second.authority
            return mine != nil && mine == theirs
        }
        #expect(settled)

        await first.stop()
        await second.stop()
    }

    @Test("a device that takes over carries on from what the last one left")
    func takeoverKeepsTheWorld() async throws {
        let relay = LoopbackRelay()
        let ball = SpaceEntity(id: "ball", kind: "sphere")
        let leader = try await space(ada, on: relay, simulation: Sandbox(initial: [ball]))
        await leader.start()
        #expect(await eventually { await leader.role == .leading })

        let successor = try await space(grace, on: relay, simulation: Sandbox())
        await successor.start()
        #expect(await eventually { await successor.state.entities["ball"] != nil })

        // The incumbent goes away without saying so, which is the case that
        // matters: a phone in a tunnel cannot announce that it is in a tunnel.
        await leader.stop()

        #expect(await eventually(timeout: .seconds(4)) { await successor.role == .leading })
        #expect(await successor.state.entities["ball"] != nil)
        #expect(await successor.authority == grace)
        await successor.stop()
    }

    /// The fence, tested where it is decided rather than through two relays and
    /// a partition: a tick from an epoch below the highest seen is inert.
    @Test("an update from a replaced authority changes nothing")
    func staleAuthorityIsIgnored() async throws {
        let relay = LoopbackRelay()
        let session = try await space(ada, on: relay, simulation: Sandbox(), mayLead: false)

        let arrived = SpaceUpdate(
            tick: SpaceTick(epoch: 4, step: 1),
            at: .fallback(),
            body: .snapshot(SpaceSnapshot(
                entities: ["ball": SpaceEntity(id: "ball", kind: "sphere")],
                authority: grace
            ))
        )
        var encoder = SpaceEncoder()
        await session.receive(TrackObject(
            group: 1, object: 0, payload: try encoder.encode(arrived), isKeyFrame: true
        ))
        #expect(await session.state.entities["ball"] != nil)

        // The replaced authority, still publishing from a lower epoch.
        var stale = SpaceEncoder()
        let old = SpaceUpdate(
            tick: SpaceTick(epoch: 3, step: 900),
            at: .fallback(),
            body: .snapshot(SpaceSnapshot(entities: [:], authority: ada))
        )
        await session.receive(TrackObject(
            group: 2, object: 0, payload: try stale.encode(old), isKeyFrame: true
        ))

        #expect(await session.state.entities["ball"] != nil)
        #expect(await session.authority == grace)
    }

    @Test("undecodable objects still count as the space being live")
    func noiseDoesNotLookLikeSilence() async throws {
        // A joiner who arrives mid-group gets deltas it cannot decode until the
        // next snapshot. Those are not silence: treating them as such is how a
        // second phone claims a game that is already running.
        let relay = LoopbackRelay()
        let session = try await space(
            ada, on: relay, simulation: Sandbox(), quiet: .milliseconds(80)
        )
        await session.start()

        let garbage = TrackObject(
            group: 1, object: 0, payload: Data([0x00, 0xFF, 0x00]), isKeyFrame: false
        )
        for _ in 0 ..< 8 {
            await session.receive(garbage)
            try? await Task.sleep(for: .milliseconds(30))
        }

        #expect(await session.role == .following)
        await session.stop()
    }
}

@Suite("A space intent on the wire")
struct SpaceIntentTests {
    @Test("everything an intent carries survives the round trip")
    func roundTrips() throws {
        let intent = SpaceIntent(
            verb: "pop",
            subject: "bubble-7",
            at: SpaceVector(x: 0.25, y: -1.5, z: 3),
            facts: ["force": .decimal(0.8), "hand": .text("left"), "first": .flag(true)],
            sequence: 42,
            when: Timecode(nanoseconds: 1_700_000_000, uncertainty: .milliseconds(3), trust: .fallback)
        )

        let decoded = try SpaceIntent(decoding: intent.encoded())

        #expect(decoded.verb == "pop")
        #expect(decoded.subject == "bubble-7")
        #expect(decoded.at == SpaceVector(x: 0.25, y: -1.5, z: 3))
        #expect(decoded.facts == intent.facts)
        #expect(decoded.sequence == 42)
        #expect(decoded.when.nanoseconds == 1_700_000_000)
    }

    @Test("an intent with nothing but a verb is legal, and one without is not")
    func minimumAndBelowIt() throws {
        let bare = try SpaceIntent(decoding: SpaceIntent(verb: "start").encoded())
        #expect(bare.verb == "start")
        #expect(bare.subject == nil)
        #expect(bare.at == nil)

        #expect(throws: WireError.self) {
            try SpaceIntent(decoding: Data([0x08, 0x01]))
        }
    }

    @Test("the same intent encodes to the same bytes twice")
    func encodingIsStable() {
        let intent = SpaceIntent(
            verb: "pop",
            subject: "b",
            facts: ["a": .number(1), "z": .number(26), "m": .text("middle")]
        )
        #expect(intent.encoded() == intent.encoded())
    }
}
