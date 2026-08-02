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
    /// The microphone on a device and a tone in a simulator, for the same reason the video
    /// default follows the camera: a phone that publishes beeps until somebody finds the
    /// picker reads as broken audio rather than as a deliberate default.
    ///
    /// The tone is still worth having, and not only for the simulator. Two phones on one desk
    /// publishing microphones is a feedback loop, and what a benchmark measures then is the
    /// room.
    ///
    /// Changing it while publishing swaps the source, which is a stop and a start of the audio
    /// publication — done here rather than refused, because refusing it is what a person meets
    /// as a picker that will not move.
    #if targetEnvironment(simulator)
        var audioInput: AudioInput = .tone { didSet { swapAudioInput(from: oldValue) } }
    #else
        var audioInput: AudioInput = .microphone { didSet { swapAudioInput(from: oldValue) } }
    #endif

    private func swapAudioInput(from previous: AudioInput) {
        guard audioInput != previous, isPublishingAudio else { return }
        Task {
            await stopAudio(deliberately: false)
            await startAudio()
        }
    }

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
    /// The camera on a device that has one, and the pattern where there is none. Defaulting
    /// to the pattern everywhere meant a phone that showed a moving gradient until somebody
    /// found the picker, which reads as a broken camera rather than as a deliberate default.
    #if targetEnvironment(simulator)
        var videoInput: VideoInput = .pattern
    #else
        var videoInput: VideoInput = .camera
    #endif

    /// Publish exactly this rung and nothing else, when set.
    ///
    /// Set for every run now, not just a measured one, because the publisher is the end that
    /// decides. Three rungs is three encode sessions sharing one hardware encoder — measured
    /// on these two phones, 1,491 frames in and 4,472 out, the 15 Pro at `thermal=serious`
    /// and a write that stalled for a second — to produce two pictures nobody asked for.
    ///
    /// And the choosing was worse than the encoding. A receiver free to move between rungs
    /// moved a 607×1349 tile down to 180p on a bandwidth estimate that could not rise,
    /// because the estimate can only measure the rung it is already receiving; then no object
    /// arrived on the new rung at all and the tile went black for the rest of the call, with
    /// the audio still perfect. One rung, chosen here, removes the switch and the arithmetic
    /// behind it. See ``publishSize``.
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

    /// Ask the encoder for speed rather than power. See ``LaunchOptions/eagerEncoding``.
    var encodesEagerly = false

    /// How often to sample the SDK's statistics.
    private let statisticsInterval: Duration

    /// How long remote tiles hold frames before showing them, or nil to show them on arrival.
    ///
    /// See ``VideoRenderer/playoutDelay``. Ignored while ``playoutBounds`` is set, which is the
    /// default: a figure chosen here would be chosen for one link on one afternoon.
    var playoutDelay: Duration? = .milliseconds(80)

    /// Bounds the playout delay sizes itself within. See ``VideoRenderer/playoutBounds``.
    ///
    /// Adaptive by default, and from a floor of nothing at all, because every floor tried here
    /// turned out to be the answer rather than a bound: the delay sat on ten, then on five, so
    /// the figure being measured was the setting. Zero declines to guess. What the delay settles
    /// at is then set by the link — the renderer keeps a few milliseconds of margin so a frame is
    /// not at the mercy of the next refresh, and adds to it only as far as the jitter demands.
    /// The ceiling is generous because it is only reached while the link is misbehaving, and a
    /// quarter second of delay is much better than the alternative during that.
    var playoutBounds: (floor: Duration, ceiling: Duration)? = (
        floor: .zero,
        ceiling: .milliseconds(250)
    )

    /// The delay currently in force on a remote tile, for display. See
    /// ``VideoRenderer/playoutDepth``.
    var playoutDepth: Duration = .zero

    /// How many frames the adaptive delay may leave unshown. See
    /// ``VideoRenderer/playoutTolerance``.
    ///
    /// Five percent, which is a conversation's setting rather than a cinema's. This app is two
    /// people looking at each other, where a few milliseconds off the round trip is worth more
    /// than a frame in twenty that nobody can point to — and the frames it gives up are the ones
    /// arriving in the long tail of the link's jitter, which were going to be shown late and
    /// wrong rather than not at all.
    ///
    /// Five rather than one or three because a relayed link has a long tail and the low quantiles
    /// sit out in it: measured through Los Angeles at sixty frames a second, arrivals had a 35ms
    /// median, an 84ms 95th percentile and a 101ms 99th, so one percent asked for a 135-155ms
    /// delay and five percent for 27-34ms. Both showed every frame and froze on none of them. The
    /// ninety milliseconds between them bought nothing anybody could see.
    var playoutTolerance = 0.05

    /// Seconds of headroom the arriving frames actually have. See ``VideoRenderer/playoutSlack``.
    var playoutSlack: Double?

    /// How long this participant's voice is being held before it is played.
    ///
    /// The video tile uses it as a floor, which is the whole of lip sync here. The two media
    /// have separate buffers sizing themselves against separate jitter — audio packets are
    /// twenty milliseconds apart and video frames sixteen, and the audio buffer only shrinks
    /// during silence — so left alone they agree by luck. In practice the voice waited eighty
    /// milliseconds while the picture waited fifteen, which is a face whose lips run ahead of
    /// it. Video is the one that gives, because holding a frame longer costs a frame of
    /// latency and stretching audio costs a click.
    func audioDelay(of who: ParticipantIdentity) -> Duration? {
        statistics?.participants[who]?.audio?.targetDelay
    }

    /// What the remote tile did with the frames it was handed. See ``VideoRenderer/drawing``.
    var drawing = VideoRenderer.Drawing()

    /// Whether the layer those frames are drawn into is attached and has a size.
    /// See ``VideoRenderer/isOnScreen``.
    var tileIsOnScreen = false

    /// How large that layer is laid out, in points.
    var tileSize: CGSize = .zero

    /// How many video tiles exist anywhere in the app. See ``VideoTile/live``.
    ///
    /// More than one per seat plus one for the self view means a tile was rebuilt while its
    /// predecessor was still alive, and the two are sharing one stream between them.
    var tileCount = 0

    /// What the display layer did with the frames, sampled from the renderer.
    var presentation: VideoRenderer.Presentation?

    /// The same, for the unscheduled preview layer, which is the control for it.
    var previewPresentation: VideoRenderer.Presentation?

    /// What the display pipeline is doing with them now. See ``VideoRenderer/Timing``.
    var timing = VideoRenderer.Timing()

    private var captureCadenceTask: Task<Void, Never>?

    /// How bright the picture going into the encoder is, `0` to `1`. See ``brightness(of:)``.
    var captureBrightness: Double?

    /// How bright the picture coming *out* of a remote stream is, decoded here.
    ///
    /// The other half of ``captureBrightness``, and the only reading that tells a black tile
    /// apart from a tile that is never drawn. Every counter between the two says frames were
    /// sent, arrived, and were presented; both a picture that is dark and a picture that never
    /// reaches the glass agree with all of them. Decoding one keyframe every group here costs
    /// a still image every couple of seconds and answers which half to look in.
    var receivedBrightness: Double?

    /// The size of that decoded picture, and how many have been sampled.
    var receivedSize: PixelSize?
    var receivedPictures = 0

    private var receivedPictureTask: Task<Void, Never>?
    private var watchedPublisher: ParticipantIdentity?

    /// The size of the frames the encoder is being handed.
    ///
    /// What was *asked* for is in the rung and is on screen twice already. This is what
    /// arrived, and the two part company silently: a capture connection that declines to
    /// rotate leaves the encoder configured for portrait and fed landscape.
    var captureSize: PixelSize?

    enum VideoInput: String, CaseIterable, Identifiable, Sendable {
        case pattern = "Test pattern"
        case camera = "Camera"
        case scene = "AR scene"

        var id: String { rawValue }
    }

    /// The sources this device can actually offer.
    ///
    /// A picker listing an AR scene on a simulator, or on a phone whose chip cannot run a
    /// session, is a choice that fails at the moment somebody goes live — which reads as a
    /// broken broadcast rather than as an unsupported option.
    var videoInputs: [VideoInput] {
        #if canImport(ARKit) && !targetEnvironment(simulator)
            ARSceneSource.isSupported
                ? VideoInput.allCases
                : VideoInput.allCases.filter { $0 != .scene }
        #else
            VideoInput.allCases.filter { $0 != .scene }
        #endif
    }

    #if canImport(ARKit) && !targetEnvironment(simulator)
        /// The live scene, while one is being published.
        ///
        /// Held for the view rather than for this model: RealityKit only draws what is in a
        /// window, so the source cannot produce a single frame until something puts its view
        /// on screen. See ``ARSceneView``.
        private(set) var arScene: ARSceneSource?
    #endif

    // MARK: - The shared space

    /// Whether this device has joined the room's bubble field.
    private(set) var isSharing = false

    /// Whether this device is the one simulating it.
    ///
    /// Worth showing. The two roles are meant to be indistinguishable to play,
    /// and the only way to know whether that is actually true is to be able to
    /// see which one you are while playing.
    private(set) var isRunningTheField = false

    /// Who has popped what, best first.
    private(set) var standings: [Score] = []

    /// How many bubbles are up.
    private(set) var bubblesUp = 0

    struct Score: Identifiable, Hashable {
        var id: String { who }
        let who: String
        let score: Int
    }

    private var space: SpaceSession?
    private var spacePump: Task<Void, Never>?

    /// Whether the shared space can be joined at all right now.
    ///
    /// It needs somewhere to draw, and the AR scene is that: the bubbles are
    /// RealityKit entities in the session's own view. Offering it beside a test
    /// pattern would be a switch that turns nothing on.
    var canShare: Bool {
        #if canImport(ARKit) && !targetEnvironment(simulator)
            return arScene != nil
        #else
            return false
        #endif
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
    var isPreviewMirrored: Bool {
        guard videoInput == .camera, cameraPosition.wantsMirroredPreview else { return false }
        // Not twice. When the capture connection is already mirroring, the buffers reaching
        // this preview are mirrored, and flipping the layer on top of that would show the
        // person the one image nobody wants: the true scene in their own preview, while
        // everybody else sees the mirror.
        return !publishesMirrored
    }

    /// Whether this host mirrors the picture it sends, rather than only its own preview.
    ///
    /// The host's call, and it travels in the pixels because there is nowhere else for it to
    /// travel: a viewer is shown what arrives and never flips anything itself. Mirroring at
    /// the capture connection costs nothing — the pipeline does it before the buffer exists —
    /// whereas a viewer-side flip would have to be agreed, carried in the catalog, and honoured
    /// by every client that draws the track, including a recorder that draws it to a file.
    ///
    /// Only ever applies to a front camera. A mirrored back camera is nobody's intent.
    var publishesMirrored = true {
        didSet {
            guard publishesMirrored != oldValue else { return }
            applyMirroring()
        }
    }

    /// Push the mirror choice at the camera, for the camera it currently is.
    private func applyMirroring() {
        camera?.publishesMirrored = publishesMirrored && cameraPosition.wantsMirroredPreview
    }

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
    }

    /// How many tiles across the gallery draws, or `nil` to let it choose.
    ///
    /// Here because the arrangement is what decides how big each tile is, and how big each
    /// tile is decides which rung the SDK subscribes to. Forcing it is the only way to ask
    /// "what does a three-across grid actually fetch?" and read the answer off the screen
    /// rather than reasoning about it.
    enum Arrangement: String, CaseIterable, Identifiable, Sendable {
        case automatic = "Automatic"
        case oneUp = "1 across"
        case twoUp = "2 across"
        case threeUp = "3 across"
        case fourUp = "4 across"

        var id: String { rawValue }

        var columns: Int? {
            switch self {
            case .automatic: nil
            case .oneUp: 1
            case .twoUp: 2
            case .threeUp: 3
            case .fourUp: 4
            }
        }
    }

    var arrangement: Arrangement = .automatic

    /// Which picture the screen is mostly given to.
    ///
    /// Separate from ``Arrangement``, which divides the space the gallery gets; this decides
    /// how much space that is. The pair is what makes a tile any given size, and a tile's size
    /// is the only input to which rung the SDK fetches — so between them they can put a real
    /// 720p decode in a 120-point box or a 180p one across half a phone, and the badge on the
    /// tile says which happened.
    enum Screen: String, CaseIterable, Identifiable, Sendable {
        /// Everyone else, with this device in a thumbnail beneath them.
        case others = "Others"
        /// This device's camera behind everyone else's tiles.
        case me = "Me, full screen"
        /// Captured and received at the same size, next to each other.
        case sideBySide = "Side by side"

        var id: String { rawValue }
    }

    /// Side by side to start, because the first question about a call is whether the two
    /// halves match: what this camera is capturing and what the other device is drawing, at the
    /// same size on one screen. Any other default makes that a comparison between a big picture
    /// and a thumbnail, which hides exactly the difference worth seeing.
    var screen: Screen = .sideBySide

    /// The shape of a tile: the shape of the video, or a square for a room with none.
    ///
    /// Taken from what is being published rather than fixed at `16/9`, because the two have
    /// to agree. A portrait camera in a landscape tile is not letterboxed, it is a small
    /// strip of picture between two black bars, and the box the SDK is told about is the
    /// tile's — so it would also ask for a rung sized for a shape nobody is sending.
    var seatAspect: Double {
        guard mode == .gallery else { return 1 }
        let size = pinnedRung?.size ?? Self.defaultCaptureSize
        return Double(size.width) / Double(size.height)
    }

    /// What the camera is asked for when no rung has been pinned.
    ///
    /// Portrait, because a phone is held upright and the sensor's own landscape frames are
    /// the thing that needs turning. See ``CameraSource``, which reads the shape of this as
    /// the instruction to turn them.
    static let defaultCaptureSize = PixelSize(width: 720, height: 1280)

    /// What to publish, for the layout this call is being drawn in.
    ///
    /// The publisher's decision, and the only one: a receiver takes what arrives. Which means
    /// the size has to be chosen for the box at the *other* end, and this app can do that
    /// honestly because both ends run the same layout — side by side gives each picture half
    /// the width of a phone, and full screen gives it all of one.
    ///
    /// Rounded up to a rung rather than sized to the pixel. An encoder reconfigured every time
    /// somebody rotates their phone is a keyframe and a stall for a difference nobody can see,
    /// and 720p already has pixels to spare for half a phone screen at 3×.
    var publishSize: PixelSize {
        switch screen {
        case .sideBySide, .others: Self.defaultCaptureSize
        case .me: PixelSize(width: 1080, height: 1920)
        }
    }

    /// The frame rate to publish at.
    var publishFrameRate: Double = 30

    /// What a rung of ``publishSize`` costs on the wire.
    ///
    /// Bits per pixel per second, times the pixels: 720p30 lands on the 1.25 megabits a
    /// measured run of the same picture settled on. Under the ladder's own figure for 720p,
    /// deliberately — that number is for a rung a viewer might be watching full screen, and
    /// this one is for half a phone over a domestic uplink two phones are sharing.
    ///
    /// Floored, because the arithmetic above it is the kind that goes wrong by a thousand.
    /// It did: the constant was written per pixel per second in units of megabits and applied
    /// as bits, the encoder was asked for one and a half kilobits, and VideoToolbox did
    /// exactly as told — it declined nineteen frames in twenty and emitted two keyframes a
    /// second. On screen that is a black tile with healthy audio beside it and every counter
    /// in the app reporting thirty frames captured. No rung anyone wants is under this, so
    /// anything that computes one has made a mistake worth surviving.
    var publishBitrate: Int {
        let pixels = Double(publishSize.pixelCount)
        let perPixel = 1.36
        let base = pixels * perPixel * (1 + (publishFrameRate / 30 - 1) * 0.6)
        return max(300_000, Int(base.rounded()))
    }

    /// The one rung this device publishes.
    func rungForLayout() -> VideoLayer {
        let size = publishSize
        return VideoLayer(
            id: LayerID("video/\(min(size.width, size.height))p"),
            size: size,
            frameRate: publishFrameRate,
            bitrate: publishBitrate,
            // One, because there is no longer anyone to shed a sub-layer for. Hierarchical
            // P-frames let a receiver drop half the frames under pressure, and a receiver
            // that is not choosing anything cannot use that — it only makes the frames
            // arrive in bunches.
            temporalLayers: 1
        )
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

    /// The quarter turn the capture connection is applying, if any.
    ///
    /// Asked of the connection rather than of what was requested, because those are the two
    /// things that can differ and the difference is invisible everywhere else.
    var cameraTurn: Double? { camera?.appliedRotationDegrees }

    /// Whether that turn is being done in software because the connection would not.
    var cameraTurnsInSoftware: Bool { camera?.softwareTurns ?? false }

    /// How often the system has taken the camera away, and what it said the last time.
    var cameraInterruptions: Int { camera?.interruptions ?? 0 }
    var lastCameraInterruption: String? { camera?.lastInterruption }

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

        // Subscribe to whatever each publisher sends, and choose nothing. Both ends of this
        // call run the same layout, so the sender already knows the size of the box its
        // picture lands in — see ``rungForLayout`` — and a receiver that also has an opinion
        // can only disagree with it. See ``RoomSession/setFollowsPublisher(_:)``.
        Task { [room] in await room.setFollowsPublisher(true) }

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
            // The seat is gone, so its tile is too — this is the one place a tile is released,
            // and it is why no view needs to.
            releaseTile(for: who)
            #if os(iOS)
                pictureInPicture?.unregister(who)
            #endif
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
    /// The short side, not the height, because a portrait rung is 720×1280 and calling that
    /// 1280p would name a resolution nobody publishes.
    func quality(of who: ParticipantIdentity) -> String? {
        guard let best = catalogs[who]?.videoLadder.highest else { return nil }
        return "\(min(best.size.width, best.size.height))p"
    }

    /// The rung actually being fetched for a tile, and the box that chose it.
    ///
    /// The pair rather than either alone. The rung on its own cannot be judged — 360p is
    /// right for a thumbnail and wrong for a full screen — and the box on its own does not
    /// say what the SDK made of it. Together they are the whole of render-aware selection,
    /// on screen, changing as the grid changes.
    func fetching(_ who: ParticipantIdentity) -> (rung: String, box: PixelSize)? {
        guard let box = layout.lastReported[who]?.pixelSize else { return nil }
        let rung = statistics?.participants[who]?.layer?.value
        return (rung.map { $0.replacingOccurrences(of: "video/", with: "") } ?? "—", box)
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
            var seen = 0
            for await frame in tap.elements {
                captureCadence.record()
                seen += 1
                // Once a second at sixty, because it reads pixels off a surface the encoder is
                // also reading and there is no question here that needs answering faster.
                guard seen % 60 == 0 else { continue }
                let luma = Self.brightness(of: frame)
                let size = frame.size
                await MainActor.run {
                    if let luma { self.captureBrightness = luma }
                    self.captureSize = size
                }
            }
        }
    }

    /// One drawing surface per seat, for as long as the seat exists.
    ///
    /// Held here rather than in the view that draws it. A tile owns a decode session, a
    /// subscription's worth of frames and a layer, and a SwiftUI view owns none of those
    /// things for longer than the next layout pass — so a tile whose lifetime followed a
    /// view's was rebuilt whenever the grid changed, and the rebuild is what put the frames
    /// and the visible layer in two different objects.
    private var tiles: [ParticipantIdentity: VideoTile] = [:]

    /// Separate from the others, because this device is two pictures. The preview comes from
    /// the camera and a subscription to this device would come from the relay; they are not
    /// the same picture and cannot share a layer.
    private var previewTile: VideoTile?

    func tile(for who: ParticipantIdentity, isSelf: Bool) -> VideoTile {
        if isSelf {
            if let previewTile { return previewTile }
            let tile = VideoTile()
            previewTile = tile
            return tile
        }
        if let existing = tiles[who] { return existing }
        let tile = VideoTile()
        tiles[who] = tile
        return tile
    }

    private func releaseTile(for who: ParticipantIdentity) {
        tiles.removeValue(forKey: who)?.detach()
    }

    /// Decode one remote participant's keyframes, purely to look at them.
    ///
    /// One participant rather than all of them, because this is a diagnostic and each tap is a
    /// decode session. The first remote publisher is the one a two-device test is about.
    func watchReceivedPicture(of who: ParticipantIdentity) {
        guard watchedPublisher != who else { return }
        watchedPublisher = who
        receivedPictureTask?.cancel()
        receivedPictureTask = Task { [weak self] in
            guard let self else { return }
            let tap = await room.tapVideo(from: who, policy: .classification)
            defer { tap.stop() }
            for await picture in tap.elements {
                let luma = Self.brightness(of: picture.frame)
                let size = picture.frame.size
                await MainActor.run {
                    if let luma { self.receivedBrightness = luma }
                    self.receivedSize = size
                    self.receivedPictures += 1
                }
            }
        }
    }

    /// The average luminance of a frame, `0` to `1`, sampled rather than summed.
    ///
    /// Exists because "no video" and "a black picture" are indistinguishable from every counter
    /// in this app: frames captured, encoded, sent, received, decoded and presented all read
    /// perfectly while a camera hands over darkness. This is the only reading that separates a
    /// broken pipeline from a lens against a desk — or from a capture configuration that looked
    /// like a power saving and was in fact a black frame.
    private static func brightness(of frame: VideoFrame) -> Double? {
        guard case let .pixelBuffer(buffer) = frame.surface else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        // Plane zero of a biplanar buffer is luma, which is the whole of the question.
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        guard stride > 0, height > 0, width > 0 else { return nil }

        let pixels = base.assumingMemoryBound(to: UInt8.self)
        var total = 0
        var counted = 0
        for row in Swift.stride(from: 0, to: height, by: max(1, height / 16)) {
            for column in Swift.stride(from: 0, to: width, by: max(1, width / 16)) {
                total += Int(pixels[row * stride + column])
                counted += 1
            }
        }
        guard counted > 0 else { return nil }
        return Double(total) / Double(counted) / 255
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
        // One rung, decided here. A measured run brings its own — the point of a benchmark is
        // that both ends agree on a figure that does not move — and any other run publishes
        // what the layout on screen is going to draw. See ``rungForLayout``.
        let rung = pinnedRung ?? rungForLayout()
        pinnedRung = rung

        // Capture what the rung says it publishes. A capture format chosen independently of the
        // ladder is how a run claims sixty frames while the camera hands over thirty.
        let size = rung.size
        let format = CaptureFormat(size: size, frameRate: rung.frameRate)

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
                applyMirroring()
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
        case .scene:
            #if canImport(ARKit) && !targetEnvironment(simulator)
                do {
                    guard ARSceneSource.isSupported else { throw ARSceneError.unsupported }
                    // An AR session is a camera, whatever it is called, and the prompt
                    // belongs here for the same reason it does on the camera path.
                    guard await Self.cameraIsAuthorised() else {
                        throw MoqomError.platform(
                            api: "AVCaptureDevice.requestAccess", status: -1
                        )
                    }

                    let scene = ARSceneSource(format: format)
                    try scene.start()
                    arScene = scene
                    source = scene

                    // Full screen, because the drawable is the tile. Everywhere else the
                    // layout decides how big a picture looks; here it decides how many
                    // pixels the encoder is given, and a scene published from a
                    // side-by-side thumbnail is a 720p rung upscaled from a third of that.
                    screen = .me
                } catch {
                    lastError = error as? MoqomError
                    videoInput = .pattern
                    let pattern = PatternSource(format: format, label: identity.username.value)
                    capture = pattern
                    source = pattern
                }
            #else
                videoInput = .pattern
                let pattern = PatternSource(format: format, label: identity.username.value)
                capture = pattern
                source = pattern
            #endif
        }

        do {
            let ladder = LayerLadder(rungs: [rung])
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
                configuration: BroadcastConfiguration(
                    ladder: ladder,
                    prefersPowerEfficiency: !encodesEagerly,
                    encoderFactory: encoders
                )
            )
            await publication.start()
            broadcast = publication
            isBroadcasting = true

            // The same measurement as the receiving end, on the frames going in. It is the
            // only way to tell an uneven picture apart from an uneven network: if capture is
            // already lumpy the far end can do nothing but reproduce it, and if capture is
            // even then everything between here and there owns the difference.
            //
            // Watched for a ladder as well as a pinned rung, which it was not. A run driven by
            // hand publishes the ladder, so the one configuration people actually use was also
            // the one whose capture nothing was measuring.
            watchCaptureCadence(of: publication)

            Journal.shared.say(
                "GO LIVE source=\(videoInput.rawValue)"
                    + " capture=\(size.width)x\(size.height)@\(Int(format.frameRate))"
                    + " rungs=" + ladder.rungs.map(\.id.value).joined(separator: ",")
                    + " stamp=\(trustedStamp == nil ? "device" : "trusted")"
            )
            applyAudioPurpose()

            // A voice with the picture, unless somebody has deliberately turned it off. Going
            // live used to publish video only, and audio was a second button with a waveform
            // on it — so the ordinary way to use this app was to broadcast, see the other
            // person, hear nothing, and conclude that audio was broken. It is a call: the two
            // start together, and the mute button beside them is how one goes quiet.
            if !isPublishingAudio, !hasStoppedAudio { await startAudio() }
            #if os(iOS)
                await startLiveActivity()
            #endif
            await refresh()
        } catch {
            lastError = error
            source.stop()
            capture = nil
            camera = nil
            #if canImport(ARKit) && !targetEnvironment(simulator)
                arScene = nil
            #endif
            broadcast = nil
        }
    }

    // MARK: - Playing in the shared space

    /// Join the room's bubble field, and put it in the scene.
    ///
    /// Whether this device ends up running the field is not decided here and
    /// deliberately cannot be: `SpaceSession` claims it if nobody else has and
    /// stands down if somebody better placed does. The interface says which of
    /// the two happened; nothing here chooses it.
    func startSharing() async {
        #if canImport(ARKit) && !targetEnvironment(simulator)
            guard !isSharing, let scene = arScene else { return }

            let field = BubbleScene()
            field.onPop = { [weak self] id in
                guard let self else { return }
                Task { await self.pop(id) }
            }

            let configuration = SpaceSession.Configuration()
            field.cadence = 1 / configuration.tickRate
            scene.show(field)

            let stamp = trustedStamp
            do {
                let joined = try await room.joinSpace(
                    BubbleField(),
                    configuration: configuration,
                    // The same clock the glass-to-glass figures are on, so that
                    // "who popped it first" is settled on a timeline both
                    // phones share rather than on arrival order at whichever
                    // one happens to be simulating.
                    clock: { stamp?() ?? .fallback() }
                )
                space = joined
                isSharing = true
                field.reset(to: await joined.state)
                follow(joined, with: field)
                Journal.shared.say("SPACE joined room=\(room.room.value)")
            } catch {
                lastError = error as? MoqomError
                scene.hideField()
            }
        #endif
    }

    func stopSharing() async {
        spacePump?.cancel()
        spacePump = nil
        space = nil
        isSharing = false
        isRunningTheField = false
        standings = []
        bubblesUp = 0
        await room.leaveSpace()
        #if canImport(ARKit) && !targetEnvironment(simulator)
            arScene?.hideField()
        #endif
    }

    #if canImport(ARKit) && !targetEnvironment(simulator)
        /// Draw everything the space says, for as long as it says anything.
        private func follow(_ space: SpaceSession, with field: BubbleScene) {
            spacePump?.cancel()
            spacePump = Task { [weak self] in
                for await event in space.events {
                    guard let self else { return }
                    switch event {
                    case let .changed(state, delta):
                        field.apply(state, delta)
                        standings = BubbleField.standings(in: state).map {
                            Score(who: $0.who, score: $0.score)
                        }
                        bubblesUp = BubbleField.bubbles(in: state).count
                    case let .roleChanged(role):
                        isRunningTheField = role == .leading
                        Journal.shared.say("SPACE role=\(role)")
                    case let .authorityChanged(who):
                        // The world is about to be restated by somebody else,
                        // and the entity names they use are their own. Starting
                        // from their snapshot rather than folding it into what
                        // the last authority left is what keeps two bubbles
                        // from sharing a node.
                        field.reset(to: await space.state)
                        Journal.shared.say(
                            "SPACE authority=\(who?.username.value ?? "nobody")"
                        )
                    }
                }
            }
        }

        /// Tell the space this device popped something.
        private func pop(_ id: SpaceEntityID) async {
            await space?.act(verb: BubbleField.pop, subject: id)
        }
    #endif

    /// Pop something, anything, as though a finger had landed on it.
    ///
    /// For a scripted run, where there is no finger. What it exercises is the
    /// half of the space a tap-free run never reaches: an intent published
    /// under this participant's own namespace, authorised by the relay,
    /// applied by whoever is simulating, and scored back to both devices. That
    /// last step is the one worth a two-phone test — the loopback proves the
    /// mechanism, and only a real relay proves it will carry it.
    @discardableResult
    func popSomething() async -> Bool {
        guard let space else { return false }
        let bubbles = BubbleField.bubbles(in: await space.state)
        guard let target = bubbles.randomElement() else { return false }
        await space.act(verb: BubbleField.pop, subject: target.id)
        return true
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
            // The mirror belongs to the front camera, not to the session, so it has to be
            // re-decided here. A back camera that kept the flip would publish every sign and
            // T-shirt backwards to everyone but the person holding the phone.
            applyMirroring()
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

    /// Whether the last thing anybody said about audio was to turn it off.
    private(set) var hasStoppedAudio = false

    /// Publish audio, from whichever input is selected.
    func startAudio() async {
        guard !isPublishingAudio else { return }
        hasStoppedAudio = false

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

        // Opened here rather than left to the first arriving voice. The microphone path needs the
        // engine anyway, but a synthetic source does not, and the session it configures is what
        // decides the output route: until something starts the graph, iOS is still on whatever
        // route the app launched with. Measured, that was the earpiece — so the first cohost to
        // speak was played into a receiver pointing at nothing, until an unrelated event moved
        // the route and the sound apparently arrived from nowhere.
        try? AudioGraph.shared.start()
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

            // Paced to a deadline rather than by sleeping for the packet duration. Sleeping for
            // twenty milliseconds takes twenty *and a bit*, every time, so a loop built that way
            // produces about forty-six packets a second where the publication expects fifty and
            // fills the shortfall with silence — four dropouts a second in what is supposed to be
            // a continuous tone, which sounds like a fault in the network rather than in the
            // signal generator. A deadline that advances by exactly a packet absorbs the
            // overshoot and catches up after any hesitation.
            // Pulsed rather than continuous, which is not decoration. Publishing runs a voice
            // detector that measures energy against a noise floor it estimates continuously, so
            // an unchanging tone is learned as the room within a second or two and every packet
            // after that is marked silence — the far end then plays exact zeros, correctly, and
            // the tone is heard for about a second and never again. Suppressing a steady hum is
            // what that detector is for; a steady hum is therefore the one signal that cannot be
            // used to test it. Speech comes in syllables, so this does too.
            var due = ContinuousClock.now
            var packet = 0
            while !Task.isCancelled {
                // Fifteen packets on, ten off: 300ms of tone every half second.
                let speaking = packet % 25 < 15
                packet += 1

                var samples = [Float](repeating: 0, count: format.samplesPerFrame)
                for index in samples.indices {
                    samples[index] = speaking ? Float(sin(phase)) * 0.2 : 0
                    phase += step
                }

                // Wrapped, so the argument to `sin` stays small over a call of any length.
                phase.formTruncatingRemainder(dividingBy: 2 * .pi)

                relay.submit(
                    AudioFrame(
                        timestamp: FrameTimestamp(nanoseconds: timestamp),
                        format: format,
                        samples: samples
                    )
                )
                timestamp += 20_000_000
                due += .milliseconds(20)
                try? await Task.sleep(until: due, clock: .continuous)
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

        // The error is kept rather than discarded. Playback fails for reasons that are entirely
        // silent otherwise — an engine that will not start because the session was refused, most
        // often — and a listener then sees a healthy subscription, rising packet counts, and no
        // sound, with nothing anywhere saying why.
        playback[who] = Task { [weak self] in
            do throws(MoqomError) {
                try await player.play(outputs)
            } catch {
                await MainActor.run { self?.lastError = error }
            }

            // Cleared when the stream ends, and that matters more than tidiness. The stream ends
            // whenever the SDK tears a participant's media down — a reconnect, a seat given up
            // and taken back — which leaves a finished task and a stopped player behind in these
            // two dictionaries. The guard at the top of this method reads them as playback
            // already running, so the participant comes back, their video returns, and their
            // voice never does.
            await self?.finishPlayback(for: who, if: player)
        }
    }

    /// What is reaching the speaker for one participant, as opposed to what is reaching the
    /// device. See ``AudioPlayer/Playback``.
    func playback(of who: ParticipantIdentity) async -> AudioPlayer.Playback? {
        await players[who]?.reading()
    }

    /// Forget a playback that ended, unless it has already been replaced.
    private func finishPlayback(for who: ParticipantIdentity, if player: AudioPlayer) async {
        guard players[who] === player else { return }
        players.removeValue(forKey: who)
        playback.removeValue(forKey: who)
        await player.stop()
    }

    private func stopPlayback(for who: ParticipantIdentity) async {
        playback.removeValue(forKey: who)?.cancel()
        if let player = players.removeValue(forKey: who) {
            await player.stop()
        }
        if watchedPublisher == who {
            receivedPictureTask?.cancel()
            receivedPictureTask = nil
            watchedPublisher = nil
        }
    }

    /// - Parameter deliberately: whether a person asked for this, in which case going live
    ///   again will not quietly turn the microphone back on. False for the internal stops —
    ///   swapping the input is a stop and a start, and it is not a decision to be silent.
    func stopAudio(deliberately: Bool = true) async {
        if deliberately { hasStoppedAudio = true }
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
        // The field is drawn in the scene's view, so it goes when the scene
        // does. Leaving the space as well as hiding it, because a device with
        // nothing on screen that is still simulating for everybody else is a
        // game the player cannot see themselves losing.
        if isSharing { await stopSharing() }
        await room.stopBroadcast()
        capture = nil
        camera = nil
        #if canImport(ARKit) && !targetEnvironment(simulator)
            // Stopped as well as released. The session holds the camera and the render loop
            // keeps drawing for as long as the view is on screen, neither of which ends
            // because the last reference went away.
            arScene?.stop()
            arScene = nil
        #endif
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

extension Duration {
    /// Seconds as a `Double`, which is what a readout formatting milliseconds wants.
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
