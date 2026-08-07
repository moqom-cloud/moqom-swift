import Testing

@testable import MoqomKit

/// What the player does with a queue deeper than it needs to be.
@Suite("Trim")
struct TrimTests {
    private static let target = Duration.milliseconds(60)

    private func decide(
        queued: Duration,
        quiet: Int = 0,
        silent: Bool = false
    ) -> Trim.Move {
        Trim.decide(queued: queued, target: Self.target, quiet: quiet, silent: silent)
    }

    @Test("a queue at its target is left alone")
    func atTargetNothingHappens() {
        #expect(decide(queued: Self.target) == .play)
        #expect(decide(queued: Self.target, quiet: 100, silent: true) == .play)
    }

    @Test("the cushion above target survives any amount of quiet")
    func theCushionIsNeverTrimmedAway() {
        // The property that makes trimming in a short gap safe: however long the quiet runs, the
        // rule stops here, so it can never be what empties the queue and starves the next word.
        let held = Self.target + Trim.cushion
        for quiet in 0 ... 500 {
            #expect(decide(queued: held, quiet: quiet, silent: true) == .play)
        }
    }

    @Test("a backlog comes down in the gap between two words")
    func aBacklogDrainsDuringSpeech() {
        // The measured failure. A delivery pause hands over its backlog at once, and the queue
        // then carried it as standing latency because the only way down needed half a second of
        // continuous quiet — which a conversation may not offer for a minute.
        let backlog = Self.target + .milliseconds(200)
        #expect(decide(queued: backlog, quiet: Trim.aGapBetweenWords, silent: true) == .dropSilence)
    }

    @Test("an ordinary cushion still waits for a settled quiet")
    func aCushionIsNotABacklog() {
        // Just above the cushion but not a backlog: the conservative rule still applies, so a
        // queue doing its job is not whittled at in every pause between words.
        let modest = Self.target + Trim.cushion + .milliseconds(10)
        #expect(decide(queued: modest, quiet: Trim.aGapBetweenWords, silent: true) == .play)
        #expect(decide(queued: modest, quiet: Trim.settledQuiet, silent: true) == .dropSilence)
    }

    @Test("speech is never removed to trim a cushion")
    func speechSurvivesTheTrim() {
        let backlog = Self.target + .milliseconds(100)
        #expect(decide(queued: backlog, quiet: 0, silent: false) == .play)
    }

    @Test("past arguing, the excess goes even if it is speech")
    func speechGoesWhenTheQueueIsAbsurd() {
        let absurd = Self.target + Trim.pastArguing + .milliseconds(1)
        #expect(decide(queued: absurd, quiet: 0, silent: false) == .dropSpeech)
    }

    @Test("a backlog drains away during speech and stops being one")
    func drainingSettlesWhereItStopsBeingABacklog() {
        // The loop the player runs, with silence arriving in ordinary gaps. It must come down,
        // and it must stop in the right place rather than running the queue dry.
        //
        // Where it stops is the two tiers meeting, and is the intended shape: the eager rule
        // takes the queue down to where it is no longer a backlog and then hands over to the
        // conservative one, which waits for a settled quiet for the rest. So an excursion is
        // undone during the conversation and the remaining cushion is only ever given up when
        // giving it up is free.
        var queued = Self.target + .milliseconds(300)
        var quiet = 0
        var trimmed = 0

        for packet in 0 ..< 2000 {
            // Speech with a two-packet gap every ten, which is an ordinary sentence.
            let silent = packet % 10 >= 8
            quiet = silent ? quiet + 1 : 0

            switch Trim.decide(queued: queued, target: Self.target, quiet: quiet, silent: silent) {
            case .dropSilence, .dropSpeech:
                trimmed += 1
                queued -= .milliseconds(20)
            case .play:
                break
            }
        }

        // 300ms of backlog gone, down to the tier boundary and no further.
        #expect(trimmed > 0)
        #expect(queued <= Self.target + Trim.backlog + .milliseconds(20))
        #expect(queued >= Self.target + Trim.cushion)
    }
}
