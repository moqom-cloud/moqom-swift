// Attaching to a RealityKit view.
//
// There are three of these on Apple's platforms and they are not variations of
// one API:
//
//   - `ARView.renderCallbacks.postProcess` — the UIKit-era hook, still present
//     on the 26 SDKs. What this file implements.
//   - `RealityView.renderingEffects.customPostProcessing` — the SwiftUI-native
//     replacement, and the one this file should be using now that the floor is
//     26. Same shape of handoff: a source texture, a target texture, and a
//     command buffer, which is why ``SceneCapture/submit(texture:at:on:)`` is
//     not typed against RealityKit and can be called from either unchanged.
//     Not yet written; tracked in the plan as ios-realityview.
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
