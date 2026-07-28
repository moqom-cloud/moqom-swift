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

        private let box = CaptureSessionBox()
        private let output = AVCaptureVideoDataOutput()
        private let queue = DispatchQueue(label: "moqom.camera", qos: .userInteractive)
        private let relay: FrameRelay

        /// Guards ``position`` and ``publishesMirrored``, which are read from
        /// whatever thread the interface runs on and written from there too,
        /// while the capture queue reads them to configure the session.
        private let lock = NSLock()
        private var current: CameraPosition
        private var mirrored = false
        private var input: AVCaptureDeviceInput

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

        public init(format: CaptureFormat, position: CameraPosition = .front) throws {
            captureFormat = format
            relay = FrameRelay(format: format)
            current = position

            guard let device = Self.device(for: position) else {
                throw MoqomError.platform(api: "AVCaptureDevice.default", status: -1)
            }
            input = try AVCaptureDeviceInput(device: device)
            super.init()

            let session = box.session
            session.beginConfiguration()
            defer { session.commitConfiguration() }

            guard session.canAddInput(input), session.canAddOutput(output) else {
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
            applyMirroring()
        }

        /// Open the device and begin delivering frames.
        ///
        /// The caller is responsible for having obtained camera authorisation.
        /// The SDK does not prompt: the prompt belongs where the app can
        /// explain itself, not at the moment a broadcast starts.
        public func start() {
            queue.async { [box] in
                guard !box.session.isRunning else { return }
                box.session.startRunning()
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

        public func stop() {
            relay.stop()
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

    extension CameraSource: AVCaptureVideoDataOutputSampleBufferDelegate {
        public func captureOutput(
            _: AVCaptureOutput,
            didOutput sampleBuffer: CMSampleBuffer,
            from _: AVCaptureConnection
        ) {
            guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

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
