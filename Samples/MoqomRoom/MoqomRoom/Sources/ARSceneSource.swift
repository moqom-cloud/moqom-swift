// Broadcasting an AR scene instead of a camera.
//
// The camera path and this one differ in where the frame comes from and in
// nothing else after that: both hand the SDK a stream of pixel buffers at the
// rung's size, and everything downstream — encoder, publication, playout,
// glass-to-glass — cannot tell them apart. That is the point of `FrameSource`
// being a stream rather than a camera abstraction.
//
// Three things about this path are not obvious and each one produces a
// convincing wrong answer if it is missed.
//
// The view has to be on screen. RealityKit draws when it is in a window and
// draws nothing when it is not, so a hidden `ARView` publishes a black stream
// while every counter in the app reports a healthy publication. The scene is
// therefore hosted in the self tile — see ``ARSceneView`` — and the tile is
// where the drawable's size comes from.
//
// The post-process callback owns the frame. A callback that does not write
// `targetColorTexture` makes the view render nothing at all, so the
// pass-through blit is an obligation and not politeness.
//
// RealityKit does not draw in a format that can be copied into a pixel buffer.
// Its offscreen target is `bgra10_xr_srgb` — ten bits per channel, eight bytes
// per pixel — and a blit is a byte copy, so `SceneCapture` refuses it rather
// than reading eight bytes per pixel as four. That refusal is what stands
// between this and the field of magenta the bench produced before the
// conversion below existed. `.disableHDR` does not prevent it and neither does
// an SDR drawable: the post-process pass reads the renderer's own target, whose
// format is not the format of the layer it eventually presents.

#if canImport(ARKit) && !targetEnvironment(simulator)
    import ARKit
    import CoreVideo
    import Metal
    import MetalPerformanceShaders
    import MoqomCore
    import MoqomKit
    import RealityKit
    import SwiftUI
    import VideoToolbox

    enum ARSceneError: Error, CustomStringConvertible {
        case unsupported
        case transferUnavailable(OSStatus)

        var description: String {
            switch self {
            case .unsupported:
                "this device cannot run an AR session"
            case let .transferUnavailable(status):
                "the AR frame could not be scaled to the rung (VTPixelTransfer \(status))"
            }
        }
    }

    /// Publishes a composited AR scene — the camera feed with a floating orb in it.
    ///
    /// Worth having as a source in its own right rather than as a demo: a composited AR
    /// frame is the input a MOQOM broadcast actually carries, and it asks the encoder a
    /// different question from a camera. Synthetic geometry has hard edges, specular
    /// highlights and a perfectly steady shape moving against a hand-held background, and
    /// the orb's silhouette is the first thing to smear when the bitrate is not there.
    ///
    /// Not a `@MainActor` type although most of it is. RealityKit and the session are
    /// main-actor only, but the render callback arrives on the render thread and the frame
    /// conversion runs in a task, so the shared state is behind a lock instead.
    final class ARSceneSource: NSObject, FrameSource, @unchecked Sendable {
        /// What is published, which is the rung and not the drawable. See ``scale(_:)``.
        let captureFormat: CaptureFormat

        /// The view that must be on screen for any of this to produce frames.
        nonisolated(unsafe) let view: ARView

        /// What the SDK reads.
        private let relay: FrameRelay

        private let lock = NSLock()

        /// Created on the first rendered frame rather than at init.
        ///
        /// ``SceneCapture`` requires its configured size to equal the texture it is handed
        /// and drops anything else — deliberately, since a mismatch would mean a scaling
        /// blit on the caller's command buffer. A drawable is sized by the view's layout,
        /// which is not known until it is on screen, so the size has to come from the first
        /// texture. A rotation or a layout change rebuilds rather than silently dropping
        /// every frame from then on.
        private var capture: SceneCapture?
        private var captureSize: PixelSize?
        private var pump: Task<Void, Never>?

        /// Scales and converts the drawable into the rung. Built on first use.
        private var transfer: VTPixelTransferSession?
        private var pool: CVPixelBufferPool?

        /// Cached conversion target for the format RealityKit actually draws in.
        nonisolated(unsafe) private var staging: (any MTLTexture)?
        nonisolated(unsafe) private var stagingSize: PixelSize?
        nonisolated(unsafe) private var converter: MPSImageConversion?

        /// The scene's own clock, for holding the render loop to the rung's rate.
        private var lastSubmitted = 0.0
        private var lastRendered = 0.0

        /// How often the scene is actually being drawn, smoothed. See ``shouldSubmit(at:)``.
        private var interval = 0.0

        private var rendered = 0
        private var published = 0
        private var skipped = 0
        private var isRunning = false

        /// The orb, kept so it can be animated.
        nonisolated(unsafe) private var orb: ModelEntity?

        /// The shared bubbles, when the room is playing rather than posing.
        ///
        /// Replaces the orb rather than joining it. The orb exists to give the
        /// encoder something moving to chew on, and a field of bubbles does
        /// that better — while also being a thing two people can both see.
        @MainActor private(set) var field: BubbleScene?

        /// Installed once, and only when there is something to tap.
        @MainActor private var tapping: UITapGestureRecognizer?

        /// What this source is doing, for the log.
        ///
        /// The drawable is the interesting half. It is chosen by SwiftUI's layout rather
        /// than by anything here, so a tile that shrank is a scene being published from
        /// fewer pixels than the rung asks for, and nothing else in the app would say so.
        var status: String {
            lock.withLock {
                let drawable = captureSize.map { "\($0.width)x\($0.height)" } ?? "not drawn"
                let rate = interval > 0 ? String(format: "%.1f", 1 / interval) : "—"
                return "\(drawable)→\(captureFormat.size.width)x\(captureFormat.size.height)"
                    + " draws=\(rate)fps rendered=\(rendered)"
                    + " published=\(published) skipped=\(skipped)"
            }
        }

        @MainActor
        init(format: CaptureFormat) {
            captureFormat = format
            relay = FrameRelay(format: format, depth: 3)
            view = ARView(frame: .zero)
            super.init()
        }

        static var isSupported: Bool {
            ARFaceTrackingConfiguration.isSupported || ARWorldTrackingConfiguration.isSupported
        }

        @MainActor
        func start() throws {
            try configureSession()
            buildScene()
            lock.withLock { isRunning = true }

            // Installed by hand rather than through `SceneCapture.attach(to:)`, because the
            // capture cannot exist until the first texture reveals the drawable's size.
            view.renderCallbacks.postProcess = { [weak self] context in
                guard let self else { return }
                draw(context)
            }
        }

        func stop() {
            let (capture, pump) = lock.withLock {
                let taken = (self.capture, self.pump)
                self.capture = nil
                self.pump = nil
                isRunning = false
                return taken
            }
            pump?.cancel()
            capture?.stop()
            relay.stop()

            Task { @MainActor [weak self] in self?.tearDown() }
        }

        @MainActor
        private func tearDown() {
            view.renderCallbacks.postProcess = nil
            view.session.pause()
        }

        /// Pause the AR session, which is what holds the camera.
        ///
        /// An AR scene is a camera however it is dressed up, so a moderator's
        /// mute has to reach the session and not only the frames coming out of
        /// it. Pausing keeps the scene and its anchors, so resuming is the
        /// session relocalising rather than the room being rebuilt.
        func suspend() {
            guard lock.withLock({ isRunning }) else { return }
            Task { @MainActor [weak self] in self?.view.session.pause() }
        }

        func resume() {
            guard lock.withLock({ isRunning }) else { return }
            Task { @MainActor [weak self] in try? self?.configureSession(resetting: false) }
        }

        func frames() -> AsyncStream<VideoFrame> { relay.frames() }

        // MARK: - The render callback

        /// Take a copy of what the scene just drew, and hand the frame back to the view.
        ///
        /// Runs on the render thread, so everything here is either cached or a Metal
        /// encode. Nothing waits and nothing touches a pixel on the CPU: the post-process
        /// callback blocking is the compositor blocking, which costs a dropped frame on the
        /// display rather than latency in the stream.
        private func draw(_ context: ARView.PostProcessContext) {
            // Before anything that can return early. A frame skipped for the rate limit is
            // still a frame the view is owed.
            defer {
                if let blit = context.commandBuffer.makeBlitCommandEncoder() {
                    blit.copy(from: context.sourceColorTexture, to: context.targetColorTexture)
                    blit.endEncoding()
                }
            }

            guard shouldSubmit(at: context.time) else { return }

            let source = captureable(context.sourceColorTexture, on: context.commandBuffer)
            let drawable = PixelSize(width: source.width, height: source.height)
            guard let capture = capture(for: drawable, device: source.device) else { return }
            capture.submit(
                texture: source,
                at: FrameTimestamp(seconds: context.time),
                on: context.commandBuffer
            )
        }

        /// Whether the scene has drawn a frame the rung has room for.
        ///
        /// RealityKit draws at the display's rate, which on a ProMotion phone can be 120
        /// against a 60fps rung. Submitting all of them costs a blit, a pool buffer and a
        /// scale each for frames the encoder will throw away, and it costs them on the
        /// render thread, so halving belongs here rather than downstream.
        ///
        /// What it must not do is halve a scene that was already slow enough, and the first
        /// version did exactly that. A gate that skips anything arriving less than a frame
        /// interval after the last one assumes the render loop is a metronome; a real one is
        /// not, and a scene measured at 54 frames a second — with gaps alternating either
        /// side of the interval — lost a fifth of them to a rule written for a scene going
        /// twice too fast. It published 43. So the rate is measured before it is limited,
        /// and a scene that is not outrunning the rung is left alone entirely.
        private func shouldSubmit(at time: Double) -> Bool {
            let rung = 1 / max(captureFormat.frameRate, 1)
            return lock.withLock {
                rendered += 1
                let gap = time - lastRendered
                lastRendered = time
                // Bounded, so that the pause while an AR session starts is not mistaken for
                // a render loop running once a second.
                if gap > 0, gap < 1 {
                    interval = interval > 0 ? interval * 0.9 + gap * 0.1 : gap
                }

                guard interval > 0, interval < rung * 0.75 else {
                    lastSubmitted = time
                    return true
                }

                guard time - lastSubmitted >= rung * 0.9 else {
                    skipped += 1
                    return false
                }
                lastSubmitted = time
                return true
            }
        }

        /// The capture for a drawable size, building it the first time that size is seen.
        private func capture(for drawable: PixelSize, device: any MTLDevice) -> SceneCapture? {
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
                    format: CaptureFormat(size: drawable, frameRate: captureFormat.frameRate),
                    device: device,
                    // So that a size or format this cannot handle says so, rather than
                    // presenting as a scene that never drew.
                    logger: MoqomLogger(
                        sink: SystemLogSink(subsystem: "cloud.moqom.sample", privacy: .hashed),
                        minimum: .warning
                    )
                )
            else { return nil }

            let stream = built.frames()
            let task = Task.detached(priority: .userInitiated) { [weak self] in
                for await frame in stream {
                    guard let self else { return }
                    deliver(frame)
                }
            }

            lock.withLock {
                capture = built
                captureSize = drawable
                pump?.cancel()
                pump = task
            }
            Journal.shared.say(
                "SCENE drawable=\(drawable.width)x\(drawable.height)"
                    + " rung=\(captureFormat.size.width)x\(captureFormat.size.height)"
            )
            return built
        }

        /// Convert the drawable into a format a capture can copy, if it is not one already.
        ///
        /// The staging texture is `_srgb` so the store re-encodes. Sampling the source
        /// linearises it, and writing that linear value into a plain `bgra8Unorm` hands the
        /// encoder a visibly dark frame. Values above one clamp, which is what tone mapping
        /// an extended-range scene into an eight-bit encoder means.
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

        // MARK: - Into the rung

        private func deliver(_ frame: VideoFrame) {
            guard case let .pixelBuffer(buffer) = frame.surface else { return }
            guard let scaled = scale(buffer) else { return }
            let first = lock.withLock {
                published += 1
                return published == 1
            }
            if first { Journal.shared.say("SCENE sample \(Self.sample(scaled))") }
            relay.submit(
                VideoFrame(
                    timestamp: frame.timestamp,
                    size: captureFormat.size,
                    surface: .pixelBuffer(scaled)
                )
            )
        }

        /// Put a drawable-sized BGRA frame into a rung-sized biplanar YUV one.
        ///
        /// Two conversions in one pass, on the video hardware rather than the CPU: the
        /// scale, because a drawable is the size of a tile and a rung is 720×1280 whatever
        /// the tile does; and the colour, because the hardware encoder consumes video-range
        /// biplanar YUV and handing it anything else inserts exactly this conversion
        /// silently, one frame at a time, where nothing reports it.
        ///
        /// Letterboxed rather than stretched. The tile is given the rung's aspect ratio, so
        /// in the ordinary case there is nothing to letterbox and this only matters when a
        /// layout puts the scene in a box of some other shape — where bars are the honest
        /// answer and a stretched face is not.
        private func scale(_ source: CVPixelBuffer) -> CVPixelBuffer? {
            guard let session = try? transferSession(), let pool = try? bufferPool() else {
                return nil
            }

            var destination: CVPixelBuffer?
            guard
                CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destination)
                == kCVReturnSuccess,
                let destination
            else {
                // Every buffer still in flight, which is backpressure rather than an error.
                return nil
            }

            guard
                VTPixelTransferSessionTransferImage(session, from: source, to: destination)
                == noErr
            else { return nil }
            return destination
        }

        /// One pixel from the middle of the first published frame.
        ///
        /// Cheap insurance against the failure this path is prone to, and the one thing no
        /// other line here can see. Every counter in the app reports a frame count, a
        /// uniform field of magenta is a frame, and the difference between a scene and a
        /// conversion that went wrong is entirely in the two chroma bytes. Neutral content
        /// puts them near 128; the magenta a misread texture format produces pins them at
        /// roughly u=202 v=171 and holds them there.
        private static func sample(_ buffer: CVPixelBuffer) -> String {
            guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
                return "unreadable"
            }
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

            guard
                let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
                let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)
            else { return "no planes" }

            let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            let rows = CVPixelBufferGetHeightOfPlane(buffer, 0)
            let y = luma.assumingMemoryBound(to: UInt8.self)[
                (rows / 2) * lumaStride + lumaStride / 2
            ]
            let uv = chroma.assumingMemoryBound(to: UInt8.self) + (rows / 4) * chromaStride
                + (chromaStride / 4) * 2

            return "\(CVPixelBufferGetWidth(buffer))x\(CVPixelBufferGetHeight(buffer))"
                + " centre y=\(y) u=\(uv[0]) v=\(uv[1])"
        }

        private func transferSession() throws -> VTPixelTransferSession {
            try lock.withLock {
                if let transfer { return transfer }
                var created: VTPixelTransferSession?
                let status = VTPixelTransferSessionCreate(
                    allocator: nil, pixelTransferSessionOut: &created
                )
                guard status == noErr, let created else {
                    throw ARSceneError.transferUnavailable(status)
                }
                VTSessionSetProperty(
                    created,
                    key: kVTPixelTransferPropertyKey_ScalingMode,
                    value: kVTScalingMode_Letterbox
                )
                transfer = created
                return created
            }
        }

        private func bufferPool() throws -> CVPixelBufferPool {
            try lock.withLock {
                if let pool { return pool }
                let attributes: [CFString: Any] = [
                    kCVPixelBufferPixelFormatTypeKey:
                        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                    kCVPixelBufferWidthKey: captureFormat.size.width,
                    kCVPixelBufferHeightKey: captureFormat.size.height,
                    kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                ]
                var created: CVPixelBufferPool?
                let status = CVPixelBufferPoolCreate(
                    kCFAllocatorDefault, nil, attributes as CFDictionary, &created
                )
                guard status == kCVReturnSuccess, let created else {
                    throw ARSceneError.transferUnavailable(status)
                }
                pool = created
                return created
            }
        }

        // MARK: - The scene

        /// The user-facing camera, so the orb floats in the scene with whoever is on the
        /// call rather than behind them.
        /// - Parameter resetting: Whether to start the world over. True when the
        ///   scene is being built; false when the session is only coming back
        ///   from a mute, where resetting would take the shared bubbles with it.
        @MainActor
        private func configureSession(resetting: Bool = true) throws {
            let options: ARSession.RunOptions =
                resetting ? [.resetTracking, .removeExistingAnchors] : []
            if ARFaceTrackingConfiguration.isSupported {
                let configuration = ARFaceTrackingConfiguration()
                configuration.isWorldTrackingEnabled = false
                view.session.run(configuration, options: options)
            } else if ARWorldTrackingConfiguration.isSupported {
                let configuration = ARWorldTrackingConfiguration()
                view.session.run(configuration, options: options)
            } else {
                throw ARSceneError.unsupported
            }

            // The phone is already encoding sixty frames a second and holding a call open.
            // Everything switched off here is something RealityKit would otherwise spend
            // GPU on, in front of an encoder that needs it and a thermal budget that is the
            // real limit on how long this can run.
            view.renderOptions = [
                .disableMotionBlur, .disableDepthOfField, .disableFaceMesh, .disableHDR,
                .disableGroundingShadows, .disablePersonOcclusion,
            ]
            view.automaticallyConfigureSession = false
            view.environment.background = .cameraFeed()
        }

    /// Put a shared bubble field in the scene, and let taps reach it.
    ///
    /// Separate from ``start()`` because the field belongs to the room and the
    /// scene belongs to the device: a broadcast can begin before anybody has
    /// joined a space, and joining one should not restart the camera.
    @MainActor
    func show(_ field: BubbleScene) {
        self.field = field
        orb?.removeFromParent()
        orb = nil
        if !view.scene.anchors.contains(where: { $0 === field.root }) {
            view.scene.addAnchor(field.root)
        }
        installTapHandling()
    }

    @MainActor
    func hideField() {
        field?.clear()
        field.map { view.scene.removeAnchor($0.root) }
        field = nil
        buildScene()
    }

    @MainActor
    private func installTapHandling() {
        guard tapping == nil else { return }
        let recogniser = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        view.addGestureRecognizer(recogniser)
        tapping = recogniser
    }

    @MainActor
    @objc private func handleTap(_ recogniser: UITapGestureRecognizer) {
        guard let field else { return }
        field.pop(at: recogniser.location(in: view), in: view)
    }

    /// A glowing sphere floating in front of the camera, bobbing so the scene is never
    /// static.
    ///
    /// Motion matters more than looks. A still overlay compresses to nothing after the
    /// first frame, and a codec handed nothing to do reports a bitrate and a latency no
    /// real broadcast will ever see.
    @MainActor
    private func buildScene() {
        view.scene.anchors.removeAll()
        if let field {
            // The field survives a rebuild: it is the room's state, not the
            // scene's, and dropping it here would empty a space that is still
            // being played in on the other phone.
            view.scene.addAnchor(field.root)
            let light = DirectionalLight()
            light.light.intensity = 2600
            light.look(at: [0, 0, -0.5], from: [0.4, 0.6, 0], relativeTo: field.root)
            field.root.addChild(light)
            return
        }

        let sphere = ModelEntity(
                mesh: .generateSphere(radius: 0.08),
                materials: [SimpleMaterial(color: .cyan, roughness: 0.15, isMetallic: true)]
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
                guard let self, let entity, let anchor, lock.withLock({ isRunning }) else { return }
                var back = entity.transform
                back.translation = [-0.12, -0.05, -0.5]
                entity.move(to: back, relativeTo: anchor, duration: 2, timingFunction: .easeInOut)
                try? await Task.sleep(for: .seconds(2))
                guard lock.withLock({ isRunning }) else { return }
                orbit(entity, around: anchor)
            }
        }
    }

    /// Hosts the `ARView` so RealityKit has a window to render into.
    ///
    /// This is the self tile while the scene is the source, rather than an extra view
    /// somewhere: the scene has to be on screen to be drawn at all, and a preview of the
    /// published frames next to a hidden copy of the same scene would be two of everything
    /// for no gain. What is on screen here is the scene itself, before the encoder — which
    /// is what a self view is supposed to be.
    struct ARSceneView: UIViewRepresentable {
        let source: ARSceneSource

        func makeUIView(context _: Context) -> ARView { source.view }
        func updateUIView(_: ARView, context _: Context) {}
    }
#endif
