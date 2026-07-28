// The room control track: the state a namespace announcement cannot carry.
//
// Announcements already answer "who is publishing", and the roster is built from
// nothing else. What they cannot answer is everything a client needs in order to
// be *correct* about those people: what they are permitted to publish, whether a
// moderator has muted them for the room, whether they are reconnecting or gone,
// who is spotlighted, whether the stage is locked, whether a recorder is
// attached, and whether the room has ended. None of that is derivable from who
// is announcing, and all of it changes while a viewer is on a train.
//
// So it travels as a track, for the same reasons the catalog does: it is
// relayed, cached, and fanned out by the tree that already exists, arrives at
// media latency, and needs no second signalling channel to secure. Four
// properties make it survivable across a dropped connection.
//
// **Every entry is numbered.** One monotonic sequence for the life of the room,
// continuing across groups and across the publisher's own reconnections. The
// number is what lets a returning client tell what it missed from what it
// already has, and it is the whole difference between a log and a stream of
// notifications.
//
// **Every change carries a value, never an increment.** `mute` is the complete
// set of muted kinds, not "also mute audio". Applying an entry twice is
// therefore the same as applying it once, which is what makes replay safe:
// after a reconnect a client re-reads objects it has already seen, and a log of
// increments would double every one of them. This is the rule to preserve when
// adding a case.
//
// **Every group begins with a snapshot.** A group is where a subscriber can
// join, so starting each one with the complete state means joining and returning
// are the same operation, and a gap heals at the next snapshot even if nothing
// asks for repair. It also makes repair cheap: one group contains a snapshot
// plus everything after it, so a FETCH of the current group is a full resync,
// and the sequence numbers make the overlap harmless.
//
// **Membership is not in here.** The temptation is to put joins and leaves in
// the log too, and it is wrong: there would then be two sources of truth for who
// is in the room, and they would disagree exactly when it mattered. A
// participant appears because they announced. This says what they may do.
//
// Two mechanisms guard compatibility, and they answer different questions.
// ``RoomUpdate/version`` is for a change of *meaning*: an entry a client would
// misread is refused outright, because applying half of an authorisation change
// is worse than applying none of it. An unrecognised ``RoomChange`` kind at a
// version this build can read is the opposite case — something was added that
// this build has no opinion about — and it is skipped while the sequence
// advances, because the alternative is a hole that never fills. A reader that
// stalled on it would sit in permanent repair, re-fetching a group whose
// contents it still could not decode, and lose the entries it *did* understand
// along with the one it did not.
//
// One consequence worth stating, because it decides who publishes this: presence
// cannot come from the participant it describes. A client that has lost its
// network is in no position to announce that it has lost its network. Only the
// party that watches the session drop can say so, which means the authority for
// this track is the relay and the control plane behind it — not a host's phone.

import Foundation
import MoqomCore

/// One numbered entry in a room's control log.
public struct RoomUpdate: Hashable, Sendable {
    /// Format version, so a client refuses an entry it would misread rather than
    /// applying half of it to live authorisation state.
    public let version: Int

    /// Position in the room's log. Starts at 1 and never repeats.
    public let sequence: UInt64

    public let body: Body

    public enum Body: Hashable, Sendable {
        /// The complete state. Applying it needs no history.
        case snapshot(RoomSnapshot)

        /// One field of one thing, as its new value.
        case change(RoomChange)
    }

    public static let currentVersion = 1

    public init(sequence: UInt64, body: Body, version: Int = RoomUpdate.currentVersion) {
        self.version = version
        self.sequence = sequence
        self.body = body
    }

    public init(sequence: UInt64, _ change: RoomChange) {
        self.init(sequence: sequence, body: .change(change))
    }

    public init(sequence: UInt64, _ snapshot: RoomSnapshot) {
        self.init(sequence: sequence, body: .snapshot(snapshot))
    }

    /// Whether this entry is a complete state rather than a field of one.
    public var isSnapshot: Bool {
        if case .snapshot = body { return true }
        return false
    }
}

/// A change to one field of room state, expressed as its new value.
///
/// Absolute rather than relative throughout — see the note at the top of this
/// file. A case that reads as a verb ("mute", "promote") is the shape to avoid;
/// a case that reads as an assignment is the shape that replays.
public enum RoomChange: Hashable, Sendable {
    /// What a participant may publish and moderate, in full.
    case grants(ParticipantIdentity, Grants)

    /// Whether they are connected, reconnecting, away, or gone. Observed by the
    /// relay, which is the only party that can see it.
    case presence(ParticipantIdentity, Presence)

    /// Moderator-imposed mute, as the complete set of what is muted.
    ///
    /// Both scopes in one case because they are set together and read together,
    /// and because two cases would let a replay apply one without the other.
    case mute(ParticipantIdentity, forEveryone: MediaKind, forAudience: MediaKind)

    /// Who is spotlighted, or nobody.
    case spotlight(ParticipantIdentity?)

    case stage(StageSnapshot)

    case lifecycle(RoomLifecycle)

    /// Everything attached to the room, in full. A disclosure a viewer is owed
    /// must not depend on having received an earlier entry.
    case watchdogs([Watchdog])

    /// Removed by a moderator, or banned.
    ///
    /// The relay stops forwarding for them and their announcement goes away, so
    /// this is not what enforces the kick — it is what lets a client say why
    /// somebody vanished, and what tells the target rather than leaving them
    /// with a stream that mysteriously stopped.
    case evicted(ParticipantIdentity)

    /// How many viewers each cohost brought, in full.
    ///
    /// The whole set every time, including the cohorts that did not change,
    /// because a per-cohost delta would drift the moment one entry was lost —
    /// and these are the numbers a revenue split is argued over.
    case audiences(Audiences)

    /// A kind this build does not know, carrying its name and nothing else.
    ///
    /// Not an error. A newer authority is entitled to publish something this
    /// client has never heard of, and the useful response is to stay current on
    /// everything else rather than to stop reading. The payload is dropped
    /// rather than retained, so this does not round-trip: re-encoding one
    /// produces a change with no body, which is safe only because nothing
    /// republishes an entry it received.
    case unrecognised(String)

    /// Whether this sets a property *of* its subject, rather than something about
    /// the room that happens to name one.
    ///
    /// The distinction decides what a client does with an entry about somebody it
    /// has never heard of: an attribute is held until they announce, and a
    /// spotlight or a stage change applies to the room immediately.
    public var isAttribute: Bool {
        switch self {
        case .grants, .presence, .mute: true
        case .spotlight, .stage, .lifecycle, .watchdogs, .evicted, .audiences,
             .unrecognised: false
        }
    }

    /// Who this entry is about, when it is about one participant.
    public var subject: ParticipantIdentity? {
        switch self {
        case let .grants(identity, _),
             let .presence(identity, _),
             let .mute(identity, _, _),
             let .evicted(identity):
            identity
        case let .spotlight(identity):
            identity
        case .stage, .lifecycle, .watchdogs, .audiences, .unrecognised:
            nil
        }
    }
}

/// The room-authoritative state of one participant.
///
/// Deliberately not a ``Participant``: that type is reachable only from an
/// announcement, and this is the half of it that the announcement cannot supply.
/// Keeping them separate is what stops the control track from becoming a second
/// way to put somebody in a roster.
public struct ParticipantControl: Hashable, Sendable, Codable {
    public var identity: ParticipantIdentity
    public var grants: Grants
    public var presence: Presence

    /// Force-muted for everyone, relay-enforced.
    public var mutedForEveryone: MediaKind

    /// Audible to hosts but not to the audience.
    public var mutedForAudience: MediaKind

    public init(
        identity: ParticipantIdentity,
        grants: Grants = Grants(),
        presence: Presence = .connected,
        mutedForEveryone: MediaKind = [],
        mutedForAudience: MediaKind = []
    ) {
        self.identity = identity
        self.grants = grants
        self.presence = presence
        self.mutedForEveryone = mutedForEveryone
        self.mutedForAudience = mutedForAudience
    }
}

/// How many viewers came in through each cohost.
///
/// The one room figure that cannot be derived from anything else a client can
/// see. A roster is built from announcements, so viewers are structurally absent
/// from it — they publish nothing — and no amount of watching the room recovers
/// *why* somebody is in it. When two cohosts bring their own followings to one
/// room, "whose audience is this" is a fact about the moment each viewer
/// arrived, and it is gone by the time anybody thinks to ask.
///
/// So it is asserted rather than inferred, by the only party that sees every
/// arrival: the control plane mints the token, so it knows what the tenant said
/// when it minted one, and it counts the sessions.
///
/// This is a count and deliberately not a membership list. Naming the viewers
/// would make the control track a second answer to who is in the room, which the
/// note at the top of this file exists to prevent, and would put a hundred
/// thousand identities on a track every client subscribes to.
public struct Audiences: Hashable, Sendable, Codable {
    /// One cohort of viewers, and who brought them.
    public struct Audience: Hashable, Sendable, Codable {
        /// The cohost whose following these viewers arrived through, or `nil`
        /// for the ones who found the room by themselves.
        ///
        /// A username rather than a ``ParticipantIdentity`` because people are
        /// followed, not phones: a cohost on an iPad and a handset is one
        /// audience, and splitting them by device would be an artefact of how
        /// they happened to join.
        ///
        /// Not required to be in the room, and that is the normal case rather
        /// than a defect. An audience arrives before its cohost does, and stays
        /// for a while after they drop — a cohort that vanished the moment its
        /// cohost's connection did would take the host's revenue split with it.
        public var via: Username?

        /// How many of them are here now.
        ///
        /// Live rather than cumulative. Peaks and totals are a question for a
        /// warehouse, which can answer it about last Tuesday; this answers it
        /// about now, which is the only thing a client can render.
        public var viewers: Int

        /// What ``viewers`` was rounded to. `1` is exact.
        ///
        /// Carried rather than assumed, for the same reason a ``Timecode``
        /// carries its uncertainty: a number whose precision is unstated will be
        /// read as exact, and a UI that prints "1,203,847 watching" from a
        /// figure quantised to the nearest thousand is lying in a way nobody can
        /// detect. Coarsening is what keeps this track quiet — a busy room's
        /// exact count changes several times a second, and publishing every
        /// change would spend the room's control bandwidth on a digit nobody
        /// reads.
        public var resolution: Int

        public init(via: Username?, viewers: Int, resolution: Int = 1) {
            self.via = via
            self.viewers = viewers
            self.resolution = max(1, resolution)
        }

        /// Whether this figure is precise.
        public var isExact: Bool { resolution == 1 }
    }

    /// Every cohort, including the unattributed one.
    ///
    /// Unattributed is an entry with no ``Audience/via`` rather than a separate
    /// field, because it is not a leftover: "found us on their own" is the
    /// organic reach of the room and the number a host compares every cohost
    /// against.
    public var cohorts: [Audience]

    public init(cohorts: [Audience] = []) {
        self.cohorts = cohorts
    }

    /// Viewers attributed to one cohost, or zero if none are.
    public subscript(via: Username) -> Int {
        cohorts.first { $0.via == via }?.viewers ?? 0
    }

    /// Viewers who arrived by themselves.
    public var unattributed: Int {
        cohorts.first { $0.via == nil }?.viewers ?? 0
    }

    /// Everyone counted here.
    ///
    /// A sum of quantised parts, so it is approximate whenever any part is, and
    /// need not equal a room's viewer count exactly.
    public var total: Int {
        cohorts.reduce(0) { $0 + $1.viewers }
    }

    /// Whether every figure in here is precise.
    public var isExact: Bool { cohorts.allSatisfy(\.isExact) }

    /// Cohorts brought by a cohost, largest first, excluding the organic one.
    ///
    /// Ordered here rather than by the authority so that the wire form has one
    /// meaning and every client draws the same order.
    public var attributed: [Audience] {
        cohorts.filter { $0.via != nil }.sorted {
            ($0.viewers, $1.via?.value ?? "") > ($1.viewers, $0.via?.value ?? "")
        }
    }
}

/// The stage, as it survives a reconnect.
///
/// Everything from ``StageState`` except the invitations in flight, and their
/// absence is the point. An invitation is a handshake with a deadline on the
/// issuer's clock, and replaying one to a client that has been offline for
/// thirty seconds produces exactly what ``StageInvitation`` exists to prevent: a
/// promotion landing while the invitee is not looking. A pending invitation
/// whose subject reconnects is reissued or expired by the authority; it is not
/// restored from history.
public struct StageSnapshot: Hashable, Sendable, Codable {
    public var slotLimit: Int
    public var isLocked: Bool
    public var spotlighted: ParticipantIdentity?
    public var queue: [ParticipantIdentity]

    public init(
        slotLimit: Int = 8,
        isLocked: Bool = false,
        spotlighted: ParticipantIdentity? = nil,
        queue: [ParticipantIdentity] = []
    ) {
        self.slotLimit = slotLimit
        self.isLocked = isLocked
        self.spotlighted = spotlighted
        self.queue = queue
    }

    public init(_ stage: StageState) {
        slotLimit = stage.slotLimit
        isLocked = stage.isLocked
        spotlighted = stage.spotlighted
        queue = stage.queue
    }

    /// Apply onto live stage state, leaving invitations in flight alone.
    public func applied(to stage: StageState) -> StageState {
        var next = stage
        next.slotLimit = slotLimit
        next.isLocked = isLocked
        next.spotlighted = spotlighted
        next.queue = queue
        return next
    }
}

/// Everything the control track knows, complete.
///
/// Sized by the room rather than by its uptime, which is the property that makes
/// recovery bounded: a client returning after an hour offline reads one of these
/// and is current, instead of replaying an hour of history.
public struct RoomSnapshot: Hashable, Sendable, Codable {
    /// One entry per participant the authority knows about, which may include
    /// people whose announcement has not arrived yet and people who publish
    /// nothing at all.
    public var participants: [ParticipantControl]

    public var stage: StageSnapshot
    public var lifecycle: RoomLifecycle
    public var watchdogs: [Watchdog]

    /// Who brought the viewers.
    ///
    /// Empty from an authority that does not attribute, which reads the same as a
    /// room nobody was brought to — correct in both cases, since the honest
    /// answer to "whose audience is this" is then "nobody knows".
    public var audiences: Audiences

    public init(
        participants: [ParticipantControl] = [],
        stage: StageSnapshot = StageSnapshot(),
        lifecycle: RoomLifecycle = .live,
        watchdogs: [Watchdog] = [],
        audiences: Audiences = Audiences()
    ) {
        self.participants = participants
        self.stage = stage
        self.lifecycle = lifecycle
        self.watchdogs = watchdogs
        self.audiences = audiences
    }

    public subscript(identity: ParticipantIdentity) -> ParticipantControl? {
        get { participants.first { $0.identity == identity } }
        set {
            guard let newValue else {
                participants.removeAll { $0.identity == identity }
                return
            }
            if let index = participants.firstIndex(where: { $0.identity == identity }) {
                participants[index] = newValue
            } else {
                participants.append(newValue)
            }
        }
    }

    /// Fold a change into this state.
    ///
    /// The authority holds a snapshot and applies its own changes to it, so that
    /// the next snapshot it writes is exactly the sum of everything it has
    /// published. Sharing the fold with the receiving side is what keeps the two
    /// from drifting.
    public mutating func apply(_ change: RoomChange) {
        switch change {
        case let .grants(identity, grants):
            self[identity, default: identity].grants = grants
        case let .presence(identity, presence):
            self[identity, default: identity].presence = presence
        case let .mute(identity, forEveryone, forAudience):
            self[identity, default: identity].mutedForEveryone = forEveryone
            self[identity, default: identity].mutedForAudience = forAudience
        case let .spotlight(identity):
            stage.spotlighted = identity
        case let .stage(snapshot):
            // Carries the spotlight too, so a stage entry cannot silently
            // resurrect a spotlight that a later entry cleared.
            stage = snapshot
        case let .lifecycle(lifecycle):
            self.lifecycle = lifecycle
        case let .watchdogs(watchdogs):
            self.watchdogs = watchdogs
        case let .evicted(identity):
            self[identity] = nil
            if stage.spotlighted == identity { stage.spotlighted = nil }
            stage.queue.removeAll { $0 == identity }
        case let .audiences(audiences):
            self.audiences = audiences
        case .unrecognised:
            // Nothing, on purpose. The sequence has already advanced by the time
            // this is reached, so the entry is accounted for; what it meant is
            // simply not knowable here. Folding it into a snapshot as anything
            // other than a no-op would mean this build republishing a guess.
            break
        }
    }

    private subscript(
        identity: ParticipantIdentity,
        default fallback: ParticipantIdentity
    ) -> ParticipantControl {
        get { self[identity] ?? ParticipantControl(identity: fallback) }
        set { self[identity] = newValue }
    }
}

/// Reads a room's control log in order, whatever order it arrives in.
///
/// Deliberately knows nothing about ``RoomState``: it decides *what to apply and
/// when*, and hands the entries back for somebody else to apply. That split is
/// what makes ordering, duplication, and gap behaviour testable without a room,
/// a transport, or a participant.
public struct RoomLog: Sendable {
    public struct Policy: Hashable, Sendable {
        /// How many out-of-order entries to hold while waiting for a gap to fill.
        ///
        /// Bounded because the hole may never fill — the object could be lost
        /// past any retransmission, or the publisher could have died mid-group.
        /// Past the bound the reader stops hoping and reports that it needs a
        /// snapshot, which is recoverable; growing without limit is not.
        public var buffer: Int

        public init(buffer: Int = 64) {
            self.buffer = buffer
        }

        public static let `default` = Policy()
    }

    public var policy: Policy

    /// The highest sequence applied with no hole beneath it. `0` before anything.
    public private(set) var applied: UInt64 = 0

    /// Whether a complete state has ever been seen.
    ///
    /// A reader that has only ever seen changes knows some fields and does not
    /// know the room, which is a different thing from an empty room.
    public private(set) var isFounded = false

    public private(set) var accepted = 0
    public private(set) var duplicates = 0

    /// Entries refused for being a version this build cannot read.
    public private(set) var rejected = 0

    /// Entries applied as no-ops because their kind is unknown to this build.
    ///
    /// Counted separately from ``rejected`` because they mean opposite things. A
    /// rejection is this reader declining to guess at something it might
    /// misapply; this is it correctly ignoring something additive. Both say the
    /// authority is newer, and only this one says the log is still whole.
    public private(set) var unrecognised = 0

    /// Whether entries were dropped because the buffer filled.
    public private(set) var isTruncated = false

    private var held: [UInt64: RoomUpdate.Body] = [:]

    public init(policy: Policy = .default) {
        self.policy = policy
    }

    /// Take one entry, and return everything that is now applicable, in order.
    ///
    /// Returns an empty array for a duplicate, for an entry from the future, and
    /// for one this build cannot read — the three cases a caller would otherwise
    /// have to distinguish before touching room state.
    public mutating func accept(_ update: RoomUpdate) -> [RoomUpdate.Body] {
        guard update.version <= RoomUpdate.currentVersion else {
            rejected += 1
            return []
        }

        switch update.body {
        case .snapshot:
            // Applies whatever came before it, because it depends on nothing
            // before it. This is the self-healing path: a client with a hole
            // three entries wide is whole again at the next group boundary
            // without asking anyone for anything.
            guard update.sequence > applied else {
                duplicates += 1
                return []
            }
            applied = update.sequence
            isFounded = true
            accepted += 1
            held = held.filter { $0.key > update.sequence }

            // The only thing that can resolve a discarded entry. Draining the
            // buffer cannot: the entries thrown away were never held, so the
            // hole they left is permanent until a complete state replaces it.
            isTruncated = false
            return tally([update.body] + drain())

        case .change:
            guard update.sequence > applied else {
                duplicates += 1
                return []
            }
            guard update.sequence == applied + 1, isFounded else {
                hold(update)
                return []
            }
            applied = update.sequence
            accepted += 1
            return tally([update.body] + drain())
        }
    }

    /// What is missing between here and the earliest entry being held.
    ///
    /// `nil` when nothing is being held, which is not the same as nothing being
    /// missing: an entry lost at the live edge looks identical to one that has
    /// not been published yet, and the way to find out is the next entry rather
    /// than a timer.
    public var missing: Range<UInt64>? {
        guard let earliest = held.keys.min() else { return nil }
        return (applied + 1) ..< earliest
    }

    /// Whether this reader is holding entries it cannot apply, or has thrown
    /// some away.
    ///
    /// The signal to repair, and the repair is a fetch of the current group,
    /// because that group starts with a snapshot.
    public var needsSnapshot: Bool { !held.isEmpty || isTruncated || !isFounded }

    /// How many entries are waiting on a gap.
    public var holding: Int { held.count }

    /// Note which of the entries about to be applied this build cannot read.
    ///
    /// Counted on the way out rather than at decode, so an entry held for a gap
    /// is counted when it is applied and not twice.
    private mutating func tally(_ bodies: [RoomUpdate.Body]) -> [RoomUpdate.Body] {
        for body in bodies {
            if case .change(.unrecognised) = body { unrecognised += 1 }
        }
        return bodies
    }

    private mutating func hold(_ update: RoomUpdate) {
        guard held.count < policy.buffer else {
            isTruncated = true
            return
        }
        held[update.sequence] = update.body
    }

    private mutating func drain() -> [RoomUpdate.Body] {
        var ready: [RoomUpdate.Body] = []
        while let next = held.removeValue(forKey: applied + 1) {
            applied += 1
            accepted += 1
            ready.append(next)
        }
        return ready
    }
}

// MARK: - Wire form

public extension RoomUpdate {
    /// The control track's name within a room's namespace.
    ///
    /// A leading marker, like the catalog's, so it cannot collide with a track
    /// an application names. It lives under the room prefix itself — which has
    /// no participant fields after it, so a client deriving a roster from
    /// announcements cannot read the room's own control track as a person.
    static let trackName = ".control"

    /// Sorted keys, so equal states produce equal bytes.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> RoomUpdate {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RoomUpdate.self, from: data)
    }
}

extension RoomUpdate: Codable {
    private enum Key: String, CodingKey {
        case version
        case sequence
        case snapshot
        case change
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        version = try container.decode(Int.self, forKey: .version)
        sequence = try container.decode(UInt64.self, forKey: .sequence)
        if let snapshot = try container.decodeIfPresent(RoomSnapshot.self, forKey: .snapshot) {
            body = .snapshot(snapshot)
        } else {
            body = .change(try container.decode(RoomChange.self, forKey: .change))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(version, forKey: .version)
        try container.encode(sequence, forKey: .sequence)
        switch body {
        case let .snapshot(snapshot):
            try container.encode(snapshot, forKey: .snapshot)
        case let .change(change):
            try container.encode(change, forKey: .change)
        }
    }
}

extension RoomChange: Codable {
    private enum Key: String, CodingKey {
        case change
        case identity
        case grants
        case presence
        case forEveryone
        case forAudience
        case stage
        case lifecycle
        case watchdogs
        case audiences
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        let kind = try container.decode(String.self, forKey: .change)

        func subject() throws -> ParticipantIdentity {
            try container.decode(ParticipantIdentity.self, forKey: .identity)
        }

        switch kind {
        case "grants":
            self = .grants(try subject(), try container.decode(Grants.self, forKey: .grants))
        case "presence":
            self = .presence(try subject(), try container.decode(Presence.self, forKey: .presence))
        case "mute":
            self = .mute(
                try subject(),
                forEveryone: try container.decode(MediaKind.self, forKey: .forEveryone),
                forAudience: try container.decode(MediaKind.self, forKey: .forAudience)
            )
        case "spotlight":
            // Absent rather than null clears it, so "nobody is spotlighted" and
            // "this writer does not know about spotlights" cannot be told apart
            // — which is correct: both mean draw no spotlight.
            self = .spotlight(
                try container.decodeIfPresent(ParticipantIdentity.self, forKey: .identity)
            )
        case "stage":
            self = .stage(try container.decode(StageSnapshot.self, forKey: .stage))
        case "lifecycle":
            self = .lifecycle(try container.decode(RoomLifecycle.self, forKey: .lifecycle))
        case "watchdogs":
            self = .watchdogs(try container.decode([Watchdog].self, forKey: .watchdogs))
        case "evicted":
            self = .evicted(try subject())
        case "audiences":
            self = .audiences(try container.decode(Audiences.self, forKey: .audiences))
        case let other:
            // Skipped rather than thrown, so a build that predates a case still
            // tracks the room. Throwing here reaches the caller as an undecodable
            // object, which does not advance the log's sequence, which is a hole
            // that only a snapshot closes — and the next entry of the same new
            // kind reopens it. See the note at the top of this file.
            self = .unrecognised(other)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        switch self {
        case let .grants(identity, grants):
            try container.encode("grants", forKey: .change)
            try container.encode(identity, forKey: .identity)
            try container.encode(grants, forKey: .grants)
        case let .presence(identity, presence):
            try container.encode("presence", forKey: .change)
            try container.encode(identity, forKey: .identity)
            try container.encode(presence, forKey: .presence)
        case let .mute(identity, forEveryone, forAudience):
            try container.encode("mute", forKey: .change)
            try container.encode(identity, forKey: .identity)
            try container.encode(forEveryone, forKey: .forEveryone)
            try container.encode(forAudience, forKey: .forAudience)
        case let .spotlight(identity):
            try container.encode("spotlight", forKey: .change)
            try container.encodeIfPresent(identity, forKey: .identity)
        case let .stage(stage):
            try container.encode("stage", forKey: .change)
            try container.encode(stage, forKey: .stage)
        case let .lifecycle(lifecycle):
            try container.encode("lifecycle", forKey: .change)
            try container.encode(lifecycle, forKey: .lifecycle)
        case let .watchdogs(watchdogs):
            try container.encode("watchdogs", forKey: .change)
            try container.encode(watchdogs, forKey: .watchdogs)
        case let .evicted(identity):
            try container.encode("evicted", forKey: .change)
            try container.encode(identity, forKey: .identity)
        case let .audiences(audiences):
            try container.encode("audiences", forKey: .change)
            try container.encode(audiences, forKey: .audiences)
        case let .unrecognised(kind):
            // Lossy, and only reachable by re-encoding something decoded by an
            // older build. Kept writable rather than made to throw so that
            // holding a log entry in a value type does not become a trap.
            try container.encode(kind, forKey: .change)
        }
    }
}
