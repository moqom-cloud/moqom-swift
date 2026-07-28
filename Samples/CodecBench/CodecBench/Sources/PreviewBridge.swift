// Turning what the codec handled into something the display layer can show.
//
// Both tiles come from inside the codec on purpose. The source tile is not a second tap on
// the camera: it is the very buffer handed to the encoder, after rotation and scaling, so
// what you compare against the reconstruction is what the model was actually asked to
// compress rather than a parallel view of roughly the same scene.
//
// Frames are copied into fresh buffers rather than forwarded. The codec's input comes from
// a pool and is overwritten on the next frame, while a display layer holds what it is
// given until it has shown it — forwarding the pool buffer would tear.

import CoreML
import CoreVideo
import Foundation
import MoqomCore

/// Copies the codec's input and output into buffers safe to hand to a renderer.
struct PreviewBridge {
    /// Separate copiers, because the two sides need not share a format: an input is NV12
    /// while a learned codec's reconstruction arrives as a tensor and becomes BGRA.
    private var sourceCopies = BufferCopier()
    private var decodedCopies = BufferCopier()

    private var decodedPool: CVPixelBufferPool?
    private var decodedSize = PixelSize(width: 0, height: 0)

    /// A copy of the frame that went into the encoder.
    mutating func source(from buffer: CVPixelBuffer, at seconds: Double) -> VideoFrame? {
        sourceCopies.copy(buffer, at: seconds)
    }

    /// A copy of a decoded frame that is already a pixel buffer, as the hardware path's is.
    mutating func decoded(from buffer: CVPixelBuffer, at seconds: Double) -> VideoFrame? {
        decodedCopies.copy(buffer, at: seconds)
    }

    /// The reconstruction, as a frame a renderer will accept.
    ///
    /// Read through the array's strides rather than as packed memory. Core ML pads rows to
    /// an alignment boundary — a 720-wide frame comes back with a stride of 736 — and
    /// treating that as dense displaces every row by the padding, which shears the picture
    /// into diagonal bands and looks exactly like a broken codec.
    mutating func decoded(from array: MLMultiArray, at seconds: Double) -> VideoFrame? {
        let shape = array.shape.map(\.intValue)
        guard shape.count == 4, shape[1] >= 3 else { return nil }
        let size = PixelSize(width: shape[3], height: shape[2])

        if decodedPool == nil || decodedSize != size {
            decodedPool = SyntheticScene.pool(for: size, format: kCVPixelFormatType_32BGRA)
            decodedSize = size
        }
        guard let decodedPool, let buffer = SyntheticScene.buffer(from: decodedPool) else {
            return nil
        }

        let strides = array.strides.map(\.intValue)
        let (channel, row, column) = (strides[1], strides[2], strides[3])

        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let destinationStride = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)

        try? array.withUnsafeBytes { raw in
            guard let values = raw.baseAddress?.assumingMemoryBound(to: Float16.self) else {
                return
            }
            for y in 0 ..< size.height {
                let line = pixels + y * destinationStride
                for x in 0 ..< size.width {
                    let source = y * row + x * column
                    let out = x * 4
                    line[out] = Self.byte(values[source + 2 * channel])
                    line[out + 1] = Self.byte(values[source + channel])
                    line[out + 2] = Self.byte(values[source])
                    line[out + 3] = 255
                }
            }
        }

        return VideoFrame(
            timestamp: FrameTimestamp(seconds: seconds), size: size, surface: .pixelBuffer(buffer)
        )
    }

    /// The models work in the unit range, which `pixel_range` in the export declares.
    private static func byte(_ value: Float16) -> UInt8 {
        UInt8(min(max(Float(value), 0), 1) * 255)
    }
}

/// Duplicates pixel buffers into a pool of its own.
///
/// Both codecs hand back buffers they still own — the encoder's input is overwritten on the
/// next frame and a decoder recycles its output — while a display layer keeps what it is
/// given until it has shown it. Copying is what stops the tile from tearing.
private struct BufferCopier {
    private var pool: CVPixelBufferPool?
    private var format: OSType = 0
    private var size = PixelSize(width: 0, height: 0)

    mutating func copy(_ buffer: CVPixelBuffer, at seconds: Double) -> VideoFrame? {
        let size = PixelSize(
            width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)
        )
        let format = CVPixelBufferGetPixelFormatType(buffer)

        // The pool matches the source's own format, so this stays a copy. A pool of some
        // other format would make the display layer convert on every single frame.
        if pool == nil || self.format != format || self.size != size {
            pool = SyntheticScene.pool(for: size, format: format)
            self.format = format
            self.size = size
        }
        guard let pool, let copy = SyntheticScene.buffer(from: pool) else { return nil }

        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferLockBaseAddress(copy, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(copy, []) }

        // Row by row per plane. The two buffers come from different pools and need not
        // agree on stride, and copying by total byte count would shear the picture wherever
        // they disagree.
        let planes = max(CVPixelBufferGetPlaneCount(buffer), 1)
        for plane in 0 ..< planes {
            guard
                let from = CVPixelBufferGetBaseAddressOfPlane(buffer, plane),
                let to = CVPixelBufferGetBaseAddressOfPlane(copy, plane)
            else { continue }
            let fromStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let toStride = CVPixelBufferGetBytesPerRowOfPlane(copy, plane)
            let rows = min(
                CVPixelBufferGetHeightOfPlane(buffer, plane),
                CVPixelBufferGetHeightOfPlane(copy, plane)
            )
            let bytes = min(fromStride, toStride)
            for row in 0 ..< rows {
                memcpy(to + row * toStride, from + row * fromStride, bytes)
            }
        }

        return VideoFrame(
            timestamp: FrameTimestamp(seconds: seconds), size: size, surface: .pixelBuffer(copy)
        )
    }
}
