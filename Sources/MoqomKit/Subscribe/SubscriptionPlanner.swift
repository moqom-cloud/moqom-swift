// Turns a set of render boxes into a set of subscription changes.
//
// This exists because of one transition: switching a grid to speaker view
// changes every tile at once, and emitting a subscription request per tile
// produces a burst that arrives at the relay interleaved and out of order. The
// planner collects the whole layout into a single diff so the caller issues one
// batch, with the priorities already assigned relative to each other.
//
// Priority assignment is the second reason. Draft-19 subscriber priority lets a
// viewer rank tracks directly and the relay sheds the lowest first, which is
// exactly the right behaviour for a grid — but only if the ranking reflects the
// layout. Assigning it from the render box means the speaker outranks the
// thumbnails automatically, rather than through a heuristic somebody has to
// keep in sync with the UI.
//
// Drawn area is the right ranking for a speaker view and no ranking at all for a
// uniform grid, where every tile is the same size and the comparison falls
// through to the identity string. Sixteen equal tiles ranked alphabetically
// means the relay sheds whoever is last in the alphabet, so a ``Gallery`` order
// can be supplied instead: it already knows who is speaking and who is pinned,
// and taking the ranking from the same place the layout took it from is what
// stops the two from disagreeing.

import Foundation
import MoqomCore

/// A subscription change to apply.
public enum SubscriptionChange: Hashable, Sendable {
    case subscribe(ParticipantIdentity, LayerID, priority: UInt8)
    case unsubscribeVideo(ParticipantIdentity)
    case reprioritise(ParticipantIdentity, priority: UInt8)

    /// Who the change is about.
    public var target: ParticipantIdentity {
        switch self {
        case let .subscribe(who, _, _), let .unsubscribeVideo(who), let .reprioritise(who, _):
            who
        }
    }

    /// The change as log fields.
    public var fields: [LogField] {
        switch self {
        case let .subscribe(who, layer, priority):
            [
                LogField("action", .text("subscribe")),
                LogField("participant", .participant(who)),
                LogField("layer", .text(layer.value)),
                LogField("priority", .number(Int(priority))),
            ]
        case let .unsubscribeVideo(who):
            [
                LogField("action", .text("unsubscribe")),
                LogField("participant", .participant(who)),
            ]
        case let .reprioritise(who, priority):
            [
                LogField("action", .text("reprioritise")),
                LogField("participant", .participant(who)),
                LogField("priority", .number(Int(priority))),
            ]
        }
    }
}

/// Holds one selector per participant and produces batched diffs.
public struct SubscriptionPlanner: Sendable {
    private var selectors: [ParticipantIdentity: LayerSelector] = [:]
    private var boxes: [ParticipantIdentity: RenderBox] = [:]
    private var priorities: [ParticipantIdentity: UInt8] = [:]

    /// Bounds how many video tracks are decoded at once.
    ///
    /// The host count is bounded by what a client can decode, not by what the
    /// relay will carry — so when a stage exceeds this, the SDK degrades the
    /// overflow to audio rather than refusing to render the room.
    ///
    /// Set it to ``Gallery/Policy/capacity`` when a gallery is driving the
    /// layout. Holding the two independently is legal and means the planner
    /// silently drops video for tiles the gallery is still drawing.
    public var videoBudget: Int

    /// Subscribe to what each publisher offers and stop choosing.
    ///
    /// See ``LayerSelectionPolicy/followsPublisher``. Held here as well as on each selector
    /// because it has to reach the selectors made later — a participant who joins after this
    /// is set would otherwise be the one tile still adapting.
    public var followsPublisher: Bool {
        didSet {
            guard followsPublisher != oldValue else { return }
            for identity in selectors.keys {
                selectors[identity]?.policy.followsPublisher = followsPublisher
            }
        }
    }

    public init(videoBudget: Int = 9, followsPublisher: Bool = false) {
        self.videoBudget = videoBudget
        self.followsPublisher = followsPublisher
    }

    /// Register or replace the ladder a participant is offering.
    ///
    /// Callers restate a ladder far more often than it changes — a default goes
    /// in when somebody joins, the catalog replaces it, and every grants update
    /// restates whatever is current — so an unchanged ladder is left completely
    /// alone, and a changed one inherits the selection already in force.
    ///
    /// Both halves matter for the same reason. A fresh ``LayerSelector`` has no
    /// ``LayerSelector/current``, and the planner reads that to mean no
    /// subscription is live, so it emits no unsubscribe when the participant
    /// later loses their box. The track then keeps arriving for a tile nobody
    /// is drawing: no error, no log, just bandwidth.
    /// - Parameter provisional: whether this is a guess made before the participant said
    ///   anything. A guessed ladder is the right thing to size a box against and the wrong
    ///   thing to subscribe from when the publisher is the one choosing — see
    ///   ``LayerSelectionPolicy/followsPublisher``. Asking for the top of a guess means asking
    ///   for a track that was never published: the relay refuses it, and the tile stays black
    ///   until the catalog arrives and the plan is redone.
    public mutating func setLadder(
        _ ladder: LayerLadder,
        for identity: ParticipantIdentity,
        provisional: Bool = false
    ) {
        if let existing = selectors[identity] {
            guard existing.ladder != ladder || existing.ladderIsProvisional != provisional else {
                return
            }
            var replacement = LayerSelector(ladder: ladder)
            replacement.policy.followsPublisher = followsPublisher
            replacement.ladderIsProvisional = provisional
            replacement.adopt(existing.current)
            selectors[identity] = replacement
        } else {
            var selector = LayerSelector(ladder: ladder)
            selector.policy.followsPublisher = followsPublisher
            selector.ladderIsProvisional = provisional
            selectors[identity] = selector
        }
    }

    public mutating func remove(_ identity: ParticipantIdentity) {
        selectors.removeValue(forKey: identity)
        boxes.removeValue(forKey: identity)
        priorities.removeValue(forKey: identity)
    }

    /// Pre-warm a participant's higher layer on an interaction that signals
    /// intent, before the layout that will need it.
    public mutating func prewarm(_ identity: ParticipantIdentity, for box: RenderBox) {
        selectors[identity]?.prewarm(for: box)
    }

    /// Recompute the whole layout and return only what changed.
    ///
    /// `allowance` is per-track: the congestion controller's estimate is for
    /// the link, and dividing it across tracks is the planner's job because
    /// only the planner knows how many there are and how big each one is drawn.
    ///
    /// `order` is a ``Gallery/order``, and breaks ties in drawn area rather than
    /// replacing it. That distinction matters: in a speaker view the areas differ
    /// and are the better signal, and in a uniform grid they are all equal and
    /// carry none at all. Participants the order does not mention rank after
    /// everyone it does.
    public mutating func plan(
        boxes newBoxes: [ParticipantIdentity: RenderBox],
        order: [ParticipantIdentity] = [],
        linkBitrate: Int = .max
    ) -> [SubscriptionChange] {
        boxes = newBoxes

        var position: [ParticipantIdentity: Int] = [:]
        for (index, identity) in order.enumerated() { position[identity] = index }

        // Area first, so a speaker view still ranks the speaker above the
        // thumbnails; the gallery only decides what area cannot. Identity last,
        // so a redraw with two tiles the gallery does not distinguish either does
        // not reshuffle priorities and churn the relay.
        let ranked = newBoxes
            .filter { $0.value.visibility == .visible }
            .sorted { lhs, rhs in
                let lhsArea = lhs.value.pixelSize.pixelCount
                let rhsArea = rhs.value.pixelSize.pixelCount
                if lhsArea != rhsArea { return lhsArea > rhsArea }

                let left = position[lhs.key] ?? Int.max
                let right = position[rhs.key] ?? Int.max
                if left != right { return left < right }

                return lhs.key.description < rhs.key.description
            }

        let share = ranked.isEmpty || linkBitrate == .max
            ? Int.max
            : max(1, linkBitrate / ranked.count)

        var changes: [SubscriptionChange] = []
        var withinBudget = Set<ParticipantIdentity>()
        for (index, entry) in ranked.enumerated() where index < videoBudget {
            withinBudget.insert(entry.key)
        }

        for identity in selectors.keys.sorted(by: { $0.description < $1.description }) {
            guard var selector = selectors[identity] else { continue }
            let box = newBoxes[identity] ?? .hidden
            let effectiveBox = withinBudget.contains(identity) || box.visibility != .visible
                ? box
                : RenderBox(width: 0, height: 0, scale: box.scale, visibility: .offScreen)

            let allowance = NetworkAllowance(bitrate: share)
            let previous = selector.current
            let selection = selector.update(box: effectiveBox, allowance: allowance)
            selectors[identity] = selector

            let rank = ranked.firstIndex { $0.key == identity }
            let priority = Self.priority(forRank: rank)
            let priorityChanged = priorities[identity] != priority
            priorities[identity] = priority

            guard let selection else {
                if priorityChanged, previous?.video != nil {
                    changes.append(.reprioritise(identity, priority: priority))
                }
                continue
            }

            if let layer = selection.video {
                changes.append(.subscribe(identity, layer, priority: priority))
            } else if previous?.video != nil {
                changes.append(.unsubscribeVideo(identity))
            }
        }

        return changes
    }

    /// The selection currently in force for a participant.
    public func selection(for identity: ParticipantIdentity) -> LayerSelection? {
        selectors[identity]?.current
    }

    /// The last layout planned against.
    ///
    /// Readable so that a reconnect can put it back: the subscriptions are gone
    /// with the session but the tiles are still the size they were, and asking
    /// the application to restate a layout it never changed would mean a room
    /// that comes back without video.
    public var layout: [ParticipantIdentity: RenderBox] { boxes }

    /// Map layout rank onto draft-19 subscriber priority, where lower is more
    /// urgent. Spread out rather than sequential so a later insertion between
    /// two tiles does not require renumbering everything after it.
    private static func priority(forRank rank: Int?) -> UInt8 {
        guard let rank else { return 255 }
        return UInt8(min(250, 16 + rank * 8))
    }
}
