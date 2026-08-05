// Displaying a subscribed track.
//
// `AVSampleBufferDisplayLayer` rather than a `VTDecompressionSession` and a
// Metal pass, for the 2D case. It decodes, it schedules against the display,
// and it handles the format change when the layer selector climbs a rung —
// which is the case that a hand-rolled decoder gets wrong, because a resolution
// change means tearing down and rebuilding a session at exactly the moment the
// viewer is watching for a quality improvement.
//
// The 3D case is genuinely different and is not this: a video textured onto an
// entity in a RealityKit scene needs the decoded surface as an `MTLTexture`,
// which means owning the decompression session and writing into a
// `LowLevelTexture`. That path is not in this file, and the seam is that
// ``VideoRenderer`` consumes ``EncodedFrame`` — the same thing a texture path
// would consume.
//
// Parameter sets are the subtle part. VideoToolbox emits length-prefixed NAL
// units, not Annex B, so the sample buffer needs a format description built
// from the parameter sets rather than the start codes a network stream would
// carry. Those arrive out of band on the catalog, which is what lets a viewer
// join at an arbitrary group instead of waiting for the next IDR.

import Foundation
import MoqomCore

#if canImport(AVFoundation) && canImport(VideoToolbox)
    import AVFoundation
    import CoreMedia
    import VideoToolbox

    #if canImport(UIKit)
        import UIKit
    #elseif canImport(AppKit)
        import AppKit
    #endif

    /// Builds decodable sample buffers from published objects.
    ///
    /// Separated from the layer so the assembly is reachable from the texture
    /// path too, and so the format-change bookkeeping lives in one place.
    ///
    /// > Important: Compiles on every Apple platform; not exercised by the test
    /// > suite, which has no decoder.
    public final class SampleBufferAssembler {
        private var format: CMFormatDescription?
        private var parameterSets: [Data] = []
        private var codec: VideoCodec

        /// Whether each frame is marked for display the moment it is decoded.
        ///
        /// Right when nothing is scheduling presentation, and wrong the moment something is: the
        /// attachment tells the display layer to ignore the timestamp it was given, so a renderer
        /// that has gone to the trouble of a timebase and a playout delay gets neither. The
        /// symptom is a stream that measures perfectly — even stamps, no losses, no reordering,
        /// full delivery — and still shows every millisecond of network jitter on the glass,
        /// because "as soon as it arrives" is exactly what was asked for.
        public var displaysImmediately = true

        public init(codec: VideoCodec = .hevc) {
            self.codec = codec
        }

        /// Switch codecs.
        ///
        /// Settable because a viewer learns the codec from the publisher's
        /// catalog, which arrives after the renderer has been built — the view
        /// exists as soon as the participant does. Discards the format
        /// description rather than converting it: an HEVC description is not a
        /// starting point for an H.264 one.
        public func setCodec(_ codec: VideoCodec) {
            guard codec != self.codec else { return }
            self.codec = codec
            format = nil
            parameterSets = []
        }

        /// Install the parameter sets from the catalog.
        ///
        /// Idempotent for identical sets, because a keyframe carries them too
        /// and rebuilding the format description on every keyframe would make
        /// the display layer re-negotiate twice a second.
        public func setParameterSets(_ sets: [Data]) throws(MoqomError) {
            guard !sets.isEmpty, sets != parameterSets else { return }
            parameterSets = sets
            format = try Self.makeFormat(from: sets, codec: codec)
        }

        /// The size of the picture being described, once anything is.
        ///
        /// Read from the format description rather than from a catalog, so it is
        /// the size of the frames actually being decoded. The two disagree for a
        /// moment whenever a publisher changes geometry, and a view laid out from
        /// the catalog's answer letterboxes until the disagreement resolves.
        public var presentedSize: PixelSize? {
            guard let format else { return nil }
            let dimensions = CMVideoFormatDescriptionGetDimensions(format)
            guard dimensions.width > 0, dimensions.height > 0 else { return nil }
            return PixelSize(width: Int(dimensions.width), height: Int(dimensions.height))
        }

        /// Wrap one encoded frame.
        ///
        /// Returns `nil` before parameter sets have arrived. That is a normal
        /// state and not an error: a subscription can deliver media before the
        /// catalog fetch that describes it completes, and the correct response
        /// is to drop until the description lands.
        public func sampleBuffer(for frame: EncodedFrame) throws(MoqomError) -> CMSampleBuffer? {
            if !frame.parameterSets.isEmpty {
                try setParameterSets(frame.parameterSets)
            }
            guard let format else { return nil }

            // A block buffer that points at `frame.data` would outlive it, so
            // the memory is allocated for the block buffer to own and freed by
            // it. The extra copy is one memcpy per frame and buys a lifetime
            // that does not depend on the caller holding the `Data`.
            var owned: CMBlockBuffer?
            let allocateStatus = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: frame.data.count,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: frame.data.count,
                flags: kCMBlockBufferAssureMemoryNowFlag,
                blockBufferOut: &owned
            )
            guard allocateStatus == noErr, let owned else {
                throw MoqomError.platform(
                    api: "CMBlockBufferCreateWithMemoryBlock",
                    status: allocateStatus
                )
            }

            let copyStatus = frame.data.withUnsafeBytes { bytes in
                CMBlockBufferReplaceDataBytes(
                    with: bytes.baseAddress!,
                    blockBuffer: owned,
                    offsetIntoDestination: 0,
                    dataLength: bytes.count
                )
            }
            guard copyStatus == noErr else {
                throw MoqomError.platform(
                    api: "CMBlockBufferReplaceDataBytes",
                    status: copyStatus
                )
            }

            var timing = CMSampleTimingInfo(
                duration: .invalid,
                presentationTimeStamp: frame.timestamp.cmTime,
                decodeTimeStamp: .invalid
            )
            var size = frame.data.count
            var sample: CMSampleBuffer?
            let sampleStatus = CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: owned,
                formatDescription: format,
                sampleCount: 1,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 1,
                sampleSizeArray: &size,
                sampleBufferOut: &sample
            )
            guard sampleStatus == noErr, let sample else {
                throw MoqomError.platform(api: "CMSampleBufferCreateReady", status: sampleStatus)
            }

            // Without this, and without a timebase, the layer buffers against a master clock that
            // was never set and the first frame sits there until the second arrives. With a
            // timebase it is the opposite of what is wanted — see `displaysImmediately`.
            if
                displaysImmediately,
                let attachments = CMSampleBufferGetSampleAttachmentsArray(
                    sample,
                    createIfNecessary: true
                ) as? [CFMutableDictionary],
                let first = attachments.first
            {
                CFDictionarySetValue(
                    first,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
                )
            }

            return sample
        }

        private static func makeFormat(
            from sets: [Data],
            codec: VideoCodec
        ) throws(MoqomError) -> CMFormatDescription {
            var pointers: [UnsafePointer<UInt8>] = []
            var sizes: [Int] = []
            var retained: [UnsafeMutablePointer<UInt8>] = []
            defer { retained.forEach { $0.deallocate() } }

            for set in sets {
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
                set.copyBytes(to: buffer, count: set.count)
                retained.append(buffer)
                pointers.append(UnsafePointer(buffer))
                sizes.append(set.count)
            }

            var format: CMFormatDescription?
            let status: OSStatus = switch codec {
            case .hevc:
                CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: pointers.count,
                    parameterSetPointers: &pointers,
                    parameterSetSizes: &sizes,
                    nalUnitHeaderLength: 4,
                    extensions: nil,
                    formatDescriptionOut: &format
                )
            case .h264:
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: pointers.count,
                    parameterSetPointers: &pointers,
                    parameterSetSizes: &sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &format
                )
            }

            guard status == noErr, let format else {
                throw MoqomError.platform(
                    api: "CMVideoFormatDescriptionCreateFromParameterSets",
                    status: status
                )
            }
            return format
        }
    }

    /// Draws a subscribed track into a layer.
    ///
    /// Main-actor bound because the layer is part of the view hierarchy, and
    /// because the render size this reports is the input to layer selection —
    /// the two facts belong to the same thread.
    @MainActor
    public final class VideoRenderer {
        public let layer = AVSampleBufferDisplayLayer()

        private let assembler: SampleBufferAssembler

        /// Draw the picture flipped left to right.
        ///
        /// For the local preview of a front camera, and for nothing else. A
        /// selfie preview that is not mirrored feels wrong in a way people
        /// cannot always name — every mirror they have ever used works this way
        /// — while a *remote* participant drawn mirrored is simply wrong, since
        /// what arrived is the real scene and the text in it reads correctly.
        ///
        /// A transform on the layer, so it costs nothing: no pass over the
        /// pixels, no second surface, and no work at all per frame. Doing this
        /// with a GPU pass is the expensive way to reach the same picture, and
        /// doing it at the capture connection reaches a different one — that
        /// mirrors what is *published*, which is
        /// ``CameraSource/publishesMirrored`` and is usually not wanted.
        public var isMirrored = false {
            didSet {
                guard isMirrored != oldValue else { return }
                apply(mirroring: isMirrored)
            }
        }

        /// How long to hold arriving frames before showing them, or `nil` to show each one as
        /// soon as it decodes.
        ///
        /// `nil` is the lowest latency this can possibly have and the least smooth picture it
        /// can possibly draw, and those are the same fact. With no schedule, a frame is displayed
        /// when it arrives, so the interval between two pictures on screen is the interval
        /// between two packets off the network — and that interval is never the interval they
        /// were captured at. A link with a median gap of 33ms and a 95th percentile of 80ms is a
        /// healthy link by every network measure and visibly choppy motion, because one frame in
        /// twenty is held on screen for two and a half frame times while the next two are shown
        /// almost together.
        ///
        /// A delay is what converts that spread back into even motion: frames are presented on
        /// their own timestamps rather than on their arrival, and anything that arrives within
        /// the delay is invisible. The cost is exactly the delay, added to every frame — so the
        /// number to choose is the jitter being absorbed and not a millisecond more. Around the
        /// 95th percentile arrival gap is the honest setting; the p99 if stalls matter more than
        /// latency.
        ///
        /// Left `nil` by default so this changes nothing for a caller who has not asked. A local
        /// preview should stay `nil` regardless: it has no network jitter to absorb, and delaying
        /// your own face on screen is the one latency a person can always feel.
        public var playoutDelay: Duration? {
            didSet {
                guard playoutDelay != oldValue else { return }
                restartSchedule()
            }
        }

        /// Bounds within which the delay sizes itself, or `nil` to use ``playoutDelay`` as given.
        ///
        /// The right delay is not a property of the application, it is a property of the link and
        /// the device at this minute, and it is the one setting where being wrong in either
        /// direction is expensive: too small drops frames the network merely delivered late, too
        /// large charges every participant latency they did not need. It also moves. The same two
        /// phones on the same relay measured a tail of 20ms one minute and 140ms the next, and a
        /// figure chosen for either is wrong for the other.
        ///
        /// So it is measured instead. Every frame arrives with some slack — the interval between
        /// its arrival and the moment it is due — and the smallest slack seen recently is exactly
        /// how much of the delay was not needed. Keeping that minimum at about one frame widens
        /// the delay when frames start arriving close to their deadline and tightens it while they
        /// keep arriving early, so the buffer settles at the floor on a good link and grows only
        /// while a bad one requires it.
        ///
        /// `floor` is a promise about latency and `ceiling` a promise about smoothness; between
        /// them, nobody has to choose a number that is wrong twice a minute. Both bound the delay
        /// this asks for, which is not quite the delay the frames experience — see
        /// ``playoutSlack``.
        ///
        /// A floor of zero is meaningful and is the interesting setting: it does not mean frames
        /// are shown the instant they arrive, which is what a `nil` ``playoutBounds`` and a `nil`
        /// ``playoutDelay`` do. It means nothing here insists on a delay, and what remains is a
        /// few milliseconds of margin against the display's own refresh plus whatever the link's
        /// jitter turns out to require.
        public var playoutBounds: (floor: Duration, ceiling: Duration)? {
            didSet { restartSchedule() }
        }

        /// A floor the delay must respect that is not a property of this link.
        ///
        /// Lip sync is the reason it exists. A participant's voice is held in its own buffer for
        /// its own reasons, and where that buffer is deeper than this one the picture has to wait
        /// or the lips run ahead of the words. Audio is never delayed to meet video instead: it
        /// is a twentieth of the bitrate and every packet decodes alone, so it keeps arriving on
        /// links where pictures have stopped, and a call that has lost its video and kept its
        /// sound is still a call.
        ///
        /// Separate from ``playoutBounds`` rather than folded into its floor because this moves
        /// while the call is running — the voice's buffer resizes itself — and setting the bounds
        /// restarts the schedule. Restarting it twice a second would re-anchor the picture
        /// continuously, which is a visible lurch each time and precisely what the adaptive delay
        /// exists to avoid. This one takes effect on the next adjustment instead.
        public var playoutFloor: Duration = .zero

        /// The share of frames the adaptive delay is willing to have arrive late.
        ///
        /// This is the trade, and there is no setting that avoids it: the delay must cover the
        /// worst arrival it intends to survive, and the worst arrival on a real link is far worse
        /// than the typical one. Sizing for every frame on a path whose median is 40ms and whose
        /// 99th percentile is 130ms costs ninety milliseconds of latency to rescue one frame in a
        /// hundred — a frame nobody would have seen go missing, in exchange for a delay everybody
        /// feels in conversation.
        ///
        /// One percent by default, which on a measured link left about two frames in a thousand
        /// unshown. Lower it towards zero for playback, where smoothness is everything and nobody
        /// is waiting for a reply; raise it for conversation, where the opposite holds.
        public var playoutTolerance = 0.01

        /// The delay actually in force, which is ``playoutDelay`` unless ``playoutBounds`` is set.
        ///
        /// Worth showing to a person: it is the latency they are paying for smoothness, and it is
        /// the only part of the path that answers to a setting rather than to physics.
        public private(set) var playoutDepth: Duration = .zero

        /// How much earlier than its deadline all but ``playoutTolerance`` of recent frames
        /// arrived, in seconds. Negative means that share of them missed it.
        ///
        /// Worth having separately from ``playoutDepth`` because the two disagree, and the
        /// disagreement is the interesting part: the schedule is anchored on one frame's arrival,
        /// so whatever delay that frame happened to carry is added to the requested depth and
        /// paid by every frame after it. A tile reporting two milliseconds of buffer and twenty
        /// of headroom is holding twenty, and the difference is latency nobody asked for.
        public private(set) var playoutSlack: Double?

        private func restartSchedule() {
            anchor = nil
            synchroniser.setRate(0, time: .invalid)
            grid = nil
            slack = []
            slackCursor = 0
            playoutSlack = nil
            catchUp = nil
            playoutDepth = playoutBounds.map { min(max($0.floor, playoutFloor), $0.ceiling) }
                ?? playoutDelay
                ?? .zero

            // The delay is only a delay if the frames wait for their timestamps.
            assembler.displaysImmediately = requestedDelay == nil
        }

        /// The delay to schedule against: the adaptive depth where bounds are set, else what the
        /// caller asked for, and `nil` only when nothing is scheduling at all.
        private var requestedDelay: Duration? {
            if playoutBounds != nil { return playoutDepth }
            return playoutDelay
        }

        /// Drives presentation from the host clock when ``playoutDelay`` is set.
        ///
        /// A synchroniser rather than the layer's `controlTimebase`, which is deprecated
        /// alongside the enqueue path this already avoids, and which cannot later be shared with
        /// an audio renderer — lip sync is the same mechanism as smooth video and there is no
        /// reason to build it twice.
        private let synchroniser = AVSampleBufferRenderSynchronizer()

        /// The presentation time the schedule was started from, and the newest frame seen since.
        /// Both needed to notice the schedule drifting away from what is arriving.
        private var anchor: CMTime?
        private var newest: CMTime = .invalid

        /// The newest timestamp as the publisher stamped it, before the grid.
        /// Kept apart from `newest` because ordering is a question about the source and the
        /// schedule is a question about the presentation, and once frames are regridded the two
        /// timelines are no longer the same one.
        private var newestSource: CMTime = .invalid

        /// The even presentation grid: where it starts, and the last slot filled.
        private var grid: CMTime?
        private var slot: Int64 = 0

        /// Recent source intervals, for measuring the rate the stream actually arrives at, and the
        /// figure settled on once there is enough of them.
        private var gaps: [Double] = []
        private var gapCursor = 0
        private var latched: Double?
        private static let gapWindow = 120

        /// Slew applied since the interval was last corrected, and how many frames it took.
        private var slewed = 0.0
        private var slews = 0

        /// The last source timestamp, for measuring the interval to the next.
        private var previousStamp: CMTime = .invalid

        /// How much slack each recent frame arrived with, in seconds, for sizing the delay.
        private var slack: [Double] = []
        private var slackCursor = 0
        private static let slackWindow = 600

        /// When the delay was last tightened, so tightening happens gradually.
        private var tightened = ContinuousClock.now

        /// When the schedule last gave back the headroom it was anchored with, so it is rare.
        private var reclaimed = ContinuousClock.now

        /// When the clock currently running fast should return to normal, by how much it will
        /// have moved by then, and the delay that leaves in force.
        private var catchUp: ContinuousClock.Instant?
        private var catchUpGive = 0.0
        private var catchUpLanding = 0.0

        /// Return the clock to real time once it has given back what it set out to.
        ///
        /// The window of remembered headroom is corrected by what the clock made up rather than
        /// emptied, for the same reason a grid shift corrects it: every sample in it was measured
        /// against a schedule that has since moved, by an amount that is known exactly. Emptying
        /// it looks harmless and is not — a decision then rests on the two seconds it takes to
        /// refill, a low quantile of two seconds of a jittery link is mostly noise, and the delay
        /// spends the call chasing it. Measured, that was a wait swinging between 18ms and 97ms
        /// several times faster than the link it was supposedly tracking.
        private func advanceCatchUp() {
            guard let end = catchUp, ContinuousClock.now >= end else { return }
            synchroniser.setRate(1, time: synchroniser.currentTime())
            catchUp = nil
            reclaimed = .now
            for index in slack.indices { slack[index] -= catchUpGive }
            playoutSlack = playoutSlack.map { $0 - catchUpGive }

            // The delay in force is now what the give-back was aimed at, and saying so is the
            // other half of the fix. Leaving it at the old figure is not merely untidy
            // reporting: the delay is what ``anchorSchedule(to:delay:)`` places the grid by, so
            // a delay that still reads 196ms after the clock has handed back 119 of them will
            // spend all 196 again at the next re-anchor — and a re-anchor is exactly what a
            // layout change or a jittery minute produces. That is the loop that took a viewer
            // from forty milliseconds of buffer to nearly two hundred and kept it there.
            playoutDepth = .seconds(catchUpLanding)

            catchUpGive = 0
            catchUpLanding = 0
        }

        /// What happened to the frames handed to this renderer.
        ///
        /// Reported because the last few inches of the path had no accounting at all. A frame can
        /// arrive, reassemble, decode and still never be shown, and until this existed the only
        /// symptom was somebody saying the motion looked wrong while every counter on both
        /// devices read zero.
        public private(set) var drawing = Drawing()

        /// Whether the layer being drawn into is somewhere a person could see it.
        ///
        /// The one thing every counter in this file is blind to. Frames can arrive, decode, be
        /// accepted by the display layer and be counted as presented while the layer is detached
        /// from the view hierarchy or laid out at no size — and then the pipeline reports perfect
        /// health to a viewer looking at a blank tile. Reported rather than asserted because
        /// there is a legitimate moment for each: a renderer built before its view is attached is
        /// detached for an instant, and one whose tile is off screen has been given no size.
        ///
        /// Answered from what the host told us rather than by walking the layer tree, which was
        /// the first attempt and read "off screen" for tiles people were plainly watching. The
        /// walk looked for a view with a window somewhere above the layer, and inside a SwiftUI
        /// hierarchy the layers above a representable's own view belong to hosts whose delegates
        /// are private or nil — so the honest answer was never reachable from down here. The view
        /// hosting the layer is the only thing that knows, and it is told by UIKit.
        public var isOnScreen: Bool {
            guard layer.bounds.width > 1, layer.bounds.height > 1 else { return false }
            return isHosted ?? (layer.superlayer != nil)
        }

        /// Whether the view holding ``layer`` is in a window.
        ///
        /// Set from `didMoveToWindow`, and left `nil` by hosts that never say — in which case
        /// ``isOnScreen`` falls back to whether the layer is parented at all, which is the most
        /// that can be known without being told.
        public var isHosted: Bool?

        /// The size the layer is laid out at, for diagnostics.
        public var drawnSize: CGSize { layer.bounds.size }

        /// What the display pipeline itself says, rather than what was handed to it.
        ///
        /// The counts in ``Drawing`` stop at the moment a frame is accepted, and everything
        /// after that — a synchroniser that never started, a decoder waiting to be flushed, a
        /// renderer that failed between two frames — is a black picture with a perfect stream
        /// behind it. These are the four questions worth asking of the far side of `enqueue`.
        public struct Timing: Sendable {
            /// The synchroniser's rate. Zero means nothing is being presented, whatever is
            /// queued.
            public var rate: Float = 0

            /// How far ahead of the presentation clock the newest queued frame sits, in
            /// seconds. Negative means frames are being scheduled into the past.
            public var ahead: Double = 0

            /// `AVQueuedSampleBufferRenderingStatus`. Two is failed.
            public var status: Int = 0

            /// Whether the decoder needs flushing before it will resume.
            public var needsFlush = false

            public init() {}
        }

        public var timing: Timing {
            var timing = Timing()
            timing.rate = synchroniser.rate
            if newest.isValid {
                timing.ahead = (newest - synchroniser.currentTime()).seconds
            }
            let renderer = layer.sampleBufferRenderer
            timing.status = renderer.status.rawValue
            timing.needsFlush = renderer.requiresFlushToResumeDecoding
            return timing
        }

        /// The preview's format description, held across frames.
        ///
        /// Every frame from one camera has the same one, and building it per frame allocated a
        /// CoreMedia object sixty times a second for a value that changes only when the capture
        /// format does. `CMVideoFormatDescriptionMatchesImageBuffer` is the cheap check for
        /// whether the held one still applies, which it will until the camera is reconfigured.
        private var previewFormat: CMFormatDescription?

        public struct Drawing: Sendable, Hashable {
            /// Frames handed to the display layer.
            public var enqueued = 0

            /// Frames dropped because the display layer was not ready for more.
            ///
            /// The decoder is behind. A few during a rung change is ordinary; a steady trickle is
            /// visible as motion that misses steps while every arrival statistic looks perfect.
            public var skippedNotReady = 0

            /// Frames dropped because no parameter sets had arrived to describe them yet.
            /// Normal at the very start of a subscription and a bug if it continues.
            public var skippedUndescribed = 0

            /// Times the display layer failed and was rebuilt.
            public var failures = 0

            /// Frames that arrived after a later one had already been shown.
            ///
            /// Zero on a link with no reordering, which is most of them, and the reason motion
            /// can look mechanically wrong while every other number is perfect: a frame whose
            /// moment has passed is not a frame missing, it is a frame *back*, and a rotating
            /// object shown one step behind and then two forward reads as a stall and a
            /// reversal rather than as a dropped frame.
            public var outOfOrder = 0

            /// Times the presentation schedule was restarted from a new frame.
            ///
            /// One at the start of a stream is the schedule beginning. More than that is it
            /// losing hold, and each one moves the timebase under everything already queued.
            public var reanchors = 0

            /// Times the even presentation grid was restarted.
            ///
            /// One at the start of a stream, and then one per genuine break in the source's
            /// timeline. A stream of them means the grid is chasing something that is not a fixed
            /// frame rate, and the smoothing it provides is not being had.
            public var regrids = 0

            /// Times the publisher changed the shape of the picture.
            ///
            /// A host switching layout, and expected to be occasional and deliberate. Worth
            /// counting because it is the one event that changes what a viewer is looking at
            /// without anything going wrong, so it is the first thing to rule out when somebody
            /// reports that a tile "jumped": one reshape is a layout change, a stream of them is
            /// a publisher oscillating between two geometries.
            public var reshapes = 0

            /// Which of the delay controller's four paths moved the delay, and how often.
            ///
            /// Here because the delay's value does not say how it got there, and the answer
            /// decides what to do about it. A delay of two hundred milliseconds reached by
            /// widening is a link whose jitter wants that much; the same figure reached by the
            /// floor is lip sync asking for it on the voice's behalf; and the same figure with
            /// a large ``playoutSlack`` beside it is neither — it is delay picked up from the
            /// frames the schedule happened to anchor on, which the reclaim is supposed to give
            /// back and evidently has not.
            ///
            /// Four counters rather than a log line because the interesting pattern is a
            /// ratio over a minute: widenings far outnumbering tightenings is a controller
            /// being driven, and reclaims that never happen with slack to spare is one that
            /// cannot get back what it took.
            public var widenings = 0
            public var tightenings = 0
            public var floorRaises = 0
            public var reclaims = 0

            public init() {}

            /// The share of frames that reached the display layer.
            public var delivered: Double {
                let total = enqueued + skippedNotReady + skippedUndescribed
                return total > 0 ? Double(enqueued) / Double(total) : 0
            }
        }

        public init(codec: VideoCodec = .hevc) {
            assembler = SampleBufferAssembler(codec: codec)
            layer.videoGravity = .resizeAspectFill
            synchroniser.addRenderer(layer.sampleBufferRenderer)
        }

        /// Present a frame on an even grid rather than at the timestamp it carries.
        ///
        /// The timestamps are honest and still unevenly spaced: a camera at sixty frames a second
        /// delivers them a median 16.7ms apart with a 95th percentile near 20ms, because capture
        /// is not a metronome. Presented as stamped on a 60Hz display, a frame 3ms late crosses a
        /// refresh boundary — it is shown for two refreshes and its successor for none. Every
        /// frame is there, in order, on time by every measure, and the motion still hitches
        /// several times a second. On a face nobody notices. On a ceiling fan it reads as the
        /// blades stalling and stepping backwards.
        ///
        /// So each frame is placed at the nearest slot on a grid of the frame interval. Nearest,
        /// rather than one slot per frame, because a frame genuinely missing upstream must stay a
        /// gap: counting slots would quietly speed the video up to hide it. The grid itself is
        /// slewed a fraction of a millisecond at a time toward where the frames actually are,
        /// which absorbs the difference between the publisher's crystal and this one without ever
        /// moving the picture enough to see.
        ///
        /// - Returns: The time to present at, always later than the previous frame's.
        private func regularise(_ presentation: CMTime, interval: Double) -> CMTime {
            guard let start = grid else {
                grid = presentation
                slot = 0
                return presentation
            }

            let offset = (presentation - start).seconds
            var index = (offset / interval).rounded()

            // Two frames landing in one slot is jitter of half an interval, and the slot below is
            // already spent. Forward by one keeps the grid monotonic, which is the one property
            // the display layer cannot recover from losing.
            if index <= Double(slot) { index = Double(slot) + 1 }

            // Beyond this the source is not jittering, it has moved: a publisher that reconnected,
            // a stall long enough to break the run, a swapped source. Slewing toward that would
            // take minutes and show a lurch every frame of it.
            let error = offset - index * interval
            guard abs(error) < 0.25 else {
                grid = presentation
                slot = 0
                latched = nil
                gaps = []
                gapCursor = 0
                slewed = 0
                slews = 0
                drawing.regrids += 1
                return presentation
            }

            slot = Int64(index)

            // Clamped well below one refresh, so correcting drift is never itself visible. Half a
            // millisecond per frame is thirty milliseconds a second of authority: far more than
            // two crystals disagree by, and enough to absorb a latched interval that is a fraction
            // of a percent from the true one.
            let slew = min(max(error / 32, -0.0005), 0.0005)
            grid = start + CMTime(seconds: slew, preferredTimescale: 90000)
            correctRate(after: slew)

            return start + CMTime(seconds: index * interval, preferredTimescale: 90000)
        }

        /// Fold a persistent one-way slew back into the interval it is compensating for.
        ///
        /// Phase and frequency are different faults and the slew alone only fixes one. A latched
        /// interval a fraction of a percent from the true rate makes the grid drift against the
        /// stream at a constant rate forever, and the slew then spends every frame pushing back
        /// against it — the picture stays even, but the whole schedule walks. Measured on a leg
        /// whose publisher ran a shade off sixty, the headroom climbed from 11ms to 50ms and was
        /// hauled back every few seconds, so the latency a person experienced swung by forty
        /// milliseconds continuously while every other figure looked perfect.
        ///
        /// The average slew over a long window *is* the frequency error, so adding it to the
        /// interval removes the drift and leaves the slew doing what it is for: jitter.
        private func correctRate(after slew: Double) {
            slewed += slew
            slews += 1
            guard slews >= 240, var interval = latched else { return }

            // Bounded at a fifth of a percent, which is far more than two crystals disagree by
            // and far less than the distance between any two frame rates worth latching. A larger
            // correction would mean the interval is not slightly wrong, it is the wrong rate, and
            // the answer to that is to measure again rather than to creep towards it.
            let correction = min(max(slewed / Double(slews), -interval / 500), interval / 500)
            interval += correction
            latched = interval
            slewed = 0
            slews = 0
        }

        /// The frame interval this stream is actually arriving at, in seconds.
        ///
        /// Measured rather than configured: the publisher's rate is in a catalog this class does
        /// not read, can change mid-call, and is a nominal figure anyway. A median over the recent
        /// past ignores the occasional doubled gap where a frame went missing.
        ///
        /// Latched once and then left alone, which is not fussiness. The grid places a frame at
        /// `round(offset / interval)` slots from an anchor that recedes for as long as the stream
        /// lasts, so the interval multiplies: a median that wanders half a percent as the window
        /// rolls moves a frame a whole slot for every two hundred slots of offset — thirty
        /// milliseconds of jump a minute into a call, which is worse than the jitter being
        /// removed. Residual error between the latched figure and the true rate is what the slew
        /// is for.
        ///
        /// `nil` until there is enough history to be worth trusting.
        private func interval(after presentation: CMTime) -> Double? {
            defer { previousStamp = presentation }
            if let latched { return latched }
            guard previousStamp.isValid else { return nil }

            let gap = (presentation - previousStamp).seconds
            if gap > 1.0 / 240, gap < 1.0 / 5 {
                if gaps.count < Self.gapWindow {
                    gaps.append(gap)
                } else {
                    gaps[gapCursor] = gap
                    gapCursor = (gapCursor + 1) % Self.gapWindow
                }
            }

            guard gaps.count >= 24 else { return nil }
            let sorted = gaps.sorted()
            let median = sorted[sorted.count / 2]

            // Snapped to the rate the publisher is almost certainly running at, because a measured
            // median is a measurement of the camera's jitter as well as of its rate, and a grid
            // built on 16.58ms when the truth is 16.667ms spends the whole call being slewed.
            let rate = 1 / median
            let common: [Double] = [15, 24, 25, 30, 48, 50, 60, 90, 120]
            let nearest = common.min { abs($0 - rate) < abs($1 - rate) }
            if let nearest, abs(nearest - rate) / rate < 0.02 {
                latched = 1 / nearest
            } else {
                latched = median
            }
            return latched
        }

        /// Copy a sample with a new presentation time and an explicit duration.
        ///
        /// The duration matters as much as the time: without it the display layer holds each frame
        /// until the next one is due, which is the same thing only when the schedule is never
        /// short of frames.
        private func retime(
            _ sample: CMSampleBuffer,
            to presentation: CMTime,
            duration: Double
        ) -> CMSampleBuffer? {
            var timing = CMSampleTimingInfo(
                duration: CMTime(seconds: duration, preferredTimescale: 90000),
                presentationTimeStamp: presentation,
                decodeTimeStamp: .invalid
            )
            var copy: CMSampleBuffer?
            let status = CMSampleBufferCreateCopyWithNewTiming(
                allocator: kCFAllocatorDefault,
                sampleBuffer: sample,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleBufferOut: &copy
            )
            return status == noErr ? copy : nil
        }

        /// Size the delay to the slack the link is actually leaving.
        ///
        /// Adjusted by moving the grid rather than by re-anchoring the schedule, which matters more
        /// than it sounds. Re-anchoring moves the timebase under every frame already queued, so
        /// what was evenly spaced becomes early or late together and the picture lurches once for
        /// each adjustment — a buffer that adapts by lurching is not obviously better than one that
        /// is simply too small. Moving the grid changes when *future* frames are due and leaves
        /// everything queued exactly where it was.
        ///
        /// - Parameter interval: The frame interval, used to bound how far one adjustment may move
        ///   the picture.
        private func resize(interval: Double, bounds: (floor: Duration, ceiling: Duration)) {
            // Five seconds of frames before anything is decided, because the figure being read is
            // a low quantile and a low quantile of a short window is the worst sample in it. At
            // three percent and two seconds it was the fourth-worst of a hundred and twenty,
            // which moves tens of milliseconds between one reading and the next on a link that
            // has not changed at all.
            guard slack.count >= 300, let worst = slackQuantile(playoutTolerance) else { return }
            playoutSlack = worst

            let depth = playoutDepth.asSeconds
            let ceiling = bounds.ceiling.asSeconds
            let floor = min(max(bounds.floor, playoutFloor).asSeconds, ceiling)

            // What to do is decided in ``PlayoutDelay``, which has no clock and no layer and can
            // therefore be run against a made-up link a thousand times in a test. What follows is
            // only the doing of it.
            let move = PlayoutDelay.adjustment(
                headroom: worst,
                delay: depth,
                floor: floor,
                ceiling: ceiling,
                interval: interval,
                mayGiveBack: catchUp == nil
                    && ContinuousClock.now - reclaimed > .milliseconds(1500),
                mayTighten: ContinuousClock.now - tightened > .milliseconds(250)
            )

            switch move {
            case .leaveItAlone:
                return

            case let .raiseToTheFloor(raised):
                drawing.floorRaises += 1
                shift(by: raised - depth, to: .seconds(raised))

            case let .widen(widened):
                drawing.widenings += 1
                shift(by: widened - depth, to: .seconds(widened))

            case let .giveBack(give, landing):
                // Capped at six percent because this timebase carries the picture and not the
                // voice, so a fast clock is also lip sync closing at the same speed. Six percent
                // for the second or two a large give takes is a couple of frames of it, against
                // a give-back that otherwise does not finish at all.
                //
                // Over about a second whatever the size, rather than at a fixed speed. A fixed
                // two percent is a second for the twenty milliseconds an anchor usually costs
                // and five seconds for the hundred a jittery link produces, and five seconds is
                // longer than the interval between the re-anchors that produce it: measured
                // through a relay whose arrivals had a 34ms median and an 84ms 95th percentile,
                // both legs of every call sat at 1.02 from start to finish, reported a 23-48ms
                // delay, and made their frames wait 53-95ms the whole time. The controller was
                // right about the delay it wanted and simply never got there.
                let rate = min(1.06, max(1.02, 1 + give))
                synchroniser.setRate(Float(rate), time: synchroniser.currentTime())
                catchUp = .now + .seconds(give / (rate - 1))
                catchUpGive = give
                catchUpLanding = landing
                drawing.reclaims += 1

            case let .tighten(reduced):
                tightened = .now
                drawing.tightenings += 1
                shift(by: reduced - depth, to: .seconds(reduced))
            }
        }

        /// The slack that only the given share of recent frames fell below.
        ///
        /// A quantile rather than the minimum, and that is the whole design. The minimum is the
        /// worst thing the link did in ten seconds, and sizing for it means paying its cost on
        /// every frame forever; a low quantile says how much delay covers all but a stated few.
        private func slackQuantile(_ share: Double) -> Double? {
            guard !slack.isEmpty else { return nil }
            let sorted = slack.sorted()
            let index = Int((Double(sorted.count - 1) * max(0, min(1, share))).rounded())
            return sorted[index]
        }

        /// Remember how much slack a frame arrived with.
        private func record(slack seconds: Double) {
            if slack.count < Self.slackWindow {
                slack.append(seconds)
            } else {
                slack[slackCursor] = seconds
                slackCursor = (slackCursor + 1) % Self.slackWindow
            }
        }

        /// Move the grid, and with it every frame not yet due.
        private func shift(by seconds: Double, to depth: Duration) {
            guard let start = grid else { return }
            grid = start + CMTime(seconds: seconds, preferredTimescale: 90000)
            playoutDepth = depth

            // Every remembered arrival is re-read against the grid it would now be measured
            // against, because moving the grid changes what all of them meant. Without this the
            // window holds ten seconds of headroom recorded before the last adjustment, each
            // adjustment is decided on evidence that predates the previous one, and the loop
            // tightens far past the point where the headroom was gone — measured, it walked a
            // hundred milliseconds too early, ran out of frames, re-anchored a hundred and
            // thirty times and ended pinned against the ceiling. The correction is exact rather
            // than approximate: the grid moved by one amount, so every slack against it moved by
            // that same amount.
            for index in slack.indices { slack[index] += seconds }
            playoutSlack = playoutSlack.map { $0 + seconds }
        }

        /// Put the presented timeline where the arriving frames are.
        ///
        /// Called on the first frame and whenever the schedule has drifted out of reach of what
        /// is arriving. Drift is not optional to handle: the timestamps come from the publisher's
        /// clock and the schedule runs on this device's, so the two diverge at whatever rate the
        /// two crystals disagree — and a viewer that never re-anchors either accumulates delay
        /// for the whole call or slowly runs ahead of the stream and shows every frame late.
        private func anchorSchedule(to presentation: CMTime, delay: Duration) {
            let seconds = Double(delay.components.seconds)
                + Double(delay.components.attoseconds) / 1e18
            let start = presentation - CMTime(seconds: seconds, preferredTimescale: 90000)

            // Counted, because re-anchoring is not free and is invisible in every other figure.
            // It moves the timebase under frames already queued, so what was scheduled evenly is
            // suddenly early or late together: the picture lurches once per re-anchor while the
            // arrival cadence, the timeline and the delivery rate all stay perfect. Rare is fine
            // and is the design; often means the schedule cannot keep hold of the stream, and
            // then this is the number that says so rather than a person describing the motion.
            if anchor != nil {
                drawing.reanchors += 1

                // Carried across the re-anchor rather than discarded, corrected by however far
                // the timebase moved. Discarding it is the obvious thing and it fails in exactly
                // the situation the adaptation exists for: a link in trouble re-anchors often,
                // each re-anchor emptied the window, the window never refilled to the two seconds
                // a decision needs, and so the delay sat at its floor through a storm that wanted
                // it at the ceiling. Measured during one, that was eighty-seven stalls and a
                // third of a minute frozen while the buffer stayed at five milliseconds.
                //
                // The correction is the same in kind as a grid shift: the newest frame had
                // whatever headroom it had, and after this it has exactly `delay`, so every
                // remembered sample moves by that difference.
                if newest.isValid {
                    let was = (newest - synchroniser.currentTime()).seconds
                    let moved = seconds - was
                    for index in slack.indices { slack[index] += moved }
                    playoutSlack = playoutSlack.map { $0 + moved }
                }
            }

            anchor = start
            catchUp = nil
            synchroniser.setRate(1, time: start)
        }

        /// Keep the schedule within reach of the stream, re-anchoring when it is not.
        ///
        /// The window is deliberately wide. Correcting small errors would mean nudging the rate
        /// every few frames, and a presentation rate that is constantly adjusted is its own
        /// source of visible unevenness — the thing this exists to remove.
        private func maintainSchedule(delay: Duration, interval: Double?) {
            guard anchor != nil, newest.isValid else { return }
            let seconds = Double(delay.components.seconds)
                + Double(delay.components.attoseconds) / 1e18
            let depth = (newest - synchroniser.currentTime()).seconds

            // Behind means frames are being scheduled for a moment that has already passed, and
            // every one of them is shown late; far ahead means the delay has grown well past
            // what was asked for and the latency is no longer the one the caller chose.
            //
            // The upper bound is the delay plus a fixed allowance rather than a multiple of it,
            // because a multiple makes the tolerance shrink with the thing being tolerated. A
            // caller asking for 25ms was getting a 125ms ceiling on a link whose own tail reaches
            // 90ms, so an ordinary burst re-anchored the schedule — and re-anchoring moves the
            // timebase under everything queued, which is a visible lurch. The allowance is what a
            // burst is worth; the delay is what the caller asked to pay on top of it.
            //
            // The lower bound allows a frame to be a frame late rather than demanding that none
            // ever are, because ``playoutTolerance`` exists precisely to let a stated few miss.
            // Re-anchoring on the first of them puts the two in opposition, and the schedule
            // loses: measured, a leg tuned to allow five percent late re-anchored eighteen
            // hundred times in fifty seconds, which cleared the headroom history on each one and
            // left the adaptation with nothing to decide on.
            let allowance = max(interval ?? 0, 0.02)
            if depth < -allowance || depth > seconds + 0.15 {
                anchorSchedule(to: newest, delay: delay)
            }
        }

        private func apply(mirroring: Bool) {
            // Without disabling actions this animates, and a preview that
            // swings through edge-on when the user taps the flip button reads
            // as a glitch rather than as a transition.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.transform = mirroring
                ? CATransform3DMakeScale(-1, 1, 1)
                : CATransform3DIdentity
            CATransaction.commit()
        }

        /// Adopt the codec the publisher's catalog names.
        public func setCodec(_ codec: VideoCodec) {
            assembler.setCodec(codec)
        }

        /// The size of the frames now being decoded, once any have been.
        ///
        /// What a view should lay itself out against. It follows the publisher
        /// through a geometry change, which a size taken from the catalog does
        /// not do promptly: the reshaped keyframe and the catalog version that
        /// describes it are on different tracks and arrive in either order.
        public var presentedSize: PixelSize? { assembler.presentedSize }

        /// Draw a reassembled frame, flushing first when objects were lost.
        ///
        /// The gap handling is why this overload exists rather than leaving
        /// callers to unwrap the frame themselves: enqueueing across a hole
        /// feeds the decoder references that never arrived, and the artefacts
        /// last until the next keyframe.
        ///
        /// A change of shape is not a gap and is deliberately not flushed. The
        /// display layer takes a queue of sample buffers each carrying its own
        /// format description, so handing it a differently sized keyframe is a
        /// supported thing to do and it switches at that frame. Flushing instead
        /// would throw away the frames already queued behind it, blank the last
        /// picture, and drop the presentation anchor — three visible costs for an
        /// event that needs none of them, since the publisher's timeline did not
        /// break and its geometry is the only thing that moved.
        public func enqueue(_ frame: DepacketisedFrame) throws(MoqomError) {
            if frame.followsGap { flush() }
            if frame.changesFormat { drawing.reshapes += 1 }
            try enqueue(frame.frame)
        }

        /// Show a frame.
        ///
        /// Drops rather than throws when the layer has failed, because the
        /// recovery is to rebuild the layer and the caller cannot do anything
        /// useful per frame.
        public func enqueue(_ frame: EncodedFrame) throws(MoqomError) {
            // `sampleBufferRenderer` rather than the layer's own status, enqueue
            // and flush, which are deprecated as of the 15/26 SDKs. Invisible
            // while the floor was macOS 14; raising it to 26 is what surfaced
            // them. Same object underneath, so this is a rename, not a
            // behaviour change.
            let renderer = layer.sampleBufferRenderer
            if renderer.status == .failed {
                renderer.flush()
                drawing.failures += 1
                return
            }

            // Counted, because these two are the quietest way a viewer loses a frame. Everything
            // upstream reports success — the object arrived, reassembly produced a frame, no gap
            // was detected — and the picture still misses a step. A display layer that is not
            // ready is a decoder that is behind, and a frame skipped for that reason never
            // appears in any loss statistic on either device.
            guard renderer.isReadyForMoreMediaData else {
                drawing.skippedNotReady += 1
                return
            }
            guard let sample = try assembler.sampleBuffer(for: frame) else {
                drawing.skippedUndescribed += 1
                return
            }

            // Ordering, which nothing upstream provides for video. QUIC orders a stream and a
            // subgroup is a stream, so frames within a group arrive in order and this costs
            // nothing for most of a call. Group boundaries are where that stops being true: the
            // tail of one group and the head of the next travel on different streams, and the
            // network is entitled to deliver the second first. At sixty frames a second with a
            // group every keyframe, that boundary comes round often enough to be seen.
            //
            // Refused rather than reordered, which is the smaller half of the fix and the half
            // that removes the artefact. Handing the display layer a timestamp older than one
            // already shown does not lose the frame, it *plays* it, so a fan blade steps
            // backwards and then forwards again — read by anyone watching as a fault in the
            // room rather than in the network. Skipping costs the one frame instead.
            //
            // The other half is a real video jitter buffer: hold every frame for the playout
            // delay already being paid and release in timestamp order, which is what the audio
            // path does and what this should grow into. Until it exists, this counter is how
            // anybody knows whether it is needed.
            // Bounded, because "older than the newest" has a second cause: a timeline that
            // restarted. A publisher that reconnects, or a source swapped underneath, can begin
            // again far behind where this renderer had reached, and a rule that refused
            // everything older would then refuse every frame forever — a permanent black tile
            // in place of an occasional backwards step, which is a much worse trade. A second is
            // far more than any reordering the network will do and far less than any restart.
            let source = sample.presentationTimeStamp
            if source.isValid, newestSource.isValid, source < newestSource {
                let behind = (newestSource - source).seconds
                if behind < 1 {
                    drawing.outOfOrder += 1
                    return
                }
                flush()
            }

            // Regridded only when something is scheduling presentation. With no schedule the
            // frames are shown on arrival whatever their timestamps say, and rewriting a timestamp
            // nothing reads would cost a copy per frame to no effect.
            var drawn = sample
            var presentation = source
            var cadence: Double?
            if
                requestedDelay != nil,
                source.isValid,
                let interval = interval(after: source),
                case let even = regularise(source, interval: interval),
                let retimed = retime(drawn, to: even, duration: interval)
            {
                drawn = retimed
                presentation = even
                cadence = interval
            }

            renderer.enqueue(drawn)
            drawing.enqueued += 1

            if source.isValid { newestSource = source }
            if presentation.isValid { newest = presentation }
            guard let delay = requestedDelay, presentation.isValid else { return }
            if anchor == nil {
                anchorSchedule(to: presentation, delay: delay)
                return
            }
            maintainSchedule(delay: delay, interval: cadence)
            advanceCatchUp()

            // Measured after the schedule is known to be running, because slack against a
            // timebase that has not started is not slack, it is the distance to a clock at zero.
            guard let bounds = playoutBounds, let cadence, catchUp == nil else { return }
            record(slack: (presentation - synchroniser.currentTime()).seconds)
            if drawing.enqueued % 30 == 0 { resize(interval: cadence, bounds: bounds) }
        }

        /// Show a captured frame without encoding it.
        ///
        /// This is the local preview, and it deliberately does not go through
        /// the encoder. Previewing the encoded stream would show the publisher
        /// their own latency and their own compression artefacts, and would
        /// keep the camera visible on screen only for as long as the
        /// publication survived.
        ///
        /// Silently ignores a frame with no pixels, because the synthetic
        /// surface exists precisely for paths that have no GPU.
        public func enqueue(_ frame: VideoFrame) {
            guard case let .pixelBuffer(buffer) = frame.surface else { return }

            let renderer = layer.sampleBufferRenderer
            if renderer.status == .failed { renderer.flush() }
            guard renderer.isReadyForMoreMediaData else { return }

            if let held = previewFormat,
               !CMVideoFormatDescriptionMatchesImageBuffer(held, imageBuffer: buffer)
            {
                previewFormat = nil
            }

            if previewFormat == nil {
                var made: CMFormatDescription?
                guard
                    CMVideoFormatDescriptionCreateForImageBuffer(
                        allocator: kCFAllocatorDefault,
                        imageBuffer: buffer,
                        formatDescriptionOut: &made
                    ) == noErr
                else { return }
                previewFormat = made
            }

            guard let format = previewFormat else { return }

            var timing = CMSampleTimingInfo(
                duration: .invalid,
                presentationTimeStamp: frame.timestamp.cmTime,
                decodeTimeStamp: .invalid
            )
            var sample: CMSampleBuffer?
            guard
                CMSampleBufferCreateReadyWithImageBuffer(
                    allocator: kCFAllocatorDefault,
                    imageBuffer: buffer,
                    formatDescription: format,
                    sampleTiming: &timing,
                    sampleBufferOut: &sample
                ) == noErr,
                let sample
            else { return }

            if
                let attachments = CMSampleBufferGetSampleAttachmentsArray(
                    sample,
                    createIfNecessary: true
                ) as? [CFMutableDictionary],
                let first = attachments.first
            {
                CFDictionarySetValue(
                    first,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
                )
            }

            renderer.enqueue(sample)
        }

        /// What the display layer did with the frames after they were handed over.
        ///
        /// The one stage nothing on the way in can see. A frame that arrived in order, on time,
        /// was never dropped and was accepted by the layer can still miss its display deadline,
        /// and the layer then drops it silently — so motion is visibly wrong while every counter
        /// upstream reads perfect. Periodic motion is where it shows: a face survives a frame
        /// held an extra refresh, and a rotating blade turns it into a stall and a reversal.
        public struct Presentation: Sendable, Hashable {
            /// Frames that would have been shown had none been dropped.
            public var total = 0

            /// Dropped before decoding, or for missing a display deadline.
            public var dropped = 0

            public var corrupted = 0

            /// Total lateness accumulated across the frames that were shown, in seconds.
            public var delay = 0.0

            public init() {}
        }

        /// `nil` where the platform does not report metrics, which is not a fault.
        ///
        /// The completion-handler form rather than the `async` property, because the property is
        /// nonisolated and awaiting it would carry the renderer — which is not `Sendable` — off
        /// this actor. Reading the numbers inside the handler and resuming with a value type
        /// keeps the object where it belongs and sends only integers across.
        public func presentation() async -> Presentation? {
            if #available(iOS 17.4, macOS 14.4, tvOS 17.4, visionOS 1.1, *) {
                let renderer = layer.sampleBufferRenderer
                return await withCheckedContinuation { continuation in
                    renderer.loadVideoPerformanceMetrics { metrics in
                        guard let metrics else {
                            continuation.resume(returning: nil)
                            return
                        }
                        var presentation = Presentation()
                        presentation.total = metrics.totalNumberOfFrames
                        presentation.dropped = metrics.numberOfDroppedFrames
                        presentation.corrupted = metrics.numberOfCorruptedFrames
                        presentation.delay = metrics.totalAccumulatedFrameDelay
                        continuation.resume(returning: presentation)
                    }
                }
            }
            return nil
        }

        /// Discard everything queued.
        ///
        /// Called on a rung change and on resumption after a gap: the queued
        /// frames reference a format or a group that no longer applies.
        public func flush() {
            // Successor to the deprecated `flushAndRemoveImage()`. The
            // completion handler is the only thing genuinely new and we do not
            // want it: a rung change should not wait on the display pipeline.
            layer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)

            // Dropped along with the frames it was scheduling. What arrives next is a new
            // keyframe from a group that may be some way from where the timeline had reached,
            // and a schedule anchored to the old one would either sit idle waiting for a time
            // already passed or hold the new picture back for as long as the difference.
            anchor = nil
            newest = .invalid
            newestSource = .invalid
            synchroniser.setRate(0, time: .invalid)

            // The grid goes with the schedule it was feeding. The rate estimate does not: the
            // stream after a flush is the same stream at the same frame rate, and throwing away
            // two seconds of measurement means two seconds of unsmoothed video to rebuild it.
            grid = nil
            slot = 0
            previousStamp = .invalid
        }
    }

    extension Duration {
        /// Seconds as a `Double`, which is what CoreMedia and the arithmetic here both want.
        fileprivate var asSeconds: Double {
            Double(components.seconds) + Double(components.attoseconds) / 1e18
        }
    }
#endif
