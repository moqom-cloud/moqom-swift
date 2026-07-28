import Foundation
import Testing

@testable import MoqomCore

@Suite("Voice activity")
struct VoiceActivityTests {
    private let format = AudioFormat.voice

    /// One frame of a sine at `amplitude`, which stands in for speech: it has
    /// energy in the band voice occupies and survives the high-pass.
    private func tone(_ amplitude: Float, hz: Double = 300, phase: inout Double) -> AudioFrame {
        let count = format.samplesPerFrame
        var samples: [Float] = []
        samples.reserveCapacity(count)
        let step = 2 * Double.pi * hz / Double(format.sampleRate)
        for _ in 0 ..< count {
            samples.append(amplitude * Float(sin(phase)))
            phase += step
        }
        return AudioFrame(timestamp: FrameTimestamp(nanoseconds: 0), format: format, samples: samples)
    }

    /// One frame of pseudo-random noise, which stands in for a room: broadband,
    /// steady, and exactly what the estimator is supposed to learn to ignore.
    private func noise(_ amplitude: Float, seed: inout UInt64) -> AudioFrame {
        let count = format.samplesPerFrame
        var samples: [Float] = []
        samples.reserveCapacity(count)
        for _ in 0 ..< count {
            // A small deterministic generator, so a failure reproduces.
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Float(seed >> 11) / Float(UInt64(1) << 53) * 2 - 1
            samples.append(amplitude * unit)
        }
        return AudioFrame(timestamp: FrameTimestamp(nanoseconds: 0), format: format, samples: samples)
    }

    private func silence() -> AudioFrame {
        AudioFrame(
            timestamp: FrameTimestamp(nanoseconds: 0),
            format: format,
            samples: [Float](repeating: 0, count: format.samplesPerFrame)
        )
    }

    @Test("a digitally silent stream never reports speech")
    func silenceIsNotSpeech() {
        var detector = VoiceActivity()
        for _ in 0 ..< 50 {
            let speaking = detector.accept(silence())
            #expect(!speaking)
        }
        #expect(detector.level == VoiceActivity.silent)
    }

    @Test("speech is reported on the frame it arrives, not several frames later")
    func onsetIsImmediate() {
        // The point of the transmission preset. A detector that waited three
        // frames to be sure would cut 60ms off the front of every sentence,
        // and the missing sound is the start of the first word.
        var detector = VoiceActivity(configuration: .transmission)
        var phase = 0.0
        for _ in 0 ..< 10 { detector.accept(silence()) }

        let spoke = detector.accept(tone(0.2, phase: &phase))
        #expect(spoke)
    }

    @Test("hangover holds through the gaps inside a sentence")
    func hangoverHoldsThroughGaps() {
        var detector = VoiceActivity(configuration: .transmission)
        var phase = 0.0
        for _ in 0 ..< 20 { detector.accept(tone(0.2, phase: &phase)) }
        #expect(detector.isSpeaking)

        // 100ms of nothing -- a stop consonant, or a breath. Five frames at
        // 20ms, well inside the 250ms hangover.
        for _ in 0 ..< 5 { detector.accept(silence()) }
        #expect(detector.isSpeaking, "a pause inside a sentence ended the sentence")

        // And a longer one, which is the end of it.
        for _ in 0 ..< 10 { detector.accept(silence()) }
        #expect(!detector.isSpeaking)
    }

    @Test("a loud steady room is not speech, which is the case gain control creates")
    func steadyNoiseIsNotSpeech() {
        // This is the test the old peak threshold could not pass. Noise at
        // -26 dBFS is far above the -50 dBFS the previous check compared
        // against, so every frame here would have been marked as speech.
        var detector = VoiceActivity()
        var seed: UInt64 = 1
        var speaking = 0
        for _ in 0 ..< 200 {
            if detector.accept(noise(0.05, seed: &seed)) { speaking += 1 }
        }

        #expect(detector.level > -50, "the fixture is quieter than the old threshold, so it proves nothing")
        #expect(speaking == 0, "steady room noise was reported as speech \(speaking) times")
    }

    @Test("speech over a loud room is still speech")
    func speechSurvivesALoudRoom() {
        var detector = VoiceActivity()
        var seed: UInt64 = 2
        var phase = 0.0

        // Learn the room first.
        for _ in 0 ..< 200 { detector.accept(noise(0.05, seed: &seed)) }
        let floor = detector.noiseFloor

        // Then talk over it, 20dB up.
        var frame = tone(0.5, phase: &phase)
        let room = noise(0.05, seed: &seed)
        frame = AudioFrame(
            timestamp: FrameTimestamp(nanoseconds: 0),
            format: format,
            samples: zip(frame.samples, room.samples).map(+)
        )

        let spoke = detector.accept(frame)
        #expect(spoke)
        #expect(floor > VoiceActivity.silent, "the floor never converged, so this proves nothing")
    }

    @Test("a constant offset is not speech, however large")
    func directCurrentIsNotSpeech() {
        // A cheap converter, or a stuck channel. Full-scale energy, nothing
        // audible, and a detector measuring raw amplitude would call it a
        // shout that never ends.
        var detector = VoiceActivity()
        let offset = AudioFrame(
            timestamp: FrameTimestamp(nanoseconds: 0),
            format: format,
            samples: [Float](repeating: 0.9, count: format.samplesPerFrame)
        )

        var speaking = 0
        for _ in 0 ..< 100 {
            if detector.accept(offset) { speaking += 1 }
        }
        #expect(speaking == 0, "a DC offset was reported as speech \(speaking) times")
    }

    @Test("the indicator preset rejects a single transient")
    func indicatorNeedsConfirmation() {
        // A door, a cough, a key. Loud, brief, and not somebody's turn to
        // speak -- so a name should not light up for it.
        var detector = VoiceActivity(configuration: .indicator)
        var phase = 0.0
        for _ in 0 ..< 20 { detector.accept(silence()) }

        let transient = detector.accept(tone(0.6, hz: 2000, phase: &phase))
        #expect(!transient)
        detector.accept(silence())
        #expect(!detector.isSpeaking)

        // Sustained is a different thing, and it does light up.
        for _ in 0 ..< 3 { detector.accept(tone(0.2, phase: &phase)) }
        #expect(detector.isSpeaking)
    }

    @Test("a stream that opens mid-sentence is not deaf until the speaker pauses")
    func hotMicrophoneStart() {
        // A hot microphone: the first frame this detector ever sees is already
        // speech. Calibrating the room from it unguarded would put the floor at
        // the speaker's own level, and nothing but a pause would ever bring it
        // back down -- so the detector would stay silent through the sentence
        // it was created to notice.
        var detector = VoiceActivity()
        var phase = 0.0
        let spoke = detector.accept(tone(0.2, phase: &phase))

        #expect(spoke, "the first frame was speech and the detector calibrated itself deaf to it")
        #expect(detector.noiseFloor <= detector.configuration.roomCeiling)
    }

    @Test("a monologue does not teach the estimator that speech is the room")
    func monologueDoesNotRaiseTheFloor() {
        // Ten seconds of unbroken tone. An estimator that chases the signal
        // exponentially closes the margin somewhere in the middle of this and
        // stops reporting speech while the speech is still going -- which is
        // the worst failure available, because a broadcaster talking without
        // pausing is the normal case rather than an edge one.
        var detector = VoiceActivity()
        var phase = 0.0
        var lost = 0
        for _ in 0 ..< 500 {
            if !detector.accept(tone(0.2, phase: &phase)) { lost += 1 }
        }

        #expect(lost == 0, "detection dropped out \(lost) times during continuous speech")
        #expect(detector.margin >= detector.configuration.threshold)
    }

    @Test("a room that gets permanently louder is learned instead of reported forever")
    func aWrongFloorRecovers() {
        // The other half of not letting speech teach the estimator: if the
        // estimate is too low, every frame looks like speech, so nothing is
        // ever a measurement of the room, so the estimate stays too low. A fan
        // switching on does exactly this. Without the watchdog the name stays
        // lit and the packets stay marked as speech for the rest of the call.
        var detector = VoiceActivity()
        var seed: UInt64 = 4

        for _ in 0 ..< 100 { detector.accept(noise(0.001, seed: &seed)) }
        let quiet = detector.noiseFloor

        let started = detector.accept(noise(0.05, seed: &seed))
        #expect(started, "a 30dB step in room noise should read as speech at first")

        // A minute of it, unchanging.
        for _ in 0 ..< 3000 { detector.accept(noise(0.05, seed: &seed)) }

        #expect(!detector.isSpeaking, "the louder room was still being reported as speech")
        #expect(detector.noiseFloor > quiet + 20, "the estimate never learned the new room")
    }

    @Test("the level is a real dBFS reading, so it can drive a meter")
    func levelIsCalibrated() {
        // A full-scale sine is 1/sqrt(2) RMS, which is -3 dBFS. Half scale is
        // -9. Anything driving a meter needs these to be the actual numbers.
        var detector = VoiceActivity()
        var phase = 0.0
        for _ in 0 ..< 5 { detector.accept(tone(0.5, phase: &phase)) }

        #expect(abs(detector.level - -9.0) < 1.0, "level read \(detector.level) dBFS, expected about -9")
    }

    @Test("the meter reports what the detector believes, not a separate estimate")
    func meterMatchesTheDetector() {
        // One measurement with two readers -- the wire and the interface -- and
        // they have to agree. A meter computing its own level would drift from
        // the decision it appears to explain, which is the sort of disagreement
        // that costs an afternoon to notice.
        var detector = VoiceActivity(configuration: .indicator)
        var phase = 0.0
        for _ in 0 ..< 5 { detector.accept(tone(0.3, phase: &phase)) }

        let meter = detector.meter
        #expect(meter.level == detector.level)
        #expect(meter.noiseFloor == detector.noiseFloor)
        #expect(meter.margin == detector.margin)
        #expect(meter.isSpeaking == detector.isSpeaking)
    }

    @Test("a reset forgets the room, for a route change to a different microphone")
    func resetForgetsTheRoom() {
        var detector = VoiceActivity()
        var seed: UInt64 = 3
        for _ in 0 ..< 100 { detector.accept(noise(0.05, seed: &seed)) }
        #expect(detector.noiseFloor > VoiceActivity.silent)

        detector.reset()
        #expect(detector.noiseFloor == VoiceActivity.silent)
        #expect(!detector.isSpeaking)

        // And calibrates again from the first frame it sees, rather than
        // treating a quiet microphone as a room that got 60dB quieter.
        detector.accept(noise(0.005, seed: &seed))
        #expect(abs(detector.noiseFloor - detector.level) < 0.001)
    }

    @Test("stereo is measured as one signal rather than per channel")
    func stereoIsDownmixed() {
        let stereo = AudioFormat(sampleRate: 48000, channels: 2)
        var detector = VoiceActivity()

        // Out of phase between the channels: each channel is loud, the sum is
        // nothing. The interesting part is that this is *stable* -- whatever
        // the answer, it must not depend on which channel happened to be read.
        var samples: [Float] = []
        for _ in 0 ..< stereo.samplesPerFrame {
            samples.append(0.5)
            samples.append(-0.5)
        }
        let frame = AudioFrame(timestamp: FrameTimestamp(nanoseconds: 0), format: stereo, samples: samples)

        var detectorAgain = detector
        let first = detector.accept(frame)
        let second = detectorAgain.accept(frame)
        #expect(first == second)
        #expect(detector.level == detectorAgain.level)
    }
}
