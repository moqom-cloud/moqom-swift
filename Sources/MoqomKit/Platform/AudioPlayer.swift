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
            voice = graph.attach(format: playback)
        }

        /// How much audio this player is willing to have waiting for the
        /// speaker.
        ///
        /// The listener's half of mouth-to-ear, and the number lip sync is
        /// aligned to. It has to cover the link's jitter, because past the
        /// jitter buffer's filling phase this queue is the only thing between a
        /// late packet and a hole in the speech, so ``RoomSession`` keeps it in
        /// step with what that buffer has learned about the link.
        ///
        /// Held rather than merely aimed at: audio arrives at the sender's rate
        /// and leaves at the listener's, and the difference — a burst, a stall,
        /// two crystals disagreeing by a hundredth of a percent — accumulates
        /// in front of the speaker with nothing to remove it. Left alone it
        /// only grows, which is a voice that falls further behind its face for
        /// as long as the call lasts.
        public private(set) var aim: Duration = .milliseconds(60)

        public func aim(at delay: Duration) {
            aim = max(.milliseconds(40), min(delay, .milliseconds(400)))
        }

        /// What the aim turned out not to cover, added to it.
        ///
        /// The jitter buffer's estimate is of the link, and the queue also has
        /// to survive this device: a thermal throttle, a route change, the
        /// decoder waiting on an actor. Those show up only as a device asking
        /// for samples that are not there, so that is what this listens to.
        /// Up quickly, because the evidence is a dropout somebody heard, and
        /// down slowly, because the absence of dropouts is not evidence that
        /// the next one will not happen.
        private var pressure: Duration = .zero
        private var starvedBefore = 0
        private var cleanPackets = 0
        private var primed = false

        /// The depth actually being held. See ``aim`` and ``Playback/queued``.
        public var target: Duration { aim + pressure }

        /// Consume a room's audio stream until it ends.
        ///
        /// Every slot is played, including the ones the jitter buffer marked as
        /// a gap: the device needs a buffer per slot, and skipping the gaps
        /// would advance the clock past them. The exception is a queue that has
        /// grown past ``target``, where a slot the publisher marked as silence
        /// is dropped instead of played — the listener cannot hear a silence
        /// that was not played, and dropping them is how the delay comes back
        /// down without anybody hearing it happen. A room is quiet between a
        /// third and a half of the time, which is enough to recover a burst
        /// within seconds.
        /// - Parameter written: called with each packet's capture time as it
        ///   goes to the device, for a caller measuring mouth-to-ear. This
        ///   rather than an audio tap, which is the obvious way and measures
        ///   the wrong thing: a tap runs its own decoder behind its own stream,
        ///   so what it times is the tap. It read four hundred milliseconds on
        ///   a link that turned out to be delivering in seventy.
        public func play(
            _ outputs: AsyncStream<JitterBufferOutput>,
            written: (@Sendable (FrameTimestamp) -> Void)? = nil
        ) async throws(MoqomError) {
            try start()
            for await output in outputs {
                // Quiet slots do not count as speech for this, and the
                // distinction is the whole of it: a ring that empties while
                // nobody is talking has cost the listener nothing, and treating
                // it as a dropout buys insurance against a silence with a
                // permanently deeper queue. The first version did exactly that
                // and settled at a quarter of a second on a link whose jitter
                // never exceeded ten milliseconds.
                if output == .silence {
                    quiet += 1
                    if voiced > 0 { voiced -= 1 }
                } else {
                    quiet = 0
                    voiced = 20
                }
                answer(voice.starved, whileSpeaking: voiced > 0)

                let queued = voice.queued
                // Trimmed above the target rather than at it, because a queue
                // held exactly at target is a queue one late packet away from a
                // hole, and the trimming is what would have put it there.
                //
                // And only in a settled quiet — half a second of it — rather
                // than in the pause between two words. A pause is where the
                // cushion is needed most: speech resumes into a queue that was
                // just emptied, the first syllable arrives to a device with
                // nothing in hand, and the depth controller reads the dropout
                // it caused as proof the link needs a deeper queue. Half a
                // second of quiet is past the end of a sentence.
                if quiet >= 25, queued > target + .milliseconds(20), output == .silence {
                    playback.trimmed += 1
                    continue
                }

                // Speech, and still too deep: the queue is past anything the
                // link's jitter justifies and the excess is pure delay. Losing
                // a packet is audible and losing the argument with the delay is
                // audible for the rest of the call.
                if queued > target + .milliseconds(200) {
                    playback.dropped += 1
                    continue
                }

                let samples = await decoder.decode(output)
                write(samples)
                if case let .packet(packet) = output { written?(packet.timestamp) }
            }
        }

        /// Slots of speech still counted as recent, and quiet slots since the
        /// last of them, both in packets. See ``play(_:written:)``.
        private var voiced = 0
        private var quiet = 0

        /// Fold what the device has been doing into the depth being held.
        private func answer(_ starved: Int, whileSpeaking speaking: Bool) {
            // The device asks for samples from the moment the engine runs, and
            // the first ones arrive whenever the room gets round to sending
            // them. Everything before the first packet is a device waiting to
            // be joined, not a queue that was too shallow.
            guard primed else {
                primed = true
                starvedBefore = starved
                return
            }

            if starved > starvedBefore {
                starvedBefore = starved
                guard speaking else { return }
                cleanPackets = 0
                pressure = min(.milliseconds(120), pressure + .milliseconds(20))
                return
            }

            cleanPackets += 1
            // Fifty packets to the second, so this is five seconds of a device
            // that asked for nothing it did not get. Slower than the rise by a
            // wide margin, and still fast enough that a single bad minute is
            // not paid for until the call ends: the earlier version gave back
            // ten milliseconds every ten seconds, which on two phones meant a
            // queue that reached its ceiling in the first minute and was still
            // there three minutes later, holding the picture back with it.
            guard cleanPackets >= 250, pressure > .zero else { return }
            cleanPackets = 0
            pressure = max(.zero, pressure - .milliseconds(10))
        }

        /// What this player has actually put into the mix.
        ///
        /// The last measurement on the path, and the only one that distinguishes "audio is
        /// arriving" from "audio is audible". Everything upstream counts packets; this counts
        /// amplitude, which is the thing a listener is either hearing or not.
        public struct Playback: Sendable, Hashable {
            /// Buffers handed to the audio device.
            public var buffers = 0

            /// Of those, the ones that were entirely zeros.
            public var silent = 0

            /// Loudest sample scheduled recently, `0` to `1`.
            public var peak: Float = 0

            /// Audio handed to the device and not yet heard. See
            /// ``AudioGraph/Voice/queued``.
            ///
            /// Part of this participant's mouth-to-ear delay and, until it was
            /// measured, the part nobody could see: a jitter buffer reporting a
            /// twenty millisecond target while a fifth of a second sat in front
            /// of the speaker describes a link that sounds nothing like it.
            public var queued: Duration = .zero

            /// Silences dropped to bring ``queued`` back to target. Inaudible.
            public var trimmed = 0

            /// Speech dropped for the same reason, which is not inaudible and
            /// should be rare. A number that climbs means the queue is being
            /// fed faster than the device drains it for longer than a burst,
            /// which is a clock difference rather than a network one.
            public var dropped = 0

            /// Times the device asked for samples and the ring was empty.
            public var starved = 0

            /// The depth being held, which is the figure lip sync should align
            /// the picture to: the momentary ``queued`` swings by a packet or
            /// two between readings and a video buffer chasing it would resize
            /// itself all call.
            public var target: Duration = .zero

            /// Frames the ring refused because it was full.
            public var refused = 0

            /// What the decoder made of the packets. See ``PlatformAudioDecoder/Decoding``.
            public var decoding = PlatformAudioDecoder.Decoding()
        }

        public func reading() async -> Playback {
            var reading = playback
            reading.decoding = await decoder.decoding
            reading.queued = voice.queued
            reading.starved = voice.starved
            reading.target = target
            playback.peak = 0
            return reading
        }

        private var playback = Playback()

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

        private func write(_ samples: [Float]) {
            guard !samples.isEmpty else { return }

            var loudest: Float = 0
            for sample in samples { loudest = max(loudest, abs(sample)) }

            playback.buffers += 1
            if loudest == 0 { playback.silent += 1 }
            playback.peak = max(playback.peak, loudest)

            // Interleaved the whole way now: the ring deinterleaves into the
            // device's buffers while it renders, so nothing on this path has to
            // build an `AVAudioPCMBuffer` per packet.
            let taken = voice.write(samples)
            let offered = samples.count / format.channels
            if taken < offered { playback.refused += offered - taken }
        }
    }
#endif
