// Putting several participants in one small window.
//
// The system gives a video call exactly one view controller and renders whatever
// view hierarchy is inside it, which means a multi-participant window is a
// question of arranging layers, not of producing a combined video. That
// distinction is the whole design. Compositing four participants into one pixel
// buffer — the obvious approach, and the one every "how do I do PiP with a grid"
// answer reaches for — requires the app to run a GPU pass per frame, and an app
// that submits GPU work while it is in the background is terminated by the
// system. Since being in the background is the entire point of Picture in
// Picture, that approach cannot work; it merely appears to, in the simulator,
// where the rule is not enforced.
//
// Four `AVSampleBufferDisplayLayer`s side by side have no such problem, because
// the decode and the scheduling belong to the media system rather than to us.
//
// The layers are borrowed rather than built. A second layer for the same
// participant would mean a second decode of the same track — the tile is a
// different size but the subscription is not, so there is nothing to gain and a
// hardware decode session to lose — so the window takes the layer the grid was
// already using and hands it back on the way out. The grid goes blank for those
// participants while the window is up, which is the same thing the system's own
// player does with an inline video that has moved to PiP.

import Foundation
import MoqomCore

#if os(iOS) || targetEnvironment(macCatalyst)
    import AVKit
    import UIKit

    /// Draws a room's Picture in Picture window and keeps the subscriptions
    /// honest while it is up.
    ///
    /// ```swift
    /// let window = MoqomPictureInPicture(room: room, layout: layout)
    /// window.source = videoGridView
    ///
    /// // From each tile, as it appears and goes away.
    /// window.register(tile.renderer, for: participant.id)
    ///
    /// await room.setPictureInPictureCast(.cohostsAndGuests)
    /// window.startsAutomatically = true
    /// ```
    ///
    /// The application still owns the renderers and still decides what a tile
    /// looks like everywhere else. What this owns is the window's contents, the
    /// arrangement inside it, and — the part that is easy to leave out and
    /// expensive to leave out — telling the layer selector that nine large tiles
    /// have become four small ones.
    ///
    /// > Important: Requires the *Audio, AirPlay, and Picture in Picture*
    /// > background mode. Without it the system refuses to start the window and
    /// > reports the refusal through ``onFailure``.
    @MainActor
    public final class MoqomPictureInPicture: NSObject {
        /// What the window is drawing, in order.
        public private(set) var slots: [Gallery.Slot] = []

        /// Whether the system currently has the window on screen.
        public private(set) var isActive = false

        /// Enter the window when the app is backgrounded, without being asked.
        ///
        /// The behaviour a viewer expects from a video app, and the reason the
        /// source view matters: the system starts the window only if that view
        /// is large and visible, so pointing this at a container that happens to
        /// be zero-sized produces a feature that silently never triggers.
        public var startsAutomatically = true {
            didSet { controller?.canStartPictureInPictureAutomaticallyFromInline = startsAutomatically }
        }

        /// The view the window flies out of, and back into.
        ///
        /// Settable rather than an initialiser argument because in SwiftUI the
        /// `UIView` does not exist until the hierarchy has been built, which is
        /// after everything that wants to own this controller. Setting it
        /// rebuilds the content source, which is cheap and idempotent.
        ///
        /// The system reads this view's frame and visibility to decide whether
        /// to start automatically, so it should be the video itself rather than
        /// a wrapper around it.
        public weak var source: UIView? {
            didSet {
                guard source !== oldValue else { return }
                rebuildContentSource()
            }
        }

        /// Whether the device supports Picture in Picture at all.
        public static var isSupported: Bool {
            AVPictureInPictureController.isPictureInPictureSupported()
        }

        /// Bring the application's own interface back before the window closes.
        ///
        /// Called when the user taps the window's restore control. Whatever it
        /// does must finish before calling the completion handler, or the
        /// animation runs against a screen that has not been rebuilt yet.
        public var onRestoreInterface: (@MainActor (@escaping (Bool) -> Void) -> Void)?

        /// The system refused to start, or stopped with an error.
        public var onFailure: (@MainActor (any Error) -> Void)?

        private let room: RoomSession
        private let layout: LayoutObserver
        private let tiles = PictureInPictureTiles()
        private let content = AVPictureInPictureVideoCallViewController()
        private var controller: AVPictureInPictureController?
        private var events: Task<Void, Never>?

        /// The layer already drawing each participant, as the tiles report
        /// themselves.
        ///
        /// Weak, because the view that owns a renderer can be torn down while
        /// the window is up — a backgrounded app whose room screen is purged
        /// under memory pressure — and a strong map would keep a decode session
        /// alive for a tile that no longer exists.
        private var renderers = [ParticipantIdentity: WeakRenderer]()

        public init(room: RoomSession, layout: LayoutObserver) {
            self.room = room
            self.layout = layout
            super.init()

            content.view.backgroundColor = .black
            content.view.addSubview(tiles)
            tiles.frame = content.view.bounds
            tiles.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            tiles.onResize = { [weak self] in self?.reportGeometry() }

            follow()
        }

        deinit { events?.cancel() }

        // MARK: - Tiles

        /// Tell the window where a participant is being drawn.
        ///
        /// Call it as the tile appears. Registration rather than a lookup
        /// closure because the tile is the thing that knows: in SwiftUI a
        /// renderer is created by a coordinator and destroyed with the view, so
        /// a closure would oblige every application to keep a parallel registry
        /// of its own and to remember to prune it.
        public func register(_ renderer: VideoRenderer, for identity: ParticipantIdentity) {
            renderers[identity] = WeakRenderer(renderer)
            guard isActive, slots.contains(where: { $0.identity == identity }) else { return }
            adopt()
        }

        /// The tile has gone away.
        ///
        /// Hands the layer back first if the window had borrowed it, so a tile
        /// dismantled during Picture in Picture does not leave a layer parented
        /// to a window that is about to close.
        public func unregister(_ identity: ParticipantIdentity) {
            renderers.removeValue(forKey: identity)
            tiles.release(identity)
        }

        private func adopt() {
            tiles.show(slots.map(\.identity)) { [renderers] identity in
                renderers[identity]?.renderer?.layer
            }
        }

        /// Ask for the window now, from the foreground.
        ///
        /// Prefer ``startsAutomatically``. This exists for the explicit button
        /// some products want, and it does nothing if the system has already
        /// started or the device does not support it.
        public func start() {
            guard let controller, !controller.isPictureInPictureActive else { return }
            controller.startPictureInPicture()
        }

        public func stop() {
            controller?.stopPictureInPicture()
        }

        private func rebuildContentSource() {
            guard let source else {
                controller = nil
                return
            }
            let content = AVPictureInPictureController.ContentSource(
                activeVideoCallSourceView: source,
                contentViewController: content
            )
            controller = AVPictureInPictureController(contentSource: content)
            controller?.delegate = self
            controller?.canStartPictureInPictureAutomaticallyFromInline = startsAutomatically
        }

        // MARK: - Occupancy

        private func follow() {
            events = Task { [weak self] in
                guard let self else { return }
                // Not `room.events`: that stream has one consumer, and taking
                // from it would leave the application receiving a fraction of
                // its own room's events with nothing to suggest why.
                for await slots in await room.pictureInPictureUpdates() {
                    await MainActor.run { self.show(slots) }
                }
            }
        }

        private func show(_ slots: [Gallery.Slot]) {
            guard slots.map(\.identity) != self.slots.map(\.identity) else {
                self.slots = slots
                return
            }
            self.slots = slots

            // Only while the window is up, and that qualification is the whole of this
            // line. Adopting borrows the layer the grid is drawing into, so doing it on a
            // roster change with no window on screen takes the picture out of the
            // application's own tile and parents it inside a view controller nobody is
            // looking at. Every counter keeps reading perfectly — the track arrives, the
            // frames decode, the layer presents — and the tile is black. Starting the
            // window adopts, which is where borrowing belongs.
            if isActive { adopt() }

            // Drives the window's shape. A single participant is 16:9; a 2x2 of
            // 16:9 tiles is also 16:9, and a side-by-side pair is 32:9, which is
            // a window the system will draw as a thin strip — correct, because
            // that is genuinely what two landscape videos side by side are.
            let grid = tiles.grid(for: slots.count)
            content.preferredContentSize = CGSize(
                width: grid.columns * 16,
                height: grid.rows * 9
            )

            if isActive { reportGeometry() }
        }

        // MARK: - Layout

        /// Tell the layer selector the tiles are small now.
        ///
        /// The reason this class needs the ``LayoutObserver`` at all. Everyone
        /// the window is not drawing is left out of the reported layout
        /// entirely, which drops their video and keeps their audio — a viewer
        /// who backgrounds a six-way conversation to watch two of them should
        /// still hear the other four.
        private func reportGeometry() {
            guard isActive else { return }
            let scale = content.view.traitCollection.displayScale
            let boxes = tiles.sizes.reduce(into: [ParticipantIdentity: RenderBox]()) {
                $0[$1.key] = RenderBox(
                    width: $1.value.width,
                    height: $1.value.height,
                    scale: scale > 0 ? scale : 1,
                    visibility: .visible
                )
            }
            guard !boxes.isEmpty else { return }
            layout.takeOver(boxes)
        }
    }

    // The conformance is isolated rather than the methods being `nonisolated`
    // with a hop inside. AVKit calls these on the main thread and the work they
    // do — reparenting layers, restating the layout — has to happen before the
    // transition animation, so hopping would put it a turn too late and show
    // the window animating out of an empty rectangle.
    extension MoqomPictureInPicture: @MainActor AVPictureInPictureControllerDelegate {
        public func pictureInPictureControllerDidStartPictureInPicture(
            _: AVPictureInPictureController
        ) {
            isActive = true
            adopt()
            reportGeometry()
        }

        public func pictureInPictureControllerDidStopPictureInPicture(
            _: AVPictureInPictureController
        ) {
            isActive = false
            tiles.releaseAll()

            // Before the grid has laid out again, so there is no window in
            // which the selector believes the layout is still four thumbnails
            // and serves the returning full-screen grid its bottom rung.
            layout.restore()
        }

        public func pictureInPictureController(
            _: AVPictureInPictureController,
            failedToStartPictureInPictureWithError error: any Error
        ) {
            isActive = false
            tiles.releaseAll()
            layout.restore()
            onFailure?(error)
        }

        public func pictureInPictureController(
            _: AVPictureInPictureController,
            restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completion:
            @escaping (Bool) -> Void
        ) {
            guard let onRestoreInterface else {
                completion(true)
                return
            }
            onRestoreInterface(completion)
        }
    }

    @MainActor
    private struct WeakRenderer {
        weak var renderer: VideoRenderer?
        init(_ renderer: VideoRenderer) { self.renderer = renderer }
    }

    /// The window's contents: a grid of layers borrowed from elsewhere.
    @MainActor
    private final class PictureInPictureTiles: UIView {
        /// A layer taken from the application's own hierarchy, and how to put
        /// it back.
        ///
        /// The home is held weakly because the view that owned the layer may be
        /// torn down while the window is up — a viewer who backgrounds the app
        /// and gets their room view purged under memory pressure. A layer with
        /// nowhere to go home to is simply dropped, and the grid builds a fresh
        /// one when it next lays out.
        private struct Borrowed {
            let layer: CALayer
            weak var home: CALayer?
            let frame: CGRect
        }

        private var borrowed: [ParticipantIdentity: Borrowed] = [:]
        private var order: [ParticipantIdentity] = []

        /// How big each tile ended up, in points.
        private(set) var sizes: [ParticipantIdentity: CGSize] = [:]

        var onResize: (@MainActor () -> Void)?

        func grid(for count: Int) -> GalleryGrid {
            GalleryGrid.fitting(
                count: max(1, count),
                in: (width: Double(bounds.width), height: Double(bounds.height))
            )
        }

        /// Adopt the layers for these participants, releasing any others.
        func show(
            _ identities: [ParticipantIdentity],
            provider: (ParticipantIdentity) -> CALayer?
        ) {
            order = identities
            let wanted = Set(identities)

            for (identity, entry) in borrowed where !wanted.contains(identity) {
                hand(back: entry)
                borrowed.removeValue(forKey: identity)
            }

            for identity in identities where borrowed[identity] == nil {
                guard let layer = provider(identity) else { continue }
                borrowed[identity] = Borrowed(
                    layer: layer,
                    home: layer.superlayer,
                    frame: layer.frame
                )
                self.layer.addSublayer(layer)
            }

            setNeedsLayout()
        }

        func releaseAll() {
            for entry in borrowed.values { hand(back: entry) }
            borrowed.removeAll()
            sizes.removeAll()
            order = []
        }

        /// Give one participant's layer back, leaving the rest alone.
        func release(_ identity: ParticipantIdentity) {
            guard let entry = borrowed.removeValue(forKey: identity) else { return }
            hand(back: entry)
            sizes.removeValue(forKey: identity)
            setNeedsLayout()
        }

        private func hand(back entry: Borrowed) {
            entry.layer.removeFromSuperlayer()
            guard let home = entry.home else { return }
            home.addSublayer(entry.layer)
            entry.layer.frame = entry.frame
            // The frame above is only good until the owning view lays out
            // again, and a view whose sublayer disappeared and came back has no
            // reason to think it needs to. Asking is cheap and skipping it
            // leaves the returned tile at whatever size the grid was when the
            // window opened.
            (home.delegate as? UIView)?.setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()

            let placed = order.compactMap { identity in
                borrowed[identity].map { (identity, $0.layer) }
            }
            guard !placed.isEmpty, bounds.width > 0, bounds.height > 0 else {
                sizes = [:]
                return
            }

            let grid = grid(for: placed.count)
            let width = bounds.width / CGFloat(grid.columns)
            let height = bounds.height / CGFloat(grid.rows)

            var measured: [ParticipantIdentity: CGSize] = [:]
            for (index, entry) in placed.enumerated() {
                let column = index % grid.columns
                let row = index / grid.columns

                // The last row centres rather than stretching. Three tiles in a
                // 2x2 means one alone on the bottom row, and giving it the full
                // width would read as a spotlight the layout never chose.
                let inRow = min(grid.columns, placed.count - row * grid.columns)
                let inset = (bounds.width - CGFloat(inRow) * width) / 2

                // Layers are positioned rather than laid out, so this must not
                // animate: an implicit animation here would leave every tile
                // sliding across a window that is a fifth of the screen.
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                entry.1.frame = CGRect(
                    x: inset + CGFloat(column) * width,
                    y: CGFloat(row) * height,
                    width: width,
                    height: height
                )
                CATransaction.commit()

                measured[entry.0] = CGSize(width: width, height: height)
            }

            guard measured != sizes else { return }
            sizes = measured
            onResize?()
        }
    }
#endif
