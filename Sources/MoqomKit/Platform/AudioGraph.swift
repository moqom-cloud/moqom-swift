// One audio graph per process, because an echo canceller has to know what the
// speaker is playing.
//
// This is the piece that makes speakerphone usable, and the reason it is a
// separate type rather than a detail of the microphone is that echo
// cancellation is not a property of capture. It is a relationship between
// capture and playback. The canceller works by subtracting a reference -- what
// went out of the speaker -- from what came into the microphone, and it can
// only subtract audio it was given. Audio rendered through some other engine,
// some other audio unit, or some other framework is not in the reference, so it
// comes back through the microphone, gets published, and every cohost hears
// themselves half a second late.
//
// The SDK used to be arranged the wrong way round. `MicrophoneSource` owned an
// `AVAudioEngine` with voice processing enabled, and every `AudioPlayer` owned
// *another* one. So a room with three cohosts ran four engines: one cancelling
// against a reference containing nothing, and three rendering the audio it
// needed to cancel. Voice processing was switched on and could not work.
//
// So: one engine, `AVAudioPlayerNode` per participant into its mixer, and the
// microphone tapped off the same engine's input. Everything the per-participant
// design cares about survives that, which is worth being explicit about because
// the shape looks like a mixer and mixing is what we refuse to do:
//
//   - Per-participant volume is a node's volume, not a scalar applied to a mix.
//   - Local mute stays an unsubscribe, so muted bytes still never leave the
//     relay. Removing a node from the graph is not the mute mechanism.
//   - The relay still forwards rather than mixes. This is a client-side sum
//     into the one output the device actually has, which the operating system
//     would perform anyway, one layer lower, where we could not see it.
//
// > Important: nothing here runs in the test suite. It needs a device with a
// > microphone, an output route, and a user who granted permission. What *is*
// > tested is ``AudioGraph/Purpose`` and its session mapping, because choosing
// > the wrong category is the failure that looks like broken hardware.

import Foundation
import MoqomCore

#if canImport(AVFAudio)
    import AVFAudio

    /// The single engine that capture and playback share.
    public final class AudioGraph: @unchecked Sendable {
        /// The graph every default path uses.
        ///
        /// A shared instance rather than one per caller, and deliberately so: a
        /// device has one microphone and one output route, two engines with
        /// voice processing enabled fight over them, and the symptom of getting
        /// this wrong is echo -- which sounds like a bug in somebody else's
        /// code. Making the correct arrangement the default is worth more than
        /// the purity of having no shared state, because the incorrect
        /// arrangement is silent.
        public static let shared = AudioGraph()

        /// What the graph is for, which decides how the system is configured.
        public enum Purpose: Sendable, Hashable, CaseIterable {
            /// Conversation, no camera.
            case voiceCall

            /// Conversation with video, which is the speakerphone case.
            ///
            /// Distinct from ``voiceCall`` because the system tunes for it:
            /// input is preferred from the microphone facing the same way as
            /// the camera in use, and output defaults to the speaker rather
            /// than the receiver, since somebody holding a phone at arm's
            /// length to be seen is not holding it against their ear.
            case videoCall

            /// Music, or anything else where the input is not a voice.
            ///
            /// Voice processing off. Not a preference -- the canceller is one
            /// part of a chain that also compresses dynamic range and
            /// suppresses anything unlike speech, and a cymbal is unlike
            /// speech. Leaving it on is how a music broadcast ends up sounding
            /// like a phone call.
            case music

            /// Receiving only, publishing nothing. The audience of an audio room.
            ///
            /// The distinction is the microphone. Every other case records, and a
            /// listener that took a recording session would be wrong four ways
            /// at once: the orange indicator implies the app is listening to a
            /// room it is only listening *to*, `playAndRecord` will not play
            /// while the app is backgrounded so the room dies when the screen
            /// locks, the input hardware stays powered for nothing, and taking
            /// the input device stops other apps from using it.
            ///
            /// A listener that becomes a speaker calls ``reconfigure(_:)``, which
            /// restarts the engine, because the category is fixed at the point it
            /// starts. That is a real audible gap of a few tens of milliseconds
            /// at the moment somebody is promoted -- and the promotion already
            /// costs a namespace announcement and a publish, so it is not the
            /// slow part.
            ///
            /// > Important: the room continuing while the screen is off also
            /// > needs the `audio` background mode declared by the *application*.
            /// > This case is necessary for it and not sufficient, and there is
            /// > no API for an SDK to grant itself a capability.
            case listening

            /// Whether the graph opens the input device at all.
            public var capturesInput: Bool { self != .listening }

            /// Whether the system's voice processing should be engaged.
            ///
            /// Nothing to cancel without capture, and asking for it anyway on a
            /// playback session takes the input device -- which is the thing this
            /// case exists to avoid.
            public var wantsVoiceProcessing: Bool { self != .music && capturesInput }
        }

        public struct Configuration: Sendable, Hashable {
            public var purpose: Purpose

            /// What the microphone should deliver.
            public var format: AudioFormat

            public init(purpose: Purpose = .videoCall, format: AudioFormat = .voice) {
                self.purpose = purpose
                self.format = format
            }
        }

        /// One participant's place in the mix.
        ///
        /// A handle rather than a raw node, so ``AudioPlayer`` cannot reach into
        /// the engine and so detaching is something the graph observes.
        public final class Voice: @unchecked Sendable {
            let node = AVAudioPlayerNode()
            private weak var graph: AudioGraph?

            /// This listener's volume for this participant, `0` to `1`.
            public var volume: Float {
                get { node.volume }
                set { node.volume = max(0, min(1, newValue)) }
            }

            init(graph: AudioGraph) { self.graph = graph }

            /// Hand the device more samples.
            public func schedule(_ buffer: AVAudioPCMBuffer) {
                node.scheduleBuffer(buffer, completionHandler: nil)
            }

            public func play() { node.play() }

            /// Take this participant out of the mix.
            public func remove() {
                graph?.detach(self)
                graph = nil
            }
        }

        public private(set) var configuration: Configuration

        /// Whether voice processing is actually engaged.
        ///
        /// Not the same as having asked for it. Some devices and some route
        /// combinations refuse, and a caller that assumed otherwise would
        /// publish echo while believing it had cancellation.
        public private(set) var isCancellingEcho = false

        private let engine = AVAudioEngine()
        private let lock = NSLock()
        private var voices: [Voice] = []
        private var capture: Capture?
        private var running = false
        private var observers: [any NSObjectProtocol] = []

        public init(configuration: Configuration = Configuration()) {
            self.configuration = configuration
            // Touching the mixer builds the connection to the output node,
            // which has to exist before the engine starts: voice processing
            // needs a live render path to take its reference from, and an
            // engine with nothing connected to its output does not have one.
            _ = engine.mainMixerNode
            observe()
        }

        deinit {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        /// Change what the graph is for.
        ///
        /// Restarts if running, because the session category and voice
        /// processing are both fixed at the point the engine starts.
        public func reconfigure(_ configuration: Configuration) throws(MoqomError) {
            lock.lock()
            let wasRunning = running
            self.configuration = configuration
            lock.unlock()

            if wasRunning {
                stop()
                try start()
            }
        }

        /// Whether the engine is actually open, which is not the same as having asked for it.
        ///
        /// Worth exposing because every counter upstream of the speaker can look perfect while
        /// this is false: packets arrive, are decoded and are handed to a player node, and a
        /// node in a stopped engine queues them silently. Nothing else in the audio path can
        /// tell a listener the difference between that and a quiet room.
        public var isRunning: Bool {
            lock.lock()
            defer { lock.unlock() }
            return running
        }

        /// Configure the system, engage voice processing, and open the device.
        public func start() throws(MoqomError) {
            lock.lock()
            defer { lock.unlock() }
            try startLocked()
        }

        public func stop() {
            lock.lock()
            defer { lock.unlock() }
            guard running else { return }
            engine.stop()
            running = false
        }

        /// Take the microphone, converted and packetised to `format`.
        ///
        /// One caller. A second tap on the same input is not something
        /// `AVAudioEngine` supports, and wanting one means wanting to fan the
        /// frames out downstream instead.
        public func microphone(format: AudioFormat? = nil) throws(MoqomError) -> AudioRelay {
            lock.lock()
            defer { lock.unlock() }

            guard configuration.purpose.capturesInput else {
                throw MoqomError.invalidState(
                    expected: "a capturing purpose",
                    actual: "\(configuration.purpose)"
                )
            }

            guard capture == nil else {
                throw MoqomError.invalidState(expected: "no microphone tap", actual: "one tap")
            }

            let capture = Capture(format: format ?? configuration.format)
            self.capture = capture
            if running { try installLocked(capture) }
            return capture.relay
        }

        /// Give a participant a place in the mix.
        ///
        /// - Parameter format: what will be scheduled on this voice. Passing it is not an
        ///   optimisation. A connection made with `nil` takes the mixer's own format, which
        ///   follows the output route and is commonly stereo, and `AVAudioPlayerNode` then
        ///   asserts on the first mono buffer handed to it — `_outputFormat.channelCount ==
        ///   buffer.format.channelCount`, a hard crash rather than a thrown error, on a call
        ///   that had connected and gone live. Voice audio is mono, so the mismatch is the
        ///   ordinary case and not an edge one. Stated explicitly, the mixer up-mixes.
        public func attach(format: AVAudioFormat? = nil) -> Voice {
            lock.lock()
            defer { lock.unlock() }

            let voice = Voice(graph: self)
            engine.attach(voice.node)
            engine.connect(voice.node, to: engine.mainMixerNode, format: format)
            voices.append(voice)
            return voice
        }

        /// What the microphone is currently hearing.
        ///
        /// ``AudioMeter/quiet`` when nothing is capturing. This is the number to
        /// watch when checking that cancellation works on a device: with the far
        /// end playing and nobody speaking, the level sits at the noise floor if
        /// the canceller has its reference and rises with the far end if it does
        /// not.
        public var meter: AudioMeter {
            lock.lock()
            let capture = self.capture
            lock.unlock()
            return capture?.meter ?? .quiet
        }

        /// Whether to bypass voice processing without tearing the graph down.
        ///
        /// The switch for the case a broadcast actually runs into: somebody
        /// talking starts a song, and the processing that made their voice
        /// intelligible is now making the music sound like a phone call.
        /// Bypassing is a property change; turning voice processing off is not,
        /// and would take the engine down mid-broadcast.
        public var isBypassingVoiceProcessing: Bool {
            get {
                guard configuration.purpose.capturesInput else { return true }
                return engine.inputNode.isVoiceProcessingBypassed
            }
            set {
                guard configuration.purpose.capturesInput else { return }
                engine.inputNode.isVoiceProcessingBypassed = newValue
            }
        }

        // MARK: - Internals

        private func startLocked() throws(MoqomError) {
            guard !running else { return }

            try activateSession()

            // Before the engine starts, and only then. Enabling voice
            // processing reconfigures the engine's input and output around the
            // system's voice-processing unit, which is not something it will do
            // while rendering.
            if configuration.purpose.wantsVoiceProcessing {
                do {
                    try engine.inputNode.setVoiceProcessingEnabled(true)
                    isCancellingEcho = true
                } catch {
                    // Not fatal, and not silent either. Capture without
                    // cancellation is better than no capture, but a caller that
                    // does not know has no way to warn the person who is about
                    // to be the source of everybody else's echo.
                    isCancellingEcho = false
                }
            } else {
                isCancellingEcho = false
            }

            if let capture { try installLocked(capture) }

            do {
                try engine.start()
            } catch {
                throw MoqomError.platform(api: "AVAudioEngine.start", status: -1)
            }
            running = true

            for voice in voices { voice.node.play() }
        }

        private func installLocked(_ capture: Capture) throws(MoqomError) {
            let hardware = engine.inputNode.outputFormat(forBus: 0)
            try capture.prepare(from: hardware)

            // A tap buffer of zero lets the engine pick, which is what it wants
            // and what avoids an extra copy on every callback.
            engine.inputNode.installTap(onBus: 0, bufferSize: 0, format: hardware) {
                buffer, _ in
                capture.ingest(buffer)
            }
        }

        private func detach(_ voice: Voice) {
            lock.lock()
            defer { lock.unlock() }
            voice.node.stop()
            engine.detach(voice.node)
            voices.removeAll { $0 === voice }
        }

        /// The system's opinion of what this graph is for.
        private func activateSession() throws(MoqomError) {
            #if os(iOS) || os(visionOS) || os(tvOS)
                let session = AVAudioSession.sharedInstance()
                let purpose = configuration.purpose
                do {
                    try session.setCategory(
                        purpose.category,
                        mode: purpose.mode,
                        options: purpose.options
                    )
                    // Asking rather than requiring. The voice-processing unit
                    // picks its own rate and the converter absorbs whatever it
                    // picks, so this only saves a resample when it is granted.
                    try? session.setPreferredSampleRate(Double(configuration.format.sampleRate))

                    // Half a packet, so the hardware hands over samples faster than the encoder
                    // consumes them. The system's own choice is much larger, and a buffer larger
                    // than a packet is not just latency: packets then leave in bursts of two and
                    // three with a gap behind them, the receiver's jitter estimator reads the
                    // bursts as an unstable link, and it sizes the playout buffer for a link that
                    // is behaving perfectly. Measured against a synthetic source on the same
                    // relay, the microphone reported ten times the jitter — 28ms against 2.7ms —
                    // and bought itself ninety milliseconds of buffer with it.
                    try? session.setPreferredIOBufferDuration(0.01)
                    try session.setActive(true)
                } catch {
                    throw MoqomError.platform(api: "AVAudioSession.setCategory", status: -1)
                }
            #endif
        }

        /// Route changes, interruptions, and the engine reconfiguring itself.
        ///
        /// All three arrive as notifications and all three invalidate the tap.
        /// This is not defensive coding: putting on a pair of AirPods in the
        /// middle of a broadcast changes the input format, and a tap installed
        /// against the old one stops delivering.
        private func observe() {
            let centre = NotificationCenter.default

            observers.append(
                centre.addObserver(
                    forName: NSNotification.Name.AVAudioEngineConfigurationChange,
                    object: engine,
                    queue: nil
                ) { [weak self] _ in
                    self?.rebuild()
                }
            )

            #if os(iOS) || os(visionOS) || os(tvOS)
                observers.append(
                    centre.addObserver(
                        forName: AVAudioSession.interruptionNotification,
                        object: AVAudioSession.sharedInstance(),
                        queue: nil
                    ) { [weak self] note in
                        let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                        guard let raw, let type = AVAudioSession.InterruptionType(rawValue: raw)
                        else { return }
                        switch type {
                        case .began: self?.interrupted()
                        case .ended: self?.rebuild()
                        @unknown default: break
                        }
                    }
                )
            #endif
        }

        /// A phone call, or Siri. The engine is already stopped by the time
        /// this arrives; the bookkeeping has to agree with it.
        private func interrupted() {
            lock.lock()
            defer { lock.unlock() }
            running = false
        }

        /// Reinstall against whatever the hardware looks like now.
        private func rebuild() {
            lock.lock()
            defer { lock.unlock() }

            // Reaching for the input node at all is what has to be avoided on a
            // playback session, not just tapping it.
            if configuration.purpose.capturesInput {
                engine.inputNode.removeTap(onBus: 0)
            }
            if running {
                engine.stop()
                running = false
            }
            // The estimate of the room belongs to the old microphone.
            capture?.reset()
            try? startLocked()
        }
    }

    public extension AudioGraph.Purpose {
        /// Whether the speaker, rather than the receiver, is the right default.
        ///
        /// The distinction is where somebody's head is. A voice call is held
        /// against an ear, so the receiver is right and the proximity sensor
        /// should blank the screen. A video call cannot be: the camera has to
        /// see a face, so the device is at arm's length and the receiver is
        /// pointing at nothing. That is why ``AudioGraph/Purpose/videoCall``
        /// exists as its own case rather than as a flag on a voice call -- it is
        /// the configuration that puts the loudspeaker and the microphone in the
        /// same room, which is the whole reason cancellation has to work.
        ///
        /// Meaningless without capture: on a playback session the system routes
        /// to the speaker on its own, and the option that asks for it is
        /// rejected.
        var prefersSpeaker: Bool { self != .voiceCall && capturesInput }

        /// Whether a headset's own microphone should be used when it has one.
        ///
        /// Off for music, where the alternative is the hands-free profile:
        /// narrowband, mono, and built for speech. A stereo output path is worth
        /// more there than a second microphone nobody is going to sing into.
        var prefersHeadsetInput: Bool { self != .music && capturesInput }
    }

    #if os(iOS) || os(visionOS) || os(tvOS)
        extension AudioGraph.Purpose {
            var category: AVAudioSession.Category {
                capturesInput ? .playAndRecord : .playback
            }

            var mode: AVAudioSession.Mode {
                switch self {
                case .voiceCall: .voiceChat
                case .videoCall: .videoChat
                case .music, .listening: .default
                }
            }

            var options: AVAudioSession.CategoryOptions {
                // A playback session reaches Bluetooth, AirPlay and the speaker
                // without being asked, and the input-related options are not
                // merely redundant there: `setCategory` rejects them, which
                // fails the activation and leaves a listener with no audio at
                // all.
                guard capturesInput else { return [] }

                var options: AVAudioSession.CategoryOptions = [.allowBluetoothA2DP]
                if prefersSpeaker { options.insert(.defaultToSpeaker) }
                if prefersHeadsetInput { options.insert(.allowBluetoothHFP) }
                return options
            }
        }
    #endif

    /// Hardware buffers in, whole packets out.
    ///
    /// Split from the graph because the two have unrelated lifetimes: a tap is
    /// reinstalled on every route change, and the accumulated tail of a packet
    /// has to survive that or every route change puts a click in the audio.
    private final class Capture: @unchecked Sendable {
        let relay: AudioRelay
        private let format: AudioFormat
        private let lock = NSLock()

        private var converter: AVAudioConverter?
        private var target: AVAudioFormat?
        private var carry: [Float] = []
        private var nextTimestamp: UInt64 = 0

        /// Measured here rather than downstream, because the samples are
        /// already in cache on this thread and a meter that lagged the audio by
        /// a queue hop would be useless for the thing it is for: watching
        /// whether the far end is leaking into the near end.
        ///
        /// The indicator preset rather than the transmission one. This drives a
        /// display, so it should not flicker on a transient; the encoder runs
        /// its own detector for the wire, where the answer has to arrive on the
        /// frame the speech does.
        private var voice = VoiceActivity(configuration: .indicator)

        init(format: AudioFormat) {
            self.format = format
            relay = AudioRelay(format: format, depth: 16)
        }

        var meter: AudioMeter {
            lock.lock()
            defer { lock.unlock() }
            return voice.meter
        }

        func prepare(from hardware: AVAudioFormat) throws(MoqomError) {
            lock.lock()
            defer { lock.unlock() }

            guard
                let target = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: Double(format.sampleRate),
                    channels: AVAudioChannelCount(format.channels),
                    interleaved: true
                ),
                let converter = AVAudioConverter(from: hardware, to: target)
            else {
                throw MoqomError.platform(api: "AVAudioConverter", status: -1)
            }
            self.target = target
            self.converter = converter
        }

        func reset() {
            lock.lock()
            defer { lock.unlock() }
            converter = nil
            target = nil
            // A different microphone has a different room.
            voice.reset()
        }

        /// Convert, accumulate, and emit whole packets.
        ///
        /// The order matters. `AVAudioEngine` delivers whatever the hardware
        /// feels like -- commonly 4.4ms on an iPhone -- and Opus wants exactly
        /// 20ms, so converting before accumulating means the accumulator counts
        /// in the units the encoder asked for.
        func ingest(_ buffer: AVAudioPCMBuffer) {
            lock.lock()
            guard let converter, let target else {
                lock.unlock()
                return
            }

            let ratio = target.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
            guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)
            else {
                lock.unlock()
                return
            }

            // The block is declared `@Sendable` but `AVAudioConverter` calls it
            // synchronously, on this thread, before `convert` returns. The box
            // is what lets the compiler see that rather than assuming an escape
            // that does not happen.
            let input = ConverterInput(buffer: buffer)
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                input.next(status: status)
            }
            guard error == nil, converted.frameLength > 0,
                  let channel = converted.floatChannelData?[0]
            else {
                lock.unlock()
                return
            }

            let count = Int(converted.frameLength) * format.channels
            carry.append(contentsOf: UnsafeBufferPointer(start: channel, count: count))

            let packet = format.samplesPerFrame * format.channels
            var ready: [AudioFrame] = []
            while carry.count >= packet {
                let samples = Array(carry.prefix(packet))
                carry.removeFirst(packet)
                let frame = AudioFrame(
                    timestamp: FrameTimestamp(nanoseconds: nextTimestamp),
                    format: format,
                    samples: samples
                )
                voice.accept(frame)
                ready.append(frame)
                // Advanced by the packet's own duration rather than read from a
                // clock: a capture timeline has to be continuous, and a wall
                // clock read per callback would inherit the scheduling jitter
                // this whole path exists to keep out of the media.
                nextTimestamp += UInt64(
                    1_000_000_000 / (format.sampleRate / format.samplesPerFrame)
                )
            }
            lock.unlock()

            for frame in ready { relay.submit(frame) }
        }
    }

    /// One buffer, handed to `AVAudioConverter` exactly once.
    private final class ConverterInput: @unchecked Sendable {
        private let buffer: AVAudioPCMBuffer
        private var supplied = false

        init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }

        func next(
            status: UnsafeMutablePointer<AVAudioConverterInputStatus>
        ) -> AVAudioBuffer? {
            guard !supplied else {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
    }
#endif
