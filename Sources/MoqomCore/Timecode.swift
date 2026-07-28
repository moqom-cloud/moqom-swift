// A position on the one timeline everything can be compared against.
//
// The problem this solves is not "what time is it". It is that a room produces
// events on a dozen machines at once — a kick decided on a phone, a join
// observed by a relay in Frankfurt, a recording segment closed by a worker in
// Iowa — and someone later has to say what happened in what order. Every one of
// those machines has its own clock, and asking each of them for a timestamp
// produces a log that reads like a total order and is not one.
//
// Three decisions follow from that, and they are the whole of this file.
//
// A timecode is an interval, not an instant. A bare number invites a comparison
// the data cannot support: two events a millisecond apart, from devices synced
// to within fifty, are simply not ordered, and a log that renders them as
// ordered has invented the answer. So the uncertainty travels with the value
// and the comparison that respects it is the only comparison offered.
//
// It is never read from the device's wall clock. A phone's clock is a user
// setting; it can be moved to 1999 in the Settings app, and it steps whenever
// the network corrects it. What a client actually holds is a monotonic reading
// — unsettable, and unaffected by correction — plus a measured offset to the
// server. See ``TrustedClock``, which is where the measurement happens.
//
// And a timecode says how much it should be believed. A process that cannot
// reach the reference falls back to its own clock — losing the observation
// entirely would be worse — but it says so, rather than serving a confident
// local guess that everything downstream then treats as fact. A fallback
// timecode is still worth recording, because it is evidence about one machine;
// it is just not evidence about the order of two.
//
// # On leap seconds
//
// The reference is `time.cloudflare.com`, which does not smear: it forwards the
// leap indicator and lets the kernel step, so UTC really does repeat a second.
// The smearing alternative — Google and AWS spread the second over 24 hours —
// keeps the clock continuous at the cost of being knowingly up to half a second
// from UTC for a whole day, undetectably, while every error bound in the system
// continues to read a few milliseconds.
//
// For a design whose entire premise is an honest error bound, that trade is the
// wrong way round. A one-second window that announces itself in advance is
// something this type can represent — see ``TrustedClock``, which widens to ±1s
// across the boundary — and a silent day-long half-second offset is not. The
// usual argument for smearing, that wall-clock time must never go backwards, does
// not apply here: every duration in this system is measured on a monotonic
// clock, never on this one.

import Foundation

/// How much a timecode should be believed.
public enum TimeTrust: String, Hashable, Sendable, Codable, CaseIterable {
    /// Produced by the reference clock itself, disciplined and known good.
    ///
    /// Still carries an uncertainty. Even the authority is only as good as the
    /// time source behind it, and a server that reported zero would be claiming
    /// something no clock can.
    case authoritative

    /// Measured against the authority, and recently enough to still be tight.
    case synchronised

    /// The local system clock, because the reference could not be reached.
    ///
    /// Either synchronisation has never succeeded, or it has gone too stale to
    /// mean anything. The value is still recorded rather than dropped — one
    /// machine's own account of itself is worth having — but it cannot be
    /// placed against another machine's, and
    /// ``Timecode/definitelyPrecedes(_:)`` will not pretend otherwise.
    ///
    /// Named for what it *is* rather than what it is not. "Unsynchronised"
    /// describes a missing property and reads, in a log line, like a warning
    /// somebody forgot to finish; "fallback" says which clock produced the
    /// number, which is the question anyone reading that line is actually
    /// asking.
    case fallback
}

public extension TimeTrust {
    /// The numeric form, for the binary record codec.
    ///
    /// The `String` raw value stays what it is because it is what appears in a
    /// log line and in the admin API's JSON, where a `2` would be unreadable.
    /// But a track carrying one of these per tick cannot spend thirteen bytes on
    /// `"synchronised"`, so the wire uses a number.
    ///
    /// **These values are fixed and shared.** They match `Trust` in
    /// `go/internal/timecode` and in `rs/moqom-relay/src/clock.rs`, where the
    /// same three states are already numbered this way. Fallback is zero on
    /// purpose, in all three: a field nobody set must read as "we do not know"
    /// rather than as a claim of accuracy.
    var wireCode: UInt8 {
        switch self {
        case .fallback: 0
        case .synchronised: 1
        case .authoritative: 2
        }
    }

    /// Read a trust level from the wire.
    ///
    /// An unrecognised code is ``TimeTrust/fallback`` rather than an error. A
    /// future peer that learns a fourth kind of clock should leave older readers
    /// treating its timestamps as unverifiable — which is what fallback means —
    /// instead of making them drop the object entirely.
    init(wireCode: UInt8) {
        switch wireCode {
        case 1: self = .synchronised
        case 2: self = .authoritative
        default: self = .fallback
        }
    }
}

/// An instant on the trusted timeline, with the width of what is actually known.
///
/// ```swift
/// let kick = await clock.now()
/// let message = await clock.now()
/// if kick.definitelyPrecedes(message) {
///     // Safe to state as fact in an audit log.
/// }
/// ```
public struct Timecode: Hashable, Sendable, Codable {
    /// The best estimate, in nanoseconds since the Unix epoch, UTC.
    ///
    /// An integer count rather than a formatted string, and nanoseconds rather
    /// than seconds, because this is the one value in the system whose whole
    /// purpose is precision: a `Double` of seconds runs out of significant
    /// digits around microseconds at present-day epochs, and a formatted
    /// timestamp costs a lossy parse at both ends. A reader wanting something
    /// human divides by a billion.
    public let nanoseconds: Int64

    /// Half the width of the interval the true instant lies in.
    ///
    /// The value is `nanoseconds ± uncertainty`. Zero is not a value any real
    /// clock produces and nothing here generates it.
    public let uncertainty: Duration

    public let trust: TimeTrust

    public init(nanoseconds: Int64, uncertainty: Duration, trust: TimeTrust) {
        self.nanoseconds = nanoseconds
        // Negative uncertainty is nonsense that would silently invert every
        // comparison below, turning "cannot tell" into a confident wrong answer.
        self.uncertainty = uncertainty < .zero ? .zero : uncertainty
        self.trust = trust
    }

    /// The earliest instant this could be, in nanoseconds since the epoch.
    public var earliest: Int64 { nanoseconds &- uncertainty.wholeNanoseconds }

    /// The latest instant this could be, in nanoseconds since the epoch.
    public var latest: Int64 { nanoseconds &+ uncertainty.wholeNanoseconds }

    /// The estimate as a `Date`, for display.
    ///
    /// Lossy below microseconds, because `Date` is a `Double` of seconds. Fine
    /// for showing a person; never round-trip a timecode through it.
    public var date: Date {
        Date(timeIntervalSince1970: Double(nanoseconds) / 1_000_000_000)
    }

    /// Whether this provably happened before `other`.
    ///
    /// The only ordering worth stating as fact, and it is deliberately strict:
    /// it is true when the two intervals do not overlap, and false when they do
    /// — including when the estimates differ. Two events a millisecond apart on
    /// devices synced to fifty are not ordered, and this returns `false` in both
    /// directions, which is the honest answer rather than a missing one.
    ///
    /// Requires both to be trusted. A fallback timecode is one machine's
    /// opinion of itself and there is nothing to place it against.
    ///
    /// > Note: For events from a *single* source, use that source's sequence
    /// > number instead — the room control log and the control plane's event
    /// > stream both carry one. Sequence orders within a source and is exact;
    /// > timecode orders across sources and is not. Reaching for a timecode to
    /// > order two entries in the same log throws away a certainty you had.
    public func definitelyPrecedes(_ other: Timecode) -> Bool {
        guard isTrusted, other.isTrusted else { return false }
        return latest < other.earliest
    }

    /// Whether these two could be the same instant.
    ///
    /// True when the intervals overlap, and true whenever either is a
    /// fallback, since there is then no basis for ruling it out.
    public func mayCoincide(with other: Timecode) -> Bool {
        guard isTrusted, other.isTrusted else { return true }
        return earliest <= other.latest && other.earliest <= latest
    }

    /// Whether this can be compared with another machine's.
    public var isTrusted: Bool { trust != .fallback }

    /// The same estimate, known less precisely.
    ///
    /// For carrying a timecode across something that adds doubt: a clock left
    /// to drift between syncs, a value relayed by a process with its own error.
    /// Uncertainty only ever grows this way, which is the point — there is no
    /// operation here that makes a timecode more certain than it was measured.
    public func widened(by extra: Duration) -> Timecode {
        Timecode(
            nanoseconds: nanoseconds,
            uncertainty: uncertainty + extra,
            trust: trust
        )
    }

    /// Shift the estimate, keeping the uncertainty.
    ///
    /// The offset is treated as exact, because the cases that need this — "one
    /// packet duration later", "the start of the segment" — are counted rather
    /// than measured.
    public func advanced(by interval: Duration) -> Timecode {
        Timecode(
            nanoseconds: nanoseconds &+ interval.wholeNanoseconds,
            uncertainty: uncertainty,
            trust: trust
        )
    }

    /// The local system clock, for when the reference cannot be reached.
    ///
    /// The deliberate fallback, and it is deliberate: the alternative — refusing
    /// to produce a timestamp at all — loses the one piece of evidence that is
    /// still available, which is this machine's own account of when something
    /// happened. What must not happen is that the fallback is *mistaken* for
    /// measured time, so it is marked ``TimeTrust/fallback`` and given a
    /// deliberately enormous uncertainty rather than a plausible one. A device
    /// clock is a user setting and can be wrong by years; a bound implying
    /// otherwise would be the lie this type exists to stop.
    public static func fallback(_ date: Date = Date()) -> Timecode {
        Timecode(
            nanoseconds: Int64(date.timeIntervalSince1970 * 1_000_000_000),
            uncertainty: .seconds(86400),
            trust: .fallback
        )
    }

    // MARK: - Wire form

    // Spelled out rather than synthesised because `Duration`'s own `Codable`
    // encodes as a pair of internal component integers — correct, opaque, and
    // no use to the third parties this format exists for. Nanoseconds is what
    // the rest of the document uses.
    private enum CodingKeys: String, CodingKey {
        case nanoseconds = "at"
        case uncertainty = "plusMinusNs"
        case trust
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nanoseconds = try container.decode(Int64.self, forKey: .nanoseconds)
        uncertainty = .nanoseconds(try container.decode(Int64.self, forKey: .uncertainty))

        // An absent trust is the unsafe reading, so it is the one taken. A
        // document from something that did not know about this field has not
        // told us its clock is good.
        trust = try container.decodeIfPresent(TimeTrust.self, forKey: .trust) ?? .fallback
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(nanoseconds, forKey: .nanoseconds)
        try container.encode(uncertainty.wholeNanoseconds, forKey: .uncertainty)
        try container.encode(trust, forKey: .trust)
    }
}

extension Timecode: CustomStringConvertible {
    /// Renders the uncertainty too, because a timecode printed without it is
    /// the thing this type exists to prevent appearing in a log.
    public var description: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: date)
        let plusMinus = Double(uncertainty.wholeNanoseconds) / 1_000_000
        return switch trust {
        case .fallback: "\(stamp) (fallback clock)"
        default: String(format: "%@ ±%.1fms", stamp, plusMinus)
        }
    }
}

public extension Duration {
    /// Whole nanoseconds, saturating rather than trapping.
    ///
    /// `Duration` counts attoseconds in a 128-bit value and can hold spans no
    /// clock will ever produce; the conversion is here so that the arithmetic
    /// above never has to think about it.
    var wholeNanoseconds: Int64 {
        let (seconds, attoseconds) = components
        let fromSeconds = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !fromSeconds.overflow else { return seconds > 0 ? .max : .min }
        let total = fromSeconds.partialValue.addingReportingOverflow(attoseconds / 1_000_000_000)
        return total.overflow ? (seconds > 0 ? .max : .min) : total.partialValue
    }
}
