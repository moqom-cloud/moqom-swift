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
    public enum CameraPosition: Sendable {
        case front
        case back

        /// Whatever the system considers default, which on a Mac is the only one.
        case system
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

        public init(format: CaptureFormat, position: CameraPosition = .front) throws {
            captureFormat = format
            relay = FrameRelay(format: format)
            super.init()

            guard let device = Self.device(for: position) else {
                throw MoqomError.platform(api: "AVCaptureDevice.default", status: -1)
            }
            let input = try AVCaptureDeviceInput(device: device)

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
#endif
