// Turning received media back into something a program can look at.
//
// The SDK has not needed this until now. Rendering goes through
// `AVSampleBufferDisplayLayer`, which decodes internally and hands back nothing,
// and playback goes through `PlatformAudioDecoder` straight into the audio
// graph. Both are the right choice for their job and both are dead ends for
// anybody who wants the pixels or the samples.
//
// So these are the seams a tap decodes through, and they are protocols for the
// same reason ``FrameEncoder`` is: the platform's answer is the right default
// and must not be the only one. A software AV1, a decoder that writes into a
// texture the application owns, a stub that lets a test drive the whole path on
// a machine with no video hardware — all of those are somebody replacing this,
// not somebody forking the SDK.
//
// The asymmetry with encoding is worth naming. An encoder is pipelined: frames
// go in, frames come out later, and the type is a stream in and a stream out.
// A decoder here is not, because a tap has no reordering to do — the
// depacketiser has already put frames in decode order, and a tap consumer that
// received them out of presentation order would have no way to fix it. So this
// is request and response, and an implementation that pipelines internally is
// expected to hide that.

import Foundation
import MoqomCore

/// Turns compressed frames back into pictures.
public protocol VideoDecoding: Sendable {
    /// Decode one frame.
    ///
    /// Returns `nil` rather than throwing when the frame cannot be decoded
    /// *yet* — before parameter sets have arrived, most commonly, which is an
    /// ordinary state at the start of a subscription and not a failure. Throws
    /// when the decoder itself is broken.
    func decode(_ frame: EncodedFrame) async throws(MoqomError) -> VideoFrame?

    /// Discard reference state.
    ///
    /// Called when objects were lost. A decoder fed across a hole produces
    /// pictures built from references that never arrived, and those artefacts
    /// persist until the next keyframe — which for a tap means handing a
    /// classifier a smeared frame and getting a confident wrong answer.
    func flush() async

    /// Release the session. Idempotent.
    func close() async
}

/// Where a decoder comes from.
public typealias VideoDecoderFactory = @Sendable (VideoCodec) throws -> any VideoDecoding

/// Turns jitter buffer output back into samples.
///
/// Takes ``JitterBufferOutput`` rather than a packet because the slots where
/// nothing arrived are part of the signal: a transcriber that saw only the
/// packets that made it would silently splice across a gap and produce a
/// sentence nobody said.
public protocol AudioDecoding: Sendable {
    /// The format the samples come back in.
    var format: AudioFormat { get }

    /// Decode one slot. Always yields a slot's worth of samples.
    func decode(_ output: JitterBufferOutput) async -> [Float]
}

/// Where an audio decoder comes from.
public typealias AudioDecoderFactory =
    @Sendable (AudioFormat, MoqomCore.AudioCodec) throws -> any AudioDecoding

/// A decoder that fabricates a picture.
///
/// The counterpart to ``SyntheticEncoder``, and it stops short of where that one
/// goes. The synthetic encoder is the fallback on a platform without
/// VideoToolbox, because undecodable bytes still exercise the packetiser, the
/// ladder, and the transport, and the first person to render one finds out
/// immediately.
///
/// This is not a fallback anywhere. A tap exists so that something can make a
/// decision about what is in a picture, and handing that something a blank frame
/// produces a confident verdict about content that was never there — which does
/// not announce itself the way a black video does. So a platform with no decoder
/// gets an error, and this type is reached only by a caller who asked for it by
/// name.
public actor SyntheticVideoDecoder: VideoDecoding {
    public nonisolated let size: PixelSize

    /// How many frames were decoded, for a test that cares whether a cadence
    /// actually saved the work it claims to.
    public private(set) var decoded = 0

    public private(set) var flushes = 0
    public private(set) var isClosed = false

    public init(size: PixelSize = PixelSize(width: 640, height: 360)) {
        self.size = size
    }

    public func decode(_ frame: EncodedFrame) async throws(MoqomError) -> VideoFrame? {
        guard !isClosed else {
            throw MoqomError.invalidState(expected: "decoding", actual: "closed")
        }
        decoded += 1
        return VideoFrame(
            timestamp: frame.timestamp,
            size: size,
            surface: .synthetic(byteCount: frame.data.count)
        )
    }

    public func flush() async {
        flushes += 1
    }

    public func close() async {
        isClosed = true
    }
}

/// An audio decoder that fabricates samples.
///
/// Exists for the same reason as ``SyntheticVideoDecoder``: somebody writing a
/// transcription consumer needs to drive it with audio whose content they chose,
/// and reaching for a real codec to do that makes the test about the codec.
///
/// Reproduces the loss cases faithfully, because those are the ones a consumer
/// gets wrong — a slot marked concealed comes back attenuated rather than
/// identical, and a silent one comes back as exact zeroes.
public actor SyntheticAudioDecoder: AudioDecoding {
    public nonisolated let format: AudioFormat

    public private(set) var decoded = 0

    /// What a decoded packet sounds like. Constant, so a consumer can assert on
    /// it without knowing anything about the encoder.
    private let level: Float

    public init(format: AudioFormat = .voice, level: Float = 0.5) {
        self.format = format
        self.level = level
    }

    public func decode(_ output: JitterBufferOutput) async -> [Float] {
        decoded += 1
        let count = format.samplesPerFrame * format.channels
        return switch output {
        case .packet: [Float](repeating: level, count: count)
        case .gap: [Float](repeating: level / 4, count: count)
        case .silence, .buffering: [Float](repeating: 0, count: count)
        }
    }
}

#if canImport(AVFoundation) && canImport(VideoToolbox)
    /// The platform's hardware decoder.
    public let defaultVideoDecoderFactory: VideoDecoderFactory = { codec in
        try PlatformVideoDecoder(codec: codec)
    }
#else
    /// No decoder off Apple platforms.
    ///
    /// Throws rather than returning a stub that silently produces nothing: a
    /// tap that yields no frames and reports no error is indistinguishable from
    /// a participant who is not publishing, and that is a bad afternoon.
    public let defaultVideoDecoderFactory: VideoDecoderFactory = { codec in
        throw MoqomError.unsupportedCodec(codec)
    }
#endif

#if canImport(AudioToolbox)
    public let defaultAudioDecoderFactory: AudioDecoderFactory = { format, codec in
        try PlatformAudioDecoder(format: format, codec: codec)
    }

    extension PlatformAudioDecoder: AudioDecoding {}
#else
    public let defaultAudioDecoderFactory: AudioDecoderFactory = { _, codec in
        throw MoqomError.unsupportedAudioCodec(codec)
    }
#endif
