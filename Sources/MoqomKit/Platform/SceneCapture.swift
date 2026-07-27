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
        private let lock = NSLock()

        /// Guarded by ``lock``, because ``adoptPool(_:)`` may be called from the
        /// broadcast actor while the render thread is drawing from it.
        private var pool: CVPixelBufferPool

        /// - Parameters:
        ///   - format: What the renderer will produce. Must match the texture
        ///     handed to ``submit(texture:at:on:)``; a mismatch is a scaling
        ///     blit the SDK will not do silently.
        ///   - device: Must be the same device the renderer draws with.
        ///     Cross-device textures cannot be blitted.
        public init(format: CaptureFormat, device: (any MTLDevice)? = nil, depth: Int = 3) throws {
            guard let resolved = device ?? MTLCreateSystemDefaultDevice() else {
                throw MoqomError.platform(api: "MTLCreateSystemDefaultDevice", status: -1)
            }
            captureFormat = format
            self.device = resolved
            relay = FrameRelay(format: format, depth: depth)
            pool = try Self.makePool(size: format.size)

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
            lock.withLock { pool = replacement }
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
            guard
                texture.width == captureFormat.size.width,
                texture.height == captureFormat.size.height
            else { return }

            let currentPool = lock.withLock { pool }

            var buffer: CVPixelBuffer?
            guard
                CVPixelBufferPoolCreatePixelBuffer(
                    kCFAllocatorDefault,
                    currentPool,
                    &buffer
                ) == kCVReturnSuccess,
                let buffer,
                let destination = metalTexture(for: buffer),
                let blit = commandBuffer.makeBlitCommandEncoder()
            else {
                // A pool that cannot vend is a pool whose buffers are all still
                // in flight, which is backpressure and not an error. Dropping
                // here is the same policy the relay applies one step later.
                return
            }

            blit.copy(from: texture, to: destination)
            blit.endEncoding()

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

        private func metalTexture(for buffer: CVPixelBuffer) -> (any MTLTexture)? {
            var wrapped: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                textureCache,
                buffer,
                nil,
                .bgra8Unorm,
                CVPixelBufferGetWidth(buffer),
                CVPixelBufferGetHeight(buffer),
                0,
                &wrapped
            )
            guard status == kCVReturnSuccess, let wrapped else { return nil }
            return CVMetalTextureGetTexture(wrapped)
        }

        /// BGRA rather than a biplanar YUV format.
        ///
        /// The tradeoff is deliberate: BGRA makes the blit a straight copy and
        /// leaves the colour conversion to VideoToolbox, which does it on the
        /// video hardware. A `420v` pool would save that conversion but needs a
        /// compute shader here to do the same work, and doing it in the render
        /// pass is only a win once the shader is also doing something else —
        /// which, once scene effects exist, it will be.
        private static func makePool(size: PixelSize) throws -> CVPixelBufferPool {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
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
