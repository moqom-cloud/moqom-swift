// Publishing a rendered scene.
//
// The scene is already on the GPU when RealityKit hands it over, and the whole
// job here is to keep it there. A read-back to a `UIImage`, or any CPU touch of
// the pixels, costs more than the encode does and shows up as a dropped frame
// on the display rather than as latency in the stream — the post-process
// callback runs on the render thread and blocking it blocks the compositor.
//
// So the path is: RealityKit's colour texture, a blit into a pool-allocated
// IOSurface-backed `CVPixelBuffer`, and a handoff at command buffer completion.
// No frame is ever mapped.
//
// The pool matters as much as the blit. VideoToolbox will accept any pixel
// buffer and silently route an unsuitable one through a `VTPixelTransferSession`
// copy on every frame, so a scene capture that is not drawing from the
// encoder's own pool looks correct and costs roughly what the read-back would
// have. ``SceneCapture/adoptPool(_:)`` is how the encoder's pool gets here.

import Foundation
import MoqomCore

#if canImport(Metal) && canImport(CoreVideo)
    import CoreVideo
    import Metal

    /// A frame source fed by a renderer.
    ///
    /// This is the RealityKit case as a first-class citizen rather than an
    /// adapter over a camera abstraction: the SDK owns no render loop, the
    /// caller does, and frames arrive when the scene is drawn.
    ///
    /// ```swift
    /// let capture = try SceneCapture(
    ///     format: CaptureFormat(size: PixelSize(width: 1920, height: 1080), frameRate: 60)
    /// )
    /// let broadcast = try await room.startBroadcast(from: capture)
    ///
    /// // From the renderer's post-process callback:
    /// capture.submit(
    ///     texture: context.sourceColorTexture,
    ///     at: FrameTimestamp(seconds: context.time),
    ///     on: context.commandBuffer
    /// )
    /// ```
    ///
    /// > Important: The Metal and CoreVideo calls here compile on every Apple
    /// > platform but are not exercised by the test suite, which has no GPU.
    /// > ``FrameRelay`` is the tested path through the same API.
    public final class SceneCapture: FrameSource, @unchecked Sendable {
        public let captureFormat: CaptureFormat

        private let device: any MTLDevice
        private let textureCache: CVMetalTextureCache
        private let relay: FrameRelay
        private let logger: MoqomLogger
        private let lock = NSLock()

        /// Guarded by ``lock``, because ``adoptPool(_:)`` may be called from the
        /// broadcast actor while the render thread is drawing from it.
        private var pool: CVPixelBufferPool

        /// What ``pool`` vends, and whether the caller chose it. Guarded by ``lock``.
        ///
        /// Tracked because the pool's format has to agree with the format of the
        /// texture being copied in, which is not known until the renderer draws.
        private var poolFormat: OSType
        private var poolWasAdopted = false

        /// The mismatched size most recently complained about, guarded by ``lock``.
        ///
        /// Remembered so the warning is one line per size rather than one per frame,
        /// while a genuine change — a rotation resizes the drawable — still reports.
        private var reportedMismatch: PixelSize?

        /// The texture format most recently refused, guarded by ``lock``.
        private var reportedFormat: MTLPixelFormat?

        /// - Parameters:
        ///   - format: What the renderer will produce. Must match the texture
        ///     handed to ``submit(texture:at:on:)``; a mismatch is a scaling
        ///     blit the SDK will not do, and every frame is dropped and reported
        ///     through `logger`. A renderer whose drawable is sized by a view's
        ///     layout does not know this until it has drawn once, so take the size
        ///     from the first texture rather than from what you intend to publish.
        ///   - device: Must be the same device the renderer draws with.
        ///     Cross-device textures cannot be blitted.
        ///   - logger: Where a rejected frame is reported. Worth passing: a size
        ///     mismatch is invisible from the outside, since the scene keeps
        ///     rendering and only the stream is empty.
        public init(
            format: CaptureFormat,
            device: (any MTLDevice)? = nil,
            depth: Int = 3,
            logger: MoqomLogger = .silent
        ) throws {
            guard let resolved = device ?? MTLCreateSystemDefaultDevice() else {
                throw MoqomError.platform(api: "MTLCreateSystemDefaultDevice", status: -1)
            }
            captureFormat = format
            self.device = resolved
            self.logger = logger
            relay = FrameRelay(format: format, depth: depth)
            poolFormat = kCVPixelFormatType_32BGRA
            pool = try Self.makePool(size: format.size, format: poolFormat)

            var cache: CVMetalTextureCache?
            let status = CVMetalTextureCacheCreate(
                kCFAllocatorDefault,
                nil,
                resolved,
                nil,
                &cache
            )
            guard status == kCVReturnSuccess, let cache else {
                throw MoqomError.platform(api: "CVMetalTextureCacheCreate", status: status)
            }
            textureCache = cache
        }

        /// Draw from the encoder's pool instead of a private one.
        ///
        /// Worth doing before the first frame and pointless after: buffers
        /// already in flight came from the old pool and will keep the old pool
        /// alive until they drain.
        public func adoptPool(_ replacement: CVPixelBufferPool) {
            lock.withLock {
                pool = replacement
                poolFormat = Self.format(of: replacement) ?? kCVPixelFormatType_32BGRA
                poolWasAdopted = true
            }
        }

        /// Hand over the scene's colour texture.
        ///
        /// Non-blocking. The blit is encoded onto the caller's command buffer,
        /// so it costs the render thread an encode and not a wait, and the
        /// frame is published from the completion handler.
        ///
        /// - Parameter texture: Must remain valid until `commandBuffer`
        ///   completes, which RealityKit's own textures do.
        public func submit(
            texture: any MTLTexture,
            at timestamp: FrameTimestamp,
            on commandBuffer: any MTLCommandBuffer
        ) {
            // A same-size blit is a copy; a different size is a scale, which is
            // a render pass and not something to do behind the caller's back on
            // their command buffer. Configure the format to match the renderer.
            //
            // Reported, because dropping silently here is indistinguishable from a
            // renderer that never draws: the scene stays on screen and only the
            // stream is empty, which sends anyone debugging it to the render loop
            // instead of to the one line of configuration that is actually wrong.
            guard
                texture.width == captureFormat.size.width,
                texture.height == captureFormat.size.height
            else {
                reportMismatch(
                    PixelSize(width: texture.width, height: texture.height)
                )
                return
            }

            // A blit is a byte copy, so the buffer it lands in has to have the same
            // layout as the texture it comes from. Copying a half-float texture into
            // a BGRA8 buffer is not a conversion, it is 8 bytes per pixel read as 4,
            // and the frame that comes out the other side is uniform magenta.
            guard let layout = Layout(texture.pixelFormat) else {
                reportUnsupported(texture.pixelFormat)
                return
            }

            guard let currentPool = pool(for: layout) else { return }

            var buffer: CVPixelBuffer?
            guard
                CVPixelBufferPoolCreatePixelBuffer(
                    kCFAllocatorDefault,
                    currentPool,
                    &buffer
                ) == kCVReturnSuccess,
                let buffer,
                let destination = metalTexture(for: buffer, as: layout.viewFormat),
                let blit = commandBuffer.makeBlitCommandEncoder()
            else {
                // A pool that cannot vend is a pool whose buffers are all still
                // in flight, which is backpressure and not an error. Dropping
                // here is the same policy the relay applies one step later.
                return
            }

            blit.copy(from: texture, to: destination)
            blit.endEncoding()

            layout.tag(buffer)

            // Built here rather than inside the handler. `addCompletedHandler`
            // takes a `@Sendable` closure and `CVPixelBuffer` is not Sendable,
            // so capturing the buffer directly asks every call site to vouch for
            // it. `FrameSurface` is where that judgement already lives — it is
            // `@unchecked Sendable` with the reasoning attached — and a
            // `VideoFrame` is Sendable outright, so handing the closure a frame
            // keeps the unsafety in one documented place.
            let frame = VideoFrame(
                timestamp: timestamp,
                size: PixelSize(width: texture.width, height: texture.height),
                surface: .pixelBuffer(buffer)
            )
            let relay = relay
            commandBuffer.addCompletedHandler { _ in relay.submit(frame) }
        }

        /// Hand over a buffer that is already in the right shape.
        ///
        /// For a renderer that draws straight into a pooled buffer — the
        /// visionOS `RealityRenderer` path — where there is nothing to blit.
        public func submit(pixelBuffer: CVPixelBuffer, at timestamp: FrameTimestamp) {
            relay.submit(
                VideoFrame(
                    timestamp: timestamp,
                    size: PixelSize(
                        width: CVPixelBufferGetWidth(pixelBuffer),
                        height: CVPixelBufferGetHeight(pixelBuffer)
                    ),
                    surface: .pixelBuffer(pixelBuffer)
                )
            )
        }

        public func frames() -> AsyncStream<VideoFrame> { relay.frames() }

        public func stop() { relay.stop() }

        /// Complain once per texture size that does not match the configuration.
        ///
        /// Called from the render thread on a frame that is being dropped, so it does
        /// as little as possible: a compare under the lock, and a log only when the
        /// answer changed.
        private func reportMismatch(_ actual: PixelSize) {
            let shouldReport = lock.withLock { () -> Bool in
                guard reportedMismatch != actual else { return false }
                reportedMismatch = actual
                return true
            }
            guard shouldReport else { return }

            logger.warning(
                .publish,
                "scene capture is dropping every frame: the renderer's texture is not the "
                    + "configured size, and scaling it is not something the SDK will do on "
                    + "your command buffer",
                [
                    LogField("texture_width", .number(actual.width)),
                    LogField("texture_height", .number(actual.height)),
                    LogField("configured_width", .number(captureFormat.size.width)),
                    LogField("configured_height", .number(captureFormat.size.height)),
                ]
            )
        }

        /// What a renderer's texture format means for the buffer it is copied into.
        ///
        /// Only the formats a renderer actually draws with are here. A texture in
        /// anything else is refused rather than reinterpreted, because every wrong
        /// answer available — swapping channels, reading half the bytes — produces a
        /// frame that looks like a broken codec rather than a broken configuration.
        private struct Layout {
            let bufferFormat: OSType
            let viewFormat: MTLPixelFormat

            /// Whether the values are linear light rather than display-encoded.
            let isLinear: Bool

            init?(_ format: MTLPixelFormat) {
                switch format {
                case .bgra8Unorm, .bgra8Unorm_srgb:
                    self.init(
                        bufferFormat: kCVPixelFormatType_32BGRA,
                        viewFormat: .bgra8Unorm,
                        isLinear: false
                    )
                // RealityKit's post-process pipeline hands over linear half-float, and
                // 64RGBAHalf is the only CoreVideo format that can hold it losslessly.
                case .rgba16Float:
                    self.init(
                        bufferFormat: kCVPixelFormatType_64RGBAHalf,
                        viewFormat: .rgba16Float,
                        isLinear: true
                    )
                default:
                    return nil
                }
            }

            private init(bufferFormat: OSType, viewFormat: MTLPixelFormat, isLinear: Bool) {
                self.bufferFormat = bufferFormat
                self.viewFormat = viewFormat
                self.isLinear = isLinear
            }

            /// Say what the pixels mean, so the conversion to YUV is right.
            ///
            /// Untagged linear values get read as though they were gamma-encoded, which
            /// is not garbage but is visibly wrong — washed out and too bright — and
            /// looks enough like a bad reconstruction to be blamed on the encoder.
            func tag(_ buffer: CVPixelBuffer) {
                guard isLinear else { return }
                CVBufferSetAttachment(
                    buffer,
                    kCVImageBufferTransferFunctionKey,
                    kCVImageBufferTransferFunction_Linear,
                    .shouldPropagate
                )
                CVBufferSetAttachment(
                    buffer,
                    kCVImageBufferColorPrimariesKey,
                    kCVImageBufferColorPrimaries_ITU_R_709_2,
                    .shouldPropagate
                )
                CVBufferSetAttachment(
                    buffer,
                    kCVImageBufferYCbCrMatrixKey,
                    kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                    .shouldPropagate
                )
            }
        }

        /// The pool for a layout, rebuilding it if the renderer's format is not what
        /// the current one vends.
        ///
        /// The format is not known at init — the renderer has not drawn yet — so the
        /// first frame is where it gets settled.
        private func pool(for layout: Layout) -> CVPixelBufferPool? {
            lock.lock()
            if poolFormat == layout.bufferFormat {
                defer { lock.unlock() }
                return pool
            }
            let wasAdopted = poolWasAdopted
            lock.unlock()

            guard
                let replacement = try? Self.makePool(
                    size: captureFormat.size,
                    format: layout.bufferFormat
                )
            else { return nil }

            lock.withLock {
                pool = replacement
                poolFormat = layout.bufferFormat
                poolWasAdopted = false
            }

            // Worth saying out loud: an adopted pool is the encoder's, and abandoning it
            // reintroduces exactly the per-frame conversion ``adoptPool(_:)`` exists to
            // avoid. The caller cannot fix it from here — the renderer's format is the
            // renderer's — but they should know why the copy came back.
            if wasAdopted {
                logger.warning(
                    .publish,
                    "the encoder's pixel buffer pool cannot hold this renderer's texture "
                        + "format, so scene capture is using its own and the frames will be "
                        + "converted on the way into the encoder",
                    [LogField("buffer_format", .text(Self.name(of: layout.bufferFormat)))]
                )
            }
            return replacement
        }

        /// Complain once per texture format that cannot be copied without conversion.
        private func reportUnsupported(_ format: MTLPixelFormat) {
            let shouldReport = lock.withLock { () -> Bool in
                guard reportedFormat != format else { return false }
                reportedFormat = format
                return true
            }
            guard shouldReport else { return }

            logger.warning(
                .publish,
                "scene capture is dropping every frame: the renderer's texture format is "
                    + "not one that can be copied into a pixel buffer, and reinterpreting it "
                    + "would publish garbage",
                [LogField("texture_format", .number(Int(format.rawValue)))]
            )
        }

        private static func format(of pool: CVPixelBufferPool) -> OSType? {
            guard
                let attributes = CVPixelBufferPoolGetPixelBufferAttributes(pool)
                    as NSDictionary?,
                let format = attributes[kCVPixelBufferPixelFormatTypeKey as String] as? NSNumber
            else { return nil }
            return OSType(truncating: format)
        }

        private static func name(of format: OSType) -> String {
            String(
                bytes: [24, 16, 8, 0].map { UInt8((format >> $0) & 0xFF) },
                encoding: .ascii
            ) ?? "\(format)"
        }

        private func metalTexture(
            for buffer: CVPixelBuffer,
            as viewFormat: MTLPixelFormat
        ) -> (any MTLTexture)? {
            var wrapped: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                textureCache,
                buffer,
                nil,
                viewFormat,
                CVPixelBufferGetWidth(buffer),
                CVPixelBufferGetHeight(buffer),
                0,
                &wrapped
            )
            guard status == kCVReturnSuccess, let wrapped else { return nil }
            return CVMetalTextureGetTexture(wrapped)
        }

        /// An RGB format rather than a biplanar YUV one.
        ///
        /// The tradeoff is deliberate: matching the renderer's own layout makes the
        /// blit a straight copy and leaves the colour conversion to VideoToolbox,
        /// which does it on the video hardware. A `420v` pool would save that
        /// conversion but needs a compute shader here to do the same work, and doing
        /// it in the render pass is only a win once the shader is also doing
        /// something else — which, once scene effects exist, it will be.
        private static func makePool(size: PixelSize, format: OSType) throws
            -> CVPixelBufferPool
        {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: format,
                kCVPixelBufferWidthKey: size.width,
                kCVPixelBufferHeightKey: size.height,
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]

            var pool: CVPixelBufferPool?
            let status = CVPixelBufferPoolCreate(
                kCFAllocatorDefault,
                nil,
                attributes as CFDictionary,
                &pool
            )
            guard status == kCVReturnSuccess, let pool else {
                throw MoqomError.platform(api: "CVPixelBufferPoolCreate", status: status)
            }
            return pool
        }
    }
#endif
