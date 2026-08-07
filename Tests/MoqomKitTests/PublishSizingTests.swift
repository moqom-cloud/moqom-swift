import MoqomCore
import Testing

/// Choosing a publish size for a box.
@Suite("Publish sizing")
struct PublishSizingTests {
    @Test("the measured tiles take the step below rather than doubling the pixels")
    func theMeasuredCase() {
        // The two phones side by side: 554 short side on the Pro, 594 on the Air, against a
        // publication of 720. Both are within an eighth of 540, so both take it.
        #expect(PublishSizing.shortSide(for: 554) == 540)
        #expect(PublishSizing.shortSide(for: 594) == 540)
    }

    @Test("covering is still the preference")
    func coversWhereItCan() {
        // Nothing here is close enough below a step to be worth the shortfall, so each takes the
        // step that covers it.
        #expect(PublishSizing.shortSide(for: 360) == 360)
        #expect(PublishSizing.shortSide(for: 420) == 540)
        #expect(PublishSizing.shortSide(for: 640) == 720)
        #expect(PublishSizing.shortSide(for: 1000) == 1080)
    }

    @Test("never short by more than the bound")
    func theShortfallIsBounded() {
        for box in 1 ... 1200 {
            let chosen = PublishSizing.shortSide(for: box)
            guard chosen < box else { continue }
            let missing = Double(box - chosen) / Double(box)
            #expect(missing <= PublishSizing.acceptableShortfall)
        }
    }

    @Test("a box past the top takes the top")
    func clampsAtTheTop() {
        #expect(PublishSizing.shortSide(for: 4000) == 1080)
    }

    @Test("a box below the bottom takes the bottom")
    func clampsAtTheBottom() {
        #expect(PublishSizing.shortSide(for: 1) == 180)
        #expect(PublishSizing.shortSide(for: 0) == 180)
    }

    @Test("the answer never falls as the box grows")
    func risesWithTheBox() {
        var last = 0
        for box in 1 ... 1200 {
            let chosen = PublishSizing.shortSide(for: box)
            #expect(chosen >= last)
            last = chosen
        }
    }

    @Test("no shortfall allowed is strict covering")
    func zeroShortfallCovers() {
        #expect(PublishSizing.shortSide(for: 554, shortfall: 0) == 720)
        #expect(PublishSizing.shortSide(for: 541, shortfall: 0) == 720)
        #expect(PublishSizing.shortSide(for: 540, shortfall: 0) == 540)
    }
}
