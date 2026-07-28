// How many columns sixteen tiles want, and how big that makes each one.
//
// Separate from the view, and not a `LazyVGrid`, for two reasons that both end
// in the same place: the tile size is a subscription decision. A grid with a
// fixed column count wastes most of a landscape iPad and squeezes a portrait
// phone, and in both cases the tiles end up a different size than the layer the
// selector chose for them — so the client either downloads pixels it cannot show
// or upscales a rung it should have climbed past. Choosing the column count to
// maximise tile area is the difference between a 16-up grid serving 180p and the
// same grid serving 360p on the same screen.
//
// It is also arithmetic, which means it can be tested without a renderer, which
// is why it is here rather than inside the `View`.

import Foundation

/// A tile arrangement for a fixed number of participants.
public struct GalleryGrid: Hashable, Sendable {
    public let columns: Int
    public let rows: Int

    public init(columns: Int, rows: Int) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
    }

    /// The arrangement that gives each tile the most usable area.
    ///
    /// Usable rather than literal: a tile is only as good as the largest rect of
    /// `aspect` that fits inside it, because video letterboxes into whatever it
    /// is given. Ranking by raw tile area instead would pick tall thin columns
    /// for landscape video and fill the screen with black bars.
    ///
    /// - Parameters:
    ///   - count: How many tiles to place. Zero returns a 1×1.
    ///   - size: The container, in whatever unit the caller is working in.
    ///   - aspect: The tile's preferred width over height. `16/9` for camera
    ///     video, `1` for the avatar seats of an audio room.
    ///   - spacing: Gap between tiles, counted in both directions.
    public static func fitting(
        count: Int,
        in size: (width: Double, height: Double),
        aspect: Double = 16.0 / 9.0,
        spacing: Double = 0
    ) -> GalleryGrid {
        guard count > 1, size.width > 0, size.height > 0, aspect > 0 else {
            return GalleryGrid(columns: 1, rows: max(1, count))
        }

        var best = GalleryGrid(columns: 1, rows: count)
        var bestArea = -1.0

        for columns in 1 ... count {
            let rows = Int((Double(count) / Double(columns)).rounded(.up))
            let width = (size.width - spacing * Double(columns - 1)) / Double(columns)
            let height = (size.height - spacing * Double(rows - 1)) / Double(rows)
            guard width > 0, height > 0 else { continue }

            let usable = min(width, height * aspect) * min(height, width / aspect)
            if usable > bestArea {
                bestArea = usable
                best = GalleryGrid(columns: columns, rows: rows)
            }
        }

        return best
    }

    /// The size of one tile in a container of this size.
    public func tile(
        in size: (width: Double, height: Double),
        spacing: Double = 0
    ) -> (width: Double, height: Double) {
        (
            width: max(0, (size.width - spacing * Double(columns - 1)) / Double(columns)),
            height: max(0, (size.height - spacing * Double(rows - 1)) / Double(rows))
        )
    }

    /// Slice a list into rows of at most ``columns``.
    public func rows<Element>(of elements: [Element]) -> [[Element]] {
        guard !elements.isEmpty else { return [] }
        return stride(from: 0, to: elements.count, by: columns).map {
            Array(elements[$0 ..< min($0 + columns, elements.count)])
        }
    }
}
