// Attaching to a RealityKit view.
//
// There are three of these on Apple's platforms and they are not variations of
// one API:
//
//   - `RealityView.renderingEffects.customPostProcessing` — the SwiftUI-native
//     hook, and the one a new app should use. ``SceneCaptureEffect`` below.
//   - `ARView.renderCallbacks.postProcess` — the same handoff for a UIKit host.
//     Kept, and not a fallback: `ARView` is not deprecated on the 26 SDKs, and
//     `RealityView` is SwiftUI-only, so dropping this would cost UIKit apps
//     support rather than shed a legacy path.
//   - `RealityRenderer` — visionOS, where there is no post-process hook at all
//     (`renderingEffects` is explicitly unavailable there) and the app drives an
//     offscreen render whose output texture goes to the same place.
//
// The obligation that is easy to miss, and it applies to both hooks: a
// post-process callback owns the frame. If it does not write
// `targetColorTexture`, the view renders nothing. So the tap blits twice — once
// to the encoder's buffer and once to the target — and the pass-through is not
// optional politeness.

#if canImport(RealityKit) && (os(iOS) || os(macOS))
    import Metal
    import MoqomCore
    import RealityKit
    // `RealityViewCameraContent` lives in the RealityKit/SwiftUI cross-import
    // overlay, so it does not exist with `import RealityKit` alone.
    import SwiftUI

    /// Publishes what a `RealityView` draws.
    ///
    /// ```swift
    /// RealityView { content in
    ///     content.add(scene)
    ///     content.moqomPublish(to: capture)
    /// }
    /// ```
    ///
    /// An app with its own effect should not install this alongside it —
    /// RealityKit takes exactly one — and should instead call
    /// ``SceneCapture/submit(texture:at:on:)`` from inside its own
    /// `postProcess`, after its passes have run, so the stream shows what the
    /// user is looking at.
    ///
    /// - Important: Compiles, and has never executed. Nothing in the test suite
    ///   can drive a RealityKit render loop.
    public struct SceneCaptureEffect: PostProcessEffect {
        private let capture: SceneCapture

        public init(publishingTo capture: SceneCapture) {
            self.capture = capture
        }

        // `prepare(for:)` is left to the protocol's default. There is nothing to
        // build ahead of time: the blit needs no pipeline state, and the texture
        // cache belongs to `SceneCapture`, which was handed a device at init and
        // would have to reject a different one here anyway.

        public mutating func postProcess(
            context: borrowing PostProcessEffectContext<any MTLCommandBuffer>
        ) {
            capture.submit(
                texture: context.sourceColorTexture,
                at: FrameTimestamp(seconds: context.time),
                on: context.commandBuffer
            )

            guard let blit = context.commandBuffer.makeBlitCommandEncoder() else { return }
            blit.copy(from: context.sourceColorTexture, to: context.targetColorTexture)
            blit.endEncoding()
        }
    }

    public extension RealityViewCameraContent {
        /// Publish what this view draws.
        ///
        /// Replaces any custom post-processing already set, because RealityKit
        /// allows one.
        mutating func moqomPublish(to capture: SceneCapture) {
            renderingEffects.customPostProcessing = .effect(
                SceneCaptureEffect(publishingTo: capture)
            )
        }

        /// Stop publishing, leaving the view rendering.
        mutating func moqomStopPublishing() {
            renderingEffects.customPostProcessing = .none
        }
    }

    public extension SceneCapture {
        /// Publish what an `ARView` draws.
        ///
        /// The UIKit equivalent of ``RealityViewCameraContent/moqomPublish(to:)``.
        /// Replaces any post-process callback already installed on the view.
        ///
        /// - Important: Compiles, and has never executed.
        @MainActor
        func attach(to view: ARView) {
            view.renderCallbacks.postProcess = { [weak self] context in
                guard let self else { return }

                submit(
                    texture: context.sourceColorTexture,
                    at: FrameTimestamp(seconds: context.time),
                    on: context.commandBuffer
                )

                guard let blit = context.commandBuffer.makeBlitCommandEncoder() else { return }
                blit.copy(from: context.sourceColorTexture, to: context.targetColorTexture)
                blit.endEncoding()
            }
        }

        /// Stop publishing what the view draws, leaving the view rendering.
        @MainActor
        func detach(from view: ARView) {
            view.renderCallbacks.postProcess = nil
        }
    }
#endif
