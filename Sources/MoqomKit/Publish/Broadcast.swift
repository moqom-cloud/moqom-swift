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

    /// Where encoders come from.
    ///
    /// Overriding this is how you bring your own codec — a software AV1, a
    /// renderer that emits a bitstream without ever producing pixels, or a
    /// synthetic one for tests. The default asks the platform for hardware.
    public var encoderFactory: EncoderFactory

    public init(
        ladder: LayerLadder = .defaultCamera(),
        codec: VideoCodec = .hevc,
        basePriority: UInt8 = 64,
        deliveryTimeout: Duration? = .milliseconds(500),
        stopsUnwatchedLayers: Bool = false,
        encoderFactory: @escaping EncoderFactory = defaultEncoderFactory
    ) {
        self.ladder = ladder
        self.codec = codec
        self.basePriority = basePriority
        self.deliveryTimeout = deliveryTimeout
        self.stopsUnwatchedLayers = stopsUnwatchedLayers
        self.encoderFactory = encoderFactory
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
    private var announcement: any AnnouncementHandle
    private var writers: [LayerID: any TrackWriter] = [:]
    private var encoders: [LayerID: any FrameEncoder] = [:]
    private var drains: [LayerID: Task<Void, Never>] = [:]

    /// Group and object numbering, per rung.
    ///
    /// Per rung rather than shared, because the rungs are separate tracks and
    /// their encoders make independent decisions about where keyframes land. A
    /// shared counter would number one track's objects from another's output.
    private var sequencing: [LayerID: TrackSequencer] = [:]
    private var statistics = BroadcastStatistics()
    private var pump: Task<Void, Never>?

    /// Consumers watching the frames on their way to the encoders.
    private var taps: [CapturePipe<VideoFrame>] = []

    /// What the catalog should say about each rung.
    ///
    /// Filled in from the first keyframe each encoder produces: the parameter
    /// sets are not known until something has been encoded, and a catalog
    /// published before then would advertise a decoder configuration nobody
    /// could construct.
    private var initialisation: [LayerID: Data] = [:]

    init(
        namespace: TrackNamespace,
        configuration: BroadcastConfiguration,
        source: any FrameSource,
        announcement: any AnnouncementHandle,
        writers: [LayerID: any TrackWriter],
        encoders: [LayerID: any FrameEncoder]
    ) {
        self.namespace = namespace
        self.configuration = configuration
        self.source = source
        self.announcement = announcement
        self.writers = writers
        self.encoders = encoders
        statistics.activeLayers = Set(writers.keys)
    }

    /// The decoder configuration each rung has produced so far.
    ///
    /// Empty until the first keyframe of that rung has been encoded.
    public var decoderConfigurations: [LayerID: Data] { initialisation }

    public var stats: BroadcastStatistics { statistics }

    /// Watch the frames this publication is about to encode.
    ///
    /// The frame handed over is the one the encoder gets: after the source, and
    /// after any effect the SDK applied, which is the distinction that matters
    /// for anything making a decision about content. A safety classifier run on
    /// the frame the application submitted would be inspecting a picture that no
    /// viewer will ever see.
    ///
    /// Free, or near enough. These frames already exist in this shape — nothing
    /// is decoded, converted, or copied to produce them, and the pixel buffer
    /// handed over is the same IOSurface the encoder is reading.
    ///
    /// Which is also the constraint. That buffer belongs to a pool the capture
    /// path is recycling, so a consumer that holds it holds a buffer the camera
    /// wants back. Process it and let it go; if it needs to outlive the call,
    /// copy it.
    ///
    /// > Note: ``TapCadence/keyFramesOnly`` has no meaning here, because nothing
    /// > has been encoded yet. See ``TapCadence/keyFramesOnly`` for what it does
    /// > instead.
    public func tapFrames(policy: TapPolicy = .everyFrame) -> MediaTap<VideoFrame> {
        let pipe = CapturePipe<VideoFrame>(policy: policy)
        taps.append(pipe)
        return pipe.tap
    }

    /// Begin pulling frames.
    ///
    /// Separate from construction because a scope grant is permission and not
    /// behaviour: the SDK must never start a camera because a token changed.
    public func start() {
        guard pump == nil else { return }

        // One drain per encoder, started before the first frame is submitted.
        // Encoders are pipelined, so output for a rung arrives on its own
        // schedule; draining them from the capture loop would couple every
        // rung's latency to the slowest one.
        for (id, encoder) in encoders {
            let output = encoder.encodedFrames()
            drains[id] = Task { [weak self] in
                for await encoded in output {
                    await self?.publish(encoded, on: id)
                }
            }
        }

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
        for (id, writer) in writers {
            sequencing[id, default: TrackSequencer()].jump(to: statistics.currentGroup)
            try? await writer.startGroup(statistics.currentGroup)
        }
    }

    /// Move the publication onto a new session's writers after a reconnect.
    ///
    /// Encoders, their drains, and the capture pump are all left running. They
    /// are local hardware and local tasks; restarting them would stop the camera
    /// and drop the frames in flight, which is a visible outage on top of the
    /// one that just happened. What is replaced is exactly what the dead
    /// transport owned.
    ///
    /// The caller is expected to follow this with ``startNewGroup()``, which the
    /// session state machine emits on resumption for the reason that matters
    /// here: the objects already sent in the current group went somewhere else,
    /// and a subscriber joining the continuation would be missing its keyframe.
    func rebind(writers: [LayerID: any TrackWriter], announcement: any AnnouncementHandle) {
        self.writers = writers
        self.announcement = announcement
        statistics.activeLayers = Set(writers.keys)
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
        for pipe in taps { pipe.tap.stop() }
        taps.removeAll()
        for drain in drains.values { drain.cancel() }
        drains.removeAll()
        for encoder in encoders.values {
            await encoder.close()
        }
        encoders.removeAll()
        for writer in writers.values {
            await writer.finish()
        }
        writers.removeAll()
        await announcement.withdraw()
    }

    /// A captured frame goes to every active encoder and nowhere else.
    ///
    /// Nothing is published from here. The frame that comes back out of an
    /// encoder is a different thing from the one that went in — reordered in
    /// general, and always later — so publishing on submission would attach the
    /// wrong object number to the wrong bytes.
    private func consume(_ frame: VideoFrame) async {
        statistics.framesSubmitted += 1

        // Before the encoders, and synchronously. A tap that ran after encoding
        // would deliver frames reordered and late; a tap that awaited anything
        // would put a consumer's latency in front of the uplink.
        if !taps.isEmpty {
            taps.removeAll { !$0.tap.isActive }
            for pipe in taps { pipe.offer(frame, at: frame.timestamp) }
        }

        for layer in configuration.ladder.rungs where isActive(layer.id) {
            guard let encoder = encoders[layer.id] else { continue }
            do {
                try await encoder.encode(frame, forcingKeyFrame: frame.forcesKeyFrame)
            } catch {
                // A rejected frame is a dropped frame, not a failed broadcast.
                // Encoders reject under back pressure and recover on the next
                // one; tearing down the publication would turn a hiccup into an
                // outage.
                statistics.framesDropped += 1
            }
        }
    }

    /// One compressed frame becomes one object on one track.
    private func publish(_ encoded: EncodedFrame, on layer: LayerID) async {
        guard let writer = writers[layer], let rung = configuration.ladder.layer(id: layer) else {
            return
        }

        if encoded.isKeyFrame, !encoded.parameterSets.isEmpty {
            initialisation[layer] = DecoderConfiguration.encode(encoded.parameterSets)
        }

        var sequencer = sequencing[layer] ?? TrackSequencer()
        let location = sequencer.next(isKeyFrame: encoded.isKeyFrame)
        sequencing[layer] = sequencer

        // A group boundary on the wire is a new subgroup stream, and the writer
        // only learns about it here. Told before the object rather than
        // inferred from it, because the transport has to close the previous
        // stream first.
        if location.startsGroup {
            try? await writer.startGroup(location.group)
            statistics.currentGroup = max(statistics.currentGroup, location.group)
        }

        let object = TrackObject(
            group: location.group,
            object: location.object,
            priority: priority(for: rung),
            payload: encoded.data,
            isKeyFrame: encoded.isKeyFrame,
            properties: ObjectProperties(
                captureTime: encoded.timestamp,
                temporalLayer: encoded.temporalLayer
            )
        )

        do {
            try await writer.write(object)
            statistics.objectsPublished += 1
        } catch {
            statistics.framesDropped += 1
        }
        statistics.framesEncoded += 1
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

}

/// Where the next object on a track goes.
///
/// A group is a group of pictures: it starts at a keyframe and every object in
/// it depends on that keyframe. That definition is what makes a group the right
/// unit for a relay to drop, for a joiner to start at, and for a recorder to
/// index — and it means the encoder decides group boundaries, not the clock and
/// not the application.
struct TrackSequencer: Sendable {
    struct Location: Hashable, Sendable {
        var group: UInt64
        var object: UInt64
        var startsGroup: Bool
    }

    private var group: UInt64 = 0

    /// The last object emitted in this group; `nil` before the first.
    private var object: UInt64?

    private var started = false

    /// Set when someone opened the group for us, so we do not open it twice.
    ///
    /// Opening it twice would put two subgroups with the same ID on the wire,
    /// which is a protocol violation rather than a wasted call.
    private var boundarySignalled = false

    /// Advance. A keyframe opens a group; anything else extends one.
    mutating func next(isKeyFrame: Bool) -> Location {
        defer { boundarySignalled = false }

        if isKeyFrame {
            if started { group += 1 }
            started = true
            object = 0
            return Location(group: group, object: 0, startsGroup: !boundarySignalled)
        }

        // A delta frame before any keyframe should not happen, and if it does,
        // publishing it is better than dropping it: the viewer recovers at the
        // next keyframe either way, and silently discarding encoder output is
        // the kind of thing that gets diagnosed as a broken encoder.
        started = true
        let next = object.map { $0 + 1 } ?? 0
        object = next
        return Location(group: group, object: next, startsGroup: false)
    }

    /// Force a boundary from outside, after a gap in the frames.
    ///
    /// The caller has already told the transport, so the next object rides the
    /// group it opened.
    mutating func jump(to group: UInt64) {
        self.group = max(self.group, group)
        object = nil
        started = false
        boundarySignalled = true
    }
}
