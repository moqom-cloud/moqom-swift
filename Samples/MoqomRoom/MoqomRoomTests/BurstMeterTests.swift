// Most of what a bubble field removes is not a pop.
//
// Bubbles climb out of the shot, and every one still up at the final whistle goes at once, so
// a meter that timed every removal would be quoting the authority's housekeeping — which
// happens on a schedule and which nobody is waiting for — as though it were the thing a
// player feels. On a thirty-second round that is the difference between a figure about the
// network and a figure about the spawn rate. These are the cases that separate them, plus the
// two clocks the timings are taken on and what each is worth when it is unavailable.

import Foundation
import MoqomCore
import MoqomKit
import Testing

@testable import MoqomRoom

@Suite("Burst meter")
struct BurstMeterTests {
    // MARK: - What counts

    @Test("a bubble that vanishes without warning is a burst")
    func aPopIsABurst() {
        let meter = BurstMeter()
        meter.observe(SpaceDelta(), in: field(bubble("b-1")), simulated: at(0), now: at(0))

        meter.observe(
            SpaceDelta(removed: ["b-1"]),
            in: field(),
            simulated: at(100),
            now: at(140)
        )

        #expect(meter.report()?.contains("bursts=1") == true)
    }

    @Test("a bubble flagged as leaving got away, and is not a burst")
    func aDepartureIsNotABurst() {
        let meter = BurstMeter()
        meter.observe(
            SpaceDelta(),
            in: field(bubble("b-1", leaving: true)),
            simulated: at(0),
            now: at(0)
        )

        meter.observe(
            SpaceDelta(removed: ["b-1"]),
            in: field(),
            simulated: at(100),
            now: at(140)
        )

        let report = meter.report()
        #expect(report?.contains("bursts=0") == true)
        #expect(report?.contains("away=1") == true)
    }

    /// The whistle flags every bubble on one tick and removes them on the next, so a whole
    /// field disappearing at once must not read as everybody scoring at once.
    @Test("the final whistle clears the field without bursting any of it")
    func theWhistleIsNotAFlurryOfScoring() {
        let meter = BurstMeter()
        meter.observe(
            SpaceDelta(),
            in: field(bubble("b-1"), bubble("b-2"), bubble("b-3")),
            simulated: at(0),
            now: at(0)
        )
        meter.observe(
            SpaceDelta(),
            in: field(
                bubble("b-1", leaving: true),
                bubble("b-2", leaving: true),
                bubble("b-3", leaving: true)
            ),
            simulated: at(50),
            now: at(60)
        )

        meter.observe(
            SpaceDelta(removed: ["b-1", "b-2", "b-3"]),
            in: field(),
            simulated: at(100),
            now: at(110)
        )

        let report = meter.report()
        #expect(report?.contains("bursts=0") == true)
        #expect(report?.contains("away=3") == true)
    }

    @Test("a removal of something that was never a bubble is not a burst")
    func onlyBubblesCount() {
        let meter = BurstMeter()
        meter.observe(SpaceDelta(), in: field(), simulated: at(0), now: at(0))

        meter.observe(
            SpaceDelta(removed: ["something-else"]),
            in: field(),
            simulated: at(100),
            now: at(140)
        )

        #expect(meter.report() == nil)
    }

    @Test("a run with no field says nothing at all")
    func silentUntilSomethingHappens() {
        #expect(BurstMeter().report() == nil)
    }

    // MARK: - The two clocks

    @Test("the wire figure is the gap between simulating a burst and applying it")
    func wireIsTheArrivalLag() {
        let meter = BurstMeter()
        meter.observe(SpaceDelta(), in: field(bubble("b-1")), simulated: at(0), now: at(0))

        meter.observe(
            SpaceDelta(removed: ["b-1"]),
            in: field(),
            simulated: at(1000),
            now: at(1042)
        )

        #expect(meter.report()?.contains("wire p50=42.0") == true)
    }

    @Test("a pop this device asked for is timed from the asking to the bubble being gone")
    func ownPopIsARoundTrip() {
        let meter = BurstMeter()
        let tapped = ContinuousClock.now
        meter.observe(SpaceDelta(), in: field(bubble("b-1")), simulated: at(0), now: at(0))
        meter.askedFor("b-1", at: tapped)

        meter.observe(
            SpaceDelta(removed: ["b-1"]),
            in: field(),
            simulated: at(100),
            now: at(140),
            arrived: tapped.advanced(by: .milliseconds(180))
        )

        let report = meter.report()
        #expect(report?.contains("mine=1") == true)
        #expect(report?.contains("trip p50=180.0") == true)
    }

    /// The trip is measured on one device's own clock at both ends, so it is the figure that
    /// survives a run where the clocks never agreed. The wire figure is not, and says so.
    @Test("without two clocks worth comparing there is still a trip but no wire figure")
    func anUntrustedClockLosesOnlyTheWireFigure() {
        let meter = BurstMeter()
        let tapped = ContinuousClock.now
        meter.observe(SpaceDelta(), in: field(bubble("b-1")), simulated: .fallback(), now: .fallback())
        meter.askedFor("b-1", at: tapped)

        meter.observe(
            SpaceDelta(removed: ["b-1"]),
            in: field(),
            simulated: .fallback(),
            now: .fallback(),
            arrived: tapped.advanced(by: .milliseconds(90))
        )

        let report = meter.report()
        #expect(report?.contains("bursts=1") == true)
        #expect(report?.contains("trip p50=90.0") == true)
        #expect(report?.contains("wire") == false)
        #expect(report?.contains("untimed=1") == true)
    }

    /// Counted rather than folded in as a zero, which would be indistinguishable from an
    /// arrival so fast the link never managed it.
    @Test("a burst that arrived before it was simulated is reported as the clocks disagreeing")
    func anImpossibleArrivalIsCalledOut() {
        let meter = BurstMeter()
        meter.observe(SpaceDelta(), in: field(bubble("b-1")), simulated: at(0), now: at(0))

        meter.observe(
            SpaceDelta(removed: ["b-1"]),
            in: field(),
            simulated: at(1000),
            now: at(900)
        )

        let report = meter.report()
        #expect(report?.contains("before-they-happened=1") == true)
        #expect(report?.contains("wire") == false)
    }

    // MARK: - Pops that go nowhere

    /// A pop aimed at a bubble that escaped instead. Timing it against whatever removal came
    /// next would invent a round trip nobody made.
    @Test("a pop whose bubble got away is still awaited rather than counted as a trip")
    func aPopThatMissedIsNotATrip() {
        let meter = BurstMeter()
        meter.observe(SpaceDelta(), in: field(bubble("b-1")), simulated: at(0), now: at(0))
        meter.askedFor("b-1")

        meter.observe(
            SpaceDelta(),
            in: field(bubble("b-1", leaving: true)),
            simulated: at(50),
            now: at(60)
        )
        meter.observe(
            SpaceDelta(removed: ["b-1"]),
            in: field(),
            simulated: at(100),
            now: at(120)
        )

        let report = meter.report()
        #expect(report?.contains("bursts=0") == true)
        #expect(report?.contains("away=1") == true)
        #expect(report?.contains("awaiting=1") == true)
    }

    @Test("somebody else's burst is counted without being credited to this device")
    func anotherPhonesPopIsNotMine() {
        let meter = BurstMeter()
        meter.observe(
            SpaceDelta(),
            in: field(bubble("b-1"), bubble("b-2")),
            simulated: at(0),
            now: at(0)
        )
        meter.askedFor("b-1")

        meter.observe(
            SpaceDelta(removed: ["b-2"]),
            in: field(bubble("b-1")),
            simulated: at(100),
            now: at(150)
        )

        let report = meter.report()
        #expect(report?.contains("bursts=1") == true)
        #expect(report?.contains("mine=0") == true)
        #expect(report?.contains("awaiting=1") == true)
    }

    // MARK: - Fixtures

    private func bubble(_ name: String, leaving: Bool = false) -> SpaceEntity {
        SpaceEntity(
            id: SpaceEntityID(name),
            kind: BubbleField.kind,
            facts: leaving ? [BubbleField.leaving: .flag(true)] : [:]
        )
    }

    private func field(_ entities: SpaceEntity...) -> SpaceSnapshot {
        SpaceSnapshot(entities: Dictionary(uniqueKeysWithValues: entities.map { ($0.id, $0) }))
    }

    /// A timecode good enough to subtract from another, at a given millisecond.
    private func at(_ milliseconds: Int64) -> Timecode {
        Timecode(
            nanoseconds: milliseconds * 1_000_000,
            uncertainty: .milliseconds(1),
            trust: .synchronised
        )
    }
}
