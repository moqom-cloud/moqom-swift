// The surface a remote participant is drawn into.
//
// A layer-backed representable rather than a SwiftUI-native view, because
// `AVSampleBufferDisplayLayer` is what decodes and schedules against the
// display; drawing decoded frames through SwiftUI would mean a texture upload
// per frame and a compositor pass that the layer already does for free.
//
// The size this view resolves to is not just layout — `.moqomRenderBox` on the
// caller reports it to the layer selector, and it is what decides which rung of
// the ladder gets subscribed to. So the modifier belongs on this view and not
// on a padded container around it.

import AVFoundation
import MoqomCore
import MoqomKit
import SwiftUI

struct RemoteVideoView: View {
    let participant: Participant
    let isSelf: Bool
    let room: RoomModel

    var body: some View {
        picture
            .background(.black)
            .overlay {
                if participant.presence != .connected {
                    Image(systemName: "person.crop.circle.badge.clock")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                } else if participant.mute.effective.contains(.video) {
                    // The reason a mute is published rather than inferred from the
                    // objects stopping. Without the catalog saying so, this tile
                    // would show a frozen last frame and no way to tell it from a
                    // stalled uplink.
                    stopped
                }
            }
    }

    /// Why this tile is not moving.
    ///
    /// Two icons rather than one, because the two cases ask different things of
    /// whoever is watching. A camera somebody turned off is settled and needs no
    /// response; a camera their phone took away is temporary, usually resolves
    /// by itself, and — the case this was built for — is invisible to the person
    /// it is happening to, who is looking at another app.
    @ViewBuilder
    private var stopped: some View {
        if participant.mute.reason(for: .video) == .interrupted {
            VStack(spacing: 6) {
                Image(systemName: "video.badge.ellipsis")
                    .font(.largeTitle)
                Text(isSelf ? "Your camera was interrupted" : "Camera interrupted")
                    .font(.caption2)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.orange)
            .padding(6)
        } else {
            Image(systemName: "video.slash.fill")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
        }
    }

    /// The scene itself for a device publishing one, and decoded frames for everything else.
    ///
    /// Not a preview of the published frames in the AR case, and it could not be: RealityKit
    /// draws only what is in a window, so this view is what makes the scene exist at all.
    /// The tile's size is therefore also the drawable's, which is why the scene switches the
    /// screen to full width when it starts.
    @ViewBuilder
    private var picture: some View {
        #if canImport(ARKit) && !targetEnvironment(simulator)
            if isSelf, room.videoInput == .scene, let scene = room.arScene {
                ARSceneView(source: scene)
            } else {
                layer
            }
        #else
            layer
        #endif
    }

    // Read here rather than inside the representable so that observation actually sees it. A
    // property read in `updateUIView` is not a body read, and the flip button would leave the
    // preview facing the wrong way until something else happened to redraw the tile.
    private var layer: some View {
        VideoLayerView(
            identity: participant.slot.identity,
            isSelf: isSelf,
            isMirrored: isSelf && room.isPreviewMirrored,
            room: room
        )
    }
}

/// Pumps one participant's frames into one layer.
///
/// A class rather than a `.task` on the view, because a SwiftUI task is tied to
/// the view's identity and a grid that reorders would tear the pump down and
/// restart it mid-group — which costs a flush and a wait for the next keyframe
/// every time somebody joins.
///
/// Owned by the room and keyed by participant — see ``RoomModel/tile(for:)`` — rather than
/// held in the representable's coordinator, which is where it used to live and where it was
/// wrong. A coordinator belongs to a view, and a layout change replaces the view: SwiftUI
/// builds the replacement, dismantles the original, and does not promise which of the two ends
/// up on screen. When it kept the first, the pump had already been cancelled with it, and the
/// second — the one still reading frames — was drawing into a layer inside a discarded view.
/// Every counter agreed the stream was perfect, because it was. It was landing somewhere
/// nobody could see.
@MainActor
final class VideoTile {
    // A renderer per tile. Sharing one across tiles would mean sharing one
    // decode session, and the whole point of subscribing per-tile is that the
    // tiles are at different resolutions.
    let renderer = VideoRenderer()

    /// How many tiles exist right now, across the whole app.
    ///
    /// A census rather than a counter of anything meaningful, kept because the failure it
    /// detects is invisible from inside any one tile: SwiftUI rebuilding a tile leaves two of
    /// these alive for the same participant, and one stream cannot feed both. Whichever pump
    /// wins reports perfect health, and the layer a person is looking at belongs to the other.
    /// One per remote participant plus one for the self view is the whole expected population.
    private(set) static var live = 0

    private var pump: Task<Void, Never>?

    /// This tile's own tap on the capture path, held so it can be stopped.
    private var preview: MediaTap<VideoFrame>?

    init() { Self.live += 1 }

    /// Draw what this device is capturing.
    ///
    /// A different path from the remote one and deliberately so: nothing is
    /// encoded, relayed, or decoded, so the preview keeps working when the
    /// publication does not.
    ///
    /// The same loop as ``attach(to:in:)``, and for the same reason. Stop ends the
    /// publication, which ends the tap this is reading; a pump that drained once then
    /// returned left `pump` set and ``attachPreview(in:)`` refusing to start again.
    /// Go live after that published a new camera — viewers saw it — while this tile
    /// still held the last frame of the previous one.
    func attachPreview(in room: RoomModel) {
        guard pump == nil else { return }
        pump = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.followPreview(in: room)
                if !Task.isCancelled { try? await Task.sleep(for: .milliseconds(100)) }
            }
        }
    }

    /// Take one broadcast's capture and draw it until that broadcast ends.
    private func followPreview(in room: RoomModel) async {
        var tap: MediaTap<VideoFrame>?
        while tap == nil, !Task.isCancelled {
            tap = await room.localPreview()
            if tap == nil { try? await Task.sleep(for: .milliseconds(100)) }
        }
        guard let tap else { return }
        preview?.stop()
        preview = tap
        defer {
            tap.stop()
            preview = nil
        }
        var drawn = 0
        for await frame in tap.elements {
            renderer.enqueue(frame)

            // The control for the received tile's own figure. This layer is on the same
            // screen, in the same app, fed by the same camera — and nothing schedules it:
            // frames go in as they are captured. So a drop count here is the panel's, and
            // a drop count only on the other layer is ours.
            drawn += 1
            if drawn % 30 == 0 {
                // Off the pump. `loadVideoPerformanceMetrics` was awaited here and took
                // about two hundred milliseconds, twice a second — which is forty percent
                // of the call spent not reading the next frame, and is exactly the stall
                // overlay: `every 0.5s`, `frozen=39%`, a median gap of half a frame as
                // the ones that piled up during the wait then arrived in a clump.
                Task { @MainActor in
                    if let presentation = await renderer.presentation() {
                        room.previewPresentation = presentation
                    }
                }
            }
        }
    }

    func attach(to identity: ParticipantIdentity, in room: RoomModel) {
        guard pump == nil else { return }
        pump = Task { [weak self] in
            // Once per stream, not once per tile. A participant's frames come from a sink the
            // session throws away whenever it stops subscribing to them — a seat given up, a
            // catalog that ended, a reconnection — and the replacement is a different stream
            // that this tile was never handed. Draining once and returning left the tile
            // black from that moment on while every counter upstream reported frames arriving
            // by the hundred, which is precisely as diagnosable as it sounds.
            while !Task.isCancelled {
                guard let self else { return }
                await self.follow(identity, in: room)

                // Beaten only by cancellation. Nothing here distinguishes "the stream ended
                // because the participant left for good" from "it ended and will be back in
                // two seconds"; the tile is destroyed either way when the roster says so.
                if !Task.isCancelled { try? await Task.sleep(for: .milliseconds(100)) }
            }
        }
    }

    /// Take one stream of this participant's frames and draw it until it ends.
    private func follow(_ identity: ParticipantIdentity, in room: RoomModel) async {
        // The stream does not exist until the planner has subscribed, and
        // subscribing waits on a layout pass. Polling rather than being
        // notified is the small price of not putting a second event
        // channel in the sample.
        var frames: AsyncStream<DepacketisedFrame>?
        while frames == nil, !Task.isCancelled {
            frames = await room.frames(of: identity)
            if frames == nil { try? await Task.sleep(for: .milliseconds(100)) }
        }
        guard let frames else { return }

        // Started with the drawing rather than with the room: what it answers is whether
        // what this tile is drawing has a picture in it.
        await room.watchReceivedPicture(of: identity)

        // Presented on a schedule rather than on arrival. Without this the picture is as
        // uneven as the network, which on a good link is even enough to measure well and
        // still visibly choppy: a p95 arrival gap of 80ms against a 33ms median is one frame
        // in twenty held for two and a half frame times. The delay is the app's choice
        // because it is a latency the user pays; the room model carries it so a benchmark
        // can set it to zero and see both halves of the trade.
        // The panel, because the schedule holds margin for a refresh boundary. The view is where
        // this is known: the renderer has a layer, not a screen.
        //
        // Measured rather than asked for, which is the whole point. ``maximumFramesPerSecond`` is
        // a capability and reports 120 on both phones here for the life of the process, while a
        // display link on the same screen reports 60 for the whole of a call — the app never opted
        // into high refresh, so it does not get it. Believing the capability credits the margin
        // down to its 12ms floor when the panel wants the full 18ms, and six milliseconds short of
        // a refresh boundary is not a latency saving, it is the display layer dropping what it
        // cannot show in the period it has. That is the fault ``PlayoutDelay/margin`` was written
        // for, and it came back the moment the figure feeding it stopped being true.
        //
        // Set before the bounds, because assigning the bounds restarts the schedule and the
        // restart sizes the delay against this. A restart that still had the sixty-hertz default
        // would hold eighteen milliseconds on a panel that can do twelve.
        #if os(iOS)
            renderer.displayRefresh = Self.panelPeriod()
        #endif

        renderer.playoutDelay = await room.playoutDelay
        renderer.playoutBounds = await room.playoutBounds
        renderer.playoutTolerance = await room.playoutTolerance

        if let codec = await room.codec(of: identity) {
            renderer.setCodec(codec)
        }

        // Measured here rather than after `enqueue`, because this is the last moment
        // the frame is the receiver's responsibility: what follows is the display
        // layer holding it until its presentation time, which is a queue depth the
        // application chose and not a cost the network imposed.
        let stamp = room.trustedStamp
        let meter = room.latency
        let cadence = room.cadence
        let timeline = room.timeline
        let renderer = renderer

        // Drained off the main actor, and that is a measurement decision as much as a
        // performance one. Recording arrival on the main actor cannot distinguish a network
        // that delivers frames in clumps from a main thread that was too busy to collect
        // them one at a time: both produce a run of near-zero gaps followed by a long one.
        // Timestamping here, before the hop, leaves only the network in the number.
        //
        // The hop itself stays, and stays awaited. The display layer is main-actor bound
        // because it is part of the view hierarchy, and handing frames over without waiting
        // would put them on the actor's queue in an order nothing guarantees — which for
        // video is worse than being late.
        //
        // A nonisolated method rather than a detached task, which was the first attempt and
        // was wrong: a detached task does not inherit cancellation, so a tile torn down and
        // rebuilt — which a grid does whenever somebody joins — left the old drain alive on
        // the same stream. Two consumers then split one track between them and each renderer
        // decoded half a stream, which looks exactly like a corrupt link.
        await Self.drain(
            frames,
            of: identity,
            into: renderer,
            stamp: stamp,
            meter: meter,
            cadence: cadence,
            timeline: timeline,
            reportingTo: room
        )
    }

    /// Move frames from the subscription to the layer, timestamping arrival off the main actor.
    ///
    /// Static and nonisolated so the loop genuinely runs off the main actor while remaining a
    /// child of the pump task: cancelling the pump cancels this, which is what stops a torn-down
    /// tile from competing for the stream with its replacement.
    private nonisolated static func drain(
        _ frames: AsyncStream<DepacketisedFrame>,
        of identity: ParticipantIdentity,
        into renderer: VideoRenderer,
        stamp: (@Sendable () -> Timecode)?,
        meter: LatencyMeter,
        cadence: CadenceMeter,
        timeline: TimelineMeter,
        reportingTo room: RoomModel
    ) async {
        var drawn = 0
        cadence.restart()
        for await frame in frames {
            if Task.isCancelled { return }
            if let stamp {
                meter.record(capturedAt: frame.frame.timestamp, receivedAt: stamp())
            }
            timeline.record(stamp: frame.frame.timestamp.nanoseconds)
            drawn += 1

            var shown = false
            await MainActor.run {
                let before = renderer.drawing.enqueued
                try? renderer.enqueue(frame)
                shown = renderer.drawing.enqueued > before

                // The publisher changed the shape of the picture. Read after enqueueing,
                // because the format description this reports is built from the keyframe
                // that was just handed over — and read at all because the tile's own aspect
                // has to follow it, or a correctly delivered reshape shows up as a picture
                // letterboxed inside a tile still laid out for the previous one.
                if frame.changesFormat {
                    room.receivedReshapes += 1
                    room.receivedShape = renderer.presentedSize
                } else if room.receivedShape == nil {
                    room.receivedShape = renderer.presentedSize
                }

                room.drawing = renderer.drawing
                room.playoutDepth = renderer.playoutDepth
                room.playoutSlack = renderer.playoutSlack
                room.playoutHold = renderer.playoutHold
                room.tileIsOnScreen = renderer.isOnScreen
                room.tileSize = renderer.drawnSize
                room.tileCount = VideoTile.live
                if drawn % 30 == 0 { room.timing = renderer.timing }
            }

            // After a frame has been handed to the layer, not when an object arrived.
            // Subscribe, the first keyframe, a drain that just started — those waits have
            // no picture yet, and counting them as freezes is how connecting read as a stall.
            // The meter itself also refuses a freeze until a second after the first
            // picture is shown: that first frame is not enough, because the next one is
            // often a long gap later while the tile and the decoder settle, and that one
            // gap became the stall that sat on the overlay for the rest of the call.
            if shown {
                cadence.record(keyFrame: frame.frame.isKeyFrame)
            }

            // Off the drain. This used to `await` the display pipeline's performance metrics
            // on the same loop that pulls the next frame. The call ran twice a second and
            // took about two hundred milliseconds, which is forty percent of the wall clock
            // spent not reading — measured as `PLAY ... p50=8.8 p95=41 max=260 freezes=135
            // frozen=39% every=0.5s` while capture beside it was sixty frames, no freezes.
            if drawn % 30 == 0 {
                Task { @MainActor in
                    if let presentation = await renderer.presentation() {
                        room.presentation = presentation
                    }
                }
            }

            // Lip sync, re-read at the same interval because the voice's buffer resizes itself
            // as the link changes. What the two delays have to be for the call to look right is
            // ``LipSync``'s to decide.
            if drawn % 30 == 0 {
                await MainActor.run {
                    guard let bounds = room.playoutBounds else { return }
                    let voice = room.audioDelay(of: identity) ?? .zero
                    let floor = LipSync.floor(voice: voice, bounds: bounds)
                    renderer.playoutFloor = floor

                    // Reported as well as applied, because a delay held up by its floor and a
                    // delay driven up by jitter are the same number on screen and want
                    // opposite responses.
                    room.playoutFloorInForce = floor

                    // Re-read for the same reason the floor is: a variable-refresh panel changes
                    // rate during a call, and the margin the schedule holds has to follow it. The
                    // first reading is taken before the link has ticked at all.
                    #if os(iOS)
                        renderer.displayRefresh = Self.panelPeriod()
                    #endif
                }
            }
        }
    }

    #if os(iOS)
        /// How long the panel is currently taking between refreshes, in seconds.
        ///
        /// The measurement where there is one, and the screen's stated maximum only until the
        /// display link has ticked. The fallback is deliberately the optimistic figure rather than
        /// a safe one: it is in force for a fraction of a second at the start of a call, and
        /// pinning it low would charge every call latency for a boundary most panels do not have.
        @MainActor
        static func panelPeriod() -> Double {
            if let measured = PanelRate.shared.period, measured > 0 { return measured }
            let hertz = UIScreen.main.maximumFramesPerSecond
            return hertz > 0 ? 1 / Double(hertz) : 1.0 / 60
        }
    #endif

    func detach() {
        pump?.cancel()
        pump = nil
        // Before the pump is gone rather than after: a tap nobody is reading still takes a
        // frame from the capture pool every time one arrives, and holds it.
        preview?.stop()
        preview = nil
    }

    deinit {
        pump?.cancel()
        preview?.stop()
        MainActor.assumeIsolated { Self.live -= 1 }
    }
}

#if os(iOS) || os(visionOS)
    private struct VideoLayerView: UIViewRepresentable {
        let identity: ParticipantIdentity
        let isSelf: Bool
        let isMirrored: Bool
        let room: RoomModel

        func makeUIView(context _: Context) -> SampleBufferView {
            SampleBufferView(renderer: start().renderer)
        }

        func updateUIView(_ view: SampleBufferView, context _: Context) {
            // Re-adopted rather than assumed, because a view can be handed a different
            // participant when the grid reorders, and because the layer may have been lent to
            // the Picture in Picture window and needs taking back.
            view.adopt(start().renderer)
        }

        /// The tile for this seat, running.
        @discardableResult private func start() -> VideoTile {
            let tile = room.tile(for: identity, isSelf: isSelf)
            tile.renderer.isMirrored = isMirrored
            if isSelf {
                tile.attachPreview(in: room)
            } else {
                tile.attach(to: identity, in: room)
                // Lend the window this tile's layer, so entering Picture in
                // Picture reuses the decode already running here instead of
                // starting a second one for the same track.
                room.pictureInPicture?.register(tile.renderer, for: identity)
            }
            return tile
        }

        // No `dismantleUIView`. The tile outlives every view that draws it and is released
        // when the participant leaves; tearing it down here is what used to stop the picture.
    }

    final class SampleBufferView: UIView {
        private var renderer: VideoRenderer

        /// Nothing is drawn here yet — see ``take()`` for why construction does not claim
        /// the layer.
        init(renderer: VideoRenderer) {
            self.renderer = renderer
            super.init(frame: .zero)
        }

        /// Draw this renderer from now on.
        ///
        /// `addSublayer` reparents, so a layer drawn in another view — or lent to the Picture
        /// in Picture window and handed back — arrives here without being detached first.
        func adopt(_ renderer: VideoRenderer) {
            if renderer !== self.renderer {
                if holdsLayer { self.renderer.layer.removeFromSuperlayer() }
                self.renderer = renderer
            }
            take()
        }

        /// Whether this view is the one the renderer's layer is currently parented to.
        private var holdsLayer: Bool { renderer.layer.superlayer === layer }

        /// Claim the layer, but only once there is a window to draw it in.
        ///
        /// The condition is the whole point. There is one renderer per participant and
        /// reparenting is unconditional, so whichever view touches the layer last wins —
        /// and SwiftUI routinely builds a replacement representable, hands it a
        /// participant, and then keeps the original. A replacement that claimed the layer
        /// on its way past left it inside a view with no window: still decoding, still
        /// presenting, still reporting a healthy stream, behind a tile that had gone
        /// black. Waiting for a window means an orphan cannot take the layer from the view
        /// a person is looking at, because it never gets one.
        private func take() {
            guard window != nil else { return }
            if !holdsLayer { layer.addSublayer(renderer.layer) }
            renderer.isHosted = true
            setNeedsLayout()
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) { fatalError("not used") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                take()
            } else if holdsLayer {
                // Only while this view still has it. A view being dismantled after its
                // replacement took the layer would otherwise report the renderer as
                // unhosted, which is the reverse of the truth and hides the tile that is
                // genuinely dark.
                renderer.isHosted = false
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // Only while we still hold it. The Picture in Picture window moves
            // this layer into its own hierarchy and lays it out there, so a
            // grid pass that happened to run meanwhile would otherwise resize
            // the layer out from under the window.
            guard holdsLayer else { return }

            // Bounds and position rather than `frame`, because the mirrored preview carries a
            // scale of minus one and a layer's frame is documented as meaningless when its
            // transform is not the identity — Core Animation derives the frame from these two
            // and the transform, so assigning it back is a round trip through a value that no
            // longer describes anything.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            renderer.layer.bounds = CGRect(origin: .zero, size: bounds.size)
            renderer.layer.position = CGPoint(x: bounds.midX, y: bounds.midY)
            CATransaction.commit()
        }
    }
#elseif os(macOS)
    private struct VideoLayerView: NSViewRepresentable {
        let identity: ParticipantIdentity
        let isSelf: Bool
        let isMirrored: Bool
        let room: RoomModel

        func makeNSView(context _: Context) -> SampleBufferView {
            SampleBufferView(renderer: start().renderer)
        }

        func updateNSView(_ view: SampleBufferView, context _: Context) {
            view.adopt(start().renderer)
        }

        /// The tile for this seat, running. See the iOS side for why it is the room's.
        @discardableResult private func start() -> VideoTile {
            let tile = room.tile(for: identity, isSelf: isSelf)
            tile.renderer.isMirrored = isMirrored
            if isSelf {
                tile.attachPreview(in: room)
            } else {
                tile.attach(to: identity, in: room)
            }
            return tile
        }
    }

    final class SampleBufferView: NSView {
        private var renderer: VideoRenderer

        init(renderer: VideoRenderer) {
            self.renderer = renderer
            super.init(frame: .zero)
            wantsLayer = true
        }

        func adopt(_ renderer: VideoRenderer) {
            if renderer !== self.renderer {
                if holdsLayer { self.renderer.layer.removeFromSuperlayer() }
                self.renderer = renderer
            }
            take()
        }

        private var holdsLayer: Bool { renderer.layer.superlayer === layer }

        /// Claim the layer once there is a window to draw it in. See the iOS side for the
        /// black tile this ordering exists to prevent.
        private func take() {
            guard window != nil, let host = layer else { return }
            if !holdsLayer { host.addSublayer(renderer.layer) }
            renderer.isHosted = true
            needsLayout = true
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) { fatalError("not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                take()
            } else if holdsLayer {
                renderer.isHosted = false
            }
        }

        override func layout() {
            super.layout()
            guard holdsLayer, let host = layer else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            renderer.layer.bounds = CGRect(origin: .zero, size: host.bounds.size)
            renderer.layer.position = CGPoint(x: host.bounds.midX, y: host.bounds.midY)
            CATransaction.commit()
        }
    }
#endif
