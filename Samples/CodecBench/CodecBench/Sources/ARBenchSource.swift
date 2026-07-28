// An AR scene as the thing being compressed.
//
// This is the input a MOQOM broadcast of an AR session actually produces, and it asks the
// codec a different question from either the camera or a clip. A composited AR frame is
// camera video plus synthetic geometry with hard edges, specular highlights, and a
// perfectly steady shape moving against a hand-held background — content whose statistics
// sit between the two things a learned codec was trained on, and where the orb's crisp
// silhouette is the first thing to smear if the bitrate is not there.
//
// The capture path is the SDK's, not a private one: ``SceneCapture`` attached to the
// `ARView` through `renderCallbacks.postProcess`. That hook is documented in the SDK as
// compiling but never having executed, because nothing in the test suite can drive a
// RealityKit render loop — so this is also the first thing to actually run it.
//
// The view has to be on screen. RealityKit renders when it is in a window and drives no
// frames when it is not, so the bench UI shows the `ARView` while this source is selected
// and the run stops producing frames the moment it goes away.

import ARKit
import AVFoundation
import CoreVideo
import Foundation
import MetalPerformanceShaders
import MoqomCore
import MoqomKit
import RealityKit
import SwiftUI
import VideoToolbox

enum ARBenchError: Error, CustomStringConvertible {
    case unsupported
    case noFrames(waited: Double)
    case transferFailed(OSStatus)

    var description: String {
        switch self {
        case .unsupported:
            "this device cannot run the AR session this source needs"
        case let .noFrames(waited):
            """
            the AR view drew nothing within \(Int(waited * 1000)) ms — it has to be on \
            screen for RealityKit to render
            """
        case let .transferFailed(status):
            "the AR frame could not be converted to the rung (VTPixelTransfer \(status))"
        }
    }
}

/// Feeds the codecs a composited AR scene containing a floating orb.
///
/// Deliberately not a `@MainActor` type even though most of it is. RealityKit and the
/// session are main-actor only, but ``render(frameIndex:into:)`` is called from inside the
/// codec's actor on every frame and hopping to the main actor there would put the
/// interface's scheduling in the middle of a measurement. So the scene is main-actor and
/// the frame handoff is a lock.
final class ARBenchSource: NSObject, BenchSource, @unchecked Sendable {
    let size: PixelSize
    let frameRate: Double

    /// The view that must be on screen for any of this to produce frames.
    nonisolated(unsafe) let view: ARView

    /// Created on the first rendered frame, not at init.
    ///
    /// ``SceneCapture`` requires its configured size to equal the texture handed to it and
    /// silently drops anything else — deliberately, since a mismatch would mean a scaling
    /// blit on the caller's command buffer. RealityKit's drawable is sized by the view's
    /// layout, which is not known until it is on screen, so the size has to come from the
    /// first texture rather than from the rung.
    private var capture: SceneCapture?
    private var captureSize: PixelSize?
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var lastServed: CVPixelBuffer?
    private var pump: Task<Void, Never>?
    private var transfer: VTPixelTransferSession?
    private var repeats = 0
    private var served = 0

    /// The orb, kept so it can be animated.
    nonisolated(unsafe) private var orb: ModelEntity?

    /// Cached conversion target, for renderers whose format a capture cannot blit.
    nonisolated(unsafe) private var staging: (any MTLTexture)?
    nonisolated(unsafe) private var stagingSize: PixelSize?
    nonisolated(unsafe) private var converter: MPSImageConversion?

    var summary: String {
        lock.withLock { "AR scene → \(size.width)x\(size.height), \(repeats)/\(served) repeated" }
    }

    @MainActor
    init(size: PixelSize, frameRate: Double) {
        self.size = size
        self.frameRate = frameRate
        view = ARView(frame: .zero)
        super.init()
    }

    static var isSupported: Bool {
        ARWorldTrackingConfiguration.isSupported || ARFaceTrackingConfiguration.isSupported
    }

    @MainActor
    func start() throws {
        try configureSession()
        buildScene()

        // Installed by hand rather than through `SceneCapture.attach(to:)`, only because
        // the capture cannot exist until the first texture reveals the drawable's size.
        // The pass-through blit is not optional politeness: a post-process callback owns
        // the frame, and a callback that does not write the target texture makes the view
        // render nothing at all.
        view.renderCallbacks.postProcess = { [weak self] context in
            guard let self else { return }

            let texture = context.sourceColorTexture
            let source = captureable(texture, on: context.commandBuffer)
            let capture = capture(
                for: PixelSize(width: source.width, height: source.height),
                device: source.device,
                textureFormat: source.pixelFormat
            )
            capture?.submit(
                texture: source,
                at: FrameTimestamp(seconds: context.time),
                on: context.commandBuffer
            )

            if let blit = context.commandBuffer.makeBlitCommandEncoder() {
                blit.copy(from: texture, to: context.targetColorTexture)
                blit.endEncoding()
            }
        }
    }

    @MainActor
    func stop() {
        view.renderCallbacks.postProcess = nil
        pump?.cancel()
        pump = nil
        lock.withLock {
            capture?.stop()
            capture = nil
            latest = nil
        }
        view.session.pause()
    }

    /// The capture for a given drawable size, building it the first time it is seen.
    ///
    /// Called on the render thread, so it does the least it can: everything is cached after
    /// the first frame, and a resize — which happens on rotation — rebuilds rather than
    /// silently dropping every subsequent frame the way a stale size would.
    private func capture(
        for drawable: PixelSize, device: any MTLDevice, textureFormat: MTLPixelFormat
    ) -> SceneCapture? {
        lock.lock()
        if let capture, captureSize == drawable {
            lock.unlock()
            return capture
        }
        let previous = capture
        lock.unlock()
        previous?.stop()

        guard
            let built = try? SceneCapture(
                format: CaptureFormat(size: drawable, frameRate: frameRate),
                device: device,
                // So that getting this size wrong says so, rather than presenting as a
                // renderer that never drew.
                logger: .system(minimum: .warning)
            )
        else { return nil }

        print(
            "AR drawable \(drawable.width)x\(drawable.height) → rung "
                + "\(size.width)x\(size.height) texture=\(textureFormat.rawValue)"
        )

        let stream = built.frames()
        let task = Task { [weak self] in
            for await frame in stream {
                guard let self else { return }
                guard case let .pixelBuffer(buffer) = frame.surface else { continue }
                store(buffer)
            }
        }

        lock.withLock {
            capture = built
            captureSize = drawable
            pump?.cancel()
            pump = task
        }
        return built
    }

    /// The user-facing camera, so the orb floats in the scene with whoever is running the
    /// bench rather than behind them.
    @MainActor
    private func configureSession() throws {
        if ARFaceTrackingConfiguration.isSupported {
            let configuration = ARFaceTrackingConfiguration()
            configuration.isWorldTrackingEnabled = false
            view.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        } else if ARWorldTrackingConfiguration.isSupported {
            let configuration = ARWorldTrackingConfiguration()
            view.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        } else {
            throw ARBenchError.unsupported
        }

        // The bench measures the codec, so nothing else should be competing for the GPU.
        view.renderOptions = [
            .disableMotionBlur, .disableDepthOfField, .disableFaceMesh, .disableHDR,
            .disableGroundingShadows, .disablePersonOcclusion,
        ]
        view.automaticallyConfigureSession = false
        view.environment.background = .cameraFeed()
    }

    /// A glowing sphere floating in front of the camera, bobbing so the scene is never
    /// static.
    ///
    /// Motion matters more than looks. A still overlay compresses to nothing after the
    /// first frame, and a codec handed nothing to do reports a latency no real broadcast
    /// will ever see.
    @MainActor
    private func buildScene() {
        view.scene.anchors.removeAll()

        let sphere = ModelEntity(
            mesh: .generateSphere(radius: 0.08),
            materials: [
                SimpleMaterial(color: .cyan, roughness: 0.15, isMetallic: true),
            ]
        )
        orb = sphere

        // Parented to the camera so it stays in frame however the phone is held, half a
        // metre out and slightly below eye line.
        let anchor = AnchorEntity(.camera)
        anchor.addChild(sphere)
        sphere.position = [0, -0.05, -0.5]
        view.scene.addAnchor(anchor)

        let light = DirectionalLight()
        light.light.intensity = 2500
        light.look(at: sphere.position, from: [0.4, 0.6, 0], relativeTo: anchor)
        anchor.addChild(light)

        orbit(sphere, around: anchor)
    }

    /// A slow circling drift, restarted as it completes.
    @MainActor
    private func orbit(_ entity: ModelEntity, around anchor: AnchorEntity) {
        var transform = entity.transform
        transform.translation = [0.12, 0.06, -0.5]
        entity.move(to: transform, relativeTo: anchor, duration: 2, timingFunction: .easeInOut)

        Task { @MainActor [weak self, weak entity, weak anchor] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, let entity, let anchor, pump != nil else { return }
            var back = entity.transform
            back.translation = [-0.12, -0.05, -0.5]
            entity.move(to: back, relativeTo: anchor, duration: 2, timingFunction: .easeInOut)
            try? await Task.sleep(for: .seconds(2))
            guard pump != nil else { return }
            orbit(entity, around: anchor)
        }
    }

    /// Convert the drawable into a format a capture can actually copy, if it isn't one.
    ///
    /// RealityKit renders this scene into `bgra10_xr_srgb`: ten bits per channel in Apple's
    /// extended range, eight bytes per pixel. `SceneCapture` blits, and a blit is a byte
    /// copy, so it refuses any format it has no matching `CVPixelBuffer` layout for rather
    /// than reinterpreting eight bytes per pixel as four — which is what turned this scene
    /// into a field of magenta before the refusal existed. The refusal is right and the
    /// conversion belongs on this side of the boundary.
    ///
    /// `.disableHDR` and an SDR drawable on the layer both fail to prevent it. A
    /// post-process pass reads RealityKit's own offscreen target, whose format is chosen by
    /// the renderer and is not the format of the layer it eventually presents to.
    ///
    /// The staging texture is `_srgb` so the store re-encodes. Sampling the source
    /// linearises it, and writing that linear value into a plain `bgra8Unorm` would hand the
    /// encoder a visibly dark frame. Values above 1.0 clamp, which is what tone mapping to
    /// an 8-bit SDR encoder means.
    private func captureable(
        _ texture: any MTLTexture, on commandBuffer: any MTLCommandBuffer
    ) -> any MTLTexture {
        switch texture.pixelFormat {
        case .bgra8Unorm, .bgra8Unorm_srgb, .rgba16Float: return texture
        default: break
        }

        let size = PixelSize(width: texture.width, height: texture.height)
        if staging == nil || stagingSize != size {
            let described = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm_srgb,
                width: size.width,
                height: size.height,
                mipmapped: false
            )
            described.usage = [.shaderRead, .shaderWrite, .renderTarget]
            described.storageMode = .private
            staging = texture.device.makeTexture(descriptor: described)
            stagingSize = size
        }

        guard let staging else { return texture }

        if converter == nil {
            converter = MPSImageConversion(
                device: texture.device,
                srcAlpha: .alphaIsOne,
                destAlpha: .alphaIsOne,
                backgroundColor: nil,
                conversionInfo: nil
            )
        }
        converter?.encode(
            commandBuffer: commandBuffer, sourceTexture: texture, destinationTexture: staging
        )
        return staging
    }

    private func store(_ buffer: CVPixelBuffer) {
        let first = lock.withLock { () -> Bool in
            let first = latest == nil && served == 0
            latest = buffer
            return first
        }
        // Logged because this is the first code to drive the SDK's RealityKit capture hook
        // at all, so "did the post-process callback ever fire" is a question worth being
        // able to answer from the console.
        if first {
            print(
                "AR first frame \(CVPixelBufferGetWidth(buffer))x"
                    + "\(CVPixelBufferGetHeight(buffer))"
            )
        }
    }

    func render(frameIndex _: Int, into buffer: CVPixelBuffer) throws {
        let source = try waitForFrame()
        let session = try transferSession()
        let status = VTPixelTransferSessionTransferImage(session, from: source, to: buffer)
        guard status == noErr else { throw ARBenchError.transferFailed(status) }

        // Sampled once. A flat frame here says the blit upstream produced nothing usable,
        // which is otherwise indistinguishable from a conversion that went wrong.
        if !described {
            described = true
            print(
                "AR sample source=\(Self.describe(source)) converted=\(Self.describe(buffer))"
            )
        }
    }

    private var described = false

    /// Format and a couple of centre pixels, enough to tell flat garbage from a picture.
    private static func describe(_ buffer: CVPixelBuffer) -> String {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let name = String(
            bytes: [24, 16, 8, 0].map { UInt8((format >> $0) & 0xFF) }, encoding: .ascii
        ) ?? "\(format)"

        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            return "\(name) unlockable"
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let planes = max(CVPixelBufferGetPlaneCount(buffer), 1)
        var parts: [String] = []
        for plane in 0 ..< planes {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { continue }
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let middle = base.assumingMemoryBound(to: UInt8.self)
                + (CVPixelBufferGetHeightOfPlane(buffer, plane) / 2) * stride + stride / 2
            parts.append("p\(plane)[\(middle[0]),\(middle[1]),\(middle[2]),\(middle[3])]")
        }
        return "\(name) \(CVPixelBufferGetWidth(buffer))x\(CVPixelBufferGetHeight(buffer)) "
            + parts.joined(separator: " ")
    }

    private func waitForFrame() throws -> CVPixelBuffer {
        let timeout = 10.0
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let frame = take() { return frame }
            Thread.sleep(forTimeInterval: 0.01)
        } while Date() < deadline
        throw ARBenchError.noFrames(waited: timeout)
    }

    private func take() -> CVPixelBuffer? {
        lock.withLock {
            guard let latest else { return nil }
            if lastServed === latest { repeats += 1 }
            lastServed = latest
            served += 1
            return latest
        }
    }

    /// Converts the AR drawable's BGRA into the NV12 the codecs consume, and scales it to
    /// the rung, on the GPU rather than the CPU.
    private func transferSession() throws -> VTPixelTransferSession {
        if let transfer { return transfer }
        var created: VTPixelTransferSession?
        let status = VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &created)
        guard status == noErr, let created else { throw ARBenchError.transferFailed(status) }
        VTSessionSetProperty(
            created,
            key: kVTPixelTransferPropertyKey_ScalingMode,
            value: kVTScalingMode_Letterbox
        )
        transfer = created
        return created
    }
}

/// Hosts the `ARView` so RealityKit has a window to render into.
struct ARSceneView: UIViewRepresentable {
    let source: ARBenchSource

    func makeUIView(context _: Context) -> ARView { source.view }
    func updateUIView(_: ARView, context _: Context) {}
}
