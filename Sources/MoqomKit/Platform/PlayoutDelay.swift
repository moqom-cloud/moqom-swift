import Foundation

/// What the adaptive playout delay should do next, decided from measurement alone.
///
/// Separated from the renderer because the decision is the part that has been wrong, twice, and
/// neither time could be reproduced without two phones and a relay. Nothing here touches a
/// timebase, a layer or a clock: it takes the headroom the frames actually arrived with and
/// returns the move, which means the loop can be run a thousand times in a test and asked
/// whether it settles.
enum PlayoutDelay {
    /// Enough for everything that still has to happen to a frame after it is handed over.
    ///
    /// Slack is measured at enqueue, and a frame is not shown at enqueue: it is decoded —
    /// several milliseconds of hardware — and then composited on a refresh boundary, up to a
    /// whole refresh interval later. Four milliseconds of slack is a frame that misses both.
    ///
    /// Measured, that is exactly what it did. An earlier controller drove the headroom onto its
    /// own four millisecond target and the display layer dropped a third of every frame it was
    /// given — 581 of 1740 in a minute — while every counter this side of it read a clean thirty
    /// frames a second, no lateness, nothing skipped. The unscheduled preview layer on the same
    /// screen, in the same app, dropped none of 1770, which is what said the panel was innocent
    /// and the schedule was not.
    ///
    /// Eighteen milliseconds covers a 720p decode and a sixty hertz refresh. A phone whose panel
    /// is faster spends the difference on latency, and it is a few milliseconds against a third
    /// of the picture.
    static let margin = 0.018

    /// The refresh interval ``margin`` was measured against.
    static let sixtyHertz = 1.0 / 60

    /// The least margin worth holding whatever the panel does.
    ///
    /// One refresh of a hundred-and-twenty hertz panel is 8.3ms, so this leaves about 3.7ms for
    /// the decode beside it. The stop exists because the cost of being wrong here is not a few
    /// milliseconds of latency, it is a third of the picture: an earlier controller drove the
    /// headroom onto a four millisecond target and the display layer silently dropped 581 frames
    /// of 1740. How long a hardware decode actually takes is not something this codebase measures
    /// yet, so the credit below stops while there is still room for one.
    static let leastMargin = 0.012

    /// What the display needs, on a panel that refreshes every `refresh` seconds.
    ///
    /// ``margin`` covers a decode and one refresh of a sixty hertz panel, and a phone with a
    /// faster panel waits less for its refresh boundary than that figure charges it for. Both
    /// phones this is measured on run at a hundred and twenty hertz and were paying for a
    /// boundary they do not have.
    ///
    /// Only ever a credit, never a charge. A panel slower than sixty hertz keeps the measured
    /// figure rather than inflating it, because eighteen milliseconds is what was shown to stop
    /// the display layer dropping frames and nothing here has measured a slower one.
    static func margin(refresh: Double) -> Double {
        max(leastMargin, margin - max(0, sixtyHertz - refresh))
    }

    /// How far past a threshold a reading must be before it is acted on.
    ///
    /// Both directions have one, and for the same reason: the figure being read is a low
    /// quantile of a twenty second window, it moves by a millisecond or two on a link that has
    /// not changed, and a controller with no dead zone spends the call chasing that.
    static let deadband = 0.006

    /// The headroom worth holding: what the display needs, or what the voice needs, whichever is
    /// larger.
    ///
    /// Fixed by the display and by lip sync rather than derived from the delay currently in
    /// force, and that is the whole correction. The previous version aimed the give-back at the
    /// delay itself — hand back only what exceeds what we asked for — which makes the target a
    /// function of the thing being controlled. Measured on two phones, that let the delay and
    /// the measurement drift apart and then locked the drift in place: the frames were waiting
    /// 143ms, the controller had asked for 196ms, and because 143 is less than 196 it concluded
    /// it had nothing to give back. A hundred and nineteen milliseconds past what the display
    /// needed sat there for the rest of the call, with only the two-millisecond trickle below
    /// working on it.
    static func target(floor: Double, ceiling: Double, display: Double = margin) -> Double {
        min(max(floor, display + deadband), ceiling)
    }

    /// One move, or none.
    ///
    /// - Parameters:
    ///   - headroom: How much earlier than its deadline all but the tolerated share of recent
    ///     frames arrived. The measured truth, and the variable being controlled.
    ///   - delay: The delay currently in force.
    ///   - floor: The least delay allowed, which lip sync moves while the call runs.
    ///   - ceiling: The most delay allowed.
    ///   - interval: The frame interval, which bounds how far one widening may move the picture.
    ///   - mayGiveBack: Whether the clock is free to run fast — no catch-up in flight, and long
    ///     enough since the last one.
    ///   - mayTighten: Whether enough time has passed for another millimetre of trickle.
    ///   - display: What the display needs, which is a property of the panel. See
    ///     ``margin(refresh:)``.
    static func adjustment(
        headroom: Double,
        delay: Double,
        floor: Double,
        ceiling: Double,
        interval: Double,
        mayGiveBack: Bool,
        mayTighten: Bool,
        display: Double = margin
    ) -> Adjustment {
        // Raised to meet a floor that moved under it — the voice's buffer grew — rather than
        // waited for, because every other path here only ever moves the delay down.
        if delay < floor - 0.001 {
            return .raiseToTheFloor(min(floor, ceiling))
        }

        // Widened at once and by the whole shortfall, because lateness costs a frame immediately
        // while earliness costs milliseconds nobody may notice. Capped per adjustment so one
        // pathological arrival cannot move the picture a long way at once; repeated adjustments
        // still reach wherever the link requires.
        //
        // Safe to be this abrupt only because the shortfall is read from a low quantile of
        // twenty seconds. A single burst barely moves that, so this fires when the link has
        // genuinely changed rather than when it has hiccuped.
        if headroom < display {
            let widened = min(delay + min(display - headroom, interval * 2), ceiling)
            guard widened > delay + 0.001 else { return .leaveItAlone }
            return .widen(to: widened)
        }

        // Handed back by running the clock fast, because that is the only way to return a large
        // amount of delay without a discontinuity. Walking the grid earlier instead was tried
        // and is worse than the problem: the queue depth falls towards zero, ordinary jitter
        // starts tripping the schedule's own limits, and both legs of a measured call ended up
        // re-anchoring by the thousand and dropping frames by the hundred. A re-anchor puts
        // every frame already queued past its new deadline at once, and measured that cost about
        // four frames each time.
        let target = target(floor: floor, ceiling: ceiling, display: display)
        if headroom > target + deadband, mayGiveBack {
            return .giveBack(seconds: headroom - target, landingOn: target)
        }

        // The trickle, for the moments the clock is not free: a catch-up already in flight, or
        // too soon after the last. On its own it recovers eight milliseconds a second, which is
        // an eighth of what a widening can add in one adjustment — that asymmetry is what let
        // the delay ratchet, and the path above is what closes it.
        //
        // Measured against the same target as the give-back, so the two agree about where rest
        // is. Given its own threshold instead, it settles a couple of milliseconds below where
        // the give-back aims and the pair never quite stop moving — which is only a wobble, but
        // it is a wobble decided by the last digit of a subtraction rather than by anything
        // anyone chose.
        if headroom > target + deadband, mayTighten {
            let reduced = max(delay - min(0.002, headroom - target), floor)
            guard reduced < delay - 0.0001 else { return .leaveItAlone }
            return .tighten(to: reduced)
        }

        return .leaveItAlone
    }

    enum Adjustment: Equatable {
        case leaveItAlone

        /// Move the grid up to meet a floor lip sync raised.
        case raiseToTheFloor(Double)

        /// Move the grid, so future frames are due later. Immediate, and the picture does not move.
        case widen(to: Double)

        /// Run the clock fast until this many seconds of headroom have been consumed, after which
        /// the delay in force is `landingOn` — which is a statement of fact rather than a hope,
        /// since the amount given back was measured against that target.
        case giveBack(seconds: Double, landingOn: Double)

        /// Move the grid down by a trickle.
        case tighten(to: Double)
    }
}
