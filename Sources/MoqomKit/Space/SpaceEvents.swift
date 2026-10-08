// Things that happen in a shared space, as distinct from what it contains.
//
// State is forgiving. A tick that arrives late is worthless and is dropped, a
// tick that is lost is repaired by the next one, and a renderer never notices
// either because every value is absolute. A game also has moments — a goal, a
// pop, a turn passing — and those are not forgiving at all. Lose one and the
// crowd never cheers; deliver it twice and the score animates twice; deliver two
// out of order and the replay shows the save before the shot.
//
// So the moments travel on the same track as the state but under the opposite
// rules, the ones the room control log uses: numbered by the authority, held
// until the gap before them fills, and delivered exactly once each.
//
// # How a lost moment comes back
//
// Each event is numbered within an epoch, from 1. Every delta repeats the events
// of its group so far (up to ``SpaceSession/Configuration/eventRedundancy``), so
// a delta lost in the middle of a group is made good by the next one. Every
// snapshot carries the most recent events of the epoch (up to
// ``SpaceSession/Configuration/eventRetention``) and the number of the last one,
// so a client that lost a whole group, or the connection, catches up at the next
// group boundary — the same boundary at which its state heals. Re-reading an
// event already delivered is inert, because the reader keeps a high-water mark.
//
// The one thing that cannot be made good is an event older than the retention
// window. The reader says so — ``SpaceSession/Event/eventsMissed(epoch:sequences:)``
// — rather than pretending, because a game that knows it missed a goal can at
// least re-read the score.
//
// # Why a joiner does not replay history
//
// A participant arriving mid-game sees the snapshot first, and the snapshot
// already reflects every event before it: the score is in the facts. Replaying
// the events behind it would cheer a goal from five minutes ago. A joiner
// therefore starts at the snapshot's high-water mark, and a participant who has
// been here all along and merely fell behind starts where it left off. Joining
// and repairing are the same operation on the state and differ only here, by
// whether the reader had a position to resume.

import Foundation
import MoqomCore

/// Something that happened in a shared space.
///
/// Application-defined, like ``SpaceEntity/kind`` and ``SpaceIntent/verb``. The
/// space orders and delivers it; it never interprets it.
public struct SpaceGameEvent: Hashable, Sendable, Codable {
    /// What happened: `"goal"`, `"popped"`, `"turn"`.
    public var name: String

    /// What it happened to, if anything.
    ///
    /// A name rather than a handle, because an event outlives the thing it is
    /// about: "popped b-7" is delivered after b-7 is gone.
    public var subject: SpaceEntityID?

    /// Anything else worth saying. Absolute values, as everywhere here.
    public var facts: [String: SpaceValue]

    public init(
        _ name: String,
        subject: SpaceEntityID? = nil,
        facts: [String: SpaceValue] = [:]
    ) {
        self.name = name
        self.subject = subject
        self.facts = facts
    }
}

/// A game event, numbered and stamped by the authority that ordered it.
public struct SpaceEventRecord: Hashable, Sendable, Codable {
    /// The authority whose log this is. See ``SpaceTick/epoch``.
    public var epoch: UInt32

    /// Position in that authority's log, from 1, without gaps.
    ///
    /// Delivered in this order and exactly once per epoch.
    public var sequence: UInt64

    public var event: SpaceGameEvent

    /// The participant whose action caused it, when one did.
    ///
    /// Nil for something the simulation decided on its own — a timer running
    /// out — and for which there is nobody to credit.
    public var from: ParticipantIdentity?

    /// The tick's instant on the shared timeline.
    public var at: Timecode

    /// The tick's instant on the authority's capture clock, when it publishes
    /// video. See ``SpacePlayout/frame(alignedTo:)``.
    public var media: FrameTimestamp?

    public init(
        epoch: UInt32,
        sequence: UInt64,
        event: SpaceGameEvent,
        from: ParticipantIdentity? = nil,
        at: Timecode,
        media: FrameTimestamp? = nil
    ) {
        self.epoch = epoch
        self.sequence = sequence
        self.event = event
        self.from = from
        self.at = at
        self.media = media
    }
}

/// Where a participant has got to in a space's events.
///
/// Carried across a reconnect so that the new subscription resumes rather than
/// joins: it delivers what was missed instead of skipping it as history, and it
/// keeps fencing an authority the old connection had already seen replaced.
public struct SpaceEventCursor: Hashable, Sendable {
    public let epoch: UInt32
    public let delivered: UInt64

    public init(epoch: UInt32, delivered: UInt64) {
        self.epoch = epoch
        self.delivered = delivered
    }
}

// MARK: - Reading the log

/// Turns events arriving in any order, any number of times, into each event
/// once, in order.
///
/// A value type with no clock and no I/O, so every interleaving a network can
/// produce can be stated in a test.
struct SpaceEventSequencer: Sendable {
    enum Output: Hashable, Sendable {
        case event(SpaceEventRecord)
        case missed(epoch: UInt32, sequences: ClosedRange<UInt64>)
    }

    /// Events held above a gap at most. A hostile peer announcing an event a
    /// billion ahead must not make this hold a billion.
    static let holdLimit = 1024

    private(set) var epoch: UInt32?
    private(set) var delivered: UInt64 = 0
    private var held: [UInt64: SpaceEventRecord] = [:]

    init(resuming cursor: SpaceEventCursor? = nil) {
        if let cursor {
            epoch = cursor.epoch
            delivered = cursor.delivered
        }
    }

    var cursor: SpaceEventCursor? {
        epoch.map { SpaceEventCursor(epoch: $0, delivered: delivered) }
    }

    /// Start a fresh log at `epoch`, delivering it from its first event.
    ///
    /// For a new authority this device knows to be a continuation — its own
    /// tenure, or the winner of a tie in the same epoch — as opposed to a log
    /// it is meeting for the first time.
    mutating func restart(epoch: UInt32) {
        self.epoch = epoch
        delivered = 0
        held.removeAll()
    }

    /// Fold in whatever one update carried.
    ///
    /// - Parameters:
    ///   - epoch: The update's epoch. Anything below the current one is a
    ///     replaced authority and is ignored whole.
    ///   - events: The events it carried, in any order, possibly repeats.
    ///   - highWater: The last sequence the authority had assigned when it
    ///     wrote the update. Lets a gap be noticed even when nothing in it
    ///     arrived.
    ///   - isSnapshot: Whether this is the authority's complete account. Only a
    ///     snapshot can declare a gap unrecoverable, because only a snapshot
    ///     promises to carry everything the authority still holds.
    mutating func receive(
        epoch incoming: UInt32,
        events: [SpaceEventRecord],
        through highWater: UInt64,
        isSnapshot: Bool
    ) -> [Output] {
        if let epoch {
            if incoming < epoch { return [] }
            if incoming > epoch { restart(epoch: incoming) }
        } else {
            // Meeting this log for the first time: whatever is behind the
            // snapshot is already in the state. A delta before any snapshot
            // cannot be applied, so its events are as much history as its
            // changes are.
            guard isSnapshot else { return [] }
            epoch = incoming
            delivered = highWater
        }

        for record in events where record.sequence > delivered {
            guard held[record.sequence] == nil else { continue }
            if held.count >= Self.holdLimit {
                // Full: what is nearest the gap is what can be delivered, so
                // the furthest ahead makes way for it.
                guard let furthest = held.keys.max(), record.sequence < furthest else { continue }
                held.removeValue(forKey: furthest)
            }
            var stamped = record
            stamped.epoch = incoming
            held[record.sequence] = stamped
        }

        var out = drain()
        if isSnapshot {
            while delivered < highWater {
                let next = held.keys.min().map { min($0, highWater &+ 1) } ?? highWater &+ 1
                let last = next - 1
                guard last > delivered else { break }
                out.append(.missed(epoch: incoming, sequences: (delivered + 1) ... last))
                delivered = last
                out += drain()
            }
        }
        return out
    }

    private mutating func drain() -> [Output] {
        var out: [Output] = []
        while delivered < .max, let next = held.removeValue(forKey: delivered + 1) {
            out.append(.event(next))
            delivered += 1
        }
        return out
    }
}

// MARK: - Writing the log

/// The authority's side: numbering, and remembering enough to repeat.
struct SpaceEventLog: Sendable {
    private(set) var epoch: UInt32 = 0
    private(set) var sequence: UInt64 = 0

    /// The epoch's most recent events, oldest first, for snapshots.
    private(set) var retained: [SpaceEventRecord] = []

    /// This group's events so far, oldest first, for deltas.
    private(set) var sinceGroup: [SpaceEventRecord] = []

    /// Ticks left on which to repeat the group's events even if nothing else
    /// changed, so that the last event before a quiet spell is not left
    /// depending on a single delta.
    private(set) var echoes = 0

    var retention: Int
    var redundancy: Int

    /// Quiet ticks after an event on which it is still repeated.
    static let echoTicks = 3

    init(retention: Int, redundancy: Int) {
        self.retention = max(1, retention)
        self.redundancy = max(1, redundancy)
    }

    mutating func restart(epoch: UInt32) {
        self.epoch = epoch
        sequence = 0
        retained.removeAll()
        sinceGroup.removeAll()
        echoes = 0
    }

    mutating func append(
        _ event: SpaceGameEvent,
        from who: ParticipantIdentity?,
        at now: Timecode,
        media: FrameTimestamp?
    ) -> SpaceEventRecord {
        sequence += 1
        let record = SpaceEventRecord(
            epoch: epoch,
            sequence: sequence,
            event: event,
            from: who,
            at: now,
            media: media
        )
        retained.append(record)
        if retained.count > retention { retained.removeFirst(retained.count - retention) }
        sinceGroup.append(record)
        echoes = Self.echoTicks
        return record
    }

    mutating func groupStarted() {
        sinceGroup.removeAll(keepingCapacity: true)
        echoes = 0
    }

    /// What a delta should carry, and whether it must be sent even if the
    /// state did not change.
    mutating func forDelta(hasNew: Bool) -> (events: [SpaceEventRecord], mustSend: Bool) {
        guard !sinceGroup.isEmpty else { return ([], false) }
        let mustSend = hasNew || echoes > 0
        if !hasNew, echoes > 0 { echoes -= 1 }
        return (Array(sinceGroup.suffix(redundancy)), mustSend)
    }
}
