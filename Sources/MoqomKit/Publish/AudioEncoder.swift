// Audio capture and compression, in the same shape as the video path.
//
// Same reasoning as ``FrameEncoder``: the pipeline has to be testable without a
// microphone, so the encoder is a protocol and the platform implementation is
// one conformer. The synthetic one is not a stub — it produces packets at the
// right cadence with plausible sizes and honest silence flags, which is enough
// to exercise pacing, the jitter buffer, and the transport.

import Foundation
import MoqomCore

/// Where audio comes from.
public protocol AudioSource: Sendable {
    var format: AudioFormat { get }

    /// The samples. One consumer, like ``FrameSource``.
    func frames() -> AsyncStream<AudioFrame>

    func stop()

    /// Let go of the microphone without ending the stream. See
    /// ``FrameSource/suspend()``, which this is the audio half of.
    func suspend()

    /// Take the microphone back.
    ///
    /// > Important: No default implementation, for the reason
    /// > ``FrameSource/resume()`` gives — a wrapper that inherits an empty one
    /// > leaves the microphone open under a mute and says it closed it.
    func resume()
}

/// How to compress one audio track.
public struct AudioEncoderConfiguration: Sendable {
    public var format: AudioFormat
    public var codec: AudioCodec

    /// Target bitrate.
    ///
    /// 24kbps is transparent for speech in Opus and leaves the whole audio
    /// track cheaper than a rounding error on any video rung — which is the
    /// point: there is never a reason to shed audio for bandwidth.
    public var bitrate: Int

    /// Send nothing while nobody is speaking.
    ///
    /// Off by default. It saves bandwidth that was not the constraint and it
    /// makes a gap and a pause indistinguishable at the receiver unless the
    /// silence is signalled explicitly, which is a bug that only appears on
    /// bad links.
    public var usesDiscontinuousTransmission: Bool

    /// How speech is told from a pause.
    ///
    /// This decides what goes in the silence property of every published
    /// object, so it is the encoder's business rather than the application's.
    /// The transmission preset is the right one here: it commits on the frame
    /// speech arrives, because a detector that waits to be sure marks the start
    /// of the first word as a pause and a receiver told a word was a pause has
    /// no way to recover it.
    public var voiceActivity: VoiceActivity.Configuration

    public init(
        format: AudioFormat = .voice,
        codec: AudioCodec = .opus,
        bitrate: Int = 24000,
        usesDiscontinuousTransmission: Bool = false,
        voiceActivity: VoiceActivity.Configuration = .transmission
    ) {
        self.format = format
        self.codec = codec
        self.bitrate = bitrate
        self.usesDiscontinuousTransmission = usesDiscontinuousTransmission
        self.voiceActivity = voiceActivity
    }
}

/// Something that turns samples into packets.
public protocol AudioEncoder: Sendable {
    var configuration: AudioEncoderConfiguration { get }

    func encode(_ frame: AudioFrame) async throws

    func encodedFrames() -> AsyncStream<EncodedAudioFrame>

    func close() async
}

/// How the SDK obtains an audio encoder.
public typealias AudioEncoderFactory =
    @Sendable (AudioEncoderConfiguration) async throws -> any AudioEncoder

/// The platform encoder where there is one, synthetic where there is not.
public let defaultAudioEncoderFactory: AudioEncoderFactory = { configuration in
    #if canImport(AudioToolbox)
        try PlatformAudioEncoder(configuration: configuration)
    #else
        SyntheticAudioEncoder(configuration: configuration)
    #endif
}

/// An encoder that fabricates packets at the right cadence.
///
/// Sizes track the input level, so a run of quiet samples produces small
/// packets and a loud passage produces large ones. That is not cosmetic: it is
/// what makes a pacing or bandwidth-estimation bug visible in a test, which a
/// constant-size stub would hide.
public actor SyntheticAudioEncoder: AudioEncoder {
    public nonisolated let configuration: AudioEncoderConfiguration

    private let stream: AsyncStream<EncodedAudioFrame>
    private let continuation: AsyncStream<EncodedAudioFrame>.Continuation
    private var closed = false
    private var voice: VoiceActivity

    public init(configuration: AudioEncoderConfiguration = AudioEncoderConfiguration()) {
        self.configuration = configuration
        voice = VoiceActivity(configuration: configuration.voiceActivity)
        (stream, continuation) = AsyncStream.makeStream(
            of: EncodedAudioFrame.self,
            bufferingPolicy: .bufferingNewest(16)
        )
    }

    deinit { continuation.finish() }

    public nonisolated func encodedFrames() -> AsyncStream<EncodedAudioFrame> { stream }

    public func encode(_ frame: AudioFrame) async throws {
        guard !closed else {
            throw MoqomError.invalidState(expected: "encoding", actual: "closed")
        }

        let isSilence = !voice.accept(frame)

        let seconds = Double(configuration.format.frameDuration.components.seconds)
            + Double(configuration.format.frameDuration.components.attoseconds) / 1e18
        let full = max(1, Int(Double(configuration.bitrate) * seconds / 8))
        let count = isSilence ? 3 : max(3, Int(Double(full) * Double(min(1, frame.peak + 0.25))))

        continuation.yield(
            EncodedAudioFrame(
                timestamp: frame.timestamp,
                duration: configuration.format.frameDuration,
                data: Data(repeating: isSilence ? 0xF8 : 0x78, count: count),
                isSilence: isSilence
            )
        )
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        continuation.finish()
    }
}

/// A source someone else pushes samples into.
///
/// The audio counterpart of ``FrameRelay``, and it exists for the same reason:
/// a real capture callback owns its own thread and cannot be made to yield to
/// an `AsyncStream` iterator.
///
/// It drops the *newest* frame when full, which is the opposite of the video
/// policy and deliberately so. Video wants the freshest picture; audio wants an
/// unbroken run of samples, because a hole in the middle of a word is more
/// audible than the whole word arriving slightly late.
public final class AudioRelay: AudioSource {
    public let format: AudioFormat

    private let stream: AsyncStream<AudioFrame>
    private let continuation: AsyncStream<AudioFrame>.Continuation

    public init(format: AudioFormat = .voice, depth: Int = 8) {
        self.format = format
        (stream, continuation) = AsyncStream.makeStream(
            of: AudioFrame.self,
            bufferingPolicy: .bufferingOldest(depth)
        )
    }

    deinit { continuation.finish() }

    /// Non-blocking, callable from a capture callback.
    public func submit(_ frame: AudioFrame) {
        continuation.yield(frame)
    }

    public func frames() -> AsyncStream<AudioFrame> { stream }

    public func stop() { continuation.finish() }

    /// Nothing to release: whoever is submitting owns the input, if there is
    /// one. The frames that keep arriving are dropped by the publication.
    public func suspend() {}
    public func resume() {}
}
