// Live camera frames as the thing being compressed.
//
// The synthetic scene is the right input for comparing two codecs' latency, because it
// asks both the identical question on every device. It is the wrong input for judging a
// learned codec's picture: MLVC was trained on camera video, so its reconstruction of
// procedural noise says nothing about what it does to a face, and a reconstruction you
// cannot recognise tells you nothing about whether the integration is correct.
//
// The camera is the opposite trade. Content changes run to run, so timings drift with
// the lighting and with how much you moved — worth knowing before comparing numbers
// across runs. What it buys is a picture you already know, which makes a wrong
// reconstruction obvious at a glance instead of arguable.
//
// Two adaptations stand between the camera and a rung, and neither is on the CPU: a
// quarter turn, because a phone held upright still captures landscape, and a scale,
// because the camera's formats are 1920x1080 and friends while the models want sizes that
// are multiples of 64. Both happen in one VideoToolbox pixel transfer.

import AVFoundation
import CoreVideo
import Foundation
import MoqomCore
import MoqomKit
import VideoToolbox

enum CameraBenchError: Error, CustomStringConvertible {
    case denied
    case noFrames(waited: Double)
    case transferFailed(OSStatus)

    var description: String {
        switch self {
        case .denied:
            "camera access was refused"
        case let .noFrames(waited):
            "the camera delivered no frame within \(Int(waited * 1000)) ms"
        case let .transferFailed(status):
            "the frame could not be scaled to the rung (VTPixelTransfer \(status))"
        }
    }
}

/// Feeds the codecs whatever the camera is seeing, scaled to the rung.
final class CameraBenchSource: BenchSource, @unchecked Sendable {
    let size: PixelSize
    let frameRate: Double

    private let camera: CameraSource
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var pump: Task<Void, Never>?
    private var transfer: VTPixelTransferSession?
    private var rotation: VTPixelRotationSession?
    private var upright: CVPixelBufferPool?
    private var uprightSize: PixelSize?

    /// Frames handed to a codec that were the same capture as the one before.
    ///
    /// Worth reporting rather than hiding. Where a codec runs faster than the camera
    /// delivers, it gets handed a repeat, and a repeated frame is nearly free to encode —
    /// so a high count means the timings flatter the codec.
    private var repeats = 0
    private var served = 0

    /// A description of what the camera actually produced, which is not necessarily what
    /// it was asked for.
    private(set) var captured: PixelSize?

    var summary: String {
        lock.withLock {
            let source = captured.map { "\($0.width)x\($0.height)" } ?? "starting"
            return "camera \(source) → \(size.width)x\(size.height), "
                + "\(repeats)/\(served) repeated"
        }
    }

    init(size: PixelSize, frameRate: Double, position: CameraPosition = .front) throws {
        self.size = size
        self.frameRate = frameRate

        // Asked for the rung, but the camera will pick its own nearest format; the
        // transfer session below reconciles the two.
        camera = try CameraSource(
            format: CaptureFormat(size: size, frameRate: frameRate), position: position
        )
    }

    /// Ask for access and begin capturing.
    static func authorized() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    func start() {
        camera.start()
        let stream = camera.frames()
        pump = Task { [weak self] in
            for await frame in stream {
                guard let self else { return }
                guard case let .pixelBuffer(buffer) = frame.surface else { continue }
                store(buffer, size: frame.size)
            }
        }
    }

    func stop() {
        pump?.cancel()
        pump = nil
        camera.stop()
        lock.withLock { latest = nil }
    }

    private func store(_ buffer: CVPixelBuffer, size captured: PixelSize) {
        lock.withLock {
            latest = buffer
            if self.captured != captured { self.captured = captured }
        }
    }

    /// Copy the most recent capture into `buffer`, scaling it to the rung.
    ///
    /// Takes the newest frame rather than queueing. A benchmark wants to know what the
    /// codec does with live input, and a queue would let the codec fall behind the camera
    /// and then measure it compressing history.
    func render(frameIndex _: Int, into buffer: CVPixelBuffer) throws {
        let source = try waitForFrame()
        let upright = try turned(source)

        let session = try transferSession()
        let status = VTPixelTransferSessionTransferImage(session, from: upright, to: buffer)
        guard status == noErr else { throw CameraBenchError.transferFailed(status) }
    }

    /// The capture stood upright, since a phone held upright still captures landscape.
    ///
    /// A pass of its own because VideoToolbox separates the two operations: a rotation
    /// session's destination has to be exactly the source with its axes swapped, so it
    /// cannot also scale, and the transfer session that scales cannot rotate. Both run on
    /// the GPU and both sit outside the codec's timing.
    ///
    /// This is not where it looks like it belongs. Rotating at the capture connection would
    /// cost nothing at all, but `AVCaptureConnection.videoRotationAngle` reports itself
    /// unsupported for this video data output and the request is silently dropped — the
    /// camera goes on delivering 1920x1080. Stretching that into a portrait rung is a
    /// picture both turned on its side and softer than the codec deserves blame for.
    private func turned(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
        let rotated = PixelSize(
            width: CVPixelBufferGetHeight(source), height: CVPixelBufferGetWidth(source)
        )
        let pool = try uprightPool(for: rotated, like: source)

        var destination: CVPixelBuffer?
        guard
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destination)
                == kCVReturnSuccess,
            let destination
        else { throw CameraBenchError.transferFailed(kCVReturnAllocationFailed) }

        let status = VTPixelRotationSessionRotateImage(
            try rotationSession(), source, destination
        )
        guard status == noErr else { throw CameraBenchError.transferFailed(status) }
        return destination
    }

    private func rotationSession() throws -> VTPixelRotationSession {
        if let rotation { return rotation }
        var created: VTPixelRotationSession?
        let status = VTPixelRotationSessionCreate(nil, &created)
        guard status == noErr, let created else {
            throw CameraBenchError.transferFailed(status)
        }

        VTSessionSetProperty(
            created, key: kVTPixelRotationPropertyKey_Rotation, value: kVTRotation_CW90
        )
        rotation = created
        return created
    }

    private func uprightPool(
        for rotated: PixelSize, like source: CVPixelBuffer
    ) throws -> CVPixelBufferPool {
        if let upright, uprightSize == rotated { return upright }

        var created: CVPixelBufferPool?
        let attributes: [String: Any] = [
            kCVPixelBufferWidthKey as String: rotated.width,
            kCVPixelBufferHeightKey as String: rotated.height,
            kCVPixelBufferPixelFormatTypeKey as String:
                CVPixelBufferGetPixelFormatType(source),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        guard
            CVPixelBufferPoolCreate(
                kCFAllocatorDefault, nil, attributes as CFDictionary, &created
            ) == kCVReturnSuccess,
            let created
        else { throw CameraBenchError.transferFailed(kCVReturnAllocationFailed) }

        upright = created
        uprightSize = rotated
        return created
    }

    /// The most recent capture, waiting for the first one to arrive.
    ///
    /// Only the first call really waits: a camera takes far longer to warm up than a frame
    /// interval, and failing the run over that would be useless.
    private func waitForFrame() throws -> CVPixelBuffer {
        let timeout = 5.0
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let frame = take() { return frame }
            Thread.sleep(forTimeInterval: 0.01)
        } while Date() < deadline
        throw CameraBenchError.noFrames(waited: timeout)
    }

    /// Claim the latest capture, counting it as a repeat if it is the one already served.
    private func take() -> CVPixelBuffer? {
        lock.withLock {
            guard let latest else { return nil }
            if lastServed === latest { repeats += 1 }
            lastServed = latest
            served += 1
            return latest
        }
    }

    /// The capture handed over last, to recognise a repeat.
    private var lastServed: CVPixelBuffer?

    /// VideoToolbox's scaler, created once.
    ///
    /// It handles the format and size difference between the camera's active format and
    /// the rung on the GPU, so it does not land in the codec's timing.
    private func transferSession() throws -> VTPixelTransferSession {
        if let transfer { return transfer }
        var created: VTPixelTransferSession?
        let status = VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &created)
        guard status == noErr, let created else {
            throw CameraBenchError.transferFailed(status)
        }

        // Fill the rung rather than letterboxing into it. A black border would be free to
        // encode and would flatter every codec. Rotated, the camera's 16:9 matches the
        // portrait rungs exactly, so this is a clean downscale rather than a stretch.
        VTSessionSetProperty(
            created,
            key: kVTPixelTransferPropertyKey_ScalingMode,
            value: kVTScalingMode_Normal
        )
        transfer = created
        return created
    }
}
