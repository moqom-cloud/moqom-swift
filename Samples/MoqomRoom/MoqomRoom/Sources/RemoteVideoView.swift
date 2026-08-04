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
                    Image(systemName: "video.slash.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }
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
    func attachPreview(in room: RoomModel) {
        guard pump == nil else { return }
        pump = Task { [weak self] in
            var tap: MediaTap<VideoFrame>?
            while tap == nil, !Task.isCancelled {
                tap = await room.localPreview()
                if tap == nil { try? await Task.sleep(for: .milliseconds(100)) }
            }
            guard let tap, let self else {
                // Cancelled while waiting, so nobody will ever read this one.
                tap?.stop()
                return
            }
            preview = tap
            var drawn = 0
            for await frame in tap.elements {
                renderer.enqueue(frame)

                // The control for the received tile's own figure. This layer is on the same
                // screen, in the same app, fed by the same camera — and nothing schedules it:
                // frames go in as they are captured. So a drop count here is the panel's, and
                // a drop count only on the other layer is ours.
                drawn += 1
                if drawn % 30 == 0, let presentation = await renderer.presentation() {
                    room.previewPresentation = presentation
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
        for await frame in frames {
            if Task.isCancelled { return }
            if let stamp {
                meter.record(capturedAt: frame.frame.timestamp, receivedAt: stamp())
            }
            cadence.record(keyFrame: frame.frame.isKeyFrame)
            timeline.record(stamp: frame.frame.timestamp.nanoseconds)
            drawn += 1

            await MainActor.run {
                try? renderer.enqueue(frame)

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
                room.tileIsOnScreen = renderer.isOnScreen
                room.tileSize = renderer.drawnSize
                room.tileCount = VideoTile.live
                if drawn % 30 == 0 { room.timing = renderer.timing }
            }

            // Twice a second rather than per frame: this crosses into the display pipeline and
            // asking it sixty times a second to describe sixty frames is its own overhead.
            if drawn % 30 == 0, let presentation = await renderer.presentation() {
                await MainActor.run { room.presentation = presentation }
            }

            // Lip sync, re-read at the same interval because the voice's buffer resizes itself
            // as the link changes. One direction only: the picture waits for the voice, never
            // the other way round. Audio is a twentieth of the bitrate and every packet stands
            // alone, so it arrives when video cannot — holding it back to match a picture that
            // is struggling would throw away the one part of the call still working.
            //
            // Bounded by the same ceiling as everything else. A voice buffer that has grown to
            // half a second is describing a link in trouble, and following it there would add
            // half a second to the picture as well; past the ceiling the two drift apart, which
            // is the better failure.
            if drawn % 30 == 0 {
                await MainActor.run {
                    guard let bounds = room.playoutBounds else { return }
                    let voice = room.audioDelay(of: identity) ?? .zero
                    let floor = min(max(bounds.floor, voice), bounds.ceiling)
                    renderer.playoutFloor = floor

                    // Reported as well as applied, because a delay held up by its floor and a
                    // delay driven up by jitter are the same number on screen and want
                    // opposite responses.
                    room.playoutFloorInForce = floor
                }
            }
        }
    }

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
