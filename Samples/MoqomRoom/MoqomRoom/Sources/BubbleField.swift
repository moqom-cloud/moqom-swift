// The game two people play in the shared space.
//
// Everything here runs on whichever device is currently the authority, and on
// no other. That is worth stating plainly because it is the opposite of how a
// shared AR demo is usually written: there is no local simulation to reconcile,
// no interpolation between two devices' guesses, and no rule that has to
// produce the same answer on both phones. One phone decides where the bubbles
// are, the other draws what it is told, and they swap roles without either of
// them noticing.
//
// # Bubbles rather than a ball
//
// A ball is the obvious shared-space demo and a bad first one: it is a single
// entity, so it exercises none of the interesting parts and looks correct even
// when the replication is barely working. A field of bubbles spawns and removes
// entities continuously, gives two people something to race each other for, and
// makes a dropped update visible immediately — a bubble that pops on one phone
// and not the other is not a subtle failure.
//
// # Why a pop is an intent and a spawn is not
//
// Only the authority spawns, because a bubble nobody agreed on is a bubble the
// other phone would not have. Anybody may pop, because that is the game — and a
// pop from the follower travels as a ``SpaceIntent``, arrives at the authority,
// and comes back as the bubble being gone. The follower does not wait for that
// round trip to animate it; see the note on ``ARSceneSource`` for why guessing
// is safe here and would not be for a spawn.

import Foundation
import MoqomCore
import MoqomKit

/// A field of rising bubbles, shared by everyone in the room.
///
/// Not an actor and not `Sendable` by inspection: every method is called by
/// ``SpaceSession`` from inside its own actor, which serialises them, and there
/// is deliberately no other way in. Anything the interface wants to know it
/// learns from the replicated state, not from here.
final class BubbleField: SpaceSimulation, @unchecked Sendable {
    /// What the game is made of, in space coordinates — metres of an invented
    /// room, not of anybody's real one. See `SpaceAnchor`.
    enum Field {
        /// Half the width and half the depth of the volume bubbles occupy.
        static let reach: Float = 0.55

        /// Where bubbles are released and where they burst on their own.
        static let floor: Float = 0.05
        static let ceiling: Float = 1.35

        /// The drawn size of a bubble at scale 1.
        static let radius: Float = 0.075
    }

    struct Rules: Sendable {
        /// How many bubbles may exist at once.
        ///
        /// Twelve. The number is a bandwidth decision as much as a design one:
        /// every live bubble is a pose on every tick, so this is the knob that
        /// decides what the space costs on a link already carrying a call.
        var capacity = 12

        /// How often a new one is released, while there is room.
        var spawnEvery = Duration.milliseconds(650)

        /// Metres a second upwards.
        var rise: Float = 0.19

        /// How far a bubble wanders sideways as it climbs.
        var drift: Float = 0.06

        static let `default` = Rules()
    }

    private let rules: Rules
    private var sinceSpawn = Duration.zero

    /// Distinguishes this authority's bubbles from its predecessor's.
    ///
    /// Identifiers must not be reused across a handover: a delta naming
    /// `b-4` while a viewer still holds the last authority's `b-4` is two
    /// different bubbles wearing one name, and the viewer would move the wrong
    /// one. A short random stem costs four bytes in the snapshot that
    /// introduces it and nothing after, since the wire interns names.
    private var stem = ""
    private var minted = 0

    /// Where each bubble is going, which is not replicated.
    ///
    /// Deliberately local to the authority. Velocity is derivable from
    /// successive poses by anyone who cares, and sending it would put a second
    /// copy of the truth on the wire for every bubble on every tick.
    private var courses: [SpaceEntityID: Course] = [:]

    private struct Course {
        var sway: Float
        var phase: Float
        var speed: Float
    }

    init(rules: Rules = .default) {
        self.rules = rules
    }

    // MARK: - Being the authority

    func opening(_ state: inout SpaceSnapshot, at _: Timecode) {
        stem = String(UInt32.random(in: 0 ..< 1_000_000), radix: 36)
        minted = 0
        sinceSpawn = .zero

        // Whatever the last authority left is kept, so a handover looks like
        // nothing happened rather than like the game restarting. They are given
        // courses of their own because the old authority's were never sent.
        courses = [:]
        for id in state.entities.keys where state.entities[id]?.kind == Self.kind {
            courses[id] = Self.course()
        }
    }

    func step(_ state: inout SpaceSnapshot, at now: Timecode, since elapsed: Duration) {
        let seconds = Float(elapsed.wholeNanoseconds) / 1_000_000_000
        guard seconds > 0, seconds < 1 else { return }

        var burst: [SpaceEntityID] = []
        for (id, entity) in state.entities where entity.kind == Self.kind {
            guard var course = courses[id] else {
                courses[id] = Self.course()
                continue
            }
            course.phase += seconds
            courses[id] = course

            var pose = entity.pose
            pose.position.y += course.speed * seconds
            // Sideways motion from the bubble's own phase rather than from a
            // random walk, so that a viewer interpolating between two updates
            // is interpolating along the path rather than across a jitter.
            pose.position.x += sin(course.phase * 1.7) * course.sway * seconds
            pose.position.z += cos(course.phase * 1.1) * course.sway * seconds

            if pose.position.y > Field.ceiling {
                burst.append(id)
            } else {
                state.entities[id]?.pose = pose
            }
        }
        for id in burst {
            state.entities.removeValue(forKey: id)
            courses.removeValue(forKey: id)
        }

        sinceSpawn += elapsed
        let living = state.entities.values.count { $0.kind == Self.kind }
        if sinceSpawn >= rules.spawnEvery, living < rules.capacity {
            sinceSpawn = .zero
            release(into: &state, at: now)
        }
    }

    func apply(
        _ intent: SpaceIntent,
        from who: ParticipantIdentity,
        to state: inout SpaceSnapshot,
        at _: Timecode
    ) {
        switch intent.verb {
        case Self.pop:
            guard
                let subject = intent.subject,
                state.entities[subject]?.kind == Self.kind
            else {
                // Already gone, which is the ordinary outcome of two people
                // reaching for the same bubble. The loser scores nothing and
                // finds out by the bubble not being there, which is what they
                // are already looking at.
                return
            }
            state.entities.removeValue(forKey: subject)
            courses.removeValue(forKey: subject)
            score(who, in: &state)
        default:
            break
        }
    }

    // MARK: - Bubbles

    private func release(into state: inout SpaceSnapshot, at now: Timecode) {
        minted += 1
        let id = SpaceEntityID("b-\(stem)-\(minted)")
        let position = SpaceVector(
            x: Float.random(in: -Field.reach ... Field.reach),
            y: Field.floor,
            z: Float.random(in: -Field.reach ... Field.reach)
        )
        state.entities[id] = SpaceEntity(
            id: id,
            kind: Self.kind,
            pose: SpacePose(
                position: position,
                rotation: .identity,
                // Carried as the pose's scale rather than as a fact, because it
                // is already in the eight floats every pose costs and a fact
                // would be a string key beside it.
                scale: Float.random(in: 0.75 ... 1.3)
            ),
            facts: [
                "hue": .decimal(Double.random(in: 0 ... 1)),
                "born": .number(now.nanoseconds),
            ]
        )
        courses[id] = Self.course()
    }

    private static func course() -> Course {
        Course(
            sway: Float.random(in: 0.4 ... 1.2),
            phase: Float.random(in: 0 ..< 6.28),
            speed: Float.random(in: 0.75 ... 1.25) * Rules.default.rise
        )
    }

    private func score(_ who: ParticipantIdentity, in state: inout SpaceSnapshot) {
        let key = Self.scoreKey(for: who)
        let current: Int64 = if case let .number(value) = state.facts[key] { value } else { 0 }
        state.facts[key] = .number(current + 1)
    }
}

extension BubbleField {
    /// What a bubble is called on the wire.
    static let kind = "bubble"

    /// The one verb this game understands.
    static let pop = "pop"

    /// Where a participant's score lives in the space's facts.
    ///
    /// A key per player rather than one table, so two people scoring in the
    /// same tick produce two independent values instead of two writes to one.
    static func scoreKey(for who: ParticipantIdentity) -> String {
        "score/\(who.username.value)/\(who.device.value)"
    }

    /// Everybody who has scored, best first.
    static func standings(in state: SpaceSnapshot) -> [(who: String, score: Int)] {
        state.facts
            .compactMap { key, value -> (String, Int)? in
                guard key.hasPrefix("score/"), case let .number(count) = value else { return nil }
                let name = key.dropFirst("score/".count).prefix { $0 != "/" }
                return (String(name), Int(count))
            }
            .sorted { ($0.1, $0.0) > ($1.1, $1.0) }
            .map { (who: $0.0, score: $0.1) }
    }

    /// The bubbles in a state, which is everything the renderer draws.
    static func bubbles(in state: SpaceSnapshot) -> [SpaceEntity] {
        state.entities.values.filter { $0.kind == kind }
    }
}
