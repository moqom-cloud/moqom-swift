// Whether somebody is talking.
//
// Three things want this answer and they want it with different tolerances,
// which is why the thresholds are configuration rather than constants:
//
//   - The wire, so a packet can be marked as a pause. A receiver that sees a
//     gap in sequence numbers conceals; one that is told "this is silence"
//     does not, and those sound different.
//   - The interface, so a room can show who is speaking. Here a wrong answer
//     for one packet is a flicker on somebody's name, so this side wants
//     confirmation before it commits.
//   - Everything expensive that should only run on speech -- transcription,
//     translation, captions. Gating those on voice activity is the difference
//     between a warm phone and a thermally throttled one.
//
// What this replaces is a peak-amplitude threshold, and that is worth stating
// because the old one looks reasonable. It asked whether any sample in the
// packet exceeded -50 dBFS. That is a test for a *digitally* silent buffer,
// not for a quiet room, and it fails in the exact configuration a broadcast
// runs in: with the system's automatic gain control engaged, the noise floor
// is deliberately amplified until it is audible, so every packet clears -50
// dBFS and nothing is ever silence. The flag was correct and useless.
//
// So the decision here is *relative*. Speech is energy standing above the room
// it is spoken in, and the room is measured continuously rather than assumed.

import Foundation

/// Whether a run of samples contains speech.
///
/// A value type holding its own filter and estimator state, so one detector
/// belongs to one stream of audio and copying it forks the estimate rather
/// than sharing it.
public struct VoiceActivity: Sendable {
    /// The dBFS value reported for a buffer with no energy at all.
    ///
    /// A floor rather than negative infinity, because these numbers reach a
    /// level meter and an axis that runs to minus infinity cannot be drawn.
    public static let silent = -120.0

    /// How eagerly to call something speech.
    public struct Configuration: Hashable, Sendable {
        /// How far above the noise floor energy must stand, in dB.
        ///
        /// Nine is about the smallest that survives a room with a fan in it.
        /// Lower makes a breath into a word; much higher loses the start of a
        /// quietly spoken sentence, which is the more annoying failure because
        /// it clips the moment somebody begins to talk.
        public var threshold: Double

        /// An absolute floor, in dBFS, below which nothing is speech however
        /// far it stands above the noise.
        ///
        /// This is what keeps a *digitally* quiet input from producing speech
        /// out of its own dither: with no noise to speak of, the noise floor
        /// estimate collapses and a -70 dBFS tick clears the relative test
        /// easily. It has no opinion about loud rooms, which is the relative
        /// test's job.
        public var gate: Double

        /// Consecutive frames above the threshold before speech is declared.
        ///
        /// One for anything on the media path: a frame is 20ms, and waiting to
        /// be sure costs exactly the beginning of the word you were sure
        /// about. More for an indicator, where a door closing should not put
        /// somebody's name in lights.
        public var onset: Int

        /// How long speech is held after the last frame above the threshold.
        ///
        /// Speech is full of gaps -- stop consonants, breaths, thinking -- and
        /// a detector without hangover reports every one of them. The cost of
        /// too much is marking a pause as speech, which is cheap. The cost of
        /// too little is a stutter in whatever this drives.
        public var hangover: Duration

        /// How fast the noise floor may climb, in dB per second.
        ///
        /// A slew rate rather than a filter, and that is the load-bearing
        /// choice. A filter that chases the signal gets *taught* by it: hold a
        /// note, or talk without pausing, and the estimate climbs until the
        /// margin closes and the detector goes deaf in the middle of the
        /// sentence it was tracking. A rate limit cannot be dragged, however
        /// loud the input, so the worst an unbroken sound can do is push the
        /// floor up by this much per second.
        ///
        /// One dB per second bounds both failures. A room that genuinely gets
        /// louder by 20dB is learned in twenty seconds, and no sound reaching
        /// the microphone can make it learn faster than that.
        public var floorRise: Double

        /// How fast the noise floor may fall, in dB per second.
        ///
        /// Fast, because energy dropping is by definition not speech standing
        /// above the floor, and the pauses between words are the best
        /// measurement of the room this will ever get. Rate-limited rather than
        /// instant so that one anomalous frame -- a dropout, a glitch, a buffer
        /// of zeroes -- cannot reset the estimate to nothing and make
        /// everything afterwards look like speech.
        public var floorFall: Double

        /// The loudest a *first* estimate of the room may be, in dBFS.
        ///
        /// The first frame calibrates, because starting from silence would
        /// report speech for the first few seconds in any room with a fan in
        /// it. But it calibrates with a cap, because the two ways of being
        /// wrong here are not equally bad. Too low over-reports speech and
        /// then corrects itself as the floor climbs. Too high under-reports,
        /// and the only thing that corrects it is a pause -- so a stream that
        /// opens mid-sentence, which is exactly what a hot microphone does,
        /// would be deaf until the speaker stopped talking.
        ///
        /// -35 dBFS is above any plausible room and below any speech worth
        /// detecting, so the cap only ever engages when the first frame was
        /// not the room.
        public var roomCeiling: Double

        /// How long speech may run before the estimate is treated as suspect.
        ///
        /// The floor does not climb while the frame is classified as speech,
        /// because letting it would mean the speaker teaches the detector that
        /// their own voice is the room. That alone deadlocks: if the estimate
        /// is too *low* -- a fan starts, and every frame afterwards clears the
        /// threshold -- then every frame is speech, so the floor never rises,
        /// so every frame stays speech.
        ///
        /// This breaks it. Nobody talks for twenty seconds without the level
        /// dipping once, so speech that has apparently run that long is better
        /// evidence that the floor is wrong than that somebody is still
        /// talking, and the estimate resumes climbing.
        public var suspicion: Duration

        /// Corner frequency of the high-pass ahead of the measurement, in Hz.
        ///
        /// Below this is nothing anybody said: a DC offset from a cheap
        /// converter, a hand moving on the device, a table being knocked, the
        /// low rumble of a car. All of it is energy, none of it is voice, and
        /// gain control amplifies it along with everything else.
        public var highPass: Double

        public init(
            threshold: Double = 9,
            gate: Double = -55,
            onset: Int = 1,
            hangover: Duration = .milliseconds(250),
            floorRise: Double = 1,
            floorFall: Double = 40,
            roomCeiling: Double = -35,
            suspicion: Duration = .seconds(20),
            highPass: Double = 80
        ) {
            self.threshold = threshold
            self.gate = gate
            self.onset = max(1, onset)
            self.hangover = hangover
            self.floorRise = floorRise
            self.floorFall = floorFall
            self.roomCeiling = roomCeiling
            self.suspicion = suspicion
            self.highPass = highPass
        }

        /// For deciding what goes on the wire: commit immediately, release slowly.
        ///
        /// Asymmetric on purpose. Declaring speech late clips a word; declaring
        /// it over early cuts one off. Both errors are audible and only one is
        /// avoidable by waiting, so this does not wait.
        public static let transmission = Configuration()

        /// For showing who is speaking: confirm first, and hold longer.
        ///
        /// 60ms of confirmation is below what anybody perceives as lag on a
        /// name lighting up, and it is enough to reject the transients -- a
        /// cough, a keyboard, a door -- that would otherwise pass.
        public static let indicator = Configuration(
            threshold: 10,
            onset: 3,
            hangover: .milliseconds(600)
        )
    }

    public let configuration: Configuration

    /// Whether the stream is currently carrying speech.
    public private(set) var isSpeaking = false

    /// Energy of the most recent frame, in dBFS, after the high-pass.
    ///
    /// Root-mean-square rather than peak. Speech is crest-heavy, so its peak
    /// says more about which vowel it was than about how loud it is, and a
    /// meter driven by peaks reads almost the same for a whisper and a shout.
    public private(set) var level = VoiceActivity.silent

    /// The current estimate of the room, in dBFS.
    public private(set) var noiseFloor = VoiceActivity.silent

    /// How far the last frame stood above the room, in dB.
    ///
    /// Exposed because it is the number to look at when a detector is behaving
    /// oddly: it separates "the room is louder than we thought" from "the
    /// input is quieter than we thought", which look identical from outside.
    public private(set) var margin = 0.0

    /// Filter state. Two samples, carried across frames so a packet boundary
    /// does not put a step into the filtered signal.
    private var lastInput: Double = 0
    private var lastOutput: Double = 0

    private var consecutive = 0
    private var held = 0
    private var calibrated = false

    /// Seconds of unbroken above-threshold energy, for the suspicion watchdog.
    private var run = 0.0

    public init(configuration: Configuration = .transmission) {
        self.configuration = configuration
    }

    /// Feed one captured frame.
    ///
    /// - Returns: whether the stream is carrying speech, which is not the same
    ///   as whether *this frame* was above the threshold -- hangover means a
    ///   quiet frame inside a sentence still answers yes.
    @discardableResult
    public mutating func accept(_ frame: AudioFrame) -> Bool {
        accept(
            samples: frame.samples,
            channels: frame.format.channels,
            sampleRate: frame.format.sampleRate,
            duration: frame.format.frameDuration
        )
    }

    /// Feed samples directly, for a caller that has not built an ``AudioFrame``.
    ///
    /// - Parameters:
    ///   - samples: interleaved, any channel count.
    ///   - channels: how many are interleaved. Channels are averaged to one
    ///     before measurement: a detector that ran per channel would have to
    ///     decide what two disagreeing answers mean, and for a question about
    ///     a person in a room they never usefully disagree.
    ///   - duration: how much time these samples cover, which is what the
    ///     estimator time constants are measured against.
    @discardableResult
    public mutating func accept(
        samples: [Float],
        channels: Int,
        sampleRate: Int,
        duration: Duration
    ) -> Bool {
        let channels = max(1, channels)
        let count = samples.count / channels
        guard count > 0, sampleRate > 0 else { return isSpeaking }

        // One pass: downmix, high-pass, accumulate energy. Three passes would
        // be clearer and this runs on every packet of every call.
        let interval = 1.0 / Double(sampleRate)
        let resistance = 1.0 / (2.0 * .pi * max(1, configuration.highPass))
        let alpha = resistance / (resistance + interval)

        var energy = 0.0
        for index in 0 ..< count {
            var mixed = 0.0
            for channel in 0 ..< channels {
                mixed += Double(samples[index * channels + channel])
            }
            mixed /= Double(channels)

            // Primed from the first sample rather than from zero, so opening a
            // stream that already has a constant offset on it does not put a
            // step through the filter and read as a click. The audio existed
            // before we started looking at it.
            if !calibrated, index == 0 { lastInput = mixed }

            // One-pole high-pass, in the difference form that needs no
            // coefficient normalisation and cannot drift its own DC.
            let filtered = alpha * (lastOutput + mixed - lastInput)
            lastInput = mixed
            lastOutput = filtered
            energy += filtered * filtered
        }

        let mean = (energy / Double(count)).squareRoot()
        level = mean > 0 ? Swift.max(Self.silent, 20 * log10(mean)) : Self.silent

        let seconds = duration.totalSeconds
        if !calibrated {
            noiseFloor = Swift.min(level, configuration.roomCeiling)
            calibrated = true
        }

        // Classify against the estimate first, then let the classification
        // decide whether the estimate is allowed to learn from this frame.
        margin = level - noiseFloor
        let above = margin >= configuration.threshold && level >= configuration.gate
        run = above ? run + seconds : 0

        if level < noiseFloor {
            // Recovery, and unconditional: energy below the floor is the one
            // measurement that cannot be speech standing above it.
            noiseFloor = Swift.max(level, noiseFloor - configuration.floorFall * seconds)
        } else if !above || run > configuration.suspicion.totalSeconds {
            noiseFloor = Swift.min(level, noiseFloor + configuration.floorRise * seconds)
        }
        noiseFloor = Swift.max(Self.silent, noiseFloor)

        if above {
            consecutive += 1
            if consecutive >= configuration.onset {
                isSpeaking = true
                held = frames(in: configuration.hangover, of: duration)
            }
        } else {
            consecutive = 0
            if isSpeaking {
                held -= 1
                if held <= 0 { isSpeaking = false }
            }
        }
        return isSpeaking
    }

    /// A snapshot of what the detector currently believes.
    ///
    /// Worth having as its own value because these four numbers are what an
    /// interface draws and what somebody measuring echo cancellation reads. The
    /// test is: play the far end, say nothing, and watch ``AudioMeter/level``.
    /// If cancellation is working it stays at the floor; if it is not, it tracks
    /// whatever the speaker is playing, which is the echo about to be published.
    public var meter: AudioMeter {
        AudioMeter(
            level: level,
            noiseFloor: noiseFloor,
            margin: margin,
            isSpeaking: isSpeaking
        )
    }

    /// Forget the room and start again.
    ///
    /// For a route change, which is the case that matters: the microphone in a
    /// pair of AirPods and the one at the bottom of a phone have different
    /// noise floors, and carrying the estimate across the switch means
    /// reporting nonsense until it re-converges.
    public mutating func reset() {
        isSpeaking = false
        level = Self.silent
        noiseFloor = Self.silent
        margin = 0
        lastInput = 0
        lastOutput = 0
        consecutive = 0
        held = 0
        calibrated = false
        run = 0
    }

    private func frames(in hangover: Duration, of frame: Duration) -> Int {
        let each = frame.totalSeconds
        guard each > 0 else { return 1 }
        return Swift.max(1, Int((hangover.totalSeconds / each).rounded()))
    }
}

/// What capture currently sounds like.
public struct AudioMeter: Hashable, Sendable {
    /// Energy of the most recent frame, in dBFS.
    public let level: Double

    /// The estimate of the room it was measured against, in dBFS.
    public let noiseFloor: Double

    /// How far the frame stood above the room, in dB.
    public let margin: Double

    public let isSpeaking: Bool

    /// Nothing has been captured yet.
    public static let quiet = AudioMeter(
        level: VoiceActivity.silent,
        noiseFloor: VoiceActivity.silent,
        margin: 0,
        isSpeaking: false
    )

    public init(level: Double, noiseFloor: Double, margin: Double, isSpeaking: Bool) {
        self.level = level
        self.noiseFloor = noiseFloor
        self.margin = margin
        self.isSpeaking = isSpeaking
    }
}

private extension Duration {
    var totalSeconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
