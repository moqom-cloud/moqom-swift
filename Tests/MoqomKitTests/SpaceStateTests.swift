import Foundation
@testable import MoqomCore
@testable import MoqomKit
import Testing

@Suite("Shared space geometry")
struct SpaceGeometryTests {
    @Test("A rotation is a rotation, whatever it was built from")
    func rotationsAreNormalised() {
        // A quaternion that is not unit length silently scales everything it
        // touches, and the scaling compounds through composition. The type has
        // no way to represent one.
        let stretched = SpaceRotation(x: 0, y: 4, z: 0, w: 4)
        let length = (stretched.x * stretched.x + stretched.y * stretched.y
            + stretched.z * stretched.z + stretched.w * stretched.w).squareRoot()

        #expect(abs(length - 1) < 1e-5)
    }

    @Test("A degenerate rotation becomes the identity rather than a NaN factory")
    func degenerateRotationsAreSafe() {
        // Reachable from a decoder fed zeros, and once a NaN is in a transform
        // every position derived from it is NaN and the scene disappears with
        // no indication of where it went.
        #expect(SpaceRotation(x: 0, y: 0, z: 0, w: 0) == .identity)
        #expect(SpaceRotation(x: .nan, y: 0, z: 0, w: 1) == .identity)
    }

    @Test("A scale of zero or less is refused")
    func degenerateScaleIsRefused() {
        // A zero scale collapses geometry to a point it cannot come back from.
        #expect(SpacePose(scale: 0).scale == 1)
        #expect(SpacePose(scale: -2).scale == 1)
        #expect(SpacePose(scale: .nan).scale == 1)
    }

    @Test("Interpolation takes the short way round")
    func rotationTakesTheShortPath() {
        // A quaternion and its negation are the same orientation reached in
        // opposite directions. Without the sign flip, a piece turning a little
        // visibly spins most of the way round instead.
        let start = SpaceRotation.yaw(0.1)
        let end = SpaceRotation(x: -start.x, y: -start.y, z: -start.z, w: -start.w)

        let middle = SpaceRotation.interpolated(from: start, to: end, amount: 0.5)

        // The two endpoints are the same orientation, so every point between
        // them should be too, rather than sweeping through a half turn.
        let dot = abs(middle.x * start.x + middle.y * start.y
            + middle.z * start.z + middle.w * start.w)
        #expect(dot > 0.999, "took the long way round the sphere")
    }

    @Test("Interpolating between near-identical rotations does not divide by zero")
    func rotationHandlesTinySeparations() {
        // The spherical formula divides by sin(theta), and theta approaches zero
        // on every still object in the scene — which is most of them.
        let start = SpaceRotation.yaw(0.5)
        let end = SpaceRotation.yaw(0.5000001)

        let middle = SpaceRotation.interpolated(from: start, to: end, amount: 0.5)

        #expect(middle.x.isFinite && middle.y.isFinite)
        #expect(middle.z.isFinite && middle.w.isFinite)
    }

    @Test("Interpolation past the end extrapolates rather than clamping")
    func interpolationExtrapolates() {
        // Deliberate. When the next tick has not arrived, a renderer would
        // rather guess a little ahead than freeze.
        let start = SpacePose(position: SpaceVector(x: 0, y: 0, z: 0))
        let end = SpacePose(position: SpaceVector(x: 1, y: 0, z: 0))

        let beyond = SpacePose.interpolated(from: start, to: end, amount: 1.5)

        #expect(abs(beyond.position.x - 1.5) < 1e-5)
    }
}

@Suite("Sampling a space on a shared clock")
struct SpaceTimelineTests {
    private func tick(_ nanoseconds: Int64) -> Timecode {
        Timecode(nanoseconds: nanoseconds, uncertainty: .milliseconds(1), trust: .synchronised)
    }

    @Test("The end of a span is 1, and past it is extrapolation")
    func samplesAlongTheSpan() {
        let start = tick(1_000_000_000)
        let end = tick(1_050_000_000)

        #expect(abs((SpaceTimeline.progress(from: start, to: end, at: start) ?? -1)) < 1e-5)
        #expect(abs((SpaceTimeline.progress(from: start, to: end, at: end) ?? -1) - 1) < 1e-5)

        let halfway = tick(1_025_000_000)
        #expect(abs((SpaceTimeline.progress(from: start, to: end, at: halfway) ?? -1) - 0.5) < 1e-5)

        let late = tick(1_075_000_000)
        #expect(abs((SpaceTimeline.progress(from: start, to: end, at: late) ?? -1) - 1.5) < 1e-5)
    }

    @Test("A dropped stream does not coast forever")
    func coastingIsCapped() {
        let start = tick(1_000_000_000)
        let end = tick(1_050_000_000)
        let far = tick(2_000_000_000)

        let amount = SpaceTimeline.progress(
            from: start,
            to: end,
            at: far,
            coasting: .milliseconds(250)
        )
        // 50ms span, 250ms past the end: (50+250)/50 = 6.
        #expect(abs((amount ?? -1) - 6) < 1e-5)
    }

    @Test("Fallback clocks are not placed against each other")
    func fallbackIsIncomparable() {
        let start = Timecode(
            nanoseconds: 1_000_000_000, uncertainty: .milliseconds(1), trust: .fallback
        )
        let end = tick(1_050_000_000)
        #expect(SpaceTimeline.progress(from: start, to: end, at: end) == nil)
    }
}

@Suite("Placing a shared space in a room")
struct SpaceAnchorTests {
    @Test("A placement round-trips")
    func placementRoundTrips() {
        // The two directions are used at different moments — rendering brings
        // network coordinates into the room, acting takes a touch back out — and
        // a mismatch between them puts a piece somewhere nobody reached for.
        let anchor = SpaceAnchor(
            origin: SpaceVector(x: 1.5, y: -0.2, z: 3),
            rotation: .yaw(0.7),
            scale: 0.4
        )
        let original = SpaceVector(x: 0.3, y: 0.1, z: -0.8)

        let returned = anchor.space(from: anchor.world(from: original))

        #expect(original.distance(to: returned) < 1e-4)
    }

    @Test("Two people who placed the space differently agree about the game")
    func differentPlacementsAgree() {
        // The whole reason the shared frame is synthetic. Ada put the board on
        // her coffee table, Grace put it on a smaller desk turned the other way,
        // and neither told the other. They must still agree on which square a
        // piece is on.
        let ada = SpaceAnchor(
            origin: SpaceVector(x: 0, y: 0.7, z: -1),
            rotation: .yaw(0.3),
            scale: 1
        )
        let grace = SpaceAnchor(
            origin: SpaceVector(x: 4, y: 0.9, z: 2),
            rotation: .yaw(2.9),
            scale: 0.5
        )

        // Ada reaches out and touches a point in her own living room.
        let touchedInAdasRoom = SpaceVector(x: 0.2, y: 0.75, z: -1.1)
        let shared = ada.space(from: touchedInAdasRoom)

        // What Grace sees, in her own room, is somewhere completely different.
        let seenInGracesRoom = grace.world(from: shared)
        #expect(seenInGracesRoom.distance(to: touchedInAdasRoom) > 0.5)

        // But converted back it is the same point on the board, which is the
        // only thing either of them replicated.
        #expect(grace.space(from: seenInGracesRoom).distance(to: shared) < 1e-4)
    }

    @Test("Scale is a local comfort setting, not a game rule")
    func scaleIsLocal() {
        // Someone at a desk plays the same game as someone with a living room.
        let desk = SpaceAnchor(scale: 0.25)
        let floor = SpaceAnchor(scale: 2)

        let onTheBoard = SpaceVector(x: 1, y: 0, z: 0)

        #expect(abs(desk.world(from: onTheBoard).x - 0.25) < 1e-5)
        #expect(abs(floor.world(from: onTheBoard).x - 2) < 1e-5)
        // Same square, either way.
        #expect(desk.space(from: desk.world(from: onTheBoard))
            .distance(to: floor.space(from: floor.world(from: onTheBoard))) < 1e-5)
    }

    @Test("The identity anchor is the one a viewer without AR uses")
    func identityAnchorIsAPassThrough() {
        let point = SpaceVector(x: 1, y: 2, z: 3)
        #expect(SpaceAnchor.identity.world(from: point).distance(to: point) < 1e-6)
    }
}

@Suite("Replicating a shared space")
struct SpaceReplicationTests {
    @Test("A newer authority outranks an older one however far it had counted")
    func epochOutranksStep() {
        // The split-brain fence. A host in a tunnel with a full send buffer may
        // still be ticking; its work must be inert, not merely late.
        let stale = SpaceTick(epoch: 3, step: 900_000)
        let fresh = SpaceTick(epoch: 4, step: 0)

        #expect(stale < fresh)
        #expect(!(fresh < stale))
    }

    @Test("Taking over resets the step rather than continuing it")
    func handoverResetsTheStep() {
        let handed = SpaceTick(epoch: 2, step: 5000).succeeding
        #expect(handed == SpaceTick(epoch: 3, step: 0))
    }

    @Test("Applying a delta twice is applying it once")
    func deltasAreIdempotent() {
        // The rule that makes repair safe: after a reconnect a client re-reads
        // objects it has already applied.
        var state = SpaceSnapshot(entities: [
            "ball": SpaceEntity(id: "ball", kind: "sphere"),
        ])
        let delta = SpaceDelta(
            moved: ["ball": SpacePose(position: SpaceVector(x: 2, y: 0, z: 0))],
            facts: ["score": .number(3)]
        )

        state.apply(delta)
        let once = state
        state.apply(delta)

        #expect(state == once)
    }

    @Test("A fact the authority cleared is cleared everywhere")
    func factsCanBeForgotten() {
        // The case a new value cannot express, and the reason `forgotten`
        // exists: a simulation that clears a score — the bubble field does it
        // on every rematch — had no way to say so, and every follower kept
        // showing the last round's numbers until the next full snapshot.
        let before = SpaceSnapshot(facts: [
            "score/ada": .number(7),
            "round": .number(1),
        ])
        let after = SpaceSnapshot(facts: ["round": .number(2)])

        let delta = before.delta(to: after)
        #expect(delta.forgotten == ["score/ada"])

        var replica = before
        replica.apply(delta)
        #expect(replica == after)
    }

    @Test("An entity fact the authority cleared is cleared everywhere")
    func entityFactsAreReplacedNotMerged() {
        // ``SpaceSnapshot/delta(to:)`` sends an entity's whole bag rather than
        // the keys that changed, precisely so that a dropped one is expressible.
        // Folding it in key by key threw that away.
        let before = SpaceSnapshot(entities: [
            "b-1": SpaceEntity(id: "b-1", kind: "bubble", facts: [
                "hue": .decimal(0.5),
                "leaving": .flag(true),
            ]),
        ])
        let after = SpaceSnapshot(entities: [
            "b-1": SpaceEntity(id: "b-1", kind: "bubble", facts: ["hue": .decimal(0.5)]),
        ])

        var replica = before
        replica.apply(before.delta(to: after))
        #expect(replica == after)
    }

    @Test("A thing can be spawned and moved in the same tick")
    func spawnsLandBeforeMoves() {
        var state = SpaceSnapshot()
        state.apply(SpaceDelta(
            moved: ["card": SpacePose(position: SpaceVector(x: 0, y: 1, z: 0))],
            spawned: [SpaceEntity(id: "card", kind: "card")]
        ))

        #expect(state.entities["card"]?.pose.position.y == 1)
    }

    @Test("A thing created and destroyed in one tick leaves nothing behind")
    func removalsHappenLast() {
        var state = SpaceSnapshot()
        state.apply(SpaceDelta(
            spawned: [SpaceEntity(id: "spark", kind: "effect")],
            removed: ["spark"]
        ))

        #expect(state.entities.isEmpty)
    }

    @Test("Releasing a claim is distinguishable from not mentioning it")
    func releasingIsNotSilence() {
        // Three states in one field: absent means unchanged, present-and-nil
        // means let go, present-and-set means grabbed.
        let ada = identity("ada", device: "phone")
        var state = SpaceSnapshot(entities: [
            "ball": SpaceEntity(id: "ball", kind: "sphere", owner: ada),
        ])

        state.apply(SpaceDelta(facts: ["turn": .text("grace")]))
        #expect(state.entities["ball"]?.owner == ada, "silence changed an owner")

        state.apply(SpaceDelta(claimed: ["ball": nil]))
        #expect(state.entities["ball"]?.owner == nil)
    }

    @Test("A diff turns one state into the other")
    func diffReconstructs() {
        // The authority sends what changed by comparing, rather than by
        // maintaining a change list beside the simulation that can drift from it.
        let ada = identity("ada", device: "phone")
        let before = SpaceSnapshot(
            entities: [
                "ball": SpaceEntity(id: "ball", kind: "sphere"),
                "old": SpaceEntity(id: "old", kind: "block"),
            ],
            facts: ["score": .number(1)]
        )
        var after = before
        after.entities["ball"]?.pose = SpacePose(position: SpaceVector(x: 5, y: 0, z: 0))
        after.entities["ball"]?.owner = ada
        after.entities["new"] = SpaceEntity(id: "new", kind: "cube")
        after.entities.removeValue(forKey: "old")
        after.facts["score"] = .number(2)

        var rebuilt = before
        rebuilt.apply(before.delta(to: after))

        #expect(rebuilt == after)
    }

    @Test("A still board produces nothing to send")
    func anUnchangedTickIsEmpty() {
        // Otherwise an idle game costs an object sixty times a second, forever,
        // to every viewer.
        let state = SpaceSnapshot(entities: [
            "ball": SpaceEntity(id: "ball", kind: "sphere"),
        ])

        #expect(state.delta(to: state).isEmpty)
    }

    @Test("An unreadable version is refused rather than half-applied")
    func versionsAreChecked() throws {
        var update = SpaceUpdate(tick: .zero, at: .fallback(), body: .delta(SpaceDelta()))
        update.version = SpaceUpdate.currentVersion + 1

        var encoder = SpaceEncoder()
        var decoder = SpaceDecoder()

        #expect(throws: WireError.self) {
            _ = try decoder.decode(try encoder.encode(update))
        }
    }
}

@Suite("A shared space on the wire")
struct SpaceWireTests {
    /// An encoder and a decoder that have agreed on nothing yet, as a
    /// publication and a subscription start out.
    private func pair() -> (SpaceEncoder, SpaceDecoder) {
        (SpaceEncoder(), SpaceDecoder())
    }

    private func snapshot(_ entities: [SpaceEntity]) -> SpaceUpdate {
        SpaceUpdate(
            tick: .zero,
            at: .fallback(),
            body: .snapshot(SpaceSnapshot(
                entities: Dictionary(uniqueKeysWithValues: entities.map { ($0.id, $0) })
            ))
        )
    }

    @Test("A snapshot survives the wire whole")
    func snapshotsRoundTrip() throws {
        var (encoder, decoder) = pair()
        let original = SpaceUpdate(
            tick: SpaceTick(epoch: 2, step: 41),
            at: Timecode(
                nanoseconds: 1_800_000_000_000_000_000,
                uncertainty: .milliseconds(4),
                trust: .synchronised
            ),
            body: .snapshot(SpaceSnapshot(
                entities: [
                    "ball": SpaceEntity(
                        id: "ball",
                        kind: "sphere",
                        pose: SpacePose(
                            position: SpaceVector(x: 1, y: 2, z: 3),
                            rotation: .yaw(0.5),
                            scale: 2
                        ),
                        owner: identity("ada"),
                        facts: ["bounces": .number(3)]
                    ),
                    "table": SpaceEntity(id: "table", kind: "plane"),
                ],
                facts: ["phase": .text("playing"), "over": .flag(false)],
                authority: identity("ada")
            ))
        )

        let returned = try decoder.decode(try encoder.encode(original))

        #expect(returned.tick == original.tick)
        #expect(returned.at.nanoseconds == original.at.nanoseconds)
        #expect(returned.at.uncertainty == original.at.uncertainty)
        #expect(returned.at.trust == .synchronised)
        #expect(returned.body == original.body)
    }

    @Test("A delta survives the wire whole")
    func deltasRoundTrip() throws {
        var (encoder, decoder) = pair()
        _ = try encoder.encode(snapshot([
            SpaceEntity(id: "ball", kind: "sphere"),
            SpaceEntity(id: "cup", kind: "cup"),
            SpaceEntity(id: "old", kind: "cube"),
        ]))
        _ = try decoder.decode(try encoder.encode(snapshot([
            SpaceEntity(id: "ball", kind: "sphere"),
            SpaceEntity(id: "cup", kind: "cup"),
            SpaceEntity(id: "old", kind: "cube"),
        ])))

        // Re-establish both sides from one snapshot rather than two, so the
        // handle tables are the same table.
        var (freshEncoder, freshDecoder) = pair()
        let opening = snapshot([
            SpaceEntity(id: "ball", kind: "sphere"),
            SpaceEntity(id: "cup", kind: "cup"),
            SpaceEntity(id: "old", kind: "cube"),
        ])
        _ = try freshDecoder.decode(try freshEncoder.encode(opening))

        let original = SpaceUpdate(
            tick: SpaceTick(epoch: 1, step: 9),
            at: .fallback(),
            body: .delta(SpaceDelta(
                moved: [
                    "ball": SpacePose(position: SpaceVector(x: 1, y: 2, z: 3)),
                    "cup": SpacePose(position: SpaceVector(x: -4, y: 0.5, z: 0)),
                ],
                spawned: [SpaceEntity(id: "card", kind: "card")],
                removed: ["old"],
                claimed: ["ball": identity("ada")],
                facts: ["score": .decimal(1.5)],
                forgotten: ["phase"],
                entityFacts: ["cup": ["full": .flag(true)]]
            ))
        )

        let returned = try freshDecoder.decode(try freshEncoder.encode(original))

        #expect(returned.body == original.body)
    }

    @Test("A released claim is distinguishable from an unchanged one")
    func releasesSurvive() throws {
        // Three states through two encodings: absent is unchanged, present with
        // no owner is released, present with one is claimed. Collapsing the
        // first two would make a drop impossible to express.
        var (encoder, decoder) = pair()
        let opening = snapshot([
            SpaceEntity(id: "ball", kind: "sphere", owner: identity("ada")),
        ])
        _ = try decoder.decode(try encoder.encode(opening))

        let release = SpaceUpdate(
            tick: SpaceTick(step: 1),
            at: .fallback(),
            body: .delta(SpaceDelta(claimed: ["ball": nil]))
        )
        let returned = try decoder.decode(try encoder.encode(release))

        guard case let .delta(delta) = returned.body else {
            Issue.record("not a delta")
            return
        }
        #expect(delta.claimed.count == 1)
        #expect(delta.claimed["ball"] == SpaceEntity?.none.map(\.owner) ?? .some(nil))
    }

    @Test("Every kind of fact survives, including a false one")
    func factTypesSurvive() throws {
        var (encoder, decoder) = pair()
        let original = SpaceUpdate(
            tick: .zero,
            at: .fallback(),
            body: .snapshot(SpaceSnapshot(facts: [
                "yes": .flag(true),
                // The one a schema-default encoding gets wrong: which field is
                // present is what says what type the value is, so an omitted
                // false would read as a fact with no value at all.
                "no": .flag(false),
                "count": .number(-9_000_000_000),
                "ratio": .decimal(0.125),
                "phase": .text("playing"),
            ]))
        )

        let returned = try decoder.decode(try encoder.encode(original))

        #expect(returned.body == original.body)
    }

    @Test("The same state encodes to the same bytes twice")
    func encodingIsDeterministic() throws {
        // Dictionaries do not promise an order. A track whose bytes change
        // without its meaning changing cannot be diffed, cached by content, or
        // compared in a test.
        let update = SpaceUpdate(
            tick: .zero,
            at: .fallback(),
            body: .snapshot(SpaceSnapshot(
                entities: Dictionary(uniqueKeysWithValues: (0 ..< 20).map {
                    let id = SpaceEntityID("e\($0)")
                    return (id, SpaceEntity(id: id, kind: "cube"))
                }),
                facts: Dictionary(uniqueKeysWithValues: (0 ..< 20).map { ("f\($0)", .number(Int64($0))) })
            ))
        )

        var first = SpaceEncoder()
        var second = SpaceEncoder()

        #expect(try first.encode(update) == second.encode(update))
    }
}

@Suite("Interning entity names")
struct SpaceInterningTests {
    @Test("A moving entity costs a handle, not its name")
    func movesDoNotCarryNames() throws {
        // The reason the codec is stateful at all. Nineteen bytes of
        // "player-2-left-hand", sixty times a second, to a million people.
        var encoder = SpaceEncoder()
        let name = "player-2-left-hand"
        _ = try encoder.encode(SpaceUpdate(
            tick: .zero,
            at: .fallback(),
            body: .snapshot(SpaceSnapshot(entities: [
                SpaceEntityID(name): SpaceEntity(id: SpaceEntityID(name), kind: "hand"),
            ]))
        ))

        let tick = try encoder.encode(SpaceUpdate(
            tick: SpaceTick(step: 1),
            at: .fallback(),
            body: .delta(SpaceDelta(moved: [
                SpaceEntityID(name): SpacePose(position: SpaceVector(x: 1, y: 0, z: 0)),
            ]))
        ))

        #expect(
            !tick.contains(Data(name.utf8)),
            "the entity's name was written into a delta"
        )
    }

    @Test("A tick that moves one thing is small")
    func ticksAreSmall() throws {
        // Not a benchmark, a ceiling. A pose is 32 bytes and a handle is 4; if a
        // one-entity tick ever costs much more than that plus a timestamp,
        // something has grown a per-entity envelope.
        var encoder = SpaceEncoder()
        _ = try encoder.encode(SpaceUpdate(
            tick: .zero,
            at: .fallback(),
            body: .snapshot(SpaceSnapshot(entities: [
                "ball": SpaceEntity(id: "ball", kind: "sphere"),
            ]))
        ))

        let tick = try encoder.encode(SpaceUpdate(
            tick: SpaceTick(step: 1),
            at: Timecode(nanoseconds: 1_800_000_000_000_000_000, uncertainty: .milliseconds(4), trust: .synchronised),
            body: .delta(SpaceDelta(moved: ["ball": .identity]))
        ))

        #expect(tick.count < 70, "a one-entity tick cost \(tick.count) bytes")
    }

    @Test("A spawn introduces its own handle mid-group")
    func spawnsCarryTheirNames() throws {
        var encoder = SpaceEncoder()
        var decoder = SpaceDecoder()
        let opening = SpaceUpdate(
            tick: .zero,
            at: .fallback(),
            body: .snapshot(SpaceSnapshot())
        )
        _ = try decoder.decode(try encoder.encode(opening))

        // Spawn and move in the same tick: the handle has to exist before
        // anything in that same delta refers to it.
        let born = SpaceUpdate(
            tick: SpaceTick(step: 1),
            at: .fallback(),
            body: .delta(SpaceDelta(
                moved: ["card": SpacePose(position: SpaceVector(x: 0, y: 1, z: 0))],
                spawned: [SpaceEntity(id: "card", kind: "card")]
            ))
        )
        let returned = try decoder.decode(try encoder.encode(born))

        guard case let .delta(delta) = returned.body else {
            Issue.record("not a delta")
            return
        }
        #expect(delta.spawned.map(\.id) == ["card"])
        #expect(delta.moved["card"]?.position.y == 1)
    }

    @Test("A snapshot renumbers, so a handover cannot leave the two sides disagreeing")
    func snapshotsResetTheTable() throws {
        var encoder = SpaceEncoder()
        var decoder = SpaceDecoder()

        _ = try decoder.decode(try encoder.encode(SpaceUpdate(
            tick: .zero,
            at: .fallback(),
            body: .snapshot(SpaceSnapshot(entities: [
                "a": SpaceEntity(id: "a", kind: "cube"),
                "b": SpaceEntity(id: "b", kind: "cube"),
            ]))
        )))

        // A new authority takes over and snapshots a different world. If the
        // table were additive rather than replaced, handle 0 would still mean
        // "a" to one side and "z" to the other.
        _ = try decoder.decode(try encoder.encode(SpaceUpdate(
            tick: SpaceTick(epoch: 1, step: 0),
            at: .fallback(),
            body: .snapshot(SpaceSnapshot(entities: [
                "z": SpaceEntity(id: "z", kind: "cube"),
            ]))
        )))

        let returned = try decoder.decode(try encoder.encode(SpaceUpdate(
            tick: SpaceTick(epoch: 1, step: 1),
            at: .fallback(),
            body: .delta(SpaceDelta(moved: ["z": SpacePose(position: SpaceVector(x: 5, y: 0, z: 0))]))
        )))

        guard case let .delta(delta) = returned.body else {
            Issue.record("not a delta")
            return
        }
        #expect(delta.moved["z"]?.position.x == 5)
        #expect(delta.moved.count == 1)
    }

    @Test("A delta read without its snapshot is refused, not guessed at")
    func missedSnapshotsAreLoud() throws {
        // The failure this scheme has to get right. A subscriber that somehow
        // starts mid-group holds no table, and every handle is meaningless. It
        // must say so rather than render a space with holes in it.
        var encoder = SpaceEncoder()
        _ = try encoder.encode(SpaceUpdate(
            tick: .zero,
            at: .fallback(),
            body: .snapshot(SpaceSnapshot(entities: [
                "ball": SpaceEntity(id: "ball", kind: "sphere"),
            ]))
        ))
        let tick = try encoder.encode(SpaceUpdate(
            tick: SpaceTick(step: 1),
            at: .fallback(),
            body: .delta(SpaceDelta(moved: ["ball": .identity]))
        ))

        var latecomer = SpaceDecoder()

        #expect(throws: WireError.self) { _ = try latecomer.decode(tick) }
    }

    @Test("Moving something that was never introduced is caught at the encoder")
    func unknownEntitiesAreCaughtEarly() throws {
        // A bug in a simulation, not in a network. Better to fail where it
        // happened than to ship subscribers a delta they cannot apply.
        var encoder = SpaceEncoder()
        _ = try encoder.encode(SpaceUpdate(
            tick: .zero,
            at: .fallback(),
            body: .snapshot(SpaceSnapshot())
        ))

        #expect(throws: MoqomError.self) {
            _ = try encoder.encode(SpaceUpdate(
                tick: SpaceTick(step: 1),
                at: .fallback(),
                body: .delta(SpaceDelta(moved: ["ghost": .identity]))
            ))
        }
    }
}

@Suite("A shared space from a hostile peer")
struct SpaceHostileTests {
    private func opened() throws -> (SpaceEncoder, SpaceDecoder) {
        var encoder = SpaceEncoder()
        var decoder = SpaceDecoder()
        _ = try decoder.decode(try encoder.encode(SpaceUpdate(
            tick: .zero,
            at: .fallback(),
            body: .snapshot(SpaceSnapshot(entities: [
                "ball": SpaceEntity(id: "ball", kind: "sphere"),
            ]))
        )))
        return (encoder, decoder)
    }

    @Test("Truncating a tick anywhere fails cleanly")
    func truncationIsSurvivable() throws {
        var (encoder, decoder) = try opened()
        let tick = try encoder.encode(SpaceUpdate(
            tick: SpaceTick(step: 1),
            at: .fallback(),
            body: .delta(SpaceDelta(moved: ["ball": .identity]))
        ))

        for length in 0 ..< tick.count {
            var attempt = decoder
            // The property is only that it returns or throws. A prefix that
            // happens to parse is fine; one that reads past the end is not.
            _ = try? attempt.decode(tick.prefix(length))
        }
    }

    @Test("Arbitrary bytes never crash the decoder")
    func fuzzedInputIsSurvivable() throws {
        let (_, base) = try opened()
        var generator = SystemRandomNumberGenerator()

        for _ in 0 ..< 1000 {
            let length = Int.random(in: 0 ... 96, using: &generator)
            let bytes = Data((0 ..< length).map { _ in UInt8.random(in: .min ... .max) })
            var attempt = base
            _ = try? attempt.decode(bytes)
        }
    }

    @Test("A tick claiming more poses than handles is rejected")
    func mismatchedArraysAreRejected() throws {
        // The one check the parallel-array layout costs. Without it, a peer
        // could hand over ten handles and one pose and walk the reader off the
        // end of the pose array.
        var (encoder, decoder) = try opened()
        let tick = try encoder.encode(SpaceUpdate(
            tick: SpaceTick(step: 1),
            at: .fallback(),
            body: .delta(SpaceDelta(moved: ["ball": .identity]))
        ))

        // Chop the last pose's worth of bytes out of the delta, leaving the
        // handle array claiming an entity the pose array no longer describes.
        var corrupted = tick
        corrupted.removeLast(16)

        var attempt = decoder
        #expect(throws: (any Error).self) { _ = try attempt.decode(corrupted) }
    }
}
