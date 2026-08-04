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
// So: one engine, one source node per participant into its mixer, and the
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
import os

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
        ///
        /// The device pulls from this rather than being pushed into. That is
        /// the difference between a queue whose depth is decided by the
        /// listener and one decided by whatever the network happened to deliver
        /// in a burst: with `scheduleBuffer` the packets of a burst all sit in
        /// front of the speaker and stay there, so a single bad second on the
        /// link becomes a permanent fifth of a second between a face and its
        /// voice. Measured on two phones through a relay, one direction sat at
        /// 200ms and the other climbed to 480ms and stayed. A render callback
        /// takes exactly what the hardware needs at exactly the hardware's
        /// rate, which makes the depth a number this code chooses.
        public final class Voice: @unchecked Sendable {
            let node: AVAudioSourceNode
            private weak var graph: AudioGraph?
            private let ring: PCMRing
            private let channels: Int

            /// This listener's volume for this participant, `0` to `1`.
            ///
            /// Applied while rendering rather than on the node, because the
            /// render block is where the samples already are.
            public var volume: Float {
                get { ring.gain }
                set { ring.gain = max(0, min(1, newValue)) }
            }

            init(graph: AudioGraph, format: AVAudioFormat) {
                self.graph = graph
                channels = Int(format.channelCount)
                // A second of slack. The depth is held far below this by the
                // player; the capacity only bounds what a pathological burst
                // can cost in memory.
                ring = PCMRing(
                    capacity: Int(format.sampleRate) * Int(format.channelCount),
                    channels: Int(format.channelCount),
                    sampleRate: format.sampleRate
                )
                let ring = ring
                node = AVAudioSourceNode(format: format) { silence, _, frames, buffers in
                    let filled = ring.render(
                        Int(frames),
                        into: UnsafeMutableAudioBufferListPointer(buffers)
                    )
                    if filled == 0 { silence.pointee = true }
                    return noErr
                }
            }

            /// Hand the device more samples, interleaved.
            ///
            /// Returns how many frames were taken. A short answer means the
            /// ring is full, which the caller is expected to treat as the
            /// device being ahead of the network rather than as an error.
            @discardableResult
            public func write(_ samples: [Float]) -> Int {
                ring.write(samples)
            }

            /// How much audio is waiting in front of the speaker.
            ///
            /// This is the last stretch of a listener's mouth-to-ear delay and,
            /// until it was measured, the part nothing reported. It is what
            /// lip sync has to be told about: the picture cannot be aligned to
            /// a voice whose delay nobody knows.
            public var queued: Duration { ring.queued }

            /// Times the device asked for samples and there were none.
            public var starved: Int { ring.starved }

            /// Drop everything waiting, for a listener who has stopped
            /// listening. Whatever is in the ring is stale by definition.
            public func flush() { ring.flush() }

            public func play() {}

            /// Take this participant out of the mix.
            public func remove() {
                graph?.detach(self)
                graph = nil
            }
        }

        /// Samples in one end, whatever the device asked for out of the other.
        ///
        /// Everything here happens under one lock, including the render side.
        /// A lock on the audio thread is a thing to be nervous about and the
        /// nervousness is right in general: a render callback that waits on a
        /// thread which then takes a page fault produces a dropout. It is
        /// tolerable here because the critical section is a bounded copy with
        /// no allocation, no ObjC and no syscall, and because the alternative —
        /// a lock-free ring with atomics — is a thing to get subtly wrong once
        /// and then debug at three in the morning through a dropout that only
        /// happens on somebody else's phone. If profiling ever shows this
        /// waiting, the fix is the atomic version, not a bigger buffer.
        private final class PCMRing: @unchecked Sendable {
            private let storage: UnsafeMutableBufferPointer<Float>
            private let channels: Int
            private let sampleRate: Double
            private let state: OSAllocatedUnfairLock<State>

            private struct State {
                var head = 0
                var count = 0
                var starved = 0
                var gain: Float = 1
            }

            init(capacity: Int, channels: Int, sampleRate: Double) {
                let rounded = max(channels, capacity - capacity % channels)
                storage = .allocate(capacity: rounded)
                storage.initialize(repeating: 0)
                self.channels = channels
                self.sampleRate = sampleRate
                state = OSAllocatedUnfairLock(initialState: State())
            }

            deinit { storage.deallocate() }

            var gain: Float {
                get { state.withLock { $0.gain } }
                set { state.withLock { $0.gain = newValue } }
            }

            var starved: Int { state.withLock { $0.starved } }

            var queued: Duration {
                let frames = state.withLock { $0.count } / channels
                return .seconds(Double(frames) / sampleRate)
            }

            func flush() {
                state.withLock { state in
                    state.head = 0
                    state.count = 0
                }
            }

            /// - Returns: frames taken, which is short of the offer when full.
            func write(_ samples: [Float]) -> Int {
                state.withLock { state in
                    let room = storage.count - state.count
                    let taking = min(samples.count, room - room % channels)
                    guard taking > 0 else { return 0 }
                    var index = (state.head + state.count) % storage.count
                    for offset in 0 ..< taking {
                        storage[index] = samples[offset]
                        index += 1
                        if index == storage.count { index = 0 }
                    }
                    state.count += taking
                    return taking / channels
                }
            }

            /// Fill the device's buffers, padding with silence if short.
            ///
            /// - Returns: frames of real audio, `0` when there was none.
            func render(
                _ frames: Int,
                into buffers: UnsafeMutableAudioBufferListPointer
            ) -> Int {
                // Unchecked because the device's buffer list is not `Sendable`
                // and cannot be: it is a pointer the render thread owns for the
                // duration of this call and nothing else may touch.
                state.withLockUnchecked { state in
                    let available = min(frames, state.count / channels)
                    if available < frames { state.starved += 1 }
                    let gain = state.gain
                    var index = state.head

                    // One buffer per channel when the format is deinterleaved,
                    // which is what this graph uses, and a single buffer when it
                    // is not. Both are handled because the format comes from the
                    // caller and a wrong guess here is silence, not a crash.
                    let deinterleaved = buffers.count == channels
                    for frame in 0 ..< frames {
                        for channel in 0 ..< channels {
                            var sample: Float = 0
                            if frame < available {
                                sample = storage[index] * gain
                                index += 1
                                if index == storage.count { index = 0 }
                            }
                            let target = deinterleaved ? channel : 0
                            let position = deinterleaved
                                ? frame
                                : frame * channels + channel
                            guard let data = buffers[target].mData else { continue }
                            data.assumingMemoryBound(to: Float.self)[position] = sample
                        }
                    }

                    state.head = index
                    state.count -= available * channels
                    return available
                }
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
        private var sink: AVAudioSinkNode?
        private var running = false

        /// What the graph was for before its microphone was suspended, and the
        /// flag that says it was. See ``suspendMicrophone()``.
        private var suspendedPurpose: Purpose?
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
        /// A failed change puts the previous arrangement back before it throws.
        ///
        /// Changing what the graph is for means stopping it and starting it
        /// again, and the second half can fail on its own: the system declines
        /// a category, a route moves underneath, voice processing refuses to
        /// re-engage. Leaving the engine stopped in that case is the worst
        /// available outcome, because playback goes with it — a force-muted
        /// participant lost the room, which is not what a mute is, and every
        /// counter upstream kept reporting healthy audio into a stopped engine.
        public func reconfigure(_ configuration: Configuration) throws(MoqomError) {
            lock.lock()
            let wasRunning = running
            let previous = self.configuration
            self.configuration = configuration
            lock.unlock()

            guard wasRunning else { return }
            stop()

            do {
                try start()
            } catch {
                lock.lock()
                self.configuration = previous
                lock.unlock()
                stop()
                // Deliberately not reported: the caller is about to hear about
                // the failure that matters, and a graph that cannot restart in
                // either arrangement has a problem no return value describes.
                try? start()
                throw error
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

        /// Give the input device back without disturbing playback.
        ///
        /// The graph keeps rendering, so a participant who has been force-muted
        /// still hears the room. What changes is the session's category: the
        /// engine becomes a ``Purpose/listening`` one, which is the only thing
        /// that actually puts the orange indicator out. Detaching the sink is
        /// not enough and the difference matters — a `playAndRecord` session
        /// holds the microphone whether or not anything is reading it, so a
        /// mute implemented by dropping samples leaves the user looking at a
        /// light that says otherwise.
        ///
        /// The microphone is not released, so the ``AudioRelay`` a publication
        /// is reading stays valid across the whole suspension and resuming
        /// needs no cooperation from it.
        /// - Returns: whether the input device was actually given back. `false`
        ///   means the system refused the change and the graph is still the one
        ///   it was, still rendering, still holding the microphone. Publishing
        ///   has stopped either way — that is the caller's doing and it is what
        ///   a mute guarantees — so what a `false` costs is the indicator going
        ///   out, not audio leaving the device.
        @discardableResult
        public func suspendMicrophone() -> Bool {
            lock.lock()
            let purpose = configuration.purpose
            guard suspendedPurpose == nil, purpose.capturesInput else {
                lock.unlock()
                return false
            }
            suspendedPurpose = purpose
            let format = configuration.format
            lock.unlock()

            do {
                try reconfigure(Configuration(purpose: .listening, format: format))
                return true
            } catch {
                // The flag has to come back off, or the graph believes it is
                // suspended while the device is open and a later resume decides
                // there is nothing to do.
                lock.lock()
                suspendedPurpose = nil
                lock.unlock()
                return false
            }
        }

        /// Open the input device again, as whatever the graph was for before.
        ///
        /// Does nothing if the microphone was never suspended, so this is safe
        /// to call on a lift that arrives twice.
        public func resumeMicrophone() throws(MoqomError) {
            lock.lock()
            guard let purpose = suspendedPurpose else {
                lock.unlock()
                return
            }
            suspendedPurpose = nil
            let format = configuration.format
            lock.unlock()

            try reconfigure(Configuration(purpose: purpose, format: format))
        }

        /// Whether the input device has been handed back for a mute.
        public var isMicrophoneSuspended: Bool {
            lock.lock()
            defer { lock.unlock() }
            return suspendedPurpose != nil
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

            // Around a stop and a start, when the engine is already running. Attaching a node
            // to the input of a rendering engine is a graph change it accepts and then does not
            // make: the connection exists, the callback is never called, and the microphone is
            // silent with every counter reading zero rather than failing. The engine is only
            // running here when somebody's voice is already playing — a viewer who then goes on
            // stage — which is exactly the path a benchmark that publishes from launch never
            // takes, and exactly the path a person tapping the microphone button always does.
            if running {
                engine.stop()
                running = false
                try startLocked()
            }
            return capture.relay
        }

        /// Give the microphone back, so the next caller can have it.
        ///
        /// Idempotent, and safe when nothing was taken.
        public func releaseMicrophone() {
            lock.lock()
            defer { lock.unlock() }
            guard capture != nil else { return }
            capture = nil
            guard sink != nil else { return }
            // Detaching a node from a rendering engine is the same graph change that attaching
            // one is, and gets the same treatment: stop, change, start — but only if anything
            // is left to run for.
            let wasRunning = running
            if wasRunning {
                engine.stop()
                running = false
            }
            uninstallLocked()
            if wasRunning, !voices.isEmpty { try? startLocked() }
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

            // A source node renders in the format it was built with, so unlike
            // a player node it cannot be handed one later.
            let rendering = format ?? engine.mainMixerNode.outputFormat(forBus: 0)
            let voice = Voice(graph: self, format: rendering)
            engine.attach(voice.node)
            engine.connect(voice.node, to: engine.mainMixerNode, format: rendering)
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

        /// How far behind real time the capture timeline has fallen.
        ///
        /// Zero when nothing is capturing. A steady figure is the pipeline's
        /// own delay; one that grows is the device's sample rate differing from
        /// the nominal one, which nothing here corrects and which arrives at
        /// the far end as audio drifting away from the picture.
        public var capturedLate: Duration {
            lock.lock()
            let capture = self.capture
            lock.unlock()
            return capture?.capturedLate ?? .zero
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

            // Turned off before the session changes rather than after, and only
            // when it was on. Voice processing lives on the input node, the
            // input node is not available under a category that does not
            // record, and an engine asked to start with the unit still engaged
            // on a session that has taken the microphone away refuses — which
            // is a mute that stops playback, because the engine that refused is
            // the one every participant is being rendered through.
            if !configuration.purpose.wantsVoiceProcessing, isCancellingEcho {
                try? engine.inputNode.setVoiceProcessingEnabled(false)
                isCancellingEcho = false
            }

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

            // Only when the session is one that records. A graph whose
            // microphone is suspended keeps its `Capture` — the publication
            // above is still holding its relay — and connecting the input node
            // anyway would reopen the device this is meant to have given back.
            if let capture, configuration.purpose.capturesInput {
                try installLocked(capture)
            } else {
                uninstallLocked()
            }

            do {
                try engine.start()
            } catch {
                throw MoqomError.platform(api: "AVAudioEngine.start", status: -1)
            }
            running = true
        }

        /// Take the microphone through a sink node rather than a tap.
        ///
        /// A tap was the obvious way and delivered speech in hundred millisecond clumps: five
        /// packets at once, then nothing for a tenth of a second, whatever size the tap was
        /// asked for — the request is documented as advisory and the engine declines it. The
        /// clumping is not cosmetic. A receiver cannot tell a bursty source from a bursty
        /// network, so its jitter buffer sizes itself for the burst, and measured on two
        /// phones that put the voice buffer at ninety milliseconds against twenty-five for an
        /// evenly paced source. Video then pays it too, because the picture is held back to
        /// meet the voice. A sink node is called once per render cycle instead, which is the
        /// session's IO buffer — ten milliseconds here — so the packets leave as they are
        /// spoken.
        ///
        /// The cost is that this runs on the render thread, where the tap did not. What
        /// happens on it is a format conversion and an append of a few hundred samples, which
        /// is the work the tap callback did with a hundred times as long to do it in; the
        /// budget at this rate is not close.
        private func installLocked(_ capture: Capture) throws(MoqomError) {
            let hardware = engine.inputNode.outputFormat(forBus: 0)
            try capture.prepare(from: hardware)

            uninstallLocked()
            #if os(iOS) || os(visionOS) || os(tvOS)
                let inputLatency = AVAudioSession.sharedInstance().inputLatency
            #else
                let inputLatency: TimeInterval = 0
            #endif
            let sink = AVAudioSinkNode { time, frames, list in
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: hardware,
                    bufferListNoCopy: list
                ) else { return noErr }
                buffer.frameLength = frames

                // The device's own reading of when this was heard, less what
                // the input path costs, which makes it the moment in the room
                // rather than the moment the sample reached this thread. The
                // camera quotes its frames the same way, and that is the entire
                // basis on which a receiver can hold the two together.
                var captured: UInt64?
                if time.pointee.mFlags.contains(.hostTimeValid) {
                    let seconds = AVAudioTime.seconds(forHostTime: time.pointee.mHostTime)
                    captured = UInt64(max(0, (seconds - inputLatency) * 1e9))
                }
                capture.ingest(buffer, captured: captured)
                return noErr
            }
            engine.attach(sink)
            engine.connect(engine.inputNode, to: sink, format: hardware)
            self.sink = sink
        }

        /// Remove the sink, if one is attached.
        private func uninstallLocked() {
            guard let sink else { return }
            engine.detach(sink)
            self.sink = nil
        }

        private func detach(_ voice: Voice) {
            lock.lock()
            defer { lock.unlock() }
            voice.flush()
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
            // playback session, not just capturing from it.
            if configuration.purpose.capturesInput {
                uninstallLocked()
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

        /// When the first packet of this capture was cut, on the host clock,
        /// and how far behind real time the newest one is. Guarded by ``lock``.
        ///
        /// The capture timeline advances by a packet's nominal duration rather
        /// than by a clock reading, which is right — a timeline assembled from
        /// wall-clock reads inherits the scheduling jitter — but it means the
        /// timeline says nothing about how long the pipeline is actually
        /// holding audio, and a backlog here is indistinguishable downstream
        /// from a slow network. This is that difference, measured: the gap
        /// between when a packet says it was captured and when it was really
        /// cut. It should be a small constant. Growth is the device's true
        /// sample rate pulling away from the nominal one.
        ///
        /// The origin is where the timeline is nailed to the host clock, and
        /// nailing it there is what lets a receiver put a voice next to a face.
        /// It used to be zero: the first packet of a call said it was captured
        /// at the beginning of time, and every one after it counted up from
        /// there. Video says when it was captured, on the clock the camera
        /// reports, so the two media arrived describing unrelated timelines and
        /// no amount of care downstream could align them. They can be aligned
        /// now because they are quoted against the same clock.
        private var origin: UInt64 = 0
        private var lag: Duration = .zero

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

        var capturedLate: Duration {
            lock.lock()
            defer { lock.unlock() }
            return lag
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
        /// - Parameter captured: when the hardware says the first sample of this
        ///   buffer was heard, in nanoseconds on the host clock, or `nil` where
        ///   the device did not say. Used once, to anchor the timeline.
        func ingest(_ buffer: AVAudioPCMBuffer, captured: UInt64? = nil) {
            lock.lock()
            guard let converter, let target else {
                lock.unlock()
                return
            }

            if origin == 0 {
                // The samples already accumulated belong before this buffer, so
                // the timeline starts that much earlier than the reading.
                let waiting = UInt64(
                    Double(carry.count / format.channels) / Double(format.sampleRate) * 1e9
                )
                let now = captured ?? DispatchTime.now().uptimeNanoseconds
                origin = now > waiting ? now - waiting : now
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
                    timestamp: FrameTimestamp(nanoseconds: origin + nextTimestamp),
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
            if !ready.isEmpty {
                let now = DispatchTime.now().uptimeNanoseconds
                lag = .nanoseconds(Int64(now - origin) - Int64(nextTimestamp))
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
