// VideoToolbox, running backwards.
//
// This exists because `AVSampleBufferDisplayLayer` is a black box in exactly the
// dimension a tap cares about: it decodes beautifully and it will not tell you
// what it decoded. Anything that wants pixels — a classifier, a transcriber's
// video half, a re-render, a texture in a RealityKit scene — has to own the
// decompression session, and this is that.
//
// Two things about it are worth knowing before reading the code.
//
// A decompression session is bound to a format description, and a format
// description is built from parameter sets. When the layer selector climbs a
// rung the resolution changes, which means new parameter sets, which means the
// session cannot decode the next frame and has to be rebuilt. That happens at
// exactly the moment the viewer is watching for the picture to improve, so it
// is handled rather than treated as an error.
//
// And the pixel format is a decision, not a default. Asking for NV12 gets the
// surface the hardware already produced; asking for BGRA gets a conversion pass
// on every frame that most consumers do not need, because Vision and Core ML
// both take NV12 directly. The wrong choice here is invisible in correctness
// and shows up as thermal load an hour into a stream.
//
// > Important: Compiles on every Apple platform; nothing in the test suite runs
// > it, because the simulator's decoder needs a real bitstream and the tests
// > have synthetic ones. The tap path around it is tested with an injected
// > decoder.

import Foundation
import MoqomCore

#if canImport(AVFoundation) && canImport(VideoToolbox)
    import CoreMedia
    import CoreVideo
    import VideoToolbox

    /// Hardware video decoding, one session per subscribed track.
    public actor PlatformVideoDecoder: VideoDecoding {
        private let assembler: SampleBufferAssembler
        private let pixelFormat: OSType

        private var session: Session?

        /// - Parameter pixelFormat: what the decoder should produce. The default
        ///   is the biplanar 4:2:0 the hardware already has, which both Vision
        ///   and Core ML accept without conversion.
        public init(
            codec: VideoCodec = .hevc,
            pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ) throws {
            assembler = SampleBufferAssembler(codec: codec)
            self.pixelFormat = pixelFormat
        }

        public func decode(_ frame: EncodedFrame) async throws(MoqomError) -> VideoFrame? {
            guard let sample = try assembler.sampleBuffer(for: frame) else { return nil }
            guard let description = CMSampleBufferGetFormatDescription(sample) else { return nil }

            try prepare(for: description)
            guard let session else { return nil }

            // Synchronous: asynchronous decompression is not enabled, so the
            // handler runs before the call returns. Worth being explicit about,
            // because reading the box afterwards is only sound because of it.
            // The box exists because the handler is a block and the compiler
            // cannot see that it does not outlive the call.
            let output = Output()
            let status = VTDecompressionSessionDecodeFrame(
                session.handle,
                sampleBuffer: sample,
                flags: [],
                infoFlagsOut: nil
            ) { code, _, image, _, _ in
                if code == noErr { output.image = image }
            }

            // A single frame the decoder refuses is not a broken decoder. The
            // common cause is a delta frame whose references were lost, and the
            // recovery is the next keyframe rather than anything a caller could
            // do.
            guard status == noErr, let decoded = output.image else { return nil }

            return VideoFrame(
                timestamp: frame.timestamp,
                size: PixelSize(
                    width: CVPixelBufferGetWidth(decoded),
                    height: CVPixelBufferGetHeight(decoded)
                ),
                surface: .pixelBuffer(decoded)
            )
        }

        public func flush() async {
            guard let session else { return }
            VTDecompressionSessionFinishDelayedFrames(session.handle)
        }

        public func close() async {
            session = nil
        }

        /// Build a session, or rebuild it when the format changed.
        private func prepare(for description: CMFormatDescription) throws(MoqomError) {
            if
                let session,
                VTDecompressionSessionCanAcceptFormatDescription(
                    session.handle,
                    formatDescription: description
                )
            {
                return
            }
            session = nil

            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: pixelFormat,
                // IOSurface-backed, so the frame can go to a Metal pass or a
                // Vision request without a copy — which is the entire reason a
                // tap is affordable at video rates.
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]

            var created: VTDecompressionSession?
            let status = VTDecompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                formatDescription: description,
                decoderSpecification: nil,
                imageBufferAttributes: attributes as CFDictionary,
                outputCallback: nil,
                decompressionSessionOut: &created
            )
            guard status == noErr, let created else {
                throw MoqomError.platform(api: "VTDecompressionSessionCreate", status: status)
            }

            // Real time, because everything here is live. The alternative tells
            // VideoToolbox it may take its time to produce a better picture,
            // which is correct for a file and a latency bug for a call.
            VTSessionSetProperty(
                created,
                key: kVTDecompressionPropertyKey_RealTime,
                value: kCFBooleanTrue
            )

            session = Session(handle: created)
        }

        /// Adopt the codec the publisher's catalog names.
        ///
        /// Discards the session: an HEVC session is not a starting point for an
        /// H.264 one, and the parameter sets that would rebuild it have not
        /// arrived yet.
        public func setCodec(_ codec: VideoCodec) {
            assembler.setCodec(codec)
            session = nil
        }
    }

    /// Owns the session's lifetime.
    ///
    /// A box rather than a stored `VTDecompressionSession`, because invalidation
    /// has to happen when the decoder goes away and an actor's `deinit` cannot
    /// touch isolated state. Tying it to a reference the actor holds means a
    /// dropped decoder releases its hardware session without anyone remembering
    /// to call ``PlatformVideoDecoder/close()``.
    private final class Session: @unchecked Sendable {
        let handle: VTDecompressionSession

        init(handle: VTDecompressionSession) {
            self.handle = handle
        }

        deinit { VTDecompressionSessionInvalidate(handle) }
    }

    /// Catches the one frame the synchronous handler produces.
    private final class Output: @unchecked Sendable {
        var image: CVImageBuffer?
    }
#endif
