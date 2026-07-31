// The room, as the views need it.
//
// This exists because a view cannot read an actor synchronously and a view body
// must not await. So the actor's event stream is drained into main-actor
// properties once, here, and the views read plain values — which is also the
// only way `roster` can be indexed during layout without the roster changing
// halfway through a diff.
//
// Note what is *not* mirrored: `watchdogs` is a separate property from
// `participants`, and there is no combined list. That is not a UI preference,
// it is the SDK's type structure showing through — `Roster` cannot hold a
// `Watchdog`, so a view that wanted them in one array would have to build the
// union deliberately rather than forget to exclude one.

import AVFoundation
import Foundation
import MoqomCore
import MoqomKit
import Observation

@MainActor
@Observable
final class RoomModel {
    private(set) var participants: [Participant] = []
    private(set) var watchdogs: [Watchdog] = []
    private(set) var stage = StageState()
    private(set) var lifecycle: RoomLifecycle = .live
    private(set) var isBroadcasting = false
    private(set) var isPublishingAudio = false
    private(set) var lastError: MoqomError?

    /// Where published audio comes from.
    ///
    /// A tone by default so the sample runs in a simulator with no input device
    /// and asks for no permission it does not need. The microphone is the option
    /// that matters on a device, and it is the only way to check the thing that
    /// cannot be checked anywhere else: whether the room's own output is being
    /// cancelled before it goes back up the uplink.
    var audioInput: AudioInput = .tone

    /// What the microphone is hearing. ``AudioMeter/quiet`` unless capturing.
    ///
    /// This is the instrument for the speakerphone test. Put a cohost's voice on
    /// the speaker, say nothing, and watch the level: at the noise floor means
    /// the canceller has its reference, and tracking the far end means it does
    /// not and everybody in the room is about to hear themselves.
    private(set) var meter = AudioMeter.quiet

    /// Whether the system agreed to cancel echo. Asking is not getting.
    private(set) var isCancellingEcho = false

    /// Turn the processing off without taking the graph down.
    ///
    /// The measurement instrument. Cancellation is invisible when it works, so
    /// the only way to know it is working is to remove it and watch the level
    /// rise by however much it was subtracting.
    var isBypassingVoiceProcessing: Bool {
        get { AudioGraph.shared.isBypassingVoiceProcessing }
        set { AudioGraph.shared.isBypassingVoiceProcessing = newValue }
    }

    enum AudioInput: String, CaseIterable, Identifiable, Sendable {
        case tone = "Tone"
        case microphone = "Microphone"

        var id: String { rawValue }
    }

    /// Where published video comes from.
    ///
    /// A rendered pattern by default, for the same reason the audio default is a
    /// tone: the sample has to run in a simulator with nothing attached and ask
    /// for no permission it does not need. The camera is the option that makes
    /// switching and mirroring mean anything, and neither can be judged from a
    /// pattern — a test card looks the same either way round.
    ///
    /// Only read when a broadcast starts. Changing it mid-broadcast would mean
    /// swapping the ``FrameSource`` the publication is bound to, which is a stop
    /// and a restart; switching between the two *cameras* is the thing that does
    /// not need one, and that is ``flipCamera()``.
    var videoInput: VideoInput = .pattern

    /// Publish exactly this rung and nothing else, when set.
    ///
    /// A ladder is right for a call and wrong for a measurement. Three rungs is three
    /// encode sessions sharing one hardware encoder, and a viewer that is free to move
    /// between them whenever the estimate wobbles — so a latency or bitrate figure taken
    /// across the run describes no single rung. Pinning one makes both ends agree on what
    /// is being measured.
    var pinnedRung: VideoLayer?

    /// A clock the other device also has, for measuring the gap between them.
    ///
    /// When set, published frames are stamped on it and received frames are measured
    /// against it. Absent, neither happens and the room behaves as it always did.
    var trustedStamp: (@Sendable () -> Timecode)?

    /// What the far side's frames cost to arrive.
    let latency = LatencyMeter()

    /// Whether they arrive evenly, which needs no clock agreement and so is measured even
    /// when the latency figures are unavailable.
    let cadence = CadenceMeter()

    /// How evenly the publisher's own timestamps are spaced, which is the timeline the
    /// picture is presented against.
    let timeline = TimelineMeter()

    /// The same, on the frames this device is capturing, so the two can be compared.
    let captureCadence = CadenceMeter()

    /// Encode one flat layer rather than two temporal ones. See ``LaunchOptions/flatLayers``.
    var flatLayers = false

    /// How often to sample the SDK's statistics.
    private let statisticsInterval: Duration

    /// How long remote tiles hold frames before showing them, or nil to show them on arrival.
    ///
    /// See ``VideoRenderer/playoutDelay``. Ignored while ``playoutBounds`` is set, which is the
    /// default: a figure chosen here would be chosen for one link on one afternoon.
    var playoutDelay: Duration? = .milliseconds(80)

    /// Bounds the playout delay sizes itself within. See ``VideoRenderer/playoutBounds``.
    ///
    /// Adaptive by default, and from a floor of ten milliseconds, because measuring it settled the
    /// question this used to guess at: on a relayed 60fps link, ten milliseconds of buffer showed
    /// no visible unevenness and lost two frames in two thousand, while the same link's arrival
    /// tail reached 140ms often enough to wreck a fixed setting anywhere near the floor. The
    /// ceiling is generous because it is only reached while the link is misbehaving, and a quarter
    /// second of delay is much better than the alternative during that.
    var playoutBounds: (floor: Duration, ceiling: Duration)? = (
        floor: .milliseconds(10),
        ceiling: .milliseconds(250)
    )

    /// The delay currently in force on a remote tile, for display. See
    /// ``VideoRenderer/playoutDepth``.
    var playoutDepth: Duration = .zero

    /// How many frames the adaptive delay may leave unshown. See
    /// ``VideoRenderer/playoutTolerance``.
    var playoutTolerance = 0.01

    /// Seconds of headroom the arriving frames actually have. See ``VideoRenderer/playoutSlack``.
    var playoutSlack: Double?

    /// What the remote tile did with the frames it was handed. See ``VideoRenderer/drawing``.
    var drawing = VideoRenderer.Drawing()

    /// What the display layer did with the frames, sampled from the renderer.
    var presentation: VideoRenderer.Presentation?

    private var captureCadenceTask: Task<Void, Never>?

    enum VideoInput: String, CaseIterable, Identifiable, Sendable {
        case pattern = "Test pattern"
        case camera = "Camera"

        var id: String { rawValue }
    }

    /// Which camera is open, when broadcasting from one.
    private(set) var cameraPosition: CameraPosition = .front

    /// Whether the self-preview is drawn flipped.
    ///
    /// Follows the camera rather than being a preference, because it is not
    /// really one: a front-camera preview that is not mirrored feels broken to
    /// the person in it, and a back-camera preview that is mirrored feels broken
    /// to everyone. Only what is *published* is a matter of taste, and this
    /// sample publishes the truth.
    var isPreviewMirrored: Bool { videoInput == .camera && cameraPosition.wantsMirroredPreview }

    /// Whether this device has muted its own microphone.
    var isMicrophoneMuted: Bool { selfMuted.contains(.audio) }

    /// Whether this device has muted its own camera.
    var isCameraMuted: Bool { selfMuted.contains(.video) }

    private(set) var selfMuted: MediaKind = []

    /// What each participant says they are publishing.
    private(set) var catalogs: [ParticipantIdentity: Catalog] = [:]

    /// Who brought the viewers.
    ///
    /// A figure to display and never a tick to animate: the authority quantises the counts
    /// and publishes them on a timer, so this changes every few seconds at most.
    private(set) var audiences = Audiences()

    /// Who the Picture in Picture window draws when the app is backgrounded.
    ///
    /// A separate question from ``boxes``, and deliberately so: the window is a
    /// few hundred points over somebody else's app, so the interesting default
    /// is not "the gallery, smaller" but "the one or two people worth watching
    /// at that size".
    var cast: CastChoice = .speaker {
        didSet {
            guard cast != oldValue else { return }
            Task { await room.setPictureInPictureCast(cast.cast) }
        }
    }

    /// Live, once the window is up. Drives nothing; shown so the state is legible.
    var isInPictureInPicture: Bool {
        #if os(iOS)
            pictureInPicture?.isActive ?? false
        #else
            false
        #endif
    }

    #if os(iOS)
        /// Owns the AVKit controller and the borrowed layers.
        ///
        /// Held here rather than in a view because the window outlives the view
        /// that started it — that is the entire feature.
        private(set) var pictureInPicture: MoqomPictureInPicture?

        /// The Lock Screen card, while broadcasting.
        private var card: BroadcastLiveActivity?
        private var cardTask: Task<Void, Never>?
    #endif

    /// Which of the two layouts the room is in.
    ///
    /// Both are the same SDK machinery with a different bound: the gallery caps
    /// occupancy at what the device can decode, and the audio room caps it at how
    /// many seats the design draws, which is a bigger number because an avatar is
    /// not a decoder.
    var mode: Mode = .gallery {
        didSet {
            guard mode != oldValue else { return }
            Task { await applyMode() }
        }
    }

    /// How many tiles the gallery draws.
    ///
    /// A control in the sample because it is the number a real client should be
    /// lowering under thermal pressure, and having it on screen makes the
    /// consequence — which participants keep video and which keep only audio —
    /// something you can watch happen.
    var boxes = 9 {
        didSet {
            guard boxes != oldValue else { return }
            Task { await applyMode() }
        }
    }

    /// Who to draw, in what order, from the SDK.
    ///
    /// Excludes this device: the self tile is drawn from the capture preview, not
    /// from a subscription to our own upload.
    private(set) var slots: [Gallery.Slot] = []

    /// In the room, without a tile. They are still audible.
    private(set) var overflow: [ParticipantIdentity] = []

    enum Mode: String, CaseIterable, Identifiable, Sendable {
        case gallery = "Gallery"
        case audioRoom = "Audio room"

        var id: String { rawValue }

        var seatAspect: Double { self == .gallery ? 16.0 / 9.0 : 1 }
    }

    /// Everything the SDK measures, resampled a few times a second.
    ///
    /// Nothing in the app supplies any of this. It is what makes the difference
    /// between a quality selector that guesses and one that knows.
    private(set) var statistics: RoomStatistics?

    /// What the SDK measures the downlink to be carrying.
    var link: LinkStatistics { statistics?.link ?? .unknown }

    /// How this device's connection looks, and how everyone else's does.
    ///
    /// Two values because they answer different questions. A viewer whose own
    /// link is failing should be told to check their network; a viewer watching
    /// one cohost on a train should be told which cohost.
    var quality: ConnectionQuality { statistics?.quality ?? .unknown }

    private(set) var qualities: [ParticipantIdentity: ConnectionQuality] = [:]

    /// What this device may do, as granted by its token.
    ///
    /// Hard-coded to owner in the sample. In a real client it is decoded from
    /// the CAT and never inferred from a role name, because roles are a
    /// rendering of capabilities rather than the other way round.
    let grants = Grants(publish: .full, moderation: .owner, isOwner: true)

    let identity: ParticipantIdentity
    let layout = LayoutObserver()

    private let session: MoqomSession
    private let room: RoomSession
    private var pump: Task<Void, Never>?
    private var sampler: Task<Void, Never>?
    private var connection: Task<Void, Never>?
    private var capture: PatternSource?
    private var camera: CameraSource?

    /// Kept so a camera switch can ask for a keyframe. Nothing else here needs
    /// it — the room owns the publication's lifetime.
    private var broadcast: Broadcast?

    private var microphone: AudioRelay?
    private var toneTask: Task<Void, Never>?
    private var mic: MicrophoneSource?
    private var meterTask: Task<Void, Never>?

    /// One player per participant, because the relay forwards rather than mixes
    /// and mixing here would throw away per-participant volume and mute.
    ///
    /// They all share one audio graph, which is a different question and has the
    /// opposite answer: the device has one speaker, and the echo canceller in
    /// front of the microphone can only subtract audio it was given. Players on
    /// separate graphs would each be echo somebody else hears.
    private var players: [ParticipantIdentity: AudioPlayer] = [:]
    private var playback: [ParticipantIdentity: Task<Void, Never>] = [:]

    init(
        session: MoqomSession,
        room: RoomSession,
        identity: ParticipantIdentity,
        statisticsInterval: Duration = .milliseconds(250)
    ) {
        self.session = session
        self.room = room
        self.identity = identity
        self.statisticsInterval = statisticsInterval
        layout.bind(to: room)
        #if os(iOS)
            pictureInPicture = MoqomPictureInPicture(room: room, layout: layout)
            pictureInPicture?.onFailure = { [weak self] error in
                // Almost always the missing background mode, and worth
                // surfacing rather than swallowing: the failure is silent
                // otherwise, and looks like the feature simply not working.
                self?.lastError = .invalidState(
                    expected: "picture in picture available",
                    actual: error.localizedDescription
                )
            }
        #endif
        start()
    }

    var roomName: String { room.room.value }

    /// Everyone but this device, which is rendered as the local preview.
    var remoteParticipants: [Participant] {
        participants.filter { $0.slot.identity != identity }
    }

    private func start() {
        pump = Task { [weak self, room] in
            for await event in room.events {
                await self?.apply(event)
            }
        }

        // Four times a second, which is faster than a person reads a number and
        // slow enough to be free. The stream ends itself when the room does.
        //
        // Adjustable because "slow enough to be free" is a claim, and a viewer describing a
        // stutter every quarter of a second is describing this interval. Turning it down is how
        // that gets confirmed or ruled out rather than argued about.
        let period = statisticsInterval
        sampler = Task { [weak self, room] in
            for await snapshot in await room.statistics(every: period) {
                self?.observe(snapshot)
            }
        }
        watchConnection()

        Task {
            await applyMode()
            await room.setPictureInPictureCast(cast.cast)
            await refresh()
        }
    }

    private func observe(_ snapshot: RoomStatistics) {
        statistics = snapshot
    }

    /// What the transport is doing, printed as it changes.
    ///
    /// A dropped connection is invisible in the per-second metrics: they keep
    /// reporting, on a stream that stopped, and the numbers describe a link that
    /// no longer exists. Half an hour was spent reading those numbers before the
    /// relay's own log said the connection had been torn down and rebuilt — so
    /// the client says it too, in the same log as everything else.
    private func watchConnection() {
        connection = Task { [weak self, session] in
            for await state in session.states {
                guard self != nil else { return }
                print("SESSION \(state.description)")
            }
        }
    }

    private func apply(_ event: RoomEvent) async {
        switch event {
        case .watchdogChanged(let set):
            watchdogs = set.all
        case .stageChanged(let updated):
            stage = updated
        case .lifecycleChanged(let updated):
            lifecycle = updated
        case .catalogChanged(let who, let catalog):
            catalogs[who] = catalog
            if catalog.audioTrack != nil { await startPlayback(for: who) }
        case .galleryChanged(let updated):
            // Carries speaking state as well as occupancy, so this one event
            // drives both the rings and the layout — and because a tile holds its
            // position while it is held, the common case is a ring changing and
            // nothing moving.
            slots = updated
            overflow = await room.galleryOverflow
        case .participantLeft(let who, _):
            catalogs.removeValue(forKey: who)
            await stopPlayback(for: who)
            await refresh()
        case .audiencesChanged(let updated):
            audiences = updated
        case .broadcastInterrupted:
            // Said in the interface rather than only in a log. Everything on screen still
            // looks live — the preview is running, the timer is counting — and nobody is
            // receiving any of it.
            lastError = MoqomError.invalidState(
                expected: "a broadcast on a live session",
                actual: "a publication that could not be reopened after reconnecting"
            )
        case .qualityChanged(let who, let quality):
            // Applied straight rather than through `refresh()`: the indicator is
            // the only thing that changed, and rebuilding the roster to draw one
            // badge would reshuffle a grid because somebody's train went into a
            // tunnel.
            qualities[who] = quality
        case .pictureInPictureChanged:
            // Nothing to do here. The window's occupancy reaches the controller
            // on its own stream; this arrives so an app that wants to draw a
            // "2 in the small window" hint has somewhere to notice it.
            break
        case .participantJoined, .presenceChanged,
             .muteChanged, .grantsChanged, .spotlightChanged:
            await refresh()
        case .terminated:
            await leave()
        }
    }

    private func refresh() async {
        participants = await room.roster.participants
        slots = await room.galleryLayout
        overflow = await room.galleryOverflow

        // Read back rather than assumed from the last call, because a moderator
        // can change what is muted without this device asking.
        selfMuted = await room.selfMuted
    }

    private func applyMode() async {
        switch mode {
        case .gallery:
            await room.setGalleryPolicy(.grid(boxes: boxes))
        case .audioRoom:
            await room.setGalleryPolicy(.audioRoom(seats: max(boxes, 12)))
        }
        applyAudioPurpose()
    }

    /// Configure the system for what this device is actually doing.
    ///
    /// The distinction that matters is publishing versus not. A viewer who has
    /// not gone on stage should hold no microphone at all: no orange indicator for
    /// an app that is only listening, no input device taken from other apps, and —
    /// the one that decides whether an audio room is usable — audio that keeps
    /// playing when the screen locks.
    ///
    /// Called on the transitions rather than on every mute, because the category
    /// is fixed when the engine starts and changing it restarts the engine. A
    /// speaker toggling their microphone stays on a recording session; leaving the
    /// stage entirely is what moves them off it.
    private func applyAudioPurpose(publishing: Bool? = nil) {
        let purpose: AudioGraph.Purpose
        if publishing ?? (isPublishingAudio || isBroadcasting) {
            purpose = mode == .audioRoom ? .voiceCall : .videoCall
        } else {
            purpose = .listening
        }

        guard AudioGraph.shared.configuration.purpose != purpose else { return }
        do {
            try AudioGraph.shared.reconfigure(
                AudioGraph.Configuration(purpose: purpose)
            )
        } catch {
            // A device that will not reconfigure its session is a reason to keep
            // listening on whatever it has, not to leave the room.
            lastError = error
        }
    }

    /// Guarantee a participant a tile, for this viewer only.
    ///
    /// Immediate rather than subject to the dwell that keeps speech from
    /// rearranging the grid: this is somebody having tapped a button.
    func togglePin(_ target: ParticipantIdentity) async {
        if slots.first(where: { $0.identity == target })?.claim == .pinned {
            await room.unpin(target)
        } else {
            await room.pin(target)
        }
    }

    func isSpeaking(_ target: ParticipantIdentity) -> Bool {
        slots.first { $0.identity == target }?.isSpeaking ?? false
    }

    /// The participant behind a tile, for the views that need the whole record.
    func participant(_ target: ParticipantIdentity) -> Participant? {
        participants.first { $0.slot.identity == target }
    }

    /// The best rung a participant is offering, for the tile's quality badge.
    ///
    /// From their catalog rather than from an assumption, which is the whole
    /// reason the catalog exists: this label is correct for a publisher whose
    /// ladder we have never seen before.
    func quality(of who: ParticipantIdentity) -> String? {
        guard let best = catalogs[who]?.videoLadder.highest else { return nil }
        return "\(best.size.height)p"
    }

    /// Decodable frames for one participant.
    ///
    /// The SDK reassembles: it drops what precedes the first keyframe, notices
    /// gaps, and attaches the parameter sets the catalog carried. All this
    /// view has to do is draw.
    func frames(of who: ParticipantIdentity) async -> AsyncStream<DepacketisedFrame>? {
        await room.frames(from: who)
    }

    /// What codec a participant's current rung is in, once their catalog says.
    func codec(of who: ParticipantIdentity) async -> VideoCodec? {
        await room.codec(of: who)
    }

    /// This device's own capture, for the self tile.
    ///
    /// Straight off the source rather than round-tripped through the relay:
    /// previewing the encoded stream would show the publisher their own
    /// latency and their own compression artefacts.
    ///
    /// The camera goes through a tap rather than a second `frames()` call,
    /// because a ``FrameSource`` has one consumer and the publication is
    /// already it — iterating twice would silently give each side half the
    /// frames. A tap is what the SDK provides for exactly this, and it copies
    /// nothing: the preview draws the same surface the encoder is reading.
    ///
    /// Notice that the preview keeps running while the camera is muted, and
    /// that is deliberate. The person who muted needs to see what they will be
    /// sending when they come back, which is why every video app shows you
    /// yourself even with the camera off to everyone else.
    /// Time the frames going into the encoder, on their own tap.
    private func watchCaptureCadence(of publication: Broadcast) {
        captureCadenceTask?.cancel()
        captureCadenceTask = Task { [captureCadence] in
            let tap = await publication.tapFrames(
                policy: TapPolicy(cadence: .everyFrame, depth: 2)
            )
            for await _ in tap.elements { captureCadence.record() }
        }
    }

    /// A tap per caller, and never a shared stream.
    ///
    /// This used to hand every caller one stream, which is the mistake ``FrameSource`` warns
    /// about: an `AsyncStream` has a single consumer, so a second view iterating it does not
    /// get a copy of the frames — between them they get one each, and in practice the newer
    /// iterator gets nothing at all.
    ///
    /// It broke at a layout change rather than at a join, which is what made it look like a
    /// network fault. A solo broadcaster draws one full-size self view; the moment somebody
    /// else appears, that view is replaced by a thumbnail beside the gallery, SwiftUI builds a
    /// new one, and the new one asked for the stream the old one already owned. The camera
    /// never stopped and the encoder never faltered — there was simply nobody left who could
    /// read the frames.
    ///
    /// The caller owns what it gets and must stop it. A tap left running holds a place in the
    /// publication's delivery list and a pixel buffer from the pool the capture path draws
    /// from.
    func localPreview() async -> MediaTap<VideoFrame>? {
        // Off the publication rather than off the source, so the pattern and the camera take
        // the same path. `Broadcast.stop()` stops every tap it handed out, which is what ends
        // each view's pump when the broadcast does.
        await broadcast?.tapFrames(policy: TapPolicy(cadence: .everyFrame, depth: 2))
    }

    // MARK: - Broadcasting

    func startBroadcast() async {
        guard !isBroadcasting else { return }

        // A rendered pattern by default rather than a camera or a scene, so the
        // sample runs in a simulator with nothing attached — and unlike an
        // empty relay, it produces pixels that actually encode. `SceneCapture`
        // is the third option a real build reaches for.
        // Capture what the rung says it publishes. A capture format chosen independently of the
        // ladder is how a run claims sixty frames while the camera hands over thirty.
        let size = pinnedRung?.size ?? PixelSize(width: 1280, height: 720)
        let format = CaptureFormat(size: size, frameRate: pinnedRung?.frameRate ?? 30)

        let source: any FrameSource
        switch videoInput {
        case .pattern:
            let pattern = PatternSource(format: format, label: identity.username.value)
            capture = pattern
            source = pattern
        case .camera:
            do {
                // The SDK deliberately does not prompt — it says so on
                // `CameraSource.start()` — because the prompt belongs where the
                // app can explain itself rather than at the moment a broadcast
                // starts. This is that place.
                guard await Self.cameraIsAuthorised() else {
                    throw MoqomError.platform(api: "AVCaptureDevice.requestAccess", status: -1)
                }
                let device = try CameraSource(
                    format: format,
                    position: cameraPosition,
                    logger: MoqomLogger(
                        sink: SystemLogSink(subsystem: "cloud.moqom.sample", privacy: .hashed),
                        minimum: .debug
                    )
                )
                device.start()
                camera = device
                source = device
            } catch {
                // Falling back rather than failing the broadcast. A simulator
                // has no camera and the interesting half of the sample — the
                // room, the gallery, the mute controls — should not be
                // unreachable because of it.
                lastError = error as? MoqomError
                videoInput = .pattern
                let pattern = PatternSource(format: format, label: identity.username.value)
                capture = pattern
                source = pattern
            }
        }

        do {
            // The ladder is capped at what is being captured. The default goes
            // to 1080p, and a 1080p rung fed 720p frames publishes an upscale:
            // the catalog says 1080p, the viewer subscribes for it, and the
            // extra bitrate buys nothing.
            let ladder = pinnedRung.map { LayerLadder(rungs: [$0]) }
                ?? .defaultCamera(topSize: size)
            let published = trustedStamp.map { TimedSource(source, stamp: $0) } ?? source
            var encoders: EncoderFactory = defaultEncoderFactory
            if flatLayers {
                encoders = { configuration in
                    var flat = configuration
                    flat.usesTemporalLayers = false
                    return try await defaultEncoderFactory(flat)
                }
            }
            let publication = try await room.startBroadcast(
                from: published,
                configuration: BroadcastConfiguration(ladder: ladder, encoderFactory: encoders)
            )
            await publication.start()
            broadcast = publication
            isBroadcasting = true

            // The same measurement as the receiving end, on the frames going in. It is the
            // only way to tell an uneven picture apart from an uneven network: if capture is
            // already lumpy the far end can do nothing but reproduce it, and if capture is
            // even then everything between here and there owns the difference.
            if pinnedRung != nil { watchCaptureCadence(of: publication) }
            applyAudioPurpose()
            #if os(iOS)
                await startLiveActivity()
            #endif
            await refresh()
        } catch {
            lastError = error
            source.stop()
            capture = nil
            camera = nil
            broadcast = nil
        }
    }

    /// Ask once, and answer from the recorded decision after that.
    private static func cameraIsAuthorised() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .video)
        default: false
        }
    }

    // MARK: - Camera and mute

    /// Swap front camera for back, or back for front.
    ///
    /// The publication is untouched: the same ``CameraSource`` keeps feeding the
    /// same encoders, so nobody watching sees the participant leave and come
    /// back. What they do see is a new scene, hence the keyframe — without it
    /// the encoder would predict the far side of the room from the near side of
    /// someone's face and take a second to admit it was wrong.
    func flipCamera() async {
        guard let camera else { return }
        let wanted = cameraPosition.flipped
        do {
            try camera.setPosition(wanted)
            cameraPosition = wanted
            await broadcast?.startNewGroup()
        } catch {
            lastError = error as? MoqomError
        }
    }

    func setMicrophoneMuted(_ muted: Bool) async {
        await setSelfMuted(muted ? selfMuted.union(.audio) : selfMuted.subtracting(.audio))
    }

    func setCameraMuted(_ muted: Bool) async {
        await setSelfMuted(muted ? selfMuted.union(.video) : selfMuted.subtracting(.video))
    }

    private func setSelfMuted(_ kinds: MediaKind) async {
        await room.setSelfMuted(kinds)
        selfMuted = await room.selfMuted
    }

    /// Publish audio, from whichever input is selected.
    func startAudio() async {
        guard !isPublishingAudio else { return }

        // Before the capture rather than after it. `AudioGraph.microphone()`
        // refuses on a listening graph, and should: a playback session has no
        // input to tap, and returning a relay that would stay silent forever is
        // the worse of the two behaviours.
        applyAudioPurpose(publishing: true)

        switch audioInput {
        case .tone: await startTone()
        case .microphone: await startMicrophone()
        }

        applyAudioPurpose()
    }

    /// Publish the real microphone, through the shared audio graph.
    ///
    /// Which is the whole point of doing it here: the graph this capture runs on
    /// is the same one every `AudioPlayer` in `startPlayback` mixes into, so the
    /// canceller's reference contains the cohosts. Nothing in this method says
    /// so, and that is the intent — the correct arrangement is the default, and
    /// an integrator gets it without knowing it was a decision.
    private func startMicrophone() async {
        let source: MicrophoneSource
        do {
            source = try MicrophoneSource()
            try source.start()
        } catch {
            lastError = error
            return
        }

        do {
            let publication = try await room.startAudio(from: source)
            await publication.start()
            isPublishingAudio = true
        } catch {
            lastError = error
            source.stop()
            return
        }

        mic = source
        isCancellingEcho = source.isCancellingEcho

        // Ten times a second, which is faster than anybody reads a number and
        // slow enough to be free. A meter driven off every 20ms packet would
        // redraw the interface fifty times a second to say the same thing.
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.meter = source.meter
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func startTone() async {
        let relay = AudioRelay()
        microphone = relay

        do {
            let publication = try await room.startAudio(from: relay)
            await publication.start()
            isPublishingAudio = true
        } catch {
            lastError = error
            microphone = nil
            return
        }

        toneTask = Task { [weak self] in
            let format = AudioFormat.voice
            var phase = 0.0
            var timestamp: UInt64 = 0
            let step = 2 * Double.pi * 440 / Double(format.sampleRate)
            while !Task.isCancelled {
                var samples = [Float](repeating: 0, count: format.samplesPerFrame)
                for index in samples.indices {
                    samples[index] = Float(sin(phase)) * 0.2
                    phase += step
                }
                relay.submit(
                    AudioFrame(
                        timestamp: FrameTimestamp(nanoseconds: timestamp),
                        format: format,
                        samples: samples
                    )
                )
                timestamp += 20_000_000
                try? await Task.sleep(for: .milliseconds(20))
            }
            _ = self
        }
    }

    /// Hear a cohost.
    ///
    /// Started from their catalog rather than from a button, because a viewer
    /// who joined a room expects to hear it. Stopping is `toggleLocalMute`,
    /// which unsubscribes rather than turning the volume down.
    private func startPlayback(for who: ParticipantIdentity) async {
        guard who != identity, playback[who] == nil else { return }
        guard let outputs = await room.audio(from: who) else { return }

        let player: AudioPlayer
        do {
            player = try AudioPlayer()
        } catch {
            // Not surfaced as an alert. A device with no output is a reason to
            // stay in the room silently, not a reason to leave it.
            return
        }
        players[who] = player
        playback[who] = Task { try? await player.play(outputs) }
    }

    private func stopPlayback(for who: ParticipantIdentity) async {
        playback.removeValue(forKey: who)?.cancel()
        if let player = players.removeValue(forKey: who) {
            await player.stop()
        }
    }

    func stopAudio() async {
        toneTask?.cancel()
        toneTask = nil
        meterTask?.cancel()
        meterTask = nil
        await room.stopAudio()
        mic?.stop()
        mic = nil
        microphone = nil
        isPublishingAudio = false
        isCancellingEcho = false
        meter = .quiet
        applyAudioPurpose()
    }

    func stopBroadcast() async {
        guard isBroadcasting else { return }
        await room.stopBroadcast()
        capture = nil
        camera = nil
        broadcast = nil
        captureCadenceTask?.cancel()
        captureCadenceTask = nil
        isBroadcasting = false
        applyAudioPurpose()
        #if os(iOS)
            // The card exists to say this device is live, so it comes down with the
            // publication and not with the room. Left to `leave()`, stopping a broadcast and
            // staying in the room leaves a Lock Screen card claiming a broadcast that ended,
            // for as long as the system will show one.
            endLiveActivity()
        #endif
        await refresh()
    }

    // MARK: - Per-viewer mute

    /// Silence one cohost for this viewer only.
    ///
    /// Never leaves the device. The relay forwards rather than mixes, so this
    /// is an unsubscribe: instant, private, and a bandwidth saving rather than
    /// a request for permission.
    func toggleLocalMute(_ target: ParticipantIdentity) async {
        guard let participant = participants.first(where: { $0.slot.identity == target }) else {
            return
        }
        if participant.mute.localToMe.contains(.audio) {
            await room.localUnmute(target, .audio)
            if catalogs[target]?.audioTrack != nil { await startPlayback(for: target) }
        } else {
            await room.localMute(target, .audio)

            // The unsubscribe ends the stream, which ends `play`, but the
            // engine stays up holding an output device it no longer needs.
            await stopPlayback(for: target)
        }
        await refresh()
    }

    // MARK: - Moderation

    func moderate(_ action: ModerationAction) async {
        do {
            try await room.moderate(action, as: grants)
            await refresh()
        } catch {
            lastError = error
        }
    }

    func attachRecorder() async {
        do {
            try await room.manageWatchdog(
                .attach(
                    WatchdogRequest(
                        kind: .recording,
                        operatedBy: .tenant,
                        descriptor: "Session recording",
                        scope: room.namespace
                    )
                ),
                as: grants
            )
        } catch {
            lastError = error
        }
    }

    func dismissError() { lastError = nil }

    func leave() async {
        toneTask?.cancel()
        toneTask = nil
        pump?.cancel()
        pump = nil
        sampler?.cancel()
        sampler = nil
        connection?.cancel()
        connection = nil
        #if os(iOS)
            pictureInPicture?.stop()
            endLiveActivity()
        #endif
        for who in playback.keys { await stopPlayback(for: who) }
        await session.close()
    }

    // MARK: - Live Activity

    #if os(iOS)
        /// Put the broadcast on the Lock Screen, and keep it current.
        ///
        /// Started from ``startBroadcast()`` rather than from joining, because a
        /// card that says "live" for a viewer is a lie, and the system charges
        /// the same budget either way.
        private func startLiveActivity() async {
            guard BroadcastLiveActivity.isPermitted, card == nil else { return }

            // Anything still showing belongs to a process that is gone, since a card this
            // one started would be held in `card` above. Cleared rather than left, or a
            // relaunch after a crash puts a second entry in Notification Centre beside a
            // stale one that will never update again.
            await BroadcastLiveActivity.endAll()

            let card = BroadcastLiveActivity(logger: .silent)
            do {
                try card.start(
                    MoqomBroadcastAttributes(
                        title: "Room \(roomName)",
                        host: identity.username.value,
                        room: room.room
                    ),
                    state: BroadcastActivityState(
                        phase: .live,
                        startedAt: .now,
                        participants: participants.count,
                        quality: quality
                    )
                )
            } catch {
                lastError = error as? MoqomError
                return
            }

            self.card = card

            // One call, and the card tracks the room from here: participant
            // count, who is talking, connection quality, and the mute and
            // camera state of this device. The throttle inside it is what keeps
            // that from spending the system's update budget in the first minute.
            cardTask = card.follow(room)
        }

        private func endLiveActivity() {
            cardTask?.cancel()
            cardTask = nil
            card?.end(card?.showing.map { var last = $0; last.phase = .ended; return last })
            card = nil
        }

        /// Clear the Lock Screen card, including one this launch never started.
        ///
        /// Exposed as a control because the card that needs clearing is usually not one the
        /// app is holding: a Live Activity survives the process that requested it, so a
        /// force quit during a broadcast leaves a card behind that nothing here has a
        /// reference to and the system will show for hours. Ending only ``card`` would leave
        /// exactly the case a person is looking at when they reach for this.
        func clearBroadcastCard() async {
            endLiveActivity()
            await BroadcastLiveActivity.endAll()
        }
    #endif
}
