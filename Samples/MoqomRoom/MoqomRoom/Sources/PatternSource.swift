// A camera substitute that produces real pixels.
//
// The sample used to hand the SDK a `FrameRelay` that nobody ever submitted to,
// which meant "Go live" announced a namespace, published a catalog, and sent no
// media at all. That is worse than not working, because from the outside it
// looks like it does: the roster updates and the controls change state.
//
// So this renders. Not because a moving gradient is interesting, but because
// every stage downstream of it — VideoToolbox, the packetiser, SFrame, the
// relay, reassembly, the display layer — is only exercised by bytes that
// decode. A simulator has no camera and this is what stands in for one; on a
// device, `CameraSource` is a one-line swap and everything after it is
// identical.
//
// Pixels are drawn on the CPU into a pooled buffer, which is exactly what the
// SDK's own documentation says not to do from a render callback. It is correct
// here and nowhere else: there is no render loop to stall, and the alternative
// is a Metal pipeline whose only job is to make a test pattern.

import CoreVideo
import Foundation
import MoqomCore
import MoqomKit

/// Renders an animated pattern at a fixed rate.
final class PatternSource: FrameSource, @unchecked Sendable {
    let captureFormat: CaptureFormat

    private let relay: FrameRelay
    private let pool: CVPixelBufferPool?
    private var task: Task<Void, Never>?

    /// A second copy of every frame, for the local preview.
    ///
    /// A tee rather than a second consumer of `frames()`: a `FrameSource`
    /// supports one, and two iterations of one stream would give the preview
    /// half the frames and the encoder the other half.
    private let previewStream: AsyncStream<VideoFrame>
    private let previewContinuation: AsyncStream<VideoFrame>.Continuation

    /// - Parameter label: Drawn as a colour seed, so two participants in one
    ///   room are visibly different streams rather than two copies of the same
    ///   gradient.
    init(format: CaptureFormat, label: String) {
        captureFormat = format
        relay = FrameRelay(format: format, depth: 3)
        // Not `hashValue`: Swift seeds that per process, so the same person
        // would be a different colour on every launch and the colour would
        // stop meaning anything.
        hue = Double(label.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) % 360 }) / 360
        pool = Self.makePool(size: format.size)
        (previewStream, previewContinuation) = AsyncStream.makeStream(
            of: VideoFrame.self,
            bufferingPolicy: .bufferingNewest(2)
        )
    }

    private let hue: Double

    func frames() -> AsyncStream<VideoFrame> {
        start()
        return relay.frames()
    }

    /// What this device is capturing, before it is encoded.
    func preview() -> AsyncStream<VideoFrame> {
        start()
        return previewStream
    }

    func stop() {
        task?.cancel()
        task = nil
        relay.stop()
        previewContinuation.finish()
    }

    private func start() {
        guard task == nil else { return }
        let interval = Duration.nanoseconds(
            Int(1_000_000_000 / max(1, captureFormat.frameRate))
        )
        task = Task { [weak self] in
            var index: UInt64 = 0
            while !Task.isCancelled {
                guard let self else { return }
                if let frame = render(index: index) {
                    relay.submit(frame)
                    previewContinuation.yield(frame)
                }
                index += 1
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func render(index: UInt64) -> VideoFrame? {
        guard let pool, let buffer = Self.buffer(from: pool) else { return nil }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let phase = Double(index % 120) / 120

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)

        // A vertical bar sweeping across a gradient. The bar is what makes a
        // stalled stream obvious at a glance — a still gradient and a frozen
        // one look the same.
        let barX = Int(phase * Double(width))
        for y in 0 ..< height {
            let row = pixels + y * stride
            let vertical = Double(y) / Double(height)
            for x in 0 ..< width {
                let horizontal = Double(x) / Double(width)
                let (r, g, b) = Self.colour(
                    hue: (hue + horizontal * 0.25).truncatingRemainder(dividingBy: 1),
                    brightness: 0.35 + vertical * 0.4
                )
                let isBar = abs(x - barX) < 6
                let pixel = row + x * 4
                pixel[0] = isBar ? 255 : b
                pixel[1] = isBar ? 255 : g
                pixel[2] = isBar ? 255 : r
                pixel[3] = 255
            }
        }

        return VideoFrame(
            timestamp: FrameTimestamp(
                nanoseconds: index * UInt64(1_000_000_000 / max(1, captureFormat.frameRate))
            ),
            size: PixelSize(width: width, height: height),
            surface: .pixelBuffer(buffer),
            // The encoder's own keyframe interval handles the rest; this is
            // only about the first frame, so a viewer who is already watching
            // does not wait two seconds for a picture.
            forcesKeyFrame: index == 0
        )
    }

    private static func colour(hue: Double, brightness: Double) -> (UInt8, UInt8, UInt8) {
        let sector = hue * 6
        let index = Int(sector) % 6
        let fraction = sector - Double(Int(sector))
        let peak = brightness
        let trough = brightness * 0.2
        let rising = trough + (peak - trough) * fraction
        let falling = peak - (peak - trough) * fraction

        let (r, g, b): (Double, Double, Double) = switch index {
        case 0: (peak, rising, trough)
        case 1: (falling, peak, trough)
        case 2: (trough, peak, rising)
        case 3: (trough, falling, peak)
        case 4: (rising, trough, peak)
        default: (peak, trough, falling)
        }
        return (UInt8(r * 255), UInt8(g * 255), UInt8(b * 255))
    }

    /// A pool rather than an allocation per frame.
    ///
    /// Not for speed. `CVPixelBufferCreate` per frame at 30fps produces
    /// IOSurface churn that shows up as a stutter under memory pressure, and
    /// the pool is also what the SDK's contract asks for.
    private static func makePool(size: PixelSize) -> CVPixelBufferPool? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: size.width,
            kCVPixelBufferHeightKey: size.height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            [kCVPixelBufferPoolMinimumBufferCountKey: 4] as CFDictionary,
            attributes as CFDictionary,
            &pool
        )
        return status == kCVReturnSuccess ? pool : nil
    }

    private static func buffer(from pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        return status == kCVReturnSuccess ? buffer : nil
    }
}
