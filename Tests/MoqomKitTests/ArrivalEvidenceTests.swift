import Testing

@testable import MoqomKit

/// Which arrivals should size the playout delay.
@Suite("Arrival evidence")
struct ArrivalEvidenceTests {
    private static let interval = 1.0 / 30

    /// An even feed at the frame interval, returning how much of it counted as evidence.
    private func evenly(_ evidence: inout ArrivalEvidence, frames: Int) -> Int {
        var admitted = 0
        for _ in 0 ..< frames {
            let counts = evidence.admits(gap: Self.interval, interval: Self.interval)
            if counts { admitted += 1 }
        }
        return admitted
    }

    @Test("an even feed is all evidence")
    func evenArrivalsAllCount() {
        var evidence = ArrivalEvidence()
        let admitted = evenly(&evidence, frames: 300)
        #expect(admitted == 300)
        #expect(evidence.pauses == 0)
        #expect(evidence.dismissed == 0)
    }

    @Test("a pause and the backlog behind it are not charged to the link")
    func aPauseAndItsBacklogAreDismissed() {
        // The measured case: 200ms of nothing, then the frames that queued up arriving as fast
        // as they can be read. All of them are late, and none of it is the link being uneven.
        var evidence = ArrivalEvidence()
        _ = evenly(&evidence, frames: 300)

        let thePause = evidence.admits(gap: 0.200, interval: Self.interval)
        #expect(!thePause)

        var backlogAdmitted = 0
        for _ in 0 ..< 5 {
            let counts = evidence.admits(gap: 0.001, interval: Self.interval)
            if counts { backlogAdmitted += 1 }
        }
        #expect(backlogAdmitted == 0)
        #expect(evidence.pauses == 1)
        #expect(evidence.dismissed == 6)

        // And once the cadence is back, arrivals describe the link again.
        let recovered = evidence.admits(gap: Self.interval, interval: Self.interval)
        #expect(recovered)
        #expect(evidence.dismissed == 6)
    }

    @Test("ordinary unevenness is still the link's, and still sized for")
    func burstinessIsNotAnInterruption() {
        // The property that keeps this from making a bad link look good. A link delivering in
        // bunches a hundred milliseconds apart is not interrupted, it is paced that way, and a
        // buffer that refused to cover it would drop frames continuously.
        var evidence = ArrivalEvidence()
        var admitted = 0
        for _ in 0 ..< 50 {
            let leading = evidence.admits(gap: 0.100, interval: Self.interval)
            if leading { admitted += 1 }
            for _ in 0 ..< 2 {
                let within = evidence.admits(gap: 0.001, interval: Self.interval)
                if within { admitted += 1 }
            }
        }

        #expect(evidence.pauses == 0)
        #expect(admitted == 150)
    }

    @Test("a link that looks like nothing but pauses is still sized for")
    func evidenceIsNeverExhausted() {
        // The safety valve. A controller with no evidence holds whatever it last decided for the
        // rest of the call, so dismissing everything is the one outcome worse than sizing for an
        // interruption.
        var evidence = ArrivalEvidence()
        var admitted = 0
        for _ in 0 ..< 200 {
            let counts = evidence.admits(gap: 0.001, interval: Self.interval)
            if counts { admitted += 1 }
        }
        #expect(admitted > 0)
    }

    @Test("a pause is one pause, however long the backlog")
    func theCapBoundsOneRecovery() {
        var evidence = ArrivalEvidence()
        let thePause = evidence.admits(gap: 0.500, interval: Self.interval)
        #expect(!thePause)

        // Far more consecutive fast arrivals than any real backlog.
        var admitted = 0
        for _ in 0 ..< 100 {
            let counts = evidence.admits(gap: 0.001, interval: Self.interval)
            if counts { admitted += 1 }
        }
        #expect(evidence.pauses == 1)
        #expect(admitted > 0)
        #expect(evidence.dismissed <= ArrivalEvidence.mostDismissedInARow + 1)
    }

    @Test("a gap just short of a pause is unevenness")
    func theThresholdIsWhereItSays() {
        var evidence = ArrivalEvidence()
        let interval = Self.interval
        let short = evidence.admits(
            gap: interval + ArrivalEvidence.aPauseRatherThanUnevenness - 0.001,
            interval: interval
        )
        #expect(short)
        let long = evidence.admits(
            gap: interval + ArrivalEvidence.aPauseRatherThanUnevenness + 0.001,
            interval: interval
        )
        #expect(!long)
    }

    @Test("a stream starting over is not a pause")
    func restartingForgetsTheRecovery() {
        var evidence = ArrivalEvidence()
        let thePause = evidence.admits(gap: 0.300, interval: Self.interval)
        #expect(!thePause)

        // Mid-recovery before the restart; afterwards the next arrival is ordinary again.
        evidence.restart()
        let afterwards = evidence.admits(gap: 0.001, interval: Self.interval)
        #expect(afterwards)
    }
}
