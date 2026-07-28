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
        VideoLayerView(identity: participant.slot.identity, isSelf: isSelf, room: room)
            .background(.black)
            .overlay {
                if participant.presence != .connected {
                    Image(systemName: "person.crop.circle.badge.clock")
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

    /// Draw what this device is capturing.
    ///
    /// A different path from the remote one and deliberately so: nothing is
    /// encoded, relayed, or decoded, so the preview keeps working when the
    /// publication does not.
    func attachPreview(in room: RoomModel) {
        guard pump == nil else { return }
        pump = Task { [weak self] in
            var preview: AsyncStream<VideoFrame>?
            while preview == nil, !Task.isCancelled {
                preview = room.localPreview()
                if preview == nil { try? await Task.sleep(for: .milliseconds(100)) }
            }
            guard let preview, let self else { return }
            for await frame in preview {
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
            for await frame in frames {
                try? renderer.enqueue(frame)
            }
        }
    }

    func detach() {
        pump?.cancel()
        pump = nil
    }

    deinit { pump?.cancel() }
}

#if os(iOS) || os(visionOS)
    private struct VideoLayerView: UIViewRepresentable {
        let identity: ParticipantIdentity
        let isSelf: Bool
        let room: RoomModel

        func makeUIView(context: Context) -> SampleBufferView {
            start(context.coordinator)
            return SampleBufferView(renderer: context.coordinator.tile.renderer)
        }

        func updateUIView(_: SampleBufferView, context: Context) {
            start(context.coordinator)
        }

        private func start(_ coordinator: Coordinator) {
            if isSelf {
                coordinator.tile.attachPreview(in: room)
            } else {
                coordinator.tile.attach(to: identity, in: room)
            }
        }

        static func dismantleUIView(_: SampleBufferView, coordinator: Coordinator) {
            coordinator.tile.detach()
        }

        func makeCoordinator() -> Coordinator { Coordinator() }

        @MainActor
        final class Coordinator {
            let tile = VideoTile()
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
            renderer.layer.frame = bounds
        }
    }
#elseif os(macOS)
    private struct VideoLayerView: NSViewRepresentable {
        let identity: ParticipantIdentity
        let isSelf: Bool
        let room: RoomModel

        func makeNSView(context: Context) -> SampleBufferView {
            start(context.coordinator)
            return SampleBufferView(renderer: context.coordinator.tile.renderer)
        }

        func updateNSView(_: SampleBufferView, context: Context) {
            start(context.coordinator)
        }

        private func start(_ coordinator: Coordinator) {
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
            renderer.layer.frame = bounds
        }
    }
#endif
