// What to do with a packet when the queue is deeper than it needs to be.
//
// Separated from the player for the reason ``PlayoutDelay`` is: it is a decision with no engine,
// no ring and no clock in it, so it can be asked the question directly instead of through an
// audio device.
//
// The queue exists to cover jitter, and everything it holds beyond that is latency. Getting the
// depth back down is harder than getting it up, because up is free — a packet arrives and is
// kept — while down means removing audio somebody was going to hear. So the rules are about
// finding the moments where removal costs nothing, and there are more of them than the first
// version assumed.

/// What to do with the packet at the head of the queue.
enum Trim: Sendable {
    /// Kept above the target rather than at it, because a queue held exactly at target is a queue
    /// one late packet away from a hole, and the trimming is what would have put it there.
    static let cushion = Duration.milliseconds(20)

    /// Past this much above target, what is being held is a backlog rather than a cushion.
    ///
    /// The distinction is what the settled-quiet rule below cannot make on its own. A delivery
    /// pause hands over everything that queued behind it at once — measured on a phone, arrival
    /// gaps of 358ms, 386ms and 641ms with no packet loss — and from then on the queue carries it
    /// as standing latency, which the picture then matches for lip sync.
    static let backlog = Duration.milliseconds(60)

    /// Quiet packets before an ordinary cushion may be trimmed. Half a second, which is past the
    /// end of a sentence rather than the gap between two words.
    static let settledQuiet = 25

    /// Quiet packets before a backlog may be trimmed.
    ///
    /// A gap between words, and there are several in every sentence. Safe at this length for a
    /// reason that applies at any length: what is removed is a packet already carrying silence,
    /// and ``cushion`` bounds how far the removing can go, so this can never be the thing that
    /// empties the queue. The half second above was protecting the cushion against a rule that
    /// already could not reach it, and the cost of the protection was a dead zone between here
    /// and ``pastArguing`` where the only way down was to stop talking.
    static let aGapBetweenWords = 2

    /// Past this much above target, the excess goes even if it is speech. Losing a packet is
    /// audible; losing the argument with the delay is audible for the rest of the call.
    static let pastArguing = Duration.milliseconds(200)

    enum Move: Sendable, Equatable {
        case play
        /// Inaudible: the packet was silence.
        case dropSilence
        /// Audible, and should be rare. A number that climbs means the queue is fed faster than
        /// the device drains it for longer than a burst, which is a clock difference.
        case dropSpeech
    }

    /// One decision.
    ///
    /// - Parameters:
    ///   - queued: What is in the ring now.
    ///   - target: The depth the link and the device justify.
    ///   - quiet: Consecutive silent packets up to and including this one.
    ///   - silent: Whether this packet is silence.
    static func decide(queued: Duration, target: Duration, quiet: Int, silent: Bool) -> Move {
        if silent, queued > target + cushion {
            let enough = queued > target + backlog ? aGapBetweenWords : settledQuiet
            if quiet >= enough { return .dropSilence }
        }
        if queued > target + pastArguing { return .dropSpeech }
        return .play
    }
}
