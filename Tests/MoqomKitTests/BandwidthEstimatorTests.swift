// Bandwidth estimation from arriving media.
//
// These tests drive the estimator with synthetic arrival patterns, which is the
// only way to test a congestion controller deterministically: a real link is
// not reproducible and a controller that is only ever exercised against real
// links has no regression tests at all.
//
// The patterns are the classic three. A clean path where frames arrive at the
// pace they were sent. A congested path where each frame arrives a little later
// than the last, which is what a filling queue looks like from the receiving
// end. And a path that recovers, where the queue drains and the controller has
// to climb back rather than staying at the floor.

import Foundation
import Testing

@testable import MoqomCore
@testable import MoqomKit
@testable import MoqomLoopback

@Suite("Bandwidth estimation")
struct BandwidthEstimatorTests {
    /// One video frame's worth of object.
    private func frame(
        _ index: Int,
        bytes: Int = 5000,
        sentAtMilliseconds: Int
    ) -> TrackObject {
        TrackObject(
            group: 0,
            object: UInt64(index),
            payload: Data(count: bytes),
            properties: ObjectProperties(
                captureTime: FrameTimestamp(nanoseconds: UInt64(sentAtMilliseconds) * 1_000_000)
            )
        )
    }

    @Test("a clean path does not trigger a backoff")
    func steadyArrivalStaysHealthy() {
        // Frames sent 33ms apart, arriving 33ms apart. There is no queue, so
        // there is nothing to react to.
        var estimator = BandwidthEstimator(initialBitrate: 1_000_000)
        for index in 0 ..< 60 {
            estimator.record(
                frame(index, sentAtMilliseconds: index * 33),
                at: .milliseconds(index * 33)
            )
        }
        #expect(estimator.state != .decreasing)
        #expect(estimator.estimate >= 1_000_000)
        #expect(abs(estimator.delayTrend) < 1)
    }

    @Test("a clean path is measured, not guessed")
    func throughputIsMeasured() {
        // 5000 bytes every 33ms is about 1.2Mbps. The estimator should say so
        // regardless of what it was initialised with.
        var estimator = BandwidthEstimator(initialBitrate: 300_000)
        for index in 0 ..< 60 {
            estimator.record(
                frame(index, sentAtMilliseconds: index * 33),
                at: .milliseconds(index * 33)
            )
        }
        #expect(estimator.receivedBitrate > 1_000_000)
        #expect(estimator.receivedBitrate < 1_400_000)
    }

    @Test("a queue building is detected before anything is lost")
    func risingDelayTriggersABackoff() {
        // This is the property that makes delay-gradient control worth the
        // complexity: not one packet is lost here, and the controller still
        // knows the path is over capacity.
        var estimator = BandwidthEstimator(initialBitrate: 2_000_000)
        var arrival = 0

        for index in 0 ..< 120 {
            // Each frame arrives 4ms later than the one before, relative to
            // when it was sent. That is a queue filling.
            arrival += 33 + 4
            estimator.record(
                frame(index, sentAtMilliseconds: index * 33),
                at: .milliseconds(arrival)
            )
        }

        #expect(estimator.delayTrend > 0)
        #expect(estimator.estimate < 2_000_000)
        #expect(estimator.objectsLost == 0)
    }

    @Test("the estimate recovers once the queue drains")
    func recoveryClimbsBack() {
        var estimator = BandwidthEstimator(initialBitrate: 2_000_000)
        var arrival = 0
        for index in 0 ..< 120 {
            arrival += 33 + 4
            estimator.record(
                frame(index, sentAtMilliseconds: index * 33),
                at: .milliseconds(arrival)
            )
        }
        let bottom = estimator.estimate

        for index in 120 ..< 400 {
            arrival += 33
            estimator.record(
                frame(index, sentAtMilliseconds: index * 33),
                at: .milliseconds(arrival)
            )
        }

        #expect(estimator.estimate > bottom)
        #expect(estimator.state != .decreasing)
    }

    @Test("a single late frame is not congestion")
    func oneLateFrameIsIgnored() {
        // Frames are late all the time. A controller that halved its estimate
        // on every one of them would spend a call oscillating.
        var estimator = BandwidthEstimator(initialBitrate: 1_000_000)
        for index in 0 ..< 40 {
            let jolt = index == 20 ? 60 : 0
            estimator.record(
                frame(index, sentAtMilliseconds: index * 33),
                at: .milliseconds(index * 33 + jolt)
            )
        }
        #expect(estimator.estimate >= 1_000_000)
    }

    @Test("gaps in object IDs are counted as loss")
    func lossIsCounted() {
        // The backstop for paths that drop without queueing first — a lossy
        // radio link rather than a congested router.
        var estimator = BandwidthEstimator()
        for index in [0, 1, 2, 5, 6] {
            estimator.record(
                frame(index, sentAtMilliseconds: index * 33),
                at: .milliseconds(index * 33)
            )
        }
        #expect(estimator.objectsLost == 2)
        #expect(estimator.objectsReceived == 5)
    }

    @Test("the estimate stays inside its bounds")
    func boundsAreRespected() {
        var estimator = BandwidthEstimator(
            initialBitrate: 500_000,
            minimumBitrate: 100_000,
            maximumBitrate: 1_000_000
        )

        var arrival = 0
        for index in 0 ..< 600 {
            arrival += 33 + 20
            estimator.record(
                frame(index, bytes: 50, sentAtMilliseconds: index * 33),
                at: .milliseconds(arrival)
            )
        }
        #expect(estimator.estimate >= 100_000)

        estimator.reset(to: 900_000)
        for index in 0 ..< 2000 {
            estimator.record(
                frame(index, bytes: 100_000, sentAtMilliseconds: index * 33),
                at: .milliseconds(index * 33)
            )
        }
        #expect(estimator.estimate <= 1_000_000)
    }

    @Test("a reset forgets a path that no longer exists")
    func resetForgetsTheOldPath() {
        // A Wi-Fi to cellular handover is a different path. Carrying the delay
        // history across describes a queue in a router that is no longer in
        // the route.
        var estimator = BandwidthEstimator(initialBitrate: 1_000_000)
        var arrival = 0
        for index in 0 ..< 120 {
            arrival += 33 + 4
            estimator.record(
                frame(index, sentAtMilliseconds: index * 33),
                at: .milliseconds(arrival)
            )
        }
        #expect(estimator.delayTrend > 0)

        estimator.reset(to: 800_000)
        #expect(estimator.estimate == 800_000)
        #expect(estimator.state == .increasing)
        #expect(estimator.receivedBitrate == 0)
    }

    @Test("an object with no capture time still counts toward throughput")
    func objectsWithoutTimestampsStillMeasureThroughput() {
        // A publisher that does not stamp its objects — an older client, or a
        // data track — gives us throughput but no gradient. Better than
        // nothing, and it must not be allowed to drive the state machine on
        // half the information.
        var estimator = BandwidthEstimator(initialBitrate: 700_000)
        for index in 0 ..< 30 {
            estimator.record(
                TrackObject(group: 0, object: UInt64(index), payload: Data(count: 4000)),
                at: .milliseconds(index * 33)
            )
        }
        #expect(estimator.receivedBitrate > 0)
        #expect(estimator.delayTrend == 0)
        #expect(estimator.estimate == 700_000)
    }
}

@Suite("Measured layout")
struct MeasuredLayoutTests {
    @Test("layout uses the measured link when it is not told one")
    func layoutFallsBackToTheMeasurement() async throws {
        // The point of the whole exercise: an integrator who calls
        // `updateLayout` without a bitrate gets a real number rather than
        // `.max`, and did not have to build a congestion controller to get it.
        let relay = LoopbackRelay()
        let session = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: credentials("alice"),
            tenant: "acme"
        )
        try await session.connect(to: RelayEndpoint(host: "loopback"))
        let room = try await session.join(room: "room-42")

        let stats = await room.linkStatistics
        #expect(stats.estimate > 0)
        #expect(stats.state == .increasing)
        #expect(await room.estimatedLinkBitrate == stats.estimate)

        // No participants, so nothing to subscribe to, but the call must not
        // require a bitrate to be supplied.
        let changes = await room.updateLayout([:])
        #expect(changes.isEmpty)
    }

    @Test("media arriving for a participant is metered on the way through")
    func mediaIsMeteredWhereItPasses() async throws {
        let relay = LoopbackRelay()
        let host = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: credentials("alice"),
            tenant: "acme"
        )
        try await host.connect(to: RelayEndpoint(host: "loopback"))
        let hostRoom = try await host.join(room: "room-42")

        let viewer = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: credentials("bob"),
            tenant: "acme"
        )
        try await viewer.connect(to: RelayEndpoint(host: "loopback"))
        let viewerRoom = try await viewer.join(room: "room-42")

        let source = FrameRelay(
            format: CaptureFormat(size: PixelSize(width: 640, height: 360), frameRate: 30),
            depth: 32
        )
        _ = try await hostRoom.startBroadcast(
            from: source,
            configuration: BroadcastConfiguration(
                ladder: LayerLadder(rungs: [
                    VideoLayer(
                        id: "video/360p",
                        size: PixelSize(width: 640, height: 360),
                        frameRate: 30,
                        bitrate: 600_000
                    ),
                ]),
                encoderFactory: { SyntheticEncoder(configuration: $0) }
            )
        )

        let who = identity("alice")
        #expect(await eventually { await viewerRoom.roster[who] != nil })
        await viewerRoom.updateLayout([
            who: RenderBox(width: 640, height: 360, scale: 1, visibility: .visible),
        ])

        for index in 0 ..< 6 {
            source.submit(
                VideoFrame(
                    timestamp: FrameTimestamp(nanoseconds: UInt64(index) * 33_000_000),
                    size: PixelSize(width: 640, height: 360),
                    surface: .synthetic(byteCount: 1024),
                    forcesKeyFrame: index == 0
                )
            )
        }

        #expect(
            await eventually { await viewerRoom.linkStatistics.objectsReceived >= 6 }
        )
        #expect(await viewerRoom.media(from: who) != nil)
    }
}
