// The speaker end.
//
// One player per participant, because the relay forwards rather than mixes and
// that is the point: per-viewer mute is an unsubscribe, per-participant volume is
// local, and a single mixed stream would throw both away.
//
// What changed is where the summing happens. Each player used to own an
// `AVAudioEngine`, so a room with three cohosts ran three of them plus the
// microphone's -- and the microphone's echo canceller had a reference containing
// none of the audio it needed to cancel, which is the definition of not working.
// Now every player is a node in the one shared graph. Per-participant volume is
// still per-participant, because it is that node's volume; what the canceller
// gets is the sum, which is what the speaker plays and therefore what comes back
// through the microphone.
//
// Scheduling is buffer-at-a-time rather than through a render callback. A render
// callback is lower latency and cannot allocate, block, or await — and the
// packets arrive from an actor, so reaching them from inside one would need a
// lock-free ring and a decoder that runs on the audio thread. That is the right
// design at scale and the wrong one to write first: the queue here adds one
// buffer of latency and is impossible to get subtly wrong.
//
// > Important: This compiles everywhere AVFAudio does, and nothing in the test
// > suite runs it. It needs an output device.

import Foundation
import MoqomCore

#if canImport(AVFAudio)
    import AVFAudio

    /// Plays one participant's audio.
    public actor AudioPlayer {
        public nonisolated let format: AudioFormat

        private let graph: AudioGraph
        private let voice: AudioGraph.Voice
        private let decoder: PlatformAudioDecoder
        private let playbackFormat: AVAudioFormat
        private let owned: Bool
        private var running = false

        /// This viewer's volume for this participant, `0` to `1`.
        ///
        /// Local and instant. Not the same thing as a mute, which unsubscribes:
        /// this is for a slider, and mute is for not paying for the bytes.
        public var volume: Float {
            get { voice.volume }
            set { voice.volume = newValue }
        }

        /// - Parameter graph: which graph to mix into. The shared one unless
        ///   there is a reason: audio played into a different graph than the one
        ///   capturing is audio the echo canceller cannot subtract, so it comes
        ///   back up the uplink as this listener's own echo.
        public init(
            graph: AudioGraph = .shared,
            format: AudioFormat = .voice,
            codec: MoqomCore.AudioCodec = .opus
        ) throws {
            self.format = format
            self.graph = graph
            owned = graph === AudioGraph.shared
            decoder = try PlatformAudioDecoder(format: format, codec: codec)

            guard
                let playback = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: Double(format.sampleRate),
                    channels: AVAudioChannelCount(format.channels),
                    interleaved: false
                )
            else {
                throw MoqomError.unsupportedAudioCodec(codec)
            }
            playbackFormat = playback
            voice = graph.attach()
        }

        /// Consume a room's audio stream until it ends.
        ///
        /// Every slot is played, including the ones the jitter buffer marked as
        /// a gap: the device needs a buffer per slot, and skipping the gaps
        /// would advance the clock past them.
        public func play(_ outputs: AsyncStream<JitterBufferOutput>) async throws(MoqomError) {
            try start()
            for await output in outputs {
                let samples = await decoder.decode(output)
                schedule(samples)
            }
        }

        public func stop() {
            guard running else { return }
            running = false
            voice.remove()
        }

        private func start() throws(MoqomError) {
            guard !running else { return }
            // The graph may already be running because the microphone started
            // it, which is the normal case in a room where this listener is also
            // publishing. Starting it twice is a no-op by design rather than by
            // luck, because the alternative is ordering rules between capture
            // and playback that a caller would have to know about.
            if owned { try graph.start() }
            voice.play()
            running = true
        }

        private func schedule(_ samples: [Float]) {
            let frames = AVAudioFrameCount(samples.count / format.channels)
            guard
                frames > 0,
                let buffer = AVAudioPCMBuffer(
                    pcmFormat: playbackFormat,
                    frameCapacity: frames
                ),
                let channels = buffer.floatChannelData
            else { return }

            buffer.frameLength = frames

            // Interleaved in, deinterleaved out. `AVAudioPCMBuffer`'s
            // non-interleaved layout is one pointer per channel, which is what
            // the mixer wants; converting here rather than asking the decoder
            // for it keeps the decoder's output in the one layout every other
            // part of the SDK uses.
            for frame in 0 ..< Int(frames) {
                for channel in 0 ..< format.channels {
                    channels[channel][frame] = samples[frame * format.channels + channel]
                }
            }

            voice.schedule(buffer)
        }
    }
#endif
