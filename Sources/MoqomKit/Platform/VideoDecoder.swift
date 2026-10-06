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
    ///
    /// An actor because a tap runs in its own task and decodes on its own schedule. The decode
    /// it wraps is not asynchronous and never was — see ``VideoDecodeSession`` — so anything
    /// that needs the pixels back on the caller's own turn takes the session directly rather
    /// than paying a hop for isolation it does not want.
    public actor PlatformVideoDecoder: VideoDecoding {
        private let assembler: SampleBufferAssembler
        private let decoder: VideoDecodeSession

        /// - Parameter pixelFormat: what the decoder should produce. The default
        ///   is the biplanar 4:2:0 the hardware already has, which both Vision
        ///   and Core ML accept without conversion.
        public init(
            codec: VideoCodec = .hevc,
            pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ) throws {
            assembler = SampleBufferAssembler(codec: codec)
            decoder = VideoDecodeSession(pixelFormat: pixelFormat)
        }

        public func decode(_ frame: EncodedFrame) async throws(MoqomError) -> VideoFrame? {
            guard let sample = try assembler.sampleBuffer(for: frame) else { return nil }
            guard let picture = try decoder.decode(sample) else { return nil }

            return VideoFrame(
                timestamp: frame.timestamp,
                size: PixelSize(
                    width: CVPixelBufferGetWidth(picture),
                    height: CVPixelBufferGetHeight(picture)
                ),
                surface: .pixelBuffer(picture)
            )
        }

        public func flush() async {
            decoder.flush()
        }

        public func close() async {
            decoder.close()
        }

        /// Adopt the codec the publisher's catalog names.
        ///
        /// Discards the session: an HEVC session is not a starting point for an
        /// H.264 one, and the parameter sets that would rebuild it have not
        /// arrived yet.
        public func setCodec(_ codec: VideoCodec) {
            assembler.setCodec(codec)
            decoder.close()
        }
    }

    /// The decompression session, and nothing else.
    ///
    /// Split out of ``PlatformVideoDecoder`` because the `async` on that type's `decode` is
    /// actor isolation and nothing else: asynchronous decompression is not enabled, so
    /// VideoToolbox runs the output handler before `VTDecompressionSessionDecodeFrame` returns.
    /// A tap does not care, but a renderer does — it draws on the main actor and cannot spend a
    /// suspension per frame to be handed pixels that were already sitting there, and a display
    /// path that awaits its own decoder has put a scheduling boundary in the middle of the one
    /// loop where lateness is the whole problem.
    ///
    /// Takes a built sample rather than an ``EncodedFrame`` for the same reason. The caller that
    /// wants this synchronously has already assembled one in order to hand it to a display
    /// layer, and assembling it twice to decode it once is work for nothing.
    ///
    /// Not `Sendable`. An actor may own one; two callers may not share one.
    final class VideoDecodeSession {
        private let pixelFormat: OSType

        private var session: Session?

        init(pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
            self.pixelFormat = pixelFormat
        }

        /// Decode one sample, synchronously.
        ///
        /// Returns `nil` when the decoder has nothing to build a picture from yet — most often
        /// a delta frame whose references were never decoded, which is the ordinary state
        /// between starting a session and the next keyframe rather than a failure.
        func decode(_ sample: CMSampleBuffer) throws(MoqomError) -> CVImageBuffer? {
            guard let description = CMSampleBufferGetFormatDescription(sample) else { return nil }

            try prepare(for: description)
            guard let session else { return nil }

            // The box exists because the handler is a block and the compiler cannot see that it
            // does not outlive the call. Reading it afterwards is only sound because the decode
            // is synchronous, which is the point of this type.
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
            return decoded
        }

        func flush() {
            guard let session else { return }
            VTDecompressionSessionFinishDelayedFrames(session.handle)
        }

        func close() {
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
    }

    /// Owns the session's lifetime.
    ///
    /// A box rather than a stored `VTDecompressionSession`, because invalidation
    /// has to happen when the decoder goes away and an actor's `deinit` cannot
    /// touch isolated state. Tying it to a reference the decoder holds means a
    /// dropped decoder releases its hardware session without anyone remembering
    /// to call ``VideoDecodeSession/close()``.
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
