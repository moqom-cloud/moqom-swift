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
        import UIKit
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

        /// Kept because a camera switch has to make the same request of the new device, whose
        /// formats are its own — a front camera that offers no doubled mode says nothing about
        /// the back one.
        private let oversampling: CaptureOversampling

        private let box = CaptureSessionBox()
        private let output = AVCaptureVideoDataOutput()
        private let queue = DispatchQueue(label: "moqom.camera", qos: .userInteractive)
        private let relay: FrameRelay

        /// The fallback rotation, its pool, and the shape it was built for. Only ever touched
        /// from the capture queue, which is where frames are delivered. See ``upright(_:)``.
        private var rotation90: VTPixelRotationSession?
        private var rotationPool: CVPixelBufferPool?
        private var rotationSource: PixelSize?
        private var rotationTurn: Turn?

        /// Whether the last frame was turned here rather than by the connection.
        ///
        /// Reported because the two paths are indistinguishable downstream and were not
        /// equivalent: they turned opposite ways, and the only evidence was one of two phones
        /// being upside down. Written on the capture queue, read for diagnostics.
        public private(set) var softwareTurns = false

        /// How many times the system has interrupted or failed this session, and why the last
        /// one did. See ``watchSession``.
        public private(set) var interruptions = 0
        public private(set) var lastInterruption: String?

        private var observers: [any NSObjectProtocol] = []

        /// The last frame's sensor stamp, on the capture queue only. See ``captureOutput``.
        private var lastCaptureStamp: CMTime?

        /// How long the system held a frame the sensor had already stamped.
        ///
        /// The one stage of the capture path nothing measured, and it is charged to the network
        /// by every figure that does. A sample buffer's stamp is written when the sensor read the
        /// row; this callback runs after readout and after whatever the image pipeline does in
        /// between, and none of that is free — but it lands inside the sensor-to-arrival figure
        /// alongside the encoder and the radio, where it looks like transport cost.
        ///
        /// Worth measuring because of the size of the hole. On two phones the whole path was
        /// observed at 29ms and is currently costing 47ms, of which the network accounts for 15
        /// and the encoder for 7. The remaining 25 were attributed to nothing at all, and this is
        /// the larger of the two places they can be.
        ///
        /// It is also the figure ``CaptureOversampling`` moves, and the only one that will say
        /// whether it worked: a faster sensor shortens readout and nothing else in the pipeline
        /// can tell the difference. Recorded for the frames that are published rather than for
        /// every frame captured, since a discarded one costs the publication nothing.
        private var delivery = StageMeter()

        /// What the sensor's stamp to this callback costs, in milliseconds.
        public var deliveryLatency: StageLatency { lock.withLock { delivery.summary } }

        /// The sensor rate and the discard cadence that turns it back into the publication rate.
        private var cadence: CaptureCadence

        /// What the device was asked to run at, which is not always what it was asked to publish.
        ///
        /// Equal to `captureFormat.frameRate` unless ``CaptureOversampling`` found a faster mode
        /// worth taking — see there. Worth surfacing because the two rates are indistinguishable
        /// downstream: every counter in the publish path sees the published rate, so a device
        /// that quietly declined the faster mode looks exactly like one that took it.
        public var sensorFrameRate: Double { lock.withLock { cadence.sensorRate } }

        /// Guards ``position`` and ``publishesMirrored``, which are read from
        /// whatever thread the interface runs on and written from there too,
        /// while the capture queue reads them to configure the session.
        private let lock = NSLock()
        private var current: CameraPosition
        private var mirrored = false
        private var rotation: Double = 0
        private var input: AVCaptureDeviceInput

        /// The turn the capture connection is actually applying, which is not always the one
        /// that was asked for. See ``applyRotation``.
        public var appliedRotationDegrees: Double {
            output.connection(with: .video).map { Double($0.videoRotationAngle) } ?? 0
        }

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
        /// across the device, so a portrait publication needs a quarter turn. Asked of
        /// the connection before the camera starts, that turn is free: the capture
        /// pipeline applies it on the way out and no buffer is ever touched twice.
        ///
        /// Asked of a *running* connection it is not free, and what it costs is the
        /// reason this is worth reading. Measured on two phones, changing the angle on a
        /// live connection stops the camera for three to five frames — the gaps are exact
        /// multiples of the frame interval in the sensor's own timestamps, so the device
        /// genuinely stopped rather than anything downstream falling behind. A host
        /// switching layout mid-call did it every time and paid a visible freeze for it.
        ///
        /// So this only reconfigures the connection while the camera is stopped. Changed
        /// while running, the turn moves to ``VTPixelRotationSession`` instead, which is
        /// hardware, keeps the surface type the encoder wants, and costs one pass per
        /// frame for as long as the published shape differs from the angle the connection
        /// was given. That is the trade, and it is the right way round: a pass per frame
        /// is a few milliseconds of silicon nobody sees, and a stopped camera is four
        /// missing frames everybody does.
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

        /// - Parameters:
        ///   - oversampling: Whether to run the sensor faster than the publication to shorten
        ///     readout, which is worth about eight milliseconds for twice the sensor and
        ///     image-pipeline work. See ``CaptureOversampling``.
        ///   - logger: Where a capture format that cannot be honoured is reported.
        ///     Worth passing: a device that will not give the requested frame rate keeps
        ///     delivering at its own, and the difference is invisible until somebody counts.
        ///
        /// > Note: `oversampling` is settled here and not revisited. Changing it later means a
        /// > new active format, and swapping the active format of a running session costs the
        /// > same three to five dropped frames that ``rotationDegrees`` goes to some length to
        /// > avoid — so a caller that wants to give the eight milliseconds back under thermal
        /// > pressure should build a source that never took them.
        public init(
            format: CaptureFormat,
            position: CameraPosition = .front,
            oversampling: CaptureOversampling = .automatic,
            logger: MoqomLogger = .silent
        ) throws {
            captureFormat = format
            relay = FrameRelay(format: format)
            current = position
            self.logger = logger
            self.oversampling = oversampling
            cadence = CaptureCadence(
                publishing: format.frameRate,
                sensor: format.frameRate
            )

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
            cadence = CaptureCadence(
                publishing: format.frameRate,
                sensor: Self.adopt(
                    format,
                    on: device,
                    oversampling: oversampling,
                    logger: logger
                )
            )
            session.commitConfiguration()

            applyMirroring()
            applyRotation()
            applyStabilisation()
            watchSession()
        }

        /// Say out loud when the system takes the camera away.
        ///
        /// Capture stalls of several seconds show up downstream as a frozen picture, a
        /// receiver that widens its playout buffer to cover them, and a hundred and fifty
        /// milliseconds of latency that then takes half a minute to give back. Everything
        /// visible at that end is a symptom, and the two explanations — the session was
        /// interrupted, or the session was fine and something after it stopped pulling —
        /// call for opposite fixes. `AVCaptureSession` knows which, and says so here.
        private func watchSession() {
            let centre = NotificationCenter.default
            #if os(iOS)
                observers.append(centre.addObserver(
                    forName: AVCaptureSession.wasInterruptedNotification,
                    object: box.session,
                    queue: nil
                ) { [weak self] note in
                    let raw = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
                    let reason = raw.flatMap(AVCaptureSession.InterruptionReason.init(rawValue:))
                    self?.interruptions += 1
                    self?.lastInterruption = reason.map(Self.describe) ?? "unknown"
                    self?.logger.warning(.media, "capture interrupted", [
                        LogField("reason", .text(reason.map(Self.describe) ?? "unknown")),
                    ])
                })
                observers.append(centre.addObserver(
                    forName: AVCaptureSession.interruptionEndedNotification,
                    object: box.session,
                    queue: nil
                ) { [weak self] _ in
                    self?.logger.info(.media, "capture resumed", [])

                    // Started again, because the end of an interruption is not the resumption
                    // of anything. A session stopped for the background stays stopped when the
                    // app returns, and what that looks like from the other end of a call is a
                    // publisher whose audio is perfect and whose picture froze on the frame
                    // before a notification was read: no error, no dropped frames, a submitted
                    // count that simply stops moving. `start()` is a no-op on a session that
                    // is already running, so a system that does resume by itself loses
                    // nothing here.
                    self?.start()
                })

                // Backgrounding is not always reported as an interruption — a session stopped
                // as the app suspends can end without one — so the return to the foreground
                // is treated as its own reason to check. Cheap: everything below is a read of
                // `isRunning` on a session that is already going.
                observers.append(centre.addObserver(
                    forName: UIApplication.didBecomeActiveNotification,
                    object: nil,
                    queue: nil
                ) { [weak self] _ in
                    self?.start()
                })
            #endif
            observers.append(centre.addObserver(
                forName: AVCaptureSession.runtimeErrorNotification,
                object: box.session,
                queue: nil
            ) { [weak self] note in
                let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
                self?.interruptions += 1
                self?.lastInterruption = "runtime error \(error?.code ?? 0)"
                self?.logger.error(.media, "capture failed", [
                    LogField("code", .number(error?.code ?? 0)),
                ])

                // Restarted, because a runtime error stops the session and nothing else will
                // start it again. The common one is the system reclaiming the device, and the
                // device usually comes back.
                self?.start()
            })
        }

        #if os(iOS)
            private static func describe(
                _ reason: AVCaptureSession.InterruptionReason
            ) -> String {
                switch reason {
                case .videoDeviceNotAvailableInBackground: "backgrounded"
                case .audioDeviceInUseByAnotherClient: "microphone taken"
                case .videoDeviceInUseByAnotherClient: "camera taken"
                case .videoDeviceNotAvailableWithMultipleForegroundApps: "sharing the screen"
                case .videoDeviceNotAvailableDueToSystemPressure: "system pressure"
                @unknown default: "unknown"
                }
            }
        #endif

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }

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
        /// - Returns: The rate the sensor was actually asked for, which is the publication rate
        ///   unless a faster whole multiple was available for the same pixels. The caller needs
        ///   it to know how many captured frames make one published one.
        @discardableResult
        private static func adopt(
            _ format: CaptureFormat,
            on device: AVCaptureDevice,
            oversampling: CaptureOversampling,
            logger: MoqomLogger
        ) -> Double {
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

            // Size settled first, and the rate chosen among what is left, because the two
            // questions are not independent: the fastest format a device has is always some
            // small high-speed mode, so asking which rate is reachable before narrowing by
            // size turns the frame-rate decision into a resolution one.
            let sized = device.formats.filter { candidate in
                let dimensions = CMVideoFormatDescriptionGetDimensions(
                    candidate.formatDescription
                )
                return dimensions.width >= Int32(wanted.width)
                    && dimensions.height >= Int32(wanted.height)
            }

            func matching(_ wantedRate: Double) -> [AVCaptureDevice.Format] {
                sized.filter { candidate in
                    candidate.videoSupportedFrameRateRanges.contains { range in
                        range.maxFrameRate + 0.01 >= wantedRate
                            && range.minFrameRate - 0.01 <= wantedRate
                    }
                }
            }

            var sensorRate = CaptureCadence.sensorRate(
                publishing: rate,
                from: sized.map(Self.offer),
                limit: oversampling.limit(publishing: rate)
            )
            var candidates = matching(sensorRate)

            // Belt and braces, because the rate was chosen from each format's outermost range
            // bounds while the list is filtered range by range. A device whose supported rates
            // have a hole in them could answer yes to the first question and no to the second,
            // and the cost of not noticing is not a slower camera — it is no format adopted at
            // all, leaving the session on a default that is neither the size nor the rate
            // anything downstream was built for.
            if candidates.isEmpty, sensorRate != rate {
                sensorRate = rate
                candidates = matching(rate)
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
                return rate
            }

            do {
                try device.lockForConfiguration()
            } catch {
                logger.warning(.media, "could not configure the camera", [
                    LogField("error", .text(String(describing: error))),
                ])
                return rate
            }
            defer { device.unlockForConfiguration() }

            device.activeFormat = best

            // Both bounds, because only setting the minimum duration leaves the device free
            // to drop to its lowest supported rate in dim light — which is the correct
            // photographic answer and the wrong one for a call, where a frame rate that
            // halves when someone turns a lamp off reads as a network fault.
            //
            // Pinned to the sensor rate rather than the published one. A device left free to
            // run slower than it was asked would break the discard cadence rather than merely
            // slow it: the survivors are chosen on their stamps, so a sensor that quietly
            // halves its rate has every frame clear the threshold and the publication carries
            // on at the right rate from a camera producing exactly enough frames to feed it,
            // with the eight milliseconds silently given back.
            let duration = CMTime(value: 1, timescale: CMTimeScale(sensorRate.rounded()))
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

            // Said out loud, because this is the one decision here that a caller might want
            // reversed and cannot otherwise observe. Both outcomes are worth a line: taking
            // the faster mode is a power cost somebody may be hunting, and declining it is
            // why a phone that should have gained eight milliseconds did not.
            if sensorRate > rate {
                logger.info(.media, "capturing faster than the publication", [
                    LogField("sensor", .number(Int(sensorRate.rounded()))),
                    LogField("publish", .number(Int(rate.rounded()))),
                ])
            } else if oversampling != .off {
                logger.info(.media, "no faster capture mode worth taking", [
                    LogField("publish", .number(Int(rate.rounded()))),
                ])
            }

            return sensorRate
        }

        /// A device format reduced to what the rate decision needs from it.
        private static func offer(_ format: AVCaptureDevice.Format) -> CaptureCadence.Option {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let ranges = format.videoSupportedFrameRateRanges
            return CaptureCadence.Option(
                pixels: Int(dimensions.width) * Int(dimensions.height),
                lowestFrameRate: ranges.map(\.minFrameRate).min() ?? 0,
                highestFrameRate: ranges.map(\.maxFrameRate).max() ?? 0
            )
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
                self?.applyRotation(asTheCameraStarts: true)
            }
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
            let sensorRate = Self.adopt(
                captureFormat,
                on: device,
                oversampling: oversampling,
                logger: logger
            )

            let swap = InputBox(previous: lock.withLock { input }, replacement: replacement)
            lock.withLock {
                current = position
                input = replacement

                // The answer can differ between the two cameras of one phone, so the cadence
                // travels with the device rather than with the source. A front camera with no
                // doubled mode and a back camera with one is an ordinary configuration, and
                // keeping the old cadence across the switch would discard half the frames of
                // a sensor that is no longer producing spares.
                cadence = CaptureCadence(
                    publishing: captureFormat.frameRate,
                    sensor: sensorRate
                )
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
        /// Off, once, and never reconsidered — which is a stronger statement than it looks and
        /// is the outcome of trying the alternative. Stabilisation was motion-driven here: the
        /// gyroscope and the activity sensors decided when a hand-held camera needed it, which
        /// is the genuinely useful version of the feature and is what it costs that killed it.
        /// Changing `preferredVideoStabilizationMode` on a running connection reconfigures the
        /// capture pipeline, and the pipeline stops while it does. Measured on two phones over
        /// the relay: the one being held froze four times in thirty seconds, once for three and
        /// a half, and produced no frames for seventeen percent of the run; the one on the desk
        /// dropped nothing. Downstream, none of that is attributable — the far end sees late
        /// frames and grows its playout buffer, so a feature meant to steady the picture
        /// arrives as a hundred and fifty milliseconds of added latency and a stuttering one.
        ///
        /// Set explicitly rather than left alone, because the default is not documented to be
        /// off and a mode inherited from whatever the device felt like is not a baseline
        /// anybody can measure against.
        private func applyStabilisation() {
            #if os(iOS) || os(tvOS)
                guard let connection = output.connection(with: .video) else { return }
                guard connection.isVideoStabilizationSupported else { return }
                guard connection.preferredVideoStabilizationMode != .off else { return }
                connection.preferredVideoStabilizationMode = .off
            #endif
        }

        /// Always called on the capture queue, for the same reason as ``applyMirroring``.
        ///
        /// - Parameter starting: Whether the camera has only just been told to run, which is
        ///   the one moment the connection may be reconfigured freely. It costs the same
        ///   three to five frames as it would later, and here they are frames before the
        ///   first one anybody sees. Every other caller leaves a delivering connection
        ///   alone — see ``rotationDegrees``.
        private func applyRotation(asTheCameraStarts starting: Bool = false) {
            guard let connection = output.connection(with: .video) else { return }
            let wanted = lock.withLock { rotation }
            guard connection.videoRotationAngle != wanted else { return }

            // ``upright(_:)`` picks a change up from the next frame's shape without the
            // camera noticing. Gated on the session's own state rather than on a flag of
            // ours, because that state is what a suspend for a force-mute and a camera
            // swap both move, and either one is a chance to have the turn back for free.
            guard starting || !box.session.isRunning else { return }
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
            queue.async { [box] in
                if box.session.isRunning { box.session.stopRunning() }
            }
        }

        /// Close the device and leave the stream open.
        ///
        /// The session is stopped and the relay is not, which is the whole
        /// difference from ``stop()``: the green indicator goes out, the
        /// publication above stays up, and ``resume()`` costs a session start
        /// rather than a rejoin. Reacquisition is not free — a few hundred
        /// milliseconds before the first frame, more if another app took the
        /// camera meanwhile — which is why this is reserved for a mute somebody
        /// else imposed rather than used for the mute button.
        public func suspend() {
            queue.async { [box] in
                if box.session.isRunning { box.session.stopRunning() }
            }
        }

        public func resume() {
            start()
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


    extension CameraSource: AVCaptureVideoDataOutputSampleBufferDelegate {
        public func captureOutput(
            _: AVCaptureOutput,
            didOutput sampleBuffer: CMSampleBuffer,
            from _: AVCaptureConnection
        ) {
            guard let captured = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

            // Said at the moment it happens, and with the sensor's own stamps, because a gap
            // reported by a cadence meter minutes later cannot be lined up against anything.
            // A frame missed here is a frame missed by the device, not by any queue of ours:
            // these stamps are written when the sensor read the row, before this callback and
            // before anything downstream could have been slow.
            if let previous = lastCaptureStamp {
                let gap = CMTimeGetSeconds(CMTimeSubtract(timestamp, previous))
                if gap > 0.25 {
                    logger.warning(.media, "the camera stopped", [
                        LogField("milliseconds", .number(Int(gap * 1000))),
                        LogField("interruptions", .number(interruptions)),
                    ])
                }
            }
            lastCaptureStamp = timestamp

            // Every frame is counted above and only some are published, because the two
            // questions are different: the camera stopping is a fact about the device, while
            // this is a choice of ours. Discarding before the rotation and the meter rather
            // than after is the point of discarding at all — a frame nobody will encode should
            // not be turned first, and at twice the rate that pass is charged twice.
            guard lock.withLock({ cadence.delivers(at: CMTimeGetSeconds(timestamp)) }) else {
                return
            }

            // Against the host clock, because that is the clock capture stamps are on. Bounded
            // before it is recorded: a stamp from a session that has just restarted can sit on
            // the far side of a discontinuity, and one such sample is a percentile nobody can
            // act on sitting in the same line as figures they can.
            let handed = CMTimeGetSeconds(
                CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), timestamp)
            )
            if handed > 0, handed < 1 {
                lock.withLock { delivery.record(.seconds(handed)) }
            }

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
        /// Two things arrive here, and neither is a fault. A layout change while the camera
        /// runs is the deliberate one: the connection is left delivering because
        /// reconfiguring it stops the camera for three to five frames, so the turn happens
        /// here instead — see ``rotationDegrees``.
        ///
        /// The other is a connection that said yes and meant no, which is why this is
        /// driven by the buffer's shape rather than by what was asked for. One of two
        /// phones on the same build set `videoRotationAngle` to ninety, reported ninety
        /// back, and went on delivering landscape frames. The property is a request, its
        /// getter echoes the request rather than the outcome, and there is no third thing
        /// to ask. So the shape of the buffer is the only honest answer, and it is checked
        /// on every frame — cheaply, because the check is two integer reads and the work
        /// only happens when they disagree with the promise.
        ///
        /// `VTPixelRotationSession` rather than anything of ours: it is hardware, it keeps
        /// the frame in the same surface type the encoder wants, and a rotation on the CPU
        /// at sixty frames a second is not affordable on the phone that needs this.
        private func upright(_ buffer: CVPixelBuffer) -> CVPixelBuffer? {
            let delivered = PixelSize(
                width: CVPixelBufferGetWidth(buffer),
                height: CVPixelBufferGetHeight(buffer)
            )
            let (rotation, mirrors) = lock.withLock { (self.rotation, mirrored) }
            guard let turn = Self.turn(
                toReach: rotation,
                having: delivered,
                mirrored: mirrors
            ) else { return nil }

            guard let session = rotator(from: buffer, turning: turn) else { return nil }
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

        /// Which way a frame has to be turned here, if it does.
        ///
        /// Separated out and given no camera to depend on because the decision is the part
        /// that was wrong, and it was wrong in a way that could not fail visibly: it compared
        /// the delivered shape against ``captureFormat``, which is what the source was asked
        /// for when it opened. Those agree until the rotation is changed while the camera runs
        /// — publishing landscape from a portrait-configured source, which is what a host
        /// changing layout does — and from then on this turned every frame back to the
        /// original shape. The rotation appeared to be accepted, nothing changed shape, and
        /// each frame paid for a hardware rotation to arrive where it already was.
        ///
        /// - Parameters:
        ///   - rotation: What ``rotationDegrees`` asks for. Every sensor format is landscape,
        ///     so an odd quarter turn is what portrait means, and that is the only question.
        ///   - delivered: The shape of the frame that arrived, which is the one honest account
        ///     of what the connection did.
        ///   - mirrored: Whether the connection is also mirroring. It flips in the sensor's
        ///     frame, about an axis a quarter turn carries onto the other one, so the
        ///     direction that arrives upright depends on it.
        static func turn(
            toReach rotation: Double,
            having delivered: PixelSize,
            mirrored: Bool
        ) -> Turn? {
            let quarters = Int((rotation / 90).rounded())
            let upright = quarters % 2 != 0
            guard upright != (delivered.height > delivered.width) else { return nil }

            // Anticlockwise is the plain case, because that is what `videoRotationAngle`
            // means — the angle is measured anticlockwise from the sensor's landscape, so a
            // connection told `90` turns the opposite way from `kVTRotation_CW90`. The two
            // read identically in code and differ by half a turn on screen, which is what one
            // phone showed while the other, rotated by its connection, was right way up.
            //
            // Mirroring changes the answer, and so does turning back out of portrait rather
            // than into it, since those two turns are inverses. Both conditions flip the
            // direction, so two of them cancel.
            return (mirrored == upright) ? Turn.clockwise : Turn.anticlockwise
        }

        /// A quarter turn, in the direction that arrives the right way up.
        enum Turn: Equatable {
            case clockwise
            case anticlockwise
        }

        /// The rotation session and its pool, built once for a given source shape.
        private func rotator(
            from buffer: CVPixelBuffer,
            turning turn: Turn
        ) -> VTPixelRotationSession? {
            let width = CVPixelBufferGetWidth(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            if let existing = rotation90,
               rotationSource == PixelSize(width: width, height: height),
               rotationTurn == turn
            {
                return existing
            }

            var created: VTPixelRotationSession?
            guard VTPixelRotationSessionCreate(nil, &created) == noErr, let created else {
                return nil
            }

            // Mirroring is why the direction is not obvious, and it is geometry rather than a
            // preference: the connection mirrors in the sensor's frame, about an axis that any
            // quarter turn carries onto the *other* axis. A horizontal flip of a landscape
            // frame becomes a vertical flip of the portrait one, and a vertically flipped face
            // reads as upside down rather than as a mirror. See ``turn(toReach:having:mirrored:)``,
            // which is where the choice is made and tested.
            //
            // The session's own flip properties would be the obvious tool and are not used:
            // whether they apply before or after the rotation is not documented, and picking
            // wrong is a half turn with nothing in the code to say which it was.
            VTSessionSetProperty(
                created,
                key: kVTPixelRotationPropertyKey_Rotation,
                value: turn == .clockwise ? kVTRotation_CW90 : kVTRotation_CCW90
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

            // Not a warning any more, and the difference matters to whoever reads the log.
            // This is the ordinary path for a layout change now: the connection is left
            // delivering and the turn happens here, deliberately. It is still worth a line,
            // because it is also what a connection that refused the angle looks like, and
            // the two are told apart by whether the camera was running at the time.
            logger.info(.media, "turning frames after capture", [
                LogField("width", .number(width)),
                LogField("height", .number(height)),
                LogField("turn", .text(turn == .clockwise ? "clockwise" : "anticlockwise")),
            ])

            rotation90 = created
            rotationPool = pool
            rotationSource = PixelSize(width: width, height: height)
            rotationTurn = turn
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
