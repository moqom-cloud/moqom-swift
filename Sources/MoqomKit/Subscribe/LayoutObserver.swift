// Getting the layout into the subscription planner.
//
// Render-aware layer selection only works if something tells it what the layout
// is, and asking every integrator to plumb view sizes into an actor by hand is
// how the feature ends up unused. The view already knows its size; the job is
// to collect the sizes for a whole layout pass and hand them over as one.
//
// Batched deliberately. SwiftUI resolves geometry one view at a time, so a
// nine-tile grid rotating produces nine size changes, and forwarding each one
// would produce nine rounds of subscription churn for a layout that settles in
// a single frame. Coalescing to the end of the run loop turns that into one
// diff — which is also the only form the relay should ever see, since the
// intermediate states were never rendered.

import Foundation
import MoqomCore

#if canImport(SwiftUI)
    import SwiftUI

    /// Collects render geometry from a view hierarchy and forwards it to a room.
    ///
    /// Main-actor bound because it is driven by layout, and `@Observable` so a
    /// debug overlay can watch what the selector is being told.
    @MainActor
    @Observable
    public final class LayoutObserver {
        private var boxes: [ParticipantIdentity: RenderBox] = [:]
        private var flush: Task<Void, Never>?
        private weak var room: RoomSession?

        /// The most recent estimate of the downlink, shared across everything
        /// being drawn. `.max` means unconstrained, which is the right default:
        /// guessing low costs quality that the render size did not ask to lose.
        public var linkBitrate: Int = .max

        /// What the planner was last told, for diagnostics.
        public private(set) var lastReported: [ParticipantIdentity: RenderBox] = [:]

        /// Called when a layout pass has settled, with the boxes the planner was told about.
        ///
        /// For a publisher rather than a subscriber, which is the part that is not obvious. The
        /// sizes collected here decide what this device *subscribes* to, and they are also the
        /// only description anywhere of how big a picture actually needs to be. A call whose
        /// two ends run the same layout can read its own tiles to know the box its own picture
        /// lands in at the far end, and publish for that box instead of for the largest one it
        /// might ever have landed in.
        ///
        /// Deliberately not the same thing as observing ``lastReported``: this fires once per
        /// settled pass, after the coalescing, so a nine-tile grid rotating calls it once.
        public var onReport: (@MainActor ([ParticipantIdentity: RenderBox]) -> Void)?

        /// A layout that replaces the view hierarchy's, or `nil` when the
        /// hierarchy is in charge.
        public private(set) var takenOver: [ParticipantIdentity: RenderBox]?

        public init(room: RoomSession? = nil) {
            self.room = room
        }

        public func bind(to room: RoomSession) {
            self.room = room
        }

        /// Which view last reported each participant, so a departing one cannot
        /// withdraw its replacement's box. See ``withdraw(_:from:)``.
        private var reporters: [ParticipantIdentity: UUID] = [:]

        /// What is collected but not yet handed over, for tests.
        ///
        /// ``lastReported`` is the same thing after a flush, and a flush waits for the end of
        /// the run loop — which is the wrong thing to assert about when the question is what a
        /// single report or withdrawal did.
        var current: [ParticipantIdentity: RenderBox] { boxes }

        /// Record where a participant is being drawn.
        public func report(_ box: RenderBox, for identity: ParticipantIdentity) {
            report(box, for: identity, from: nil)
        }

        func report(_ box: RenderBox, for identity: ParticipantIdentity, from reporter: UUID?) {
            if let reporter { reporters[identity] = reporter }
            guard boxes[identity] != box else { return }
            boxes[identity] = box
            scheduleFlush()
        }

        /// Record that a participant is no longer on screen.
        ///
        /// Distinct from a zero-sized box: a tile scrolled out of a list keeps
        /// its size and stops being drawn, and the planner treats those the
        /// same way only because both end in dropping video.
        public func withdraw(_ identity: ParticipantIdentity) {
            withdraw(identity, from: nil)
        }

        /// The same, from a view that may already have been replaced.
        ///
        /// A withdrawal from a view that no longer owns the tile is ignored, and that is the
        /// whole reason the token exists. SwiftUI builds a view's replacement before it takes
        /// the original away, so any change that moves a tile — a different arrangement, a
        /// grid that reflows, a stage that puts the gallery somewhere else — runs the new
        /// tile's first report and *then* the old tile's disappearance. Unconditional, that
        /// second step deletes the box the new tile just reported, the planner is told the
        /// participant is not being drawn, and it unsubscribes. Nothing reports again, because
        /// the surviving tile's geometry has not changed since, so the video stops for good
        /// and every counter says the link is healthy.
        func withdraw(_ identity: ParticipantIdentity, from reporter: UUID?) {
            if let reporter, let owner = reporters[identity], owner != reporter { return }
            reporters[identity] = nil
            guard boxes.removeValue(forKey: identity) != nil else { return }
            scheduleFlush()
        }

        /// Push the current layout without waiting for the coalescing window.
        public func flushNow() async {
            flush?.cancel()
            flush = nil
            await deliver()
        }

        /// Draw somewhere the view hierarchy cannot see, and report that
        /// instead of what the hierarchy says.
        ///
        /// Picture in Picture is the case this exists for, and it is a
        /// replacement rather than an addition for a reason that only shows up
        /// on a bill. Backgrounding an app does not tear its views down: every
        /// `GeometryReader` in the grid still holds the size it had when the
        /// user swiped home, so a window that merely *added* four small boxes
        /// would leave nine large ones in place and keep paying for full-size
        /// video to draw thumbnails — with the screen off, where nothing looks
        /// wrong until the data usage is read back a month later.
        ///
        /// The hierarchy keeps reporting underneath. Nothing is lost, so
        /// ``restore()`` puts the grid back in one pass rather than waiting for
        /// a layout that only happens once the app is visible again.
        public func takeOver(_ boxes: [ParticipantIdentity: RenderBox]) {
            guard takenOver != boxes else { return }
            takenOver = boxes
            scheduleFlush()
        }

        /// Hand the layout back to the view hierarchy.
        public func restore() {
            guard takenOver != nil else { return }
            takenOver = nil
            scheduleFlush()
        }

        private func scheduleFlush() {
            guard flush == nil else { return }
            flush = Task { [weak self] in
                // One turn of the main actor, which is after SwiftUI has
                // finished resolving the pass that triggered this.
                await Task.yield()
                guard let self, !Task.isCancelled else { return }
                flush = nil
                await deliver()
            }
        }

        private func deliver() async {
            guard let room else { return }
            let snapshot = takenOver ?? boxes
            lastReported = snapshot
            onReport?(snapshot)
            _ = await room.updateLayout(snapshot, linkBitrate: linkBitrate)
        }
    }

    public extension View {
        /// Report this view's size to the layer selector.
        ///
        /// Apply it to the view the remote video is drawn into, not to a
        /// container: the selector is choosing a decode resolution and a
        /// padding difference is the difference between two rungs.
        ///
        /// ```swift
        /// RemoteVideoView(participant: person)
        ///     .moqomRenderBox(for: person.identity, reportingTo: layout)
        /// ```
        func moqomRenderBox(
            for identity: ParticipantIdentity,
            reportingTo observer: LayoutObserver
        ) -> some View {
            modifier(RenderBoxReporter(identity: identity, observer: observer))
        }
    }

    private struct RenderBoxReporter: ViewModifier {
        let identity: ParticipantIdentity
        let observer: LayoutObserver

        /// This view's claim on the identity, for as long as SwiftUI keeps the view alive.
        ///
        /// `@State` rather than a stored property because a modifier is a value that is
        /// rebuilt on every update: a stored `UUID()` would be a new token each pass and would
        /// mean nothing. State is keyed to the view's identity, which is exactly the lifetime
        /// being tracked — the same tile keeps its token across updates, and a tile SwiftUI
        /// rebuilds gets a new one.
        @State private var token = UUID()

        // Points are not pixels and the ladder is in pixels. A 320pt tile is
        // two different subscriptions on a 2x phone and a 3x one, and taking
        // the scale from the environment is the only way to get it right on an
        // external display.
        @Environment(\.displayScale) private var displayScale

        func body(content: Content) -> some View {
            content
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .onChange(of: proxy.size, initial: true) { _, size in
                                observer.report(
                                    RenderBox(
                                        width: size.width,
                                        height: size.height,
                                        scale: displayScale
                                    ),
                                    for: identity,
                                    from: token
                                )
                            }
                    }
                }
                .onDisappear { observer.withdraw(identity, from: token) }
        }
    }
#endif
