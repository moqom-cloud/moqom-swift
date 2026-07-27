import Testing

@testable import MoqomCore

@Suite("Layer ladders")
struct LayerLadderTests {
    private let ladder = LayerLadder.defaultCamera()

    @Test("rungs are sorted on construction rather than trusted to be ordered")
    func rungsAreSorted() {
        let shuffled = LayerLadder(rungs: [
            VideoLayer(id: "b", size: PixelSize(width: 1280, height: 720), frameRate: 30, bitrate: 2),
            VideoLayer(id: "a", size: PixelSize(width: 320, height: 180), frameRate: 30, bitrate: 1),
        ])
        #expect(shuffled.rungs.map(\.id) == ["a", "b"])
    }

    @Test("selection snaps up, never to the nearest rung")
    func snapsUpward() {
        // 480×270 sits between 180p and 360p. Snapping to the nearest would
        // pick 180p and upscale on the client, which looks worse than the
        // bandwidth saving is worth.
        let chosen = ladder.lowestCovering(pixels: 480 * 270)
        #expect(chosen?.id == "video/360p")
    }

    @Test("a box larger than the top rung gets the top rung")
    func clampsToTop() {
        let chosen = ladder.lowestCovering(pixels: 4096 * 2160)
        #expect(chosen?.id == "video/1080p")
    }

    @Test("a link too poor for any rung still gets the base layer")
    func degradesRatherThanRefusing() {
        let chosen = ladder.highestWithin(bitrate: 1000)
        #expect(chosen?.id == "video/180p")
    }

    @Test("the network bound picks the most expensive rung that fits")
    func networkBound() {
        #expect(ladder.highestWithin(bitrate: 1_000_000)?.id == "video/360p")
        #expect(ladder.highestWithin(bitrate: 2_000_000)?.id == "video/720p")
    }

    @Test("an empty ladder means audio only rather than a crash")
    func emptyLadder() {
        let empty = LayerLadder(rungs: [])
        #expect(empty.isEmpty)
        #expect(empty.lowestCovering(pixels: 1000) == nil)
    }
}
