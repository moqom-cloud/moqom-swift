// Audio: encoding, publishing, and the jitter buffer.
//
// The jitter buffer gets the most attention here because it is the part with
// real behaviour and no hardware in the way. Everything it does is a trade
// between latency and gaps, and the tests are written to pin the trades rather
// than the implementation: what should be audible, what should not, and what
// should never happen at all.

import Foundation
import Testing

@testable import MoqomCore
@testable import MoqomKit
@testable import MoqomLoopback

/// One frame of a 300Hz tone peaking at `peak`.
///
/// A tone rather than a constant, and the distinction is not cosmetic. A buffer
/// of one repeated value is a DC offset: it has energy, it has a peak, and there
/// is nothing to hear. Voice detection high-passes before it measures, precisely
/// so that a converter with an offset on it does not report a room full of
/// speech, which means a constant-valued fixture is classified as a pause
/// however large the constant is. Feeding one to assert that speech reaches the
/// wire would be asserting it about audio nobody can hear.
private func tone(_ peak: Float, count: Int = 960, hz: Double = 300) -> [Float] {
    let step = 2 * Double.pi * hz / 48000
    return (0 ..< count).map { peak * Float(sin(Double($0) * step)) }
}

@Suite("Audio formats")
struct AudioFormatTests {
    @Test("the voice default is one 20ms packet of 48kHz mono")
    func voiceDefault() {
        let format = AudioFormat.voice
        #expect(format.sampleRate == 48000)
        #expect(format.channels == 1)
        #expect(format.samplesPerFrame == 960)
    }

    @Test("packet size follows the frame duration")
    func samplesFollowDuration() {
        #expect(AudioFormat(frameDuration: .milliseconds(10)).samplesPerFrame == 480)
        #expect(AudioFormat(frameDuration: .milliseconds(40)).samplesPerFrame == 1920)
    }

    @Test("peak level finds the loudest sample regardless of sign")
    func peakIsAbsolute() {
        let frame = AudioFrame(
            timestamp: FrameTimestamp(nanoseconds: 0),
            format: .voice,
            samples: [0.1, -0.9, 0.3]
        )
        #expect(abs(frame.peak - 0.9) < 0.0001)
    }
}

@Suite("Audio encoding")
struct AudioEncodingTests {
    private func samples(peak: Float, count: Int = 960) -> [Float] {
        tone(peak, count: count)
    }

    @Test("a silent buffer is encoded as silence, and said so")
    func silenceIsFlagged() async throws {
        let encoder = SyntheticAudioEncoder()
        try await encoder.encode(
            AudioFrame(
                timestamp: FrameTimestamp(nanoseconds: 0),
                format: .voice,
                samples: samples(peak: 0)
            )
        )
        var packets = encoder.encodedFrames().makeAsyncIterator()
        let packet = try #require(await packets.next())
        #expect(packet.isSilence)

        // The packet still exists. A receiver that saw a gap in sequence
        // numbers instead would conceal, which sounds worse than the pause it
        // was trying to hide.
        #expect(!packet.data.isEmpty)
    }

    @Test("speech produces a substantially larger packet than silence")
    func speechCostsMoreThanSilence() async throws {
        let encoder = SyntheticAudioEncoder()
        try await encoder.encode(
            AudioFrame(
                timestamp: FrameTimestamp(nanoseconds: 0),
                format: .voice,
                samples: samples(peak: 0)
            )
        )
        try await encoder.encode(
            AudioFrame(
                timestamp: FrameTimestamp(nanoseconds: 20_000_000),
                format: .voice,
                samples: samples(peak: 0.8)
            )
        )

        var packets = encoder.encodedFrames().makeAsyncIterator()
        let quiet = try #require(await packets.next())
        let loud = try #require(await packets.next())
        #expect(loud.data.count > quiet.data.count * 4)
    }

    @Test("a closed encoder refuses rather than silently dropping")
    func closedEncoderThrows() async throws {
        let encoder = SyntheticAudioEncoder()
        await encoder.close()
        await #expect(throws: MoqomError.self) {
            try await encoder.encode(
                AudioFrame(
                    timestamp: FrameTimestamp(nanoseconds: 0),
                    format: .voice,
                    samples: self.samples(peak: 0.5)
                )
            )
        }
    }
}

@Suite("Jitter buffer")
struct JitterBufferTests {
    private func packet(
        _ index: UInt64,
        silence: Bool = false
    ) -> EncodedAudioFrame {
        EncodedAudioFrame(
            timestamp: FrameTimestamp(nanoseconds: index * 20_000_000),
            duration: .milliseconds(20),
            data: Data(repeating: UInt8(index & 0xFF), count: silence ? 3 : 60),
            isSilence: silence
        )
    }

    /// Arrival at exactly the packet's own pace: no jitter at all.
    private func arrival(_ index: UInt64) -> Duration {
        .milliseconds(Int(index) * 20)
    }

    @Test("nothing plays until there is enough held to absorb the jitter")
    func fillsBeforePlaying() {
        var buffer = JitterBuffer(minimumDelay: .milliseconds(60))
        #expect(buffer.next() == .buffering)

        buffer.insert(sequence: 0, packet(0), at: arrival(0))
        buffer.insert(sequence: 1, packet(1), at: arrival(1))
        #expect(buffer.next() == .buffering)

        buffer.insert(sequence: 2, packet(2), at: arrival(2))
        guard case .packet = buffer.next() else {
            Issue.record("expected the buffer to start once it was full")
            return
        }
    }

    @Test("packets that arrive out of order are played in order")
    func reordersInFlight() {
        var buffer = JitterBuffer(minimumDelay: .milliseconds(60))
        buffer.insert(sequence: 2, packet(2), at: arrival(2))
        buffer.insert(sequence: 0, packet(0), at: arrival(0))
        buffer.insert(sequence: 1, packet(1), at: arrival(1))

        var played: [UInt8] = []
        for _ in 0 ..< 3 {
            if case let .packet(packet) = buffer.next() {
                played.append(packet.data.first ?? 0xFF)
            }
        }
        #expect(played == [0, 1, 2])
    }

    @Test("a packet that missed its slot is discarded, not played late")
    func latePacketsAreDropped() {
        // Playing it now would put it after audio that has already been heard.
        // The gap it left is the lesser evil, and it has already been concealed.
        var buffer = JitterBuffer(minimumDelay: .milliseconds(20))
        buffer.insert(sequence: 0, packet(0), at: arrival(0))
        buffer.insert(sequence: 1, packet(1), at: arrival(1))
        _ = buffer.next()
        _ = buffer.next()

        buffer.insert(sequence: 0, packet(0), at: .milliseconds(500))
        #expect(buffer.stats.packetsLate == 1)
    }

    @Test("a duplicate is counted and ignored")
    func duplicatesAreIgnored() {
        var buffer = JitterBuffer(minimumDelay: .milliseconds(20))
        buffer.insert(sequence: 5, packet(5), at: arrival(5))
        buffer.insert(sequence: 5, packet(5), at: arrival(5))
        #expect(buffer.stats.packetsDuplicate == 1)
        #expect(buffer.depth == 1)
    }

    @Test("a hole with newer packets behind it is a gap, not a stall")
    func missingPacketBecomesAGap() {
        var buffer = JitterBuffer(minimumDelay: .milliseconds(20))
        buffer.insert(sequence: 0, packet(0), at: arrival(0))
        buffer.insert(sequence: 2, packet(2), at: arrival(2))

        guard case .packet = buffer.next() else {
            Issue.record("expected the first packet")
            return
        }
        #expect(buffer.next() == .gap)
        guard case .packet = buffer.next() else {
            Issue.record("expected the packet after the gap")
            return
        }
        #expect(buffer.stats.gaps == 1)
    }

    @Test("running dry waits rather than concealing audio still in flight")
    func drainingIsNotLoss() {
        // The distinction matters: concealment invents audio. Doing that
        // because the buffer emptied would fabricate sound the sender is about
        // to deliver for real.
        var buffer = JitterBuffer(minimumDelay: .milliseconds(20))
        buffer.insert(sequence: 0, packet(0), at: arrival(0))
        _ = buffer.next()

        #expect(buffer.next() == .buffering)
        #expect(buffer.stats.gaps == 0)
    }

    @Test("silence is played as silence, never as a gap")
    func silenceIsNotAGap() {
        var buffer = JitterBuffer(minimumDelay: .milliseconds(20))
        buffer.insert(sequence: 0, packet(0, silence: true), at: arrival(0))
        #expect(buffer.next() == .silence)
        #expect(buffer.stats.gaps == 0)
    }

    @Test("a jittery link grows the buffer, and a steady one does not")
    func depthFollowsMeasuredJitter() {
        var steady = JitterBuffer(minimumDelay: .milliseconds(20))
        for index in UInt64(0) ..< 50 {
            steady.insert(sequence: index, packet(index), at: arrival(index))
        }
        #expect(steady.stats.targetDelay == .milliseconds(20))

        var jittery = JitterBuffer(minimumDelay: .milliseconds(20))
        for index in UInt64(0) ..< 50 {
            // Alternating early and late by 30ms: the same average rate, a very
            // different delay distribution. A fixed buffer sized for the
            // average loses half of these.
            let wobble = index.isMultiple(of: 2) ? 30 : -30
            jittery.insert(
                sequence: index,
                packet(index),
                at: .milliseconds(Int(index) * 20 + wobble)
            )
        }
        #expect(jittery.stats.targetDelay > .milliseconds(20))
        #expect(jittery.stats.jitter > .zero)
    }

    @Test("the buffer never grows past its ceiling")
    func targetIsClamped() {
        // Past the ceiling, more depth does not save the call: nobody can hold
        // a conversation through half a second of delay, and admitting the link
        // cannot carry it is more useful than hiding it.
        var buffer = JitterBuffer(minimumDelay: .milliseconds(20), maximumDelay: .milliseconds(100))
        for index in UInt64(0) ..< 100 {
            let wobble = index.isMultiple(of: 2) ? 400 : -400
            buffer.insert(
                sequence: index,
                packet(index),
                at: .milliseconds(Int(index) * 20 + wobble)
            )
        }
        #expect(buffer.stats.targetDelay <= .milliseconds(100))
    }

    @Test("a reset forgets a stream that no longer exists")
    func resetClearsEverything() {
        var buffer = JitterBuffer()
        buffer.insert(sequence: 0, packet(0), at: arrival(0))
        buffer.insert(sequence: 1, packet(1), at: arrival(1))
        buffer.reset()
        #expect(buffer.depth == 0)
        #expect(buffer.next() == .buffering)
    }
}

@Suite("Audio publication")
struct AudioPublicationTests {
    @Test("captured audio becomes objects on the audio track")
    func audioReachesTheRelay() async throws {
        let relay = LoopbackRelay()
        let session = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: credentials("alice"),
            tenant: "acme"
        )
        try await session.connect(to: RelayEndpoint(host: "loopback"))
        let room = try await session.join(room: "room-42")

        let source = AudioRelay(depth: 32)
        let publication = try await room.startAudio(
            from: source,
            configuration: AudioPublicationConfiguration(
                encoderFactory: { SyntheticAudioEncoder(configuration: $0) }
            )
        )

        for index in 0 ..< 5 {
            source.submit(
                AudioFrame(
                    timestamp: FrameTimestamp(nanoseconds: UInt64(index) * 20_000_000),
                    format: .voice,
                    samples: tone(0.5)
                )
            )
        }

        #expect(await eventually { await publication.stats.packetsPublished == 5 })

        let objects = await relay.objects(onTrackNamed: "audio")
        #expect(objects.count == 5)

        // Every audio packet is independently decodable, so every one of them
        // is somewhere a subscriber can join. Marking otherwise would make a
        // relay hold audio waiting for a keyframe that never comes.
        #expect(objects.allSatisfy { $0.isKeyFrame })

        // And below every video rung, so a relay under pressure drops pictures
        // before it drops speech.
        #expect(objects.allSatisfy { $0.priority < 64 })
        #expect(objects[2].properties.captureTime?.nanoseconds == 40_000_000)
    }

    @Test("a second of audio fills one group before starting another")
    func groupsAreAFixedSpanOfTime() async throws {
        let relay = LoopbackRelay()
        let session = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: credentials("bob"),
            tenant: "acme"
        )
        try await session.connect(to: RelayEndpoint(host: "loopback"))
        let room = try await session.join(room: "room-42")

        // Four packets to the group, so the boundary lands somewhere countable.
        let source = AudioRelay(depth: 32)
        let publication = try await room.startAudio(
            from: source,
            configuration: AudioPublicationConfiguration(
                groupDuration: .milliseconds(80),
                encoderFactory: { SyntheticAudioEncoder(configuration: $0) }
            )
        )

        for index in 0 ..< 9 {
            source.submit(
                AudioFrame(
                    timestamp: FrameTimestamp(nanoseconds: UInt64(index) * 20_000_000),
                    format: .voice,
                    samples: tone(0.5)
                )
            )
        }

        #expect(await eventually { await publication.stats.packetsPublished == 9 })
        let objects = await relay.objects(onTrackNamed: "audio")
        #expect(objects.map(\.group) == [0, 0, 0, 0, 1, 1, 1, 1, 2])
        #expect(objects.map(\.object) == [0, 1, 2, 3, 0, 1, 2, 3, 0])
    }

    @Test("silence is published, and the speaking flag follows it")
    func speakingFlagTracksTheAudio() async throws {
        let relay = LoopbackRelay()
        let session = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: credentials("carol"),
            tenant: "acme"
        )
        try await session.connect(to: RelayEndpoint(host: "loopback"))
        let room = try await session.join(room: "room-42")

        let source = AudioRelay(depth: 32)
        let publication = try await room.startAudio(
            from: source,
            configuration: AudioPublicationConfiguration(
                encoderFactory: { SyntheticAudioEncoder(configuration: $0) }
            )
        )

        source.submit(
            AudioFrame(
                timestamp: FrameTimestamp(nanoseconds: 0),
                format: .voice,
                samples: Array(repeating: 0, count: 960)
            )
        )
        #expect(await eventually { await publication.stats.packetsPublished == 1 })
        #expect(await publication.stats.isSpeaking == false)

        source.submit(
            AudioFrame(
                timestamp: FrameTimestamp(nanoseconds: 20_000_000),
                format: .voice,
                samples: tone(0.7)
            )
        )
        #expect(await eventually { await publication.stats.isSpeaking })
        #expect(await publication.stats.silentPackets == 1)

        // Silence travels as an object property, not inside the payload. A
        // receiver has to tell it from loss before decoding, and a relay has to
        // tell it without decrypting.
        let objects = await relay.objects(onTrackNamed: "audio")
        #expect(objects.first?.properties.isSilence == true)
        #expect(objects.last?.properties.isSilence != true)
    }
}

@Suite("Audio reception")
struct AudioReceptionTests {
    private func object(sequence: UInt64, isSilence: Bool = false) -> TrackObject {
        TrackObject(
            group: sequence / 50,
            object: sequence % 50,
            priority: 16,
            payload: Data([UInt8(sequence & 0xFF)]),
            isKeyFrame: true,
            properties: ObjectProperties(
                captureTime: FrameTimestamp(nanoseconds: sequence * 20_000_000),
                temporalLayer: 0,
                isSilence: isSilence
            )
        )
    }

    @Test("sequence comes from the timestamp, not from the group arithmetic")
    func sequenceSurvivesAGroupBoundary() {
        // The subscriber does not know the publisher's group size, so
        // `group * size + object` is not available to it. Deriving the sequence
        // from the capture time gives the same answer and keeps giving it if the
        // publisher changes its group size mid-stream.
        var receiver = AudioReceiver()
        for sequence in UInt64(48) ... 52 {
            receiver.accept(object(sequence: sequence), at: .milliseconds(sequence * 20))
        }

        var played: [UInt8] = []
        for _ in 0 ..< 5 {
            if case let .packet(packet) = receiver.next() {
                played.append(packet.data.first ?? 0)
            }
        }
        #expect(played == [48, 49, 50, 51, 52])
    }

    @Test("a packet with no capture time is counted, not guessed at")
    func untimedPacketsAreRefused() {
        var receiver = AudioReceiver()
        let accepted = receiver.accept(
            TrackObject(group: 0, object: 0, payload: Data([1]), isKeyFrame: true),
            at: .zero
        )
        #expect(accepted == false)
        #expect(receiver.packetsWithoutTiming == 1)
    }

    @Test("silence arrives as silence and a hole arrives as a gap")
    func silenceIsNotLoss() {
        var receiver = AudioReceiver()
        receiver.accept(object(sequence: 0), at: .zero)
        receiver.accept(object(sequence: 1, isSilence: true), at: .milliseconds(20))
        receiver.accept(object(sequence: 3), at: .milliseconds(60))

        var outputs: [JitterBufferOutput] = []
        for _ in 0 ..< 4 { outputs.append(receiver.next()) }

        #expect(outputs[1] == .silence)
        #expect(outputs[2] == .gap)
        #expect(receiver.buffer.stats.gaps == 1)
    }

    @Test("a format change starts the buffer over")
    func formatChangeResets() {
        // Sequence numbers are measured in packet durations, so packets held
        // against the old duration are indexed on a scale that no longer
        // applies.
        var receiver = AudioReceiver()
        receiver.accept(object(sequence: 0), at: .zero)
        receiver.setFormat(AudioFormat(sampleRate: 16000, channels: 1))
        #expect(receiver.buffer.depth == 0)
        #expect(receiver.format.sampleRate == 16000)
    }

    @Test("a viewer receives a cohost's audio through the room")
    func audioReachesAViewer() async throws {
        let relay = LoopbackRelay()

        let host = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: credentials("alice"),
            tenant: "acme"
        )
        try await host.connect(to: RelayEndpoint(host: "loopback"))
        let hostRoom = try await host.join(room: "room-42")

        let viewer = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: credentials("bob"),
            tenant: "acme"
        )
        try await viewer.connect(to: RelayEndpoint(host: "loopback"))
        let viewerRoom = try await viewer.join(room: "room-42")

        let source = AudioRelay(depth: 64)
        _ = try await hostRoom.startAudio(
            from: source,
            configuration: AudioPublicationConfiguration(
                encoderFactory: { SyntheticAudioEncoder(configuration: $0) }
            )
        )

        // The subscription is driven by the catalog, not by a layout pass:
        // audio has no render box and there is no size at which a viewer wants
        // to stop hearing someone.
        let who = identity("alice")
        #expect(await eventually { await viewerRoom.audio(from: who) != nil })
        let audio = try #require(await viewerRoom.audio(from: who))

        for index in 0 ..< 8 {
            source.submit(
                AudioFrame(
                    timestamp: FrameTimestamp(nanoseconds: UInt64(index) * 20_000_000),
                    format: .voice,
                    samples: tone(0.5)
                )
            )
        }

        var heard = 0
        for await output in audio {
            if case .packet = output { heard += 1 }
            if heard == 4 { break }
        }
        #expect(heard == 4)
        #expect(await viewerRoom.audioStatistics(for: who)?.packetsLate == 0)
    }

    @Test("muting a cohost for yourself unsubscribes their audio")
    func localMuteUnsubscribes() async throws {
        // The claim per-viewer mute makes is that it is a bandwidth saving
        // rather than a client-side discard. That is only true if the
        // subscription actually goes away.
        let relay = LoopbackRelay()

        let host = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: credentials("carol"),
            tenant: "acme"
        )
        try await host.connect(to: RelayEndpoint(host: "loopback"))
        let hostRoom = try await host.join(room: "room-42")

        let viewer = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: credentials("dave"),
            tenant: "acme"
        )
        try await viewer.connect(to: RelayEndpoint(host: "loopback"))
        let viewerRoom = try await viewer.join(room: "room-42")

        _ = try await hostRoom.startAudio(
            from: AudioRelay(depth: 8),
            configuration: AudioPublicationConfiguration(
                encoderFactory: { SyntheticAudioEncoder(configuration: $0) }
            )
        )

        let who = identity("carol")
        #expect(await eventually { await viewerRoom.audio(from: who) != nil })
        #expect(
            await relay.recorded {
                if case let .subscribed(track, _) = $0 { return track.name.value == "audio" }
                return false
            }
        )

        await viewerRoom.localMute(who, .audio)
        #expect(
            await eventually {
                await relay.recorded {
                    if case let .unsubscribed(track) = $0 { return track.name.value == "audio" }
                    return false
                }
            }
        )

        // And unmuting brings it back, rather than leaving the viewer
        // permanently deaf to someone they silenced once.
        await viewerRoom.localUnmute(who, .audio)
        #expect(
            await eventually {
                let subscribes = await relay.log.filter {
                    if case let .subscribed(track, _) = $0 { return track.name.value == "audio" }
                    return false
                }
                return subscribes.count == 2
            }
        )
    }
}

// MARK: - Playback

// The decoder's loss handling, through the PCM path.
//
// The PCM path for the loss cases, because the part with judgement in it is what
// happens when nothing arrived and that is codec-independent. Opus is exercised
// separately below and needs to be: "enough" was the belief that let a decoder
// which produced samples for exactly one packet per call ship, because the only
// path under test was the one that never touches the converter.
#if canImport(AudioToolbox)
    @Suite("Audio playback")
    struct PlaybackTests {
        private func pcm(_ samples: [Float]) -> Data {
            var data = Data()
            for sample in samples {
                let value = Int16(max(-1, min(1, sample)) * Float(Int16.max))
                withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
            }
            return data
        }

        private func packet(_ samples: [Float]) -> JitterBufferOutput {
            .packet(
                EncodedAudioFrame(
                    timestamp: FrameTimestamp(nanoseconds: 0),
                    duration: .milliseconds(20),
                    data: pcm(samples)
                )
            )
        }

        /// The bug this exists for: audio that arrived, decoded without error, and was silent.
        ///
        /// One packet is not a test of a decoder. The converter is asked to fill a frame count,
        /// so it calls back for more input after taking the packet it was given, and the answer
        /// to that second call decides whether the decoder survives — "no more now" and it does,
        /// "end of stream" and it returns zero frames for every packet for the rest of the call.
        /// Both answers report `noErr`. On a call it presented as every counter healthy, the
        /// speaking indicators lighting up, and nothing audible.
        @Test("a decoder keeps decoding after the first packet")
        func opusKeepsGoing() async throws {
            let encoder = try PlatformAudioEncoder(
                configuration: AudioEncoderConfiguration(format: .voice, codec: .opus)
            )
            let decoder = try PlatformAudioDecoder(format: .voice, codec: .opus)

            for index in 0 ..< 5 {
                try await encoder.encode(
                    AudioFrame(
                        timestamp: FrameTimestamp(nanoseconds: UInt64(index) * 20_000_000),
                        format: .voice,
                        samples: tone(0.6)
                    )
                )
            }

            var packets = encoder.encodedFrames().makeAsyncIterator()
            for index in 0 ..< 5 {
                let encoded = try #require(await packets.next())
                let decoded = await decoder.decode(.packet(encoded))

                // The first packet comes back short by Opus's priming delay — 120 samples of
                // pre-skip at 48kHz, which the codec swallows before it can produce anything.
                // Every packet after it is a full slot, and every one of them carries the tone.
                if index == 0 {
                    #expect(decoded.count > 0)
                    continue
                }
                #expect(decoded.count == AudioFormat.voice.samplesPerFrame)
                #expect(decoded.contains { $0 != 0 }, "packet \(index) decoded to silence")
            }
        }

        @Test("a packet round-trips through the PCM path")
        func roundTrip() async throws {
            let decoder = try PlatformAudioDecoder(format: .voice, codec: .pcm)
            let samples = [Float](repeating: 0.5, count: 960)
            let decoded = await decoder.decode(packet(samples))

            #expect(decoded.count == 960)
            // 16-bit quantisation, so not exact.
            #expect(abs(decoded[0] - 0.5) < 0.001)
        }

        @Test("every slot produces a slot's worth of samples")
        func everySlotIsFull() async throws {
            let decoder = try PlatformAudioDecoder(format: .voice, codec: .pcm)
            let expected = AudioFormat.voice.samplesPerFrame

            // The audio device needs a buffer per slot whatever happened on the
            // network. A short answer here is a click.
            for output in [JitterBufferOutput.silence, .gap, .buffering] {
                #expect(await decoder.decode(output).count == expected)
            }
        }

        @Test("silence is zero and a gap is a fade")
        func silenceIsNotConcealment() async throws {
            let decoder = try PlatformAudioDecoder(format: .voice, codec: .pcm)
            _ = await decoder.decode(packet([Float](repeating: 0.8, count: 960)))

            // Silence was meant, so it is reproduced exactly. Fading into it
            // would sound like the line dropping rather than someone stopping.
            let quiet = await decoder.decode(.silence)
            #expect(quiet.allSatisfy { $0 == 0 })

            // A gap was not meant, and the previous packet decays into it.
            _ = await decoder.decode(packet([Float](repeating: 0.8, count: 960)))
            let concealed = await decoder.decode(.gap)
            #expect(concealed[0] > 0)
            #expect(concealed[0] < 0.8)
            #expect(concealed[959] < concealed[0])
        }

        @Test("a gap with nothing behind it is silence, not noise")
        func gapWithNoHistory() async throws {
            let decoder = try PlatformAudioDecoder(format: .voice, codec: .pcm)
            let concealed = await decoder.decode(.gap)
            #expect(concealed.allSatisfy { $0 == 0 })
        }

        @Test("concealment decays rather than repeating")
        func concealmentDecays() async throws {
            let decoder = try PlatformAudioDecoder(format: .voice, codec: .pcm)
            _ = await decoder.decode(packet([Float](repeating: 0.8, count: 960)))

            // A repeated packet is a buzz at the packet rate, which is more
            // noticeable than the level dropping away.
            var peak = Float(1)
            for _ in 0 ..< 4 {
                let concealed = await decoder.decode(.gap)
                let next = concealed.map(abs).max() ?? 0
                #expect(next < peak)
                peak = next
            }
            #expect(peak < 0.1)
        }
    }
#endif
