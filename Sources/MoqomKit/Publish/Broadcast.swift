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
    /// Opt-in, and the reason is not caution about the hysteresis or the keyframe on resume —
    /// ``Broadcast/setDemandedLayers(_:pinned:)`` handles both. It is that **this SDK does not
    /// know who is watching**, and cannot supply the demand set itself.
    ///
    /// Which subscriptions exist is the relay's knowledge, and no signal carries it back to the
    /// publisher. So the application has to work it out and say so, and until something calls
    /// `setDemandedLayers` every rung stays active and this switch changes nothing at all. That
    /// is worth stating plainly, because a power control that silently does nothing is worse
    /// than an absent one: with a four-rung ``LayerLadder/defaultCamera()``, a caller who sets
    /// this and believes it is encoding four streams of every frame regardless.
    public var stopsUnwatchedLayers: Bool

    /// Where encoders come from.
    ///
    /// Overriding this is how you bring your own codec — a software AV1, a
    /// renderer that emits a bitstream without ever producing pixels, or a
    /// synthetic one for tests. The default asks the platform for hardware.
    public var encoderFactory: EncoderFactory

    /// Let the encoders trade speed for power. See ``EncoderConfiguration/prefersPowerEfficiency``.
    public var prefersPowerEfficiency: Bool

    /// Follow the source when it changes the shape of what it captures.
    ///
    /// On by default because the alternative is worse in a way that is hard to
    /// see: a source that starts producing a different aspect — a host switching
    /// layout, a rotation, a scene whose tiling changed — hands the encoder
    /// frames it was not configured for, and the encoder squeezes them into the
    /// shape it was built with. Everyone then looks stretched, and nothing
    /// anywhere reports an error.
    ///
    /// Following means the rungs are reshaped to the new aspect and the tracks
    /// carry on under the same names, with the switch landing on a keyframe. See
    /// ``Broadcast/reshape(toAspectOf:)``.
    public var followsCaptureShape: Bool

    /// How long capture may produce nothing before the room is told it has
    /// stopped. See ``Broadcast/captureStalls``.
    ///
    /// A second suits anything running at a normal frame rate: the largest gap
    /// measured on a healthy call was 130ms, and real interruptions measured on
    /// the same phones ran from four seconds to a hundred and four, so the
    /// boundary sits in empty space where a threshold wants to be.
    ///
    /// Raise it for a source that is meant to be slow. A screen share sending
    /// two frames a second is silent for half a second at a time by design, and
    /// a stall detector calibrated for a camera would keep announcing that the
    /// presenter's capture had failed.
    public var stallReportedAfter: Duration

    public init(
        ladder: LayerLadder = .defaultCamera(),
        codec: VideoCodec = .hevc,
        basePriority: UInt8 = 64,
        deliveryTimeout: Duration? = .milliseconds(500),
        stopsUnwatchedLayers: Bool = false,
        prefersPowerEfficiency: Bool = true,
        followsCaptureShape: Bool = true,
        stallReportedAfter: Duration = .seconds(1),
        encoderFactory: @escaping EncoderFactory = defaultEncoderFactory
    ) {
        self.ladder = ladder
        self.codec = codec
        self.basePriority = basePriority
        self.deliveryTimeout = deliveryTimeout
        self.stopsUnwatchedLayers = stopsUnwatchedLayers
        self.prefersPowerEfficiency = prefersPowerEfficiency
        self.followsCaptureShape = followsCaptureShape
        self.stallReportedAfter = stallReportedAfter
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

    /// Times the publication changed the shape of what it sends.
    ///
    /// One per layout change on the host. A number that climbs on its own means
    /// something upstream is oscillating between two aspect ratios, which costs a
    /// keyframe and a doubled encode every time it happens.
    public var reshapes = 0

    /// Whether capture is currently producing nothing, unasked.
    ///
    /// See ``BroadcastConfiguration/stallReportedAfter``. A publication that is
    /// muted or restricted is never described this way: the silence there was
    /// requested.
    public var captureStalled = false

    /// How many times that has happened since the broadcast started.
    ///
    /// Worth a count and not only a flag, because the interesting version of
    /// this fault is the one that keeps happening — a phone whose camera is
    /// taken every time a notification arrives reports a healthy frame rate
    /// between outages and a tile nobody can watch.
    public var captureStalls = 0

    /// Changes of shape given up on, the previous shape being restored.
    ///
    /// Should be zero. One means a handover that never landed, which is a
    /// keyframe that went missing between an encoder and this actor, and what a
    /// viewer saw was the previous shape stretched to hold a differently shaped
    /// picture. Worth surfacing rather than retrying quietly: the retry is
    /// automatic and the reason it was needed is not visible anywhere else.
    public var reshapesAbandoned = 0

    /// Encoded frames discarded because their encoder no longer owns the track.
    ///
    /// Almost always the cost of a seamless reshape, and it should be a frame or
    /// two per reshape. A hardware encoder holds frames internally, so when a rung
    /// switches shape the old session is still carrying pictures that were
    /// captured before the switch; those cannot go out after the keyframe that
    /// reshaped the track, because a subscriber would decode them against the new
    /// format and see the picture tear. The same applies, more rarely, to a session
    /// that was replaced after it stopped accepting frames.
    public var framesOutOfShape = 0

    /// Encoder sessions replaced after they stopped accepting frames.
    ///
    /// Nonzero means the uplink recovered from something it used to die of. A
    /// count that keeps climbing means it is dying repeatedly, which is a
    /// different problem and one no other counter here would show — a rebuild
    /// restores every other number to looking healthy.
    public var encodersRebuilt: Int

    /// What the encoders did with the frames that never became objects.
    ///
    /// Summed across rungs, and read from the encoders rather than recorded here: the gap
    /// between submitted and encoded is inside them, and until this was carried out the only
    /// honest description of it was "somewhere in VideoToolbox".
    public var encoding = EncoderAccounting()

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

    /// The shape now being published, once it differs from what was configured.
    public var shape: LayerLadder?

    public init(
        framesSubmitted: Int = 0,
        framesEncoded: Int = 0,
        framesDropped: Int = 0,
        framesMuted: Int = 0,
        framesUnroutable: Int = 0,
        objectsPublished: Int = 0,
        currentGroup: UInt64 = 0,
        encodersRebuilt: Int = 0,
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
        self.encodersRebuilt = encodersRebuilt
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

    /// The quickest this stage was observed to be.
    ///
    /// Reported because a floor is the part of a stage that no scheduling explains: the median
    /// and the tail of a capture path move with load, and what is left underneath them is the
    /// cost of the path itself. It is also the figure a measurement anchored on a minimum has
    /// silently subtracted — see the sample's `TimedSource`, where a clock offset taken as the
    /// smallest sensor-to-delivery gap removes exactly this much from every latency it reports.
    public var best: Double

    public init(
        samples: Int = 0,
        median: Double = 0,
        p95: Double = 0,
        worst: Double = 0,
        best: Double = 0
    ) {
        self.samples = samples
        self.median = median
        self.p95 = p95
        self.worst = worst
        self.best = best
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
            worst: worst,
            // Over the window rather than the run, unlike the worst above it, because the
            // floor is being used to correct a clock offset that is itself re-derived from a
            // window — and a run-long minimum would keep a single lucky frame from an hour ago
            // as the answer.
            best: sorted[0]
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

    /// The geometry being published now, which starts as the configured one.
    ///
    /// Held apart from `configuration.ladder` because that one is the request and
    /// this one is the fact. They differ from the moment the source changes shape,
    /// and the catalog has to describe this one.
    private var shape: LayerLadder

    /// Encoders for a shape that is being switched to but has not landed.
    ///
    /// A rung is in here from the moment its replacement encoder is built until
    /// that encoder produces a keyframe, which is the object that reshapes the
    /// track. Both encoders exist during that window and only one of them is
    /// being fed — see ``consume(_:)`` for why it is the new one.
    private var incoming: [LayerID: any FrameEncoder] = [:]
    private var incomingDrains: [LayerID: Task<Void, Never>] = [:]

    /// The shape ``incoming`` is encoding at, while a handover is in progress.
    private var reshaping: LayerLadder?

    /// Which encoder generation owns each rung's track.
    ///
    /// Incremented when a rung's encoder is replaced, and carried by that
    /// encoder's drain, so output from a session that has been superseded can be
    /// recognised and dropped. Without it the old encoder's pipeline empties
    /// itself onto the wire after the switch, in the previous shape, behind the
    /// keyframe that changed it.
    private var generations: [LayerID: Int] = [:]

    /// A frame whose shape disagrees with what is being published, and how many
    /// in a row. See ``framesBeforeReshape``.
    private var disagreeing: (aspect: Double, count: Int)?

    /// How many frames of a new shape are enough to act on.
    ///
    /// Two, because one is not evidence. A rotation can produce a single frame at
    /// an intermediate size, and a reshape costs a keyframe on every rung — an
    /// expensive answer to a question that answers itself on the next frame.
    private static let framesBeforeReshape = 2

    /// Ignore aspect differences smaller than this.
    ///
    /// A pixel of rounding in either dimension is not a layout change, and an
    /// exact comparison would reshape on every frame for a source whose height is
    /// odd.
    private static let aspectTolerance = 0.01

    /// When each captured frame went to the encoders, and what each stage has cost.
    private var submitted: [FrameTimestamp: ContinuousClock.Instant] = [:]
    private var encodeMeter = StageMeter()
    private var writeMeter = StageMeter()
    private var statistics = BroadcastStatistics()
    private var pump: Task<Void, Never>?

    /// When the last frame arrived from capture, and the task that notices when
    /// none has for a while. See ``judgeTheSilence()``.
    private var lastFrame: ContinuousClock.Instant?
    private var watchdog: Task<Void, Never>?
    private let stalls = Stalls()

    /// Whether ``setMuted(_:)`` is currently holding frames back.
    public private(set) var isMuted = false

    /// Whether the camera has been closed by somebody other than its owner.
    ///
    /// Kept apart from ``isMuted`` because the two are lifted by different
    /// people. Folding a moderator's mute into the participant's own would mean
    /// a lift turning a camera back on that its owner had switched off, and the
    /// person it surprises is the one who was already being moderated.
    public private(set) var isRestricted = false

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
        shape = configuration.ladder
        statistics.activeLayers = Set(writers.keys)
    }

    /// The rungs as they are being published, which follows the source's shape.
    public var currentLadder: LayerLadder { shape }

    /// Each time the published shape changes, for a caller that has to republish
    /// something describing it.
    ///
    /// A stream rather than a `didSet` or a poll, because the catalog is the thing
    /// that has to follow and the catalog is owned by the session rather than by
    /// the publication. Buffering the newest one only: a subscriber that missed an
    /// intermediate shape has no use for it, since the current one supersedes it
    /// completely.
    public nonisolated var reshapes: AsyncStream<LayerLadder> { reshaped.stream }

    private let reshaped = Reshapes()

    /// True when capture has gone silent without being asked to, false when it
    /// comes back.
    ///
    /// For whoever owns the description of this publisher — the session, which
    /// puts it in the catalog so the room can say why a tile has stopped moving.
    /// Only the latest value is kept, since an outage that has already ended is
    /// nothing anybody needs to be told about late.
    public nonisolated var captureStalls: AsyncStream<Bool> { stalls.stream }

    /// The decoder configuration each rung has produced so far.
    ///
    /// Empty until the first keyframe of that rung has been encoded.
    public var decoderConfigurations: [LayerID: Data] { initialisation }

    /// Summarised when asked rather than when recorded.
    ///
    /// Both meters keep a three-hundred sample window, and a percentile means a sort. Folding
    /// that into the statistics as each frame went by sorted six hundred numbers per frame —
    /// thirty-six thousand a second at sixty frames — to produce a figure that is read once a
    /// second by a diagnostic line. Recording stays O(1); the sort happens per reader.
    public var stats: BroadcastStatistics {
        var reading = statistics
        reading.encodeLatency = encodeMeter.summary
        reading.writeLatency = writeMeter.summary
        for encoder in encoders.values {
            let accounting = encoder.accounting
            reading.encoding.emitted += accounting.emitted
            reading.encoding.declined += accounting.declined
            reading.encoding.unreadable += accounting.unreadable
            reading.encoding.overrun += accounting.overrun
        }
        return reading
    }

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
            drains[id] = drain(encoder, on: id, generation: generation(of: id))
        }

        let frames = source.frames()
        pump = Task { [weak self] in
            for await frame in frames {
                await self?.consume(frame)
            }
        }

        // Checked several times within the threshold, so that most of the delay
        // in noticing is the threshold rather than the polling.
        let interval = min(.milliseconds(250), configuration.stallReportedAfter / 4)
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
                await self?.judgeTheSilence()
            }
        }
    }

    /// Has capture gone quiet without anybody asking it to?
    ///
    /// Only ever asked about a broadcast that ought to be producing frames. A
    /// mute stops them on purpose and says so through its own channel, and a
    /// force-mute closes the hardware deliberately; reporting either as an
    /// interruption would tell the room a second, wrong reason for a silence it
    /// has already been given the right one for.
    private func judgeTheSilence() {
        guard !isMuted, !isRestricted, let last = lastFrame else { return }

        let quiet = ContinuousClock.now - last > configuration.stallReportedAfter
        guard quiet != statistics.captureStalled else { return }

        statistics.captureStalled = quiet
        if quiet { statistics.captureStalls += 1 }
        stalls.announce(quiet)
    }

    /// Route one encoder's output onto its track, tagged with which session it is.
    private func drain(
        _ encoder: any FrameEncoder,
        on layer: LayerID,
        generation: Int
    ) -> Task<Void, Never> {
        let output = encoder.encodedFrames()
        return Task { [weak self] in
            for await encoded in output {
                await self?.publish(encoded, on: layer, generation: generation)
            }
        }
    }

    private func generation(of layer: LayerID) -> Int { generations[layer] ?? 0 }

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

    /// Restrict production to the layers someone is actually watching, plus whatever watchdogs
    /// have pinned.
    ///
    /// Has no effect unless ``BroadcastConfiguration/stopsUnwatchedLayers`` is set, and nothing
    /// in this SDK calls it: the demand set is the application's to supply, because which
    /// subscriptions exist is the relay's knowledge and no signal carries it here.
    ///
    /// Two things are handled here rather than left to the caller, since getting either wrong
    /// produces a fault a viewer sees rather than a number an operator reads.
    ///
    /// A rung is not dropped the moment its last viewer leaves. Changing rung is an unsubscribe
    /// followed by a subscribe, so a viewer stepping from 720p to 360p momentarily demands
    /// neither, and a broadcast that acted on the instant would tear down an encoder and stand
    /// it back up within a frame or two of the same switch — paying a full restart and a
    /// keyframe for something nobody asked for. It lingers instead. See ``lingersUnwatched``.
    ///
    /// And a rung returning from dormancy opens with a keyframe. Its last object was some
    /// arbitrary delta frame, so without one the arriving viewer has nothing decodable until the
    /// encoder's own interval comes round — two seconds by default, which is a black tile for
    /// two seconds after a subscription that appeared to succeed.
    public func setDemandedLayers(_ demanded: Set<LayerID>, pinned: Set<LayerID>) {
        guard configuration.stopsUnwatchedLayers else { return }
        let wanted = demanded.union(pinned)
        let now = clock.now

        for rung in configuration.ladder.rungs where wanted.contains(rung.id) {
            // Dormant, as opposed to merely on its way out: a rung still inside its linger has
            // been encoding all along and owes nobody a keyframe.
            if !isActive(rung.id) { owedAKeyFrame.insert(rung.id) }
            leftAt.removeValue(forKey: rung.id)
        }

        for rung in configuration.ladder.rungs where !wanted.contains(rung.id) {
            if leftAt[rung.id] == nil { leftAt[rung.id] = now }
        }

        demandedLayers = wanted
        refreshActiveLayers()
    }

    /// How long a rung goes on being encoded after the last viewer leaves it. See
    /// ``setDemandedLayers(_:pinned:)``.
    ///
    /// Long enough to cover a rung change, which is the common reason a layer briefly has no
    /// audience, and short enough that a viewer genuinely leaving stops costing an encode within
    /// a few frames of leaving.
    static let lingersUnwatched = Duration.seconds(3)

    /// What the application last said was wanted. Empty means nobody has said.
    private var demandedLayers: Set<LayerID>?

    /// When each rung last dropped out of demand, for the linger above.
    private var leftAt: [LayerID: ContinuousClock.Instant] = [:]

    /// Rungs whose next encode must be a keyframe because they are resuming.
    private var owedAKeyFrame: Set<LayerID> = []

    private func refreshActiveLayers() {
        statistics.activeLayers = Set(
            configuration.ladder.rungs.map(\.id).filter { isActive($0) }
        )
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
        statistics.isMuted = muted || isRestricted
        guard !muted, !isRestricted else { return }


        // Coming back is not simply the opposite of going away. Subscribers
        // have a hole where the muted frames would have been, so the group they
        // are mid-way through cannot be continued into: a viewer joining the
        // continuation would be missing its keyframe, and one already watching
        // would be handed frames referencing pictures that were never sent.
        // Same reasoning as a reconnect, and the same remedy.
        await startNewGroup()
        resumesWithKeyFrame = true
    }

    /// Close the camera, or open it again, without taking the publication down.
    ///
    /// The stronger form of ``setMuted(_:)`` and the one a force-mute uses: the
    /// frames stop because the device is shut, so the claim the user reads off
    /// the indicator and the claim the relay is making finally agree. Everything
    /// else stands — announcement, tracks, subscribers — so this is still not
    /// ``stop()``.
    ///
    /// Restoring costs whatever the camera takes to warm up, and the first
    /// frame after it is a keyframe.
    public func setCaptureRestricted(_ restricted: Bool) async {
        guard restricted != isRestricted else { return }
        isRestricted = restricted
        statistics.isMuted = restricted || isMuted

        guard !restricted else {
            source.suspend()
            return
        }
        source.resume()
        guard !isMuted else { return }
        await startNewGroup()
        resumesWithKeyFrame = true
    }

    public func stop() async {
        pump?.cancel()
        pump = nil
        watchdog?.cancel()
        watchdog = nil
        source.stop()
        for pipe in taps { pipe.tap.stop() }
        taps.removeAll()
        for drain in drains.values { drain.cancel() }
        drains.removeAll()
        for drain in incomingDrains.values { drain.cancel() }
        incomingDrains.removeAll()
        for encoder in encoders.values {
            await encoder.close()
        }
        encoders.removeAll()

        // A reshape that was in flight when the publication stopped still holds
        // hardware sessions. Nothing will promote them now.
        for encoder in incoming.values {
            await encoder.close()
        }
        incoming.removeAll()
        reshaping = nil
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

        // Recovery is announced from here rather than left to the watchdog,
        // because the room has been showing a caption over this person for as
        // long as the outage lasted and a quarter of a second of it after the
        // picture comes back is a quarter of a second of the app being wrong
        // about something the viewer can see.
        lastFrame = .now
        if statistics.captureStalled {
            statistics.captureStalled = false
            stalls.announce(false)
        }

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
        guard !isMuted, !isRestricted else {
            statistics.framesMuted += 1
            return
        }

        await followShape(of: frame)

        let forcesKeyFrame = frame.forcesKeyFrame || resumesWithKeyFrame
        resumesWithKeyFrame = false

        // While a handover is in flight the new encoders get the frames and the
        // old ones get nothing, which is the whole reason the switch is invisible.
        //
        // The alternative — keep feeding both until the new one produces its
        // keyframe — sounds more careful and cannot work: the frames arriving now
        // are the new shape, so the old session would be encoding pictures it was
        // not built for, which is the stretching this exists to avoid. What keeps
        // the picture continuous instead is that the old encoder has frames of the
        // *old* shape still inside it, and those keep publishing until the new
        // keyframe arrives to replace them.
        // A handover that is not finishing has to end, because while it runs the old
        // encoders are not being fed and the only thing publishing is the one that
        // has produced nothing. Half a second of that is a frozen picture, and every
        // second after it is the same.
        //
        // Reverting means the previous shape resumes on frames that are now a
        // different shape, so the encoder squeezes them and everyone looks
        // stretched. That is the right way round: stretched and live beats correctly
        // shaped and stopped, and the counter says which happened.
        if let began = handoverBegan, clock.now - began > Self.longestHandover {
            await abandonTheReshape()
        }

        if reshaping != nil {
            for encoder in incoming.values {
                // Every frame of the handover, not just the first, because the
                // handover turns on one object arriving and an encoder's output
                // stream is entitled to discard it. It keeps the newest frames
                // and drops the oldest under back pressure — correct for live
                // media, and it means the keyframe that reshapes the track is
                // exactly the object most likely to be thrown away when the
                // pipeline is behind, which is when a reshape is most likely to
                // be happening.
                //
                // So whatever survives the buffer is a keyframe. In the healthy
                // case that costs nothing, because the drain runs between frames
                // and the handover is over after one; under pressure it costs a
                // few whole pictures on a link that was already dropping frames,
                // which is the cheaper end of the trade against a stream that
                // publishes nothing until the encoder's own keyframe interval
                // comes round two seconds later.
                do {
                    try await encoder.encode(frame, forcingKeyFrame: true)
                } catch {
                    statistics.framesDropped += 1
                }
            }
            return
        }

        // Noted against the frame's own timestamp, because that is the only thing that survives
        // the encoder: what comes back out is different bytes, later, and in general reordered.
        // Bounded, so a rung that stops producing output cannot turn this into a slow leak.
        submitted[frame.timestamp] = .now
        if submitted.count > 90 {
            for stale in submitted.keys.sorted().prefix(submitted.count - 90) {
                submitted.removeValue(forKey: stale)
            }
        }

        // Recomputed here because a linger expires with the passage of time rather than with a
        // call, so this is the only place that notices.
        if configuration.stopsUnwatchedLayers { refreshActiveLayers() }

        for layer in configuration.ladder.rungs where isActive(layer.id) {
            guard let encoder = encoders[layer.id] else { continue }
            // A rung coming back from dormancy opens with a keyframe, whatever the frame itself
            // asked for. See `setDemandedLayers(_:pinned:)`.
            let resuming = owedAKeyFrame.remove(layer.id) != nil
            do {
                try await encoder.encode(frame, forcingKeyFrame: forcesKeyFrame || resuming)
                refusals[layer.id] = nil
            } catch {
                // A rejected frame is a dropped frame, not a failed broadcast.
                // Encoders reject under back pressure and recover on the next
                // one; tearing down the publication would turn a hiccup into an
                // outage.
                statistics.framesDropped += 1
                await noteRefusal(on: layer.id)
            }
        }
    }

    /// When the handover in progress began, if one has.
    private var handoverBegan: ContinuousClock.Instant?

    /// Measured rather than counted in frames, which is what this was and which was
    /// wrong in a way worth keeping a note about. What the deadline protects against
    /// is a frozen picture, and a frozen picture is a duration. Frames are a proxy for
    /// it only while they arrive at the rate the camera promises: feed this actor
    /// faster than its drain tasks get scheduled — a test, a machine under load — and
    /// fifteen frames go by before the new encoder has run once, so every handover is
    /// abandoned just before it would have landed, retried, and abandoned again.
    private let clock = ContinuousClock()

    /// How long a handover may go on before the previous shape is restored.
    ///
    /// Half a second, which at 30fps is fifteen frames. It should take one; anything
    /// past a few is a keyframe that went missing rather than a slow encoder, and
    /// while this runs the only encoder being fed is the one that has not produced
    /// anything.
    private static let longestHandover: Duration = .milliseconds(500)

    /// Give up on a change of shape and put the previous one back.
    private func abandonTheReshape() async {
        for drain in incomingDrains.values { drain.cancel() }
        incomingDrains.removeAll()
        for encoder in incoming.values { await encoder.close() }
        incoming.removeAll()
        reshaping = nil
        handoverBegan = nil
        statistics.reshapesAbandoned += 1

        // The rungs missed every frame of the handover, so the group they were
        // part-way through cannot be continued into: a viewer joining the
        // continuation would be missing its keyframe. Same reasoning as coming
        // back from a mute, and the same remedy.
        await startNewGroup()
        resumesWithKeyFrame = true
    }

    /// Notice that the source has changed the shape of what it captures.
    ///
    /// Frame-driven rather than announced, and that is the important choice.
    /// ``FrameSource/captureFormat`` is what a source intends and is not
    /// renegotiated while it runs, so a layout change shows up as frames of a
    /// different size and nowhere else. Acting on the frames also means an encoder
    /// for a shape is only ever built once frames of that shape exist, so there is
    /// no window in which the wrong session is being fed.
    private func followShape(of frame: VideoFrame) async {
        guard configuration.followsCaptureShape, reshaping == nil else { return }
        guard frame.size.width > 0, frame.size.height > 0 else { return }

        let captured = Double(frame.size.width) / Double(frame.size.height)
        let published = shape.rungs.first.map {
            Double($0.size.width) / Double($0.size.height)
        }
        guard let published, abs(captured - published) > Self.aspectTolerance else {
            disagreeing = nil
            return
        }

        // Counted against the aspect rather than a plain tally, so a source that
        // wobbles between two shapes never accumulates its way to a switch.
        if let held = disagreeing, abs(held.aspect - captured) <= Self.aspectTolerance {
            disagreeing = (captured, held.count + 1)
        } else {
            disagreeing = (captured, 1)
        }
        guard disagreeing?.count ?? 0 >= Self.framesBeforeReshape else { return }
        disagreeing = nil

        await reshape(toAspectOf: frame.size)
    }

    /// Publish at the aspect ratio of what is being captured.
    ///
    /// The rungs keep their short sides and their names; only the long side moves.
    /// See ``LayerLadder/reshaped(toAspectOf:)`` and ``reshape(to:)``.
    public func reshape(toAspectOf capture: PixelSize) async {
        // Derived from the configured ladder every time rather than from the
        // current shape, so a sequence of layout changes cannot accumulate
        // rounding into rungs that drift away from what was asked for.
        await reshape(to: configuration.ladder.reshaped(toAspectOf: capture))
    }

    /// Publish differently sized pictures on the same tracks.
    ///
    /// Everything a subscriber holds stays valid: the namespace, the track names,
    /// the subscriptions, the rung it chose. What changes is the size of the
    /// pictures inside those tracks, and it changes at a keyframe carrying the
    /// decoder configuration for the new size, so a viewer neither resubscribes
    /// nor waits for a catalog to catch up.
    ///
    /// Which is why the rungs must keep their identities: a ``LayerID`` is a track
    /// name, so renaming one is not a change of size but a different publication,
    /// and every subscriber would have to be told to go and find it. Rungs in
    /// `ladder` that this publication does not already have are ignored.
    ///
    /// Takes effect when the new encoders produce that keyframe, a frame or two
    /// away. Until then the previous size keeps going out, because a subscriber
    /// shown the old picture for two more frames has seen nothing happen and one
    /// shown nothing has seen a glitch. That is the whole of the overlap: two
    /// encoders exist for as long as it takes the new one to emit one frame.
    public func reshape(to ladder: LayerLadder) async {
        let target = LayerLadder(
            rungs: ladder.rungs.filter { encoders[$0.id] != nil },
            kind: ladder.kind
        )
        // Rung by rung rather than ladder against ladder, because a caller may pass
        // a ladder covering only some of the rungs and an unchanged subset is still
        // unchanged. A reshape that changes nothing still costs every rung a
        // keyframe, so it is worth being sure.
        let settled = target.rungs.allSatisfy { $0 == shape.layer(id: $0.id) }
        guard !target.isEmpty, !settled, target != reshaping else { return }

        var built: [LayerID: any FrameEncoder] = [:]
        for rung in target.rungs {
            do {
                built[rung.id] = try await configuration.encoderFactory(
                    EncoderConfiguration(
                        layer: rung,
                        codec: configuration.codec,
                        prefersPowerEfficiency: configuration.prefersPowerEfficiency
                    )
                )
            } catch {
                // All or nothing. Reshaping some rungs and not others would leave
                // a publication whose ladder disagrees with itself, and a viewer
                // switching rungs mid-call would change aspect as a side effect of
                // changing quality.
                for encoder in built.values { await encoder.close() }
                return
            }
        }
        guard !built.isEmpty else { return }

        reshaping = target
        incoming = built
        handoverBegan = clock.now
        for (id, encoder) in built {
            incomingDrains[id] = drain(encoder, on: id, generation: generation(of: id) + 1)
        }
    }

    /// Hand a rung's track over to the encoder that reshaped it.
    ///
    /// Called with the keyframe that will be the first object of the new shape,
    /// and returns whether the caller should go on to publish it.
    private func promote(_ layer: LayerID, to encoder: any FrameEncoder) async -> Bool {
        guard let rung = reshaping?.layer(id: layer) else { return false }

        // Generation first, so any output still inside the old session is
        // recognised as stale by the time it arrives.
        generations[layer] = generation(of: layer) + 1

        let retired = encoders[layer]
        encoders[layer] = encoder
        drains[layer]?.cancel()
        drains[layer] = incomingDrains.removeValue(forKey: layer)
        incoming.removeValue(forKey: layer)
        await retired?.close()

        shape = LayerLadder(
            rungs: shape.rungs.map { $0.id == layer ? rung : $0 },
            kind: shape.kind
        )

        // The handover is over when the last rung has switched. Announced then and
        // not per rung: the catalog describes the whole ladder, and republishing it
        // mid-handover would advertise a mixture of shapes that was true for a
        // few milliseconds.
        if incoming.isEmpty {
            reshaping = nil
            handoverBegan = nil
            statistics.reshapes += 1
            statistics.shape = shape
            reshaped.announce(shape)
        }
        return true
    }

    /// Rungs whose encoder is refusing frames, and how many in a row.
    private var refusals: [LayerID: Int] = [:]

    /// How many refusals in a row mean the session is gone rather than busy.
    ///
    /// Back pressure is a frame or two. A VideoToolbox session that has been
    /// invalidated — by memory pressure, by the app losing the encoder to
    /// something else, by a foreground transition it did not survive — refuses
    /// every frame from then on, and the two are the same error to the caller.
    /// Half a second of solid refusals tells them apart.
    private static let refusalsBeforeRebuild = 15

    /// Replace a rung's encoder once it has stopped taking frames altogether.
    ///
    /// Worth the complexity because the failure it fixes is silent and total: a
    /// broadcast in this state still captures, still holds its writers, still
    /// reports itself as live, and sends nothing for the rest of the call. It
    /// showed up in a two-phone run as a picture that froze after seven seconds
    /// on one handset while every other counter looked healthy.
    private func noteRefusal(on layer: LayerID) async {
        let count = (refusals[layer] ?? 0) + 1
        refusals[layer] = count
        guard count == Self.refusalsBeforeRebuild else { return }

        // The shape being published, not the one that was configured. A rung whose
        // encoder dies after a layout change has to come back at the size its
        // subscribers are decoding; rebuilding it from the original ladder would
        // undo the reshape and nothing would say so.
        guard let rung = shape.layer(id: layer) else { return }

        let replacement: any FrameEncoder
        do {
            replacement = try await configuration.encoderFactory(
                EncoderConfiguration(
                    layer: rung,
                    codec: configuration.codec,
                    prefersPowerEfficiency: configuration.prefersPowerEfficiency
                )
            )
        } catch {
            // Left counting. If the platform cannot give out an encoder now it
            // may in a second, and the next refusal after this one will ask
            // again rather than this holding the loop open waiting.
            refusals[layer] = 0
            return
        }

        await encoders[layer]?.close()
        drains[layer]?.cancel()
        encoders[layer] = replacement
        refusals[layer] = 0
        statistics.encodersRebuilt += 1

        // A generation of its own, for the same reason a reshape takes one: the
        // session being replaced may still emit, and its output belongs to a track
        // it no longer owns.
        generations[layer] = generation(of: layer) + 1

        // The new session shares nothing with the old one, so the first frame
        // out of it has to be a keyframe or every subscriber holds a picture
        // that references frames this encoder never produced.
        resumesWithKeyFrame = true

        drains[layer] = drain(replacement, on: layer, generation: generation(of: layer))
    }

    /// One compressed frame becomes one object on one track.
    ///
    /// The generation says which encoder session produced this, and it is checked
    /// rather than trusted because a rung can change shape underneath its own
    /// pipeline. Three cases arrive here and only one of them is ordinary:
    /// output from the session that currently owns the track, the keyframe from a
    /// session that is about to take it over, and — for a frame or two after that
    /// — pictures of the previous shape emerging from a session that has already
    /// been retired.
    private func publish(_ encoded: EncodedFrame, on layer: LayerID, generation: Int) async {
        let current = self.generation(of: layer)
        if generation != current {
            // Ahead of the current generation: this is the replacement encoder's
            // output during a handover. Only its keyframe is publishable, and
            // publishing it is what completes the switch.
            guard
                generation == current + 1,
                encoded.isKeyFrame,
                let encoder = incoming[layer],
                await promote(layer, to: encoder)
            else {
                statistics.framesOutOfShape += 1
                return
            }
        }

        guard let writer = writers[layer], let rung = shape.layer(id: layer) else {
            // Counted, because this used to be the quietest failure in the SDK. A rung with no
            // writer discards every frame the encoder produces, and returning here without
            // saying so left the publication's own statistics describing a healthy broadcast:
            // frames submitted, none encoded, nothing dropped.
            statistics.framesUnroutable += 1
            return
        }

        if let at = submitted[encoded.timestamp] {
            encodeMeter.record(.now - at)
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
                // On every keyframe, not only the ones that change something. A
                // group is then decodable from itself, which is what the relay's
                // cache needs: it keys groups by track name, the shape of a track
                // can change, and nothing in the cache knows that. A joiner handed
                // an older group has to be able to read it without asking what the
                // publisher is doing now.
                configuration: encoded.isKeyFrame ? initialisation[layer] : nil,
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
        statistics.framesEncoded += 1
    }

    /// Whether this rung is being produced.
    ///
    /// Derived rather than stored, so a linger expires on its own without anything having to be
    /// called again. The previous version read `statistics.activeLayers`, which meant the answer
    /// depended on a set that only ``setDemandedLayers(_:pinned:)`` ever wrote — and since
    /// nothing calls that, the set held every rung and this returned true forever.
    private func isActive(_ layer: LayerID) -> Bool {
        guard configuration.stopsUnwatchedLayers else { return true }
        // Nobody has said what is wanted, so everything is. A publisher whose application does
        // not supply demand must keep publishing; going dark would be the worse failure.
        guard let demandedLayers else { return true }
        if demandedLayers.contains(layer) { return true }
        guard let left = leftAt[layer] else { return true }
        return clock.now - left < Self.lingersUnwatched
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

/// The published shape, as it changes.
///
/// A separate object so the stream can be handed out from a non-isolated
/// property: an actor cannot expose its own stored continuation without either
/// making the accessor async, which is awkward at a call site that just wants to
/// start a task, or making the property non-isolated, which a stored actor
/// property cannot be.
private final class Reshapes: Sendable {
    let stream: AsyncStream<LayerLadder>
    private let continuation: AsyncStream<LayerLadder>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(
            of: LayerLadder.self,
            bufferingPolicy: .bufferingNewest(1)
        )
    }

    deinit { continuation.finish() }

    func announce(_ ladder: LayerLadder) { continuation.yield(ladder) }
}

/// Whether capture is producing anything, as that changes.
///
/// Separate from the actor for the same reason as ``Reshapes``: a stored
/// continuation cannot be handed out from an actor's non-isolated property.
private final class Stalls: Sendable {
    let stream: AsyncStream<Bool>
    private let continuation: AsyncStream<Bool>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(
            of: Bool.self,
            bufferingPolicy: .bufferingNewest(1)
        )
    }

    deinit { continuation.finish() }

    func announce(_ stalled: Bool) { continuation.yield(stalled) }
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
