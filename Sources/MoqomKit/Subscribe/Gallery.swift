// Which participants get a box, in what order, and what happens to the rest.
//
// Sixteen tiles is not sixteen decoders. A phone will not decode sixteen
// simultaneous 1080p streams, and asking it to is not a performance problem but
// a hard failure: `VideoToolbox` refuses the session and the tile stays black.
// What makes sixteen work is that sixteen tiles are small — a 16-up grid on a
// phone is about 90x160 points per tile — so the ladder serves each one its
// bottom rung and the decode cost falls with the resolution. The box count and
// the layer choice are therefore the same decision made twice, which is why
// this type feeds ``SubscriptionPlanner`` rather than sitting beside it.
//
// The problem it exists to solve is who gets left out. Twenty cohosts and
// sixteen boxes means four people have no tile, and the obvious implementations
// pick the wrong four:
//
//   - Roster order picks them alphabetically, and they stay picked. A cohost
//     called Zoe is invisible for the whole broadcast, including while she is
//     the only one talking.
//   - Drawn area, which is what the planner used on its own, cannot break the
//     tie: every tile in a uniform grid is the same size, so it falls through
//     to the identity string and lands back on alphabetical.
//   - Pure active-speaker order picks correctly and reshuffles constantly. Every
//     tile move costs an unsubscribe, a subscribe and a wait for a keyframe, so
//     the grid flickers black while faces jump between positions. This is the
//     single most complained-about behaviour in every product that ships it.
//
// So: rank by claim, but treat holding a box as a claim in itself. An occupant
// keeps its box for at least ``Policy/dwell`` whatever else happens, and keeps
// its *position* for as long as it holds the box. Speech changes who is on
// screen; it does not rearrange the people already there.

import Foundation
import MoqomCore

/// The occupants of a bounded set of tiles, and the order to draw them in.
///
/// Drives both layouts the SDK supports. A video grid bounds occupancy by what
/// the device can decode; an audio room bounds it by how many seats the design
/// draws, which is a much larger number because an avatar costs nothing. The
/// ordering, the stability and the promotion-on-speech behaviour are identical,
/// and were not worth writing twice.
public struct Gallery: Sendable {
    /// The most video tiles this will ever hand out.
    ///
    /// A decode bound, not a layout one. Sixteen concurrent hardware decode
    /// sessions is optimistic on older hardware even at the bottom rung, so this
    /// is the ceiling a caller may ask for rather than a number to default to —
    /// and a client under thermal pressure should be lowering ``Policy/boxes``,
    /// not discovering this limit.
    public static let maximumVideoBoxes = 16

    public enum Kind: String, Hashable, Sendable {
        /// Tiles carry decoded video, so occupancy is bounded by the decoder.
        case video

        /// Seats carry an avatar and a speaking ring. Audio is subscribed for
        /// everyone on stage regardless of seating, because a speaker nobody can
        /// hear is not a layout state anybody wants.
        case audio
    }

    public struct Policy: Hashable, Sendable {
        public var kind: Kind

        /// How many tiles the layout draws.
        public var boxes: Int

        /// The shortest time a box is held before it can be taken away.
        ///
        /// The churn bound. With sixteen boxes and a three-second dwell, the
        /// worst case is sixteen tile changes every three seconds; without it, a
        /// room where four people are interrupting each other rearranges on
        /// every syllable. Three seconds is long enough to read a name and short
        /// enough that a new speaker appears while they are still talking.
        public var dwell: Duration

        public init(kind: Kind = .video, boxes: Int = 9, dwell: Duration = .seconds(3)) {
            self.kind = kind
            self.boxes = boxes
            self.dwell = dwell
        }

        /// Occupancy after the decode ceiling is applied.
        public var capacity: Int {
            switch kind {
            case .video: max(0, min(boxes, Gallery.maximumVideoBoxes))
            case .audio: max(0, boxes)
            }
        }

        /// A grid of video tiles.
        public static func grid(boxes: Int = 9) -> Policy {
            Policy(kind: .video, boxes: boxes)
        }

        /// A seated audio room: many speakers, no video, and a dwell long enough
        /// that seats do not shuffle during a conversation.
        ///
        /// Seats are not the stage limit. ``StageState/slotLimit`` decides how
        /// many people may publish; this decides how many of them the design
        /// draws before the rest become a summary row.
        public static func audioRoom(seats: Int = 12) -> Policy {
            Policy(kind: .audio, boxes: seats, dwell: .seconds(10))
        }
    }

    /// Why a participant holds a box, strongest last.
    ///
    /// Ordered by declaration, so the synthesised comparison is the ranking.
    /// ``spoke(at:)`` compares by recency, which is what puts the person who
    /// talked ten seconds ago above the person who has not talked at all.
    public enum Claim: Hashable, Sendable, Comparable {
        /// Not connected. Keeps a box while one is spare — a cohost in a lift
        /// should still have a tile saying so — and is first to lose it.
        case absent

        /// Here, and has never been heard.
        case present

        /// Silent now, voiced at this time.
        case spoke(at: MonotonicTime)

        case speaking

        /// This viewer asked for them, and it never leaves the device.
        case pinned

        /// The room asked for them. Above ``pinned`` because the host's framing
        /// of their own broadcast should outrank a viewer's preference about
        /// where to look — both are guaranteed a box, so this only decides which
        /// comes first.
        case spotlighted
    }

    public struct Slot: Hashable, Sendable, Identifiable {
        public let identity: ParticipantIdentity
        public let claim: Claim

        /// Live now. Separate from ``claim`` because a pinned participant who is
        /// talking has a claim of ``Claim/pinned`` and still needs a ring.
        public let isSpeaking: Bool

        /// Pulled to the front of the layout rather than holding a stable
        /// position, which is what a spotlight is for.
        public var isFeatured: Bool { claim >= .pinned }

        public var id: ParticipantIdentity { identity }
    }

    public var policy: Policy

    /// Participants that never get a box.
    ///
    /// The local participant belongs here: their camera is a self view drawn
    /// from the capture session, not a subscription to their own upload.
    public var excluded: Set<ParticipantIdentity> = []

    public private(set) var pinned: Set<ParticipantIdentity> = []

    /// The occupants, in the order to draw them.
    public private(set) var slots: [Slot] = []

    /// Everyone in the room without a box, strongest claim first.
    ///
    /// Not an error state and not hidden: these participants keep their audio —
    /// the planner drops video for them and ``LayerSelectionPolicy`` keeps the
    /// audio subscription — so the room stays audible while the grid stays
    /// within what the device can decode. A UI showing "+4" draws it from here.
    public private(set) var overflow: [ParticipantIdentity] = []

    /// Stable position per occupant, so a tile does not move while it is held.
    private var seats: [ParticipantIdentity: Int] = [:]

    /// When each occupant was granted its box, for the dwell test.
    private var granted: [ParticipantIdentity: MonotonicTime] = [:]

    public init(policy: Policy = .grid()) {
        self.policy = policy
    }

    /// The occupants in draw order, which is the order the planner ranks
    /// subscriptions by. Read from the same place so the relay sheds the tile
    /// the layout considers least important rather than a different one.
    public var order: [ParticipantIdentity] { slots.map(\.identity) }

    public func isPinned(_ identity: ParticipantIdentity) -> Bool {
        pinned.contains(identity)
    }

    /// Guarantee this participant a box.
    ///
    /// Takes effect at the next ``update(_:speakers:at:)`` rather than
    /// immediately, so a pin during a layout pass cannot produce a gallery that
    /// disagrees with the subscriptions until the next one.
    public mutating func pin(_ identity: ParticipantIdentity) {
        pinned.insert(identity)
    }

    public mutating func unpin(_ identity: ParticipantIdentity) {
        pinned.remove(identity)
    }

    /// Recompute occupancy and order.
    ///
    /// - Returns: Whether anything changed, so a caller can drive this from a
    ///   timer without republishing state or reissuing subscriptions.
    @discardableResult
    public mutating func update(
        _ roster: Roster,
        speakers: ActiveSpeakers,
        at now: MonotonicTime
    ) -> Bool {
        // Backstage is excluded rather than ranked. A guest waiting to go live
        // is drawn in a separate strip to the hosts who can see them, and
        // putting them in the same collection as the stage is how a guest ends
        // up on air a promotion early.
        let candidates = roster.participants.filter {
            !excluded.contains($0.id) && !$0.slot.isBackstage
        }

        let ranked = candidates
            .map { (participant: $0, claim: claim(for: $0, speakers: speakers)) }
            .sorted { lhs, rhs in
                if lhs.claim != rhs.claim { return lhs.claim > rhs.claim }
                return (lhs.participant.username.value, lhs.participant.device.value)
                    < (rhs.participant.username.value, rhs.participant.device.value)
            }

        // Lower is stronger. Anyone absent from the room ranks below everyone.
        var strength: [ParticipantIdentity: Int] = [:]
        for (index, entry) in ranked.enumerated() {
            strength[entry.participant.id] = index
        }

        let capacity = policy.capacity
        let wanted = Set(ranked.prefix(capacity).map(\.participant.id))
        let present = Set(candidates.map(\.id))

        // Departures free their box immediately. Dwell protects an occupant from
        // being displaced, not from having left.
        var occupants = Set(seats.keys).intersection(present)

        // A reduced box count is a hard bound and ignores dwell: the layout has
        // already stopped drawing the tile.
        while occupants.count > capacity {
            guard let weakest = weakest(of: occupants, by: strength) else { break }
            occupants.remove(weakest)
        }

        // Spare boxes go to the strongest claims, in rank order.
        for entry in ranked where occupants.count < capacity {
            occupants.insert(entry.participant.id)
        }

        // Full. A challenger strong enough to be wanted may take a box from an
        // occupant that is not, once that occupant has held it long enough.
        for entry in ranked where !occupants.contains(entry.participant.id) {
            let challenger = entry.participant.id
            guard wanted.contains(challenger) else { continue }
            let displaceable = occupants.filter { !wanted.contains($0) }
            guard let weakest = weakest(of: displaceable, by: strength) else { continue }

            // A pin or a spotlight takes effect now. Dwell is there to stop
            // *speech* from rearranging the grid, and making somebody wait three
            // seconds for the tile they just asked for would be applying it to
            // the wrong thing entirely.
            if entry.claim < .pinned {
                guard let since = granted[weakest], now - since >= policy.dwell else { continue }
            }

            occupants.remove(weakest)
            occupants.insert(challenger)
        }

        for identity in seats.keys where !occupants.contains(identity) {
            seats.removeValue(forKey: identity)
            granted.removeValue(forKey: identity)
        }

        // Seat newcomers in rank order, into the lowest free position, so two
        // participants arriving in the same pass are seated deterministically.
        for entry in ranked where occupants.contains(entry.participant.id) {
            let identity = entry.participant.id
            guard seats[identity] == nil else { continue }
            let taken = Set(seats.values)
            var seat = 0
            while taken.contains(seat) { seat += 1 }
            seats[identity] = seat
            granted[identity] = now
        }

        let nextSlots = ranked
            .filter { occupants.contains($0.participant.id) }
            .map {
                Slot(
                    identity: $0.participant.id,
                    claim: $0.claim,
                    isSpeaking: speakers.isSpeaking($0.participant.id)
                )
            }
            .sorted { lhs, rhs in
                if lhs.isFeatured != rhs.isFeatured { return lhs.isFeatured }
                if lhs.isFeatured, lhs.claim != rhs.claim { return lhs.claim > rhs.claim }
                return (seats[lhs.identity] ?? 0) < (seats[rhs.identity] ?? 0)
            }

        let nextOverflow = ranked
            .map(\.participant.id)
            .filter { !occupants.contains($0) }

        let changed = nextSlots != slots || nextOverflow != overflow
        slots = nextSlots
        overflow = nextOverflow
        return changed
    }

    private func claim(for participant: Participant, speakers: ActiveSpeakers) -> Claim {
        if participant.isSpotlighted { return .spotlighted }
        if pinned.contains(participant.id) { return .pinned }

        // Checked before speech so that a participant who dropped mid-sentence
        // becomes the first candidate for eviction instead of holding a box on
        // the strength of audio that stopped arriving.
        guard participant.presence == .connected else { return .absent }

        if speakers.isSpeaking(participant.id) { return .speaking }
        if let last = speakers.lastSpoke(participant.id) { return .spoke(at: last) }
        return .present
    }

    private func weakest(
        of identities: some Collection<ParticipantIdentity>,
        by strength: [ParticipantIdentity: Int]
    ) -> ParticipantIdentity? {
        identities.max { lhs, rhs in
            let left = strength[lhs] ?? .max
            let right = strength[rhs] ?? .max
            if left != right { return left < right }
            return lhs.description > rhs.description
        }
    }
}
