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
//
// # Nothing sends a position
//
// A bubble's whole path is a function of its name, where it was released and
// how old it is — ``course(for:)`` and ``position(spawnedAt:as:after:)``, which
// both devices evaluate and neither transmits. So a tick carries a spawn, a
// pop, or nothing at all, and the field costs a few bytes a second instead of
// twelve poses twenty times a second.
//
// It began as a bandwidth argument and turned into a correctness one. Poses on
// the wire arrive at the tick rate, and a renderer that writes them is a
// renderer whose motion is only as smooth as the network was — which on a phone
// that redraws when it feels like it looked like the whole field jumping once a
// second. A path nobody has to receive cannot stutter.
//
// The cost is that the two sides must agree exactly, which is why the course is
// hashed from the name rather than drawn at random, and why the path is a
// closed form rather than an integration. A stepped simulation gives a
// different answer to a device that asked at a different moment.

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

        /// Where bubbles are released, and where they give up on being caught.
        ///
        /// Nothing bursts at the ceiling. A bubble that gets past it is a
        /// bubble that got away, which is a different thing to watch and a
        /// different thing to feel: the only pops in the game are the ones
        /// somebody's finger caused, so a score is the whole story of the round
        /// rather than a share of whatever happened to be reachable.
        static let floor: Float = 0.05
        static let ceiling: Float = 1.35

        /// How far above the ceiling a bubble is still drawn while leaving.
        ///
        /// Far enough to be out of the shot on any sensible placement. It is
        /// removed there rather than at the ceiling so that the escape is
        /// something the player sees happen, not something they infer from a
        /// bubble that stopped existing at head height.
        static let departure: Float = 2.4

        /// The drawn size of a bubble at scale 1.
        static let radius: Float = 0.075
    }

    /// The numbers behind the game.
    ///
    /// Only ``capacity`` and ``spawnEvery`` are the authority's to choose. The
    /// rest describe the path, and a path is computed on both devices from
    /// ``Rules/default`` — so an authority that changed ``rise`` would be the
    /// only one that knew, and would start removing bubbles the other phone
    /// could still see. They live here because they belong with the numbers
    /// beside them, not because they are configurable.
    struct Rules: Sendable {
        /// How many bubbles may exist at once.
        ///
        /// Twelve, which is now purely a design number. It was also a bandwidth
        /// one when every live bubble cost a pose on every tick; a bubble in
        /// flight costs nothing per tick at all.
        var capacity = 12

        /// How often a new one is released, while there is room.
        var spawnEvery = Duration.milliseconds(650)

        /// Metres a second upwards, before the per-bubble spread in
        /// ``BubbleField/course(for:)``.
        var rise: Float = 0.19

        /// Metres a second squared, once a bubble is past the ceiling.
        ///
        /// An escape should read as an escape rather than as the same slow
        /// climb continuing off the top of the shot — a player who cannot tell
        /// that a bubble is going will not hurry, and hurrying is the game.
        ///
        /// An acceleration rather than the per-second multiplier it was, so
        /// that the climb has a closed form. A rate compounded once a tick
        /// gives a different height to a device that ticked at a different
        /// rate, and both sides now compute this for themselves.
        var flight: Float = 0.6

        static let `default` = Rules()
    }

    /// How long a round lasts.
    ///
    /// A field that never ends is a demo rather than a game: nothing is won, so
    /// there is no reason to hurry, and hurrying is the whole of it. Thirty
    /// seconds is long enough for a lead to change hands and short enough to be
    /// played twice while somebody is still holding the phone.
    ///
    /// Nothing starts the next one but somebody asking. A clock that restarted
    /// by itself would begin a round while both players were still reading the
    /// last one's score, and the first few seconds of a round nobody is looking
    /// at are the ones that decide it.
    static let roundLength = Duration.seconds(30)

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

    init(rules: Rules = .default) {
        self.rules = rules
    }

    // MARK: - Being the authority

    func opening(_ state: inout SpaceSnapshot, at _: Timecode) {
        stem = String(UInt32.random(in: 0 ..< 1_000_000), radix: 36)
        minted = 0
        sinceSpawn = .zero

        // Whatever the last authority left is kept, so a handover looks like
        // nothing happened rather than like the game restarting. Nothing has to
        // be reconstructed for them: a bubble's path comes from its name, so
        // the incoming authority already knows where every one of them is
        // going. The round in progress is in the state for the same reason.
    }

    func step(_ state: inout SpaceSnapshot, at now: Timecode, since elapsed: Duration) {
        let seconds = Float(elapsed.wholeNanoseconds) / 1_000_000_000
        guard seconds > 0, seconds < 1 else { return }

        // The first round starts because somebody went live. Every round after
        // it starts because somebody asked — see ``rematch``.
        let round = Self.round(in: state) ?? begin(1, in: &state, at: now)
        let playing = now.nanoseconds < round.ends

        // Nothing below integrates a position or writes one. Where a bubble is
        // follows from its name and its age, which both devices can work out,
        // so all a tick has to decide is which bubbles are still in the field.
        var gone: [SpaceEntityID] = []
        for (id, entity) in state.entities where entity.kind == Self.kind {
            let leaving = entity.facts[Self.leaving] != nil

            guard playing else {
                // The final whistle. Flagged on one tick and taken on the next,
                // because a delta that both flags and removes carries only the
                // removal — and a renderer that did not learn these were
                // unclaimed would burst every one of them as though the round
                // had ended in a flurry of scoring.
                if leaving {
                    gone.append(id)
                } else {
                    state.entities[id]?.facts[Self.leaving] = .flag(true)
                }
                continue
            }

            let height = Self.position(of: entity, as: id, at: now).y
            if height > Field.departure, leaving {
                gone.append(id)
                continue
            }

            // Said once, and said on the entity rather than inferred from its
            // height by the renderer. A viewer that worked it out for itself
            // would be reimplementing the rule, and the two copies would
            // disagree the first time either number moved — with the visible
            // result being a bubble that pops on one phone and drifts off the
            // top of the other.
            if height > Field.ceiling, !leaving {
                state.entities[id]?.facts[Self.leaving] = .flag(true)
            }
        }
        for id in gone {
            state.entities.removeValue(forKey: id)
        }

        sinceSpawn += elapsed
        // Bubbles on their way out do not count against the field. They are
        // above the shot and unreachable, and holding a place open for them
        // would empty the playable part of the field for as long as they take
        // to leave — which is exactly when there is nothing left to tap.
        let catchable = state.entities.values.count {
            $0.kind == Self.kind && $0.facts[Self.leaving] == nil
        }
        if playing, sinceSpawn >= rules.spawnEvery, catchable < rules.capacity {
            sinceSpawn = .zero
            release(into: &state, at: now)
        }
    }

    /// Start a round, and clear the last one's scores.
    ///
    /// The scores go here rather than at the final whistle so that the result
    /// stays on screen for as long as it takes somebody to call for a rematch.
    /// Clearing them when the round ended would show the winner for exactly one
    /// frame.
    @discardableResult
    private func begin(_ number: Int, in state: inout SpaceSnapshot, at now: Timecode) -> Round {
        for key in state.facts.keys where key.hasPrefix(Self.scorePrefix) {
            state.facts.removeValue(forKey: key)
        }
        let round = Round(
            number: number,
            ends: now.nanoseconds &+ Self.roundLength.wholeNanoseconds
        )
        state.facts[Self.roundNumber] = .number(Int64(number))
        state.facts[Self.roundEnds] = .number(round.ends)
        sinceSpawn = .zero
        return round
    }

    func apply(
        _ intent: SpaceIntent,
        from who: ParticipantIdentity,
        to state: inout SpaceSnapshot,
        at now: Timecode
    ) {
        switch intent.verb {
        case Self.rematch:
            // Either player may call for one, and whoever asks first is the one
            // who starts it. A second request — the other phone tapping a
            // moment later, or the same phone tapped twice — finds a round
            // already running and does nothing, rather than restarting the
            // round that has just begun and wiping a score somebody earned.
            guard
                let round = Self.round(in: state),
                now.nanoseconds >= round.ends
            else { return }
            begin(round.number + 1, in: &state, at: now)
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
                Self.hue: .decimal(Double.random(in: 0 ... 1)),
                Self.born: .number(now.nanoseconds),
            ]
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

    /// The two verbs this game understands.
    static let pop = "pop"
    static let rematch = "rematch"

    /// Set on a bubble that is climbing out of reach.
    ///
    /// The renderer's cue that this one is not going to be popped and should
    /// not be drawn as though it were.
    static let leaving = "leaving"

    /// A bubble's colour, and the instant it was released.
    static let hue = "hue"
    static let born = "born"

    /// Which round is being played, and when it closes.
    static let roundNumber = "round"
    static let roundEnds = "round/ends"

    static let scorePrefix = "score/"

    /// Where a participant's score lives in the space's facts.
    ///
    /// A key per player rather than one table, so two people scoring in the
    /// same tick produce two independent values instead of two writes to one.
    static func scoreKey(for who: ParticipantIdentity) -> String {
        "\(scorePrefix)\(who.username.value)/\(who.device.value)"
    }

    /// Everybody who has scored, best first.
    static func standings(in state: SpaceSnapshot) -> [(who: String, score: Int)] {
        state.facts
            .compactMap { key, value -> (String, Int)? in
                guard key.hasPrefix(scorePrefix), case let .number(count) = value else {
                    return nil
                }
                let name = key.dropFirst(scorePrefix.count).prefix { $0 != "/" }
                return (String(name), Int(count))
            }
            .sorted { ($0.1, $0.0) > ($1.1, $1.0) }
            .map { (who: $0.0, score: $0.1) }
    }

    /// The bubbles in a state, which is everything the renderer draws.
    static func bubbles(in state: SpaceSnapshot) -> [SpaceEntity] {
        state.entities.values.filter { $0.kind == kind }
    }

    // MARK: - The round

    /// Where the round has got to, as both devices read it from the state.
    struct Round: Sendable, Hashable {
        /// Which round this is, counting from one.
        var number: Int

        /// When the field closes, in nanoseconds on the shared clock.
        var ends: Int64
    }

    static func round(in state: SpaceSnapshot) -> Round? {
        guard
            case let .number(number) = state.facts[roundNumber],
            case let .number(ends) = state.facts[roundEnds]
        else { return nil }
        return Round(number: Int(number), ends: ends)
    }

    // MARK: - Where a bubble is

    /// The path a bubble takes, which is a property of its name.
    ///
    /// Hashed rather than drawn at random, and that is the whole trick: two
    /// devices that have never exchanged a word about this bubble agree about
    /// where it is going, so nobody has to send it. It also means a handover
    /// changes nothing — an incoming authority derives the same courses the
    /// outgoing one was using, rather than inventing new ones for bubbles
    /// already in the air.
    struct Course: Sendable, Hashable {
        var speed: Float
        var sway: Float
        var phase: Float
    }

    static func course(for id: SpaceEntityID) -> Course {
        let hash = id.rawValue.unicodeScalars.reduce(UInt64(5381)) { $0 &* 33 &+ UInt64($1.value) }
        func unit(_ shift: UInt64) -> Float { Float((hash >> shift) % 1024) / 1024 }
        return Course(
            speed: Rules.default.rise * (0.75 + 0.5 * unit(0)),
            sway: 0.4 + 0.8 * unit(10),
            phase: unit(20) * 2 * .pi
        )
    }

    /// Where a bubble released at `spawn` has got to, `seconds` later.
    ///
    /// A closed form rather than an integration, because the two sides ask at
    /// different moments and a stepped simulation would give them different
    /// answers. Everything here is exact at any `seconds`.
    static func position(
        spawnedAt spawn: SpaceVector,
        as id: SpaceEntityID,
        after seconds: Float
    ) -> SpaceVector {
        let course = course(for: id)
        let age = max(0, seconds)

        // Straight up at the bubble's own speed to the ceiling, and
        // accelerating above it.
        let toCeiling = max(0, (Field.ceiling - spawn.y) / course.speed)
        let height: Float
        if age <= toCeiling {
            height = spawn.y + course.speed * age
        } else {
            let over = age - toCeiling
            height = Field.ceiling + course.speed * over
                + 0.5 * Rules.default.flight * over * over
        }

        // The sideways wander, as the integral of the sway rather than a sum
        // of steps of it.
        let phase = course.phase
        return SpaceVector(
            x: spawn.x + course.sway / 1.7 * (cos(1.7 * phase) - cos(1.7 * (phase + age))),
            y: height,
            z: spawn.z + course.sway / 1.1 * (sin(1.1 * (phase + age)) - sin(1.1 * phase))
        )
    }

    /// The same, for a bubble in a state that knows when it was born.
    static func position(of entity: SpaceEntity, as id: SpaceEntityID, at now: Timecode) -> SpaceVector {
        position(spawnedAt: entity.pose.position, as: id, after: age(of: entity, at: now))
    }

    /// How long a bubble has been up, in seconds.
    ///
    /// Taken from whatever clock is in hand rather than only from a trusted
    /// one, and the distinction matters in both directions. The authority
    /// stamped `born` with the same clock it is asking with, so this is exact
    /// there whether or not anybody synchronised anything — and the authority
    /// is the one that cannot afford to be wrong, since it decides when a
    /// bubble has left. Refusing to answer without a trusted clock froze the
    /// field: nothing aged, so nothing departed, so nothing new was released.
    ///
    /// A follower is reading its own wall clock against the authority's, which
    /// agree to within a second or so on any phone taking network time. It only
    /// matters for a bubble that was already up when this device joined; one it
    /// watched appear is a few milliseconds old by construction.
    static func age(of entity: SpaceEntity, at now: Timecode) -> Float {
        guard case let .number(born) = entity.facts[Self.born] else { return 0 }
        let seconds = Float(now.nanoseconds &- born) / 1_000_000_000
        return seconds.isFinite && seconds > 0 ? seconds : 0
    }

    /// How long a bubble takes to reach the ceiling.
    ///
    /// The oldest a bubble may be *drawn* as being, whatever the clocks say.
    /// See ``BubbleScene`` for why that matters: an age guessed too high puts a
    /// bubble above the shot, and a node placed out of shot stays there for the
    /// rest of its life, because nothing redraws one that already exists. Too
    /// low is a bubble that appears lower than it should and climbs out of it.
    static func climbTime(spawnedAt spawn: SpaceVector, as id: SpaceEntityID) -> Float {
        max(0, (Field.ceiling - spawn.y) / course(for: id).speed)
    }

    /// How long a bubble lasts, from release to out of shot.
    static func lifetime(spawnedAt spawn: SpaceVector, as id: SpaceEntityID) -> Float {
        let course = course(for: id)
        let over = Field.departure - Field.ceiling
        let flight = Rules.default.flight
        let escape = (-course.speed + (course.speed * course.speed + 2 * flight * over).squareRoot())
            / flight
        return climbTime(spawnedAt: spawn, as: id) + escape
    }
}
