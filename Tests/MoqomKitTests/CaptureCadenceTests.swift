// Running the sensor faster than the publication, and which frames that publishes.
//
// The camera is not testable here — no device, no authorisation prompt to answer — but both
// halves of this are, and both are the kind of wrong that produces working video. Choose the
// rate badly and the phone runs a 4K sensor to save eight milliseconds. Discard the wrong
// frames and the publication is unevenly spaced or the wrong rate entirely, which reads as a
// network fault at the far end and is charged to the relay by every figure that reports it.

import Foundation
import Testing

@testable import MoqomCore
@testable import MoqomKit

@Suite("What a stage costs at its best")
struct StageFloorTests {
    @Test("the floor is the quickest in the window, not the quickest ever")
    func reportsTheFloor() {
        // Load-bearing for the latency figure rather than a curiosity. A clock offset taken as
        // the smallest sensor-to-delivery gap subtracts exactly this much from every latency
        // reported, so it is the number that puts the capture stage back into the total — and
        // it has to describe the same window the offset was derived from, or the correction is
        // for a frame that is no longer representative.
        var meter = StageMeter()
        for milliseconds in [19.0, 15.5, 22.0, 16.0, 40.0] {
            meter.record(.milliseconds(Int(milliseconds)))
        }

        let summary = meter.summary
        #expect(summary.best == 15.0)
        #expect(summary.worst == 40.0)
        #expect(summary.samples == 5)
    }

    @Test("a stage with nothing recorded claims nothing")
    func emptyIsZero() {
        #expect(StageMeter().summary.best == 0)
    }
}

@Suite("Capture cadence")
struct CaptureCadenceTests {
    /// A 720p sensor mode at sixty, and the same one at a hundred and twenty.
    private let base = CaptureCadence.Option(
        pixels: 1280 * 720,
        lowestFrameRate: 1,
        highestFrameRate: 60
    )
    private let doubled = CaptureCadence.Option(
        pixels: 1280 * 720,
        lowestFrameRate: 1,
        highestFrameRate: 120
    )

    @Test("the faster mode is taken when it costs no more pixels")
    func takesTheFasterMode() {
        #expect(
            CaptureCadence.sensorRate(publishing: 60, from: [base, doubled], limit: 2) == 120
        )
    }

    @Test("a device with nothing faster publishes from its own rate")
    func declinesWhenThereIsNothingFaster() {
        #expect(CaptureCadence.sensorRate(publishing: 60, from: [base], limit: 2) == 60)
    }

    @Test("the faster mode is declined when it would cost resolution")
    func declinesABiggerSensorMode() {
        // The trade that has to be refused: a phone reaching a hundred and twenty only by
        // reading a 4K sensor would spend the whole power saving of the capture ladder to buy
        // eight milliseconds, and the encoder is about to scale those pixels away anyway.
        let expensive = CaptureCadence.Option(
            pixels: 3840 * 2160,
            lowestFrameRate: 1,
            highestFrameRate: 120
        )
        #expect(
            CaptureCadence.sensorRate(publishing: 60, from: [base, expensive], limit: 2) == 60
        )
    }

    @Test("a high-speed mode that cannot run slowly is not a candidate")
    func respectsTheLowerBound() {
        // Some formats have a floor as well as a ceiling. One that will not go below 120 can
        // still be the doubled mode, but a request to publish at 120 from it has nothing to
        // double into.
        let highSpeed = CaptureCadence.Option(
            pixels: 1280 * 720,
            lowestFrameRate: 120,
            highestFrameRate: 240
        )
        #expect(CaptureCadence.sensorRate(publishing: 60, from: [highSpeed], limit: 2) == 60)
        #expect(
            CaptureCadence.sensorRate(publishing: 120, from: [highSpeed], limit: 2) == 240
        )
    }

    @Test("declining oversampling asks for the publication rate")
    func offMeansOff() {
        #expect(CaptureOversampling.off.limit == 1)
        #expect(
            CaptureCadence.sensorRate(
                publishing: 30,
                from: [base, doubled],
                limit: CaptureOversampling.off.limit
            ) == 30
        )
    }

    @Test("the faster sensor is taken at every publication rate")
    func doesNotJudgeOnRate() {
        // Deliberately not conditioned on the rate, though the obvious model says it should
        // be. What decides is whether a device has already reached its image pipeline's floor,
        // and the two phones measured disagree at the same sixty frames a second: the Air
        // gains four milliseconds going to a 120fps sensor and the Pro gains none. Nothing
        // available before the camera is open tells the two apart.
        #expect(CaptureOversampling.automatic.limit == 2)
        #expect(
            CaptureCadence.sensorRate(
                publishing: 60,
                from: [base, doubled],
                limit: CaptureOversampling.automatic.limit
            ) == 120
        )
    }

    @Test("a sensor at the publication rate discards nothing")
    func passesEverythingThrough() {
        var cadence = CaptureCadence(publishing: 60, sensor: 60)
        #expect(!cadence.oversamples)
        for frame in 0 ..< 10 {
            let delivered = cadence.delivers(at: Double(frame) / 60)
            #expect(delivered)
        }
    }

    @Test("a doubled sensor publishes every other frame")
    func halvesTheRate() {
        var cadence = CaptureCadence(publishing: 60, sensor: 120)
        #expect(cadence.multiple == 2)

        var kept: [Int] = []
        for frame in 0 ..< 12 where cadence.delivers(at: Double(frame) / 120) {
            kept.append(frame)
        }
        #expect(kept == [0, 2, 4, 6, 8, 10])
    }

    @Test("a quadrupled sensor still publishes at the requested rate")
    func quartersTheRate() {
        // The case that catches a tolerance expressed as a fraction of the publication
        // interval rather than of the sensor's: at four times the rate, three quarters of a
        // publication interval lands exactly on the third frame and the result is eighty
        // frames a second from a sixty-frame publication.
        var cadence = CaptureCadence(publishing: 60, sensor: 240)
        var kept: [Int] = []
        for frame in 0 ..< 16 where cadence.delivers(at: Double(frame) / 240) {
            kept.append(frame)
        }
        #expect(kept == [0, 4, 8, 12])
    }

    @Test("a sensor that drops a frame re-phases instead of drifting")
    func survivesADroppedFrame() {
        // A camera under system pressure drops frames on its own. Counting every other one
        // would put the publication half a frame out of phase for the rest of the session;
        // deciding on the stamps recovers on the next frame.
        var cadence = CaptureCadence(publishing: 60, sensor: 120)
        let stamps = [0, 1, 2, 3, 5, 6, 7, 8].map { Double($0) / 120 }

        var kept: [Double] = []
        for stamp in stamps where cadence.delivers(at: stamp) {
            kept.append(stamp)
        }

        // Frame four never arrived, so five is published in its place and the cadence carries
        // on from there. What must not happen is a run of consecutive frames or a long gap.
        let gaps = zip(kept, kept.dropFirst()).map { $1 - $0 }
        #expect(gaps.allSatisfy { $0 > 1.0 / 120 && $0 < 3.0 / 120 })
    }

    @Test("a restarted session does not discard everything")
    func rephasesAcrossADiscontinuity() {
        // An interruption ends with the session running on its own clock, which can be behind
        // the one before it. Measured against a stale reference, every frame would look too
        // early and the publication would stop until the new clock caught up with the old.
        var cadence = CaptureCadence(publishing: 60, sensor: 120)
        _ = cadence.delivers(at: 900)

        let first = cadence.delivers(at: 0)
        let second = cadence.delivers(at: 1.0 / 120)
        let third = cadence.delivers(at: 2.0 / 120)
        #expect(first)
        #expect(!second)
        #expect(third)
    }
}
