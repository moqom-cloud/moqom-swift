// What a shared space contains, and how that is replicated.
//
// The room control track and this one look alike and are not, and the difference
// decides most of what is below.
//
// Control entries are *facts about people* — a grant, an eviction — and every
// one of them matters forever. So that log holds an out-of-order entry until the
// gap before it fills, because an entry skipped is a permission wrong. A shared
// space is a *simulation*, and a tick that arrives after the tick following it
// is worthless: nobody wants to see the ball where it was two frames ago. So
// this discards late arrivals rather than reordering them, which makes it far
// closer to a video track than to a control log, and it fans out and caches
// through exactly the same machinery for the same reason.
//
// Two rules are inherited from the control log unchanged, because they are what
// make a replicated log survivable rather than merely correct on a good network.
//
// **Every value is absolute, never an increment.** A delta says where an entity
// *is*, not how far it moved. Applying it twice is applying it once. A log of
// displacements would double every one of them on the reconnect that re-reads
// objects already seen, and would drift permanently on any object dropped.
//
// **Every group begins with a snapshot.** Joining and returning are then the
// same operation, and a client that has fallen out of sync heals at the next
// snapshot even if it never asks for repair.
//
// # Split brain
//
// The one thing a room log never has to handle is two publishers. This track has
// exactly that risk: the authority is a participant's device, and a device that
// goes quiet for four seconds may be gone or may be in a lift. If a new authority
// starts while the old one is still running, both publish to the same track.
//
// ``SpaceTick`` is the fence. Every tick carries an epoch that increments on
// handover, and a client ignores anything from an epoch below the highest it has
// seen. The stale authority's writes are then inert rather than corrupting.
// Noticing the replacement is a separate problem: a real relay pins each
// subscription to the publisher it first found, so an incumbent that never
// subscribes again will simulate forever beside a successor nobody told it
// about. ``SpaceSession`` resubscribes while it is leading, which is what
// makes the fence observable rather than merely correct.

import Foundation
import MoqomCore

/// A point on a shared space's simulation timeline.
///
/// Two numbers rather than one, and the second is the interesting one. `step`
/// counts simulation ticks. `epoch` counts *authorities*: it increments every
/// time the simulation moves to a different device.
///
/// The epoch is a fencing token, and it exists because the authority here is a
/// phone rather than a server. When a host drops, someone else has to take over,
/// and there is no way to be sure the original has actually stopped — it may be
/// in a tunnel with a full send buffer. Without a fence, the two of them
/// interleave writes to one track and the state tears. With one, the older
/// authority's ticks are ignored by every reader the moment the newer one
/// publishes, and the old authority learns it has been replaced by reading the
/// track it is writing to.
public struct SpaceTick: Hashable, Sendable, Codable, Comparable {
    /// Which authority produced this. Increments on every handover.
    public var epoch: UInt32

    /// The simulation step, within that authority's tenure.
    public var step: UInt64

    public init(epoch: UInt32 = 0, step: UInt64 = 0) {
        self.epoch = epoch
        self.step = step
    }

    public static let zero = SpaceTick()

    /// Orders by epoch first, so a newer authority always wins regardless of how
    /// far the older one had counted.
    public static func < (lhs: SpaceTick, rhs: SpaceTick) -> Bool {
        (lhs.epoch, lhs.step) < (rhs.epoch, rhs.step)
    }

    /// The next step under the same authority.
    public var next: SpaceTick { SpaceTick(epoch: epoch, step: step + 1) }

    /// The first step of the next authority.
    ///
    /// Resets the step, because it is only meaningful within an epoch and
    /// carrying it over would suggest a continuity that is not there.
    public var succeeding: SpaceTick { SpaceTick(epoch: epoch + 1, step: 0) }
}

/// The name of one thing in a shared space.
///
/// A string chosen by the application, like the rest of the identifiers in this
/// SDK. An integer would be a byte or two cheaper and would mean the authority
/// has to hand out identifiers and everyone has to wait for one, which costs a
/// round trip at exactly the moment a game wants to feel immediate.
public struct SpaceEntityID: Hashable, Sendable, Codable, RawRepresentable,
    ExpressibleByStringLiteral, CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ value: String) { rawValue = value }
    public init(stringLiteral value: String) { rawValue = value }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}

extension SpaceEntityID: CodingKeyRepresentable {
    /// Makes a dictionary keyed by an identifier encode as a JSON object.
    ///
    /// Without this, Swift falls back to a flat array of alternating keys and
    /// values — `["ball",{…},"cube",{…}]` — which is valid, half the size of the
    /// problem, and miserable to write a web or Android decoder against. Entity
    /// maps are most of this track's bytes, so the shape is worth pinning.
    public var codingKey: any CodingKey { Key(rawValue) }

    public init?<T>(codingKey: T) where T: CodingKey {
        self.init(codingKey.stringValue)
    }

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }

        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.init(stringValue) }
        init?(intValue _: Int) { nil }
    }
}

/// A value a game attaches to an entity or to the space.
///
/// A closed set of scalars rather than arbitrary JSON, and the restriction is
/// deliberate. Replicated state has to be comparable — to tell a change from a
/// repeat — and diffable, and nested free-form structure is neither. A game with
/// something genuinely structured to say can encode it and put the string here,
/// which keeps the cost visible to whoever chose it.
public enum SpaceValue: Hashable, Sendable, Codable {
    case flag(Bool)
    case number(Int64)
    case decimal(Double)
    case text(String)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .flag(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .number(value)
        } else if let value = try? container.decode(Double.self) {
            self = .decimal(value)
        } else {
            self = .text(try container.decode(String.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .flag(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .decimal(value): try container.encode(value)
        case let .text(value): try container.encode(value)
        }
    }
}

/// One thing in a shared space.
public struct SpaceEntity: Hashable, Sendable, Codable {
    public var id: SpaceEntityID

    /// What the application should draw. Never interpreted here.
    public var kind: String

    /// Where it is, in space coordinates. See ``SpaceAnchor`` for the difference
    /// between that and where it is in anybody's living room.
    public var pose: SpacePose

    /// Who is currently manipulating it, if anyone.
    ///
    /// Assigned by the authority, which is what makes it useful: two people
    /// grabbing the same piece both send an intent, one of them gets the
    /// ownership, and the loser finds out by seeing the winner's name here
    /// rather than by having their local drag silently overruled.
    public var owner: ParticipantIdentity?

    /// Application state. Absolute values only — see the note at the top.
    public var facts: [String: SpaceValue]

    public init(
        id: SpaceEntityID,
        kind: String,
        pose: SpacePose = .identity,
        owner: ParticipantIdentity? = nil,
        facts: [String: SpaceValue] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.pose = pose
        self.owner = owner
        self.facts = facts
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, pose = "at", owner, facts
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(SpaceEntityID.self, forKey: .id)
        kind = try container.decode(String.self, forKey: .kind)
        pose = try container.decodeIfPresent(SpacePose.self, forKey: .pose) ?? .identity
        owner = try container.decodeIfPresent(ParticipantIdentity.self, forKey: .owner)
        facts = try container.decodeIfPresent([String: SpaceValue].self, forKey: .facts) ?? [:]
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        if pose != .identity { try container.encode(pose, forKey: .pose) }
        try container.encodeIfPresent(owner, forKey: .owner)
        if !facts.isEmpty { try container.encode(facts, forKey: .facts) }
    }
}

/// What changed in one tick.
///
/// Every field is an absolute value. `moved` carries where an entity now is, not
/// how far it went; `facts` carries a value, not a delta. Applying the same
/// delta twice leaves the state where applying it once did, which is what makes
/// the overlap after a repair harmless.
public struct SpaceDelta: Hashable, Sendable, Codable {
    /// Entities whose pose changed, with their new pose.
    public var moved: [SpaceEntityID: SpacePose]

    /// Entities that came into existence, in full.
    public var spawned: [SpaceEntity]

    /// Entities that no longer exist.
    public var removed: [SpaceEntityID]

    /// Ownership assignments. A present key with a nil value releases.
    ///
    /// Two levels of optional, which is unpleasant and is the honest encoding of
    /// three states: absent means unchanged, present-and-nil means released,
    /// present-and-set means claimed.
    public var claimed: [SpaceEntityID: ParticipantIdentity?]

    /// Space-wide application state, as new values.
    public var facts: [String: SpaceValue]

    /// Space-wide facts that no longer exist.
    ///
    /// A new value cannot say "gone", and without this a fact could be set but
    /// never unset — a simulation that cleared one had to wait for the next
    /// snapshot for anybody else to find out. Which read, in the sample this
    /// exists for, as last round's scores staying on screen for two seconds
    /// after the rematch that cleared them.
    public var forgotten: [String]

    /// Per-entity application state, as new values.
    public var entityFacts: [SpaceEntityID: [String: SpaceValue]]

    public init(
        moved: [SpaceEntityID: SpacePose] = [:],
        spawned: [SpaceEntity] = [],
        removed: [SpaceEntityID] = [],
        claimed: [SpaceEntityID: ParticipantIdentity?] = [:],
        facts: [String: SpaceValue] = [:],
        forgotten: [String] = [],
        entityFacts: [SpaceEntityID: [String: SpaceValue]] = [:]
    ) {
        self.moved = moved
        self.spawned = spawned
        self.removed = removed
        self.claimed = claimed
        self.facts = facts
        self.forgotten = forgotten
        self.entityFacts = entityFacts
    }

    /// Whether this says anything at all.
    ///
    /// An authority ticking on a still board should send nothing rather than an
    /// empty object sixty times a second.
    public var isEmpty: Bool {
        moved.isEmpty && spawned.isEmpty && removed.isEmpty
            && claimed.isEmpty && facts.isEmpty && forgotten.isEmpty
            && entityFacts.isEmpty
    }
}

/// The complete contents of a shared space.
public struct SpaceSnapshot: Hashable, Sendable, Codable {
    public var entities: [SpaceEntityID: SpaceEntity]

    /// Space-wide application state: the score, whose turn it is, the phase.
    public var facts: [String: SpaceValue]

    /// Who is simulating.
    ///
    /// In the snapshot so that a joiner learns it without a second exchange, and
    /// so that a client can tell whether the person it is watching is still the
    /// one in charge.
    public var authority: ParticipantIdentity?

    public init(
        entities: [SpaceEntityID: SpaceEntity] = [:],
        facts: [String: SpaceValue] = [:],
        authority: ParticipantIdentity? = nil
    ) {
        self.entities = entities
        self.facts = facts
        self.authority = authority
    }

    /// Fold one tick's changes in.
    ///
    /// Order matters and is chosen so that a delta can spawn a thing and move it
    /// in the same tick: spawns land before moves, and removals happen last so
    /// that a thing created and destroyed within one tick leaves nothing behind.
    public mutating func apply(_ delta: SpaceDelta) {
        for entity in delta.spawned {
            entities[entity.id] = entity
        }
        for (id, pose) in delta.moved {
            entities[id]?.pose = pose
        }
        for (id, owner) in delta.claimed {
            entities[id]?.owner = owner
        }
        for (id, facts) in delta.entityFacts {
            // Replaced, not merged. ``delta(to:)`` sends an entity's whole bag
            // precisely because a dropped key cannot be sent as a new value;
            // folding it in key by key undid that, and a fact the authority had
            // cleared stayed set on everybody watching.
            entities[id]?.facts = facts
        }
        for (key, value) in delta.facts {
            facts[key] = value
        }
        for key in delta.forgotten {
            facts.removeValue(forKey: key)
        }
        for id in delta.removed {
            entities.removeValue(forKey: id)
        }
    }

    /// The changes that would turn this state into another.
    ///
    /// Used by the authority to send a tick without having to track what it
    /// touched. Comparing is cheap next to simulating, and a diff computed from
    /// the state cannot drift from it the way a hand-maintained change list can.
    public func delta(to next: SpaceSnapshot) -> SpaceDelta {
        var delta = SpaceDelta()

        for (id, entity) in next.entities {
            guard let previous = entities[id] else {
                delta.spawned.append(entity)
                continue
            }
            if previous.pose != entity.pose { delta.moved[id] = entity.pose }
            if previous.owner != entity.owner { delta.claimed[id] = entity.owner }
            if previous.facts != entity.facts {
                // The whole bag, not the changed keys. A removed key cannot be
                // expressed as a new value, and the bags are small.
                delta.entityFacts[id] = entity.facts
            }
        }
        for id in entities.keys where next.entities[id] == nil {
            delta.removed.append(id)
        }
        for (key, value) in next.facts where facts[key] != value {
            delta.facts[key] = value
        }
        for key in facts.keys where next.facts[key] == nil {
            delta.forgotten.append(key)
        }
        return delta
    }
}

/// One numbered entry on a shared space's track.
public struct SpaceUpdate: Hashable, Sendable, Codable {
    /// Format version, so a client refuses an entry it would misread.
    public var version: Int

    /// Which authority, and which step of the simulation.
    public var tick: SpaceTick

    /// The trusted time this tick was simulated for.
    ///
    /// Not the time it was sent, and the distinction is the point: this is the
    /// instant the state describes, so a receiver knows how stale what it is
    /// holding is, and can place it on a timeline shared with every other
    /// participant. Carries its own uncertainty, so a device whose clock has
    /// fallen back to local time is visibly unable to do that rather than
    /// quietly wrong about it. See ``SpaceTimeline``.
    public var at: Timecode

    public var body: Body

    /// The same instant on the authority's capture clock, when it is on camera.
    ///
    /// The clock its video frames are stamped with, so a viewer can draw the
    /// board at exactly the moment of the picture it is showing. See
    /// ``SpacePlayout``.
    public var media: FrameTimestamp?

    /// Game events, in this authority's numbering. See ``SpaceGameEvent``.
    ///
    /// A delta carries its group's events so far and a snapshot the epoch's
    /// most recent, so most of these are repeats and a reader drops them.
    public var events: [SpaceEventRecord]

    /// The last event number this authority had assigned when it wrote this.
    ///
    /// Zero when it has assigned none. Lets a reader notice a gap even when
    /// nothing in the gap arrived.
    public var eventSequence: UInt64

    /// Who this authority is handing the space to, on its last snapshot.
    ///
    /// The named participant takes over at the next epoch straight away rather
    /// than waiting out ``SpaceSession/Configuration/quiet``.
    public var successor: ParticipantIdentity?

    public enum Body: Hashable, Sendable {
        /// Everything. Applying it needs no history.
        case snapshot(SpaceSnapshot)

        /// What changed since the previous tick.
        case delta(SpaceDelta)
    }

    public static let currentVersion = 1

    public init(
        tick: SpaceTick,
        at: Timecode,
        body: Body,
        version: Int = SpaceUpdate.currentVersion,
        media: FrameTimestamp? = nil,
        events: [SpaceEventRecord] = [],
        eventSequence: UInt64 = 0,
        successor: ParticipantIdentity? = nil
    ) {
        self.version = version
        self.tick = tick
        self.at = at
        self.body = body
        self.media = media
        self.events = events
        self.eventSequence = eventSequence
        self.successor = successor
    }

    public var isSnapshot: Bool {
        if case .snapshot = body { return true }
        return false
    }

    private enum CodingKeys: String, CodingKey {
        case version = "v", tick = "t", at, snapshot, delta
        case media, events, eventSequence = "seq", successor = "next"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        tick = try container.decode(SpaceTick.self, forKey: .tick)
        at = try container.decode(Timecode.self, forKey: .at)
        media = try container.decodeIfPresent(FrameTimestamp.self, forKey: .media)
        events = try container.decodeIfPresent([SpaceEventRecord].self, forKey: .events) ?? []
        eventSequence = try container.decodeIfPresent(UInt64.self, forKey: .eventSequence) ?? 0
        successor = try container.decodeIfPresent(ParticipantIdentity.self, forKey: .successor)
        if let snapshot = try container.decodeIfPresent(SpaceSnapshot.self, forKey: .snapshot) {
            body = .snapshot(snapshot)
        } else {
            body = .delta(try container.decode(SpaceDelta.self, forKey: .delta))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(tick, forKey: .tick)
        try container.encode(at, forKey: .at)
        switch body {
        case let .snapshot(snapshot): try container.encode(snapshot, forKey: .snapshot)
        case let .delta(delta): try container.encode(delta, forKey: .delta)
        }
        try container.encodeIfPresent(media, forKey: .media)
        if !events.isEmpty { try container.encode(events, forKey: .events) }
        if eventSequence > 0 { try container.encode(eventSequence, forKey: .eventSequence) }
        try container.encodeIfPresent(successor, forKey: .successor)
    }
}

public extension SpaceUpdate {
    /// The track a shared space is published on, under the room's namespace.
    ///
    /// A sibling of `.control` rather than part of it. The two have opposite
    /// authorities — one is the relay, one is a participant — different
    /// cadences by two orders of magnitude, and different consequences for
    /// falling behind. Sharing a track would put a grant change behind a
    /// backlog of ball positions.
    static let trackName = ".space"

    /// Below the control track's 8 and below media.
    ///
    /// A game that stutters is a bad game; a room that mis-authorises somebody
    /// is a broken one, and a call where the audio breaks up is unusable. When
    /// the link cannot carry everything, this is what should suffer.
    static let priority: UInt8 = 24
}

/// Where a renderer samples a space that ticks slower than the display.
///
/// The simulation publishes twenty times a second. A view drawing at sixty
/// that showed only those instants would step, and a follower that waited for
/// the packet before moving would sit a round-trip behind the authority — two
/// phones, two different games to look at. Sampling both against the same
/// clock, and extrapolating a little when the next tick has not arrived, is
/// what makes them draw the same pose.
public enum SpaceTimeline {
    /// How far between two ticks `now` sits: 0 at `start`, 1 at `end`.
    ///
    /// Unclamped above 1, because that is extrapolation — the thing a renderer
    /// wants when the next state has not arrived yet and the alternative is
    /// freezing. Capped at `coasting` past `end` so a dropped stream does not
    /// fling entities into the distance.
    ///
    /// `nil` when the clocks cannot be compared. A fallback timecode is one
    /// machine's opinion of itself, and sampling it against another would
    /// place bubbles where nobody put them.
    public static func progress(
        from start: Timecode,
        to end: Timecode,
        at now: Timecode,
        coasting: Duration = .milliseconds(250)
    ) -> Float? {
        guard now.isTrusted, start.isTrusted, end.isTrusted else { return nil }
        // Saturating, because all three can come off the wire.
        return SpacePlayout.progress(
            from: start.nanoseconds,
            to: end.nanoseconds,
            at: now.nanoseconds,
            coasting: coasting.wholeNanoseconds
        )
    }
}

// Deliberately no `encoded()` here, though every other track type in this SDK
// has one. This track's encoding interns entity names, so an update's bytes
// depend on the updates before it and a free function cannot produce them. Use
// ``SpaceEncoder`` and ``SpaceDecoder``, one of each per publication or
// subscription. `Codable` conformance is retained for tests and for anyone
// wanting to read a tick in a debugger, not for the wire.
