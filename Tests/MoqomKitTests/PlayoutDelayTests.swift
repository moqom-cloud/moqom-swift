// How much delay the picture is held for, and whether the loop that chooses it settles.
//
// The renderer needs a display layer and a timebase, so none of this was reachable from a test
// until the decision was separated from the doing of it. What made that worth doing is that the
// loop has been wrong twice, in the same direction, and neither time was visible in anything but
// a two-phone bench: the delay climbs, nothing errors, every counter reads healthy, and the call
// is simply further behind than it was a minute ago.
//
// So the link here is a model rather than a mock. Frames arrive with some headroom; moving the
// grid moves that headroom by the same amount; running the clock fast consumes it; and
// re-anchoring places the grid by whatever delay the controller currently believes in. That last
// one is the mechanism that turned a transient into a permanent cost, so it is the one most
// worth being able to run a hundred times.

import Foundation
import Testing

@testable import MoqomKit

@Suite("The adaptive playout delay")
struct PlayoutDelayTests {
    /// A link, a schedule, and the loop that adjusts one against the other.
    ///
    /// `headroom` is what the controller measures; `delay` is what it believes it has asked for.
    /// The two are separate on purpose, because their drifting apart is the fault being tested.
    private struct Link {
        var delay: Double
        var headroom: Double
        var floor = 0.0
        var ceiling = 0.25
        var interval = 1.0 / 30

        /// Seconds since the run began, advanced one decision at a time.
        var now = 0.0

        /// When the clock currently running fast stops, and where that leaves the delay.
        var catchUpEnds: Double?
        var catchUpGive = 0.0
        var catchUpLanding = 0.0
        var lastGiveBack = -100.0
        var lastTighten = -100.0

        var widenings = 0
        var giveBacks = 0

        /// One decision, a second apart, which is how often the renderer reconsiders at 30fps.
        mutating func tick(jitter: Double = 0) {
            now += 1

            if let ends = catchUpEnds, now >= ends {
                headroom -= catchUpGive
                delay = catchUpLanding
                catchUpEnds = nil
                lastGiveBack = now
            }

            headroom += jitter

            // Nothing is measured while the clock is running fast, so nothing is decided either.
            guard catchUpEnds == nil else { return }

            let move = PlayoutDelay.adjustment(
                headroom: headroom,
                delay: delay,
                floor: floor,
                ceiling: ceiling,
                interval: interval,
                mayGiveBack: now - lastGiveBack > 1.5,
                mayTighten: now - lastTighten > 0.25
            )

            switch move {
            case .leaveItAlone:
                break
            case let .raiseToTheFloor(raised):
                headroom += raised - delay
                delay = raised
            case let .widen(widened):
                widenings += 1
                headroom += widened - delay
                delay = widened
            case let .giveBack(give, landing):
                giveBacks += 1
                let rate = min(1.06, max(1.02, 1 + give))
                catchUpEnds = now + give / (rate - 1)
                catchUpGive = give
                catchUpLanding = landing
            case let .tighten(reduced):
                lastTighten = now
                headroom += reduced - delay
                delay = reduced
            }
        }

        /// Put the grid where a re-anchor would put it.
        ///
        /// The anchoring frame is given exactly the delay in force, and every frame after it is
        /// early or late by however much its own arrival differs from that one's. So a schedule
        /// anchored on a frame that was unusually delayed keeps that frame's bad luck for the
        /// rest of the call — which is why the delay the controller believes in has to be true.
        mutating func reAnchor(onAFrameLateBy error: Double = 0) {
            headroom = delay + error
        }

        mutating func run(seconds: Int, jitter: Double = 0) {
            for _ in 0 ..< seconds { tick(jitter: jitter) }
        }
    }

    private var target: Double { PlayoutDelay.margin + PlayoutDelay.deadband }

    @Test("the delay a link no longer needs is handed back")
    func excessComesBack() {
        // The measured failure exactly: frames waiting 143ms while the controller believed it
        // had asked for 196, which is 119ms past anything the display needs.
        var link = Link(delay: 0.196, headroom: 0.143)
        link.run(seconds: 20)

        #expect(link.headroom < target + 0.01)
        #expect(link.delay < target + 0.01)
    }

    @Test("what the controller believes matches what the frames experience")
    func beliefFollowsMeasurement() {
        var link = Link(delay: 0.196, headroom: 0.143)
        link.run(seconds: 20)

        // The two must agree, or the next re-anchor spends the difference again.
        #expect(abs(link.delay - link.headroom) < 0.01)
    }

    @Test("a re-anchor after a give-back does not spend the old delay")
    func aReAnchorKeepsTheGain() {
        var link = Link(delay: 0.196, headroom: 0.143)
        link.run(seconds: 20)
        link.reAnchor()

        #expect(link.headroom < target + 0.01)
    }

    @Test("frames arriving late are covered at once")
    func latenessIsCoveredImmediately() {
        var link = Link(delay: 0.03, headroom: 0.03)
        link.headroom = 0.002
        link.tick()

        #expect(link.headroom > 0.015)
        #expect(link.widenings == 1)
    }

    @Test("a burst every eight seconds does not ratchet the delay")
    func repeatedBurstsDoNotRatchet() {
        // What a host changing layout does to a viewer: a keyframe, a handful of late frames, a
        // re-anchor, and then a quiet stretch — over and over. On two phones this took a
        // viewer's buffer from forty milliseconds to nearly two hundred and kept it there.
        //
        // A guard rather than a reproduction, and worth being clear about which: run against
        // the loop this replaced, this pattern passes. What the old loop actually failed is
        // ``excessComesBack``, where the delay and the measurement have already come apart —
        // there it stayed 53ms adrift and gave back two milliseconds a second. So this one says
        // the new loop does not find a *new* way to climb, and that one says the old fault is
        // fixed.
        //
        // The anchoring frame is late on some rounds and early on others, because the sign is
        // what decides whether the old gate could see the excess at all: anchor on a late frame
        // and the frames after it have headroom to spare, anchor on an early one and they have
        // less headroom than the delay claims.
        var link = Link(delay: target, headroom: target)

        for round in 0 ..< 8 {
            link.tick(jitter: -0.03)
            link.reAnchor(onAFrameLateBy: round.isMultiple(of: 2) ? 0.04 : -0.02)
            link.run(seconds: 7)
        }

        #expect(link.delay < 0.08, "the delay reached \(Int(link.delay * 1000))ms")
        #expect(link.headroom < 0.08)
    }

    @Test("a link that genuinely needs more delay keeps it")
    func aJitteryLinkIsNotStarved() {
        // The opposite failure, and the reason the give-back cannot simply be fast: a link whose
        // arrivals really do spread must be allowed to hold the delay that covers them.
        var link = Link(delay: target, headroom: target)

        for _ in 0 ..< 30 {
            link.tick(jitter: -0.05)
            link.run(seconds: 1)
        }

        #expect(link.delay > 0.05)
    }

    @Test("lip sync's floor is never given away")
    func theFloorHolds() {
        var link = Link(delay: 0.196, headroom: 0.196, floor: 0.12)
        link.run(seconds: 30)

        #expect(link.delay >= 0.12 - 0.001)
        #expect(link.headroom >= 0.12 - 0.01)
    }

    @Test("the ceiling bounds what a bad link can ask for")
    func theCeilingHolds() {
        var link = Link(delay: 0.03, headroom: 0.03, ceiling: 0.15)

        for _ in 0 ..< 60 { link.tick(jitter: -0.05) }

        #expect(link.delay <= 0.15 + 0.001)
    }

    @Test("a delay already where it belongs is left alone")
    func restIsRest() {
        let move = PlayoutDelay.adjustment(
            headroom: target,
            delay: target,
            floor: 0,
            ceiling: 0.25,
            interval: 1.0 / 30,
            mayGiveBack: true,
            mayTighten: true
        )

        #expect(move == .leaveItAlone)
    }

    @Test("a floor that moves under the delay raises it")
    func theFloorRaises() {
        let move = PlayoutDelay.adjustment(
            headroom: 0.03,
            delay: 0.03,
            floor: 0.1,
            ceiling: 0.25,
            interval: 1.0 / 30,
            mayGiveBack: true,
            mayTighten: true
        )

        #expect(move == .raiseToTheFloor(0.1))
    }

    @Test("the trickle still runs when the clock is not free")
    func theTrickleCoversTheGaps() {
        let move = PlayoutDelay.adjustment(
            headroom: 0.1,
            delay: 0.1,
            floor: 0,
            ceiling: 0.25,
            interval: 1.0 / 30,
            mayGiveBack: false,
            mayTighten: true
        )

        #expect(move == .tighten(to: 0.098))
    }

    @Test("a sixty hertz panel is charged what was measured on one")
    func sixtyHertzIsUnchanged() {
        #expect(PlayoutDelay.margin(refresh: PlayoutDelay.sixtyHertz) == PlayoutDelay.margin)
    }

    @Test("a faster panel keeps the refresh it does not wait for")
    func aFasterPanelPaysLess() {
        let fast = PlayoutDelay.margin(refresh: 1.0 / 120)
        #expect(fast < PlayoutDelay.margin)
        #expect(fast >= PlayoutDelay.leastMargin)
    }

    /// The credit stops while there is still room for a decode beside the refresh, because the
    /// failure it guards against is a third of the picture rather than a few milliseconds.
    @Test("the credit stops at a margin that still covers a refresh and a decode")
    func theCreditHasAFloor() {
        #expect(PlayoutDelay.margin(refresh: 1.0 / 240) == PlayoutDelay.leastMargin)
        #expect(PlayoutDelay.margin(refresh: 0) == PlayoutDelay.leastMargin)
        #expect(PlayoutDelay.leastMargin > 1.0 / 120)
    }

    @Test("a slower panel is not charged more than what was measured")
    func aSlowerPanelIsNotPunished() {
        #expect(PlayoutDelay.margin(refresh: 1.0 / 30) == PlayoutDelay.margin)
    }

    /// A hold inside the ceiling is not something to correct, and the deadband is what stops the
    /// grid being nudged by the last digit of a median.
    @Test("a hold within the ceiling is left alone")
    func nothingToHandBack() {
        #expect(PlayoutDelay.ceilingCorrection(hold: 0.020, ceiling: 0.020, interval: 1.0 / 60)
            == nil)
        #expect(PlayoutDelay.ceilingCorrection(hold: 0.024, ceiling: 0.020, interval: 1.0 / 60)
            == nil)
    }

    /// An excess above the ceiling is handed back in full, because with lip sync holding the floor
    /// at the ceiling this is the only thing left that can enforce it.
    @Test("an excess above the ceiling is handed back")
    func handsBackTheExcess() {
        let correction = PlayoutDelay.ceilingCorrection(
            hold: 0.030,
            ceiling: 0.020,
            interval: 1.0 / 60
        )
        #expect(correction.map { abs($0 - 0.010) < 1e-9 } == true)
    }

    /// The cap survives, because a large excess arriving as one jump is a visible lurch whatever
    /// the gain says.
    @Test("no single pass moves the picture more than a frame")
    func neverMoreThanAFrame() {
        let interval = 1.0 / 60
        #expect(PlayoutDelay.ceilingCorrection(hold: 2.0, ceiling: 0.020, interval: interval)
            == interval)
    }

    /// The point of the whole exercise: on a faster panel the delay settles lower, because the
    /// target it is aiming at is what the display needs and the display needs less.
    @Test("a faster panel settles the delay lower")
    func aFasterPanelSettlesLower() {
        let slow = PlayoutDelay.target(floor: 0, ceiling: 0.25, display: PlayoutDelay.margin)
        let fast = PlayoutDelay.target(
            floor: 0,
            ceiling: 0.25,
            display: PlayoutDelay.margin(refresh: 1.0 / 120)
        )
        #expect(fast < slow)
    }

    /// One late frame, which is what a step used to cost a lurch for.
    @Test("a momentary undershoot is left to the rate")
    func ridesOutOneLateFrame() {
        #expect(
            !PlayoutDelay.needsAnchoring(depth: -0.023, allowance: 0.02, straying: 0.1),
            "a frame arriving late is not a lost stream"
        )
    }

    @Test("an undershoot the rate has not answered is stepped")
    func stepsWhenTheRateHasHadItsChance() {
        #expect(PlayoutDelay.needsAnchoring(depth: -0.023, allowance: 0.02, straying: 1.0))
    }

    /// Far enough out that waiting costs more than the step does.
    @Test("a stall is stepped at once rather than ridden")
    func doesNotRideOutAStall() {
        #expect(PlayoutDelay.needsAnchoring(depth: -0.5, allowance: 0.02, straying: 0.01))
    }

    @Test("a schedule with frames in hand is left alone")
    func leavesAHealthyScheduleAlone() {
        #expect(!PlayoutDelay.needsAnchoring(depth: 0.018, allowance: 0.02, straying: nil))
        #expect(!PlayoutDelay.needsAnchoring(depth: -0.01, allowance: 0.02, straying: nil))
    }
}
