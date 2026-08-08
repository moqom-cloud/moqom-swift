import Testing

@testable import MoqomKit

/// The loop that keeps a viewer's schedule level with a publisher's clock.
///
/// Run against a made-up pair of clocks rather than two phones, which is the point of the type
/// existing separately: the fault it was written for takes minutes of drift to appear on a real
/// call and four hundred milliseconds of simulated time here.
@Suite("Schedule tracking")
struct ScheduleTrackingTests {
    /// A viewer's schedule against a publisher whose clock runs at a different rate.
    ///
    /// The only physics involved: the depth between the newest frame and the playhead grows at
    /// the difference between the two rates. The publisher runs `drift` faster than real time,
    /// the viewer presents at whatever the loop asks for, and the gap is the integral of the
    /// difference.
    struct Link {
        var drift: Double
        var wanted: Double
        var depth: Double

        private var tracking = ScheduleTracking()
        private var rate = 0.0

        init(drift: Double, wanted: Double = 0.09) {
            self.drift = drift
            self.wanted = wanted
            depth = wanted
        }

        var standing: Double { tracking.standing }

        /// The rate the loop is actually running at, which is what the drain tests are about.
        var applied: Double { rate }

        /// A quarter of a second, which is how often the renderer revises the correction.
        mutating func quarterOfASecond() {
            depth += (drift - rate) * 0.25
            if let moved = tracking.correction(depth: depth, wanted: wanted) { rate = moved }
        }

        mutating func run(seconds: Double) {
            for _ in 0 ..< Int(seconds * 4) { quarterOfASecond() }
        }
    }

    @Test("a publisher whose clock runs fast is tracked, not chased")
    func convergesOnTheDrift() {
        // A hundred parts per million: two ordinary crystals, and enough to add a hundred
        // milliseconds of unasked-for delay every quarter of an hour.
        var link = Link(drift: 0.0001)
        link.run(seconds: 60)

        // The loop has found the drift and is holding it, so the depth is where it was asked
        // to be rather than wherever an hour of drift would have taken it.
        #expect(abs(link.standing - 0.0001) < 0.00002)
        #expect(abs(link.depth - link.wanted) < 0.002)
    }

    @Test("the same in the other direction")
    func convergesOnASlowPublisher() {
        var link = Link(drift: -0.0001)
        link.run(seconds: 60)
        #expect(abs(link.standing + 0.0001) < 0.00002)
        #expect(abs(link.depth - link.wanted) < 0.002)
    }

    @Test("it settles rather than oscillating around the target")
    func settlesWithoutRinging() {
        // The failure a purely integral loop has, and the reason for the proportional term:
        // depth is the integral of the rate error, so integral action alone makes an undamped
        // second-order system, which does not converge — it rings for the length of the call.
        var link = Link(drift: 0.0002)
        link.run(seconds: 120)

        var worst = 0.0
        for _ in 0 ..< 120 {
            link.quarterOfASecond()
            worst = max(worst, abs(link.depth - link.wanted))
        }
        // A millisecond of residual movement after it has settled, against the tens the
        // undamped version swings by.
        #expect(worst < 0.001)
    }

    @Test("a starting error is removed instead of being lived with")
    func closesAnAnchorError() {
        // What a schedule anchored on a late frame leaves behind: the depth is well above what
        // was asked for and nothing about the link is wrong. Before this loop existed, that
        // error stayed until the delay wandered far enough to trip a re-anchor.
        //
        // Two minutes to close a tenth of a second, which is the price of a loop slow enough
        // to ignore jitter. Nothing waits that long in practice: an error this size is what
        // ``PlayoutDelay/Adjustment/giveBack(seconds:landingOn:)`` exists for, and it runs the
        // clock an order of magnitude harder. This is the floor under that, for the errors too
        // small to be worth a give-back and too large to live with.
        var link = Link(drift: 0)
        link.depth = 0.2
        link.run(seconds: 120)
        #expect(abs(link.depth - link.wanted) < 0.005)
    }

    @Test("a rate nobody could see, even while correcting")
    func neverAskedForAVisibleRate() {
        var link = Link(drift: 0.0001)
        link.depth = 0.4

        var fastest = 0.0
        for _ in 0 ..< 400 {
            link.quarterOfASecond()
            fastest = max(fastest, abs(link.standing))
        }
        #expect(fastest <= ScheduleTracking.mostTrimWorthApplying)
    }

    @Test("an error beyond its authority does not become a record of authority it lacks")
    func doesNotWindUp() {
        // A publisher running five percent fast is not a crystal, and this loop cannot hold it.
        // What it must not do is spend the whole time accumulating a correction it never
        // applied, because then it answers nothing for as long again after the cause has gone.
        var link = Link(drift: 0.05)
        link.run(seconds: 30)
        #expect(link.standing <= ScheduleTracking.mostTrimWorthApplying)

        // What winding up would look like: thirty seconds of an error the loop could not
        // answer, recorded as thirty seconds' worth of correction it then has to spend. The
        // history should hold a small number instead — the part of the excursion that was
        // inside its reach — so that when the publisher settles, so does this.
        #expect(link.standing < 0.002)

        link.drift = 0
        link.depth = link.wanted
        link.run(seconds: 60)
        #expect(abs(link.depth - link.wanted) < 0.005)
    }

    @Test("delay above what was asked for is drained in seconds, not minutes")
    func drainsAnExcessPromptly() {
        // The fault this answers, measured on a phone: a leg holding a hundred milliseconds more
        // than it asked for commanded one percent of rate, which needs ten seconds — and the next
        // burst refilled it long before then, so the excess was permanent rather than slowly
        // corrected. Its hold sat at sixty-four milliseconds against a fifty-millisecond ceiling
        // while every figure it published about itself was inside its bounds.
        var link = Link(drift: 0)
        link.depth = link.wanted + 0.1

        link.run(seconds: 4)

        // Down to jitter, which is where the gentle loop takes over. The old gain left almost the
        // whole hundred milliseconds still sitting there at this point.
        #expect(link.depth - link.wanted < ScheduleTracking.anExcessWorthDraining + 0.005)
    }

    @Test("a schedule short of its delay is filled with the old caution")
    func fillsCautiously() {
        // The asymmetry, which is the whole design: running fast moves towards the publisher's
        // clock and can at worst empty the queue, while running slow adds the delay this exists
        // to remove. Only the first gets the extra authority.
        var link = Link(drift: 0)
        link.depth = link.wanted - 0.1

        var slowest = 0.0
        for _ in 0 ..< 40 {
            link.quarterOfASecond()
            slowest = min(slowest, link.applied)
        }

        #expect(slowest >= -ScheduleTracking.mostTrimWorthApplying)
        #expect(slowest < -0.001)
    }

    @Test("a depth that drops in one step is not drained on a stale estimate")
    func stopsDrainingWhatIsGone() {
        // A re-anchor moves the depth in a single step while the loop's estimate of it takes about
        // two seconds to follow. Draining on the estimate alone means running five percent fast
        // across those two seconds against a queue that no longer holds the surplus — a further
        // hundred milliseconds taken out of it, and the frames that should have filled it shown
        // late. The gate is the live reading, which is not fooled.
        var tracking = ScheduleTracking()
        let wanted = 0.05

        for _ in 0 ..< 8 { _ = tracking.correction(depth: wanted + 0.15, wanted: wanted) }
        let afterTheReanchor = tracking.correction(depth: wanted, wanted: wanted) ?? 0

        #expect(afterTheReanchor <= ScheduleTracking.mostTrimWorthApplying)
    }

    @Test("draining an excess teaches the loop nothing about crystals")
    func drainingIsNotDriftEvidence() {
        // Why the history is still gated on the tracking clamp rather than whichever one is in
        // force. A drain is not evidence about crystals, and recording it as such would leave the
        // loop running fast for the rest of the call with nothing left to correct.
        var link = Link(drift: 0)
        link.depth = link.wanted + 0.2

        link.run(seconds: 6)

        #expect(abs(link.standing) < 0.001)
    }

    @Test("what was learnt survives a re-anchor")
    func resumingKeepsTheCorrection() {
        var tracking = ScheduleTracking()
        for _ in 0 ..< 40 { _ = tracking.correction(depth: 0.1, wanted: 0.09) }
        let learnt = tracking.standing
        #expect(learnt > 0)

        // A re-anchor takes the rate away and hands it back; the two crystals disagree by the
        // same amount either side of it.
        #expect(tracking.resuming() == learnt)

        // A restart is a different matter: possibly a different publisher, so a correction
        // measured against the old one is worse than none.
        tracking.forget()
        #expect(tracking.standing == 0)
    }
}
