// Camera capture.
//
// Deliberately the smaller of the two capture paths in this package. A camera
// is one thing that can fill a ``FrameSource`` and the SDK gains nothing by
// wrapping more of `AVCaptureSession` than it needs — an app that wants
// multi-cam, a specific format, or a depth stream should own the session and
// push into a ``FrameRelay``, which is the same interface this uses.
//
// The one thing worth centralising is the output format. `AVCaptureSession`
// defaults to a format that is not what the encoder wants, and the resulting
// per-frame conversion is invisible until someone profiles it.

import Foundation
import MoqomCore

#if canImport(AVFoundation) && (os(iOS) || os(macOS))
    import AVFoundation
    import CoreVideo
    import VideoToolbox

    #if os(iOS)
        import CoreMotion
    #endif

    /// Which camera to open.
    public enum CameraPosition: Hashable, Sendable {
        case front
        case back

        /// Whatever the system considers default, which on a Mac is the only one.
        case system

        /// The other one, for a flip control that does not need to ask which
        /// camera is open. `.system` has no opposite and stays put.
        public var flipped: CameraPosition {
            switch self {
            case .front: .back
            case .back: .front
            case .system: .system
            }
        }

        /// Whether a preview of this camera should be drawn mirrored.
        ///
        /// The front camera, and only the front camera. See
        /// ``CameraSource/publishesMirrored`` for why this is a question about
        /// the preview rather than about the video.
        public var wantsMirroredPreview: Bool { self == .front }
    }

    /// Frames from a capture device.
    ///
    /// > Important: Compiles on iOS and macOS; not exercised by the test suite,
    /// > which has no camera and no authorisation prompt to answer.
    public final class CameraSource: NSObject, FrameSource, @unchecked Sendable {
        public let captureFormat: CaptureFormat
        private let logger: MoqomLogger

        private let box = CaptureSessionBox()
        private let output = AVCaptureVideoDataOutput()
        private let queue = DispatchQueue(label: "moqom.camera", qos: .userInteractive)
        private let relay: FrameRelay

        /// The fallback rotation, its pool, and the shape it was built for. Only ever touched
        /// from the capture queue, which is where frames are delivered. See ``upright(_:)``.
        private var rotation90: VTPixelRotationSession?
        private var rotationPool: CVPixelBufferPool?
        private var rotationSource: PixelSize?
        private var rotationMirrors = false

        /// Whether the last frame was turned here rather than by the connection.
        ///
        /// Reported because the two paths are indistinguishable downstream and were not
        /// equivalent: they turned opposite ways, and the only evidence was one of two phones
        /// being upside down. Written on the capture queue, read for diagnostics.
        public private(set) var softwareTurns = false

        /// Guards ``position`` and ``publishesMirrored``, which are read from
        /// whatever thread the interface runs on and written from there too,
        /// while the capture queue reads them to configure the session.
        private let lock = NSLock()
        private var current: CameraPosition
        private var mirrored = false
        private var rotation: Double = 0
        private var input: AVCaptureDeviceInput
        private var steadying = Stabilisation.whenMoving
        private var moving = false

        /// When to spend power on holding the picture steady.
        ///
        /// Stabilisation is not free and is not always worth anything. It buffers frames so it
        /// can compare them, which is latency in a live call, and it warps every one of them,
        /// which is work on a device already encoding sixty a second. Against that it fixes the
        /// one thing nothing downstream can: a shaking camera, which also happens to be the
        /// worst case for the encoder, because a picture where every pixel moved is a picture
        /// with no redundancy left to compress.
        ///
        /// So the useful setting is neither on nor off but *when*, and the question is about the
        /// camera rather than the scene: a phone propped on a desk gains nothing from
        /// stabilisation however much the person in front of it moves, and a phone in a walking
        /// hand needs it whatever it is pointed at. The device's own gyroscope answers exactly
        /// that question, and costs almost nothing to ask.
        public enum Stabilisation: Hashable, Sendable {
            /// Never. Lowest latency and lowest power, right for a fixed camera.
            case off

            /// While the device is being moved, and for a few seconds after it stops.
            case whenMoving

            /// Always, which is what `AVFoundation` does when asked for `.auto`.
            case always
        }

        /// When the picture should be held steady. Motion-driven by default.
        public var stabilisation: Stabilisation {
            get { lock.withLock { steadying } }
            set {
                lock.withLock { steadying = newValue }
                queue.async { [weak self] in self?.applyStabilisation() }
                #if os(iOS)
                    if newValue == .whenMoving { watchMotion() } else { motion.stop() }
                #endif
            }
        }

        /// Whether the device is currently being moved about, by either measure below.
        public var isMoving: Bool { lock.withLock { moving } }

        /// The turn the capture connection is actually applying, which is not always the one
        /// that was asked for. See ``applyRotation``.
        public var appliedRotationDegrees: Double {
            output.connection(with: .video).map { Double($0.videoRotationAngle) } ?? 0
        }

        #if os(iOS)
            /// Whether the person holding the device is walking, running, or riding something.
            ///
            /// Distinct from ``isMoving``, which a hand gesture at a desk also sets. Always
            /// false without motion permission, where ``isMoving`` still works — so the two
            /// together are also how an application can tell whether the permission took.
            public var isWalking: Bool { motion.isStriding }

            private let motion = MotionWatch()
        #endif

        /// Which camera is open.
        public var position: CameraPosition { lock.withLock { current } }

        /// Whether the *published* video is mirrored. Off, and it should
        /// usually stay off.
        ///
        /// Mirroring is two separate questions that share a word, and
        /// conflating them is the common bug. The preview of your own front
        /// camera should be mirrored, because a preview that is not behaves
        /// like no mirror anyone has used — raise your left hand and the image
        /// raises its right. What everyone *else* sees should not be, because
        /// their copy is the real scene: mirror it and every letter on a
        /// T-shirt, whiteboard, or held-up sign is backwards, and the person on
        /// camera is the one who cannot tell.
        ///
        /// So the default mirrors the preview and publishes the truth. The
        /// preview half costs nothing and is not done here at all — see
        /// ``VideoRenderer/isMirrored``, which flips a layer rather than any
        /// pixels. This property is the other half, for the applications that
        /// genuinely want the mirrored image on the wire, and it is done by the
        /// capture connection so that it also costs nothing.
        public var publishesMirrored: Bool {
            get { lock.withLock { mirrored } }
            set {
                lock.withLock { mirrored = newValue }
                queue.async { [weak self] in self?.applyMirroring() }
            }
        }

        /// How far to rotate the delivered frames, in degrees counter-clockwise.
        ///
        /// A phone held upright still captures landscape: the sensor's long axis is
        /// across the device, so a portrait publication needs a quarter turn. Doing it
        /// here, at the connection, is the only place it is free — the capture pipeline
        /// applies it before the buffer is ever handed over, whereas rotating afterwards
        /// means touching every pixel of every frame on the CPU.
        ///
        /// Note this changes the size of the delivered frames, swapping width and height
        /// for an odd multiple of 90. It does not change ``captureFormat``, which is what
        /// the source was *asked* for.
        public var rotationDegrees: Double {
            get { lock.withLock { rotation } }
            set {
                lock.withLock { rotation = newValue }
                queue.async { [weak self] in self?.applyRotation() }
            }
        }

        /// - Parameter logger: Where a capture format that cannot be honoured is reported.
        ///   Worth passing: a device that will not give the requested frame rate keeps
        ///   delivering at its own, and the difference is invisible until somebody counts.
        public init(
            format: CaptureFormat,
            position: CameraPosition = .front,
            logger: MoqomLogger = .silent
        ) throws {
            captureFormat = format
            relay = FrameRelay(format: format)
            current = position
            self.logger = logger

            guard let device = Self.device(for: position) else {
                throw MoqomError.platform(api: "AVCaptureDevice.default", status: -1)
            }
            input = try AVCaptureDeviceInput(device: device)

            // A portrait format is a request for a quarter turn, because no camera has a
            // portrait sensor mode. Every format a device offers is landscape, and a phone
            // held upright is a landscape sensor with the picture on its side — which is why
            // asking for 720×1280 without this found no format at all on the way up the list
            // and then settled on a 4K one, whose height is the first that clears 1280.
            //
            // Inferred rather than asked for. A caller that wants portrait frames has said so
            // by the shape of the format, and a second parameter agreeing with it would only
            // be a way to disagree.
            rotation = format.size.height > format.size.width ? 90 : 0

            super.init()

            let session = box.session
            session.beginConfiguration()

            guard session.canAddInput(input), session.canAddOutput(output) else {
                session.commitConfiguration()
                throw MoqomError.platform(api: "AVCaptureSession.canAdd", status: -1)
            }
            session.addInput(input)

            // Biplanar video-range YUV, because it is what the hardware encoder
            // consumes. Leaving the default in place inserts a colour
            // conversion on every frame that never reports itself.
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            ]

            // A capture queue that backs up is a capture queue holding buffers
            // the device needs back; dropping is what keeps the pool alive.
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            session.addOutput(output)

            // The format before the connection, and the connection after the commit. Both
            // orderings are load-bearing and neither is obvious.
            //
            // A connection answers `isVideoRotationAngleSupported` against the format that is
            // active *now*, and inside a configuration block that is still the device's
            // default — so asking there gets an answer about a format that is about to be
            // replaced. It is also why this failed on one phone and not the other despite
            // identical code: the two ship different default formats, one of which happened
            // to allow the turn. The failure is silent and total. The encoder is built from
            // the rung, so it is expecting portrait, and landscape frames arrive into it.
            Self.adopt(format, on: device, logger: logger)
            session.commitConfiguration()

            applyMirroring()
            applyRotation()
            applyStabilisation()
        }

        /// Ask the device for the size and frame rate that were requested.
        ///
        /// Without this the ``CaptureFormat`` handed in is documentation: the session runs at
        /// whatever the device's default active format provides, which is thirty frames a
        /// second on every iPhone. Asking for sixty produced thirty, and nothing said so —
        /// the encoder was told to expect sixty, the catalog advertised sixty, and the
        /// publisher's own counters showed a steady thirty that looked like a hardware limit
        /// rather than a request nobody made.
        ///
        /// Chosen by preferring an exact size match at the requested rate, then the smallest
        /// format that is at least as large. A format list is not sorted and not uniform
        /// across devices, so picking the first plausible entry gets a 4K format for a 720p
        /// request on some phones and burns the power budget on pixels that are about to be
        /// scaled away.
        private static func adopt(
            _ format: CaptureFormat,
            on device: AVCaptureDevice,
            logger: MoqomLogger
        ) {
            // Compared against the sensor's own orientation, which is always landscape. The
            // frames are turned afterwards, at the connection, so a portrait request of
            // 720×1280 is a 1280×720 sensor mode and not the 4K one that is the smallest
            // format literally 1280 pixels tall.
            let asked = format.size
            let wanted = asked.height > asked.width
                ? PixelSize(width: asked.height, height: asked.width)
                : asked
            let rate = max(1, format.frameRate)

            #if os(iOS)
                // Before the formats are read, because switching it changes which formats
                // exist: with Center Stage on, a device offers only the formats that support
                // it, and the choice below is made from that shortened list.
                //
                // Off for a call. It crops into a wide sensor and pans the crop to follow
                // whoever it finds, which is a decision about framing that belongs to the
                // person holding the phone, and it re-frames on its own schedule — a slow
                // drift across the scene that an encoder pays for as full-frame motion. On
                // the phone whose front camera is the square Center Stage sensor it also
                // took over the shape of the output entirely: the connection was asked for a
                // quarter turn, reported that it had taken it, and delivered landscape
                // frames anyway, because the framing happens after the rotation.
                if AVCaptureDevice.isCenterStageEnabled {
                    AVCaptureDevice.centerStageControlMode = .app
                    AVCaptureDevice.isCenterStageEnabled = false
                }
            #endif

            let candidates = device.formats.filter { candidate in
                let dimensions = CMVideoFormatDescriptionGetDimensions(
                    candidate.formatDescription
                )
                guard dimensions.width >= Int32(wanted.width),
                      dimensions.height >= Int32(wanted.height)
                else { return false }
                return candidate.videoSupportedFrameRateRanges.contains { range in
                    range.maxFrameRate + 0.01 >= rate && range.minFrameRate - 0.01 <= rate
                }
            }

            // The smallest that will do, measured in pixels, so a 720p60 request does not
            // land on a 4K60 sensor mode. Ties are broken on power: a binned mode reads fewer
            // sensor rows, and an eight-bit mode moves two thirds of the bytes of a ten-bit
            // one through every stage that follows. Neither shows up in the picture at this
            // size, and together they are the difference between a phone that stays warm and
            // one that gets hot enough for iOS to start slowing the camera down.
            let best = candidates.min { left, right in
                let a = CMVideoFormatDescriptionGetDimensions(left.formatDescription)
                let b = CMVideoFormatDescriptionGetDimensions(right.formatDescription)
                let pixels = (Int(a.width) * Int(a.height), Int(b.width) * Int(b.height))
                if pixels.0 != pixels.1 { return pixels.0 < pixels.1 }
                if isCheap(left) != isCheap(right) { return isCheap(left) }
                return isBinned(left) && !isBinned(right)
            }

            guard let best else {
                logger.warning(.media, "no capture format offers what was asked for", [
                    LogField("width", .number(wanted.width)),
                    LogField("height", .number(wanted.height)),
                    LogField("frameRate", .number(Int(rate))),
                ])
                return
            }

            do {
                try device.lockForConfiguration()
            } catch {
                logger.warning(.media, "could not configure the camera", [
                    LogField("error", .text(String(describing: error))),
                ])
                return
            }
            defer { device.unlockForConfiguration() }

            device.activeFormat = best

            // Both bounds, because only setting the minimum duration leaves the device free
            // to drop to its lowest supported rate in dim light — which is the correct
            // photographic answer and the wrong one for a call, where a frame rate that
            // halves when someone turns a lamp off reads as a network fault.
            let duration = CMTime(value: 1, timescale: CMTimeScale(rate.rounded()))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration

            // Turned off rather than left automatic. Extended-range capture runs the sensor
            // and the ISP harder for a picture that is then compressed to two megabits and
            // shown in a tile, and the automatic setting will engage it as soon as the scene
            // has a bright window in it — so the same call warms up or does not depending on
            // where somebody is sitting.
            #if os(iOS) || os(tvOS)
                if best.isVideoHDRSupported {
                    device.automaticallyAdjustsVideoHDREnabled = false
                    device.isVideoHDREnabled = false
                }
            #endif

            // sRGB where offered, for the same reason: the wide-gamut and HLG spaces carry ten
            // bits per component through capture and conversion, and nothing downstream of the
            // encoder asked for them.
            if best.supportedColorSpaces.contains(.sRGB) {
                device.activeColorSpace = .sRGB
            }
        }

        /// Whether a format's pixels are eight bits per component.
        ///
        /// Ten-bit modes are named with an `x` prefix — `x420`, `x422` — against the `420v` and
        /// `420f` of the eight-bit ones.
        /// Whether the sensor combines neighbouring pixels for this format, which is the cheap
        /// way to reach a small size. Not a concept on macOS, where the answer is always no.
        private static func isBinned(_ format: AVCaptureDevice.Format) -> Bool {
            #if os(iOS) || os(tvOS)
                return format.isVideoBinned
            #else
                return false
            #endif
        }

        private static func isCheap(_ format: AVCaptureDevice.Format) -> Bool {
            let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            return subtype == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                || subtype == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        }

        /// Open the device and begin delivering frames.
        ///
        /// The caller is responsible for having obtained camera authorisation.
        /// The SDK does not prompt: the prompt belongs where the app can
        /// explain itself, not at the moment a broadcast starts.
        public func start() {
            queue.async { [weak self, box] in
                guard !box.session.isRunning else { return }
                box.session.startRunning()

                // Again, once frames are actually flowing. A connection's properties are
                // reset by anything that rebuilds it, and a running session is the only
                // state in which the answer to "will you turn this?" is the final one.
                self?.applyRotation()
            }
            #if os(iOS)
                if stabilisation == .whenMoving { watchMotion() }
            #endif
        }

        public func frames() -> AsyncStream<VideoFrame> { relay.frames() }

        /// Switch to the other camera without interrupting the publication.
        ///
        /// The stream of frames does not stop and is not replaced, which is the
        /// reason this exists rather than leaving an application to build a
        /// second ``CameraSource``: the publication, the encoders, and every
        /// subscriber are bound to the source that was handed to
        /// ``RoomSession/startBroadcast(from:configuration:)``, so swapping the
        /// object means stopping and restarting the broadcast, and a viewer
        /// sees the participant leave the stage and come back.
        ///
        /// The device is opened on the calling thread and the session is
        /// reconfigured on the capture queue. That split is what lets this
        /// report a camera it cannot open — no such device, or another process
        /// holding it — as a thrown error rather than as frames that quietly
        /// never arrive.
        ///
        /// > Note: The new camera's first frames arrive a moment later, and
        /// > they are a different scene entirely. Follow this with
        /// > ``Broadcast/startNewGroup()`` so subscribers get a keyframe rather
        /// > than a second of the new camera predicted from the old one.
        public func setPosition(_ position: CameraPosition) throws(MoqomError) {
            guard position != self.position else { return }
            guard let device = Self.device(for: position) else {
                throw MoqomError.platform(api: "AVCaptureDevice.default", status: -1)
            }

            let replacement: AVCaptureDeviceInput
            do {
                replacement = try AVCaptureDeviceInput(device: device)
            } catch {
                throw MoqomError.platform(api: "AVCaptureDeviceInput.init", status: -1)
            }

            // The new device has its own default active format, so the request has to be made
            // again. Otherwise flipping to the back camera mid-call silently halves the frame
            // rate of everything after it.
            Self.adopt(captureFormat, on: device, logger: logger)

            let swap = InputBox(previous: lock.withLock { input }, replacement: replacement)
            lock.withLock {
                current = position
                input = replacement
            }

            queue.async { [weak self, box] in
                let session = box.session
                session.beginConfiguration()
                session.removeInput(swap.previous)

                if session.canAddInput(swap.replacement) {
                    session.addInput(swap.replacement)
                } else {
                    // Rolling back rather than committing a session with no
                    // input at all. The switch failing is recoverable; a
                    // publication that goes black because the camera it used to
                    // have was removed on the way to one it could not get is
                    // not, and it would go on reporting itself as healthy.
                    session.addInput(swap.previous)
                    self?.revert(to: swap.previous)
                }

                session.commitConfiguration()
                self?.applyMirroring()
                self?.applyRotation()
                self?.applyStabilisation()
            }
        }

        /// Put the previous input back on record after a failed switch.
        private func revert(to previous: AVCaptureDeviceInput) {
            lock.withLock {
                current = switch previous.device.position {
                case .front: .front
                case .back: .back
                default: .system
                }
                input = previous
            }
        }

        /// Push the mirroring flag onto the capture connection.
        ///
        /// Always called on the capture queue, and always after a
        /// reconfiguration, because a connection belongs to the input that was
        /// just replaced and the new one comes back with the defaults.
        private func applyMirroring() {
            guard let connection = output.connection(with: .video) else { return }
            let wanted = lock.withLock { mirrored }
            guard connection.isVideoMirroringSupported else { return }

            // The automatic behaviour mirrors the front camera for you, which
            // sounds like the right thing and is the bug: it mirrors what is
            // published, not what is previewed.
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = wanted
        }

        /// Always called on the capture queue, for the same reason as ``applyMirroring``.
        ///
        /// Stabilisation is the expensive default nobody asks for. It buffers frames to
        /// compare them, which adds latency to a live call, and it runs a warp over every one
        /// of them, which is real work on a device already encoding sixty a second. What it
        /// buys is a steadier picture from a moving camera — worth having when filming, and
        /// worth nothing for a phone propped on a desk pointed at a face.
        private func applyStabilisation() {
            #if os(iOS) || os(tvOS)
                guard let connection = output.connection(with: .video) else { return }
                guard connection.isVideoStabilizationSupported else { return }

                let wanted: AVCaptureVideoStabilizationMode = lock.withLock {
                    switch steadying {
                    case .off: .off
                    case .always: .standard
                    case .whenMoving: moving ? .standard : .off
                    }
                }
                guard connection.preferredVideoStabilizationMode != wanted else { return }

                // `.standard` rather than `.cinematic`, which is the other one worth having and
                // is the wrong trade here: cinematic buffers a good deal more of the future to
                // smooth a pan, and a call cannot spend that.
                connection.preferredVideoStabilizationMode = wanted
            #endif
        }

        #if os(iOS)
            /// Follow the gyroscope, and turn stabilisation on and off as it answers.
            ///
            /// Asymmetric on purpose. Movement engages it within a fifth of a second, because the
            /// frames worth rescuing are the ones at the start of a shake; stillness disengages it
            /// only after several seconds, because a switch that flips at every pause would show
            /// as the picture jumping scale each time — stabilisation crops, and turning it off
            /// widens the field of view back out.
            private func watchMotion() {
                motion.start { [weak self] rate in
                    guard let self else { return }
                    let changed: Bool = lock.withLock {
                        guard moving != rate else { return false }
                        moving = rate
                        return true
                    }
                    guard changed else { return }
                    queue.async { [weak self] in self?.applyStabilisation() }
                }
            }
        #endif

        /// Always called on the capture queue, for the same reason as ``applyMirroring``.
        private func applyRotation() {
            guard let connection = output.connection(with: .video) else { return }
            let wanted = lock.withLock { rotation }
            guard connection.videoRotationAngle != wanted else { return }
            guard connection.isVideoRotationAngleSupported(wanted) else {
                // Said out loud because of what it costs silently. Everything downstream was
                // sized from ``captureFormat``: the encoder is configured for portrait, the
                // catalog advertises it, and the frames arriving are landscape — which is not
                // a failure anything checks, it is a picture that is stretched and on its
                // side at the far end while every counter reads normal.
                logger.warning(.media, "the capture connection will not rotate", [
                    LogField("degrees", .number(Int(wanted))),
                ])
                return
            }
            connection.videoRotationAngle = wanted
        }

        public func stop() {
            relay.stop()
            #if os(iOS)
                motion.stop()
            #endif
            queue.async { [box] in
                if box.session.isRunning { box.session.stopRunning() }
            }
        }

        private static func device(for position: CameraPosition) -> AVCaptureDevice? {
            switch position {
            case .front:
                AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            case .back:
                AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            case .system:
                AVCaptureDevice.default(for: .video)
            }
        }
    }

    #if os(iOS)
        /// Reports whether the device is being moved, from the gyroscope and from what the
        /// person carrying it is doing.
        ///
        /// The gyroscope rather than the accelerometer, and rate rather than orientation. What
        /// stabilisation corrects is rotation — the small involuntary turns of a hand holding a
        /// phone — and rotation rate is the quantity that says how much of it is happening. A
        /// phone can be perfectly still at any angle, and gravity dominates an accelerometer at
        /// all of them, so an accelerometer answers the wrong question and answers it noisily.
        ///
        /// The gyroscope alone answers it a beat at a time, though, and walking is not a beat.
        /// It is a sequence of them with gaps: a stride, a pause at a kerb, a stride. Judged on
        /// rotation rate every one of those pauses looks like the phone being set down, and
        /// stabilisation switching off and on across a walk is worse than either state, because
        /// engaging it crops the frame and disengaging widens it — the picture visibly jumps
        /// scale each way. `CMMotionActivityManager` names the sustained thing the gyroscope can
        /// only sample, so the two together hold stabilisation on for the whole walk and drop it
        /// when the walk ends.
        ///
        /// > Note: the activity half needs `NSMotionUsageDescription` in the application's
        /// > `Info.plist` and the person's permission; an application without the key is
        /// > terminated the moment it asks. Raw gyroscope data needs neither. Where permission
        /// > is absent, refused, or the device has no motion coprocessor, this falls back to the
        /// > gyroscope alone and everything still works — a little more eagerly.
        final class MotionWatch: @unchecked Sendable {
            private let manager = CMMotionManager()
            private let activity = CMMotionActivityManager()
            private let queue: OperationQueue = {
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1
                queue.qualityOfService = .utility
                return queue
            }()

            /// Radians per second at which the device counts as moving, and the lower figure it
            /// must fall below to count as still again.
            ///
            /// Two thresholds rather than one, because a single one flaps: a hand hovering
            /// either side of it would toggle stabilisation several times a second. A phone
            /// lying on a desk reads a few hundredths from sensor noise alone, a hand holding
            /// one still reads around a tenth, and a hand that is actually moving reads several
            /// times that.
            private let starts = 0.25
            private let stops = 0.08

            /// How long stillness must last before stabilisation is dropped.
            private let settles = Duration.seconds(4)

            private var still: ContinuousClock.Instant?

            /// What each sensor thinks, and what the caller was last told. Both sources report
            /// on ``queue``, which is serial, so these need no lock.
            private var shaking = false
            private var striding = false
            private var reported = false

            /// Whether the person is walking, running, or riding something. See ``isWalking``.
            var isStriding: Bool { striding }

            func start(_ changed: @escaping @Sendable (Bool) -> Void) {
                watchActivity(changed)

                guard manager.isGyroAvailable, !manager.isGyroActive else { return }

                // Twenty a second. The decision is a threshold with a four-second hold on one
                // side of it, so nothing here can use a faster signal, and the sensor is cheaper
                // to read slowly.
                manager.gyroUpdateInterval = 0.05
                manager.startGyroUpdates(to: queue) { [weak self] data, _ in
                    guard let self, let rate = data?.rotationRate else { return }
                    let magnitude = (rate.x * rate.x + rate.y * rate.y + rate.z * rate.z)
                        .squareRoot()
                    shaking = settle(on: magnitude)
                    guard let now = publish() else { return }
                    changed(now)
                }
            }

            /// Follow what the person is doing, if they have allowed it.
            ///
            /// Checked rather than attempted, because asking without the usage description is
            /// not an error that can be caught — the system terminates the process. Refused and
            /// unavailable are both ordinary: the gyroscope covers the same ground with a
            /// shorter memory, so there is nothing here to tell anyone about or ask twice for.
            /// A `notDetermined` status is the one case that prompts, and it prompts because
            /// starting updates is the only way to ask.
            private func watchActivity(_ changed: @escaping @Sendable (Bool) -> Void) {
                guard CMMotionActivityManager.isActivityAvailable() else { return }
                switch CMMotionActivityManager.authorizationStatus() {
                case .denied, .restricted: return
                default: break
                }

                activity.startActivityUpdates(to: queue) { [weak self] reading in
                    guard let self, let reading else { return }

                    // Anything that carries the phone along with it. Cycling and driving are in
                    // here with walking because they shake a held phone harder than walking
                    // does, and `stationary` is not simply the negation of the rest: a reading
                    // can be none of these with low confidence, which is the coprocessor saying
                    // it does not know, and the gyroscope is the better answer then.
                    let carried = reading.walking || reading.running
                        || reading.cycling || reading.automotive
                    if carried {
                        striding = true
                    } else if reading.stationary {
                        striding = false
                    }
                    guard let now = publish() else { return }
                    changed(now)
                }
            }

            /// The gyroscope's hysteresis, kept apart from the sensor plumbing so it can be
            /// reasoned about. Returns whether the device is shaking now.
            private func settle(on magnitude: Double) -> Bool {
                if magnitude > starts {
                    still = nil
                    return true
                }
                guard shaking else { return false }
                guard magnitude < stops else {
                    still = nil
                    return true
                }

                let began = still ?? .now
                still = began
                guard ContinuousClock.now - began > settles else { return true }
                still = nil
                return false
            }

            /// The combined answer, and only when it changed.
            ///
            /// An OR, and the asymmetry is the point: either sensor seeing movement engages
            /// stabilisation, and it takes both of them going quiet to let it go. Walking holds
            /// it through the pause at a kerb that the gyroscope would have read as stillness.
            private func publish() -> Bool? {
                let now = shaking || striding
                guard now != reported else { return nil }
                reported = now
                return now
            }

            func stop() {
                manager.stopGyroUpdates()
                activity.stopActivityUpdates()
                still = nil
                shaking = false
                striding = false
                reported = false
            }

            deinit { manager.stopGyroUpdates() }
        }
    #endif

    extension CameraSource: AVCaptureVideoDataOutputSampleBufferDelegate {
        public func captureOutput(
            _: AVCaptureOutput,
            didOutput sampleBuffer: CMSampleBuffer,
            from _: AVCaptureConnection
        ) {
            guard let captured = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let turned = upright(captured)
            let buffer = turned ?? captured
            softwareTurns = turned != nil

            relay.submit(
                VideoFrame(
                    timestamp: FrameTimestamp(seconds: CMTimeGetSeconds(timestamp)),
                    size: PixelSize(
                        width: CVPixelBufferGetWidth(buffer),
                        height: CVPixelBufferGetHeight(buffer)
                    ),
                    surface: .pixelBuffer(buffer)
                )
            )
        }

        /// Turn a frame the capture connection did not, or `nil` when none is needed.
        ///
        /// A fallback that should never run, kept because the alternative to it is what
        /// actually happened: one of two phones on the same build set `videoRotationAngle`
        /// to ninety, reported ninety back, and went on delivering landscape frames. The
        /// property is a request, its getter echoes the request rather than the outcome, and
        /// there is no third thing to ask. So the shape of the buffer is the only honest
        /// answer, and it is checked on every frame — cheaply, because the check is two
        /// integer reads and the work only happens when they disagree with the promise.
        ///
        /// `VTPixelRotationSession` rather than anything of ours: it is hardware, it keeps
        /// the frame in the same surface type the encoder wants, and a rotation on the CPU
        /// at sixty frames a second is not affordable on the phone that needs this.
        private func upright(_ buffer: CVPixelBuffer) -> CVPixelBuffer? {
            let wanted = captureFormat.size
            let width = CVPixelBufferGetWidth(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            guard (wanted.height > wanted.width) != (height > width) else { return nil }

            guard let session = rotator(from: buffer) else { return nil }
            var turned: CVPixelBuffer?
            guard let pool = rotationPool,
                  CVPixelBufferPoolCreatePixelBuffer(nil, pool, &turned) == kCVReturnSuccess,
                  let turned
            else { return nil }

            guard VTPixelRotationSessionRotateImage(session, buffer, turned) == noErr else {
                return nil
            }
            return turned
        }

        /// The rotation session and its pool, built once for a given source shape.
        private func rotator(from buffer: CVPixelBuffer) -> VTPixelRotationSession? {
            let width = CVPixelBufferGetWidth(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            let mirrors = lock.withLock { mirrored }
            if let existing = rotation90,
               rotationSource == PixelSize(width: width, height: height),
               rotationMirrors == mirrors
            {
                return existing
            }

            var created: VTPixelRotationSession?
            guard VTPixelRotationSessionCreate(nil, &created) == noErr, let created else {
                return nil
            }

            // Which way to turn depends on whether the connection has already mirrored, and
            // that is geometry rather than a preference.
            //
            // Anticlockwise is the plain case, because that is what `videoRotationAngle`
            // means — the angle is measured anticlockwise from the sensor's landscape, so a
            // connection told `90` turns the opposite way from `kVTRotation_CW90`. The two
            // read identically in code and differ by half a turn on screen, which is what one
            // phone showed while the other, rotated by its connection, was right way up.
            //
            // Mirroring changes the answer. The connection mirrors in the sensor's frame,
            // about an axis that any quarter turn carries onto the *other* axis: a horizontal
            // flip of a landscape frame becomes a vertical flip of the portrait one, and a
            // vertically flipped face reads as upside down rather than as a mirror. Turning
            // the other way is exactly the half turn that converts one into the other, since
            // a vertical flip followed by a half turn is a horizontal flip. So the mirrored
            // path turns clockwise and arrives at the same picture the connection produces
            // when it does both itself.
            //
            // The session's own flip properties would be the obvious tool and are not used:
            // whether they apply before or after the rotation is not documented, and picking
            // wrong is the same half turn again with nothing in the code to say which it was.
            VTSessionSetProperty(
                created,
                key: kVTPixelRotationPropertyKey_Rotation,
                value: mirrors ? kVTRotation_CW90 : kVTRotation_CCW90
            )

            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: CVPixelBufferGetPixelFormatType(buffer),
                kCVPixelBufferWidthKey: height,
                kCVPixelBufferHeightKey: width,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            var pool: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(
                nil,
                nil,
                attributes as CFDictionary,
                &pool
            ) == kCVReturnSuccess else { return nil }

            logger.warning(.media, "rotating frames in software; the camera would not", [
                LogField("width", .number(width)),
                LogField("height", .number(height)),
            ])

            rotation90 = created
            rotationPool = pool
            rotationSource = PixelSize(width: width, height: height)
            rotationMirrors = mirrors
            return created
        }
    }
    /// Carries the capture session onto the capture queue.
    ///
    /// `@unchecked` because `AVCaptureSession` predates `Sendable`. Everything
    /// after construction touches it only from ``CameraSource``'s own serial
    /// queue, which is also where it has to happen: `startRunning()` blocks,
    /// and calling it on the main thread stalls the UI for as long as the
    /// device takes to open.
    private final class CaptureSessionBox: @unchecked Sendable {
        let session = AVCaptureSession()
    }

    /// Carries the two inputs of a camera switch onto the capture queue.
    ///
    /// `@unchecked` for the same reason as ``CaptureSessionBox``:
    /// `AVCaptureDeviceInput` predates `Sendable`. Both are constructed on the
    /// calling thread and then touched only from the capture queue, and the
    /// object is handed over rather than shared — the caller keeps no
    /// reference it will use again.
    private struct InputBox: @unchecked Sendable {
        let previous: AVCaptureDeviceInput
        let replacement: AVCaptureDeviceInput
    }
#endif
