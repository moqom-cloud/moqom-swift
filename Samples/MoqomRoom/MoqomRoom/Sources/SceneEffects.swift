// Where beauty filters and scene effects attach.
//
// The hook is a Metal pass on the caller's command buffer, before the frame is
// handed to the SDK. That ordering is the whole design: effects run inside the
// render loop the app already owns, so the frame never leaves the GPU, and the
// SDK is handed the texture the user is actually looking at rather than a
// second render of the same scene.
//
// This is why `SceneCapture.submit(texture:at:on:)` takes a command buffer
// instead of owning one. An SDK that owned the buffer would have to either run
// effects itself — becoming a filter framework — or take the frame before
// effects ran, which puts the preview and the broadcast out of agreement.
//
// The list below is UI only. Wiring a real filter means writing the compute
// pass in `apply(_:to:on:)` and nothing else in the app changes.

import MoqomCore
import MoqomKit
import SwiftUI

#if canImport(Metal)
    import Metal
#endif

enum SceneEffect: String, CaseIterable, Identifiable {
    case none
    case smoothing
    case backgroundBlur
    case colourGrade

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: "No effect"
        case .smoothing: "Skin smoothing"
        case .backgroundBlur: "Background blur"
        case .colourGrade: "Colour grade"
        }
    }

    var symbol: String {
        switch self {
        case .none: "circle.slash"
        case .smoothing: "wand.and.stars"
        case .backgroundBlur: "person.and.background.dotted"
        case .colourGrade: "camera.filters"
        }
    }
}

@MainActor
@Observable
final class SceneEffectsModel {
    var active: SceneEffect = .none

    #if canImport(Metal)
        /// Run the active effect over a frame, in place, on the render loop's
        /// own command buffer.
        ///
        /// Called from the post-process callback before
        /// `SceneCapture.submit(texture:at:on:)`, so the encoder and the
        /// preview see the same pixels.
        ///
        /// Unimplemented: a real pass is a compute pipeline per effect, and
        /// the sample has no shaders. The signature is the contract.
        func apply(
            _ effect: SceneEffect,
            to texture: any MTLTexture,
            on commandBuffer: any MTLCommandBuffer
        ) {
            guard effect != .none else { return }
            _ = texture
            _ = commandBuffer
        }
    #endif
}

struct SceneEffectsMenu: View {
    @State private var effects = SceneEffectsModel()

    var body: some View {
        Menu {
            Picker("Effect", selection: $effects.active) {
                ForEach(SceneEffect.allCases) { effect in
                    Label(effect.label, systemImage: effect.symbol)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .tag(effect)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label("Effects", systemImage: effects.active.symbol)
        }
        .menuStyle(.borderlessButton)
    }
}
