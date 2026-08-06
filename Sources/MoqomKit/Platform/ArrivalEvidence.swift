// Whether a frame's lateness says anything about the link.
//
// The playout delay is sized from a low quantile of how much headroom recent frames arrived
// with: hold enough that all but `playoutTolerance` of them make their deadline. That is the
// right question to ask of jitter and the wrong one to ask of an interruption, and the numbers
// make the difference stark.
//
// The window is 600 samples and the tolerance is one percent, so the figure being read is the
// sixth-worst arrival of six hundred. At thirty frames a second a two-hundred-millisecond
// delivery pause makes about six frames late — the backlog that arrives at once when delivery
// resumes. So a single pause is, by arithmetic, exactly enough to set the quantile, and 600
// frames at thirty a second is twenty seconds before it leaves the window.
//
// Measured on two phones, that is the whole of the latency that was left. Pauses of 100-200ms
// with no packet loss arrived every fifteen or twenty seconds, so the window never lacked a
// fresh one, and the buffer sat permanently at whatever the worst recent pause demanded — a
// quarter of a second of delay on every frame, bought to cover six frames that had already been
// late by the time it was bought.
//
// The audio path answers this already: a transit step beyond a quarter second is re-anchored
// rather than charged to the link, because it describes the receiver having been away rather
// than the network having changed. This is the same judgement for the picture.
//
// What it deliberately does not do is dismiss ordinary unevenness. A link that delivers in
// bunches a hundred milliseconds apart is not interrupted, it is paced that way, and a buffer
// that refused to size for it would drop frames continuously. Hence a threshold well clear of
// bunching, and a cap on how much can be dismissed in a row.

/// Whether an arrival should size the playout delay.
struct ArrivalEvidence: Sendable, Equatable {
    /// How far past the frame interval a gap has to be before it is a pause rather than
    /// unevenness.
    ///
    /// The same hundred and fifty milliseconds the schedule re-anchors on, and for the same
    /// reason: past this, more has happened than a link being uneven. Below it, a gap is charged
    /// to the link and the buffer grows to cover it, which is correct — covering a hundred
    /// milliseconds of bunching costs a hundred milliseconds and is worth it. Covering a pause
    /// that recurs every twenty seconds costs the same on every frame for the whole call.
    static let aPauseRatherThanUnevenness = 0.150

    /// A gap this fraction of the interval or more means the cadence is back, so the backlog has
    /// drained and arrivals describe the link again.
    static let cadenceRestored = 0.5

    /// The most consecutive arrivals that may be dismissed.
    ///
    /// The safety valve, and the reason this cannot make a bad link look good. If something
    /// about a link produces a permanent stream of what looks like pauses, the delay must still
    /// be sized from it — a controller with no evidence holds whatever it last decided, forever.
    /// A second of frames is far longer than any backlog a pause of this size can produce.
    static let mostDismissedInARow = 30

    /// Pauses noticed. Worth reporting: a call with these and a wide delay is being asked to pay
    /// for interruptions, which is a different complaint from a call on a jittery link.
    private(set) var pauses = 0

    /// Arrivals not charged to the link.
    private(set) var dismissed = 0

    private var recovering = 0

    /// Whether this arrival's headroom should size the delay.
    ///
    /// - Parameters:
    ///   - gap: Seconds since the previous arrival.
    ///   - interval: The frame interval.
    mutating func admits(gap: Double, interval: Double) -> Bool {
        if gap > interval + Self.aPauseRatherThanUnevenness {
            pauses += 1
            recovering = 1
            dismissed += 1
            return false
        }

        guard recovering > 0 else { return true }

        // The backlog: frames queued during the pause, arriving as fast as they can be read.
        // They are late by construction and none of it is the link's doing.
        if gap >= interval * Self.cadenceRestored || recovering >= Self.mostDismissedInARow {
            recovering = 0
            return true
        }

        recovering += 1
        dismissed += 1
        return false
    }

    /// Forget where we are, for a schedule starting over.
    mutating func restart() {
        recovering = 0
    }
}
