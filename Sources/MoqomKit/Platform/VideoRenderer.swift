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
        private let codec: VideoCodec

        public init(codec: VideoCodec = .hevc) {
            self.codec = codec
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

            // Without this the layer buffers against a master clock that was
            // never set, and the first frame sits there until the second
            // arrives.
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

        public init(codec: VideoCodec = .hevc) {
            assembler = SampleBufferAssembler(codec: codec)
            // The publisher's clock, not ours. Rate control belongs upstream:
            // a viewer that resamples to its own clock reintroduces the buffer
            // the whole stack exists to avoid.
            layer.videoGravity = .resizeAspectFill
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
                return
            }
            guard
                renderer.isReadyForMoreMediaData,
                let sample = try assembler.sampleBuffer(for: frame)
            else { return }

            renderer.enqueue(sample)
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
        }
    }
#endif
