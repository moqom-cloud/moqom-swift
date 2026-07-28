// Opus back to samples, and samples to a speaker.
//
// The mirror of `PlatformAudioEncoder`, with one asymmetry that matters. The
// encoder is handed whole packets and produces whole packets, so it needs no
// state between calls. The decoder has to answer for slots where nothing
// arrived, and a decoder that returned nothing for those would leave the audio
// device with a hole — which is worse than concealment, because a hole in the
// callback is a click and concealment is a smudge.
//
// So the loss cases are handled here rather than left to the caller:
//
//   - A gap is concealed by fading the previous packet's samples. Crude next to
//     what Opus's own PLC does, and chosen because AudioConverter gives no
//     access to it; the alternative is silence, which is more audible.
//   - Silence is exactly zero samples, not a concealment. The publisher meant
//     it, so reproducing it is correct and fading into it would sound like the
//     line dropping.
//
// > Important: This compiles everywhere AudioToolbox and AVFAudio do, and
// > nothing in the test suite runs it. It needs a real audio unit and an output
// > device.

import Foundation
import MoqomCore

#if canImport(AudioToolbox)
    import AudioToolbox

    /// Turns compressed packets back into interleaved float samples.
    public actor PlatformAudioDecoder {
        public nonisolated let format: AudioFormat

        private let converter: Decoder?

        /// The last real packet's samples, for concealing the next gap.
        private var previous: [Float] = []

        public init(format: AudioFormat = .voice, codec: MoqomCore.AudioCodec = .opus) throws {
            self.format = format
            switch codec {
            case .pcm:
                converter = nil
            case .opus:
                converter = try Decoder(format: format)
            }
        }

        /// Decode whatever the jitter buffer produced for one slot.
        ///
        /// Always returns a slot's worth of samples, because the audio device
        /// always needs one.
        public func decode(_ output: JitterBufferOutput) -> [Float] {
            let count = format.samplesPerFrame * format.channels

            switch output {
            case let .packet(packet):
                let samples = decode(packet.data) ?? conceal(count: count)
                previous = samples
                return samples

            case .silence:
                previous = []
                return [Float](repeating: 0, count: count)

            case .gap:
                // Faded rather than repeated. A repeated packet is a buzz at the
                // packet rate, which is more noticeable than the level dropping.
                let concealed = conceal(count: count)
                previous = concealed
                return concealed

            case .buffering:
                return [Float](repeating: 0, count: count)
            }
        }

        private func decode(_ data: Data) -> [Float]? {
            guard let converter else {
                // PCM: little-endian 16-bit, as the encoder wrote it.
                var samples: [Float] = []
                samples.reserveCapacity(data.count / 2)
                var index = data.startIndex
                while index + 1 < data.endIndex {
                    let low = UInt16(data[index])
                    let high = UInt16(data[index + 1])
                    let value = Int16(bitPattern: high << 8 | low)
                    samples.append(Float(value) / Float(Int16.max))
                    index += 2
                }
                return samples
            }
            return try? converter.decode(data)
        }

        /// Fade the previous slot toward zero.
        private func conceal(count: Int) -> [Float] {
            guard !previous.isEmpty else { return [Float](repeating: 0, count: count) }
            var faded = [Float](repeating: 0, count: count)
            for index in 0 ..< min(count, previous.count) {
                let decay = 1 - Float(index) / Float(count)
                faded[index] = previous[index] * decay * 0.5
            }
            return faded
        }
    }

    /// The AudioConverter, running the other way.
    ///
    /// `@unchecked Sendable` for the same reason as the encoder's: the only
    /// concurrency is a synchronous callback the converter makes on this
    /// thread, from inside a call this type made, which the compiler cannot see
    /// through a C function pointer.
    private final class Decoder: @unchecked Sendable {
        private var converter: AudioConverterRef?
        private var pending = Data()
        private var description = AudioStreamPacketDescription()
        private var consumed = false
        private let channels: Int
        private let framesPerPacket: Int

        init(format: AudioFormat) throws {
            channels = format.channels
            framesPerPacket = format.samplesPerFrame

            var input = AudioStreamBasicDescription(
                mSampleRate: Float64(format.sampleRate),
                mFormatID: kAudioFormatOpus,
                mFormatFlags: 0,
                mBytesPerPacket: 0,
                mFramesPerPacket: UInt32(framesPerPacket),
                mBytesPerFrame: 0,
                mChannelsPerFrame: UInt32(channels),
                mBitsPerChannel: 0,
                mReserved: 0
            )
            var output = AudioStreamBasicDescription(
                mSampleRate: Float64(format.sampleRate),
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: UInt32(4 * channels),
                mFramesPerPacket: 1,
                mBytesPerFrame: UInt32(4 * channels),
                mChannelsPerFrame: UInt32(channels),
                mBitsPerChannel: 32,
                mReserved: 0
            )

            var created: AudioConverterRef?
            let status = AudioConverterNew(&input, &output, &created)
            guard status == noErr, let created else {
                throw MoqomError.platform(api: "AudioConverterNew", status: status)
            }
            converter = created
        }

        func dispose() {
            if let converter { AudioConverterDispose(converter) }
            converter = nil
        }

        deinit { dispose() }

        func decode(_ data: Data) throws -> [Float] {
            guard let converter else {
                throw MoqomError.invalidState(expected: "open", actual: "disposed")
            }

            pending = data
            consumed = false
            description = AudioStreamPacketDescription(
                mStartOffset: 0,
                mVariableFramesInPacket: 0,
                mDataByteSize: UInt32(data.count)
            )

            var samples = [Float](repeating: 0, count: framesPerPacket * channels)
            var frames = UInt32(framesPerPacket)

            let status = samples.withUnsafeMutableBufferPointer { buffer -> OSStatus in
                var buffers = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: UInt32(channels),
                        mDataByteSize: UInt32(buffer.count * 4),
                        mData: UnsafeMutableRawPointer(buffer.baseAddress)
                    )
                )
                return AudioConverterFillComplexBuffer(
                    converter,
                    { _, packetCount, bufferList, packetDescriptions, context in
                        let box = Unmanaged<Decoder>
                            .fromOpaque(context!)
                            .takeUnretainedValue()
                        return box.supply(
                            packetCount: packetCount,
                            into: bufferList,
                            descriptions: packetDescriptions
                        )
                    },
                    Unmanaged.passUnretained(self).toOpaque(),
                    &frames,
                    &buffers,
                    nil
                )
            }

            guard status == noErr else {
                throw MoqomError.platform(api: "AudioConverterFillComplexBuffer", status: status)
            }
            return Array(samples.prefix(Int(frames) * channels))
        }

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
            packetCount.pointee = 1

            withUnsafeMutablePointer(to: &description) { descriptions?.pointee = $0 }
            pending.withUnsafeMutableBytes { raw in
                bufferList.pointee.mNumberBuffers = 1
                bufferList.pointee.mBuffers.mNumberChannels = UInt32(channels)
                bufferList.pointee.mBuffers.mDataByteSize = UInt32(raw.count)
                bufferList.pointee.mBuffers.mData = raw.baseAddress
            }
            return noErr
        }
    }
#endif
