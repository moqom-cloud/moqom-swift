// What the local oscillator is actually doing, rather than what a datasheet
// says it might.
//
// ``TrustedClock`` projects an old exchange forward by adding elapsed monotonic
// time to it, which assumes the local crystal runs at exactly the right rate.
// It does not, so the projection is widened by ``TrustedClock/maximumDrift`` —
// a hundred parts per million, the pessimistic end of what a cheap oscillator
// does across its temperature range. Over the five minutes between polls that
// is thirty milliseconds of admitted error, and it is admitted whether or not
// any of it happened.
//
// The thing is that a run of exchanges already contains the answer. Each one
// says what trusted time was at a known monotonic reading, so the *slope* of
// trusted-minus-monotonic across them is the rate error itself, in the units it
// is wanted in. Measuring it costs no extra polls and turns the bound from a
// property of the worst crystal ever shipped into a property of this one: a few
// parts per million on a phone, so a millisecond or two rather than thirty.
//
// Two things follow that are worth stating, because they are why this is worth
// having beyond a narrower number on a readout. Knowing the rate means the
// projection can be *corrected* and not merely bounded, so successive exchanges
// land where the previous one predicted. And ``TrustedClock/adopt(_:)`` decides
// whether a new exchange agrees with history by comparing it against exactly
// that prediction — so an uncorrected rate error shows up as disagreement, and
// a large enough one gets read as the clock having stepped.
//
// # Why the bound is what it is
//
// The slope is fitted through points that are each uncertain by their own
// exchange's measurement error, so the error in the slope is roughly that
// divided by the baseline it was fitted over. Five milliseconds of exchange
// error across half an hour of anchors is about three parts per million, and
// the bound gets wider automatically when the exchanges were poor or the window
// is short — which is the correct behaviour and the reason for preferring this
// to just asserting that phones are good.
//
// It is floored rather than trusted all the way down. A fit over a long enough
// baseline can claim a tighter rate than the oscillator will hold, because the
// rate is not a constant: it moves with temperature, and a phone that starts
// encoding video is a phone whose crystal is about to warm up. The floor is
// what stops a confident fit from outliving the conditions it was taken in.

import Foundation

/// The local clock's measured rate error, and how well that is known.
///
/// Both are fractions rather than durations: a rate is per unit time, and the
/// error it accounts for depends on how long a projection runs.
struct ClockDrift: Sendable, Hashable {
    /// How much slower the local monotonic clock runs than trusted time.
    ///
    /// Positive means the local clock is losing, so a projection needs to add
    /// this fraction of the elapsed time on top. Sign is easiest to keep
    /// straight from the projection it feeds: `trusted + elapsed × (1 + rate)`.
    let rate: Double

    /// What ``rate`` could be wrong by, as a fraction.
    let bound: Double

    /// The prior: no correction, and the datasheet's worst case as the bound.
    ///
    /// What a clock is worth before it has enough exchanges to say anything
    /// about itself, and what it falls back to when a fit comes out implausible.
    static let unmeasured = ClockDrift(rate: 0, bound: TrustedClock.maximumDrift)

    /// The tightest rate error worth believing, as a fraction.
    ///
    /// One part per million. Not a measurement limit — a long enough baseline
    /// will fit tighter than this — but a statement that the rate is not
    /// constant over the interval the fit is used across, so a bound below it
    /// describes the fit rather than the clock.
    static let stability = 1.0 / 1_000_000.0

    /// Exchanges needed before a fit is attempted.
    ///
    /// Three, so that a slope is over-determined rather than drawn through two
    /// points. Two points always fit perfectly and say nothing about whether
    /// they should have.
    static let minimumSamples = 3

    /// The shortest baseline a fit is taken from, in seconds.
    ///
    /// Below this the exchange errors dominate the separation and the slope is
    /// mostly noise. Two minutes puts the bound at the same order as the
    /// datasheet figure it would replace, so there is nothing to gain until
    /// then and something to lose from a bad fit.
    static let minimumSpan = 120.0

    /// One exchange, reduced to what a fit needs.
    struct Observation: Sendable, Hashable {
        /// Monotonic seconds, from any fixed origin.
        let seconds: Double

        /// Trusted time minus monotonic time at that reading, in seconds.
        ///
        /// The accumulated error, which is the quantity whose slope is wanted.
        /// The origin cancels in the fit, so it does not matter that this is
        /// dominated by the arbitrary constant between the two clocks — but the
        /// caller should subtract a reference anyway, because a double holding
        /// nanoseconds since 1970 has resolution to spare and no more.
        let error: Double

        /// What that exchange could not pin down, in seconds.
        let measurement: Double
    }

    /// Fit a rate through a run of exchanges.
    ///
    /// Returns ``unmeasured`` rather than a bad answer whenever the input
    /// cannot support one: too few points, too short a baseline, or a slope so
    /// far outside what an oscillator does that something other than drift
    /// produced it.
    static func estimate(from observations: [Observation]) -> ClockDrift {
        guard observations.count >= minimumSamples else { return .unmeasured }

        let seconds = observations.map(\.seconds)
        guard let earliest = seconds.min(), let latest = seconds.max() else { return .unmeasured }
        let span = latest - earliest
        guard span >= minimumSpan else { return .unmeasured }

        let count = Double(observations.count)
        let meanSeconds = seconds.reduce(0, +) / count
        let meanError = observations.map(\.error).reduce(0, +) / count

        var covariance = 0.0
        var variance = 0.0
        for observation in observations {
            let offset = observation.seconds - meanSeconds
            covariance += offset * (observation.error - meanError)
            variance += offset * offset
        }
        guard variance > 0 else { return .unmeasured }

        let rate = covariance / variance

        // A fit outside the datasheet bound is not a fast crystal, it is an
        // exchange that lied or a history that spans something this does not
        // model. The prior is the safe answer and costs only the width it
        // already had.
        guard rate.isFinite, abs(rate) <= TrustedClock.maximumDrift else { return .unmeasured }

        // Twice the worst exchange over the baseline: the slope is pinned by
        // the ends, and either end being wrong by its own measurement error
        // tilts it by that much across the span.
        let worst = observations.map(\.measurement).max() ?? 0
        let bound = min(
            TrustedClock.maximumDrift,
            max(stability, 2 * worst / span)
        )
        return ClockDrift(rate: rate, bound: bound)
    }

    /// What this rate contributes to a projection over `elapsed` seconds.
    func correction(after seconds: Double) -> Double {
        seconds * rate
    }

    /// What this rate leaves unaccounted for over `elapsed` seconds.
    func uncertainty(after seconds: Double) -> Double {
        seconds * bound
    }
}
