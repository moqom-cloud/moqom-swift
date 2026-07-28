// What the Lock Screen says about a broadcast, and how often it is allowed to
// say something new.
//
// The framework part of Live Activities is small. The part that decides whether
// a product ships is the update policy, because ActivityKit budgets updates and
// a broadcast produces changes far faster than any budget allows: a nine-person
// room reassigns the active speaker several times a second, and an app that
// forwards each one exhausts its allowance within the first minute and then
// stops updating for the rest of the stream. The user sees a card frozen on
// whoever happened to be talking when the budget ran out, which is worse than
// having shipped nothing.
//
// Three things keep it inside the budget, in descending order of how much they
// save:
//
//   - The elapsed time is not an update. `Text(timerInterval:)` renders a
//     running clock from a date the card already has, so a broadcast that
//     changes in no other way costs exactly one update for its whole duration.
//     This is the single biggest saving available and it is free.
//   - An update that would not change a pixel is never sent. Not raw equality:
//     ``BroadcastActivityState/differsVisibly(from:)`` compares what is drawn,
//     so a viewer count ticking 1_004 -> 1_005 under a card that reads "1K"
//     costs nothing.
//   - Everything else waits for a minimum interval, except the handful of
//     transitions where a delay would be a lie — recording starting, the stream
//     ending, a mute the user just pressed.
//
// The types here are deliberately free of ActivityKit so the policy can be
// tested on a machine that has no Live Activities. ``BroadcastLiveActivity``
// is the half that talks to the framework.

import Foundation
import MoqomCore

/// What a broadcast's Live Activity is showing.
///
/// Kept to scalars and short strings. ActivityKit caps an update payload at
/// 4 KB and silently drops anything larger, so this is not a place to put a
/// roster.
public struct BroadcastActivityState: Hashable, Sendable, Codable {
    /// Where the broadcast is.
    public enum Phase: String, Hashable, Sendable, Codable {
        /// Everything is working.
        case live

        /// The transport dropped and the SDK is retrying. Distinct from
        /// ``ended`` because it recovers, and a card that said "ended" for the
        /// eight seconds of a lift journey would send the audience away.
        case reconnecting

        /// Over. Nothing moves this back.
        case ended
    }

    public var phase: Phase

    /// When the broadcast started, for the card's own clock.
    ///
    /// A date rather than a duration, and this is the point: give SwiftUI the
    /// date and `Text(timerInterval:)` counts without being told, so a card
    /// showing an elapsed time costs one update rather than one per second.
    /// Storing a formatted duration would turn a free clock into the single
    /// largest consumer of the update budget.
    public var startedAt: Date

    /// How many people are in the room, watchdogs excluded.
    public var participants: Int

    /// Who is talking, if anybody, as a display name.
    public var speaker: String?

    /// Whether a recorder is attached.
    ///
    /// Urgent in both directions. A recording indicator that appears thirty
    /// seconds late has told the user something untrue for thirty seconds, and
    /// in several jurisdictions that is the difference between disclosure and
    /// its absence.
    public var isRecording: Bool

    /// How the connection looks, for the card's signal indicator.
    public var quality: ConnectionQuality

    /// This device's microphone, when the user is broadcasting.
    ///
    /// `nil` for a viewer, which is how the card knows not to draw a mute
    /// control at all.
    public var isMuted: Bool?

    /// This device's camera, when the user is broadcasting.
    public var isCameraOff: Bool?

    public init(
        phase: Phase = .live,
        startedAt: Date,
        participants: Int = 0,
        speaker: String? = nil,
        isRecording: Bool = false,
        quality: ConnectionQuality = .unknown,
        isMuted: Bool? = nil,
        isCameraOff: Bool? = nil
    ) {
        self.phase = phase
        self.startedAt = startedAt
        self.participants = participants
        self.speaker = speaker
        self.isRecording = isRecording
        self.quality = quality
        self.isMuted = isMuted
        self.isCameraOff = isCameraOff
    }

    /// Whether the card would look different.
    ///
    /// Participant counts are compared at the precision a card can show rather
    /// than exactly. A room of four is a room where every arrival matters and
    /// every arrival is drawn; a room of forty thousand is a room where the
    /// card reads "40K" and the next nine hundred and ninety nine arrivals
    /// change nothing on screen while costing the entire update budget.
    public func differsVisibly(from other: Self) -> Bool {
        if phase != other.phase { return true }
        if startedAt != other.startedAt { return true }
        if speaker != other.speaker { return true }
        if isRecording != other.isRecording { return true }
        if quality != other.quality { return true }
        if isMuted != other.isMuted { return true }
        if isCameraOff != other.isCameraOff { return true }
        return Self.bucket(participants) != Self.bucket(other.participants)
    }

    /// Whether the change cannot wait for the throttle's interval.
    ///
    /// The test is not "is this important" but "would a delay make the card
    /// wrong in a way the user would act on". A stale speaker name is untidy; a
    /// stale mute indicator makes somebody keep talking into a muted
    /// microphone, and a stale recording indicator is a disclosure failure.
    public func demandsAttention(comparedTo other: Self) -> Bool {
        phase != other.phase
            || isRecording != other.isRecording
            || isMuted != other.isMuted
            || isCameraOff != other.isCameraOff
    }

    /// The granularity a count is drawn at.
    ///
    /// Exact below a thousand, then thousands, then ten-thousands — the same
    /// steps a card's own abbreviation makes, so two counts in the same bucket
    /// really do render identically.
    static func bucket(_ count: Int) -> Int {
        switch count {
        case ..<1_000: count
        case ..<100_000: count / 1_000
        default: count / 10_000
        }
    }
}

/// Whether a change to the card is worth spending an update on.
///
/// Pure and value-typed so the policy can be exercised without a device: the
/// interesting cases are a burst of speaker changes, a mute in the middle of
/// that burst, and a room that goes quiet with an update still owed.
public struct BroadcastActivityThrottle: Sendable {
    /// What to do with a proposed state.
    public enum Decision: Hashable, Sendable {
        /// Update the activity now.
        case send

        /// Worth showing, but too soon. Ask again after this long.
        ///
        /// A duration rather than a boolean because the owed update has to
        /// actually arrive: a room where the speaker changes once and then
        /// falls silent would otherwise sit on the old name forever, having
        /// declined the only update it was ever going to get.
        case wait(Duration)

        /// Nothing a viewer would notice. Not owed, not scheduled.
        case skip
    }

    /// The shortest gap between routine updates.
    ///
    /// Two seconds is chosen against the Lock Screen rather than against the
    /// budget: the card is a glance surface, and a name that changes faster
    /// than it can be read is noise whatever it costs to send. Products with
    /// the frequent-updates entitlement can lower it; products without one
    /// should not.
    public var interval: Duration

    /// How far ahead to set the card's stale date.
    ///
    /// The system dims the card once this passes, which is the honest
    /// presentation for "this app has stopped being able to tell us anything".
    /// Generous by default, because a broadcast where nothing changes for two
    /// minutes is a normal broadcast and not a dead one — the timer is still
    /// counting and the count is still right.
    public var staleAfter: Duration

    private var last: BroadcastActivityState?
    private var sentAt: MonotonicTime?

    public init(interval: Duration = .seconds(2), staleAfter: Duration = .seconds(120)) {
        self.interval = interval
        self.staleAfter = staleAfter
    }

    /// The state the card is currently showing.
    public var showing: BroadcastActivityState? { last }

    /// Decide what to do with a new state, and record it if the answer is to
    /// send.
    ///
    /// Mutating on purpose. A throttle that answered without remembering would
    /// need every caller to tell it afterwards what they did, and the caller
    /// that forgets produces a throttle that never throttles.
    public mutating func consider(
        _ next: BroadcastActivityState,
        at now: MonotonicTime
    ) -> Decision {
        guard let last, let sentAt else {
            self.last = next
            self.sentAt = now
            return .send
        }

        guard next.differsVisibly(from: last) else { return .skip }

        // The end of a broadcast is never held back, whatever the interval
        // says: the card is about to be dismissed and a held update would be
        // one the user never sees at all.
        if next.phase == .ended || next.demandsAttention(comparedTo: last) {
            self.last = next
            self.sentAt = now
            return .send
        }

        let elapsed = now - sentAt
        guard elapsed >= interval else { return .wait(interval - elapsed) }

        self.last = next
        self.sentAt = now
        return .send
    }
}
