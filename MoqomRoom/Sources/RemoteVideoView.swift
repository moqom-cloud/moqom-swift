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

    var body: some View {
        VideoLayerView(identity: participant.slot.identity)
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

#if os(iOS) || os(visionOS)
    private struct VideoLayerView: UIViewRepresentable {
        let identity: ParticipantIdentity

        func makeUIView(context: Context) -> SampleBufferView {
            SampleBufferView(renderer: context.coordinator.renderer)
        }

        func updateUIView(_: SampleBufferView, context _: Context) {}

        func makeCoordinator() -> Coordinator { Coordinator() }

        @MainActor
        final class Coordinator {
            // A renderer per tile. Sharing one across tiles would mean sharing
            // one decode session, and the whole point of subscribing per-tile
            // is that the tiles are at different resolutions.
            let renderer = VideoRenderer()
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

        func makeNSView(context: Context) -> SampleBufferView {
            SampleBufferView(renderer: context.coordinator.renderer)
        }

        func updateNSView(_: SampleBufferView, context _: Context) {}

        func makeCoordinator() -> Coordinator { Coordinator() }

        @MainActor
        final class Coordinator {
            let renderer = VideoRenderer()
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
