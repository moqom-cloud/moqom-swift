// Audio, as far as the core needs to know about it.
//
// Audio is not small video and the differences drive the whole pipeline. A
// dropped video frame costs one picture; a dropped audio packet is audible, and
// two in a row is a word. Audio is also the track that carries conversation, so
// its deadline is tighter than video's even though its bitrate is a rounding
// error next to it.
//
// The practical consequences, all of which show up elsewhere in the SDK:
//
//   - Audio publishes at a lower numeric priority than any video rung, so the
//     relay sheds pictures before it sheds speech.
//   - Audio goes on datagrams where it fits, because a lost packet is better
//     than a retransmitted one that arrives after its playout time.
//   - Audio has a jitter buffer and video does not. Video can render a frame
//     the moment it arrives; audio has to arrive on a clock or it clicks.

import Foundation

/// How audio is compressed on the wire.
public enum AudioCodec: String, Hashable, Sendable, CaseIterable {
    /// The default, and what any interoperating stack will expect.
    ///
    /// Chosen over AAC for latency rather than quality: Opus runs at a 20ms
    /// frame with a 6.5ms lookahead, where AAC-LC's 1024-sample frame plus
    /// filterbank delay is closer to 60ms before a single packet is sent.
    case opus

    /// Uncompressed 16-bit PCM.
    ///
    /// Useful on a loopback or a LAN and never over the internet: one channel
    /// at 48kHz is 768kbps, roughly twelve times what Opus needs to sound
    /// better than a phone call.
    case pcm
}

/// The shape of a stream of samples.
public struct AudioFormat: Hashable, Sendable {
    public let sampleRate: Int
    public let channels: Int

    /// How much audio is in one packet.
    ///
    /// 20ms is the conferencing default and the one to keep unless there is a
    /// specific reason: shorter packets multiply per-packet overhead, which for
    /// audio is a large fraction of the payload, and longer ones add their own
    /// duration to the end-to-end delay.
    public let frameDuration: Duration

    public init(
        sampleRate: Int = 48000,
        channels: Int = 1,
        frameDuration: Duration = .milliseconds(20)
    ) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.frameDuration = frameDuration
    }

    /// Samples per channel in one packet.
    public var samplesPerFrame: Int {
        let seconds = Double(frameDuration.components.seconds)
            + Double(frameDuration.components.attoseconds) / 1e18
        return Int((Double(sampleRate) * seconds).rounded())
    }

    /// Mono 48kHz at 20ms. What a microphone should be asked for.
    public static let voice = AudioFormat()
}

/// A block of captured samples.
///
/// Interleaved 32-bit float, which is what every Apple capture path produces
/// natively and what Opus takes without conversion. Converting to and from
/// 16-bit integers in between would cost two passes over every sample to lose
/// precision.
public struct AudioFrame: Sendable {
    public let timestamp: FrameTimestamp
    public let format: AudioFormat

    /// Interleaved samples, `channels * samplesPerFrame` of them.
    public let samples: [Float]

    public init(timestamp: FrameTimestamp, format: AudioFormat, samples: [Float]) {
        self.timestamp = timestamp
        self.format = format
        self.samples = samples
    }

    /// Peak absolute amplitude, for a level meter or a speaking indicator.
    public var peak: Float {
        samples.reduce(0) { Swift.max($0, Swift.abs($1)) }
    }
}

/// One compressed audio packet.
public struct EncodedAudioFrame: Hashable, Sendable {
    public let timestamp: FrameTimestamp
    public let duration: Duration
    public let data: Data

    /// Whether the encoder believes this packet is silence.
    ///
    /// Not a hint to drop it. A receiver still needs to know the packet
    /// existed, because a gap in sequence numbers and a deliberate silence are
    /// different things and only one of them should trigger concealment.
    public let isSilence: Bool

    public init(
        timestamp: FrameTimestamp,
        duration: Duration,
        data: Data,
        isSilence: Bool = false
    ) {
        self.timestamp = timestamp
        self.duration = duration
        self.data = data
        self.isSilence = isSilence
    }
}
