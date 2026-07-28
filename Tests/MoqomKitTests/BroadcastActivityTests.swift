import Foundation
import Testing

@testable import MoqomCore
@testable import MoqomKit

private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

private func card(
    phase: BroadcastActivityState.Phase = .live,
    participants: Int = 3,
    speaker: String? = nil,
    recording: Bool = false,
    quality: ConnectionQuality = .good,
    muted: Bool? = nil
) -> BroadcastActivityState {
    BroadcastActivityState(
        phase: phase,
        startedAt: epoch,
        participants: participants,
        speaker: speaker,
        isRecording: recording,
        quality: quality,
        isMuted: muted
    )
}

@Suite("Broadcast activity content")
struct BroadcastActivityStateTests {
    @Test("a count that renders the same is not a change")
    func countsCompareAtDisplayPrecision() {
        // A room of forty thousand redraws "40K" no matter which of the next
        // thousand arrivals is being counted. Sending an update per arrival
        // would spend the entire budget on a card that never changes, and the
        // card then freezes for the rest of the stream.
        #expect(!card(participants: 40_001).differsVisibly(from: card(participants: 40_002)))
        #expect(card(participants: 40_001).differsVisibly(from: card(participants: 51_000)))
    }

    @Test("small rooms count every person")
    func smallRoomsAreExact() {
        // The same rule the other way round: in a room of four, the fourth
        // person arriving is the whole event.
        #expect(card(participants: 3).differsVisibly(from: card(participants: 4)))
    }

    @Test("the speaker, the signal and the recorder are all visible changes")
    func visibleFieldsAreCompared() {
        let base = card()
        #expect(base.differsVisibly(from: card(speaker: "ana")))
        #expect(base.differsVisibly(from: card(quality: .poor)))
        #expect(base.differsVisibly(from: card(recording: true)))
    }

    @Test("only the changes a delay would make wrong demand attention")
    func urgencyIsNarrow() {
        let base = card()

        // A stale speaker name is untidy. A stale mute makes somebody talk into
        // a dead microphone, and a stale recording indicator is a disclosure
        // that did not happen.
        #expect(!card(speaker: "ana").demandsAttention(comparedTo: base))
        #expect(!card(participants: 900).demandsAttention(comparedTo: base))
        #expect(!card(quality: .bad).demandsAttention(comparedTo: base))

        #expect(card(recording: true).demandsAttention(comparedTo: base))
        #expect(card(muted: true).demandsAttention(comparedTo: base))
        #expect(card(phase: .reconnecting).demandsAttention(comparedTo: base))
    }
}

@Suite("Broadcast activity throttle")
struct BroadcastActivityThrottleTests {
    @Test("the first state always goes out")
    func firstStateSends() {
        var throttle = BroadcastActivityThrottle()
        #expect(throttle.consider(card(), at: .seconds(0)) == .send)
        #expect(throttle.showing == card())
    }

    @Test("a state nobody would notice costs nothing")
    func identicalStateIsSkipped() {
        var throttle = BroadcastActivityThrottle()
        _ = throttle.consider(card(), at: .seconds(0))
        #expect(throttle.consider(card(), at: .seconds(10)) == .skip)
    }

    @Test("a routine change inside the interval is owed, not dropped")
    func routineChangeWaits() {
        // The distinction that matters. Dropping it would leave a room where
        // the speaker changes once and then falls silent showing the wrong name
        // for the rest of the broadcast, having declined the only update it was
        // ever going to get.
        var throttle = BroadcastActivityThrottle(interval: .seconds(2))
        _ = throttle.consider(card(), at: .seconds(0))

        #expect(
            throttle.consider(card(speaker: "ana"), at: .milliseconds(500))
                == .wait(.milliseconds(1500))
        )
        #expect(throttle.showing?.speaker == nil)
    }

    @Test("the same change goes out once the interval is up")
    func routineChangeSendsLater() {
        var throttle = BroadcastActivityThrottle(interval: .seconds(2))
        _ = throttle.consider(card(), at: .seconds(0))
        _ = throttle.consider(card(speaker: "ana"), at: .milliseconds(500))

        #expect(throttle.consider(card(speaker: "ana"), at: .seconds(3)) == .send)
        #expect(throttle.showing?.speaker == "ana")
    }

    @Test("a mute the user just pressed does not wait its turn")
    func urgentChangeJumpsTheInterval() {
        // Two seconds of a control that looks like it did nothing is two
        // seconds of the user pressing it again.
        var throttle = BroadcastActivityThrottle(interval: .seconds(2))
        _ = throttle.consider(card(muted: false), at: .seconds(0))

        #expect(throttle.consider(card(muted: true), at: .milliseconds(100)) == .send)
    }

    @Test("the end of a broadcast is never held back")
    func endingIsImmediate() {
        // The card is about to be dismissed, so a held update is one the user
        // never sees at all.
        var throttle = BroadcastActivityThrottle(interval: .seconds(30))
        _ = throttle.consider(card(), at: .seconds(0))

        #expect(throttle.consider(card(phase: .ended), at: .milliseconds(50)) == .send)
    }

    @Test("a burst of speaker changes costs one update")
    func aBurstCoalesces() {
        // Nine people interrupting each other produce several active-speaker
        // transitions a second. Forwarding each one is how an app exhausts its
        // allowance in the first minute of a two-hour stream.
        var throttle = BroadcastActivityThrottle(interval: .seconds(2))
        _ = throttle.consider(card(), at: .seconds(0))

        var sent = 0
        for step in 1 ... 20 {
            let at = MonotonicTime.milliseconds(step * 100)
            if throttle.consider(card(speaker: "user\(step)"), at: at) == .send { sent += 1 }
        }

        #expect(sent == 1)
        #expect(throttle.showing?.speaker == "user20")
    }
}
