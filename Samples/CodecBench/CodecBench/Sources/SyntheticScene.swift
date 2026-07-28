// Deterministic frames, so two codecs are asked the same question.
//
// The camera is the wrong input for a comparison. Its content differs run to
// run, and content decides how many bits a frame costs and therefore how long
// it takes to encode — so a camera-fed A/B measures the room's lighting as much
// as the codec. This renders the same pixels for the same frame index every
// time, on every device.
//
// It is also not a still image, for the opposite reason: a static scene
// compresses to almost nothing after the first keyframe, and an encoder handed
// nothing to do reports a latency no real broadcast will ever see. So the scene
// has continuous global motion, moving edges, and a high-frequency field that
// does not sit still, which is what makes motion estimation and the entropy
// coder work.
//
// Frames are rendered into a buffer the caller supplies, never one allocated
// here. That is not a style preference: VideoToolbox wants buffers from its own
// pool, and one allocated independently can trigger a per-frame pixel transfer
// that never reports itself as an error and would be charged to the encoder.

import CoreVideo
import Foundation
import MoqomCore

enum SceneError: Error, CustomStringConvertible {
    case lockFailed(CVReturn, describing: String)
    case notLinear(plane: Int, describing: String)

    var description: String {
        switch self {
        case let .lockFailed(code, geometry):
            "the pixel buffer would not lock for writing (\(code)) — \(geometry)"
        case let .notLinear(plane, geometry):
            """
            plane \(plane) is not a linear layout the CPU can write, which means a \
            lossless-compressed pixel format — \(geometry)
            """
        }
    }
}

/// Renders a repeatable moving scene into caller-owned pixel buffers.
struct SyntheticScene: BenchSource {
    let size: PixelSize
    let frameRate: Double

    /// How much of the frame is fine detail rather than smooth gradient.
    ///
    /// Detail is what separates a talking head from a stage: MLVC's published
    /// gains collapse on high-frequency content, so a harness that only ever
    /// rendered soft gradients would reproduce its best case and none of ours.
    var detail: Double = 0.5

    /// Fill `buffer` with the scene as of `index`.
    ///
    /// NV12, because that is what the camera produces and what both a hardware
    /// encoder and a Core ML model accept without a conversion pass in between.
    func render(frameIndex index: Int, into buffer: CVPixelBuffer) throws {
        // The lock's result is checked. When it fails the base addresses are not
        // ours to write to, and the pointers CoreVideo hands back in that case are
        // not always null — writing to one faults on the first row.
        let locked = CVPixelBufferLockBaseAddress(buffer, [])
        guard locked == kCVReturnSuccess else {
            throw SceneError.lockFailed(locked, describing: Self.geometry(of: buffer))
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        try Self.checkLinear(buffer)

        let phase = Double(index) / max(1, frameRate)

        // Luma. A diagonal sweep for global motion, a moving bar for a hard
        // edge, and a hashed term for detail the encoder cannot predict away.
        if let luma = Self.plane(0, of: buffer) {
            let width = luma.width
            let barCentre = Double(width) * (0.5 + 0.45 * sin(phase * 1.7))

            for y in luma.rows {
                for x in 0 ..< min(width, luma.stride) {
                    let sweep = 128.0
                        + 90.0 * sin(Double(x) * 0.011 + phase * 3.1)
                        * cos(Double(y) * 0.009 - phase * 2.3)

                    // A moving vertical bar: a real edge for the encoder to
                    // track, which a sum of sinusoids never provides.
                    let bar = abs(Double(x) - barCentre) < 12 ? 70.0 : 0.0

                    // Cheap spatial hash. Deliberately not a PRNG: it must be a
                    // pure function of position and phase so the same frame
                    // index renders identically on every run and device.
                    //
                    // Every term is narrowed to UInt32 before it is multiplied. The
                    // multiplications are meant to overflow, and doing them in Int
                    // first would overflow into a value no UInt32 can hold.
                    let hashed = detail * Double(
                        (UInt32(truncatingIfNeeded: x) &* 2_654_435_761
                            ^ UInt32(truncatingIfNeeded: y) &* 2_246_822_519
                            ^ UInt32(truncatingIfNeeded: index) &* 374_761_393)
                            % 96
                    )

                    luma[x, y] = UInt8(clamping: Int(sweep + bar + hashed))
                }
            }
        }

        // Chroma, interleaved and at half resolution. Slowly drifting, because
        // a constant chroma plane is free to encode and would flatter both
        // codecs equally but unrealistically.
        if let chroma = Self.plane(1, of: buffer) {
            // Two bytes per chroma sample, interleaved, so a sample only fits
            // while both of its bytes are inside the row.
            let samples = min(chroma.width, chroma.stride / 2)

            for y in chroma.rows {
                for x in 0 ..< samples {
                    let u = 128.0 + 40.0 * sin(Double(x) * 0.02 + phase)
                    let v = 128.0 + 40.0 * cos(Double(y) * 0.02 - phase * 0.8)
                    chroma[x * 2, y] = UInt8(clamping: Int(u))
                    chroma[x * 2 + 1, y] = UInt8(clamping: Int(v))
                }
            }
        }
    }

    /// A locked plane, and the number of bytes that are genuinely behind it.
    ///
    /// The capacity is the point of this type. Treating a plane as `stride * height`
    /// bytes assumes the allocation matches the geometry the buffer reports, and a
    /// buffer from a VideoToolbox pool need not honour that — on a write past the end
    /// the process takes EXC_BAD_ACCESS rather than getting an error back. So the
    /// bound is derived from where the next plane starts, or from the buffer's own
    /// reported data size for the last one.
    private struct Plane {
        let base: UnsafeMutablePointer<UInt8>
        let width: Int
        let height: Int
        let stride: Int
        let capacity: Int

        /// The rows that fit inside the capacity.
        var rows: Range<Int> {
            guard stride > 0 else { return 0 ..< 0 }
            return 0 ..< min(height, capacity / stride)
        }

        subscript(x: Int, y: Int) -> UInt8 {
            get { base[y * stride + x] }
            nonmutating set { base[y * stride + x] = newValue }
        }
    }

    private static func plane(_ index: Int, of buffer: CVPixelBuffer) -> Plane? {
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, index),
              let first = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)
        else { return nil }

        let start = Int(bitPattern: base)
        let planeCount = CVPixelBufferGetPlaneCount(buffer)
        let limit: Int
        if index + 1 < planeCount,
           let next = CVPixelBufferGetBaseAddressOfPlane(buffer, index + 1) {
            limit = Int(bitPattern: next)
        } else {
            limit = Int(bitPattern: first) + CVPixelBufferGetDataSize(buffer)
        }

        return Plane(
            base: base.assumingMemoryBound(to: UInt8.self),
            width: CVPixelBufferGetWidthOfPlane(buffer, index),
            height: CVPixelBufferGetHeightOfPlane(buffer, index),
            stride: CVPixelBufferGetBytesPerRowOfPlane(buffer, index),
            capacity: max(0, limit - start)
        )
    }

    /// Refuse a buffer whose pixels are not laid out as rows of bytes.
    ///
    /// The case that matters on an iPhone: `VTCompressionSessionGetPixelBufferPool`
    /// hands out `&8v0`, one of Apple's lossless-compressed formats, where the
    /// reported bytes-per-row is not a row pitch at all — for a 544-wide luma plane
    /// it comes back as 17408, and a linear write walks off the allocation on the
    /// first few rows. There is no supported way to write those pixels from the CPU,
    /// so the answer is to notice and say so rather than to clamp and produce a frame
    /// that is quietly garbage.
    private static func checkLinear(_ buffer: CVPixelBuffer) throws {
        for index in 0 ..< max(1, CVPixelBufferGetPlaneCount(buffer)) {
            guard let plane = plane(index, of: buffer) else { continue }
            guard plane.stride >= plane.width, plane.rows.count == plane.height else {
                throw SceneError.notLinear(plane: index, describing: geometry(of: buffer))
            }
        }
    }

    /// A buffer's real geometry, for an error a reader can act on.
    private static func geometry(of buffer: CVPixelBuffer) -> String {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let fourCC = String(bytes: (0 ..< 4).reversed().map {
            UInt8((format >> (8 * UInt32($0))) & 0xFF)
        }, encoding: .ascii) ?? "\(format)"
        let planes = (0 ..< max(1, CVPixelBufferGetPlaneCount(buffer))).map { index in
            "\(index): \(CVPixelBufferGetWidthOfPlane(buffer, index))"
                + "x\(CVPixelBufferGetHeightOfPlane(buffer, index))"
                + " stride \(CVPixelBufferGetBytesPerRowOfPlane(buffer, index))"
        }
        return "format \(fourCC), "
            + "\(CVPixelBufferGetWidth(buffer))x\(CVPixelBufferGetHeight(buffer)), "
            + "dataSize \(CVPixelBufferGetDataSize(buffer)), "
            + "planes [\(planes.joined(separator: "; "))]"
    }

    /// A pool of buffers the CPU can actually write.
    ///
    /// Both paths use this, including the VideoToolbox one. The note at the top of
    /// this file said to prefer the compression session's own pool, and that advice
    /// is right for a camera or a GPU producer — but not here: on an iPhone that pool
    /// returns lossless-compressed buffers, and a renderer cannot write them at all.
    /// Plain bi-planar buffers carrying IOSurface backing are what the camera hands
    /// VideoToolbox in a real pipeline, so submitting them is the ordinary path rather
    /// than a workaround, and it does not provoke a per-frame pixel transfer.
    static func pool(
        for size: PixelSize,
        format: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    ) -> CVPixelBufferPool? {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: format,
            kCVPixelBufferWidthKey as String: size.width,
            kCVPixelBufferHeightKey as String: size.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        var pool: CVPixelBufferPool?
        guard
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess
        else { return nil }
        return pool
    }

    static func buffer(from pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess else {
            return nil
        }
        return buffer
    }
}
