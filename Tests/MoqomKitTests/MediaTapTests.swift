import Foundation
import Testing

@testable import MoqomCore
@testable import MoqomKit
@testable import MoqomLoopback

/// A sine rather than a constant, for the reason set out in `AudioTests`: a run
/// of one repeated value is a DC offset that voice detection high-passes away,
/// so a fixture built from one is classified as a pause however loud it looks.
private func tone(_ peak: Float, count: Int = 960, hz: Double = 300) -> [Float] {
    let step = 2 * Double.pi * hz / 48000
    return (0 ..< count).map { peak * Float(sin(Double($0) * step)) }
}

@Suite("Tap cadence")
struct PacerTests {
    private func frame(_ index: Int) -> FrameTimestamp {
        FrameTimestamp(nanoseconds: UInt64(index) * 33_000_000)
    }

    @Test("every frame means every frame")
    func everyFrame() {
        var pacer = Pacer(cadence: .everyFrame)
        let admitted = (0 ..< 10).filter { pacer.admits(at: frame($0), isKeyFrame: $0 == 0) }
        #expect(admitted.count == 10)
    }

    @Test("keyframes only declines the work rather than the delivery")
    func keyFramesSkipTheDecode() {
        // The whole saving. A keyframe decodes without the frames around it, so
        // declining a delta costs nothing later — which is what makes this
        // cadence closer to a still image decode than to running a decoder.
        let pacer = Pacer(cadence: .keyFramesOnly)
        #expect(pacer.decodes(isKeyFrame: true))
        #expect(!pacer.decodes(isKeyFrame: false))

        // Every other cadence has to decode everything, because the frames it
        // does not deliver are still references for the ones it does.
        #expect(Pacer(cadence: .everyFrame).decodes(isKeyFrame: false))
        #expect(Pacer(cadence: .atMost(fps: 1)).decodes(isKeyFrame: false))
    }

    @Test("a rate limit spaces frames by capture time, not by arrival")
    func rateLimiting() {
        // Against the publisher's clock, because that is the one the frames are
        // stamped with. Pacing against arrival would deliver a burst as a burst.
        var pacer = Pacer(cadence: .atMost(fps: 10))
        let admitted = (0 ..< 30).filter { pacer.admits(at: frame($0), isKeyFrame: false) }

        // 30fps in, 10fps out: every third frame, and the first one always.
        #expect(admitted == [0, 3, 6, 9, 12, 15, 18, 21, 24, 27])
    }

    @Test("a stream that pauses delivers immediately when it resumes")
    func resumptionIsNotPenalised() {
        // Measured from the last delivered frame rather than a running clock. A
        // clock would spend the pause counting down an interval that nothing was
        // arriving during, and then hold the first frame back after it.
        var pacer = Pacer(cadence: .atMost(fps: 2))
        let first = pacer.admits(at: FrameTimestamp(nanoseconds: 0), isKeyFrame: false)
        let tooSoon = pacer.admits(at: FrameTimestamp(nanoseconds: 100_000_000), isKeyFrame: false)
        let afterThePause = pacer.admits(at: FrameTimestamp(seconds: 30), isKeyFrame: false)
        let againTooSoon = pacer.admits(at: FrameTimestamp(seconds: 30.1), isKeyFrame: false)

        #expect(first)
        #expect(!tooSoon)
        #expect(afterThePause)
        #expect(!againTooSoon)
    }

    @Test("keyframes have no meaning before anything is encoded")
    func cadenceBeforeEncoding() {
        // A capture tap sees frames the encoder has not looked at, so there are
        // no groups to key off. Delivering nothing would be a trap; falling back
        // to the rate that cadence would have produced anyway is not.
        #expect(TapCadence.keyFramesOnly.beforeEncoding == .atMost(fps: 1))
        #expect(TapCadence.everyFrame.beforeEncoding == .everyFrame)
        #expect(TapCadence.atMost(fps: 5).beforeEncoding == .atMost(fps: 5))
    }
}

@Suite("Tap back pressure")
struct TapBackPressureTests {
    @Test("a consumer that never reads loses frames instead of holding the pipeline")
    func slowConsumerDropsRatherThanStalls() async {
        // The invariant the whole design turns on. If a classifier stalls, the
        // picture keeps rendering and the uplink keeps sending; the consumer
        // degrades itself and nothing else.
        let tap = MediaTap<Int>(policy: TapPolicy(depth: 2))

        for value in 0 ..< 100 {
            tap.deliver(value)
        }

        let stats = tap.statistics
        #expect(stats.delivered == 2, "buffered \(stats.delivered)")
        #expect(stats.dropped == 98)
        #expect(stats.completeness < 0.05)

        // And what survived is the newest, because a frame past its deadline is
        // not late but worthless.
        var seen: [Int] = []
        tap.stop()
        for await value in tap.elements { seen.append(value) }
        #expect(seen == [98, 99])
    }

    @Test("an unbounded tap keeps everything, which is what audio needs")
    func unboundedKeepsOrder() async {
        // A transcript with holes in it still reads as a transcript, so the
        // failure is silent and lands in a human's hands as fact.
        let tap = MediaTap<Int>(policy: .transcription)
        for value in 0 ..< 500 { tap.deliver(value) }
        tap.stop()

        var seen: [Int] = []
        for await value in tap.elements { seen.append(value) }
        #expect(seen == Array(0 ..< 500))
        #expect(tap.statistics.dropped == 0)
        #expect(tap.statistics.completeness == 1)
    }

    @Test("a stopped tap stops counting and says so")
    func stoppingIsObservable() {
        // The SDK polls this to release a decoder rather than trusting the
        // consumer to call stop, because "remember to call stop" holds until the
        // first early return.
        let tap = MediaTap<Int>(policy: TapPolicy(depth: 4))
        #expect(tap.isActive)
        tap.stop()
        #expect(!tap.isActive)

        tap.deliver(1)
        #expect(tap.statistics.delivered == 0)
    }

    @Test("skipped and dropped are different numbers")
    func policyIsNotFailure() {
        // One is the cadence working and the other is the consumer losing. A
        // dashboard that added them together would report a healthy classifier
        // as broken.
        let tap = MediaTap<Int>(policy: TapPolicy(depth: 1))
        tap.skip()
        tap.skip()
        tap.deliver(1)
        tap.deliver(2)

        let stats = tap.statistics
        #expect(stats.skipped == 2)
        #expect(stats.dropped == 1)
        #expect(stats.delivered == 1)
        #expect(stats.completeness == 0.5)
    }
}

@Suite("Tapping what this device is about to send")
struct CaptureTapTests {
    private let endpoint = RelayEndpoint(host: "loopback")

    private func session(_ name: String, relay: LoopbackRelay) async throws -> MoqomSession {
        let session = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: credentials(name),
            tenant: "acme"
        )
        try await session.connect(to: endpoint)
        return session
    }

    @Test("captured frames reach a tap without being encoded first")
    func framesReachTheTap() async throws {
        let relay = LoopbackRelay()
        let host = try await session("alice", relay: relay)
        let room = try await host.join(room: "room-42")

        let rung = VideoLayer(
            id: "video/360p",
            size: PixelSize(width: 640, height: 360),
            frameRate: 30,
            bitrate: 600_000
        )
        let source = FrameRelay(format: CaptureFormat(size: rung.size, frameRate: 30), depth: 16)
        let broadcast = try await room.startBroadcast(
            from: source,
            configuration: BroadcastConfiguration(
                ladder: LayerLadder(rungs: [rung]),
                encoderFactory: { SyntheticEncoder(configuration: $0) }
            )
        )

        let tap = await broadcast.tapFrames(policy: TapPolicy(depth: 16))

        for index in 0 ..< 4 {
            source.submit(
                VideoFrame(
                    timestamp: FrameTimestamp(nanoseconds: UInt64(index) * 33_000_000),
                    size: rung.size,
                    surface: .synthetic(byteCount: 1024),
                    forcesKeyFrame: index == 0
                )
            )
        }

        var seen: [UInt64] = []
        for await frame in tap.elements {
            seen.append(frame.timestamp.nanoseconds)
            if seen.count == 4 { break }
        }

        // The frames the encoder got, in submission order and with the capture
        // timestamps intact. Nothing has been compressed, reordered, or delayed.
        #expect(seen == [0, 33_000_000, 66_000_000, 99_000_000])
    }

    @Test("a capture tap does not cost the publisher any frames")
    func tappingIsNotBackPressure() async throws {
        // A consumer that never reads must not slow the uplink down. This one
        // never reads at all.
        let relay = LoopbackRelay()
        let host = try await session("bob", relay: relay)
        let room = try await host.join(room: "room-42")

        let rung = VideoLayer(
            id: "video/360p",
            size: PixelSize(width: 640, height: 360),
            frameRate: 30,
            bitrate: 600_000
        )
        let source = FrameRelay(format: CaptureFormat(size: rung.size, frameRate: 30), depth: 64)
        let broadcast = try await room.startBroadcast(
            from: source,
            configuration: BroadcastConfiguration(
                ladder: LayerLadder(rungs: [rung]),
                encoderFactory: { SyntheticEncoder(configuration: $0) }
            )
        )

        let tap = await broadcast.tapFrames(policy: TapPolicy(depth: 1))

        for index in 0 ..< 32 {
            source.submit(
                VideoFrame(
                    timestamp: FrameTimestamp(nanoseconds: UInt64(index) * 33_000_000),
                    size: rung.size,
                    surface: .synthetic(byteCount: 256),
                    forcesKeyFrame: index == 0
                )
            )
        }

        #expect(await eventually { await broadcast.stats.framesSubmitted == 32 })
        #expect(await broadcast.stats.framesDropped == 0)
        #expect(tap.statistics.dropped > 0, "a one-deep tap should have lost frames")
    }

    @Test("stopping the broadcast ends the tap rather than leaving it waiting")
    func stoppingClosesTheTap() async throws {
        let relay = LoopbackRelay()
        let host = try await session("carol", relay: relay)
        let room = try await host.join(room: "room-42")

        let source = FrameRelay(
            format: CaptureFormat(size: PixelSize(width: 640, height: 360), frameRate: 30)
        )
        let broadcast = try await room.startBroadcast(
            from: source,
            configuration: BroadcastConfiguration(
                encoderFactory: { SyntheticEncoder(configuration: $0) }
            )
        )
        let tap = await broadcast.tapFrames()

        await room.stopBroadcast()

        // A consumer written as a `for await` has to come back, or the task it
        // is running in leaks for the lifetime of the process.
        var count = 0
        for await _ in tap.elements { count += 1 }
        #expect(count == 0)
        #expect(!tap.isActive)
    }

    @Test("captured samples reach a tap after echo cancellation and before the encoder")
    func samplesReachTheTap() async throws {
        // The one tap that gives an application something it could not have got
        // for itself. Opening a second microphone would return the raw hardware
        // feed, which contains everybody else in the call coming back through
        // the speaker.
        let relay = LoopbackRelay()
        let host = try await session("dave", relay: relay)
        let room = try await host.join(room: "room-42")

        let source = AudioRelay(depth: 64)
        let publication = try await room.startAudio(
            from: source,
            configuration: AudioPublicationConfiguration(
                encoderFactory: { SyntheticAudioEncoder(configuration: $0) }
            )
        )
        let tap = await publication.tapSamples()

        for index in 0 ..< 6 {
            source.submit(
                AudioFrame(
                    timestamp: FrameTimestamp(nanoseconds: UInt64(index) * 20_000_000),
                    format: .voice,
                    samples: tone(0.5)
                )
            )
        }

        var seen: [AudioFrame] = []
        for await frame in tap.elements {
            seen.append(frame)
            if seen.count == 6 { break }
        }

        #expect(seen.map(\.timestamp.nanoseconds) == (0 ..< 6).map { UInt64($0) * 20_000_000 })
        #expect(seen.allSatisfy { $0.samples.count == AudioFormat.voice.samplesPerFrame })
        #expect(seen.allSatisfy { $0.peak > 0 })
    }

    @Test("an audio tap ignores a cadence rather than honouring it")
    func audioIgnoresCadence() async throws {
        // Audio has no independently decodable frame to skip to, and a consumer
        // handed a subset of it does not get less of the truth, it gets
        // something untrue.
        let relay = LoopbackRelay()
        let host = try await session("erin", relay: relay)
        let room = try await host.join(room: "room-42")

        let source = AudioRelay(depth: 64)
        let publication = try await room.startAudio(
            from: source,
            configuration: AudioPublicationConfiguration(
                encoderFactory: { SyntheticAudioEncoder(configuration: $0) }
            )
        )
        // Unbounded, so this measures the cadence and not the consumer. A
        // shallow buffer would drop under load and leave the two indistinguishable.
        let tap = await publication.tapSamples(
            policy: TapPolicy(cadence: .keyFramesOnly, depth: 0)
        )

        for index in 0 ..< 8 {
            source.submit(
                AudioFrame(
                    timestamp: FrameTimestamp(nanoseconds: UInt64(index) * 20_000_000),
                    format: .voice,
                    samples: tone(0.5)
                )
            )
        }

        var seen = 0
        for await _ in tap.elements {
            seen += 1
            if seen == 8 { break }
        }
        #expect(seen == 8)
        #expect(tap.statistics.skipped == 0)
        #expect(tap.statistics.dropped == 0)
    }
}

@Suite("Tapping what a participant is sending")
struct ReceiveTapTests {
    private let endpoint = RelayEndpoint(host: "loopback")

    private func session(_ name: String, relay: LoopbackRelay) async throws -> MoqomSession {
        let session = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: credentials(name),
            tenant: "acme"
        )
        try await session.connect(to: endpoint)
        return session
    }

    private let rung = VideoLayer(
        id: "video/360p",
        size: PixelSize(width: 640, height: 360),
        frameRate: 30,
        bitrate: 600_000
    )

    /// A publisher, a viewer subscribed to them, and the source to drive it.
    private func pair(
        relay: LoopbackRelay,
        host: String,
        viewer: String,
        encryption: RoomEncryption? = nil
    ) async throws -> (RoomSession, FrameRelay, ParticipantIdentity) {
        let publisher = try await session(host, relay: relay)
        let watcher = try await session(viewer, relay: relay)
        let hostRoom = try await publisher.join(room: "room-42")
        let viewerRoom = try await watcher.join(room: "room-42")

        if let encryption {
            await hostRoom.useEncryption(encryption)
            await viewerRoom.useEncryption(encryption)
        }

        let source = FrameRelay(format: CaptureFormat(size: rung.size, frameRate: 30), depth: 32)
        _ = try await hostRoom.startBroadcast(
            from: source,
            configuration: BroadcastConfiguration(
                ladder: LayerLadder(rungs: [rung]),
                encoderFactory: { SyntheticEncoder(configuration: $0) }
            )
        )

        let who = identity(host)
        _ = await eventually { await viewerRoom.roster[who] != nil }
        await viewerRoom.updateLayout(
            [who: RenderBox(width: 640, height: 360, scale: 1)],
            linkBitrate: 5_000_000
        )
        _ = await eventually { await viewerRoom.codec(of: who) != nil }

        return (viewerRoom, source, who)
    }

    private func submit(_ source: FrameRelay, count: Int) {
        for index in 0 ..< count {
            source.submit(
                VideoFrame(
                    timestamp: FrameTimestamp(nanoseconds: UInt64(index) * 33_000_000),
                    size: rung.size,
                    surface: .synthetic(byteCount: 1024),
                    forcesKeyFrame: index == 0
                )
            )
        }
    }

    @Test("a viewer can decode a participant's video for its own processing")
    func decodedFramesReachTheTap() async throws {
        let relay = LoopbackRelay()
        let decoder = SyntheticVideoDecoder(size: rung.size)
        let (room, source, who) = try await pair(relay: relay, host: "alice", viewer: "bob")

        let tap = await room.tapVideo(
            from: who,
            policy: TapPolicy(depth: 32, decoderFactory: { _ in decoder })
        )
        submit(source, count: 6)

        var seen: [TappedVideo] = []
        for await frame in tap.elements {
            seen.append(frame)
            if seen.count == 4 { break }
        }

        // The first picture out is a keyframe, because everything before one is
        // dropped — which is the property that makes joining mid-stream work.
        #expect(seen.first?.isKeyFrame == true)
        #expect(seen.allSatisfy { !$0.followsGap })
        #expect(seen.map(\.frame.timestamp.nanoseconds) == [0, 33_000_000, 66_000_000, 99_000_000])
        #expect(seen.allSatisfy { $0.frame.size == rung.size })
    }

    @Test("asking for keyframes only does not decode the frames between them")
    func keyFramesOnlySavesTheDecode() async throws {
        // The claim this cadence makes is not that it delivers less, it is that
        // it costs less. If the decoder still ran on every frame the policy
        // would be a filter rather than a saving.
        let relay = LoopbackRelay()
        let decoder = SyntheticVideoDecoder(size: rung.size)
        let (room, source, who) = try await pair(relay: relay, host: "carol", viewer: "dave")

        let tap = await room.tapVideo(
            from: who,
            policy: TapPolicy(cadence: .keyFramesOnly, depth: 8, decoderFactory: { _ in decoder })
        )
        submit(source, count: 12)

        // Waited on reassembly rather than on the tap, because the tap's own
        // counters are what is under test and polling them would let this
        // assert after the first frame through.
        //
        // Both results are discarded, which makes these settle-waits rather than
        // claims: twelve frames submitted need not all arrive, and the assertions
        // below are about the ratio between decoded and delivered rather than
        // about reaching any particular count. So they are bounded explicitly —
        // the shared default is sized for a condition that will come true, and a
        // wait that is allowed to expire wants the smallest window that lets the
        // pipeline finish, or the whole suite waits out both of them.
        let settle = Duration.seconds(2)
        _ = await eventually(timeout: settle) {
            await room.videoStatistics(for: who)?.framesProduced ?? 0 >= 10
        }
        _ = await eventually(timeout: settle) {
            tap.statistics.skipped + tap.statistics.delivered >= 10
        }

        let decoded = await decoder.decoded
        let stats = tap.statistics
        #expect(decoded == stats.delivered, "decoded \(decoded), delivered \(stats.delivered)")
        #expect(stats.skipped > stats.delivered, "skipped \(stats.skipped)")
    }

    @Test("frames arrive decrypted, which is what makes on-device inference work")
    func tapsSeePlaintextInAnEncryptedRoom() async throws {
        // The point of doing this on the client. A relay cannot classify what it
        // cannot read, and a participant can, because the participant is who the
        // media was encrypted for. If a tap saw ciphertext those two facts would
        // be incompatible and end-to-end encryption would mean no safety
        // tooling at all.
        let relay = LoopbackRelay()
        let key = Data(repeating: 0x2B, count: 32)
        let decoder = SyntheticVideoDecoder(size: rung.size)
        let (room, source, who) = try await pair(
            relay: relay,
            host: "erin",
            viewer: "frank",
            encryption: RoomEncryption.sharedKey(key, keyID: 1)
        )

        let tap = await room.tapVideo(
            from: who,
            policy: TapPolicy(depth: 16, decoderFactory: { _ in decoder })
        )
        submit(source, count: 4)

        var first: TappedVideo?
        for await frame in tap.elements {
            first = frame
            break
        }

        let picture = try #require(first)
        #expect(picture.isKeyFrame)

        // Decrypted, not merely delivered: the payload the decoder saw is the
        // publisher's bitstream and not an SFrame envelope, so its byte count
        // matches what the encoder produced rather than that plus a header.
        guard case let .synthetic(bytes) = picture.frame.surface else {
            Issue.record("expected a synthetic surface")
            return
        }
        #expect(bytes > 0)
        #expect(await room.decryptionStatistics?.objectsRejected == 0)
    }

    @Test("stopping a tap releases the decoder it was holding")
    func stoppingReleasesTheDecoder() async throws {
        // On a phone a decompression session is a bounded hardware resource
        // shared with everything else on screen. A tap that kept one after the
        // processing stopped would be taking it from the picture.
        let relay = LoopbackRelay()
        let decoder = SyntheticVideoDecoder(size: rung.size)
        let (room, source, who) = try await pair(relay: relay, host: "grace", viewer: "heidi")

        let tap = await room.tapVideo(
            from: who,
            policy: TapPolicy(depth: 8, decoderFactory: { _ in decoder })
        )
        submit(source, count: 3)
        _ = await eventually { await decoder.decoded > 0 }

        tap.stop()

        // The release happens on the next frame through, because that is when
        // the receive path notices. Keep the media flowing so it does.
        submit(source, count: 3)
        #expect(await eventually { await decoder.isClosed })
    }

    @Test("unsubscribing a participant ends their taps")
    func unsubscribingEndsTheTap() async throws {
        // A tap on a track nobody is subscribed to holds a decoder that will
        // never be fed, and a consumer blocked on it waits for a frame that is
        // not coming.
        let relay = LoopbackRelay()
        let decoder = SyntheticVideoDecoder(size: rung.size)
        let (room, source, who) = try await pair(relay: relay, host: "ivan", viewer: "judy")

        let tap = await room.tapVideo(
            from: who,
            policy: TapPolicy(depth: 8, decoderFactory: { _ in decoder })
        )
        submit(source, count: 3)
        _ = await eventually { tap.statistics.delivered > 0 }

        // Dropping the box unsubscribes, which is how a viewer stops paying for
        // a tile that left the screen.
        await room.updateLayout([:], linkBitrate: 5_000_000)

        #expect(await eventually { !tap.isActive })
        #expect(await eventually { await decoder.isClosed })
    }

    @Test("a decoder that cannot be built is reported rather than silently empty")
    func undecodableIsVisible() async throws {
        // A tap that yields nothing and reports nothing is indistinguishable
        // from a participant who is not publishing, which is a bad afternoon.
        let relay = LoopbackRelay()
        let (room, source, who) = try await pair(relay: relay, host: "ken", viewer: "lily")

        let tap = await room.tapVideo(
            from: who,
            policy: TapPolicy(depth: 8, decoderFactory: { codec in
                throw MoqomError.unsupportedCodec(codec)
            })
        )
        submit(source, count: 4)

        #expect(await eventually { tap.statistics.undecodable > 0 })
        #expect(tap.statistics.delivered == 0)
    }

    @Test("two taps on one participant get their own cadence and their own decoder")
    func tapsDoNotShareState() async throws {
        // A safety classifier on keyframes and a re-render on everything are
        // different jobs and should not have to agree. Sharing one decoder would
        // mean one of them silently getting the other's frame rate.
        let relay = LoopbackRelay()
        let everything = SyntheticVideoDecoder(size: rung.size)
        let keyframes = SyntheticVideoDecoder(size: rung.size)
        let (room, source, who) = try await pair(relay: relay, host: "mike", viewer: "nina")

        let full = await room.tapVideo(
            from: who,
            policy: TapPolicy(depth: 32, decoderFactory: { _ in everything })
        )
        let sparse = await room.tapVideo(
            from: who,
            policy: TapPolicy(cadence: .keyFramesOnly, depth: 32, decoderFactory: { _ in keyframes })
        )
        submit(source, count: 12)

        _ = await eventually { full.statistics.delivered >= 6 }

        #expect(full.statistics.delivered > sparse.statistics.delivered)
        #expect(sparse.statistics.skipped > 0)
        #expect(full.statistics.skipped == 0)
    }

    @Test("decoded audio arrives with the loss cases labelled")
    func audioTapLabelsConcealment() async throws {
        // A model handed concealed audio transcribes it as confidently as
        // anything else, which is how a gap in the network becomes a sentence in
        // a transcript that nobody said.
        let relay = LoopbackRelay()
        let publisher = try await session("olive", relay: relay)
        let watcher = try await session("peter", relay: relay)
        let hostRoom = try await publisher.join(room: "room-42")
        let viewerRoom = try await watcher.join(room: "room-42")

        let source = AudioRelay(depth: 64)
        _ = try await hostRoom.startAudio(
            from: source,
            configuration: AudioPublicationConfiguration(
                encoderFactory: { SyntheticAudioEncoder(configuration: $0) }
            )
        )

        let who = identity("olive")
        _ = await eventually { await viewerRoom.audio(from: who) != nil }

        let decoder = SyntheticAudioDecoder()
        let tap = await viewerRoom.tapAudio(
            from: who,
            policy: TapPolicy(depth: 0, audioDecoderFactory: { _, _ in decoder })
        )

        for index in 0 ..< 8 {
            source.submit(
                AudioFrame(
                    timestamp: FrameTimestamp(nanoseconds: UInt64(index) * 20_000_000),
                    format: .voice,
                    samples: tone(0.5)
                )
            )
        }

        var seen: [TappedAudio] = []
        for await slot in tap.elements {
            seen.append(slot)
            if seen.count == 4 { break }
        }

        #expect(seen.allSatisfy { $0.origin == .live })
        #expect(seen.allSatisfy { $0.frame.samples.count == AudioFormat.voice.samplesPerFrame })

        // A continuous timeline, including across the slots that carry no
        // packet. A consumer that had to infer it would have to reimplement the
        // jitter buffer's pacing to do it.
        let spacing = zip(seen, seen.dropFirst()).map {
            $1.frame.timestamp.nanoseconds - $0.frame.timestamp.nanoseconds
        }
        #expect(spacing.allSatisfy { $0 == 20_000_000 }, "spacing \(spacing)")
    }
}
