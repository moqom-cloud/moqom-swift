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
        // Read here rather than inside the representable so that observation
        // actually sees it. A property read in `updateUIView` is not a body
        // read, and the flip button would leave the preview facing the wrong
        // way until something else happened to redraw the tile.
        VideoLayerView(
            identity: participant.slot.identity,
            isSelf: isSelf,
            isMirrored: isSelf && room.isPreviewMirrored,
            room: room
        )
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
}

/// Pumps one participant's frames into one layer.
///
/// A class rather than a `.task` on the view, because a SwiftUI task is tied to
/// the view's identity and a grid that reorders would tear the pump down and
/// restart it mid-group — which costs a flush and a wait for the next keyframe
/// every time somebody joins.
@MainActor
final class VideoTile {
    // A renderer per tile. Sharing one across tiles would mean sharing one
    // decode session, and the whole point of subscribing per-tile is that the
    // tiles are at different resolutions.
    let renderer = VideoRenderer()

    private var pump: Task<Void, Never>?

    /// This tile's own tap on the capture path, held so it can be stopped.
    private var preview: MediaTap<VideoFrame>?

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
            for await frame in tap.elements {
                renderer.enqueue(frame)
            }
        }
    }

    func attach(to identity: ParticipantIdentity, in room: RoomModel) {
        guard pump == nil else { return }
        pump = Task { [weak self] in
            // The stream does not exist until the planner has subscribed, and
            // subscribing waits on a layout pass. Polling rather than being
            // notified is the small price of not putting a second event
            // channel in the sample.
            var frames: AsyncStream<DepacketisedFrame>?
            while frames == nil, !Task.isCancelled {
                frames = await room.frames(of: identity)
                if frames == nil { try? await Task.sleep(for: .milliseconds(100)) }
            }
            guard let frames, let self else { return }

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
            for await frame in frames {
                if let stamp {
                    meter.record(capturedAt: frame.frame.timestamp, receivedAt: stamp())
                }
                cadence.record()
                try? renderer.enqueue(frame)
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
    }
}

#if os(iOS) || os(visionOS)
    private struct VideoLayerView: UIViewRepresentable {
        let identity: ParticipantIdentity
        let isSelf: Bool
        let isMirrored: Bool
        let room: RoomModel

        func makeUIView(context: Context) -> SampleBufferView {
            start(context.coordinator)
            return SampleBufferView(renderer: context.coordinator.tile.renderer)
        }

        func updateUIView(_: SampleBufferView, context: Context) {
            start(context.coordinator)
        }

        private func start(_ coordinator: Coordinator) {
            coordinator.tile.renderer.isMirrored = isMirrored
            if isSelf {
                coordinator.tile.attachPreview(in: room)
            } else {
                coordinator.tile.attach(to: identity, in: room)
                // Lend the window this tile's layer, so entering Picture in
                // Picture reuses the decode already running here instead of
                // starting a second one for the same track.
                coordinator.identity = identity
                room.pictureInPicture?.register(coordinator.tile.renderer, for: identity)
            }
        }

        static func dismantleUIView(_: SampleBufferView, coordinator: Coordinator) {
            coordinator.tile.detach()
            if let identity = coordinator.identity {
                coordinator.room?.pictureInPicture?.unregister(identity)
            }
        }

        func makeCoordinator() -> Coordinator {
            let coordinator = Coordinator()
            coordinator.room = room
            return coordinator
        }

        @MainActor
        final class Coordinator {
            let tile = VideoTile()
            var identity: ParticipantIdentity?
            weak var room: RoomModel?
        }
    }

    final class SampleBufferView: UIView {
        private let renderer: VideoRenderer

        init(renderer: VideoRenderer) {
            self.renderer = renderer
            super.init(frame: .zero)
            layer.addSublayer(renderer.layer)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) { fatalError("not used") }

        override func layoutSubviews() {
            super.layoutSubviews()
            // Only while we still hold it. The Picture in Picture window moves
            // this layer into its own hierarchy and lays it out there, so a
            // grid pass that happened to run meanwhile would otherwise resize
            // the layer out from under the window.
            guard renderer.layer.superlayer === layer else { return }
            renderer.layer.frame = bounds
        }
    }
#elseif os(macOS)
    private struct VideoLayerView: NSViewRepresentable {
        let identity: ParticipantIdentity
        let isSelf: Bool
        let isMirrored: Bool
        let room: RoomModel

        func makeNSView(context: Context) -> SampleBufferView {
            start(context.coordinator)
            return SampleBufferView(renderer: context.coordinator.tile.renderer)
        }

        func updateNSView(_: SampleBufferView, context: Context) {
            start(context.coordinator)
        }

        private func start(_ coordinator: Coordinator) {
            coordinator.tile.renderer.isMirrored = isMirrored
            if isSelf {
                coordinator.tile.attachPreview(in: room)
            } else {
                coordinator.tile.attach(to: identity, in: room)
            }
        }

        static func dismantleNSView(_: SampleBufferView, coordinator: Coordinator) {
            coordinator.tile.detach()
        }

        func makeCoordinator() -> Coordinator { Coordinator() }

        @MainActor
        final class Coordinator {
            let tile = VideoTile()
        }
    }

    final class SampleBufferView: NSView {
        private let renderer: VideoRenderer

        init(renderer: VideoRenderer) {
            self.renderer = renderer
            super.init(frame: .zero)
            wantsLayer = true
            layer?.addSublayer(renderer.layer)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) { fatalError("not used") }

        override func layout() {
            super.layout()
            guard renderer.layer.superlayer === layer else { return }
            renderer.layer.frame = bounds
        }
    }
#endif
