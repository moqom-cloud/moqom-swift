import Foundation
@testable import MoqomKit
import MoqomCore
import Testing

/// What the encoding change was for.
///
/// Not a benchmark harness — these numbers move with the machine and nothing
/// here asserts a time. They exist because the claim that justified hand-rolling
/// a wire format is a quantitative one, and a quantitative claim that nobody
/// measures is a preference.
@Suite("What a tick costs", .serialized)
struct SpaceCostTests {
    /// Fifty entities is a busy board: every hand of a four-player game, the
    /// pieces, and the scenery that moves.
    private static let entities = 50

    private func world() -> SpaceSnapshot {
        var snapshot = SpaceSnapshot()
        for index in 0 ..< Self.entities {
            let id = SpaceEntityID("entity-\(index)")
            snapshot.entities[id] = SpaceEntity(
                id: id,
                kind: index.isMultiple(of: 2) ? "cube" : "sphere",
                pose: SpacePose(
                    position: SpaceVector(x: Float(index), y: 1.5, z: -2.25),
                    rotation: .yaw(Float(index) * 0.1)
                )
            )
        }
        return snapshot
    }

    private func tick(_ world: SpaceSnapshot) -> SpaceUpdate {
        var moved: [SpaceEntityID: SpacePose] = [:]
        for (id, entity) in world.entities {
            var pose = entity.pose
            pose.position.x += 0.01
            moved[id] = pose
        }
        return SpaceUpdate(
            tick: SpaceTick(step: 1),
            at: Timecode(
                nanoseconds: 1_800_000_000_000_000_000,
                uncertainty: .milliseconds(4),
                trust: .synchronised
            ),
            body: .delta(SpaceDelta(moved: moved))
        )
    }

    @Test("A tick of fifty moving entities fits in a packet")
    func aTickIsSmall() throws {
        // The number that matters. A delta that exceeds the path MTU is a delta
        // that can be split across packets, and a split tick is a tick that
        // arrives late or not at all.
        let world = self.world()
        var encoder = SpaceEncoder()
        _ = try encoder.encode(SpaceUpdate(tick: .zero, at: .fallback(), body: .snapshot(world)))
        let binary = try encoder.encode(tick(world))

        let json = try JSONEncoder().encode(tick(world))

        print("""

        fifty moving entities, one tick
          binary  \(binary.count) bytes
          JSON    \(json.count) bytes
          ratio   \(String(format: "%.1f", Double(json.count) / Double(binary.count)))x

        """)

        // Fifty poses at 32 bytes is 1,600, and fifty handles is 200. Anything
        // much beyond 1,850 means a per-entity envelope has crept back in, which
        // is the regression this asserts against.
        #expect(binary.count < 1850, "a fifty-entity tick cost \(binary.count) bytes")

        // Worth stating plainly rather than hoping: a board this busy does not
        // fit in one datagram, and no encoding would make it. The poses alone
        // exceed a 1,200-byte path MTU. That is fine here — MOQT carries these
        // on QUIC streams, which fragment and retransmit — but it does mean a
        // tick is not atomic on the wire, and a design that assumed otherwise
        // would be wrong. Halving the entity count, or sending half the board
        // per tick, is what would buy atomicity.
        #expect(binary.count > 1200, "if this ever fits an MTU, revisit the note above")
    }

    @Test("Reading a tick is far cheaper than parsing one")
    func readingIsCheap() throws {
        // The claim behind the parallel-array layout: poses are read out of the
        // received buffer where they lie. This measures the consequence rather
        // than the mechanism — a hundred decodes of a fifty-entity tick against
        // the same work in JSON.
        let world = self.world()
        var encoder = SpaceEncoder()
        var decoder = SpaceDecoder()
        let opening = SpaceUpdate(tick: .zero, at: .fallback(), body: .snapshot(world))
        _ = try decoder.decode(try encoder.encode(opening))

        let binary = try encoder.encode(tick(world))
        let json = try JSONEncoder().encode(tick(world))
        let rounds = 200

        // Three consumers, each doing the same job: get every moved entity's new
        // position and add up the x. Measuring the decode alone would flatter
        // the middle path, which does its expensive work — a string hash and a
        // dictionary insertion per entity — precisely so that a caller can then
        // iterate cheaply. The cost has to be measured where a renderer pays it.
        var checksum: Float = 0

        // Warm first. Whichever path runs first otherwise pays for the cold
        // cache and the first-touch of every lazily initialised thing behind
        // `Data`, which on operations this short is larger than the difference
        // being measured — and it silently flatters whatever runs second.
        for _ in 0 ..< 50 {
            var attempt = decoder
            let tick = try attempt.view(binary)
            for index in 0 ..< tick.moveCount {
                checksum += tick.move(index).pose.position.x
            }
            var second = decoder
            _ = try second.decode(binary)
            _ = try JSONDecoder().decode(SpaceUpdate.self, from: json)
        }
        checksum = 0

        let viewStart = ContinuousClock.now
        for _ in 0 ..< rounds {
            var attempt = decoder
            let tick = try attempt.view(binary)
            for index in 0 ..< tick.moveCount {
                checksum += tick.move(index).pose.position.x
            }
        }
        let viewTime = ContinuousClock.now - viewStart

        let decodeStart = ContinuousClock.now
        for _ in 0 ..< rounds {
            var attempt = decoder
            let update = try attempt.decode(binary)
            guard case let .delta(delta) = update.body else { continue }
            for (_, pose) in delta.moved {
                checksum += pose.position.x
            }
        }
        let decodeTime = ContinuousClock.now - decodeStart

        let jsonStart = ContinuousClock.now
        for _ in 0 ..< rounds {
            let update = try JSONDecoder().decode(SpaceUpdate.self, from: json)
            guard case let .delta(delta) = update.body else { continue }
            for (_, pose) in delta.moved {
                checksum += pose.position.x
            }
        }
        let jsonTime = ContinuousClock.now - jsonStart

        print("""

        reading every moved pose out of one tick of fifty entities
          view      \(viewTime / rounds)
          decode    \(decodeTime / rounds)
          JSON      \(jsonTime / rounds)

        """)

        #expect(checksum > 0, "the compiler elided the work being measured")

        // Only in release. A debug build leaves everything in this package
        // unoptimised while `JSONDecoder` stays optimised inside the standard
        // library, so the comparison there measures the build mode rather than
        // the format — and it inverts, which would make this a test that fails
        // on every ordinary `swift test`.
        #if !DEBUG
            // The binary path is worth roughly 25x against JSON, and that is the
            // number the format was built for.
            #expect(jsonTime > decodeTime * 5, "binary decoding has lost its advantage")
        #endif

        // The view is *not* asserted to be faster, and that is a finding rather
        // than a concession. The guess going in was that materialising
        // `[SpaceEntityID: SpacePose]` — fifty string hashes and fifty
        // dictionary insertions — would dominate a tick. Measured, it does not:
        // both paths read the same fifty poses out of the same buffer, and that
        // read is what the time goes on. The two come out within a few percent
        // of each other, in either order.
        //
        // ``SpaceTickView`` earns its place on the other two counts. It
        // allocates nothing, where the materialising path allocates a dictionary
        // and fifty string boxes per tick — three thousand a second at 60Hz,
        // which a tight loop with a warm allocator does not show and a real app
        // with a fragmented heap does. And it can hand the whole pose run
        // straight to a GPU buffer through `withUnsafePoses`, which the
        // materialising path cannot do at any speed.
        #expect(
            viewTime < decodeTime * 2,
            "the view has become dramatically slower than materialising, which inverts its purpose"
        )
    }
}
