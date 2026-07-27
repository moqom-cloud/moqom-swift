// A live publication.
//
// The layer ladder is the interesting part. Two spatial layers, each with
// temporal sub-layers, published as separate tracks: the relay sheds the
// enhancement layer under congestion without decoding anything, because
// dropping a track is a scheduling decision rather than a media one.
//
// The loop back the other way is what owning both ends buys. The relay knows
// which layers have subscribers, so it can tell the publisher when nobody is
// watching one — and on a phone, stopping an unwatched encode saves a hardware
// session, its uplink, and its thermal budget. Two subscribers pin regardless
// of demand and both are easy to forget: the recorder holds the top layer, and
// the safety detector holds a minimum so that an empty room cannot be used to
// downgrade the stream the classifier sees.

import Foundation
import MoqomCore

/// How to encode and publish.
public struct BroadcastConfiguration: Sendable {
    /// The rungs to produce.
    public var ladder: LayerLadder

    public var codec: VideoCodec

    /// Publisher priority for the base layer. Lower is more urgent.
    ///
    /// Enhancement layers are published at a numerically higher value so the
    /// relay's scheduler sheds them first without being told to.
    public var basePriority: UInt8

    /// Objects older than this are not worth sending.
    public var deliveryTimeout: Duration?

    /// Stop encoding a layer nobody is subscribed to.
    ///
    /// Needs hysteresis and a fresh keyframe on resume, and needs to be honest
    /// about the ramp-up gap when a viewer asks for a layer that is not
    /// currently being produced — so it is opt-in rather than the default.
    public var stopsUnwatchedLayers: Bool

    public init(
        ladder: LayerLadder = .defaultCamera(),
        codec: VideoCodec = .hevc,
        basePriority: UInt8 = 64,
        deliveryTimeout: Duration? = .milliseconds(500),
        stopsUnwatchedLayers: Bool = false
    ) {
        self.ladder = ladder
        self.codec = codec
        self.basePriority = basePriority
        self.deliveryTimeout = deliveryTimeout
        self.stopsUnwatchedLayers = stopsUnwatchedLayers
    }
}

/// What a publication is doing right now.
public struct BroadcastStatistics: Hashable, Sendable {
    public var framesSubmitted: Int
    public var framesEncoded: Int

    /// Frames the SDK dropped because the encoder or the link was behind.
    ///
    /// Surfaced rather than hidden: dropping is the correct response to
    /// pressure, and an integrator who cannot see it will misread the resulting
    /// frame rate as a bug in their capture.
    public var framesDropped: Int

    public var objectsPublished: Int
    public var currentGroup: UInt64

    /// Layers currently being produced. Shrinks when
    /// ``BroadcastConfiguration/stopsUnwatchedLayers`` is on and nobody is
    /// watching.
    public var activeLayers: Set<LayerID>

    public init(
        framesSubmitted: Int = 0,
        framesEncoded: Int = 0,
        framesDropped: Int = 0,
        objectsPublished: Int = 0,
        currentGroup: UInt64 = 0,
        activeLayers: Set<LayerID> = []
    ) {
        self.framesSubmitted = framesSubmitted
        self.framesEncoded = framesEncoded
        self.framesDropped = framesDropped
        self.objectsPublished = objectsPublished
        self.currentGroup = currentGroup
        self.activeLayers = activeLayers
    }
}

/// A running publication.
///
/// Holding one is what makes a participant appear in the roster: the namespace
/// announcement is taken when the broadcast starts and withdrawn when it stops.
public actor Broadcast {
    /// Where this publishes.
    public nonisolated let namespace: TrackNamespace

    public nonisolated let configuration: BroadcastConfiguration

    private let source: any FrameSource
    private let announcement: any AnnouncementHandle
    private var writers: [LayerID: any TrackWriter] = [:]
    private var statistics = BroadcastStatistics()
    private var pump: Task<Void, Never>?
    private var nextObject: UInt64 = 0

    init(
        namespace: TrackNamespace,
        configuration: BroadcastConfiguration,
        source: any FrameSource,
        announcement: any AnnouncementHandle,
        writers: [LayerID: any TrackWriter]
    ) {
        self.namespace = namespace
        self.configuration = configuration
        self.source = source
        self.announcement = announcement
        self.writers = writers
        statistics.activeLayers = Set(writers.keys)
    }

    public var stats: BroadcastStatistics { statistics }

    /// Begin pulling frames.
    ///
    /// Separate from construction because a scope grant is permission and not
    /// behaviour: the SDK must never start a camera because a token changed.
    public func start() {
        guard pump == nil else { return }
        let frames = source.frames()
        pump = Task { [weak self] in
            for await frame in frames {
                await self?.consume(frame)
            }
        }
    }

    /// Start a new group at the next frame.
    ///
    /// Called on resumption after a gap, because frames were lost and
    /// continuing the interrupted group hands every viewer an undecodable
    /// stream.
    public func startNewGroup() async {
        statistics.currentGroup += 1
        nextObject = 0
        for writer in writers.values {
            try? await writer.startGroup(statistics.currentGroup)
        }
    }

    /// Restrict production to the layers someone is actually watching, plus
    /// whatever watchdogs have pinned.
    public func setDemandedLayers(_ demanded: Set<LayerID>, pinned: Set<LayerID>) {
        guard configuration.stopsUnwatchedLayers else { return }
        statistics.activeLayers = demanded.union(pinned)
    }

    public func stop() async {
        pump?.cancel()
        pump = nil
        source.stop()
        for writer in writers.values {
            await writer.finish()
        }
        writers.removeAll()
        await announcement.withdraw()
    }

    private func consume(_ frame: VideoFrame) async {
        statistics.framesSubmitted += 1

        if frame.forcesKeyFrame {
            await startNewGroup()
        }

        // Encoding is the platform layer's job and it is not reachable without
        // a GPU, so the object here carries the frame's shape rather than its
        // pixels when there is no encoder attached. The transport contract, the
        // group and object numbering, and the priority mapping are all
        // exercised either way, which is the part worth testing off-device.
        let payload = Self.descriptor(for: frame)

        for layer in configuration.ladder.rungs where isActive(layer.id) {
            guard let writer = writers[layer.id] else { continue }
            let object = TrackObject(
                group: statistics.currentGroup,
                object: nextObject,
                priority: priority(for: layer),
                payload: payload,
                isKeyFrame: frame.forcesKeyFrame || nextObject == 0
            )
            do {
                try await writer.write(object)
                statistics.objectsPublished += 1
            } catch {
                statistics.framesDropped += 1
            }
        }
        statistics.framesEncoded += 1
        nextObject += 1
    }

    private func isActive(_ layer: LayerID) -> Bool {
        !configuration.stopsUnwatchedLayers || statistics.activeLayers.contains(layer)
    }

    /// Enhancement layers sit numerically above the base so the relay sheds
    /// them first. Clamped rather than wrapped, because a ladder deep enough to
    /// overflow would otherwise turn the lowest rung into the most urgent one.
    private func priority(for layer: VideoLayer) -> UInt8 {
        guard let index = configuration.ladder.index(of: layer.id) else {
            return configuration.basePriority
        }
        return UInt8(min(255, Int(configuration.basePriority) + index * 8))
    }

    private static func descriptor(for frame: VideoFrame) -> Data {
        var bytes = Data(capacity: 20)
        withUnsafeBytes(of: frame.timestamp.nanoseconds.littleEndian) { bytes.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(frame.size.width).littleEndian) { bytes.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(frame.size.height).littleEndian) { bytes.append(contentsOf: $0) }
        return bytes
    }
}
