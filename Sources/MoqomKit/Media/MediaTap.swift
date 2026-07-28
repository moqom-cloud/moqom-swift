// Raw media, on its way out of the SDK.
//
// Everything else in this SDK moves media between two points it owns: a camera
// to an encoder, a subscription to a display layer. A tap is the deliberate
// exception — it hands frames to somebody whose processing we know nothing
// about, which makes it the one place where the interesting questions are about
// what happens when that somebody is slow, or wrong, or malicious.
//
// # A tap can never be back pressure
//
// The rule the whole design turns on: a slow consumer must degrade itself and
// nothing else. If a transcriber stalls, the microphone keeps capturing and the
// uplink keeps sending; if a classifier stalls, the picture keeps rendering. So
// every tap is a bounded buffer that drops rather than a channel that waits, and
// the drops are counted so the consumer can find out it is losing rather than
// quietly missing half of what it thinks it is seeing.
//
// This is why a tap is not simply "give me the AsyncStream you already have".
// The SDK's internal streams are single-consumer and load-bearing: handing one
// out would mean a tap and a renderer splitting frames between them, which
// presents as a video that runs at half speed for reasons nobody can find.
//
// # Decoding costs real money, so it is asked for rather than assumed
//
// Outbound taps are nearly free: those frames already exist in the shape a
// consumer wants, because that is the shape the encoder was about to take.
//
// Inbound taps are not. The receive path never decodes — `AVSampleBufferDisplayLayer`
// decodes internally and gives nothing back — so a tap on a remote participant
// starts a decompression session that would not otherwise exist, and on a phone
// those are a bounded hardware resource shared with everything else on screen.
// Nothing here starts one until it is asked to, and ``TapCadence/keyFramesOnly``
// exists because most of what people want this for does not need more.
//
// # Where this sits relative to encryption
//
// After decryption, always, on the device that is entitled to the plaintext.
// That ordering is what makes on-device inference the answer to the end-to-end
// encryption problem rather than a casualty of it: a relay cannot classify what
// it cannot read, and a client can, because the client is the recipient. Nothing
// in this file weakens that — a tap is available exactly to the participants who
// could already see and hear the media with their own eyes and ears.
//
// What it does do is put that media somewhere the SDK can no longer account for,
// which is a product and legal question rather than an engineering one. See
// ``Watchdog`` for the disclosure mechanism, and the note on ``MediaTap`` for why
// the SDK cannot make that call on an integrator's behalf.

import Foundation
import MoqomCore

/// How often a video tap wants a frame.
///
/// Rate, not quality. A tap that asks for less does not get worse pixels, it
/// gets fewer of them — which is what almost every consumer of this actually
/// wants, because inference at thirty frames a second is thirty times the cost
/// of inference at one and rarely thirty times the answer.
public enum TapCadence: Hashable, Sendable {
    /// Everything. For a re-render, a compositor, or a recorder.
    case everyFrame

    /// Only frames that start a group.
    ///
    /// The cheapest useful mode by a wide margin, and the reason is structural:
    /// a keyframe is independently decodable, so this decodes standalone
    /// pictures rather than maintaining a reference chain. At a two-second
    /// keyframe interval that is a picture every two seconds for roughly the
    /// cost of a still image decode.
    ///
    /// Which makes it the right default for the classification jobs people
    /// reach for first — nudity, scene, presence, brand safety. None of them
    /// change their answer within a group, and asking for every frame to run
    /// them is paying thirty times over for the same verdict.
    case keyFramesOnly

    /// At most this many frames a second, evenly spaced.
    ///
    /// Costs a full decode of everything regardless, because the frames not
    /// delivered are still references the delivered ones need. Use it when the
    /// consumer needs arbitrary frames rather than group boundaries — motion,
    /// gesture, gaze — and accept that the saving is in the consumer rather
    /// than in the decoder.
    ///
    /// Delivers the frame nearest each target time rather than the first one
    /// past it, which is the difference between asking for ten a second from a
    /// thirty a second source and getting ten rather than seven and a half.
    case atMost(fps: Double)

    /// What this cadence means where nothing has been encoded yet.
    ///
    /// The capture path has no groups and no keyframes — those are decisions the
    /// encoder has not made at the point a capture tap sees the frame. Rather
    /// than deliver nothing there, ``keyFramesOnly`` becomes the rate it would
    /// have produced anyway at a typical keyframe interval.
    var beforeEncoding: TapCadence {
        self == .keyFramesOnly ? .atMost(fps: 1) : self
    }
}

/// Where a tapped audio slot came from.
///
/// The distinction a transcriber has to respect. Concealed audio is invented by
/// the decoder to cover a hole, and a model handed it will transcribe it as
/// confidently as anything else — which is how a gap in the network becomes a
/// sentence in a transcript that nobody said.
public enum AudioOrigin: Hashable, Sendable {
    /// A packet that arrived.
    case live

    /// Nothing arrived and the decoder invented something.
    case concealed

    /// The publisher sent nothing because there was nothing to send.
    case silence
}

/// One decoded picture from a remote participant.
public struct TappedVideo: Sendable {
    public let frame: VideoFrame

    /// Whether this picture began a group.
    public let isKeyFrame: Bool

    /// Objects were lost between the previous picture and this one.
    ///
    /// Carried rather than hidden because it changes what the content means. A
    /// frame decoded immediately after a hole is built partly from references
    /// that never arrived, so a classifier looking at it is looking at
    /// something that was never on anybody's screen.
    public let followsGap: Bool
}

/// One decoded audio slot from a remote participant.
public struct TappedAudio: Sendable {
    public let frame: AudioFrame
    public let origin: AudioOrigin
}

/// How a tap behaves under pressure.
public struct TapPolicy: Sendable {
    /// How often to deliver.
    ///
    /// Ignored for audio taps, and deliberately so: audio has no independently
    /// decodable frame to skip to, and a transcriber handed every third packet
    /// does not produce a third of a transcript, it produces nonsense.
    public var cadence: TapCadence

    /// How many elements may queue before the oldest is dropped.
    ///
    /// Zero or less means unbounded, which is the right answer for audio and
    /// the wrong one for video. Audio is small, ordered, and useless with holes
    /// in it; video is large enough that a stalled consumer holding a backlog of
    /// pixel buffers will exhaust the pool the capture path is drawing from.
    public var depth: Int

    /// Where the video decoder comes from.
    ///
    /// Overriding this is how you bring your own — a software AV1, a decoder
    /// that writes into a texture you own, or a synthetic one for tests. Mirrors
    /// ``BroadcastConfiguration/encoderFactory`` on the way in, for the same
    /// reason: the platform's answer is the right default and must not be the
    /// only one.
    public var decoderFactory: VideoDecoderFactory

    /// Where the audio decoder comes from. Same reasoning.
    public var audioDecoderFactory: AudioDecoderFactory

    public init(
        cadence: TapCadence = .everyFrame,
        depth: Int = 2,
        decoderFactory: @escaping VideoDecoderFactory = defaultVideoDecoderFactory,
        audioDecoderFactory: @escaping AudioDecoderFactory = defaultAudioDecoderFactory
    ) {
        self.cadence = cadence
        self.depth = depth
        self.decoderFactory = decoderFactory
        self.audioDecoderFactory = audioDecoderFactory
    }

    /// Every frame, shallow buffer. For a re-render or a compositor.
    public static var everyFrame: Self { Self() }

    /// One picture per group, one deep.
    ///
    /// What a safety classifier should ask for. One deep because a classifier
    /// that has fallen behind wants the current picture and not the one from
    /// four seconds ago — the stale verdict is worse than no verdict, since it
    /// is the one that gets acted on.
    public static var classification: Self {
        Self(cadence: .keyFramesOnly, depth: 1)
    }

    /// Everything, unbounded. For transcription and translation.
    ///
    /// Unbounded is not an oversight. A transcript with holes reads as a
    /// transcript, so the failure is silent and lands in a human's hands as
    /// fact; the memory this can hold is bounded in practice by an audio track
    /// being a few kilobytes a second.
    public static var transcription: Self {
        Self(depth: 0)
    }
}

/// What a tap has seen.
public struct TapStatistics: Hashable, Sendable {
    /// Elements handed to the consumer.
    public var delivered: Int = 0

    /// Elements the consumer was too slow to take.
    ///
    /// Non-zero means the processing is not keeping up and is silently sampling
    /// rather than seeing everything. Worth surfacing: a detector that believes
    /// it inspected every frame and inspected a third of them is wrong in a way
    /// that no amount of testing its model will reveal.
    public var dropped: Int = 0

    /// Elements not delivered because the cadence did not ask for them.
    ///
    /// Distinct from ``dropped``, because this one is the policy working.
    public var skipped: Int = 0

    /// Frames that arrived but could not be decoded.
    ///
    /// Ordinary in small numbers at the start of a subscription, where media can
    /// precede the catalog that describes it. Sustained means a codec the
    /// decoder does not have.
    public var undecodable: Int = 0

    public init(
        delivered: Int = 0,
        dropped: Int = 0,
        skipped: Int = 0,
        undecodable: Int = 0
    ) {
        self.delivered = delivered
        self.dropped = dropped
        self.skipped = skipped
        self.undecodable = undecodable
    }

    /// Delivered as a fraction of what was offered, cadence aside.
    ///
    /// The number a consumer should assert on. `1` means it is seeing
    /// everything the policy asked for.
    public var completeness: Double {
        let offered = delivered + dropped
        guard offered > 0 else { return 1 }
        return Double(delivered) / Double(offered)
    }
}

/// Raw media leaving the SDK.
///
/// Hold one for as long as the processing runs and call ``stop()`` when it
/// stops. A tap that is never stopped keeps a decoder alive, and on a phone that
/// is a hardware session somebody else wanted.
///
/// > Important: The SDK cannot tell an on-device transcriber from an upload. The
/// > moment frames cross this boundary they are outside anything MOQOM can
/// > account for, promise, or revoke — so a tap that leaves the device is a
/// > disclosure the integrator owes their participants, and ``Watchdog`` is the
/// > mechanism for making it. Nothing here enforces that, because a library that
/// > pretended to would be selling a guarantee it cannot keep.
public final class MediaTap<Element: Sendable>: Sendable {
    /// The media.
    ///
    /// Ends when ``stop()`` is called, when the participant leaves, or when the
    /// room does. A consumer written as `for await` over this needs no other
    /// lifecycle handling.
    public let elements: AsyncStream<Element>

    public let policy: TapPolicy

    private let continuation: AsyncStream<Element>.Continuation
    private let counters = Counters()

    init(policy: TapPolicy) {
        self.policy = policy
        (elements, continuation) = AsyncStream.makeStream(
            of: Element.self,
            bufferingPolicy: policy.depth > 0
                ? .bufferingNewest(policy.depth)
                : .unbounded
        )
    }

    /// What this tap has seen.
    public var statistics: TapStatistics { counters.snapshot }

    /// Whether anything is still listening.
    ///
    /// Goes false on ``stop()`` and when the consumer walks away from the
    /// stream. The SDK polls this to release the decoder rather than asking the
    /// consumer to be careful, because "remember to call stop" is a rule that
    /// holds until the first `guard` with an early return in it.
    public var isActive: Bool { counters.isActive }

    /// Stop delivering and release anything the tap was holding.
    ///
    /// Idempotent, and safe to call from anywhere.
    public func stop() {
        counters.finish()
        continuation.finish()
    }

    /// Hand an element to the consumer, or count the reason it did not go.
    ///
    /// Never suspends and never fails, which is the property the callers depend
    /// on: this is invoked from the receive path and from the capture path, and
    /// both of them have somewhere more important to be.
    func deliver(_ element: Element) {
        switch continuation.yield(element) {
        case .enqueued:
            counters.delivered()
        case .dropped:
            // `bufferingNewest` evicts the oldest and takes the new one, so the
            // consumer still gets current media; what it lost is the frame it
            // had not got to yet.
            counters.dropped()
        case .terminated:
            counters.finish()
        @unknown default:
            break
        }
    }

    /// Record that the cadence declined this one.
    func skip() {
        counters.skipped()
    }

    /// Record a frame that arrived and could not be decoded.
    func undecodable() {
        counters.undecodable()
    }
}

/// Counters behind a lock, because a tap is written from an actor and read from
/// wherever the consumer happens to live.
private final class Counters: @unchecked Sendable {
    private let lock = NSLock()
    private var statistics = TapStatistics()
    private var active = true

    var snapshot: TapStatistics { lock.withLock { statistics } }
    var isActive: Bool { lock.withLock { active } }

    func delivered() { lock.withLock { statistics.delivered += 1 } }
    func dropped() { lock.withLock { statistics.dropped += 1 } }
    func skipped() { lock.withLock { statistics.skipped += 1 } }
    func undecodable() { lock.withLock { statistics.undecodable += 1 } }
    func finish() { lock.withLock { active = false } }
}

/// Decides which frames a cadence lets through.
///
/// A separate value from the tap so it can be tested without a decoder, and so
/// the arithmetic — which is the part with an off-by-one in it — is in one
/// place rather than duplicated between the video and audio paths.
struct Pacer: Sendable {
    let cadence: TapCadence

    /// When the last delivered frame was captured.
    private var last: FrameTimestamp?

    /// When the last offered frame was captured, delivered or not.
    private var previous: FrameTimestamp?

    /// Roughly how far apart offered frames are, smoothed.
    ///
    /// Needed because frames arrive on a grid that has nothing to do with the
    /// requested rate. Thirty frames a second is a frame every 33.3ms, and a
    /// request for ten a second wants one every 100ms — a boundary no frame
    /// ever lands on. Gating strictly on "at least 100ms since the last one"
    /// then delivers the frame at 132ms and yields 7.5fps for a request of 10,
    /// which reads as the cadence being broken rather than as arithmetic.
    private var gap: UInt64 = 0

    init(cadence: TapCadence) {
        self.cadence = cadence
    }

    /// Whether a frame is worth decoding at all.
    ///
    /// The one cadence where this can answer no is ``TapCadence/keyFramesOnly``,
    /// and that is the whole saving: a keyframe decodes without the frames
    /// around it, so declining the rest costs nothing later.
    func decodes(isKeyFrame: Bool) -> Bool {
        cadence != .keyFramesOnly || isKeyFrame
    }

    /// Whether to deliver a frame captured at `timestamp`.
    mutating func admits(at timestamp: FrameTimestamp, isKeyFrame: Bool) -> Bool {
        switch cadence {
        case .everyFrame:
            return true

        case .keyFramesOnly:
            return isKeyFrame

        case let .atMost(fps):
            guard fps > 0 else { return false }
            observe(timestamp)

            guard let last else {
                self.last = timestamp
                return true
            }

            // Against the previous *delivered* frame rather than a running
            // clock, so a stream that pauses and resumes delivers immediately on
            // resumption instead of waiting out an interval that elapsed while
            // nothing was arriving.
            let interval = UInt64(1_000_000_000 / fps)
            let elapsed = timestamp.nanoseconds &- last.nanoseconds

            // Whichever frame lands nearest the target time, rather than the
            // first one past it. Half a frame of tolerance is what "nearest"
            // reduces to when frames are evenly spaced, which they are.
            //
            // Capped at half the interval, because a stream that stopped for
            // thirty seconds and resumed leaves the estimate believing frames
            // arrive thirty seconds apart. Uncapped, that tolerance would admit
            // everything for as long as the estimate took to recover.
            let tolerance = min(gap / 2, interval / 2)
            guard elapsed &+ tolerance >= interval else { return false }
            self.last = timestamp
            return true
        }
    }

    /// Learn how far apart frames are arriving.
    ///
    /// Smoothed rather than taken from the last pair, because a single late
    /// frame would otherwise widen the tolerance enough to admit the next one
    /// early and leave the rate oscillating.
    private mutating func observe(_ timestamp: FrameTimestamp) {
        defer { previous = timestamp }
        guard let previous, timestamp > previous else { return }
        let observed = timestamp.nanoseconds - previous.nanoseconds
        gap = gap == 0 ? observed : (gap * 3 + observed) / 4
    }
}

/// A capture tap and the pacing in front of it.
///
/// Generic over the element because the video and audio capture paths differ in
/// nothing but the type: both already hold the frame in the shape a consumer
/// wants, because that is the shape the encoder was about to take.
final class CapturePipe<Element: Sendable> {
    let tap: MediaTap<Element>
    private var pacer: Pacer

    init(policy: TapPolicy) {
        tap = MediaTap(policy: policy)
        pacer = Pacer(cadence: policy.cadence.beforeEncoding)
    }

    func offer(_ element: Element, at timestamp: FrameTimestamp) {
        guard pacer.admits(at: timestamp, isKeyFrame: false) else {
            tap.skip()
            return
        }
        tap.deliver(element)
    }
}

/// A receive-side video tap, its pacing, and the decoder it owns.
///
/// The decoder is per tap rather than per participant. Sharing one would mean
/// two consumers with different cadences contending for its reference state,
/// and the failure — one of them silently getting the other's frame rate — is
/// worse than the cost of a second session for the rare case of two taps on one
/// participant.
///
/// An actor rather than a plain object, because decoding is asynchronous and
/// the receive path awaits it. A non-isolated class here would mean the frame
/// and the decoder crossing an isolation boundary on every picture, which the
/// compiler is right to refuse.
actor ReceiveVideoPipe {
    nonisolated let tap: MediaTap<TappedVideo>

    private let factory: VideoDecoderFactory
    private var decoder: (any VideoDecoding)?

    /// What the current decoder was built for.
    ///
    /// A rung change can change the codec, and a decoder built for the other
    /// one does not fail loudly — it fails inside VideoToolbox, frame after
    /// frame, which reads as a broken stream rather than a stale decoder.
    private var codec: VideoCodec?

    private var pacer: Pacer

    /// Whether a construction failure has already been reported.
    ///
    /// Reported once, because a decoder that cannot be built cannot be built
    /// thirty times a second either, and the log line is the same one.
    private var reported = false

    init(policy: TapPolicy) {
        tap = MediaTap(policy: policy)
        factory = policy.decoderFactory
        pacer = Pacer(cadence: policy.cadence)
    }

    /// Offer a frame, returning a decoder failure the first time it happens.
    ///
    /// Returning it rather than throwing, because this is called from the
    /// receive path where there is nobody to catch it and the correct response
    /// is a log line and a counter.
    func offer(_ frame: DepacketisedFrame, codec: VideoCodec) async -> MoqomError? {
        let encoded = frame.frame
        guard pacer.decodes(isKeyFrame: encoded.isKeyFrame) else {
            tap.skip()
            return nil
        }

        if decoder == nil || self.codec != codec {
            await decoder?.close()
            do {
                decoder = try factory(codec)
                self.codec = codec
            } catch {
                decoder = nil
                tap.undecodable()
                guard !reported else { return nil }
                reported = true
                return error as? MoqomError ?? .unsupportedCodec(codec)
            }
        }
        guard let decoder else {
            tap.undecodable()
            return nil
        }

        // Before the decode and after the codec check. A decoder carried across
        // a hole produces pictures from references that never arrived, and the
        // point of a tap is usually to make a decision about what is in the
        // picture.
        if frame.followsGap { await decoder.flush() }

        guard let decoded = try? await decoder.decode(encoded) else {
            tap.undecodable()
            return nil
        }
        guard pacer.admits(at: decoded.timestamp, isKeyFrame: encoded.isKeyFrame) else {
            tap.skip()
            return nil
        }

        tap.deliver(
            TappedVideo(
                frame: decoded,
                isKeyFrame: encoded.isKeyFrame,
                followsGap: frame.followsGap
            )
        )
        return nil
    }

    func close() async {
        tap.stop()
        await decoder?.close()
        decoder = nil
    }
}

/// A receive-side audio tap and the decoder it owns.
///
/// No pacer. Audio has nothing independently decodable to skip to, and a
/// consumer handed a subset of the slots does not get a shorter transcript, it
/// gets a wrong one.
actor ReceiveAudioPipe {
    nonisolated let tap: MediaTap<TappedAudio>

    private let factory: AudioDecoderFactory
    private var decoder: (any AudioDecoding)?
    private var built: AudioFormat?
    private var reported = false

    /// Where the next slot sits on the timeline.
    ///
    /// Synthesised rather than taken from the packet, because the slots that
    /// matter most for a timeline — the concealed and silent ones — have no
    /// packet to take it from. Seeded from the first real packet and advanced by
    /// one frame duration per slot, which is exactly what the jitter buffer's
    /// output means.
    private var clock: FrameTimestamp?

    init(policy: TapPolicy) {
        tap = MediaTap(policy: policy)
        factory = policy.audioDecoderFactory
    }

    func offer(
        _ output: JitterBufferOutput,
        format: AudioFormat,
        codec: MoqomCore.AudioCodec
    ) async -> MoqomError? {
        // Not media. The buffer is still filling, and inventing a slot of
        // silence for it would put the timeline ahead of the audio.
        guard output != .buffering else { return nil }

        if decoder == nil || built != format {
            do {
                decoder = try factory(format, codec)
                built = format
            } catch {
                decoder = nil
                tap.undecodable()
                guard !reported else { return nil }
                reported = true
                return error as? MoqomError ?? .unsupportedAudioCodec(codec)
            }
        }
        guard let decoder else {
            tap.undecodable()
            return nil
        }

        let samples = await decoder.decode(output)

        if case let .packet(packet) = output, clock == nil {
            clock = packet.timestamp
        }
        let timestamp = clock ?? FrameTimestamp(nanoseconds: 0)
        clock = FrameTimestamp(
            nanoseconds: timestamp.nanoseconds
                &+ UInt64(format.samplesPerFrame) &* 1_000_000_000
                / UInt64(max(1, format.sampleRate))
        )

        let origin: AudioOrigin = switch output {
        case .packet: .live
        case .gap: .concealed
        case .silence: .silence
        case .buffering: .silence
        }

        tap.deliver(
            TappedAudio(
                frame: AudioFrame(timestamp: timestamp, format: format, samples: samples),
                origin: origin
            )
        )
        return nil
    }
}
