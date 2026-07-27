// The frame that crosses the boundary between the app's render loop and the
// SDK's encoder.
//
// The constraint that shapes this type is that frames never leave GPU memory.
// A `CVPixelBuffer` here is IOSurface-backed and pool-allocated, and the only
// thing the SDK does with it is hand it to a Metal pass and then to
// VideoToolbox. Nothing in the SDK reads a pixel on the CPU, and a type that
// made that easy to do by accident would be the wrong type.

import Foundation

#if canImport(CoreVideo)
    import CoreVideo
#endif

#if canImport(CoreMedia)
    import CoreMedia
#endif

/// A presentation timestamp on the capture clock.
///
/// Nanoseconds rather than `CMTime` so the value types stay usable in tests and
/// on platforms without CoreMedia; ``cmTime`` bridges where CoreMedia exists.
public struct FrameTimestamp: Hashable, Sendable, Comparable, Codable {
    public let nanoseconds: UInt64

    public init(nanoseconds: UInt64) { self.nanoseconds = nanoseconds }

    public init(seconds: Double) {
        nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
    }

    public var seconds: Double { Double(nanoseconds) / 1_000_000_000 }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.nanoseconds < rhs.nanoseconds }

    #if canImport(CoreMedia)
        /// Nanosecond timescale, which is what the capture clocks report and
        /// avoids a rounding step that would show up as timestamp jitter.
        public var cmTime: CMTime {
            CMTime(value: CMTimeValue(nanoseconds), timescale: 1_000_000_000)
        }
    #endif
}

/// The GPU surface a frame lives on.
///
/// `@unchecked Sendable` because `CVPixelBuffer` is a CoreFoundation type with
/// no Swift concurrency annotation. The discipline that makes it safe is that a
/// buffer is written exactly once, by whoever rendered into it, before being
/// submitted — and never touched again by the submitter. Recycling is the
/// pool's job, and the pool hands out a buffer only when the previous holder
/// has released it. Breaking that rule produces tearing rather than a crash,
/// which is why it is stated here rather than left to be discovered.
public enum FrameSurface: @unchecked Sendable {
    #if canImport(CoreVideo)
        /// An IOSurface-backed, pool-allocated buffer.
        ///
        /// It must come from `VTCompressionSessionGetPixelBufferPool()` where a
        /// compression session exists. A buffer allocated independently may
        /// look identical and still trigger a per-frame `VTPixelTransferSession`
        /// copy that never surfaces as an error.
        case pixelBuffer(CVPixelBuffer)
    #endif

    /// A frame with no backing surface, carrying only its shape.
    ///
    /// The loopback transport and the tests move frames through the whole
    /// publish path without a GPU, which is the only way most of that path is
    /// reachable on a machine with no display.
    case synthetic(byteCount: Int)
}

/// One frame handed to the SDK.
public struct VideoFrame: Sendable {
    /// When the frame was rendered, on the capture clock.
    public let timestamp: FrameTimestamp

    /// Dimensions in device pixels.
    public let size: PixelSize

    /// Where the pixels are.
    public let surface: FrameSurface

    /// Whether the publisher wants this frame to start a new group.
    ///
    /// Resumption after a gap must start a new group — frames were lost, so
    /// continuing the interrupted one hands every viewer an undecodable stream.
    public let forcesKeyFrame: Bool

    public init(
        timestamp: FrameTimestamp,
        size: PixelSize,
        surface: FrameSurface,
        forcesKeyFrame: Bool = false
    ) {
        self.timestamp = timestamp
        self.size = size
        self.surface = surface
        self.forcesKeyFrame = forcesKeyFrame
    }
}
