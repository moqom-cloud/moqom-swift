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

    /// Frames the camera produced while the publication was muted.
    ///
    /// Separate from ``framesDropped`` because they mean opposite things to
    /// whoever is reading them. A rising drop count is pressure and may be a
    /// problem; a rising muted count is the user's own choice being honoured,
    /// and it is the number that distinguishes "muted" from "the capture
    /// stopped", which look identical from the objects published.
    public var framesMuted: Int

    /// Encoded frames that had nowhere to go, because the rung had no writer.
    ///
    /// Distinct from ``framesDropped``, which is pressure and self-correcting. This is a
    /// publication that has lost the track it publishes on and cannot get it back by itself:
    /// the encoder is working, the frames are compressed, and every one of them is being
    /// discarded on the way to the wire.
    ///
    /// It exists because its absence was indistinguishable from success. A broadcast whose
    /// writer failed to reopen after a reconnect reported frames submitted, none encoded,
    /// nothing dropped and no error, on a camera running at a perfect thirty frames a second
    /// — a dead uplink whose every local indicator was healthy.
    public var framesUnroutable: Int

    public var objectsPublished: Int
    public var currentGroup: UInt64

    /// Layers currently being produced. Shrinks when
    /// ``BroadcastConfiguration/stopsUnwatchedLayers`` is on and nobody is
    /// watching.
    public var activeLayers: Set<LayerID>

    /// Whether the publication is holding frames back. See
    /// ``Broadcast/setMuted(_:)``.
    public var isMuted: Bool

    /// How long the encoder held each frame, from submission to compressed output.
    ///
    /// The first of the two costs an application controls, and the one most often assumed rather
    /// than measured. A hardware encoder at 720p is a few milliseconds and its p95 is close to
    /// its median; a p95 several times the median means frames are queueing at the encoder,
    /// which no amount of network work will fix.
    public var encodeLatency: StageLatency

    /// How long the transport took to accept each object.
    ///
    /// The other cost, and the one that explains an uneven stream when capture and encode are
    /// both smooth. This is not the time to reach anywhere — it is how long the publisher was
    /// made to wait before it could hand the bytes over. A median under a millisecond with an
    /// occasional hundred means the send path is applying back pressure in bursts, and every
    /// frame captured during one of those arrives late at the far end in a bunch.
    public var writeLatency: StageLatency

    public init(
        framesSubmitted: Int = 0,
        framesEncoded: Int = 0,
        framesDropped: Int = 0,
        framesMuted: Int = 0,
        framesUnroutable: Int = 0,
        objectsPublished: Int = 0,
        currentGroup: UInt64 = 0,
        activeLayers: Set<LayerID> = [],
        isMuted: Bool = false,
        encodeLatency: StageLatency = StageLatency(),
        writeLatency: StageLatency = StageLatency()
    ) {
        self.encodeLatency = encodeLatency
        self.writeLatency = writeLatency
        self.framesSubmitted = framesSubmitted
        self.framesEncoded = framesEncoded
        self.framesDropped = framesDropped
        self.framesMuted = framesMuted
        self.framesUnroutable = framesUnroutable
        self.objectsPublished = objectsPublished
        self.currentGroup = currentGroup
        self.activeLayers = activeLayers
        self.isMuted = isMuted
    }
}

/// What one stage of the publish path cost, in milliseconds.
///
/// Percentiles rather than an average, because an average is exactly the shape of measurement
/// that hides the problem being looked for. Thirty frames a second where twenty-nine take two
/// milliseconds and one takes two hundred averages nine, which reads as healthy and is the
/// arithmetic of a visible stutter.
///
/// A bounded window of samples, so a publication running for an hour reports what it is doing
/// now rather than an average over everything it has ever done. The worst is kept for the whole
/// run separately: a single stall is a fact about the run and a window would eventually forget it.
public struct StageLatency: Sendable, Hashable {
    public var samples: Int
    public var median: Double
    public var p95: Double
    public var worst: Double

    public init(samples: Int = 0, median: Double = 0, p95: Double = 0, worst: Double = 0) {
        self.samples = samples
        self.median = median
        self.p95 = p95
        self.worst = worst
    }
}

/// Collects durations and summarises them, for one stage.
///
/// Deliberately not an actor and not locked: each instance lives inside the actor that writes it.
struct StageMeter {
    private var samples: [Double] = []
    private var cursor = 0
    private var count = 0
    private var worst = 0.0
    private static let window = 300

    mutating func record(_ elapsed: Duration) {
        let milliseconds = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15
        count += 1
        worst = max(worst, milliseconds)
        if samples.count < Self.window {
            samples.append(milliseconds)
        } else {
            samples[cursor] = milliseconds
            cursor = (cursor + 1) % Self.window
        }
    }

    var summary: StageLatency {
        guard !samples.isEmpty else { return StageLatency() }
        let sorted = samples.sorted()
        func percentile(_ fraction: Double) -> Double {
            sorted[Int((Double(sorted.count - 1) * fraction).rounded())]
        }
        return StageLatency(
            samples: count,
            median: percentile(0.5),
            p95: percentile(0.95),
            worst: worst
        )
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

    /// When each captured frame went to the encoders, and what each stage has cost.
    private var submitted: [FrameTimestamp: ContinuousClock.Instant] = [:]
    private var encodeMeter = StageMeter()
    private var writeMeter = StageMeter()
    private var statistics = BroadcastStatistics()
    private var pump: Task<Void, Never>?

    /// Whether ``setMuted(_:)`` is currently holding frames back.
    public private(set) var isMuted = false

    /// Set while unmuting, and cleared by the frame that carries the keyframe.
    private var resumesWithKeyFrame = false

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

    /// Stop encoding, without taking the publication down.
    ///
    /// The distinction from ``stop()`` is the whole point. Stopping withdraws
    /// the announcement, closes the tracks, and takes the participant out of
    /// everyone's roster; muting leaves all of that standing and simply stops
    /// producing objects. Subscribers keep their subscriptions, the layer
    /// selector keeps its rung, and unmuting is a frame away rather than a
    /// resubscribe and a wait for the next keyframe.
    ///
    /// The camera is left running. That is a deliberate limit and worth being
    /// plain about: this stops the bytes reaching the relay, it does not put
    /// the hardware indicator out. An application that wants the stronger claim
    /// — the one the user reads off the green dot — should stop the capture
    /// device as well, and pay the reacquisition latency when it comes back.
    public func setMuted(_ muted: Bool) async {
        guard muted != isMuted else { return }
        isMuted = muted
        statistics.isMuted = muted
        guard !muted else { return }


        // Coming back is not simply the opposite of going away. Subscribers
        // have a hole where the muted frames would have been, so the group they
        // are mid-way through cannot be continued into: a viewer joining the
        // continuation would be missing its keyframe, and one already watching
        // would be handed frames referencing pictures that were never sent.
        // Same reasoning as a reconnect, and the same remedy.
        await startNewGroup()
        resumesWithKeyFrame = true
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
        //
        // Before the mute check too, and that is a decision rather than an
        // accident of ordering: a tap is the local processing path — a safety
        // classifier, a transcriber, a beauty filter's own analysis — and those
        // are exactly the things that should keep seeing the camera while it is
        // not being sent anywhere. A consumer that wants to stop when the user
        // mutes can stop; one that needed the frames cannot get them back.
        if !taps.isEmpty {
            taps.removeAll { !$0.tap.isActive }
            for pipe in taps { pipe.offer(frame, at: frame.timestamp) }
        }

        // Counted as submitted above and then dropped here, so the statistics
        // show a source still producing into a publication that is not sending.
        // Reporting them as never submitted would make a muted broadcast look
        // like a dead camera.
        guard !isMuted else {
            statistics.framesMuted += 1
            return
        }

        let forcesKeyFrame = frame.forcesKeyFrame || resumesWithKeyFrame
        resumesWithKeyFrame = false

        // Noted against the frame's own timestamp, because that is the only thing that survives
        // the encoder: what comes back out is different bytes, later, and in general reordered.
        // Bounded, so a rung that stops producing output cannot turn this into a slow leak.
        submitted[frame.timestamp] = .now
        if submitted.count > 90 {
            for stale in submitted.keys.sorted().prefix(submitted.count - 90) {
                submitted.removeValue(forKey: stale)
            }
        }

        for layer in configuration.ladder.rungs where isActive(layer.id) {
            guard let encoder = encoders[layer.id] else { continue }
            do {
                try await encoder.encode(frame, forcingKeyFrame: forcesKeyFrame)
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
            // Counted, because this used to be the quietest failure in the SDK. A rung with no
            // writer discards every frame the encoder produces, and returning here without
            // saying so left the publication's own statistics describing a healthy broadcast:
            // frames submitted, none encoded, nothing dropped.
            statistics.framesUnroutable += 1
            return
        }

        if let at = submitted[encoded.timestamp] {
            encodeMeter.record(.now - at)
            statistics.encodeLatency = encodeMeter.summary
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

        // Timed across the group boundary as well as the object, because the boundary is the
        // expensive half: closing one subgroup stream and opening the next is work the object
        // write itself never does, and folding them together would hide it in the tail.
        let handedOver = ContinuousClock.now
        do {
            try await writer.write(object)
            statistics.objectsPublished += 1
        } catch {
            statistics.framesDropped += 1
        }
        writeMeter.record(.now - handedOver)
        statistics.writeLatency = writeMeter.summary
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
