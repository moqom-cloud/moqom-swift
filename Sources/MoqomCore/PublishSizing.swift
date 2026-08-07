// Choosing what size to publish for a box of a known size.
//
// Deliberately not ``LayerLadder/lowestCovering(pixels:)``, and the difference is worth stating
// because the two look like the same question. That one is a *subscriber* picking a rung from a
// ladder somebody else built, where the rungs are an octave apart and the nearest one below a box
// can be a third smaller — enough to see, which is why it refuses to go below.
//
// This is a *publisher* choosing its own size, and it has the one thing the subscriber lacks:
// control over how far below the box it lands. Bounded at an eighth, the far end upscales by
// 1.14× and nobody sees it, and the pixels saved are real — measured on two phones side by side,
// the tiles were 554 pixels on the short side and the publication was 720, so covering strictly
// meant 720×1280 where 540×960 would do. That is 44% of the pixels, and by the same ratio most
// of the bitrate and the encode, spent on detail that was scaled away before it was seen.

/// Choosing a size to publish at, for a picture that lands in a box of known size.
public enum PublishSizing: Sendable {
    /// The short sides worth publishing at.
    ///
    /// The default ladder's rungs plus 540, so a viewer that does choose for itself is mostly
    /// choosing between sizes it already expects. Coarse on purpose: for a live publication every
    /// step is a reshape, and a reshape is a keyframe.
    public static let steps = [180, 360, 540, 720, 1080]

    /// How much smaller than its box a picture may be published, against the box's short side.
    ///
    /// An eighth. The far end upscales by 1.14× to fill the box, which on a phone is not a thing
    /// anybody can point to — the display is resampling anyway. Twice this would start to soften
    /// edges and small text, so it is a bound rather than a preference: the aim is still to cover
    /// the box, and this only says when missing by a little is better than doubling the pixels.
    public static let acceptableShortfall = 0.125

    /// The short side to publish for a box whose short side is `box` device pixels.
    ///
    /// - Parameters:
    ///   - box: The short side of the box the picture lands in, in device pixels.
    ///   - steps: The sizes to choose between. Assumed ascending.
    ///   - shortfall: How far below the box the answer may land. See ``acceptableShortfall``.
    public static func shortSide(
        for box: Int,
        steps: [Int] = steps,
        shortfall: Double = acceptableShortfall
    ) -> Int {
        guard let smallest = steps.first, let largest = steps.last else { return box }
        guard box > 0 else { return smallest }

        // The smallest step that leaves no more than `shortfall` of the box uncovered. Expressed
        // as a floor on the step rather than a search for the nearest, so the answer is still the
        // lowest covering step wherever one is close enough — this only ever moves the boundary,
        // never the preference for covering.
        let least = Double(box) * (1 - shortfall)
        return steps.first { Double($0) >= least } ?? largest
    }
}
