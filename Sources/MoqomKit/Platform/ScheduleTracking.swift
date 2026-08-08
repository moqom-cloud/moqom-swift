// Holding one device's presentation clock level with another device's capture clock.
//
// Frames are stamped by the publisher and presented against the viewer's own timebase, and the
// two are driven by different crystals. They disagree — always, by tens of parts per million,
// and by more when one of the two is warm or busy. The gap between the newest frame and the
// playhead therefore walks in one direction for as long as the call lasts, in whichever
// direction the disagreement happens to go.
//
// Left alone it ends one of two ways. Walking up, the delay grows until the schedule gives up
// and re-anchors, which moves the timebase under every frame already queued and lurches the
// picture; measured across two phones, that was once every seven seconds for nine minutes, a
// hold cycling between the 89ms that was asked for and 240ms. Walking down, the buffer empties
// and ordinary jitter starts arriving late.
//
// A small permanent correction to the presentation rate removes the cause. Separate from the
// question of how deep the buffer should be, which is ``PlayoutDelay``'s: that one decides
// where the schedule should sit, and this one keeps it there.
//
// Here rather than in the renderer for the same reason ``PlayoutDelay`` is: a control loop that
// needs a display layer and a real clock to run can only be judged by watching a call, and a
// loop can be wrong in ways that take a minute of drift to show. This one can be run against a
// made-up pair of clocks a thousand times in a test.

/// A proportional-integral loop over the depth of a presentation schedule.
struct ScheduleTracking: Sendable, Equatable {
    /// Past this the correction is no longer a correction.
    ///
    /// Two percent, which is far more than two crystals ever disagree by and is deliberately
    /// not sized for crystals. The drift a viewer actually sees is whatever moves the gap
    /// between arriving frames and the grid they are presented on, and an evenly spaced grid
    /// laid down at a slightly wrong interval walks against the source at a percent or so —
    /// far more than the parts per million the hardware contributes.
    ///
    /// Running fast is not the same as running out of step, which is the thing worth being
    /// careful about here. Both media are timed by the publisher, so a viewer correcting its
    /// picture towards the publisher's clock is moving into agreement with the voice rather
    /// than away from it: the correction closes lip sync, it does not open it. The clamp is
    /// therefore about limiting the damage a bad measurement can do, not about protecting sync.
    static let mostTrimWorthApplying = 0.02

    /// How hard the loop leans on the error in front of it, and on the history of it.
    ///
    /// Depth is the integral of the rate error, so a loop correcting it with integral action
    /// alone is second-order with nothing damping it: it does not settle, it oscillates around
    /// the target for the length of the call. The first of these is the damping. The second is
    /// what lets the settled error be zero rather than merely small, which matters because the
    /// thing being cancelled is a constant.
    ///
    /// Tuned together for a critically damped loop with a time constant around twenty seconds.
    /// Slow on purpose, and the reason is the input: depth is read from live arrivals, which
    /// jitter by tens of milliseconds several times a second, while the drift underneath moves
    /// over minutes. A loop quick enough to answer the jitter would spend the call answering
    /// it, at the cost of the picture's speed wobbling in time with the network.
    static let leanOnTheError = 0.1
    static let leanOnItsHistory = 0.000625

    /// What the loop may do when the schedule is holding more delay than was asked for.
    ///
    /// Draining an excess and tracking two crystals are different jobs sharing one loop, and
    /// every figure above is tuned for the second. Drift is tens of parts per million and moves
    /// over minutes, so a gain of a tenth and a clamp of two percent are generous for it — and
    /// glacial for the first. Measured on a phone holding a hundred milliseconds more than it
    /// asked for: the error commanded one percent, which needs ten seconds to drain, and the next
    /// burst arrived long before that. The excess was not slowly corrected, it was permanent, and
    /// the leg sat at sixty-four milliseconds of hold against a fifty-millisecond ceiling.
    ///
    /// Asymmetric, because the two directions do not carry the same risk. Running fast moves the
    /// picture towards the publisher's clock, so it closes lip sync rather than opening it, and
    /// the worst it can do is empty the queue — bounded, and answered by the schedule's own
    /// re-anchor. Running slow adds delay, which is the thing being drained. So the authority
    /// goes to the drain direction and the caution stays with the other.
    ///
    /// Five percent of a talking head is not visible; ten seconds of avoidable delay is.
    static let mostDrainWorthApplying = 0.05
    static let leanOnAnExcess = 1.0

    /// How much more than was asked for counts as an excess rather than jitter.
    ///
    /// A frame's worth at thirty a second. Below this the reading is the ordinary unevenness of
    /// live arrivals, and answering it with the authority above is how a loop ends up wobbling
    /// the picture's speed in time with the network.
    static let anExcessWorthDraining = 0.02

    /// How much of a new depth reading to believe, against the running estimate.
    ///
    /// An eighth per reading, four readings a second: a couple of seconds of smoothing, which
    /// is short against the loop above it and long against the jitter beneath it. Filtering
    /// here rather than trusting the loop's slowness to do it keeps the proportional term
    /// working on something that resembles the drift.
    static let believeOfEachReading = 0.125

    /// A change smaller than this is not worth the timebase operation it would cost.
    ///
    /// Two parts per million. Coarser sounds harmless and is not: the whole quantity being
    /// tracked is tens of parts per million, so a threshold anywhere near it quantises the
    /// correction into steps larger than the thing being corrected, and the loop can only
    /// hunt around the answer instead of arriving at it.
    static let worthApplying = 0.000002

    /// What the loop has learnt about the difference between the two clocks.
    ///
    /// The useful figure to look at: it is a direct measurement of something no other counter
    /// sees, and it should settle within a few tens of parts per million of zero. Sitting
    /// against ``mostTrimWorthApplying`` is the loop reporting that what it is being asked to
    /// track is not crystal drift.
    private(set) var standing = 0.0

    /// The correction currently in force, so it is only reapplied when it has moved.
    private(set) var applied = 0.0

    /// The smoothed depth the loop is working from. See ``believeOfEachReading``.
    private var settled: Double?

    /// Fold one observation of the schedule's depth into the correction.
    ///
    /// - Parameters:
    ///   - depth: How far ahead of the playhead the newest frame is, in seconds.
    ///   - wanted: The depth that was asked for, in seconds.
    /// - Returns: The rate offset to apply — 0.0001 meaning a hundred parts per million faster
    ///   than real time — or `nil` when it has not moved enough to be worth applying.
    mutating func correction(depth: Double, wanted: Double) -> Double? {
        let smoothed = settled.map { $0 + (depth - $0) * Self.believeOfEachReading } ?? depth
        settled = smoothed

        let error = smoothed - wanted

        // Draining, or tracking. The distinction is only ever this: whether there is more delay
        // in the schedule than the caller asked to pay for.
        //
        // Both the estimate and the reading in front of it have to agree, because the estimate
        // takes about two seconds to follow a change and a re-anchor moves the depth in one step.
        // Without the second condition the loop spends those two seconds draining a surplus that
        // is already gone — at five percent, which is a further hundred milliseconds off a queue
        // that no longer has it, and the frames that should have filled it are shown late.
        let draining = error > Self.anExcessWorthDraining
            && depth - wanted > Self.anExcessWorthDraining
        let lean = draining ? Self.leanOnAnExcess : Self.leanOnTheError
        let most = draining ? Self.mostDrainWorthApplying : Self.mostTrimWorthApplying

        let proposed = lean * error + standing

        // The history only accumulates while the correction is one this loop can actually
        // apply. Past the clamp the rate no longer follows the error, so continuing to add it
        // up records authority the loop does not have, and it then spends seconds unwinding
        // that record before it can respond to anything at all. Whatever produces an error that
        // large is not crystal drift.
        // Against the tracking clamp rather than whichever one is in force, deliberately. This
        // record is the loop's estimate of how far apart the two crystals are, and a drain is not
        // evidence about crystals: letting an excess accumulate here would teach the loop a
        // standing correction for something that has already been drained away, and it would
        // then run fast for the rest of the call with nothing left to correct.
        if abs(proposed) < Self.mostTrimWorthApplying {
            standing += Self.leanOnItsHistory * error
        }

        let rate = min(most, max(-Self.mostTrimWorthApplying, proposed))

        guard abs(rate - applied) > Self.worthApplying else { return nil }
        applied = rate
        return rate
    }

    /// The correction to resume at after the clock has been driven by something else.
    ///
    /// A re-anchor and a give-back both take the rate away from this loop and hand it back. The
    /// disagreement between the two crystals did not pause while that happened, so what is
    /// resumed is what was already learnt: returning to a flat rate instead means every one of
    /// those events starts the slide again, and the loop's whole value is that it does not have
    /// to be relearnt.
    mutating func resuming() -> Double {
        applied = standing
        return standing
    }

    /// Forget everything, for a stream that is no longer the same stream.
    ///
    /// Unlike a re-anchor, which keeps it. A restart may bring a different publisher, and a
    /// correction carried onto a clock it was never measured against is worse than none.
    mutating func forget() {
        standing = 0
        applied = 0
        settled = nil
    }
}
