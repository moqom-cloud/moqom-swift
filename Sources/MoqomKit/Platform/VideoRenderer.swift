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

        /// How often the panel this is drawing on refreshes, in seconds.
        ///
        /// Part of the delay, and the part nothing about the link decides: a frame handed over
        /// between two refreshes waits for the next one, so the schedule has to hold enough margin
        /// to cover a boundary it cannot see. How much is ``PlayoutDelay/margin(refresh:)``.
        ///
        /// Defaults to sixty hertz, which is the safe answer rather than the common one — a phone
        /// is usually faster, and being wrong in that direction costs latency while being wrong in
        /// the other drops frames. Whoever owns the view knows the screen and should say.
        public var displayRefresh = PlayoutDelay.sixtyHertz

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

        /// How long the frame in the middle waits between arriving and being shown, in seconds.
        ///
        /// The hold, and the honest half of a glass-to-glass figure. ``playoutSlack`` is the
        /// wrong number for that and reads plausibly enough to be believed: it is a low quantile,
        /// so it describes the margin of the unluckiest frames rather than the wait of a typical
        /// one, and on a link in trouble it goes *negative* while the delay in force is at its
        /// ceiling. Clamped at zero it then reports a struggling receiver as having no hold at
        /// all — measured on two phones, one holding 250ms showed forty and the other holding
        /// 155ms showed a hundred and twenty, so the worse leg read three times better.
        ///
        /// Clamped for the same reason ``playoutSlack`` is not: a frame that arrives after its
        /// deadline is shown when it can be, and a negative wait is not a thing that happens to
        /// it. Frames that missed are counted in ``Drawing/late`` where they can be seen.
        ///
        /// Read from the schedule rather than from the arrival window — see ``held`` — because the
        /// arrival window has to be displaced every time the grid moves, and this figure was got
        /// wrong twice that way: once reading half a second on a leg holding twenty-nine
        /// milliseconds, and once reading zero on a leg holding fifty.
        public private(set) var playoutHold: Double?

        private func restartSchedule() {
            anchor = nil
            synchroniser.setRate(0, time: .invalid)
            grid = nil
            slack = []
            slackCursor = 0
            held = []
            heldCursor = 0
            playoutSlack = nil
            playoutHold = nil
            // The next arrival follows a stream change rather than a pause, so the gap before it
            // means nothing and must not be read as one.
            arrived = nil
            strayed = nil
            evidence.restart()
            catchUp = nil

            // Unlike a re-anchor, which keeps it. This is a new stream and possibly a new
            // publisher, so the ratio between the two clocks is no longer the one that was
            // learnt — and a correction carried onto a clock it was not measured against is
            // worse than none.
            tracking.forget()
            // The display's target, not the application's floor. Starting at zero — which is
            // what `bounds.floor` is, on purpose, so the floor is not the answer — spent the
            // first two seconds missing deadlines, leapt to the ceiling, and left the hold
            // sitting on the extra the leap was anchored with. The target is what the loop
            // would settle on once it had evidence; beginning there skips the evidence it
            // would have drawn from a depth nobody would choose.
            playoutDepth = playoutBounds.map { bounds in
                let floor = max(bounds.floor, playoutFloor).asSeconds
                let display = PlayoutDelay.margin(refresh: displayRefresh)
                let ceiling = PlayoutDelay.ceiling(
                    asked: bounds.ceiling.asSeconds,
                    floor: floor,
                    interval: displayRefresh,
                    display: display
                )
                return .seconds(
                    PlayoutDelay.target(floor: floor, ceiling: ceiling, display: display)
                )
            }
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

        /// Whole slots of delay the forcings have taken on and not yet handed back.
        private var debt = 0

        /// The most of it worth carrying, in slots.
        ///
        /// Four, which at sixty frames a second is a sixteenth of a second and more than a run of
        /// bad luck produces. The cap is not about the delay — a debt this large has already been
        /// paid, and refusing to record it does not give it back — but about the handing back. An
        /// uncapped debt meeting a long gap after a stall would close the whole of it at once, and
        /// a picture that jumps a quarter of a second forward to settle an old account is a worse
        /// thing to watch than the account is to keep. Past this, the recovery belongs to a
        /// re-anchor, which is the mechanism for a schedule that has lost its place.
        private static let mostDebtWorthReclaiming = 4

        /// The last source timestamp, for measuring the interval to the next.
        private var previousStamp: CMTime = .invalid

        /// How much slack each recent frame arrived with, in seconds, for sizing the delay.
        ///
        /// Six hundred samples, which at thirty frames a second is twenty seconds — the reason
        /// ``ArrivalEvidence`` exists. A sample that does not describe the link stays here for
        /// twenty seconds, and with a one percent tolerance the sixth-worst of them decides the
        /// delay, so six frames of one interruption are enough to set it for that whole time.
        private var slack: [Double] = []
        private var slackCursor = 0
        private static let slackWindow = 600

        /// How long the queued frames were actually waiting, in seconds.
        ///
        /// Kept apart from ``slack`` and deliberately not corrected the way it is. A slack sample
        /// says how much headroom a frame arrived with against the grid of the moment, so when the
        /// grid moves every sample has to be displaced with it — and each displacement is another
        /// chance to be wrong about a figure a person reads. Twice now it has been: once when a
        /// re-anchor put its whole drift onto six hundred samples, and once when the hold was left
        /// behind by a shift and clamped to zero.
        ///
        /// This is read straight off the schedule on every frame, against the grid in force at
        /// that moment. It is never stale, never needs adjusting, and answers the question the
        /// glass-to-glass figure is actually asking: how long does a frame wait.
        private var held: [Double] = []
        private var heldCursor = 0
        private static let heldWindow = 300

        /// When the previous frame was enqueued, for telling a pause from ordinary unevenness.
        private var arrived: ContinuousClock.Instant?
        private var evidence = ArrivalEvidence()

        /// When the delay was last tightened, so tightening happens gradually.
        private var tightened = ContinuousClock.now

        /// When the schedule last gave back the headroom it was anchored with, so it is rare.
        private var reclaimed = ContinuousClock.now

        /// When the clock currently running fast should return to normal, by how much it will
        /// have moved by then, and the delay that leaves in force.
        private var catchUp: ContinuousClock.Instant?
        private var catchUpGive = 0.0
        private var catchUpLanding = 0.0

        /// Keeps this schedule level with the clock that stamped the frames. See
        /// ``ScheduleTracking``.
        private var tracking = ScheduleTracking()

        /// When the correction was last revised, so it is revised on a schedule rather than
        /// once per frame.
        private var tracked = ContinuousClock.now

        /// When the schedule first ran past the frames it had, or `nil` while it has some.
        private var strayed: ContinuousClock.Instant?

        /// Run the presentation clock at a rate, keeping the timeline continuous across it.
        private func run(at rate: Double) {
            // A tenth of a percent, which is well under what an eye resolves in the motion of a
            // talking head and well over the parts-per-million the drift correction deals in. What
            // is being counted is the loop changing its mind, not the loop working.
            if abs(rate - running) > 0.001 { drawing.speedShifts += 1 }
            running = rate
            drawing.widestSpeed = max(drawing.widestSpeed, abs(rate - 1))

            synchroniser.setRate(Float(rate), time: synchroniser.currentTime())
        }

        /// The rate the presentation clock was last set to.
        private var running = 1.0

        /// Hold the schedule level with the publisher's clock.
        ///
        /// Called with every frame and acting four times a second, which is slow next to the
        /// thing it corrects — parts per million, a millisecond every few seconds — and fast
        /// enough that the error never reaches anything visible.
        private func track(depth: Double, wanted: Double) {
            // Not while the clock is already running fast on purpose. A give-back is a large
            // one-off correction with a known end; this is the small permanent one, and both
            // driving the rate at once means neither knows what it achieved.
            guard catchUp == nil else { return }

            let now = ContinuousClock.now
            guard now - tracked >= .milliseconds(250) else { return }
            tracked = now

            let moved = tracking.correction(depth: depth, wanted: wanted)
            drawing.drains = tracking.drains
            drawing.refills = tracking.refills
            drawing.observations = tracking.observations
            guard let rate = moved else { return }
            drawing.trim = tracking.standing * 1_000_000
            run(at: 1 + rate)
        }

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
            // Back to the standing correction rather than to one exactly, because the drift the
            // correction answers did not pause while the give-back ran. Returning to a flat 1
            // means starting the slide again from whatever the give-back left, and the loop
            // then spends its first seconds rediscovering a number it already knew.
            run(at: 1 + tracking.resuming())
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

            /// The headroom the delay is actually chosen from: how much earlier than its
            /// deadline all but the tolerated share of recent frames arrived. See
            /// ``playoutSlack``.
            ///
            /// Worth having beside ``ahead``, and not the same question. ``ahead`` is the
            /// newest frame, so it describes the typical arrival; this is a low quantile, so it
            /// describes the worst few. On a link that delivers in bursts they disagree
            /// completely — measured, a viewer whose frames sat 216ms ahead was holding a
            /// quarter-second buffer, which looks like a controller ignoring its own
            /// measurement until you can see that the measurement it reads was a different
            /// number entirely. Until this was reported, it was not visible anywhere.
            public var headroom: Double?

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
            timing.headroom = playoutSlack
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

        /// The extra places this picture is being drawn, and the machinery for drawing it there.
        ///
        /// Empty for almost every track in almost every call, and while it is empty none of this
        /// runs: frames go to the display layer compressed and it decodes them itself, which is
        /// the path everything else here was measured against.
        private var extras: [Presenter] = []
        private var sharedDecoder: VideoDecodeSession?
        private var sharedFormat: CMFormatDescription?
        private var isSharing = false

        /// The newest picture the shared decode produced, for a presenter that arrives between
        /// keyframes. A reference to one IOSurface, like every other copy of it here.
        private var latest: CMSampleBuffer?

        /// Decode every frame once here, from the first keyframe, so a view added later shows
        /// the current picture at once instead of waiting for the next keyframe.
        ///
        /// For a picture that is going to be in more than one place at a moment nobody can
        /// schedule: a feed card that expands into the room, a tile lifted into the stage. Off,
        /// the first presenter waits for a keyframe (up to a group, about two seconds) because
        /// the display layer's own decoder has no pictures to hand over. On, the cost is one
        /// decompression session per renderer whether or not anything is mirrored, which is the
        /// same cost the display layer was paying internally.
        ///
        /// Takes effect at the next keyframe.
        public var mirrorsInstantly = false

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

            /// Frames the shared decoder could not turn into a picture.
            ///
            /// Only ever counted while a host is on screen more than once, and expected to be
            /// zero even then: the changeover happens on a keyframe, and everything after a
            /// keyframe decodes. A steady count is the shared decode failing, and it looks
            /// different from every other kind of loss — the picture stops in every view of that
            /// host at once, because there is only one decode behind all of them.
            public var undecodable = 0

            /// Times this track changed between one decode for every view and letting the display
            /// layer decode for itself.
            ///
            /// Two per extra view opened and closed again. More than that is views being built
            /// and dismantled behind somebody's back, which is worth knowing about because each
            /// changeover drops whatever was queued at the moment it happened.
            public var changeovers = 0

            /// Times the schedule was moved to meet frames that had already missed the playhead.
            ///
            /// Discarding them until the next keyframe is what this replaced, and the reasoning
            /// behind that was sound about the wrong thing. Playing a late burst against a
            /// timebase that has already run past it is a fast-forward stutter; playing it
            /// against a timebase moved to meet it is just the stream, on time, a little later
            /// than before. The old path paid up to a whole group to avoid a stutter that moving
            /// the timeline does not produce — two seconds of nothing, at sixty frames a second
            /// with a keyframe every two, for one frame eighty milliseconds late.
            ///
            /// Measured on the call that prompted this: five thousand four hundred frames
            /// discarded against four thousand nine hundred shown, on a link that had delivered
            /// every one of them on time. Frequent rebases still mean the schedule cannot hold
            /// the stream, which is what this counts; they no longer mean the picture stops.
            public var rebases = 0

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

            /// The standing rate correction holding this schedule against the publisher's clock,
            /// in parts per million.
            ///
            /// Reported because it is the measurement nothing else here makes: the difference
            /// between two devices' idea of a second, which is otherwise only ever seen through
            /// its consequences. A few tens of it is two ordinary crystals. Sitting against its
            /// limit is the loop saying the thing it is being asked to track is not crystal
            /// drift at all.
            public var trim = 0.0

            /// How many of the tracking loop's observations took its drain path, out of how many
            /// it made.
            ///
            /// The drain leans on the error ten times harder than ordinary tracking and exists
            /// for one case: a schedule holding more delay than was asked for. So a hold above
            /// the request with this near zero is the drain being gated out, and a hold above the
            /// request with this near one is the drain running and losing. See
            /// ``ScheduleTracking/drains``.
            public var drains = 0

            /// Observations that ran the same correction the other way, recovering a queue about
            /// to run out. See ``ScheduleTracking/refills``.
            public var refills = 0

            /// Slots the grid left empty, and frames that arrived too close to the one before to
            /// have a slot of their own.
            ///
            /// The pair describes the picture rather than the schedule, which every other figure
            /// here describes instead. An empty slot holds the previous frame for two intervals
            /// and the motion visibly stops; a crowded one means a frame was pushed later than it
            /// was meant to be shown. A schedule can be perfectly level while both of these run,
            /// and a viewer would call that jitter and be right.
            public var gapped = 0
            public var crowded = 0

            /// Empty slots spent giving back delay a forcing had taken on, rather than left empty.
            ///
            /// The two counters above move in opposite directions and this is where they meet. A
            /// crowded frame is held an interval longer than it asked for and the pointer keeps
            /// that interval afterwards; a gap is an interval nothing was going to be shown in.
            /// Closing one against the other costs no frame and no rate — the speeding up is
            /// exactly the slowing down being undone — so this rising while ``gapped`` does not is
            /// the schedule paying off its own delay out of time it had no use for.
            public var reclaimedSlots = 0

            /// Frames that arrived after one newer than themselves.
            ///
            /// Distinct from ``crowded`` in kind rather than degree: a crowded frame is half an
            /// interval early and belongs where it is put, while one of these belongs at a moment
            /// already gone. Shown anyway — the grid is kept monotonic, so it lands after the
            /// newer frame — which puts older content on the screen after newer and takes the
            /// motion backwards before it goes on. Nothing else here can see it.
            public var stale = 0

            /// The interval the grid is being laid at, and the interval the frames are actually
            /// arriving at, both in seconds.
            ///
            /// The pair is the question the counters above raise and cannot answer. A grid laid a
            /// little slower than the source runs out of slots, and the frames that find theirs
            /// taken are pushed into the next one — which takes the slot after, and so on. Nothing
            /// in the schedule reports that, because from the schedule's point of view every frame
            /// was placed on the grid exactly as intended.
            public var laid = 0.0
            public var arriving = 0.0

            /// How far frames are being shown from the moment their timestamp asks for, in
            /// seconds: the middle of the recent window and its ninety-fifth.
            ///
            /// The figure that decides whether the grid is smoothing the stream or mangling it,
            /// and the one thing the placement counters cannot say. Placing an arrival on an even
            /// grid is only faithful while the arrival was nearly on it already — a frame moved
            /// half an interval is shown at a moment the camera never saw, and a stream of them
            /// moved by varying amounts is motion that stutters while every count reads clean.
            /// Bounded by construction at half an interval, so what matters is where in that range
            /// it sits: near zero is a grid locked to the stream, spread across it is not.
            public var phase = 0.0
            public var worstPhase = 0.0

            /// Slots between where a frame asked to go and the slot pointer, median and lowest.
            ///
            /// One is a grid keeping step with its stream. Below one is the pointer standing ahead
            /// of the frames, which is both a frame shown late by that many intervals and a frame
            /// that will be counted stale, so it is the quantity that says whether those are one
            /// fault or two.
            public var lead = 0.0
            public var worstLead = 0.0

            /// How far the presentation speed has been moved, in parts per million, and how often
            /// it has been moved by enough to matter.
            ///
            /// The loop's own documentation warns that a rate under constant adjustment is itself
            /// a source of visible unevenness, and the recovery authority was recently widened to
            /// five percent in both directions. This is what says whether that warning has come
            /// true: a rate wandering percent-wide several times a second is motion that speeds up
            /// and slows down, which looks like jitter and is not.
            public var speedShifts = 0
            public var widestSpeed = 0.0
            public var observations = 0

            /// Times the even presentation grid was restarted.
            ///
            /// One at the start of a stream, and then one per genuine break in the source's
            /// timeline. A stream of them means the grid is chasing something that is not a fixed
            /// frame rate, and the smoothing it provides is not being had.
            public var regrids = 0

            /// Frames found holding above the ceiling, which nothing here now acts on directly.
            ///
            /// It used to be the count of corrections made, and the correction is gone — see
            /// ``shift(by:to:)`` for why it could never work and the note beside its removal for
            /// why, once it could, it was one draining loop too many. What is left is the
            /// observation without the action: how often the hold is over its ceiling while
            /// ``ScheduleTracking`` is the only thing closing it.
            ///
            /// Which is the more useful of the two anyway. A count of corrections says how busy
            /// this was; a count of excesses says whether the loop that owns the depth is keeping
            /// its promise, and a number that does not fall over a call says it is not.
            ///
            /// Counted apart from ``regrids``, which it shared until the conflation hid a fault
            /// for the length of an investigation: four hundred of these beside two decisions by
            /// the delay controller reads as a grid restarting for no reason, and was in fact the
            /// ceiling being missed twice a second. Different events, different causes, and only
            /// one of them is about the source's timeline.
            public var handbacks = 0

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

            /// Delivery pauses noticed, and arrivals not charged to the link because of them.
            /// See ``ArrivalEvidence``.
            ///
            /// Read beside the widenings above. Widenings with no pauses is a link that is
            /// genuinely uneven and a delay that is correctly answering it; widenings that
            /// track the pauses are a call paying permanent latency for transient
            /// interruptions, which is what these were added to tell apart.
            public var pauses = 0
            public var dismissed = 0

            public init() {}

            /// The share of frames that reached the display layer.
            public var delivered: Double {
                let total = enqueued + skippedNotReady + skippedUndescribed + undecodable
                return total > 0 ? Double(enqueued) / Double(total) : 0
            }
        }

        public init(codec: VideoCodec = .hevc) {
            assembler = SampleBufferAssembler(codec: codec)
            layer.videoGravity = .resizeAspectFill
            synchroniser.addRenderer(layer.sampleBufferRenderer)
        }

        /// Another place this renderer's picture is drawn.
        ///
        /// One host can be on screen more than once — a gallery tile and the stage, a tile and a
        /// window — and each of those places needs a layer of its own, because a layer has
        /// exactly one superlayer. Moving the renderer's own between them is what makes the
        /// picture appear in whichever view touched it last instead of in both, and it is why
        /// Picture in Picture blanks the tile it borrows from.
        ///
        /// A presenter is not a second renderer. There is one subscription, one decode, one
        /// schedule and one timebase for the track however many of these exist: the renderer
        /// decodes each frame once and hands the same picture to every presenter, and they join
        /// its synchroniser so they show it at the moment it does. Which is why there is nothing
        /// on this type — no counters, no playout settings, no codec — since a presenter decides
        /// nothing. It is somewhere to put a layer.
        ///
        /// Every view therefore draws the same resolution, and that is the trade being made. The
        /// alternative is a decode per view, which buys a thumbnail the right to be a thumbnail
        /// and spends a hardware decoder slot per view to do it.
        @MainActor
        public final class Presenter {
            public let layer = AVSampleBufferDisplayLayer()

            fileprivate init() {
                layer.videoGravity = .resizeAspectFill
            }

            fileprivate func enqueue(_ sample: CMSampleBuffer) {
                let renderer = layer.sampleBufferRenderer
                if renderer.status == .failed { renderer.flush() }
                guard renderer.isReadyForMoreMediaData else { return }
                renderer.enqueue(sample)
            }

            fileprivate func flush() {
                layer.sampleBufferRenderer.flush(
                    removingDisplayedImage: true,
                    completionHandler: nil
                )
            }
        }

        /// Draw this renderer's picture in another place as well.
        ///
        /// The returned presenter's layer is the caller's to parent and lay out, exactly as
        /// ``layer`` is. It shows the current picture straight away when this renderer is
        /// already decoding once (``mirrorsInstantly``, or another presenter attached since the
        /// last keyframe); otherwise nothing is drawn into it until the next keyframe.
        public func addPresenter() -> Presenter {
            let presenter = Presenter()
            extras.append(presenter)
            synchroniser.addRenderer(presenter.layer.sampleBufferRenderer)
            if isSharing, let latest, let now = Self.immediate(latest) {
                presenter.enqueue(now)
            }
            return presenter
        }

        /// A copy of a decoded sample that displays on arrival rather than at its timestamp,
        /// which by now is in the past. The copy shares the picture.
        private static func immediate(_ sample: CMSampleBuffer) -> CMSampleBuffer? {
            var copy: CMSampleBuffer?
            guard CMSampleBufferCreateCopy(allocator: kCFAllocatorDefault, sampleBuffer: sample, sampleBufferOut: &copy) == noErr,
                  let copy,
                  let attachments = CMSampleBufferGetSampleAttachmentsArray(copy, createIfNecessary: true),
                  CFArrayGetCount(attachments) > 0
            else { return nil }
            let first = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                first,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
            return copy
        }

        /// Stop drawing into a presenter. Idempotent, and safe to call from a view teardown.
        public func remove(_ presenter: Presenter) {
            guard let index = extras.firstIndex(where: { $0 === presenter }) else { return }
            extras.remove(at: index)
            presenter.flush()
            synchroniser.removeRenderer(
                presenter.layer.sampleBufferRenderer,
                at: synchroniser.currentTime(),
                completionHandler: nil
            )
        }

        /// How many extra places this picture is being drawn. Zero for a track shown once.
        public var presenterCount: Int { extras.count }

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
        /// - Returns: The time to present at, always later than the previous frame's, or `nil` for
        ///   a frame that belongs before one already shown and is therefore not shown at all.
        private func regularise(_ presentation: CMTime, interval: Double) -> CMTime? {
            guard let start = grid else {
                grid = presentation
                slot = 0
                debt = 0
                return presentation
            }

            let offset = (presentation - start).seconds
            let natural = (offset / interval).rounded()
            var index = natural

            // How far the slot pointer has run past where the frames actually are, in whole slots.
            // One or more means the grid is waiting on frames that have not come; zero means this
            // frame wants the slot just spent; negative means it wants one *behind* that and the
            // pointer is ahead of the stream by that many slots.
            //
            // Nothing else reports this and two standing symptoms both fall out of it. Every
            // forcing below sets the pointer one beyond itself whatever the frame asked for, so the
            // gap a forcing opens is carried for the rest of the call, and a frame placed n slots
            // past the one it asked for is shown n intervals late — which is held delay that never
            // comes back. Measured: a fifth of frames arrive behind the spent slot, and the hold
            // sits at twice the depth the schedule asked for. If the pointer is running ahead those
            // are one fault and not two.
            record(lead: natural - Double(slot))

            // Two frames landing in one slot is jitter of half an interval, and the slot below is
            // already spent. Forward by one keeps the grid monotonic, which is the one property
            // the display layer cannot recover from losing.
            if index <= Double(slot) {
                // Two cases that look identical here and are not remotely alike. A frame tied with
                // the slot just used is jitter of half an interval, and moving it on by one is the
                // smoothing this function exists for. A frame whose slot is *behind* that is a
                // frame that arrived after one newer than itself, and moving it forward shows older
                // content after newer — the motion goes back and then forward, which is visible,
                // and which every counter here was blind to because the timestamps it hands out
                // were made monotonic before anything could notice.
                // Two cases that look identical here and are not remotely alike. A frame tied with
                // the slot just used is jitter of half an interval, and moving it on by one is the
                // smoothing this function exists for. A frame whose slot is *behind* that arrived
                // after one newer than itself, and moving it forward shows older content after
                // newer.
                //
                // Declining the second sort instead was tried, so that the pointer stands still
                // and the stream catches up with it by a slot. It does cure the accumulation — the
                // pointer never fell behind the stream again in either direction, where before it
                // had been walking out to fourteen slots and snapping back. It also moved the
                // phase onto a rounding boundary, and that is much worse: `natural` then alternates
                // between the slot just spent and two slots on, which is a doubled frame followed
                // by a skipped one, over and over. Measured, crowding went to 52% of frames,
                // skipped slots to 46%, and the display layer's own drops from half a percent to
                // ten. Twenty-nine frames were declined in the whole run to buy that.
                if index < Double(slot) {
                    drawing.stale += 1
                } else {
                    drawing.crowded += 1
                }
                index = Double(slot) + 1

                // Recorded, because a forcing is a slot of delay taken on and not given back.
                //
                // It is a ratchet otherwise, and it was one. The pointer ends a forcing one slot
                // beyond where the stream asked for, every later frame is forced for the same
                // reason whatever the link then does, and each is placed one interval later than
                // its own timestamp wanted — so a single half-interval of jitter, once, in the
                // first second of a call, is sixteen and a half milliseconds held for the rest of
                // it. Measured on three legs of four: ninety-nine percent of frames counted
                // crowded and a lead pinned at zero, which is not ninety-nine percent of frames
                // arriving badly. It is one, and then the consequence.
                debt = min(debt + 1, Self.mostDebtWorthReclaiming)
            } else {
                // An empty slot, and the one place the delay a forcing took on can be handed back.
                //
                // The two are the same quantity with opposite signs. A forcing holds a frame an
                // interval longer than its timestamp asked for; a gap is an interval in which no
                // frame was going to be shown at all. Spend one against the other and the picture
                // keeps the publisher's rate exactly — nothing is sped up on balance, because the
                // slowing being undone is this function's own and not the source's.
                //
                // Which is what makes it safe against the rule above it: closing a gap that is
                // there because a frame is genuinely missing would hide the loss by running the
                // video fast. Closing one only as far as the debt allows cannot, because the debt
                // is a count of intervals this already added.
                //
                // It is strictly the better moment for it, too. The alternative way to give a slot
                // back is to decline a frame, which costs a frame and was measured doing far more
                // harm than the delay it recovered. A gap costs nothing: the motion was going to
                // stop for that interval regardless, and this fills it instead.
                let empty = Int(index) - Int(slot) - 1
                let reclaimed = min(debt, empty)
                if reclaimed > 0 {
                    index -= Double(reclaimed)
                    debt -= reclaimed
                    drawing.reclaimedSlots += reclaimed
                }
                drawing.gapped += empty - reclaimed
            }

            // Beyond this the source is not jittering, it has moved: a publisher that reconnected,
            // a stall long enough to break the run, a swapped source. Slewing toward that would
            // take minutes and show a lurch every frame of it.
            //
            // Measured against the slot the frame was *placed* at, which during a run of forcings
            // is how far the pointer has been pushed past the stream. That is the condition this
            // needs to catch as well as a source that jumped: both leave the grid describing
            // something the frames are no longer on, and both recover the same way.
            let displaced = offset - index * interval
            guard abs(displaced) < 0.25 else {
                grid = presentation
                slot = 0
                debt = 0
                latched = nil
                gaps = []
                gapCursor = 0
                slewed = 0
                slews = 0
                drawing.regrids += 1
                return presentation
            }

            slot = Int64(index)

            // Against the slot the frame *asked for*, never the one it may have just been moved
            // to. This is a phase-locked loop and this term is its only reading of phase, so it
            // has to be a property of the stream rather than of what this function did a few lines
            // ago. Bounded by construction at half an interval, because the natural slot is the
            // nearest one.
            //
            // Feeding it the forced slot instead is a loop that runs away, and it was running.
            // During a run of forcings that figure is not a phase error at all, it is the whole
            // accumulated displacement — measured, up to a hundred and sixty-seven milliseconds —
            // which saturates the slew negative. With a quarter of frames on that path the average
            // goes negative too, ``correctRate(after:)`` folds it into the latched interval and
            // shortens it, a shorter interval pushes the grid's slots past the frames faster, more
            // frames are forced, and each one shortens the interval again. Two phones sat in it
            // for whole calls, laying a grid of 16.634ms against a source arriving every 16.670,
            // which is the wrong direction from a loop whose entire job is to close that gap.
            //
            // What it cost is worth recording, because none of the counters this class publishes
            // named it: the pointer walked up to fourteen slots past the stream, so a quarter of
            // an hour into a call the typical frame was being shown ten slots — a sixth of a
            // second — after the moment it was captured for, and then snapped back when the
            // displacement finally tripped the regrid above. Build, snap, build again.
            let error = offset - natural * interval
            record(phase: abs(error))

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
        ///
        /// Except that it is not, quite, and the part it misses is the one that shows. A slew is
        /// driven by the phase error, and the phase error is the offset less the *nearest* whole
        /// number of slots — so it can never exceed half a slot, whatever the frequency error
        /// underneath it is doing. Let the grid run a fraction of a percent long and the offset
        /// falls behind a slot at a time; each time it falls a whole one, the nearest slot changes
        /// with it and the phase error drops back to nothing. The rounding hands the loop a
        /// perfectly locked phase while the grid walks away from the stream underneath it.
        ///
        /// Which it did, in both directions, on the same pair of phones within a quarter of an
        /// hour: sixty-six parts per million long on one run and a hundred and sixty short on the
        /// next, with the placement faults following the sign — frames landing behind the slot
        /// pointer when the grid ran long, empty slots when it ran short, and neither visible to
        /// a loop reading a phase error that had been folded back to zero.
        ///
        /// So the arrival median is read as well, which is the same frequency error with nothing
        /// rounded out of it — and the two are combined into the one figure the grid is actually
        /// solving for rather than added as two independent corrections.
        ///
        /// That figure follows from what a stable pointer means. `natural` has to advance exactly
        /// one slot per frame, or the grid walks away from the stream a slot at a time; it advances
        /// by `(arriving - slew) / interval`; so the interval that holds it still is `arriving -
        /// slew`, with the slew *subtracted* from the arrival rate. This had been adding it, and
        /// two terms that pull against each other whenever there is anything to correct is an
        /// oscillator — measured, the latched interval swung a thousand to two and a half thousand
        /// parts per million either side of the source between consecutive readings.
        ///
        /// Tracking the target rather than dropping the slew, because the slew is load-bearing for
        /// something else. Pinning the interval to the bare arrival rate does lock the grid — a
        /// hundred and twenty parts per million against nine hundred, and not one stale frame in
        /// four legs — but it also takes away the only place a persistent grid creep could be
        /// absorbed, and the timebase trim inherits the whole of it. That was measured too: trim
        /// ramping to fifteen hundred parts per million and being reset by a re-anchor, thirty to
        /// sixty re-anchors a leg against seven, and a p95 out at two hundred milliseconds. The
        /// interval has to keep that job, and this is the target that lets it keep it without
        /// fighting the phase.
        ///
        /// A quarter of the distance at a time because the arrival figure is a median over a
        /// rolling window and worth leaning on rather than trusting.
        private static let believeOfEachArrivalMeasurement = 0.25

        private func correctRate(after slew: Double) {
            slewed += slew
            slews += 1
            guard slews >= 240, var interval = latched else { return }

            // Ignored when it disagrees by more than the gap between adjacent frame rates worth
            // latching, because at that size it is not a grid a shade off the stream, it is the
            // wrong rate latched — and creeping a quarter at a time towards the wrong rate is a
            // slower way to arrive somewhere this should not go at all.
            // The bare arrival rate, with the slew left out of it. The slew belongs in the target
            // on the arithmetic — a pointer holds still when the interval is `arriving - slew` —
            // but it was measured in and it is worse in every column that matters: the grid came
            // out further from the source than leaving it out entirely (sixteen hundred parts per
            // million against a hundred and twenty), stale frames came back, and the re-anchors
            // and the p95 came with them. It is an average of a quantity that saturates, over a
            // window in which the thing it is correcting has already changed, and it carries more
            // noise than the term it is refining.
            let measured = drawing.arriving
            let target = measured > 0 && abs(measured - interval) / interval < 0.02
                ? measured
                : interval

            // Bounded at a fifth of a percent, which is far more than two crystals disagree by
            // and far less than the distance between any two frame rates worth latching. A larger
            // correction would mean the interval is not slightly wrong, it is the wrong rate, and
            // the answer to that is to measure again rather than to creep towards it.
            let wanted = (target - interval) * Self.believeOfEachArrivalMeasurement
            let correction = min(max(wanted, -interval / 500), interval / 500)
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

            // Kept measured past the latch, because the latched figure is corrected towards this
            // by ``correctRate(after:)`` and nothing else in here can see a frequency error — the
            // phase the slew reads has the whole slots rounded out of it. Slowly and by a fraction
            // at a time rather than by assignment, which is what the note above rules out: a
            // median that wanders half a percent as the window rolls would move a frame a whole
            // slot if the grid followed it directly.
            let sorted = gaps.sorted()
            if !sorted.isEmpty { drawing.arriving = sorted[sorted.count / 2] }

            if let latched {
                drawing.laid = latched
                return latched
            }

            guard gaps.count >= 24 else { return nil }
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
            // Sixty samples, which is two seconds, and this figure only ever describes a cold
            // start: the window never shrinks once filled, so from the first fill onwards the
            // count is far above any threshold this could name. It was three hundred, and three
            // hundred frames is ten seconds of running at whatever the floor happens to be
            // before the delay is allowed to be anything else.
            //
            // Measured from a cold start on two phones, that floor was zero — the application
            // asks for none and the audio floor is zero until a voice has arrived — so the
            // schedule spent ten seconds with frames missing their deadlines, drew its evidence
            // entirely from a depth nobody would choose, then leapt to its ceiling in one step
            // and spent forty seconds handing it back at the full rate cap.
            //
            // Two seconds is a noisier quantile and a much better answer, because the alternative
            // is not a quieter answer, it is the floor.
            guard slack.count >= 60, let worst = slackQuantile(playoutTolerance) else { return }
            playoutSlack = worst
            playoutHold = heldMedian()

            let depth = playoutDepth.asSeconds
            let floor = max(bounds.floor, playoutFloor).asSeconds

            // The ceiling gives way to the floor rather than the floor being flattened onto it.
            //
            // Lip sync raises the floor while a call runs, and the floor it asks for is not a
            // preference: below it the voice is ahead of the mouth. The ceiling is a preference —
            // it is the latency this would rather not exceed. Clamping the floor down to meet it,
            // which is what happened here and in ``LipSync/floor(voice:bounds:)``, does not
            // enforce the ceiling; it leaves the two equal, and a controller whose floor and
            // ceiling are the same number has no move it is allowed to make. Every path in
            // ``PlayoutDelay`` then reduces to holding still, while the thing that wanted a change
            // goes on wanting one.
            //
            // Seen twice, and only ever with the voice buffer grown: the audio target at seventy
            // milliseconds against twenty in the runs either side of it, the floor pinned exactly
            // on the ceiling, and a picture that a person watching called jittery while the
            // schedule's own figures looked settled. Runs where the voice sat at twenty never
            // reproduced it, which is why an A/B that did not grow the buffer cleared a change
            // that was not at fault.
            //
            // A slot of room, because that is the smallest move the grid can make and therefore
            // the least that makes the difference between a controller and a constant.
            let display = PlayoutDelay.margin(refresh: displayRefresh)
            let ceiling = PlayoutDelay.ceiling(
                asked: bounds.ceiling.asSeconds,
                floor: floor,
                interval: interval,
                display: display
            )

            // What a person waits is the hold, and the hold can sit well above the delay that was
            // asked for. The schedule is anchored on one frame's arrival, so whatever headroom
            // that frame happened to carry is paid by every frame after it, and none of the paths
            // below can see it: they reason about the request, and ``track(depth:wanted:)`` closes
            // the difference at half a millisecond per frame.
            //
            // A ceiling that governs only the request is not a promise about latency. Measured on
            // two phones with the ceiling at fifty milliseconds, one leg held sixty-eight at the
            // median and a hundred and fifty-eight at worst, and broke ninety glass-to-glass on
            // ninety of a hundred and thirty-nine samples while every figure it published about
            // itself was inside its bounds.
            //
            // Which is now ``ScheduleTracking``'s to close, and only its own, because two loops
            // draining one buffer is one loop too many.
            //
            // This existed because the grid could not be driven — see ``shift(by:to:)`` for why
            // every correction it made was undone — so the hold could sit at twice its ceiling
            // with nothing able to reach it. Giving the shift the clock instead fixed that, and in
            // fixing it made this the second controller pulling on a buffer the tracking loop was
            // already regulating. Both drain, neither can see the other, and the buffer goes to
            // nothing between them: measured with the grid locked to the source, the trim ramped
            // to three thousand parts per million, the schedule starved, and the re-anchor that
            // refilled it arrived thirty to sixty times a leg against seven, taking the p95 from
            // seventy milliseconds to two hundred and fifty.
            //
            // So the excess is left to ``track(depth:wanted:)``, which is the loop that owns the
            // depth, and which closes it at half a millisecond per frame without a step.
            if let hold = playoutHold, hold > ceiling + PlayoutDelay.deadband {
                drawing.handbacks += 1
            }

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
                mayTighten: ContinuousClock.now - tightened > .milliseconds(250),
                display: display
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

        /// Remember how long the schedule is currently making frames wait.
        private func record(held seconds: Double) {
            if held.count < Self.heldWindow {
                held.append(seconds)
            } else {
                held[heldCursor] = seconds
                heldCursor = (heldCursor + 1) % Self.heldWindow
            }
        }

        /// The wait the middle frame of the recent window had.
        private func heldMedian() -> Double? {
            guard !held.isEmpty else { return nil }
            let sorted = held.sorted()
            return max(0, sorted[(sorted.count - 1) / 2])
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

        /// Remember how far a frame was from the slot it was placed in.
        private func record(phase seconds: Double) {
            if phases.count < Self.gapWindow {
                phases.append(seconds)
            } else {
                phases[phaseCursor] = seconds
                phaseCursor = (phaseCursor + 1) % Self.gapWindow
            }

            let sorted = phases.sorted()
            drawing.phase = sorted[sorted.count / 2]
            drawing.worstPhase = sorted[min(sorted.count - 1, sorted.count * 95 / 100)]
        }

        private var phases: [Double] = []
        private var phaseCursor = 0

        /// Track where frames are asking to go relative to the slot pointer.
        private func record(lead: Double) {
            if leads.count < Self.gapWindow {
                leads.append(lead)
            } else {
                leads[leadCursor] = lead
                leadCursor = (leadCursor + 1) % Self.gapWindow
            }

            let sorted = leads.sorted()
            drawing.lead = sorted[sorted.count / 2]
            drawing.worstLead = sorted[0]
        }

        private var leads: [Double] = []
        private var leadCursor = 0

        /// Move the grid, and with it every frame not yet due.
        /// Moves the clock rather than the grid, which are not interchangeable however alike they
        /// look from here.
        ///
        /// The grid's position is not this function's to set. It is owned by the slew, which holds
        /// it against the arriving timestamps and nulls any phase error it finds — including one
        /// this puts there. Move the grid by less than a slot and the slew reads the difference as
        /// error and walks it back over the next thirty frames; move it by a whole slot and every
        /// frame's index drops by one and cancels it outright. There is no third case: a grid move
        /// is either undone or void, and the delay it was asked to carry comes back either way.
        ///
        /// Which is what six hundred hand-backs across two phones did. The correction fired twice a
        /// second for the length of every call, the counter climbed exactly as designed, and the
        /// hold it exists to bring to twenty milliseconds sat at thirty-nine for the duration. The
        /// grid it moved was returned to where the slew wanted it, every time, before the next.
        ///
        /// The clock has no such owner. Nothing measures the timebase against the stream, so
        /// advancing it by an amount shows every queued frame that much sooner and it stays shown
        /// that much sooner. The sign is the one this reads oddly at: a schedule is delayed by
        /// putting the clock *behind* it, so a shift later moves the clock earlier.
        private func shift(by seconds: Double, to depth: Duration) {
            guard grid != nil else { return }
            synchroniser.setRate(
                synchroniser.rate,
                time: synchroniser.currentTime()
                    - CMTime(seconds: seconds, preferredTimescale: 90000)
            )
            playoutDepth = depth

            // Every remembered arrival is re-read against the clock it would now be measured
            // against, because moving the clock changes what all of them meant — a headroom is a
            // frame's time less the clock's, so a clock moved back by an amount is every headroom
            // larger by it. Without this the
            // window holds ten seconds of headroom recorded before the last adjustment, each
            // adjustment is decided on evidence that predates the previous one, and the loop
            // tightens far past the point where the headroom was gone — measured, it walked a
            // hundred milliseconds too early, ran out of frames, re-anchored a hundred and
            // thirty times and ended pinned against the ceiling. The correction is exact rather
            // than approximate: the grid moved by one amount, so every slack against it moved by
            // that same amount.
            for index in slack.indices { slack[index] += seconds }
            playoutSlack = playoutSlack.map { $0 + seconds }

            // And the holds, for the same reason and one more. The hold window is three hundred
            // frames, so its median describes the middle of the last five seconds; the correction
            // above runs four times a second. Left undisplaced, ten corrections land before the
            // measurement that asks for them registers the first, and each of the ten reads the
            // same stale excess and asks again — eighty milliseconds handed back to cure twenty.
            //
            // Which is what two of four legs did: a hold driven clean through its ceiling to zero,
            // no buffer left to absorb anything, and a third of the frames then arriving behind
            // the slot they were meant for. Displacing the window closes the loop on the same
            // frame it acts, and the second correction sees the first.
            for index in held.indices { held[index] += seconds }
        }

        /// Put the presented timeline where the arriving frames are.
        ///
        /// Called on the first frame and whenever the schedule has drifted out of reach of what
        /// is arriving. Drift is not optional to handle: the timestamps come from the publisher's
        /// clock and the schedule runs on this device's, so the two diverge at whatever rate the
        /// two crystals disagree — and a viewer that never re-anchors either accumulates delay
        /// for the whole call or slowly runs ahead of the stream and shows every frame late.
        private func anchorSchedule(to presentation: CMTime, delay: Duration) {
            var delay = delay

            // A give-back caught in flight by a re-anchor. Abandoning it — which is what
            // dropping ``catchUp`` below amounts to on its own — is the more expensive of the
            // two ways to be wrong: the clock has already handed back part of the delay while
            // ``playoutDepth`` still names the figure before it, and the grid placed just below
            // is placed by that figure. The delay comes straight back, in full, at the very
            // moment the schedule had a free hand to be rid of it.
            //
            // Settled at the landing the controller chose instead. A re-anchor places the grid
            // wherever it is told, so there is no cost to telling it the right thing.
            if catchUp != nil {
                playoutDepth = .seconds(catchUpLanding)
                catchUpGive = 0
                catchUpLanding = 0
                if playoutBounds != nil { delay = playoutDepth }
            }

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
                //
                // Bounded above, because that reasoning holds for a shift and only approximately
                // here. A shift moves one grid by one amount, so every sample measured against it
                // moves by that amount exactly. A re-anchor that follows a drift is not one move:
                // the grid was sliding while those samples were being taken, so displacing all of
                // them by the final, worst displacement overstates every one of them.
                //
                // Measured on two phones, a re-anchor arriving after the schedule had fallen a few
                // hundred milliseconds behind put that whole distance onto six hundred samples at
                // once. The median hold — which is the figure a glass-to-glass reading is built
                // from — then read between three hundred and nine hundred milliseconds for the
                // twenty seconds the window took to turn over, while the delay in force was
                // twenty-nine milliseconds, the newest frame sat fifty milliseconds ahead and
                // nothing was ever held for anything like that long. Between re-anchors the same
                // figure tracked the delay to within a few milliseconds, which is what said the
                // spikes were the correction rather than the link.
                //
                // The ceiling is what the new grid can actually produce: frames are placed `delay`
                // ahead, and anchoring on one frame's arrival can add about its own interval on
                // top of that. Anything past it did not happen to a frame.
                if newest.isValid {
                    let was = (newest - synchroniser.currentTime()).seconds
                    let moved = seconds - was
                    let most = seconds + (latched ?? 1.0 / 30)
                    for index in slack.indices { slack[index] = min(slack[index] + moved, most) }
                    playoutSlack = playoutSlack.map { min($0 + moved, most) }
                }
            }

            anchor = start
            catchUp = nil

            // Carried across, because the two crystals disagree by the same amount either side
            // of a re-anchor. Dropping to a flat rate here would make every re-anchor a fresh
            // start for the tracking loop, and the loop's whole value is that it does not have
            // to be relearned.
            synchroniser.setRate(Float(1 + tracking.resuming()), time: start)
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

            // Recorded before any of the corrections below, and against the grid that produced it,
            // which is the whole point of keeping this separately from the slack window.
            record(held: depth)

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

            // How long the schedule has been running past its frames, which is the difference
            // between a late frame and a lost stream. Only the second is worth a step.
            if depth < -allowance {
                strayed = strayed ?? ContinuousClock.now
            } else {
                strayed = nil
            }

            // Far enough out in either direction that the schedule has lost the stream rather
            // than drifted within it, and a re-anchor is the only thing that recovers it. The
            // undershoot side is a question about persistence rather than a threshold, because
            // the rate can recover a momentary one and does it without a lurch.
            let outran = PlayoutDelay.needsAnchoring(
                depth: depth,
                allowance: allowance,
                straying: strayed.map { (ContinuousClock.now - $0).asSeconds }
            )
            if outran || depth > seconds + 0.15 {
                // Which side it failed on is the one thing worth telling the rate loop, because
                // the two say opposite things about it. Overshooting is a queue that grew, and
                // the rate is what will drain it. Running out is the rate having already drained
                // more than there was, and carrying that correction across unchanged is how a
                // loop arranges its own next re-anchor.
                if outran { tracking.outran() }
                anchorSchedule(to: newest, delay: delay)
                strayed = nil
                return
            }

            // Correcting an excess here, from the schedule's own position, was tried and is a
            // mistake worth leaving a note about. The excess is real — the schedule is anchored
            // on one frame's arrival, so that frame's headroom is paid by every frame after it,
            // and ``track(depth:wanted:)`` closes it at half a millisecond per frame — but a
            // shift is the wrong instrument for it from in here.
            //
            // Two reasons, both measured. ``shift(by:to:)`` displaces every remembered slack
            // sample, which is right when it happens once a second from ``resize(interval:)`` and
            // ruinous at thirty times a second: the window is driven down faster than arrivals
            // refill it, and both phones ended up reporting eight seconds of negative headroom.
            // And it steers on schedule position while ``PlayoutDelay`` steers on headroom, so
            // the two pull against each other with no arbiter.
            //
            // Whatever bounds this belongs inside the controller, which already has a ceiling and
            // already owns the grid.

            // Inside the bounds, which is where this belongs: re-anchoring is what happens when
            // the schedule has already lost the stream, and tracking is what keeps it from
            // getting there. Before this existed the first was the only mechanism, so the
            // ordinary state of a call was a slow slide into a lurch.
            track(depth: depth, wanted: seconds)
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

            // A frame that has already missed the playhead means the schedule is running
            // somewhere the stream is not. Move the schedule to meet it rather than throw it
            // away: cleared of its anchor, this frame falls through to the enqueue below, finds
            // nothing to be measured against, and re-anchors the timeline on itself the usual
            // delay ahead. The picture keeps moving and the whole cost is the lateness, paid
            // once, as latency the give-back is already there to reclaim.
            //
            // The frames behind it in the same burst are the reason this is worth doing. Against
            // the old timebase they are all late together and each one trips this again; against
            // the moved one they are an ordinary run of frames at an ordinary spacing.
            if requestedDelay != nil, anchor != nil, source.isValid {
                let playhead = synchroniser.currentTime()
                if playhead.isValid {
                    let lateBy = (playhead - source).seconds
                    let interval = interval(after: source) ?? (1.0 / 30)
                    if PlayoutDelay.hasMissed(by: lateBy, interval: interval) {
                        drawing.rebases += 1
                        rebase()
                    }
                }
            }

            // Regridded only when something is scheduling presentation. With no schedule the
            // frames are shown on arrival whatever their timestamps say, and rewriting a timestamp
            // nothing reads would cost a copy per frame to no effect.
            var drawn = sample
            var presentation = source
            var cadence: Double?
            if let delay = requestedDelay, source.isValid, let interval = interval(after: source) {
                // Declined rather than placed. Returning here rather than falling through to the
                // enqueue below, which would hand the layer an unscheduled frame carrying its own
                // source timestamp — behind the one already shown, which is the thing being
                // avoided.
                guard let even = regularise(source, interval: interval) else { return }
                if let retimed = retime(drawn, to: even, duration: interval) {
                    drawn = retimed
                    presentation = even
                    cadence = interval
                }
            }

            guard draw(drawn, isKeyFrame: frame.isKeyFrame) else { return }
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

            // A frame that arrived after a delivery pause is late because of the pause, and
            // sizing the delay from it buys a quarter second of permanent latency to cover six
            // frames that were already late. See ``ArrivalEvidence``.
            let now = ContinuousClock.now
            let gap = arrived.map { (now - $0).asSeconds } ?? cadence
            arrived = now
            drawing.pauses = evidence.pauses
            drawing.dismissed = evidence.dismissed

            // Only the recording is skipped, not the decision. A dismissed arrival is one fewer
            // piece of evidence, not a reason to stop acting on the evidence already held.
            if evidence.admits(gap: gap, interval: cadence) {
                record(slack: (presentation - synchroniser.currentTime()).seconds)
            }
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

            // Back to letting the display layer decode for itself, and the presenters wait for
            // the next keyframe like they did when they were first attached. The shared session
            // has just lost the references it was working from, and a primary still routed
            // through it would draw nothing until a keyframe nothing here can promise is coming —
            // whereas the layer's own decoder recovers on whatever arrives.
            for presenter in extras { presenter.flush() }
            sharedDecoder = nil
            sharedFormat = nil
            isSharing = false
            latest = nil

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
            debt = 0
            previousStamp = .invalid
        }

        /// Let go of the schedule, so the next frame can put it where the stream actually is.
        ///
        /// Everything cleared here describes where the presented timeline sits, and all of it is
        /// about to be wrong: the frame that prompted this is behind the playhead, so the anchor
        /// it would be placed against, the grid built on that anchor and the newest timestamps
        /// measured against it all belong to a timeline the stream has moved on from.
        ///
        /// What is deliberately *not* here is a flush, and that absence is the point. The decoded
        /// pictures the layer is holding are the reference frames every delta frame after this
        /// one needs. Discarding them is what used to make an independently decodable frame the
        /// only way back, and so what turned one late frame into a keyframe interval of nothing.
        /// Nothing queued is lost by moving the timebase: those frames are ahead of this one, and
        /// a timeline moved back makes them later rather than sooner.
        private func rebase() {
            anchor = nil
            newest = .invalid
            newestSource = .invalid
            grid = nil
            slot = 0
            debt = 0
        }

        /// Hand one frame to the display layer, and to every extra presenter.
        ///
        /// Returns whether it was drawn, because the schedule that follows this in ``enqueue(_:)``
        /// is about frames that reached the screen and a frame that did not is not evidence about
        /// timing.
        ///
        /// With no presenters this is the one line it replaced. Everything below only runs for a
        /// host who is on screen more than once.
        private func draw(_ sample: CMSampleBuffer, isKeyFrame: Bool) -> Bool {
            let renderer = layer.sampleBufferRenderer
            let wanted = !extras.isEmpty || mirrorsInstantly

            // At a keyframe and nowhere else, because both halves of the switch need one. A
            // decompression session that has not seen an IDR has no references to build a
            // picture from, and a display layer accepts a new format description — compressed
            // one frame, raw the next — at a keyframe rather than between two. So a view opened
            // mid-group changes nothing until the next keyframe comes round: the picture already
            // on screen carries on decoding itself and the new view waits, which is the right
            // way round, since the wait belongs to the person who just opened a second view and
            // not to the one already watching.
            if isSharing != wanted, isKeyFrame { changeOver(to: wanted) }

            guard isSharing, let decoder = sharedDecoder else {
                renderer.enqueue(sample)
                return true
            }

            guard let picture = try? decoder.decode(sample),
                  let raw = raw(picture, timedLike: sample)
            else {
                drawing.undecodable += 1
                return false
            }

            // The same sample buffer to all of them. It is a reference to one IOSurface, so this
            // is a retain per view and not a copy per view, and handing an already-decoded
            // picture to a display layer does not start a decode — which is the whole reason
            // one host in three places costs one decoder slot instead of three.
            renderer.enqueue(raw)
            for presenter in extras { presenter.enqueue(raw) }
            latest = raw
            return true
        }

        /// Move between decoding once for every view and letting the display layer decode alone.
        private func changeOver(to sharing: Bool) {
            // What is queued was built the other way round. It is a few frames — tens of
            // milliseconds of playout — and a keyframe is arriving to replace them, so dropping
            // them is cheaper than discovering in the field how a display layer feels about
            // compressed samples queued behind an uncompressed one. The displayed image stays,
            // so nothing blanks in the meantime.
            layer.sampleBufferRenderer.flush(removingDisplayedImage: false, completionHandler: nil)
            sharedDecoder = sharing ? VideoDecodeSession() : nil
            sharedFormat = nil
            isSharing = sharing
            latest = nil
            drawing.changeovers += 1
        }

        /// Wrap a decoded picture so it presents at the moment the frame it came from would have.
        ///
        /// Timed from the sample rather than from the frame, because by here the sample may have
        /// been retimed onto the even grid and the grid is what the schedule is holding.
        private func raw(
            _ picture: CVImageBuffer,
            timedLike sample: CMSampleBuffer
        ) -> CMSampleBuffer? {
            if
                let held = sharedFormat,
                !CMVideoFormatDescriptionMatchesImageBuffer(held, imageBuffer: picture)
            {
                sharedFormat = nil
            }

            if sharedFormat == nil {
                var made: CMFormatDescription?
                guard
                    CMVideoFormatDescriptionCreateForImageBuffer(
                        allocator: kCFAllocatorDefault,
                        imageBuffer: picture,
                        formatDescriptionOut: &made
                    ) == noErr
                else { return nil }
                sharedFormat = made
            }
            guard let format = sharedFormat else { return nil }

            var timing = CMSampleTimingInfo(
                duration: sample.duration,
                presentationTimeStamp: sample.presentationTimeStamp,
                decodeTimeStamp: .invalid
            )
            var made: CMSampleBuffer?
            guard
                CMSampleBufferCreateReadyWithImageBuffer(
                    allocator: kCFAllocatorDefault,
                    imageBuffer: picture,
                    formatDescription: format,
                    sampleTiming: &timing,
                    sampleBufferOut: &made
                ) == noErr
            else { return nil }
            return made
        }
    }

    extension Duration {
        /// Seconds as a `Double`, which is what CoreMedia and the arithmetic here both want.
        fileprivate var asSeconds: Double {
            Double(components.seconds) + Double(components.attoseconds) / 1e18
        }
    }
#endif
