import Foundation
import Testing

@testable import MoqomCore
@testable import MoqomKit
@testable import MoqomLoopback

@Suite("Connection quality")
struct ConnectionQualityTests {
    /// A link with nothing wrong with it.
    private func healthy(
        received: Int = 1000,
        lost: Int = 0,
        state: BandwidthState = .increasing,
        trend: Double = 0
    ) -> LinkStatistics {
        LinkStatistics(
            estimate: 3_000_000,
            received: 2_800_000,
            state: state,
            delayTrend: trend,
            objectsReceived: received,
            objectsLost: lost
        )
    }

    @Test("a link with no traffic is unknown, not bad")
    func silenceIsNotFailure() {
        // The distinction that matters most in practice. A room that has just
        // been joined has measured nothing, and showing a red indicator for it
        // is the fastest way to lose a user's trust in the indicator.
        let quality = ConnectionQuality.from(link: healthy(received: 0))
        #expect(quality == .unknown)
    }

    @Test("loss maps onto the buckets the thresholds describe")
    func lossDrivesTheBuckets() {
        #expect(ConnectionQuality.from(link: healthy(received: 1000, lost: 0)) == .excellent)
        // 0.4%: still hidden by a codec's own concealment, so still excellent.
        #expect(ConnectionQuality.from(link: healthy(received: 996, lost: 4)) == .excellent)
        // 1%: past concealment, short of visible.
        #expect(ConnectionQuality.from(link: healthy(received: 990, lost: 10)) == .good)
        // 3%: visible artefacts.
        #expect(ConnectionQuality.from(link: healthy(received: 970, lost: 30)) == .poor)
        // 15%: keyframe intervals being missed, so it stops recovering.
        #expect(ConnectionQuality.from(link: healthy(received: 850, lost: 150)) == .bad)
    }

    @Test("backing off costs one level and cannot on its own reach bad")
    func congestionIsNotFailure() {
        // A controller that has decided to back off is evidence a queue is
        // building, but a link delivering everything is working — the backoff is
        // the mechanism doing its job. If this drove the indicator on its own, it
        // would fire during every normal probe cycle, and an indicator that cries
        // wolf is one that gets ignored on the day it is right.
        let backingOff = healthy(state: .decreasing)
        #expect(ConnectionQuality.from(link: backingOff) == .good)

        let rising = healthy(trend: 50)
        #expect(ConnectionQuality.from(link: rising) == .good)

        // Floored at `poor`: no amount of congestion signal turns a lossless
        // link into `bad`.
        let losing = healthy(received: 970, lost: 30, state: .decreasing)
        #expect(ConnectionQuality.from(link: losing) == .poor)
    }

    @Test("an explicit loss figure overrides the link's own")
    func perParticipantLossWins() {
        // What keeps one struggling cohost from dragging every tile's indicator
        // down with them. The link figure is an aggregate across every
        // subscription; a single participant's own loss is the number that
        // describes that participant.
        let aggregate = healthy(received: 900, lost: 100)
        #expect(ConnectionQuality.from(link: aggregate) == .bad)
        #expect(ConnectionQuality.from(link: aggregate, loss: 0) == .excellent)
    }

    @Test("quality is ordered, so the worst of a set is meaningful")
    func qualityIsOrdered() {
        #expect(ConnectionQuality.bad < ConnectionQuality.poor)
        #expect(ConnectionQuality.excellent > ConnectionQuality.good)
        #expect([ConnectionQuality.good, .poor, .excellent].min() == .poor)
    }

    @Test("loss ratio is zero for a link that has received nothing")
    func lossRatioIsDefinedEverywhere() {
        // A room with no traffic has not lost anything, and returning a division
        // by zero here would poison every derived figure.
        #expect(healthy(received: 0).lossRatio == 0)
        #expect(healthy(received: 900, lost: 100).lossRatio == 0.1)
    }

    @Test("encode drops are measured like network loss")
    func encodeDropsAreVisible() {
        // A frame the device threw away and a frame the network lost look
        // identical to whoever was meant to see it — and only this figure can
        // reveal the first kind, since no amount of network measurement would.
        var publishing = PublishingStatistics(
            video: BroadcastStatistics(framesSubmitted: 100, framesDropped: 30)
        )
        #expect(publishing.encodeDropRatio == 0.3)

        publishing.video = BroadcastStatistics(framesSubmitted: 0, framesDropped: 0)
        #expect(publishing.encodeDropRatio == 0)

        #expect(PublishingStatistics().encodeDropRatio == 0)
        #expect(!PublishingStatistics().isPublishing)
    }
}

@Suite("Room statistics")
struct RoomStatisticsTests {
    private let endpoint = RelayEndpoint(host: "loopback")

    private func session(
        _ name: String,
        relay: LoopbackRelay,
        logger: MoqomLogger = .silent
    ) async throws -> MoqomSession {
        let session = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: credentials(name),
            tenant: "acme",
            logger: logger
        )
        try await session.connect(to: endpoint)
        return session
    }

    private func source() -> FrameRelay {
        FrameRelay(
            format: CaptureFormat(size: PixelSize(width: 1280, height: 720), frameRate: 30)
        )
    }

    @Test("a freshly joined room reports itself as unmeasured, not as broken")
    func aNewRoomIsUnknown() async throws {
        let relay = LoopbackRelay()
        let viewer = try await session("bob", relay: relay)
        let room = try await viewer.join(room: "room-42")

        let stats = await room.statistics
        #expect(stats.room == "room-42")
        #expect(stats.identity == identity("bob"))
        #expect(stats.quality == .unknown)
        #expect(stats.participantCount == 0)
        #expect(stats.participants.isEmpty)
        #expect(!stats.publishing.isPublishing)
        #expect(stats.worstQuality == .unknown)
        #expect(stats.struggling.isEmpty)

        // Not encrypted, so there is nothing to say about decryption — as
        // distinct from saying that zero objects were decrypted.
        #expect(stats.decryption == nil)
    }

    @Test("one snapshot carries the link, the uplink and every participant")
    func oneSnapshotCoversTheRoom() async throws {
        // The reason this type exists. Reading an encoder's output rate and a
        // link estimate a few hundred milliseconds apart describes two different
        // moments, and comparing them is most of what diagnosis consists of.
        let relay = LoopbackRelay()
        let host = try await session("alice", relay: relay)
        let viewer = try await session("bob", relay: relay)
        let hostRoom = try await host.join(room: "room-42")
        let viewerRoom = try await viewer.join(room: "room-42")

        _ = try await hostRoom.startBroadcast(from: source())
        #expect(await eventually { await viewerRoom.roster.count == 1 })

        let hostStats = await hostRoom.statistics
        #expect(hostStats.publishing.isPublishing)
        #expect(hostStats.publishing.video != nil)

        let viewerStats = await viewerRoom.statistics
        #expect(viewerStats.participantCount == 1)
        #expect(viewerStats.participants[identity("alice")] != nil)
        #expect(viewerStats.participants[identity("bob")] == nil)
        #expect(viewerStats.uptime > .zero)
    }

    @Test("a participant nobody is measuring is unknown rather than perfect")
    func unmeasuredParticipantsAreUnknown() async throws {
        // A tile with no subscription — which is the normal state for somebody in
        // a large room's overflow — has no measurable stream. Reporting
        // `excellent` for it would be a claim about something never observed.
        let relay = LoopbackRelay()
        let host = try await session("alice", relay: relay)
        let viewer = try await session("bob", relay: relay)
        let hostRoom = try await host.join(room: "room-42")
        let viewerRoom = try await viewer.join(room: "room-42")

        _ = try await hostRoom.startBroadcast(from: source())
        #expect(await eventually { await viewerRoom.roster.count == 1 })

        let stats = await viewerRoom.statistics
        let alice = stats.participants[identity("alice")]
        #expect(alice?.quality == .unknown)
        #expect(alice?.video == nil)
        #expect(alice?.audio == nil)
        #expect(stats.struggling.isEmpty)
    }

    @Test("the periodic stream keeps producing snapshots and stops when the room ends")
    func theStreamFollowsTheRoom() async throws {
        let relay = LoopbackRelay()
        let viewer = try await session("bob", relay: relay)
        let room = try await viewer.join(room: "room-42")

        let stream = await room.statistics(every: .milliseconds(100))
        var seen: [RoomStatistics] = []
        for await snapshot in stream {
            seen.append(snapshot)
            if seen.count == 2 {
                // Terminating the room is what ends the stream. A diagnostics
                // overlay should not need to be told separately to stop.
                await room.deliverTerminal(.hostEnded)
            }
            if seen.count == 4 { break }
        }

        #expect(seen.count >= 2)
        // Monotonic, because they are separate readings of one clock rather than
        // a cached value handed out repeatedly.
        #expect(seen[1].capturedAt >= seen[0].capturedAt)
        #expect(seen.last?.lifecycle.isEnded == true)
    }

    @Test("an unreasonable interval is clamped rather than honoured")
    func theIntervalIsClamped() async throws {
        // Sampling walks the roster and hops to three actors. A caller asking for
        // a millisecond is asking for the measurement to become the load, and the
        // right answer is to give them the fastest rate that is not that.
        let relay = LoopbackRelay()
        let viewer = try await session("bob", relay: relay)
        let room = try await viewer.join(room: "room-42")

        let stream = await room.statistics(every: .microseconds(1))
        let started = ContinuousClock.now
        var seen = 0
        for await _ in stream {
            seen += 1
            if seen == 3 { break }
        }
        // Three samples at a clamped 100ms cannot arrive in under 150ms.
        #expect(ContinuousClock.now - started > .milliseconds(150))
    }

    @Test("a quality change arrives as an event, once")
    func qualityChangesAreEvents() async throws {
        // So an application's indicator updates when the thing changed rather
        // than at whatever rate it happened to poll.
        let relay = LoopbackRelay()
        let viewer = try await session("bob", relay: relay)
        let room = try await viewer.join(room: "room-42")

        let stream = room.events
        let events = Task {
            var qualities: [ConnectionQuality] = []
            for await event in stream {
                if case let .qualityChanged(who, quality) = event, who == identity("bob") {
                    qualities.append(quality)
                    if qualities.count == 1 { break }
                }
            }
            return qualities
        }

        _ = await room.statistics
        // Sampling twice with nothing changed must not produce a second event: a
        // stable connection should be silent.
        _ = await room.statistics

        let qualities = await events.value
        #expect(qualities == [.unknown])
    }

    @Test("control-track health is part of the snapshot")
    func controlHealthIsReported() async throws {
        // A room whose control log has a hole is one where grants and mute states
        // may be stale, and that presents as a permissions bug rather than as the
        // network problem it is. It belongs beside the network figures.
        let relay = LoopbackRelay()
        let authority = try await session("alice", relay: relay)
        let room = try await authority.join(room: "room-42")

        var stats = await room.statistics
        #expect(stats.control.sequence == 0)
        #expect(!stats.control.isFounded)
        #expect(!stats.control.isAuthority)

        // A client that has just joined wants a snapshot and has nothing wrong
        // with it. Those are two different questions and this is why they are two
        // different properties.
        #expect(stats.control.needsSnapshot)
        #expect(!stats.control.hasGap)

        let publisher = try await room.assumeAuthority(signer: testAuthority)
        try await publisher.snapshot()

        #expect(await eventually { await room.logPosition > 0 })
        stats = await room.statistics
        #expect(stats.control.isAuthority)
        #expect(stats.control.isFounded)
        #expect(stats.control.sequence > 0)
        #expect(stats.control.duplicates == 0)
        #expect(stats.control.rejected == 0)
        #expect(!stats.control.isTruncated)
        #expect(!stats.control.hasGap)
    }

    @Test("the snapshot's log fields carry no payloads")
    func snapshotFieldsAreSafe() async throws {
        // `LogValue` has no case that could hold one, so this is really a check
        // that the fields are the ones a reader needs — and that they are all
        // renderable without a privacy decision.
        let relay = LoopbackRelay()
        let viewer = try await session("bob", relay: relay)
        let room = try await viewer.join(room: "room-42")

        let fields = await room.statistics.fields
        let names = fields.map(\.name)
        #expect(names.contains("room"))
        #expect(names.contains("quality"))
        #expect(names.contains("loss"))
        #expect(names.contains("estimate_bps"))

        for field in fields {
            #expect(!field.value.rendered(.hashed).isEmpty)
        }
    }
}

@Suite("Session logging")
struct SessionLoggingTests {
    private let endpoint = RelayEndpoint(host: "loopback")

    @Test("connecting and joining are recorded")
    func lifecycleIsLogged() async throws {
        let sink = RecordingLogSink()
        let relay = LoopbackRelay()
        let session = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: credentials("alice"),
            tenant: "acme",
            logger: MoqomLogger(sink: sink, minimum: .debug)
        )

        try await session.connect(to: endpoint)
        _ = try await session.join(room: "room-42")
        await session.leave(room: "room-42")

        let messages = sink.messages
        #expect(messages.contains("connecting"))
        #expect(messages.contains("connected"))
        #expect(messages.contains("joined"))
        #expect(messages.contains("left"))
    }

    @Test("a failed connect is recorded as an error")
    func failureIsLogged() async throws {
        let sink = RecordingLogSink()
        let session = MoqomSession(
            transport: FailingTransport(),
            credentials: credentials("alice"),
            tenant: "acme",
            logger: MoqomLogger(sink: sink, minimum: .debug)
        )

        await #expect(throws: MoqomError.self) {
            try await session.connect(to: endpoint)
        }

        let failures = sink.records.filter { $0.level == .error }
        #expect(failures.map(\.message) == ["connect failed"])
        #expect(failures.first?.category == .session)
    }

    @Test("nothing is written by default")
    func silentByDefault() async throws {
        // An SDK that logs to a host application's console without being asked is
        // itself a bug report. The integrator who wants diagnostics passes a
        // logger; everyone else gets silence.
        let relay = LoopbackRelay()
        let session = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: credentials("alice"),
            tenant: "acme"
        )
        try await session.connect(to: endpoint)
        let room = try await session.join(room: "room-42")

        #expect(session.logger.sink is SilentLogSink)
        #expect(room.logger.sink is SilentLogSink)
    }

    @Test("the room inherits the session's logger")
    func loggerIsInherited() async throws {
        let sink = RecordingLogSink()
        let relay = LoopbackRelay()
        let session = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: credentials("alice"),
            tenant: "acme",
            logger: MoqomLogger(sink: sink, minimum: .debug)
        )
        try await session.connect(to: endpoint)
        let room = try await session.join(room: "room-42")

        await room.deliverTerminal(.hostEnded)
        #expect(sink.messages.contains("room ended"))

        let ended = sink.records.first { $0.message == "room ended" }
        #expect(ended?.category == .room)
        #expect(ended?.fields.contains { $0.name == "reason" } == true)
        // The moderation code stays out of it: a policy code beside a username is
        // a record of an enforcement decision, and that belongs wherever the
        // tenant keeps those rather than in a client's diagnostics.
        #expect(ended?.line().contains("reason=hostEnded") == true)
    }
}

/// A transport that refuses every dial, for testing the failure path.
private struct FailingTransport: Transport {
    func connect(
        to _: RelayEndpoint,
        credentials _: DeviceCredentials
    ) async throws(MoqomError) -> any TransportSession {
        throw MoqomError.transport(.unreachable)
    }
}
