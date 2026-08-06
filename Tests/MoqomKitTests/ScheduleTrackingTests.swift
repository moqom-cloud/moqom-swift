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
