// What an encoder is, independent of which one you have.
//
// The protocol exists because the publish path has to be testable without a
// GPU. Everything between a compressed frame and a MOQT object — group
// boundaries, object numbering, priority per rung, the properties that carry
// presentation time — is SDK logic that a hardware dependency should not hide.
// Splitting the encoder out means the pipeline runs in CI against a synthetic
// bitstream and runs on a device against VideoToolbox, over the same code.
//
// The unit is a frame rather than a byte stream. A MOQT object is a frame, so
// an encoder that handed back an undelimited stream would force the packetiser
// to re-parse for boundaries the encoder already knew.

import Foundation
import MoqomCore

#if canImport(VideoToolbox)
    import VideoToolbox
#endif

/// One encoded frame on its way to a track.
public struct EncodedFrame: Sendable {
    public let timestamp: FrameTimestamp
    public let isKeyFrame: Bool

    /// `0` for the base layer, `1` for frames nothing depends on.
    ///
    /// Derived from `kCMSampleAttachmentKey_IsDependedOnByOthers` rather
    /// than counted by the SDK, because the encoder is the only thing that
    /// knows the reference structure it actually produced — it may ignore a
    /// requested base layer fraction on hardware that cannot do it.
    public let temporalLayer: Int

    /// Length-prefixed NAL units, as VideoToolbox emits them.
    public let data: Data

    /// Parameter sets, present on keyframes.
    ///
    /// Carried out of band on the catalog rather than inline in every
    /// keyframe: a viewer joining mid-stream needs them before the first
    /// object, and a subscriber that starts at an arbitrary group would
    /// otherwise have to wait for the next IDR to learn how to configure a
    /// decoder.
    public let parameterSets: [Data]

    public init(
        timestamp: FrameTimestamp,
        isKeyFrame: Bool,
        temporalLayer: Int,
        data: Data,
        parameterSets: [Data]
    ) {
        self.timestamp = timestamp
        self.isKeyFrame = isKeyFrame
        self.temporalLayer = temporalLayer
        self.data = data
        self.parameterSets = parameterSets
    }
}

/// How to encode one rung.
public struct EncoderConfiguration: Sendable {
    public var layer: VideoLayer
    public var codec: VideoCodec

    /// Split the rung into two temporal layers.
    ///
    /// Costs a little efficiency and buys the relay something to shed that
    /// degrades gracefully.
    public var usesTemporalLayers: Bool

    /// How long a joiner may wait for a decodable point.
    public var keyFrameInterval: Duration

    /// Let the encoder trade speed for power.
    ///
    /// On by default because a phone that publishes for an hour is thermally limited long
    /// before it is compute limited, and an encoder that has throttled the camera is a worse
    /// picture than one that took a few extra milliseconds per frame. Turn it off where the
    /// few milliseconds are the product: measured on a 720p60 camera the difference was
    /// around 3ms per frame, which is a fifth of the frame interval and a twelfth of a
    /// glass-to-glass budget that is trying to stay under two frames.
    public var prefersPowerEfficiency: Bool

    public init(
        layer: VideoLayer,
        codec: VideoCodec = .hevc,
        usesTemporalLayers: Bool = true,
        keyFrameInterval: Duration = .seconds(2),
        prefersPowerEfficiency: Bool = true
    ) {
        self.layer = layer
        self.codec = codec
        self.usesTemporalLayers = usesTemporalLayers
        self.keyFrameInterval = keyFrameInterval
        self.prefersPowerEfficiency = prefersPowerEfficiency
    }
}

/// Something that turns frames into a bitstream.
///
/// Submission and output are separate because every real encoder is
/// pipelined: ``encode(_:forcingKeyFrame:)`` returns when the frame has been
/// accepted, not when it has been compressed. A synchronous API would either
/// lie about that or stall the caller for the depth of the hardware pipeline.
public protocol FrameEncoder: Sendable {
    var configuration: EncoderConfiguration { get }

    /// Submit one frame. Returns on acceptance, not completion.
    func encode(_ frame: VideoFrame, forcingKeyFrame: Bool) async throws

    /// Compressed output, in presentation order.
    func encodedFrames() -> AsyncStream<EncodedFrame>

    /// What became of the frames handed over, for the ones that produced nothing.
    ///
    /// Defaulted, so an integrator's encoder does not have to answer. What it costs when
    /// nobody answers is what this was added for: fifty frames submitted, one published, and
    /// no counter anywhere between them with an opinion about the other forty-nine.
    var accounting: EncoderAccounting { get }

    /// Flush and release. Idempotent.
    func close() async
}

/// Where frames went inside an encoder.
public struct EncoderAccounting: Hashable, Sendable {
    /// Handed to the consumer.
    public var emitted = 0

    /// The encoder produced no picture for the frame.
    public var declined = 0

    /// A picture came back that could not be read.
    public var unreadable = 0

    /// A picture was produced and the consumer was too far behind to take it.
    public var overrun = 0

    public init() {}

    public var isQuiet: Bool { declined == 0 && unreadable == 0 && overrun == 0 }
}

public extension FrameEncoder {
    var accounting: EncoderAccounting { EncoderAccounting() }
}

/// How the SDK obtains an encoder for one rung.
public typealias EncoderFactory = @Sendable (EncoderConfiguration) async throws -> any FrameEncoder

/// The hardware encoder where there is one, and a synthetic bitstream where
/// there is not.
///
/// The fallback is not silent about what it is: ``SyntheticEncoder`` produces
/// undecodable bytes, and a caller who ends up here on a platform they expected
/// hardware on will see that in the first frame they try to render.
public let defaultEncoderFactory: EncoderFactory = { configuration in
    #if canImport(VideoToolbox)
        try VideoEncoder(configuration: configuration)
    #else
        SyntheticEncoder(configuration: configuration)
    #endif
}

/// An encoder that fabricates a bitstream.
///
/// Not a mock: it produces real ``EncodedFrame`` values with plausible sizes,
/// keyframe cadence, and temporal layering, so the packetiser, the ladder, the
/// group logic, and the transport all do their actual work. What it does not
/// produce is a decodable picture.
///
/// This is what the loopback path uses, and it is also the only encoder
/// available on a platform without VideoToolbox.
public actor SyntheticEncoder: FrameEncoder {
    public nonisolated let configuration: EncoderConfiguration

    private let stream: AsyncStream<EncodedFrame>
    private let continuation: AsyncStream<EncodedFrame>.Continuation
    private var framesSinceKeyFrame = 0
    private var counter: UInt64 = 0
    private var closed = false

    public init(configuration: EncoderConfiguration) {
        self.configuration = configuration
        (stream, continuation) = AsyncStream.makeStream(
            of: EncodedFrame.self,
            bufferingPolicy: .bufferingNewest(8)
        )
    }

    deinit { continuation.finish() }

    public nonisolated func encodedFrames() -> AsyncStream<EncodedFrame> { stream }

    public func encode(_ frame: VideoFrame, forcingKeyFrame: Bool = false) async throws {
        guard !closed else {
            throw MoqomError.invalidState(expected: "encoding", actual: "closed")
        }

        let interval = keyFrameIntervalInFrames
        let isKeyFrame = forcingKeyFrame
            || frame.forcesKeyFrame
            || framesSinceKeyFrame == 0
            || framesSinceKeyFrame >= interval
        framesSinceKeyFrame = isKeyFrame ? 1 : framesSinceKeyFrame + 1

        // Alternate frames sit on the upper temporal layer, matching what a
        // request for two layers actually produces: every other frame is
        // depended on by nothing and is therefore droppable.
        let temporalLayer = configuration.usesTemporalLayers && !isKeyFrame
            ? Int(counter % 2)
            : 0

        // A keyframe being roughly an order of magnitude larger than a delta
        // frame is the ratio that makes a pacing or congestion bug visible.
        let size = isKeyFrame ? 12_000 : 1_200
        counter += 1

        continuation.yield(
            EncodedFrame(
                timestamp: frame.timestamp,
                isKeyFrame: isKeyFrame,
                temporalLayer: temporalLayer,
                data: Self.pattern(byte: UInt8(counter & 0xFF), count: size),
                parameterSets: isKeyFrame ? [Data([0x00, 0x01, 0x02, 0x03])] : []
            )
        )
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        continuation.finish()
    }

    private var keyFrameIntervalInFrames: Int {
        let seconds = Double(configuration.keyFrameInterval.components.seconds)
            + Double(configuration.keyFrameInterval.components.attoseconds) / 1e18
        let rate = max(1.0, configuration.layer.frameRate)
        return max(1, Int((seconds * rate).rounded()))
    }

    /// Length-prefixed like a real AVCC/HVCC unit, so anything downstream that
    /// walks NAL units sees a well-formed shape rather than a blob.
    private static func pattern(byte: UInt8, count: Int) -> Data {
        var data = Data(capacity: count + 4)
        withUnsafeBytes(of: UInt32(count).bigEndian) { data.append(contentsOf: $0) }
        data.append(Data(repeating: byte, count: count))
        return data
    }
}
