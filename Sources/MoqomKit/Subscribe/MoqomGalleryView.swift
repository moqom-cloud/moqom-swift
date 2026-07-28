// A grid of tiles that reports its own geometry.
//
// The SDK ships this rather than leaving it to each integrator because of one
// step everybody skips. Render-aware layer selection only works if every tile
// reports its size, and a hand-built grid that forgets ``moqomRenderBox`` on one
// branch looks completely normal: the video arrives, it is just the wrong
// resolution, and nobody can tell which of the two plausible causes it is.
// Making the grid the thing that reports means it cannot be left out.
//
// The tile content is the caller's. What is opinionated here is the arrangement
// and the reporting; what a participant looks like is a product decision, and an
// SDK that shipped an avatar with a name label would be wrong in every app that
// used it.

import Foundation
import MoqomCore

#if canImport(SwiftUI)
    import SwiftUI

    /// Lays a gallery's occupants out and tells the planner how big they are.
    ///
    /// ```swift
    /// MoqomGalleryView(gallery: room.gallery, reportingTo: room.layout) { slot in
    ///     ParticipantTile(slot: slot)
    /// }
    /// ```
    public struct MoqomGalleryView<Tile: View>: View {
        private let slots: [Gallery.Slot]
        private let observer: LayoutObserver
        private let aspect: Double
        private let spacing: Double
        private let tile: (Gallery.Slot) -> Tile

        /// - Parameters:
        ///   - aspect: Tile shape. `16/9` for camera video, `1` for the avatar
        ///     seats of an audio room.
        public init(
            slots: [Gallery.Slot],
            reportingTo observer: LayoutObserver,
            aspect: Double = 16.0 / 9.0,
            spacing: Double = 8,
            @ViewBuilder tile: @escaping (Gallery.Slot) -> Tile
        ) {
            self.slots = slots
            self.observer = observer
            self.aspect = aspect
            self.spacing = spacing
            self.tile = tile
        }

        public init(
            gallery: Gallery,
            reportingTo observer: LayoutObserver,
            aspect: Double = 16.0 / 9.0,
            spacing: Double = 8,
            @ViewBuilder tile: @escaping (Gallery.Slot) -> Tile
        ) {
            self.init(
                slots: gallery.slots,
                reportingTo: observer,
                aspect: aspect,
                spacing: spacing,
                tile: tile
            )
        }

        public var body: some View {
            GeometryReader { proxy in
                let grid = GalleryGrid.fitting(
                    count: slots.count,
                    in: (width: proxy.size.width, height: proxy.size.height),
                    aspect: aspect,
                    spacing: spacing
                )
                let size = grid.tile(
                    in: (width: proxy.size.width, height: proxy.size.height),
                    spacing: spacing
                )

                VStack(spacing: spacing) {
                    ForEach(Array(grid.rows(of: slots).enumerated()), id: \.offset) { _, row in
                        HStack(spacing: spacing) {
                            ForEach(row) { slot in
                                tile(slot)
                                    .frame(width: size.width, height: size.height)
                                    .moqomRenderBox(for: slot.identity, reportingTo: observer)
                            }
                        }
                    }
                }
                // A partly filled last row centres rather than stretching: the
                // alternative is a final tile several times the size of the
                // others, which reads as a spotlight nobody asked for.
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
    }
#endif
