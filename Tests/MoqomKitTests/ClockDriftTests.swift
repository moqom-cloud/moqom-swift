import Foundation
import Testing

@testable import MoqomKit

@Suite("measuring the local oscillator instead of assuming the worst")
struct ClockDriftTests {
    /// Exchanges from a crystal running at a known rate, polled every five
    /// minutes, each pinned down to `measurement` seconds.
    private func run(
        ppm: Double,
        polls: Int,
        measurement: Double = 0.005,
        interval: Double = 300
    ) -> [ClockDrift.Observation] {
        (0 ..< polls).map { poll in
            let seconds = Double(poll) * interval
            return ClockDrift.Observation(
                seconds: seconds,
                error: seconds * ppm / 1_000_000,
                measurement: measurement
            )
        }
    }

    @Test("a run of exchanges tells you the rate they were taken at")
    func findsTheRate() {
        let drift = ClockDrift.estimate(from: run(ppm: 12, polls: 8))
        #expect(abs(drift.rate - 12.0 / 1_000_000) < 0.1 / 1_000_000)
    }

    @Test("the bound beats the datasheet once there is a baseline to fit over")
    func narrowsTheBound() {
        let drift = ClockDrift.estimate(from: run(ppm: 12, polls: 8))

        // Eight polls is a 35-minute baseline; 5ms exchanges over that is a
        // few parts per million rather than a hundred.
        #expect(drift.bound < TrustedClock.maximumDrift / 10)

        // Which is what the whole thing is for: the admitted error over one
        // poll interval, in milliseconds.
        let admitted = drift.uncertainty(after: 300) * 1000
        #expect(admitted < 3)
    }

    @Test("a worse exchange widens the bound rather than being ignored")
    func respectsTheExchange() {
        let good = ClockDrift.estimate(from: run(ppm: 12, polls: 8, measurement: 0.002))
        let poor = ClockDrift.estimate(from: run(ppm: 12, polls: 8, measurement: 0.040))
        #expect(poor.bound > good.bound)
    }

    @Test("no fit is claimed from too few exchanges or too short a window")
    func declinesWithoutEvidence() {
        #expect(ClockDrift.estimate(from: run(ppm: 12, polls: 2)) == .unmeasured)
        #expect(ClockDrift.estimate(from: []) == .unmeasured)

        // Three polls, but taken seconds apart: the separation is smaller than
        // the exchange error, so the slope through them is noise.
        let hurried = run(ppm: 12, polls: 3, interval: 10)
        #expect(ClockDrift.estimate(from: hurried) == .unmeasured)
    }

    @Test("a slope no crystal could produce falls back to the prior")
    func refusesTheImplausible() {
        // Something other than drift moved this clock — a step, or a forged
        // reply that got through. A fit would encode it as a rate and then
        // project it forward forever.
        var observations = run(ppm: 0, polls: 8)
        observations[7] = ClockDrift.Observation(
            seconds: observations[7].seconds,
            error: 5.0,
            measurement: 0.005
        )
        #expect(ClockDrift.estimate(from: observations) == .unmeasured)
    }

    @Test("the bound never claims more than the oscillator will hold")
    func floorsAtStability() {
        // A day of perfect exchanges would fit to a nanosecond per second. The
        // rate is not constant over the interval this gets used across, so the
        // floor is what keeps the claim honest.
        let drift = ClockDrift.estimate(
            from: run(ppm: 12, polls: 8, measurement: 0.000_001, interval: 3600)
        )
        #expect(drift.bound == ClockDrift.stability)
    }

    @Test("correcting the rate is what stops a drifting clock looking stepped")
    func predictsTheNextExchange() {
        // Eight polls to learn the rate, then project across a ninth interval
        // and see how far off the prediction lands. Uncorrected this is the
        // full drift; corrected it is whatever the fit missed.
        let history = run(ppm: 80, polls: 8)
        let drift = ClockDrift.estimate(from: history)

        let interval = 300.0
        let actual = interval * 80 / 1_000_000
        let uncorrected = actual
        let corrected = abs(actual - drift.correction(after: interval))

        #expect(uncorrected * 1000 > 20)
        #expect(corrected * 1000 < 1)
    }
}
