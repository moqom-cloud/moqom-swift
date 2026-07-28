// Opus through AudioToolbox.
//
// Apple ships an Opus encoder inside AudioConverter, which is worth knowing
// because the alternative is vendoring libopus and every consumer of the SDK
// inheriting a C dependency. `kAudioFormatOpus` has been there since iOS 11.
//
// Two things about driving AudioConverter for a live stream:
//
//   - It pulls, rather than being pushed. The input procedure is called back
//     synchronously from inside `AudioConverterFillComplexBuffer`, so the
//     samples for a packet have to be staged before the call and the callback
//     just hands them over. This is why there is a box holding pending input
//     instead of a queue.
//   - It insists on whole packets. Opus at 48kHz wants exactly 960 frames for
//     20ms, and handing it a partial buffer produces a converter that stalls
//     rather than an error. Everything upstream therefore delivers in exact
//     packet multiples, and this type refuses anything else instead of
//     silently truncating.
//
// > Important: This compiles everywhere AudioToolbox does, and nothing in the
// > test suite runs it. It needs a real audio unit.

import Foundation
import MoqomCore

#if canImport(AudioToolbox)
    import AudioToolbox

    /// An Opus (or PCM) encoder backed by AudioToolbox.
    public actor PlatformAudioEncoder: AudioEncoder {
        public nonisolated let configuration: AudioEncoderConfiguration

        private let converter: Converter?
        private let stream: AsyncStream<EncodedAudioFrame>
        private let continuation: AsyncStream<EncodedAudioFrame>.Continuation
        private var closed = false
        private var voice: VoiceActivity

        public init(configuration: AudioEncoderConfiguration) throws {
            self.configuration = configuration
            voice = VoiceActivity(configuration: configuration.voiceActivity)
            (stream, continuation) = AsyncStream.makeStream(
                of: EncodedAudioFrame.self,
                bufferingPolicy: .bufferingNewest(16)
            )

            switch configuration.codec {
            case .pcm:
                // Nothing to convert. Kept as a real path rather than an error
                // because it is the only way to get audio out of the SDK
                // without a codec in the loop, which is what you want when
                // bisecting whether a problem is the encoder or the transport.
                converter = nil
            case .opus:
                do {
                    converter = try Converter(configuration: configuration)
                } catch {
                    continuation.finish()
                    throw error
                }
            }
        }

        deinit { continuation.finish() }

        public nonisolated func encodedFrames() -> AsyncStream<EncodedAudioFrame> { stream }

        public func encode(_ frame: AudioFrame) async throws {
            guard !closed else {
                throw MoqomError.invalidState(expected: "encoding", actual: "closed")
            }

            let expected = configuration.format.samplesPerFrame * configuration.format.channels
            guard frame.samples.count == expected else {
                // Opus has no concept of a partial packet. Accepting one would
                // either desynchronise the converter or silently change the
                // packet duration, and both surface far from here.
                throw MoqomError.invalidState(
                    expected: "\(expected) samples", actual: "\(frame.samples.count)"
                )
            }

            // Measured once per frame, before the branch, because the detector
            // is stateful: asking it twice would advance its estimate of the
            // room twice per packet, and asking it only on one branch would give
            // a codec change a different silence answer for the same audio.
            let isSilence = !voice.accept(frame)

            guard let converter else {
                var data = Data(capacity: frame.samples.count * 2)
                for sample in frame.samples {
                    let clamped = Swift.max(-1, Swift.min(1, sample))
                    let value = Int16(clamped * Float(Int16.max))
                    withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
                }
                continuation.yield(
                    EncodedAudioFrame(
                        timestamp: frame.timestamp,
                        duration: configuration.format.frameDuration,
                        data: data,
                        isSilence: isSilence
                    )
                )
                return
            }

            let encoded = try converter.encode(frame.samples)
            guard !encoded.isEmpty else { return }
            continuation.yield(
                EncodedAudioFrame(
                    timestamp: frame.timestamp,
                    duration: configuration.format.frameDuration,
                    data: encoded,
                    isSilence: isSilence
                )
            )
        }

        public func close() async {
            guard !closed else { return }
            closed = true
            converter?.dispose()
            continuation.finish()
        }
    }

    /// The AudioConverter, and the staging its callback reads from.
    ///
    /// `@unchecked Sendable` because the only concurrency here is the converter
    /// calling back into it synchronously, on the same thread, inside a call
    /// this type made. The compiler cannot see that through a C function
    /// pointer.
    private final class Converter: @unchecked Sendable {
        private var converter: AudioConverterRef?
        private var pending: [Float] = []
        private var consumed = false
        private let channels: Int
        private let framesPerPacket: Int
        private let maximumPacketSize: Int

        init(configuration: AudioEncoderConfiguration) throws {
            channels = configuration.format.channels
            framesPerPacket = configuration.format.samplesPerFrame

            var input = AudioStreamBasicDescription(
                mSampleRate: Float64(configuration.format.sampleRate),
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: UInt32(4 * channels),
                mFramesPerPacket: 1,
                mBytesPerFrame: UInt32(4 * channels),
                mChannelsPerFrame: UInt32(channels),
                mBitsPerChannel: 32,
                mReserved: 0
            )
            var output = AudioStreamBasicDescription(
                mSampleRate: Float64(configuration.format.sampleRate),
                mFormatID: kAudioFormatOpus,
                mFormatFlags: 0,
                mBytesPerPacket: 0,
                mFramesPerPacket: UInt32(framesPerPacket),
                mBytesPerFrame: 0,
                mChannelsPerFrame: UInt32(channels),
                mBitsPerChannel: 0,
                mReserved: 0
            )

            var created: AudioConverterRef?
            let status = AudioConverterNew(&input, &output, &created)
            guard status == noErr, let created else {
                throw MoqomError.platform(api: "AudioConverterNew", status: status)
            }
            converter = created

            var bitrate = UInt32(configuration.bitrate)
            AudioConverterSetProperty(
                created,
                kAudioConverterEncodeBitRate,
                UInt32(MemoryLayout<UInt32>.size),
                &bitrate
            )

            // Opus never produces more than 1275 bytes for one frame per
            // channel. Sizing the output buffer from the spec rather than the
            // bitrate means a rate-control spike cannot overrun it.
            maximumPacketSize = 1275 * channels + 16
        }

        func dispose() {
            if let converter { AudioConverterDispose(converter) }
            converter = nil
        }

        deinit { dispose() }

        func encode(_ samples: [Float]) throws -> Data {
            guard let converter else {
                throw MoqomError.invalidState(expected: "open", actual: "disposed")
            }

            pending = samples
            consumed = false

            var output = Data(count: maximumPacketSize)
            var packets: UInt32 = 1
            var description = AudioStreamPacketDescription()

            let status = output.withUnsafeMutableBytes { raw -> OSStatus in
                var buffers = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: UInt32(channels),
                        mDataByteSize: UInt32(maximumPacketSize),
                        mData: raw.baseAddress
                    )
                )
                return AudioConverterFillComplexBuffer(
                    converter,
                    { _, packetCount, bufferList, packetDescriptions, context in
                        let box = Unmanaged<Converter>
                            .fromOpaque(context!)
                            .takeUnretainedValue()
                        return box.supply(
                            packetCount: packetCount,
                            into: bufferList,
                            descriptions: packetDescriptions
                        )
                    },
                    Unmanaged.passUnretained(self).toOpaque(),
                    &packets,
                    &buffers,
                    &description
                )
            }

            // `noErr` with zero packets means the converter wants more input,
            // which cannot happen when a whole packet was supplied — but it is
            // not an error either, so it returns nothing rather than throwing.
            guard status == noErr || status == kAudioConverterErr_UnspecifiedError else {
                throw MoqomError.platform(api: "AudioConverterFillComplexBuffer", status: status)
            }
            guard packets > 0 else { return Data() }

            return output.prefix(Int(description.mDataByteSize))
        }

        /// The converter asking for input, from inside `encode`.
        private func supply(
            packetCount: UnsafeMutablePointer<UInt32>,
            into bufferList: UnsafeMutablePointer<AudioBufferList>,
            descriptions: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?
        ) -> OSStatus {
            guard !consumed else {
                packetCount.pointee = 0
                return noErr
            }
            consumed = true

            descriptions?.pointee = nil
            packetCount.pointee = UInt32(pending.count / channels)

            pending.withUnsafeMutableBufferPointer { buffer in
                bufferList.pointee.mNumberBuffers = 1
                bufferList.pointee.mBuffers.mNumberChannels = UInt32(channels)
                bufferList.pointee.mBuffers.mDataByteSize = UInt32(buffer.count * 4)
                bufferList.pointee.mBuffers.mData = UnsafeMutableRawPointer(buffer.baseAddress)
            }
            return noErr
        }
    }
#endif
