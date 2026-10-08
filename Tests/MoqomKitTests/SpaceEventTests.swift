// Moments in a shared space, and the built-in edits that cause most of them.
//
// The sequencer is tested as a value, because every interleaving a network can
// produce is one line to state there and a flaky test to stage through a relay.
// The session tests then check that the pieces are wired together: an event
// raised on the authority reaches a follower once, a joiner does not replay the
// past, a refusing simulation refuses, the capture clock rides along for the
// playout to align to, and a handover does not wait out the silence.

import Foundation
import Testing

@testable import MoqomCore
@testable import MoqomKit
@testable import MoqomLoopback

private func record(_ sequence: UInt64, _ name: String = "e", epoch: UInt32 = 1) -> SpaceEventRecord {
    SpaceEventRecord(epoch: epoch, sequence: sequence, event: SpaceGameEvent(name), at: .fallback())
}

private func sequences(_ outputs: [SpaceEventSequencer.Output]) -> [UInt64] {
    outputs.compactMap { output in
        if case let .event(record) = output { return record.sequence }
        return nil
    }
}

@Suite("Ordering a space's events")
struct SpaceEventSequencerTests {
    @Test("events out of order and repeated come out once each, in order")
    func reordersAndDeduplicates() {
        var sequencer = SpaceEventSequencer(resuming: SpaceEventCursor(epoch: 1, delivered: 0))
        #expect(sequences(sequencer.receive(
            epoch: 1, events: [record(2)], through: 2, isSnapshot: false
        )).isEmpty)
        #expect(sequences(sequencer.receive(
            epoch: 1, events: [record(1), record(2)], through: 2, isSnapshot: false
        )) == [1, 2])
        #expect(sequences(sequencer.receive(
            epoch: 1, events: [record(1), record(2), record(3)], through: 3, isSnapshot: false
        )) == [3])
        #expect(sequencer.cursor == SpaceEventCursor(epoch: 1, delivered: 3))
    }

    @Test("a joiner starts at the snapshot's high-water mark rather than replaying history")
    func joinerSkipsHistory() {
        var sequencer = SpaceEventSequencer()
        let out = sequencer.receive(
            epoch: 3, events: [record(4, epoch: 3), record(5, epoch: 3)], through: 5, isSnapshot: true
        )
        #expect(out.isEmpty)
        #expect(sequences(sequencer.receive(
            epoch: 3, events: [record(6, epoch: 3)], through: 6, isSnapshot: false
        )) == [6])
    }

    @Test("a gap a snapshot cannot fill is reported, and what follows it is delivered")
    func unrecoverableGapIsReported() {
        var sequencer = SpaceEventSequencer(resuming: SpaceEventCursor(epoch: 1, delivered: 2))
        let out = sequencer.receive(
            epoch: 1, events: [record(9), record(10)], through: 10, isSnapshot: true
        )
        #expect(out.first == .missed(epoch: 1, sequences: 3 ... 8))
        #expect(sequences(out) == [9, 10])
    }

    @Test("a replaced authority's events are ignored, and a new one's start from its first")
    func epochsFence() {
        var sequencer = SpaceEventSequencer(resuming: SpaceEventCursor(epoch: 2, delivered: 7))
        #expect(sequencer.receive(
            epoch: 1, events: [record(8)], through: 8, isSnapshot: false
        ).isEmpty)
        #expect(sequences(sequencer.receive(
            epoch: 3, events: [record(1, epoch: 3)], through: 1, isSnapshot: false
        )) == [1])
    }

    @Test("an event announced far ahead does not make the reader hold the distance")
    func holdingIsBounded() {
        var sequencer = SpaceEventSequencer(resuming: SpaceEventCursor(epoch: 1, delivered: 0))
        let far = (2 ... UInt64(SpaceEventSequencer.holdLimit + 50)).map { record($0) }
        _ = sequencer.receive(epoch: 1, events: far, through: UInt64(far.count + 1), isSnapshot: false)
        let out = sequencer.receive(epoch: 1, events: [record(1)], through: 1, isSnapshot: false)
        #expect(sequences(out) == Array(1 ... UInt64(SpaceEventSequencer.holdLimit)))
    }

    @Test("a delta's repeats make good a lost one")
    func redundancyRepairs() {
        var log = SpaceEventLog(retention: 4, redundancy: 3)
        log.restart(epoch: 1)
        log.groupStarted()
        _ = log.append(SpaceGameEvent("a"), from: nil, at: .fallback(), media: nil)
        let first = log.forDelta(hasNew: true)
        _ = log.append(SpaceGameEvent("b"), from: nil, at: .fallback(), media: nil)
        let second = log.forDelta(hasNew: true)
        #expect(first.mustSend && second.mustSend)

        // The first delta is lost; the second repeats what it carried.
        var reader = SpaceEventSequencer(resuming: SpaceEventCursor(epoch: 1, delivered: 0))
        let out = reader.receive(epoch: 1, events: second.events, through: log.sequence, isSnapshot: false)
        #expect(sequences(out) == [1, 2])
    }

    @Test("a still board keeps repeating its last event for a few ticks, then stops")
    func echoesThenQuiet() {
        var log = SpaceEventLog(retention: 4, redundancy: 3)
        log.restart(epoch: 1)
        _ = log.append(SpaceGameEvent("goal"), from: nil, at: .fallback(), media: nil)
        var sent = 0
        for _ in 0 ..< 10 where log.forDelta(hasNew: false).mustSend { sent += 1 }
        #expect(sent == SpaceEventLog.echoTicks)
    }
}

/// A space that refuses any spawn of a `"bomb"`, and scores a goal whenever a
/// `"ball"` reaches the far side.
private struct Rules: SpaceSimulation {
    func step(_: inout SpaceSnapshot, at _: Timecode, since _: Duration) {}

    func permits(_ edit: SpaceEdit, from _: ParticipantIdentity, in _: SpaceSnapshot) -> Bool {
        if case let .spawn(entity) = edit, entity.kind == "bomb" { return false }
        return true
    }

    func events(
        between previous: SpaceSnapshot,
        and next: SpaceSnapshot,
        at _: Timecode
    ) -> [SpaceGameEvent] {
        let before = previous.entities["ball"]?.pose.position.x ?? 0
        let after = next.entities["ball"]?.pose.position.x ?? 0
        return before < 10 && after >= 10 ? [SpaceGameEvent("goal", subject: "ball")] : []
    }
}

/// Everything a session said, for a test to look through afterwards.
private final class Heard: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [SpaceSession.Event] = []
    private var samples: [SpaceSample] = []
    private var tasks: [Task<Void, Never>] = []

    init(_ session: SpaceSession) {
        tasks.append(Task { [weak self] in
            for await event in session.events { self?.add(event) }
        })
        tasks.append(Task { [weak self] in
            for await sample in session.states { self?.add(sample) }
        })
    }

    deinit { for task in tasks { task.cancel() } }

    private func add(_ event: SpaceSession.Event) { lock.withLock { events.append(event) } }
    private func add(_ sample: SpaceSample) { lock.withLock { samples.append(sample) } }

    var gameEvents: [SpaceEventRecord] {
        lock.withLock {
            events.compactMap { event in
                if case let .event(record) = event { return record }
                return nil
            }
        }
    }

    var latestSample: SpaceSample? { lock.withLock { samples.last } }
}

@Suite("Events and edits in a shared space")
struct SpaceEventSessionTests {
    private let endpoint = RelayEndpoint(host: "loopback", alpn: ["moqt-19"])
    private let ada = identity("ada", device: "phone-1")
    private let grace = identity("grace", device: "phone-2")
    private let linus = identity("linus", device: "phone-3")

    private func space(
        _ who: ParticipantIdentity,
        on relay: LoopbackRelay,
        simulation: any SpaceSimulation = Rules(),
        mayLead: Bool = true,
        quiet: Duration = .milliseconds(60),
        mediaClock: SpaceMediaClock? = nil
    ) async throws -> SpaceSession {
        let connection = try await LoopbackTransport(relay: relay).connect(
            to: endpoint,
            credentials: DeviceCredentials(identity: who, token: Data("token".utf8), deviceKey: nil)
        )
        return try SpaceSession(
            tenant: "acme",
            room: "room-42",
            identity: who,
            connection: connection,
            simulation: simulation,
            configuration: SpaceSession.Configuration(
                tickRate: 60,
                groupLength: 10,
                quiet: quiet,
                mayLead: mayLead
            ),
            mediaClock: mediaClock
        )
    }

    private func leaderAndFollower(
        on relay: LoopbackRelay,
        mediaClock: SpaceMediaClock? = nil
    ) async throws -> (SpaceSession, SpaceSession) {
        let leader = try await space(ada, on: relay, mediaClock: mediaClock)
        await leader.start()
        #expect(await eventually { await leader.role == .leading })
        let follower = try await space(grace, on: relay, mayLead: false)
        await follower.start()
        #expect(await eventually { await follower.authority == ada })
        return (leader, follower)
    }

    @Test("built-in edits from a follower are applied by the authority, unless its rules say no")
    func editsAndPermission() async throws {
        let relay = LoopbackRelay()
        let (leader, follower) = try await leaderAndFollower(on: relay)

        await follower.edit(.spawn(SpaceEntity(id: "ball", kind: "sphere")))
        #expect(await eventually { await follower.state.entities["ball"] != nil })

        let moved = SpacePose(position: SpaceVector(x: 3, y: 0, z: 0))
        await follower.edit(.move("ball", moved))
        #expect(await eventually { await follower.state.entities["ball"]?.pose == moved })

        await follower.edit(.spawn(SpaceEntity(id: "boom", kind: "bomb")))
        await follower.edit(.despawn("ball"))
        #expect(await eventually { await follower.state.entities["ball"] == nil })
        #expect(await leader.state.entities["boom"] == nil, "the rules refused the bomb")

        await leader.stop()
        await follower.stop()
    }

    @Test("an event reaches everybody once, in the authority's order")
    func eventsAreDeliveredOnce() async throws {
        let relay = LoopbackRelay()
        let (leader, follower) = try await leaderAndFollower(on: relay)
        let atLeader = Heard(leader)
        let atFollower = Heard(follower)

        await follower.edit(.event(SpaceGameEvent("cheer")))
        await follower.edit(.spawn(SpaceEntity(id: "ball", kind: "sphere")))
        await follower.edit(.move("ball", SpacePose(position: SpaceVector(x: 12, y: 0, z: 0))))

        #expect(await eventually { atFollower.gameEvents.count == 2 })
        // Long enough for every repeat of both events to have arrived.
        try await Task.sleep(for: .milliseconds(400))

        let names = atFollower.gameEvents.map(\.event.name)
        #expect(names == ["cheer", "goal"])
        #expect(atFollower.gameEvents.map(\.sequence) == [1, 2])
        #expect(atFollower.gameEvents.first?.from == grace)
        #expect(atFollower.gameEvents.last?.from == nil, "the simulation raised the goal itself")
        #expect(atLeader.gameEvents.map(\.event.name) == ["cheer", "goal"])

        await leader.stop()
        await follower.stop()
    }

    @Test("somebody joining mid-game sees the state, not a replay of what happened before")
    func latecomerSkipsHistory() async throws {
        let relay = LoopbackRelay()
        let (leader, follower) = try await leaderAndFollower(on: relay)
        let atFollower = Heard(follower)
        await follower.edit(.event(SpaceGameEvent("kickoff")))
        await follower.edit(.spawn(SpaceEntity(id: "ball", kind: "sphere")))
        #expect(await eventually { atFollower.gameEvents.count == 1 })
        // A joiner reads from the latest group's snapshot, so what happened
        // earlier in that group is not history yet. Ten ticks at 60 Hz is a
        // group; wait out a few.
        try await Task.sleep(for: .milliseconds(500))

        let latecomer = try await space(linus, on: relay, mayLead: false)
        let atLatecomer = Heard(latecomer)
        await latecomer.start()
        #expect(await eventually { await latecomer.state.entities["ball"] != nil })

        await follower.edit(.event(SpaceGameEvent("whistle")))
        #expect(await eventually { atLatecomer.gameEvents.count == 1 })
        try await Task.sleep(for: .milliseconds(200))
        #expect(atLatecomer.gameEvents.map(\.event.name) == ["whistle"])
        #expect(await latecomer.eventCursor?.delivered == 2)

        await leader.stop()
        await follower.stop()
        await latecomer.stop()
    }

    @Test("ticks carry the authority's capture clock, so a viewer can draw the board at the picture")
    func mediaClockRidesAlong() async throws {
        let relay = LoopbackRelay()
        let captured = FrameTimestamp(seconds: 1234.5)
        let (leader, follower) = try await leaderAndFollower(on: relay, mediaClock: { captured })
        let atFollower = Heard(follower)

        await follower.edit(.spawn(SpaceEntity(id: "ball", kind: "sphere")))
        #expect(await eventually { atFollower.latestSample?.state.entities["ball"] != nil })
        #expect(atFollower.latestSample?.media == captured)

        var playout = SpacePlayout()
        if let sample = atFollower.latestSample { playout.insert(sample) }
        let frame = playout.frame(alignedTo: captured)
        #expect(frame?.state.entities["ball"] != nil)

        await leader.stop()
        await follower.stop()
    }

    @Test("a handover names the successor, who takes over without waiting out the silence")
    func handoverIsImmediate() async throws {
        let relay = LoopbackRelay()
        // Long enough that the outgoing authority does not reclaim the space
        // in the moment before the successor's first snapshot reaches it.
        let leader = try await space(ada, on: relay, quiet: .milliseconds(900))
        await leader.start()
        #expect(await eventually { await leader.role == .leading })

        // A silence far longer than the test will wait, so only the handover
        // can explain the successor leading.
        let successor = try await space(grace, on: relay, quiet: .seconds(60))
        await successor.start()
        #expect(await eventually { await successor.authority == ada })

        try await leader.handOver(to: grace)
        #expect(await eventually(timeout: .seconds(3)) { await successor.role == .leading })
        #expect(await eventually { await leader.authority == grace })
        #expect(await leader.role == .following)

        await leader.stop()
        await successor.stop()
    }
}
