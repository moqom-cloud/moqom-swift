// Connecting is waiting, not stalling. A freeze is a session total, so a gap
// that belongs to subscribe / the first keyframe / the tile settling would sit
// on the overlay for the rest of the call. These are the cases that did.

import Foundation
import Testing

@testable import MoqomRoom

@Suite("Cadence meter stalls")
struct CadenceMeterTests {
    @Test("a long gap at connect is not a stall")
    func connectingIsNotAStall() {
        let meter = CadenceMeter()
        meter.restart()
        let start = ContinuousClock.now

        meter.record(at: start)
        meter.record(at: start.advanced(by: .milliseconds(200)), keyFrame: true)
        meter.record(at: start.advanced(by: .milliseconds(216)))

        #expect(meter.reading()?.freezes == 0)
    }

    @Test("a burst then a wait is still connecting, not a stall")
    func aClumpDoesNotArmTheMeter() {
        let meter = CadenceMeter()
        meter.restart()
        let start = ContinuousClock.now

        meter.record(at: start)
        meter.record(at: start.advanced(by: .milliseconds(1)))
        meter.record(at: start.advanced(by: .milliseconds(2)))
        meter.record(at: start.advanced(by: .milliseconds(250)), keyFrame: true)
        meter.record(at: start.advanced(by: .milliseconds(266)))

        #expect(meter.reading()?.freezes == 0)
    }

    @Test("a long gap in the first second of picture is still connecting")
    func aGapBeforeASecondIsNotAStall() {
        let meter = CadenceMeter()
        meter.restart()
        let start = ContinuousClock.now

        meter.record(at: start)
        meter.record(at: start.advanced(by: .milliseconds(16)))
        meter.record(at: start.advanced(by: .milliseconds(700)), keyFrame: true)

        #expect(meter.reading()?.freezes == 0)
    }

    @Test("a long gap a second after the first picture is a stall")
    func aGapOnceSettledIsAStall() {
        let meter = CadenceMeter()
        meter.restart()
        let start = ContinuousClock.now

        meter.record(at: start)
        meter.record(at: start.advanced(by: .milliseconds(16)))
        meter.record(at: start.advanced(by: .seconds(1) + .milliseconds(200)), keyFrame: true)

        #expect(meter.reading()?.freezes == 1)
        #expect(meter.reading()?.onKeyFrame == 1)
    }

    @Test("a new drain does not compare across the wait between streams")
    func restartForgetsTheLastArrival() {
        let meter = CadenceMeter()
        let start = ContinuousClock.now
        meter.record(at: start)
        meter.record(at: start.advanced(by: .milliseconds(16)))

        meter.restart()
        let later = start.advanced(by: .seconds(5))
        meter.record(at: later)
        meter.record(at: later.advanced(by: .milliseconds(16)))

        #expect(meter.reading()?.freezes == 0)
    }
}
