// Video value types: sizes, codecs, and the quality ladder.
//
// A "layer" here is a track, not a field inside a bitstream. That is the whole
// reason render-aware selection is cheap in MoQ and awkward in an SFU: changing
// quality is SUBSCRIBE and UNSUBSCRIBE, the protocol's native operation, rather
// than a proprietary control message the server has to interpret.

import Foundation

/// A size in device pixels.
///
/// Deliberately not `CGSize`: everything downstream of layer selection is an
/// integer pixel count, and a floating-point size invites the mistake this type
/// exists to prevent — comparing layout points against encoder dimensions.
public struct PixelSize: Hashable, Sendable, Codable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = max(0, width)
        self.height = max(0, height)
    }

    /// Total pixels, which is what layer comparisons are actually about — a
    /// 640×360 box and a 360×640 box need the same rung of the ladder.
    public var pixelCount: Int { width * height }

    public var isEmpty: Bool { width == 0 || height == 0 }
}

extension PixelSize: CustomStringConvertible {
    public var description: String { "\(width)×\(height)" }
}

/// Video codecs the Apple hardware encoders support.
///
/// AV1 is absent from the encode side on purpose: no shipping Apple silicon has
/// an AV1 encode block, and software AV1 cannot hold 60fps on a phone. Decode
/// is a different question and belongs to the viewer path.
public enum VideoCodec: String, Hashable, Sendable, Codable {
    case h264
    case hevc
}

/// Which ladder a track is climbing.
///
/// Screenshare and camera want opposite things and applying one policy to both
/// makes text unreadable. Legibility depends on resolution in a way that faces
/// do not, so a screenshare degrades frame rate to almost nothing before it
/// gives up a single pixel.
public enum LadderKind: String, Hashable, Sendable, Codable {
    case camera
    case screenShare
}

/// Identifies one rung, and is the track name suffix it is published under.
public struct LayerID: Hashable, Sendable, Codable, ExpressibleByStringLiteral {
    public let value: String

    public init(stringLiteral value: String) { self.value = value }
    public init(_ value: String) { self.value = value }
}

extension LayerID: CustomStringConvertible {
    public var description: String { value }
}

/// One rung of a quality ladder: a track a subscriber can choose.
public struct VideoLayer: Hashable, Sendable, Identifiable {
    /// Track name suffix, e.g. `video/360p`.
    public let id: LayerID

    /// Encoded dimensions in pixels.
    public let size: PixelSize

    /// Frames per second at the top temporal layer.
    public let frameRate: Double

    /// Nominal bitrate in bits per second. Used for the network-side bound and
    /// for reporting, never as a delivery guarantee.
    public let bitrate: Int

    /// How many temporal sub-layers this spatial layer carries.
    ///
    /// VideoToolbox gives hierarchical P-frames essentially for free under
    /// low-latency rate control, so two spatial layers with three temporal
    /// sub-layers each is six operating points from two encode sessions — which
    /// is about the thermal ceiling on a phone.
    public let temporalLayers: Int

    public init(
        id: LayerID,
        size: PixelSize,
        frameRate: Double,
        bitrate: Int,
        temporalLayers: Int = 1
    ) {
        self.id = id
        self.size = size
        self.frameRate = frameRate
        self.bitrate = bitrate
        self.temporalLayers = max(1, temporalLayers)
    }

    /// The same rung at the aspect ratio of what is being captured.
    ///
    /// The short side is held and the long side follows, rounded to an even
    /// number of pixels: chroma is subsampled by two in both directions, so an
    /// odd dimension is a size half the encoders in the world will refuse and the
    /// rest will quietly round for you.
    public func reshaped(toAspectOf capture: PixelSize) -> VideoLayer {
        guard capture.width > 0, capture.height > 0 else { return self }

        let short = min(size.width, size.height)
        let upright = capture.height > capture.width
        let ratio = upright
            ? Double(capture.height) / Double(capture.width)
            : Double(capture.width) / Double(capture.height)
        let long = max(short, Int((Double(short) * ratio).rounded()) & ~1)
        let resized = upright
            ? PixelSize(width: short, height: long)
            : PixelSize(width: long, height: short)

        guard resized != size else { return self }
        return VideoLayer(
            id: id,
            size: resized,
            frameRate: frameRate,
            bitrate: bitrate,
            temporalLayers: temporalLayers
        )
    }
}

/// The rungs a publisher offers, ascending.
///
/// Ordering is enforced at construction rather than assumed, because selection
/// walks the ladder and an out-of-order rung turns "lowest layer at or above
/// what the box needs" into a silently wrong answer instead of a crash.
public struct LayerLadder: Hashable, Sendable {
    /// Rungs in ascending pixel-count order.
    public let rungs: [VideoLayer]

    /// Which degradation policy applies.
    public let kind: LadderKind

    /// A ladder with no rungs is legal and means audio-only.
    public init(rungs: [VideoLayer], kind: LadderKind = .camera) {
        self.rungs = rungs.sorted { lhs, rhs in
            if lhs.size.pixelCount != rhs.size.pixelCount {
                return lhs.size.pixelCount < rhs.size.pixelCount
            }
            return lhs.bitrate < rhs.bitrate
        }
        self.kind = kind
    }

    public var isEmpty: Bool { rungs.isEmpty }

    /// The cheapest rung, if any.
    public var lowest: VideoLayer? { rungs.first }

    /// The most expensive rung, if any.
    public var highest: VideoLayer? { rungs.last }

    public func layer(id: LayerID) -> VideoLayer? { rungs.first { $0.id == id } }

    /// The same ladder, turned to the shape of what is being captured.
    ///
    /// Every rung keeps its identity — its ``LayerID``, and therefore the track
    /// it publishes on — its short side, its frame rate and its bitrate. Only
    /// the long side moves, to whatever the new aspect asks for. That is the
    /// division a live layout change needs: the shape of the picture is the
    /// source's business and may change while a broadcast runs, whereas the
    /// rungs are a contract with subscribers, who chose one by name and would
    /// have to be told to choose again if the names moved underneath them.
    ///
    /// Short side rather than pixel count, because the short side is what the
    /// rung is named after and what a viewer reads as the quality. Holding the
    /// pixel count instead would make `video/720p` mean 933×525 in landscape and
    /// 720×1280 in portrait, so rotating a phone would appear to change quality.
    public func reshaped(toAspectOf capture: PixelSize) -> LayerLadder {
        guard capture.width > 0, capture.height > 0 else { return self }
        return LayerLadder(
            rungs: rungs.map { $0.reshaped(toAspectOf: capture) },
            kind: kind
        )
    }

    /// Position of `id` in the ladder, for hysteresis comparisons.
    public func index(of id: LayerID) -> Int? { rungs.firstIndex { $0.id == id } }

    /// The lowest rung whose pixel count is at least `pixels`, or the highest
    /// rung when nothing reaches it.
    ///
    /// Snapping upward rather than to the nearest rung is deliberate: matching
    /// a 480×270 box to a 360×640 rung would upscale on the client, and upscaled
    /// video looks worse than the bandwidth saving is worth.
    public func lowestCovering(pixels: Int) -> VideoLayer? {
        rungs.first { $0.size.pixelCount >= pixels } ?? rungs.last
    }

    /// The most expensive rung within `bitrate`, or the cheapest when even that
    /// does not fit — a viewer on a bad link gets the base layer rather than
    /// nothing, and congestion control deals with the shortfall.
    public func highestWithin(bitrate: Int) -> VideoLayer? {
        rungs.last { $0.bitrate <= bitrate } ?? rungs.first
    }

    /// A conventional camera ladder, as a starting point for callers who have
    /// not measured their own content.
    ///
    /// Oriented by `topSize`, and the rung names count the short side either way — a portrait
    /// top size gives 720×1280 as `video/720p`, the same rung turned upright. A landscape
    /// ladder under a portrait camera is not a cosmetic mismatch: the encoder is configured
    /// from the rung, so every frame is squeezed into a shape it was not captured in, and the
    /// only sign of it is that everyone looks wrong.
    public static func defaultCamera(topSize: PixelSize = PixelSize(width: 1920, height: 1080))
        -> LayerLadder
    {
        let upright = topSize.height > topSize.width
        func sized(_ long: Int, _ short: Int) -> PixelSize {
            upright
                ? PixelSize(width: short, height: long)
                : PixelSize(width: long, height: short)
        }

        var rungs: [VideoLayer] = [
            VideoLayer(
                id: "video/180p",
                size: sized(320, 180),
                frameRate: 30,
                bitrate: 200_000,
                temporalLayers: 2
            ),
            VideoLayer(
                id: "video/360p",
                size: sized(640, 360),
                frameRate: 30,
                bitrate: 600_000,
                temporalLayers: 3
            ),
            VideoLayer(
                id: "video/720p",
                size: sized(1280, 720),
                frameRate: 30,
                bitrate: 1_800_000,
                temporalLayers: 3
            ),
        ]
        if topSize.pixelCount >= 1920 * 1080 {
            rungs.append(
                VideoLayer(
                    id: "video/1080p",
                    size: sized(1920, 1080),
                    frameRate: 30,
                    bitrate: 4_000_000,
                    temporalLayers: 3
                )
            )
        }
        if topSize.pixelCount >= 3840 * 2160 {
            rungs.append(
                VideoLayer(
                    id: "video/2160p",
                    size: sized(3840, 2160),
                    frameRate: 30,
                    bitrate: 12_000_000,
                    temporalLayers: 3
                )
            )
        }
        return LayerLadder(rungs: rungs, kind: .camera)
    }
}

/// Which media a request or a mute applies to.
public struct MediaKind: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let audio = MediaKind(rawValue: 1 << 0)
    public static let video = MediaKind(rawValue: 1 << 1)
    public static let screenShare = MediaKind(rawValue: 1 << 2)

    public static let all: MediaKind = [.audio, .video, .screenShare]
}
