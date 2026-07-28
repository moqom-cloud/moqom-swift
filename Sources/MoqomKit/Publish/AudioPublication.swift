// Audio on the wire.
//
// The mapping differs from video in one structural way. A video group is a
// group of pictures and holds however many frames the encoder puts between
// keyframes; an audio group is a fixed span of time, because every audio packet
// is independently decodable and there is nothing else for a group boundary to
// mean. One second per group is the choice here: short enough that a joiner
// starts talking quickly, long enough that the per-group stream setup is not a
// meaningful share of a 24kbps track.
//
// Audio also publishes at a numerically lower priority than any video rung, so
// a relay under pressure sheds pictures before it sheds speech. That ordering
// is the single most important thing in this file. A call that keeps audio and
// loses video is a call; the reverse is not.

import Foundation
import MoqomCore

/// How to publish audio.
public struct AudioPublicationConfiguration: Sendable {
    public var encoder: AudioEncoderConfiguration

    /// Publisher priority. Below every video rung, deliberately.
    public var priority: UInt8

    /// How much audio goes in one group.
    public var groupDuration: Duration

    /// Where the encoder comes from.
    public var encoderFactory: AudioEncoderFactory

    public init(
        encoder: AudioEncoderConfiguration = AudioEncoderConfiguration(),
        priority: UInt8 = 16,
        groupDuration: Duration = .seconds(1),
        encoderFactory: @escaping AudioEncoderFactory = defaultAudioEncoderFactory
    ) {
        self.encoder = encoder
        self.priority = priority
        self.groupDuration = groupDuration
        self.encoderFactory = encoderFactory
    }

    /// Packets per group, at least one.
    var packetsPerGroup: Int {
        let group = Double(groupDuration.components.seconds)
            + Double(groupDuration.components.attoseconds) / 1e18
        let packet = Double(encoder.format.frameDuration.components.seconds)
            + Double(encoder.format.frameDuration.components.attoseconds) / 1e18
        guard packet > 0 else { return 1 }
        return max(1, Int((group / packet).rounded()))
    }
}

/// What an audio publication is doing.
public struct AudioPublicationStatistics: Hashable, Sendable {
    public var framesCaptured: Int = 0
    public var packetsPublished: Int = 0
    public var packetsDropped: Int = 0
    public var silentPackets: Int = 0
    public var currentGroup: UInt64 = 0

    /// Whether the last packet carried speech, for a talking indicator.
    public var isSpeaking: Bool = false
}

/// A running audio publication.
public actor AudioPublication {
    public nonisolated let track: FullTrackName
    public nonisolated let configuration: AudioPublicationConfiguration

    private let source: any AudioSource
    private let encoder: any AudioEncoder
    private var writer: (any TrackWriter)?
    private var capture: Task<Void, Never>?
    private var drain: Task<Void, Never>?
    private var statistics = AudioPublicationStatistics()

    /// Position within the current group.
    private var packetInGroup = 0

    /// Consumers watching the samples on their way to the encoder.
    private var taps: [CapturePipe<AudioFrame>] = []

    init(
        track: FullTrackName,
        configuration: AudioPublicationConfiguration,
        source: any AudioSource,
        encoder: any AudioEncoder,
        writer: any TrackWriter
    ) {
        self.track = track
        self.configuration = configuration
        self.source = source
        self.encoder = encoder
        self.writer = writer
    }

    public var stats: AudioPublicationStatistics { statistics }

    /// Watch the samples this publication is about to encode.
    ///
    /// This is the one tap that gives an application something it could not
    /// have got for itself, and the reason is the echo canceller. The samples
    /// here have been through the shared audio graph: the speaker's output has
    /// been subtracted, so what is left is this participant's voice and not the
    /// room's. An application that opened its own microphone alongside the SDK
    /// would get the raw hardware feed instead — everyone else in the call,
    /// coming back through the speaker, mixed with the person holding the
    /// phone. Transcribe that and you transcribe the whole room, twice, from
    /// each device.
    ///
    /// Linear PCM at the capture format, one frame per encoder packet, in
    /// order, including the frames the detector considers silence. Silence is
    /// included on purpose: a transcriber needs to know the pause happened.
    ///
    /// > Note: ``TapPolicy/cadence`` is ignored. Audio has no independently
    /// > decodable frame to skip to, and a consumer handed a subset of it does
    /// > not get less of the truth, it gets something untrue.
    public func tapSamples(policy: TapPolicy = .transcription) -> MediaTap<AudioFrame> {
        let pipe = CapturePipe<AudioFrame>(
            policy: TapPolicy(
                cadence: .everyFrame,
                depth: policy.depth,
                decoderFactory: policy.decoderFactory
            )
        )
        taps.append(pipe)
        return pipe.tap
    }

    /// Move the publication onto a new session's writer after a reconnect.
    ///
    /// The capture pump and the encoder are untouched: a microphone is local
    /// hardware and a dropped connection is not a reason to restart it. Only the
    /// writer belonged to the dead session.
    ///
    /// The next packet opens a group, because the old group's earlier packets
    /// went to a relay this one has never spoken to. Continuing it would leave
    /// every subscriber's numbering with a hole it will wait on.
    func rebind(writer: any TrackWriter) {
        self.writer = writer
        if packetInGroup > 0 {
            packetInGroup = 0
            statistics.currentGroup += 1
        }
    }

    public func start() {
        guard capture == nil else { return }

        let packets = encoder.encodedFrames()
        drain = Task { [weak self] in
            for await packet in packets {
                await self?.publish(packet)
            }
        }

        let frames = source.frames()
        capture = Task { [weak self] in
            for await frame in frames {
                await self?.consume(frame)
            }
        }
    }

    public func stop() async {
        capture?.cancel()
        capture = nil
        drain?.cancel()
        drain = nil
        source.stop()
        for pipe in taps { pipe.tap.stop() }
        taps.removeAll()
        await encoder.close()
        await writer?.finish()
        writer = nil
    }

    private func consume(_ frame: AudioFrame) async {
        statistics.framesCaptured += 1

        if !taps.isEmpty {
            taps.removeAll { !$0.tap.isActive }
            for pipe in taps { pipe.offer(frame, at: frame.timestamp) }
        }

        do {
            try await encoder.encode(frame)
        } catch {
            statistics.packetsDropped += 1
        }
    }

    private func publish(_ packet: EncodedAudioFrame) async {
        guard let writer else { return }

        if packetInGroup == 0 {
            try? await writer.startGroup(statistics.currentGroup)
        }

        let object = TrackObject(
            group: statistics.currentGroup,
            object: UInt64(packetInGroup),
            priority: configuration.priority,
            payload: packet.data,
            // Every Opus packet stands alone, so every one of them is a point a
            // subscriber can join at. Saying otherwise would make a relay hold
            // audio waiting for a keyframe that is never coming.
            isKeyFrame: true,
            properties: ObjectProperties(
                captureTime: packet.timestamp,
                temporalLayer: 0,
                isSilence: packet.isSilence
            )
        )

        do {
            try await writer.write(object)
            statistics.packetsPublished += 1
            statistics.isSpeaking = !packet.isSilence
            if packet.isSilence { statistics.silentPackets += 1 }
        } catch {
            statistics.packetsDropped += 1
        }

        packetInGroup += 1
        if packetInGroup >= configuration.packetsPerGroup {
            packetInGroup = 0
            statistics.currentGroup += 1
        }
    }
}
