import Testing

@testable import MoqomCore
@testable import MoqomKit

@Suite("Subscription planning")
struct SubscriptionPlannerTests {
    private func grid(_ count: Int) -> ([ParticipantIdentity], SubscriptionPlanner) {
        var planner = SubscriptionPlanner()
        let people = (0 ..< count).map { identity("user\(String(format: "%02d", $0))") }
        for person in people {
            planner.setLadder(.defaultCamera(), for: person)
        }
        return (people, planner)
    }

    @Test("a nine-person grid subscribes to thumbnails, not to nine 1080p streams")
    func gridSubscribesToWhatItDraws() {
        // Nine at 1080p is roughly 22 Mbps of downlink. At the resolution the
        // tiles actually render it is closer to 5, and in a grid that is the
        // dominant cost rather than an optimisation at the margin.
        var (people, planner) = grid(9)
        let boxes = Dictionary(
            uniqueKeysWithValues: people.map { ($0, RenderBox(width: 320, height: 180, scale: 2)) }
        )

        let changes = planner.plan(boxes: boxes)
        let layers = changes.compactMap { change -> LayerID? in
            if case let .subscribe(_, layer, _) = change { return layer }
            return nil
        }

        #expect(layers.count == 9)
        #expect(Set(layers) == ["video/360p"])
    }

    @Test("switching grid to speaker is one batch, not a burst of individual requests")
    func speakerSwitchIsBatched() {
        var (people, planner) = grid(9)
        let gridBoxes = Dictionary(
            uniqueKeysWithValues: people.map { ($0, RenderBox(width: 320, height: 180, scale: 2)) }
        )
        _ = planner.plan(boxes: gridBoxes)

        var speakerBoxes = gridBoxes
        speakerBoxes[people[0]] = RenderBox(width: 390, height: 220, scale: 3)
        for person in people.dropFirst() {
            speakerBoxes[person] = RenderBox(width: 60, height: 34, scale: 2)
        }

        let changes = planner.plan(boxes: speakerBoxes)
        let speakerLayer = changes.compactMap { change -> LayerID? in
            if case let .subscribe(who, layer, _) = change, who == people[0] { return layer }
            return nil
        }.first

        #expect(speakerLayer == "video/720p")
        #expect(changes.count > 1)
    }

    @Test("priority follows the layout, so the relay sheds thumbnails first")
    func priorityFollowsDrawnArea() {
        var (people, planner) = grid(3)
        var boxes: [ParticipantIdentity: RenderBox] = [:]
        boxes[people[0]] = RenderBox(width: 390, height: 220, scale: 3)
        boxes[people[1]] = RenderBox(width: 120, height: 68, scale: 2)
        boxes[people[2]] = RenderBox(width: 60, height: 34, scale: 2)

        let changes = planner.plan(boxes: boxes)
        var priorities: [ParticipantIdentity: UInt8] = [:]
        for case let .subscribe(who, _, priority) in changes {
            priorities[who] = priority
        }

        // Lower is more urgent in draft-19, so the speaker must sort below the
        // thumbnails numerically.
        #expect(priorities[people[0]]! < priorities[people[1]]!)
        #expect(priorities[people[1]]! < priorities[people[2]]!)
    }

    @Test("beyond the decode budget, the overflow degrades to audio rather than refusing")
    func budgetDegradesTheOverflow() {
        // Agora caps a client at 50 subscriptions and refuses beyond it. The
        // bound here is what the client can decode, and exceeding it costs
        // video on the smallest tiles rather than an error.
        var (people, planner) = grid(12)
        planner.videoBudget = 4
        let boxes = Dictionary(
            uniqueKeysWithValues: people.enumerated().map { index, person in
                (person, RenderBox(width: Double(200 - index * 10), height: 100, scale: 2))
            }
        )

        let changes = planner.plan(boxes: boxes)
        let subscribed = changes.compactMap { change -> ParticipantIdentity? in
            if case let .subscribe(who, _, _) = change { return who }
            return nil
        }

        #expect(subscribed.count == 4)
        for person in subscribed {
            #expect(planner.selection(for: person)?.video != nil)
        }
        // Everyone else keeps audio.
        for person in people where !subscribed.contains(person) {
            #expect(planner.selection(for: person)?.audio == true)
            #expect(planner.selection(for: person)?.video == nil)
        }
    }

    @Test("a uniform grid ranks by the gallery, because equal tiles cannot rank themselves")
    func galleryOrderOutranksDrawnArea() {
        // Sixteen tiles the same size means drawn area ties, and the tie-break is
        // the identity string — so without an order the relay sheds whoever is
        // last in the alphabet, regardless of who is talking.
        var (people, planner) = grid(3)
        let boxes = Dictionary(
            uniqueKeysWithValues: people.map { ($0, RenderBox(width: 120, height: 68, scale: 2)) }
        )

        let changes = planner.plan(boxes: boxes, order: [people[2], people[0], people[1]])
        var priorities: [ParticipantIdentity: UInt8] = [:]
        for case let .subscribe(who, _, priority) in changes {
            priorities[who] = priority
        }

        #expect(priorities[people[2]]! < priorities[people[0]]!)
        #expect(priorities[people[0]]! < priorities[people[1]]!)
    }

    @Test("the gallery decides who loses video past the budget, and they keep audio")
    func galleryOrderDecidesTheOverflow() {
        var (people, planner) = grid(4)
        planner.videoBudget = 2
        let boxes = Dictionary(
            uniqueKeysWithValues: people.map { ($0, RenderBox(width: 120, height: 68, scale: 2)) }
        )

        // Reverse of the alphabet, which is what an active speaker at the end of
        // the roster looks like to the planner.
        _ = planner.plan(boxes: boxes, order: people.reversed())

        #expect(planner.selection(for: people[3])?.video != nil)
        #expect(planner.selection(for: people[2])?.video != nil)
        for person in [people[0], people[1]] {
            #expect(planner.selection(for: person)?.video == nil)
            #expect(planner.selection(for: person)?.audio == true)
        }
    }

    @Test("a re-layout that changes nothing emits nothing")
    func stableLayoutIsSilent() {
        var (people, planner) = grid(4)
        let boxes = Dictionary(
            uniqueKeysWithValues: people.map { ($0, RenderBox(width: 120, height: 68, scale: 2)) }
        )

        let first = planner.plan(boxes: boxes)
        let second = planner.plan(boxes: boxes)

        #expect(!first.isEmpty)
        #expect(second.isEmpty)
    }

    @Test("the link estimate is divided across the tracks actually being drawn")
    func linkBitrateIsShared() {
        var (people, planner) = grid(4)
        let boxes = Dictionary(
            uniqueKeysWithValues: people.map { ($0, RenderBox(width: 640, height: 360, scale: 2)) }
        )

        // 2.4 Mbps across four tiles is 600 kbps each, which buys 360p rather
        // than the 720p the boxes would otherwise justify.
        let changes = planner.plan(boxes: boxes, linkBitrate: 2_400_000)
        let layers = Set(
            changes.compactMap { change -> LayerID? in
                if case let .subscribe(_, layer, _) = change { return layer }
                return nil
            }
        )

        #expect(layers == ["video/360p"])
    }

    @Test("a participant who leaves stops being planned for")
    func removalIsClean() {
        var (people, planner) = grid(2)
        let boxes = Dictionary(
            uniqueKeysWithValues: people.map { ($0, RenderBox(width: 120, height: 68, scale: 2)) }
        )
        _ = planner.plan(boxes: boxes)
        planner.remove(people[0])

        let changes = planner.plan(boxes: boxes)
        #expect(planner.selection(for: people[0]) == nil)
        #expect(!changes.contains { change in
            if case let .subscribe(who, _, _) = change { return who == people[0] }
            return false
        })
    }
}
