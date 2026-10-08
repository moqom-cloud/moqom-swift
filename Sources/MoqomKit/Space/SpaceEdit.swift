// The four things any participant can ask of a space without the application
// writing a simulation first.
//
// ``SpaceSimulation`` is the right shape for a game with rules, and the wrong
// shape for the first ten minutes with this SDK: a board where people put pieces
// down, slide them about, and shout "check" should not need a protocol
// conformance. So spawning, moving, despawning, and sending an event are built
// in. They travel as ordinary intents under reserved verbs, are applied by
// whoever is simulating, and pass through ``SpaceSimulation/permits(_:from:in:)``
// first — which is where a game with rules says no.

import Foundation
import MoqomCore

/// A change any participant can ask a space for.
public enum SpaceEdit: Hashable, Sendable {
    /// Put a new thing in the space, or replace one with the same name.
    case spawn(SpaceEntity)

    /// Put an existing thing somewhere else. Absolute, like every pose.
    case move(SpaceEntityID, SpacePose)

    /// Take a thing out.
    case despawn(SpaceEntityID)

    /// Something happened. Ordered and delivered exactly once to everybody.
    case event(SpaceGameEvent)
}

extension SpaceEdit {
    /// The verbs these travel under. Prefixed so that no game's own verb can
    /// collide with them.
    enum Verb {
        static let spawn = "moqom.spawn"
        static let move = "moqom.move"
        static let despawn = "moqom.despawn"
        static let event = "moqom.event"
    }

    /// The intent that asks for this.
    func intent() -> SpaceIntent {
        switch self {
        case let .spawn(entity):
            SpaceIntent(
                verb: Verb.spawn,
                subject: entity.id,
                facts: entity.facts,
                kind: entity.kind,
                pose: entity.pose
            )
        case let .move(id, pose):
            SpaceIntent(verb: Verb.move, subject: id, pose: pose)
        case let .despawn(id):
            SpaceIntent(verb: Verb.despawn, subject: id)
        case let .event(event):
            SpaceIntent(
                verb: Verb.event,
                subject: event.subject,
                facts: event.facts,
                kind: event.name
            )
        }
    }

    /// The edit an intent asks for, or `nil` for an application's own verb.
    ///
    /// A reserved verb missing what it needs is also `nil`, and then reaches
    /// nobody: it is not the application's, and it is not well-formed.
    init?(_ intent: SpaceIntent) {
        switch intent.verb {
        case Verb.spawn:
            guard let id = intent.subject, let kind = intent.kind else { return nil }
            self = .spawn(SpaceEntity(
                id: id,
                kind: kind,
                pose: intent.pose ?? .identity,
                facts: intent.facts
            ))
        case Verb.move:
            guard let id = intent.subject, let pose = intent.pose else { return nil }
            self = .move(id, pose)
        case Verb.despawn:
            guard let id = intent.subject else { return nil }
            self = .despawn(id)
        case Verb.event:
            guard let name = intent.kind else { return nil }
            self = .event(SpaceGameEvent(name, subject: intent.subject, facts: intent.facts))
        default:
            return nil
        }
    }

    /// Whether this is a reserved verb at all, well-formed or not.
    static func isReserved(_ verb: String) -> Bool {
        verb.hasPrefix("moqom.")
    }

    /// Fold this into a state, collecting the event if it is one.
    func apply(
        to state: inout SpaceSnapshot,
        from who: ParticipantIdentity,
        emitting events: inout [(SpaceGameEvent, ParticipantIdentity?)]
    ) {
        switch self {
        case let .spawn(entity):
            state.entities[entity.id] = entity
        case let .move(id, pose):
            state.entities[id]?.pose = pose
        case let .despawn(id):
            state.entities.removeValue(forKey: id)
        case let .event(event):
            events.append((event, who))
        }
    }
}

/// A space with no rules: whatever anybody spawns, moves, or sends, happens.
///
/// The simulation to start with, and enough on its own for a board where the
/// players are the rules — chess with friends, a shared sketch, pieces on a
/// table. Replace it with a ``SpaceSimulation`` of your own when the game needs
/// to say no to something.
public struct OpenSpace: SpaceSimulation {
    public init() {}

    public func step(_: inout SpaceSnapshot, at _: Timecode, since _: Duration) {}
}
