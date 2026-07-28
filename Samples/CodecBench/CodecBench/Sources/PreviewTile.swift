// Watching a run rather than trusting it.
//
// Two tiles: what went into the codec, and what came back out. Timings cannot tell a
// working pipeline from a broken one — a codec whose recurrent state is wired up wrongly
// runs at exactly the same speed and produces exactly as plausible a set of numbers — so
// the only cheap check on correctness is looking at the picture.
//
// Frames go through the SDK's own ``VideoRenderer``, which is an
// `AVSampleBufferDisplayLayer` under the hood, rather than converting to `CGImage` and
// handing SwiftUI a new `Image` every frame. That keeps the display off the CPU, and it
// exercises the same renderer a real MOQOM app uses.

import AVFoundation
import CoreVideo
import MoqomCore
import MoqomKit
import SwiftUI

/// A `VideoRenderer` and the frames going into it.
///
/// Owns the renderer so that the tile can be rebuilt by SwiftUI without dropping the
/// display layer, which would flash black on every layout pass.
@MainActor
@Observable
final class PreviewPipe {
    let title: String
    let renderer: VideoRenderer

    /// Frames shown, so a dead tile can be told apart from a tile showing a still scene.
    private(set) var shown = 0

    /// Mirrored only for a front-camera view of yourself, where an unmirrored preview
    /// behaves like no mirror anyone has used.
    var isMirrored: Bool {
        get { renderer.isMirrored }
        set { renderer.isMirrored = newValue }
    }

    init(title: String) {
        self.title = title
        renderer = VideoRenderer()
    }

    func show(_ frame: VideoFrame) {
        renderer.enqueue(frame)
        shown += 1
    }

    func reset() {
        renderer.flush()
        shown = 0
    }
}

/// One labelled video tile.
struct PreviewTile: View {
    let pipe: PreviewPipe
    var aspect: Double = 9.0 / 16.0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(pipe.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            VideoLayerView(renderer: pipe.renderer)
                .aspectRatio(aspect, contentMode: .fit)
                .background(.black)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    if pipe.shown == 0 {
                        ProgressView().controlSize(.small)
                    }
                }
        }
    }
}

private struct VideoLayerView: UIViewRepresentable {
    let renderer: VideoRenderer

    func makeUIView(context _: Context) -> SampleBufferView {
        SampleBufferView(renderer: renderer)
    }

    func updateUIView(_: SampleBufferView, context _: Context) {}
}

final class SampleBufferView: UIView {
    private let renderer: VideoRenderer

    init(renderer: VideoRenderer) {
        self.renderer = renderer
        super.init(frame: .zero)
        layer.addSublayer(renderer.layer)
        renderer.layer.videoGravity = .resizeAspect
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        renderer.layer.frame = bounds
    }
}
