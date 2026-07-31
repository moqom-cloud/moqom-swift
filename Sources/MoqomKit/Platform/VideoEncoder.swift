// The hardware encoder.
//
// Three settings separate a conferencing encoder from a file encoder, and
// getting any of them wrong costs latency that no amount of transport work
// gets back:
//
//   - Low-latency rate control. Without it VideoToolbox targets a bitrate over
//     a window and will happily spend a second of buffering to hit it.
//   - No frame reordering. B-frames mean the decoder cannot emit a frame until
//     it has seen a later one, which is a structural delay in the codec.
//   - A keyframe interval that exists at all, so a joiner is not waiting on the
//     publisher's next scene change.
//
// Temporal layering is the other reason to be here. Asking the encoder for a
// base layer at half the frame rate produces a stream where the odd frames are
// depended on by nothing, so the relay can drop them under congestion and the
// result is a lower frame rate rather than a corrupt one. That is a property of
// the bitstream, not of the relay, and it has to be requested at encode time.

import Foundation
import MoqomCore

#if canImport(VideoToolbox)
    import CoreMedia
    import CoreVideo
    import VideoToolbox

    /// A hardware compression session for one rung of the ladder.
    ///
    /// One session per rung rather than one session downscaled per frame: the
    /// hardware encoder is a fixed resource, and simulcast means the sessions
    /// are what the ladder is made of. Sessions are also why
    /// ``BroadcastConfiguration/stopsUnwatchedLayers`` is worth having — an
    /// unwatched rung holds one of a handful of them.
    ///
    /// > Important: This type is written against VideoToolbox and compiles on
    /// > every Apple platform, but nothing in the package's test suite runs it.
    /// > It needs a GPU and, in practice, a device.
    public actor VideoEncoder: FrameEncoder {
        public nonisolated let configuration: EncoderConfiguration

        /// Whether the session got the low-latency rate controller.
        ///
        /// False means this encoder is targeting its bitrate over a window and
        /// may buffer to hit it, which is a latency floor the transport cannot
        /// undo. The simulator is the case that makes this worth exposing
        /// rather than fataling: it has an encoder for both codecs and no
        /// low-latency one for either, so refusing outright would mean the SDK
        /// cannot encode anything without a device.
        public nonisolated let usesLowLatencyRateControl: Bool

        private let box: SessionBox
        private nonisolated var session: VTCompressionSession { box.session }
        private let stream: AsyncStream<EncodedFrame>
        private let continuation: AsyncStream<EncodedFrame>.Continuation
        private var isClosed = false

        public init(configuration: EncoderConfiguration) throws {
            self.configuration = configuration
            (stream, continuation) = AsyncStream.makeStream(
                of: EncodedFrame.self,
                bufferingPolicy: .bufferingNewest(8)
            )

            // Requested on the specification rather than as a property, because
            // it selects a different rate control implementation and cannot be
            // switched on after the session exists. Which is also why the
            // fallback has to be a second create rather than a property set.
            var created: VTCompressionSession?
            var status = Self.create(&created, for: configuration, lowLatency: true)
            let lowLatency = status == noErr

            // `kVTCouldNotFindVideoEncoderErr` here means "no low-latency
            // encoder for this codec", not "no encoder": the plain session
            // still builds. Any other failure is a real one and is not retried,
            // because a second create would only turn a diagnosable status into
            // a confusing one.
            if status == kVTCouldNotFindVideoEncoderErr {
                status = Self.create(&created, for: configuration, lowLatency: false)
            }

            guard status == noErr, let created else {
                continuation.finish()
                throw MoqomError.platform(api: "VTCompressionSessionCreate", status: status)
            }
            usesLowLatencyRateControl = lowLatency
            box = SessionBox(session: created)

            try Self.configure(created, with: configuration)
        }

        deinit { continuation.finish() }

        /// Encoded output, in presentation order.
        ///
        /// Ordering holds only because frame reordering is off; with B-frames
        /// this would need a reorder buffer and would no longer be a stream you
        /// can forward as it arrives.
        public nonisolated func encodedFrames() -> AsyncStream<EncodedFrame> { stream }

        /// The pool a caller should draw pixel buffers from.
        ///
        /// Using it is not an optimisation. A buffer allocated anywhere else
        /// may be missing an attribute the encoder needs and will be copied
        /// through a `VTPixelTransferSession` on every single frame — which
        /// never surfaces as an error, only as power draw.
        public nonisolated var pixelBufferPool: CVPixelBufferPool? {
            VTCompressionSessionGetPixelBufferPool(session)
        }

        /// Submit one frame.
        ///
        /// Returns once VideoToolbox has accepted the frame, which is not when
        /// it has been encoded — output arrives on ``encodedFrames()``.
        public func encode(_ frame: VideoFrame, forcingKeyFrame: Bool = false) async throws {
            guard !isClosed else {
                throw MoqomError.invalidState(expected: "encoding", actual: "closed")
            }
            guard case let .pixelBuffer(buffer) = frame.surface else {
                // A synthetic frame has no pixels; the loopback path uses those
                // and never reaches an encoder.
                throw MoqomError.unsupportedCodec(configuration.codec)
            }

            var properties: [CFString: Any]?
            if forcingKeyFrame || frame.forcesKeyFrame {
                properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue as Any]
            }

            let sink = continuation
            let status = VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: buffer,
                presentationTimeStamp: frame.timestamp.cmTime,
                duration: .invalid,
                frameProperties: properties as CFDictionary?,
                infoFlagsOut: nil,
                outputHandler: { status, _, sample in
                    guard status == noErr, let sample else { return }
                    if let encoded = Self.encodedFrame(from: sample) {
                        sink.yield(encoded)
                    }
                }
            )
            guard status == noErr else {
                throw MoqomError.platform(api: "VTCompressionSessionEncodeFrame", status: status)
            }
        }

        /// Change the target bitrate without rebuilding the session.
        ///
        /// The rung's resolution is fixed for the life of the session, so this
        /// is the only knob congestion control has here; a resolution change is
        /// a different rung.
        public func setBitrate(_ bitsPerSecond: Int) throws {
            try Self.set(
                kVTCompressionPropertyKey_AverageBitRate,
                to: bitsPerSecond as CFNumber,
                on: session
            )
        }

        /// Flush and finish the output stream.
        public func close() async {
            guard !isClosed else { return }
            isClosed = true
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            continuation.finish()
        }

        private static func create(
            _ session: inout VTCompressionSession?,
            for configuration: EncoderConfiguration,
            lowLatency: Bool
        ) -> OSStatus {
            let specification: [CFString: Any] = lowLatency
                ? [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue as Any]
                : [:]
            return VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                width: Int32(configuration.layer.size.width),
                height: Int32(configuration.layer.size.height),
                codecType: codecType(configuration.codec),
                encoderSpecification: specification.isEmpty ? nil : specification as CFDictionary,
                imageBufferAttributes: nil,
                compressedDataAllocator: nil,
                outputCallback: nil,
                refcon: nil,
                compressionSessionOut: &session
            )
        }

        private static func codecType(_ codec: VideoCodec) -> CMVideoCodecType {
            switch codec {
            case .h264: kCMVideoCodecType_H264
            case .hevc: kCMVideoCodecType_HEVC
            }
        }

        private static func configure(
            _ session: VTCompressionSession,
            with configuration: EncoderConfiguration
        ) throws {
            try set(kVTCompressionPropertyKey_RealTime, to: kCFBooleanTrue, on: session)
            try set(
                kVTCompressionPropertyKey_AllowFrameReordering,
                to: kCFBooleanFalse,
                on: session
            )
            try set(
                kVTCompressionPropertyKey_AverageBitRate,
                to: configuration.layer.bitrate as CFNumber,
                on: session
            )
            try set(
                kVTCompressionPropertyKey_ExpectedFrameRate,
                to: configuration.layer.frameRate as CFNumber,
                on: session
            )

            // Asked for, not required: the encoder is free to decline, and declining is not a
            // fault. Where it is honoured the hardware trades a little quality at the same
            // bitrate for measurably less power, which on a phone holding sixty frames a second,
            // a camera, a radio and a display is the difference between a call that stays at
            // nominal and one that throttles the camera twenty minutes in. Best effort with
            // `try?` because it did not exist before iOS 17 and older systems refuse it.
            try? set(
                kVTCompressionPropertyKey_MaximizePowerEfficiency,
                to: kCFBooleanTrue,
                on: session
            )

            let interval = configuration.keyFrameInterval.totalSeconds
            try set(
                kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                to: interval as CFNumber,
                on: session
            )

            if configuration.usesTemporalLayers {
                // Half the frames become a base layer nothing else references.
                // Best effort: hardware that cannot produce the split ignores
                // this, which is why the temporal layer of an output frame is
                // read back from the sample rather than assumed.
                try? set(
                    kVTCompressionPropertyKey_BaseLayerFrameRateFraction,
                    to: 0.5 as CFNumber,
                    on: session
                )
            }

            VTCompressionSessionPrepareToEncodeFrames(session)
        }

        private static func set(
            _ key: CFString,
            to value: CFTypeRef?,
            on session: VTCompressionSession
        ) throws {
            let status = VTSessionSetProperty(session, key: key, value: value)
            guard status == noErr else {
                throw MoqomError.platform(api: "VTSessionSetProperty(\(key))", status: status)
            }
        }

        private static func encodedFrame(from sample: CMSampleBuffer) -> EncodedFrame? {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }

            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            guard
                CMBlockBufferGetDataPointer(
                    block,
                    atOffset: 0,
                    lengthAtOffsetOut: nil,
                    totalLengthOut: &length,
                    dataPointerOut: &pointer
                ) == noErr,
                let pointer
            else { return nil }

            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sample,
                createIfNecessary: false
            ) as? [[CFString: Any]]
            let first = attachments?.first

            // Absence means sync, so the default when the attachment is missing
            // has to be `true` rather than `false`.
            let isKeyFrame = !((first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
            let dependedOn = (first?[kCMSampleAttachmentKey_IsDependedOnByOthers] as? Bool) ?? true

            let timestamp = CMSampleBufferGetPresentationTimeStamp(sample)
            let nanoseconds = UInt64(max(0, CMTimeGetSeconds(timestamp)) * 1_000_000_000)

            return EncodedFrame(
                timestamp: FrameTimestamp(nanoseconds: nanoseconds),
                isKeyFrame: isKeyFrame,
                temporalLayer: dependedOn ? 0 : 1,
                data: Data(bytes: pointer, count: length),
                parameterSets: isKeyFrame ? parameterSets(from: sample) : []
            )
        }

        private static func parameterSets(from sample: CMSampleBuffer) -> [Data] {
            guard let format = CMSampleBufferGetFormatDescription(sample) else { return [] }

            var count = 0
            let probe = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                format,
                parameterSetIndex: 0,
                parameterSetPointerOut: nil,
                parameterSetSizeOut: nil,
                parameterSetCountOut: &count,
                nalUnitHeaderLengthOut: nil
            )
            let isHEVC = probe == noErr
            if !isHEVC {
                guard
                    CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                        format,
                        parameterSetIndex: 0,
                        parameterSetPointerOut: nil,
                        parameterSetSizeOut: nil,
                        parameterSetCountOut: &count,
                        nalUnitHeaderLengthOut: nil
                    ) == noErr
                else { return [] }
            }

            var sets: [Data] = []
            for index in 0 ..< count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                let status = isHEVC
                    ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                        format,
                        parameterSetIndex: index,
                        parameterSetPointerOut: &pointer,
                        parameterSetSizeOut: &size,
                        parameterSetCountOut: nil,
                        nalUnitHeaderLengthOut: nil
                    )
                    : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                        format,
                        parameterSetIndex: index,
                        parameterSetPointerOut: &pointer,
                        parameterSetSizeOut: &size,
                        parameterSetCountOut: nil,
                        nalUnitHeaderLengthOut: nil
                    )
                guard status == noErr, let pointer else { continue }
                sets.append(Data(bytes: pointer, count: size))
            }
            return sets
        }
    }

    /// Carries the session across the actor boundary.
    ///
    /// `@unchecked` because `VTCompressionSession` is a CoreFoundation type
    /// with no concurrency annotation. VideoToolbox documents sessions as safe
    /// to use from any thread, and the pixel buffer pool in particular has to
    /// be reachable from a render callback that cannot await.
    private final class SessionBox: @unchecked Sendable {
        let session: VTCompressionSession

        init(session: VTCompressionSession) { self.session = session }

        deinit { VTCompressionSessionInvalidate(session) }
    }

    private extension Duration {
        var totalSeconds: Double {
            Double(components.seconds) + Double(components.attoseconds) / 1e18
        }
    }
#endif
