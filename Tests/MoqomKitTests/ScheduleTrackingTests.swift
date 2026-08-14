import Testing

@testable import MoqomKit

/// The loop that keeps a viewer's schedule level with a publisher's clock.
///
/// Run against a made-up pair of clocks rather than two phones, which is the point of the type
/// existing separately: the fault it was written for takes minutes of drift to appear on a real
/// call and four hundred milliseconds of simulated time here.
@Suite("Schedule tracking")
struct ScheduleTrackingTests {
    /// Running out of frames says the picture was too fast, and that is the whole of the claim.
    @Test("outrunning the stream cuts a correction that was running fast")
    func outranCutsAFastCorrection() {
        var tracking = ScheduleTracking()
        for _ in 0 ..< 200 { _ = tracking.correction(depth: 0.030, wanted: 0.020) }

        let was = tracking.standing
        #expect(was > 0)
        tracking.outran()
        #expect(tracking.standing < was)

        // And it is resumed at the reduced figure rather than the one that emptied the queue.
        #expect(tracking.resuming() == tracking.standing)
    }

    /// A queue that ran dry while the picture was already slow ran dry for some other reason, and
    /// slowing further is not the answer to it.
    @Test("outrunning leaves a correction that was running slow alone")
    func outranSparesASlowCorrection() {
        var tracking = ScheduleTracking()
        for _ in 0 ..< 200 { _ = tracking.correction(depth: 0.010, wanted: 0.020) }

        let was = tracking.standing
        #expect(was < 0)
        tracking.outran()
        #expect(tracking.standing == was)
    }

    /// The fault this exists for, in the shape it actually had.
    ///
    /// A queue above its request is an error the loop integrates for as long as it lasts; a queue
    /// below it is cut short within a frame or two by the re-anchor, which puts the depth back
    /// above the request. So the loop is exposed to one sign far longer than the other, and the
    /// history climbs whatever the link is really doing.
    @Test("the history does not ratchet when only one sign of error is ever visible")
    func theHistoryDoesNotRatchet() {
        var ratcheting = ScheduleTracking()
        var corrected = ScheduleTracking()

        // Two minutes of it, at the quarter-second the loop actually runs at, with the schedule
        // held ten milliseconds above its request and starved once every couple of seconds —
        // which is the cadence the phones re-anchored at.
        for observation in 1 ... 480 {
            _ = ratcheting.correction(depth: 0.047, wanted: 0.037)
            _ = corrected.correction(depth: 0.047, wanted: 0.037)
            if observation % 8 == 0 { corrected.outran() }
        }

        // Measured on two phones before the cut: a standing correction past twenty-eight hundred
        // parts per million and still climbing, which is a picture running three tenths of a
        // percent fast for the rest of the call.
        #expect(ratcheting.standing > 0.0028)

        // After it, something that stays inside what two crystals could plausibly be apart by.
        #expect(corrected.standing < 0.0002)
    }

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

    /// The disagreement that actually shows up on a phone, which is not two crystals.
    ///
    /// Bounded at two hundred parts per million the loop could not cancel it and the ceiling
    /// correction hauled the schedule back about 1.4 times a second for the length of a call.
    /// Bounded at two thousand — tried on the strength of a measurement that turned out to be
    /// circular — the picture was visibly worse than either.
    @Test("a grid that walks a percent against the source is cancelled")
    func cancelsMoreThanCrystals() {
        var link = Link(drift: 0.01, wanted: 0.020)
        link.run(seconds: 20 * 60)

        #expect(
            abs(link.standing - 0.01) < 0.001,
            "the loop settled somewhere other than the rate it was asked to match"
        )
        #expect(
            abs(link.depth - link.wanted) < 0.002,
            "a schedule this far from its request is one the ceiling correction has to hold down"
        )
    }

    /// A queue about to run out, which used to be left to the re-anchor.
    ///
    /// At the tracking gain a thirty-seven millisecond shortfall commands 0.37 percent and needs
    /// ten seconds, so the step always arrived first — and the step is the lurch. This is the
    /// drain's authority pointed the other way.
    @Test("a shortfall is recovered fast enough to matter")
    func recoversAShortfallBeforeTheStepWould() {
        var tracking = ScheduleTracking()
        let wanted = 0.020

        // Seventeen milliseconds past the newest frame: the queue is empty and frames are being
        // shown late.
        var rate = 0.0
        for _ in 0 ..< 12 { rate = tracking.correction(depth: -0.017, wanted: wanted) ?? rate }

        #expect(rate < -0.01, "a shortfall answered at \(rate) takes longer than the grace period")
        #expect(rate >= -ScheduleTracking.mostDrainWorthApplying)
        #expect(tracking.refills > 0)

        // And it is not mistaken for evidence about the crystals, for the same reason a drain is
        // not: it would otherwise run slow for the rest of the call with nothing left to recover.
        #expect(tracking.standing == 0)
    }

    @Test("ordinary unevenness is not answered with the recovery gain")
    func doesNotRefillOnJitter() {
        var tracking = ScheduleTracking()

        // Ten milliseconds short of a twenty millisecond request is inside the jitter the
        // deadband exists for.
        for _ in 0 ..< 12 { _ = tracking.correction(depth: 0.010, wanted: 0.020) }
        #expect(tracking.refills == 0)
    }

    /// The other half of the bound: it may not record authority it cannot use.
    ///
    /// Held above the request and not allowed to move, which is a loop being asked for something
    /// no rate correction can deliver. It has to stop somewhere, because every part per million
    /// past what it may apply is time spent unwinding before it can answer anything real.
    @Test("an error nothing can fix is not accumulated without limit")
    func doesNotRecordAuthorityItCannotApply() {
        var tracking = ScheduleTracking()
        let wanted = 0.020

        for _ in 0 ..< 40000 {
            _ = tracking.correction(depth: wanted + 0.006, wanted: wanted)
        }

        #expect(tracking.standing <= ScheduleTracking.mostDriftWorthLearning)
        #expect(
            tracking.standing <= ScheduleTracking.mostTrimWorthApplying,
            "a history larger than the rate clamp is a record of authority the loop never had"
        )
    }

    /// The overshoot that sat on the glass: eighteen milliseconds extra against a twenty
    /// millisecond request. At a twenty millisecond gate that is jitter, drained at two
    /// milliseconds a second, and still there when the next burst arrives. Twelve milliseconds
    /// lets it through.
    @Test("a standing overshoot smaller than a thirty-fps frame is still drained")
    func drainsTheOvershootThatLookedLikeJitter() {
        var link = Link(drift: 0, wanted: 0.020)
        link.depth = 0.038

        link.run(seconds: 4)

        #expect(link.depth - link.wanted < ScheduleTracking.anExcessWorthDraining)
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

    /// A schedule a hundred milliseconds short of its delay, which for a long time was filled with
    /// the cautious gain.
    ///
    /// The reasoning was that running fast can at worst empty the queue, while running slow adds
    /// the very delay the loop exists to remove — so only the drain got the authority. What that
    /// left out is what emptying the queue costs: the re-anchor that answers it moves the timebase
    /// under every queued frame, which is a lurch, and at the cautious gain a shortfall took ten
    /// seconds to recover so the lurch always won. Measured on a seven-millisecond link, that was
    /// a queue swinging seventy milliseconds and stepping twice a second.
    @Test("a schedule short of its delay is filled fast enough to avoid the step")
    func fillsBeforeTheStepWould() {
        var link = Link(drift: 0)
        link.depth = link.wanted - 0.1

        var slowest = 0.0
        for _ in 0 ..< 40 {
            link.quarterOfASecond()
            slowest = min(slowest, link.applied)
        }

        #expect(slowest >= -ScheduleTracking.mostDrainWorthApplying)
        #expect(
            slowest < -0.01,
            "a shortfall answered at \(slowest) is one the re-anchor answers first"
        )

        // And it lands, rather than running slow past the point of having recovered.
        #expect(abs(link.depth - link.wanted) < ScheduleTracking.anExcessWorthDraining)
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
