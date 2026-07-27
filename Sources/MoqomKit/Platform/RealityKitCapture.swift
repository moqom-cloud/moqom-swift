// Attaching to a RealityKit view.
//
// There are three of these on Apple's platforms and they are not variations of
// one API:
//
//   - `ARView.renderCallbacks.postProcess` — iOS 15 through 25, and macOS. What
//     this file implements, because it is the one the current SDK exposes.
//   - `RealityView.renderingEffects.customPostProcessing` — iOS 26 and later,
//     the SwiftUI-native replacement. Same shape of handoff: a source texture,
//     a target texture, and a command buffer. ``SceneCapture/submit(texture:at:on:)``
//     is deliberately not typed against RealityKit so that the newer callback
//     can call it unchanged.
//   - `RealityRenderer` — visionOS, where there is no post-process hook at all
//     and the app drives an offscreen render whose output texture goes to the
//     same place.
//
// The obligation that is easy to miss: a post-process callback owns the frame.
// If it does not write `targetColorTexture`, the view renders nothing. So the
// tap blits twice — once to the encoder's buffer and once to the target — and
// the pass-through is not optional politeness.

#if canImport(RealityKit) && (os(iOS) || os(macOS))
    import Metal
    import MoqomCore
    import RealityKit

    public extension SceneCapture {
        /// Publish what an `ARView` draws.
        ///
        /// Replaces any post-process callback already installed on the view,
        /// because RealityKit allows exactly one. An app with its own effect
        /// should call ``SceneCapture/submit(texture:at:on:)`` from inside that
        /// effect instead — after its own passes have run, so the stream shows
        /// what the user sees.
        ///
        /// - Important: Written against RealityKit and compiles, but untested:
        ///   nothing in the suite can instantiate an `ARView`.
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
