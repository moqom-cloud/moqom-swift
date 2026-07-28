// Real frames, for the questions the synthetic scene cannot answer.
//
// The synthetic scene exists so two codecs get an identical, device-independent
// question, and for comparing latency that is the right input. It is the wrong input
// for judging a learned codec's picture. MLVC was trained on camera video, and its
// reconstruction of procedural noise says little about what it does to a face — the
// content is outside anything it saw in training, so both the quality it reaches and
// the bits it spends are unrepresentative.
//
// So this reads a real clip. It decodes with AVFoundation rather than taking raw YUV
// because a few hundred megabytes of I420 is impractical to keep on a phone, and
// because decoding from a container is what a real pipeline does anyway. The clip is
// authored at the rung's exact size, so there is no scaling here: a resampler in the
// input path would quietly become part of what is being measured.
//
// Frames are produced strictly before the timed region, and looping restarts the
// reader rather than seeking, because seeking lands on the nearest sync sample and
// would silently repeat or skip frames.

import AVFoundation
import CoreVideo
import Foundation
import MoqomCore

enum ClipError: Error, CustomStringConvertible {
    case notFound(searched: [String])
    case noVideoTrack(String)
    case wrongSize(clip: PixelSize, expected: PixelSize)
    case readFailed(String)
    case decodeStalled(frameIndex: Int)

    var description: String {
        switch self {
        case let .notFound(searched):
            "no clip found; looked for \(searched.joined(separator: ", "))"
        case let .noVideoTrack(name):
            "\(name) has no video track"
        case let .wrongSize(clip, expected):
            """
            clip is \(clip.width)x\(clip.height) but the rung is \
            \(expected.width)x\(expected.height); author the clip at the rung's size \
            rather than scaling it here
            """
        case let .readFailed(reason):
            "the clip would not decode: \(reason)"
        case let .decodeStalled(index):
            "the decoder produced nothing for frame \(index)"
        }
    }
}

/// Frames for a codec to compress.
protocol BenchSource: Sendable {
    var size: PixelSize { get }
    var frameRate: Double { get }
    func render(frameIndex: Int, into buffer: CVPixelBuffer) throws
}

/// Decodes a clip from the app's Documents directory, looping to fill a run.
///
/// A lock-guarded class rather than an actor. `CVPixelBuffer` is not `Sendable`, so an
/// actor's `render` could not take the caller's buffer without laundering it, and the
/// buffer genuinely is shared mutable state — it belongs to the codec's pool and is
/// written in place. A lock says the same thing without pretending otherwise. Only the
/// reader needs guarding, and one codec runs at a time.
final class ClipSource: BenchSource, @unchecked Sendable {
    let size: PixelSize
    let frameRate: Double
    let name: String

    private let url: URL
    private let lock = NSLock()
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?

    /// Where a clip pushed to the device lands, and where a bundled fallback would be.
    ///
    /// Same search order as the models: Documents first, so a clip can be replaced
    /// without a rebuild.
    static func candidates(for stem: String) -> [URL] {
        var urls: [URL] = []
        if let documents = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first {
            urls.append(documents.appendingPathComponent("\(stem).mp4"))
            urls.append(documents.appendingPathComponent("\(stem).mov"))
        }
        if let bundled = Bundle.main.url(forResource: stem, withExtension: "mp4") {
            urls.append(bundled)
        }
        return urls
    }

    /// Find the clip for a rung, or nil when there is none to be had.
    ///
    /// Returns nil rather than throwing so a caller can fall back to the synthetic
    /// scene: a missing clip is a reason to measure something else, not to fail a run.
    static func forRung(size: PixelSize, frameRate: Double) async -> ClipSource? {
        let stem = "real-\(size.width)x\(size.height)"
        for url in candidates(for: stem) where FileManager.default.fileExists(atPath: url.path) {
            do {
                let asset = AVURLAsset(url: url)
                guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                    continue
                }
                let natural = try await track.load(.naturalSize)
                let clip = PixelSize(
                    width: Int(natural.width.rounded()),
                    height: Int(natural.height.rounded())
                )
                guard clip == size else {
                    print("CLIP \(url.lastPathComponent) rejected: "
                        + "\(ClipError.wrongSize(clip: clip, expected: size))")
                    continue
                }
                return ClipSource(url: url, size: size, frameRate: frameRate)
            } catch {
                print("CLIP \(url.lastPathComponent) rejected: \(error)")
            }
        }
        return nil
    }

    init(url: URL, size: PixelSize, frameRate: Double) {
        self.url = url
        self.size = size
        self.frameRate = frameRate
        name = url.lastPathComponent
    }

    /// Copy the next clip frame into `buffer`, restarting the clip when it runs out.
    ///
    /// The caller's index is deliberately ignored beyond ordering. A run is longer than
    /// any clip worth shipping, so what matters is that frames arrive in order and that
    /// a loop boundary looks like a scene cut rather than a frozen frame.
    func render(frameIndex index: Int, into buffer: CVPixelBuffer) throws {
        lock.lock()
        defer { lock.unlock() }

        if reader == nil { try startReading() }
        guard let output else { throw ClipError.decodeStalled(frameIndex: index) }

        var sample = output.copyNextSampleBuffer()
        if sample == nil {
            // End of clip. Rebuild the reader; a fresh pass costs one decode of the
            // first GOP and keeps motion continuous within each pass.
            try startReading()
            sample = self.output?.copyNextSampleBuffer()
        }

        guard let sample, let source = CMSampleBufferGetImageBuffer(sample) else {
            throw ClipError.decodeStalled(frameIndex: index)
        }
        try Self.copy(source, into: buffer)
    }

    private func startReading() throws {
        reader?.cancelReading()

        let asset = AVURLAsset(url: url)
        let reader = try AVAssetReader(asset: asset)
        guard let track = asset.tracks(withMediaType: .video).first else {
            throw ClipError.noVideoTrack(name)
        }

        // Ask for the same format the camera produces and both codecs consume, so the
        // copy below is a copy and not a conversion.
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw ClipError.readFailed("the reader rejected an NV12 output")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw ClipError.readFailed(reader.error?.localizedDescription ?? "unknown")
        }

        self.reader = reader
        self.output = output
    }

    /// Plane-by-plane copy between two NV12 buffers.
    ///
    /// Row by row rather than one block: the two buffers come from different pools and
    /// need not share a stride, and copying by total byte count would shear the image
    /// whenever they disagree.
    private static func copy(_ source: CVPixelBuffer, into destination: CVPixelBuffer) throws {
        let lockSource = CVPixelBufferLockBaseAddress(source, .readOnly)
        guard lockSource == kCVReturnSuccess else {
            throw ClipError.readFailed("the decoded frame would not lock (\(lockSource))")
        }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }

        let lockDestination = CVPixelBufferLockBaseAddress(destination, [])
        guard lockDestination == kCVReturnSuccess else {
            throw ClipError.readFailed("the target frame would not lock (\(lockDestination))")
        }
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }

        let planes = min(
            CVPixelBufferGetPlaneCount(source), CVPixelBufferGetPlaneCount(destination)
        )
        for plane in 0 ..< planes {
            guard
                let from = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                let to = CVPixelBufferGetBaseAddressOfPlane(destination, plane)
            else { continue }

            let fromStride = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
            let toStride = CVPixelBufferGetBytesPerRowOfPlane(destination, plane)
            let rows = min(
                CVPixelBufferGetHeightOfPlane(source, plane),
                CVPixelBufferGetHeightOfPlane(destination, plane)
            )
            let bytes = min(fromStride, toStride)

            for row in 0 ..< rows {
                memcpy(to + row * toStride, from + row * fromStride, bytes)
            }
        }
    }
}
