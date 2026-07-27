import Testing

@testable import MoqomCore
@testable import MoqomKit

@Suite("Render-aware layer selection")
struct LayerSelectionTests {
    private let ladder = LayerLadder.defaultCamera()

    @Test("a thumbnail on a 3x display is served for its device pixels, not its points")
    func devicePixelRatioIsHonoured() {
        // 160×90pt at 3× is 480×270px, which needs 360p. Reading the layout
        // size and ignoring the scale would serve 180p and under-serve every
        // high-DPI client — invisible in a simulator at 1×.
        var selector = LayerSelector(ladder: ladder)
        let selection = selector.update(box: RenderBox(width: 160, height: 90, scale: 3))

        #expect(selection?.video == "video/360p")
        #expect(selection?.reason == .renderSize)
    }

    @Test("the same box at 1x gets a cheaper layer")
    func lowDensityGetsLess() {
        var selector = LayerSelector(ladder: ladder)
        let selection = selector.update(box: RenderBox(width: 160, height: 90, scale: 1))

        #expect(selection?.video == "video/180p")
    }

    @Test("gigabit fibre does not buy a thumbnail more pixels than it draws")
    func renderSizeBoundsEvenOnAFastLink() {
        var selector = LayerSelector(ladder: ladder)
        let selection = selector.update(
            box: RenderBox(width: 160, height: 90, scale: 2),
            allowance: NetworkAllowance(bitrate: 1_000_000_000)
        )

        #expect(selection?.video == "video/180p")
    }

    @Test("a degraded link does not get fullscreen quality")
    func networkBoundsEvenWhenFullscreen() {
        var selector = LayerSelector(ladder: ladder)
        let selection = selector.update(
            box: RenderBox(width: 390, height: 844, scale: 3),
            allowance: NetworkAllowance(bitrate: 700_000)
        )

        #expect(selection?.video == "video/360p")
        #expect(selection?.reason == .networkCapacity)
    }

    @Test("off screen drops video and keeps audio")
    func offScreenKeepsAudio() {
        var selector = LayerSelector(ladder: ladder)
        selector.update(box: RenderBox(width: 390, height: 220, scale: 3))

        let selection = selector.update(
            box: RenderBox(width: 390, height: 220, scale: 3, visibility: .offScreen)
        )

        #expect(selection?.video == nil)
        #expect(selection?.audio == true)
        #expect(selection?.reason == .notVisible)
    }

    @Test("a backgrounded app drops video too")
    func backgroundedDropsVideo() {
        var selector = LayerSelector(ladder: ladder)
        selector.update(box: RenderBox(width: 390, height: 220, scale: 3))
        let selection = selector.update(
            box: RenderBox(width: 390, height: 220, scale: 3, visibility: .appBackgrounded)
        )

        #expect(selection?.video == nil)
    }

    @Test("a momentarily occluded view keeps its subscription by default")
    func occlusionIsNotHidden() {
        // Occlusion is often a sheet being dismissed. Dropping video for it
        // costs a keyframe on the way back, which is worse than the saving.
        var selector = LayerSelector(ladder: ladder)
        selector.update(box: RenderBox(width: 390, height: 220, scale: 3))
        let selection = selector.update(
            box: RenderBox(width: 390, height: 220, scale: 3, visibility: .occluded)
        )

        #expect(selection == nil)
        #expect(selector.current?.video == "video/720p")
    }

    @Test("dragging a window across a rung boundary does not oscillate")
    func hysteresisPreventsOscillation() {
        // Every switch costs a keyframe, so a one-pixel wobble across the
        // boundary must not produce one.
        var selector = LayerSelector(ladder: ladder)
        selector.update(box: RenderBox(width: 320, height: 180, scale: 2))
        #expect(selector.current?.video == "video/360p")

        var switches = 0
        for step in 0 ..< 40 {
            let jitter = Double(step % 2)
            let changed = selector.update(
                box: RenderBox(width: 320 + jitter, height: 180 + jitter, scale: 2)
            )
            if changed != nil { switches += 1 }
        }

        #expect(switches == 0)
    }

    @Test("a real growth in size does climb the ladder")
    func hysteresisStillAllowsRealChanges() {
        var selector = LayerSelector(ladder: ladder)
        selector.update(box: RenderBox(width: 320, height: 180, scale: 2))
        let selection = selector.update(box: RenderBox(width: 640, height: 360, scale: 2))

        #expect(selection?.video == "video/720p")
    }

    @Test("coming back from hidden goes straight to the right rung")
    func returningFromHiddenDoesNotClimbOneStepAtATime() {
        var selector = LayerSelector(ladder: ladder)
        selector.update(box: RenderBox(width: 390, height: 220, scale: 3))
        selector.update(box: RenderBox(width: 390, height: 220, scale: 3, visibility: .offScreen))

        let selection = selector.update(box: RenderBox(width: 390, height: 220, scale: 3))
        #expect(selection?.video == "video/720p")
    }

    @Test("pre-warming starts the higher layer before the layout needs it")
    func prewarmAnticipatesFullscreen() {
        // Start on intent — hover or touch-down — so the frame is ready before
        // the animation finishes rather than a second after.
        var selector = LayerSelector(ladder: ladder)
        selector.update(box: RenderBox(width: 160, height: 90, scale: 2))
        #expect(selector.current?.video == "video/180p")

        selector.prewarm(for: RenderBox(width: 390, height: 844, scale: 3))
        let selection = selector.update(box: RenderBox(width: 160, height: 90, scale: 2))

        #expect(selection?.video == "video/1080p")
        #expect(selection?.reason == .prewarming)
    }

    @Test("pre-warming does not override a link that cannot carry it")
    func prewarmRespectsTheLink() {
        var selector = LayerSelector(ladder: ladder)
        selector.update(box: RenderBox(width: 160, height: 90, scale: 2))
        selector.prewarm(for: RenderBox(width: 390, height: 844, scale: 3))

        let selection = selector.update(
            box: RenderBox(width: 160, height: 90, scale: 2),
            allowance: NetworkAllowance(bitrate: 300_000)
        )

        #expect(selection?.video != "video/1080p")
    }

    @Test("a subscribe budget caps quality without refusing to render")
    func subscribeBudgetDegradesRatherThanRefusing() {
        var selector = LayerSelector(ladder: ladder)
        let selection = selector.update(
            box: RenderBox(width: 390, height: 844, scale: 3),
            allowance: NetworkAllowance(bitrate: .max, ceiling: "video/360p")
        )

        #expect(selection?.video == "video/360p")
        #expect(selection?.reason == .subscribeBudget)
    }

    @Test("an unchanged layout produces no subscription traffic")
    func idempotentUpdatesAreSilent() {
        var selector = LayerSelector(ladder: ladder)
        let box = RenderBox(width: 200, height: 120, scale: 2)

        let first = selector.update(box: box)
        let second = selector.update(box: box)
        let third = selector.update(box: box)

        #expect(first != nil)
        #expect(second == nil)
        #expect(third == nil)
    }

    @Test("screenshare uses a tighter band, because a resolution drop breaks legibility")
    func screenShareHasItsOwnPolicy() {
        let shareLadder = LayerLadder(
            rungs: LayerLadder.defaultCamera().rungs,
            kind: .screenShare
        )
        let selector = LayerSelector(ladder: shareLadder)

        #expect(selector.policy == .screenShare)
        #expect(selector.policy.upgradeFactor < LayerSelectionPolicy.default.upgradeFactor)
    }

    @Test("a publisher offering nothing yields audio only rather than a crash")
    func emptyLadderIsAudioOnly() {
        var selector = LayerSelector(ladder: LayerLadder(rungs: []))
        let selection = selector.update(box: RenderBox(width: 390, height: 220, scale: 3))

        #expect(selection?.video == nil)
        #expect(selection?.audio == true)
    }
}
