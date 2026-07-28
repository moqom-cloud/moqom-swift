// The two things being compared, behind one interface.
//
// Each codec owns its own pixel buffers and never hands one out, because
// CVPixelBuffer is not Sendable and because VideoToolbox is particular about
// where its input comes from. The currency between a codec and the runner is a
// measurement, not a frame.
//
// Both paths measure a round trip on one device. That is deliberately not what a
// call does — a real broadcast encodes here and decodes somewhere else — but the
// sum is what a cohost pays, since in a room every participant does both, and
// measuring them together is the only way to see them contend for the same
// silicon.

import CoreML
import CoreVideo
import Foundation
import MoqomCore
import MoqomKit

/// One frame's worth of measurement.
struct Sample: Sendable {
    var encodeMillis: Double
    var decodeMillis: Double

    /// Compressed size. Zero where a path produces no bitstream.
    var byteCount: Int

    var isKeyFrame: Bool

    /// Reconstruction quality against the frame that went in, when the path decodes to
    /// something comparable. Nil where it does not.
    ///
    /// This is the check that tells you the integration is right. A learned codec whose
    /// state is wired up wrongly still runs at exactly the same speed and still produces
    /// plausible-looking timings — the only thing that changes is the picture, so timing
    /// numbers on their own cannot tell a working pipeline from a broken one.
    var psnr: Double?

    var totalMillis: Double { encodeMillis + decodeMillis }
}

/// What the codec was given and what it gave back, for the two preview tiles.
struct PreviewPair: Sendable {
    /// The buffer handed to the encoder, after any rotation and scaling.
    let source: VideoFrame
    /// The decoder's reconstruction, where the path produces one.
    let decoded: VideoFrame?
}

enum CodecError: Error, CustomStringConvertible {
    case noPixelBufferPool
    case noModelFound(searched: [String])
    case modelHasNoFrameInput(name: String, inputs: [String])
    case encoderProducedNothing

    var description: String {
        switch self {
        case .noPixelBufferPool:
            "the compression session did not provide a pixel buffer pool"
        case let .noModelFound(searched):
            "no compiled Core ML model in any of: \(searched.joined(separator: ", "))"
        case let .modelHasNoFrameInput(name, inputs):
            """
            \(name) declares no input a frame fits: no image, and no rank-4 tensor \
            with three channels. Its inputs are \(inputs.joined(separator: ", "))
            """
        case .encoderProducedNothing:
            "the encoder accepted a frame and emitted none"
        }
    }
}

protocol CodecUnderTest: Actor {
    nonisolated var label: String { get }

    /// Anything expensive and one-off: sessions, model loads, warm-up.
    func prepare() async throws

    /// Render frame `index` and put it through encode and decode, timing each.
    func roundTrip(frameIndex: Int, forceKeyFrame: Bool) async throws -> Sample

    func close() async
}

// MARK: - Hardware HEVC, as MOQOM actually ships it

/// The baseline: MoqomKit's own VideoToolbox encoder and decoder.
///
/// Using the SDK's types rather than a fresh compression session is the whole
/// point. A hand-rolled baseline would measure whatever settings this file chose
/// — and low-latency rate control, the keyframe interval and the temporal layer
/// configuration all move encode latency — so it would answer a question nobody
/// asked. This measures the encoder a MOQOM broadcast really uses.
actor HardwareCodec: CodecUnderTest {
    nonisolated let label: String

    private let scene: BenchSource
    private let configuration: EncoderConfiguration

    private var encoder: VideoEncoder?
    private var decoder: PlatformVideoDecoder?
    private var queue: FrameQueue?
    private var pump: Task<Void, Never>?
    private var input: CVPixelBuffer?

    /// A one-frame handoff from the encoder's output stream.
    ///
    /// `AsyncStream.Iterator` is deliberately not `Sendable`, so it cannot be held on
    /// an actor and advanced with `await` — that would send it across an isolation
    /// boundary. Instead one task owns the iterator for its whole lifetime and pushes
    /// here, leaving `roundTrip` something it can await without moving anything.
    private actor FrameQueue {
        private var buffered: [EncodedFrame] = []
        private var waiter: CheckedContinuation<EncodedFrame, Never>?

        func push(_ frame: EncodedFrame) {
            if let waiter {
                self.waiter = nil
                waiter.resume(returning: frame)
            } else {
                buffered.append(frame)
            }
        }

        func next() async -> EncodedFrame {
            if !buffered.isEmpty { return buffered.removeFirst() }
            return await withCheckedContinuation { waiter = $0 }
        }
    }

    /// Where to send frames for display, and how often.
    private let preview: (@Sendable (PreviewPair) -> Void)?
    private var lastPreview = ContinuousClock().now
    private var bridge = PreviewBridge()

    init(
        scene: BenchSource,
        codec: VideoCodec,
        layer: VideoLayer,
        preview: (@Sendable (PreviewPair) -> Void)? = nil
    ) {
        label = "\(codec.rawValue.uppercased()) hardware"
        self.scene = scene
        self.preview = preview
        configuration = EncoderConfiguration(
            layer: layer,
            codec: codec,
            // Off. Temporal layers change the reference structure and so the
            // per-frame cost, and the Core ML path has no equivalent — leaving
            // them on would put a MOQOM-specific advantage into a comparison
            // that is supposed to be about the codecs.
            usesTemporalLayers: false,
            keyFrameInterval: .seconds(2)
        )
    }

    func prepare() async throws {
        let encoder = try VideoEncoder(configuration: configuration)
        let queue = FrameQueue()
        let frames = encoder.encodedFrames()
        pump = Task { for await frame in frames { await queue.push(frame) } }
        self.queue = queue
        self.encoder = encoder
        decoder = try PlatformVideoDecoder(codec: configuration.codec)

        // Deliberately not `encoder.pixelBufferPool`. That pool's buffers use a
        // lossless-compressed format on this hardware, which the scene renderer
        // cannot write — see the note on `SyntheticScene.pool(for:format:)`. Video
        // range, matching what the session would have chosen for itself, so nothing
        // pays for a range conversion on the way in.
        guard
            let pool = SyntheticScene.pool(
                for: configuration.layer.size,
                format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ),
            let buffer = SyntheticScene.buffer(from: pool)
        else { throw CodecError.noPixelBufferPool }
        input = buffer

        // Warm up. The first frame of any session pays for allocation and, on
        // some parts, a clock ramp — charging that to the codec would put a
        // 40ms outlier in the p99 of a run that is otherwise honest.
        //
        // The first one is allowed to throw. Anything wrong with the buffers or the
        // session is wrong on frame zero, and swallowing it here only moves the
        // report of it to somewhere with less context.
        _ = try await roundTrip(frameIndex: 0, forceKeyFrame: true)
        for index in 1 ..< 8 {
            _ = try? await roundTrip(frameIndex: index, forceKeyFrame: false)
        }
    }

    func roundTrip(frameIndex index: Int, forceKeyFrame: Bool) async throws -> Sample {
        guard let encoder, let decoder, let input else { throw CodecError.encoderProducedNothing }

        // Traced on the very first frame only. Each step below is running on this
        // device for the first time, and a signal number on its own does not say
        // which one of them stopped.
        let trace = index == 0
        if trace { print("HW render size=\(scene.size.width)x\(scene.size.height)") }
        let renderStart = ContinuousClock().now
        try scene.render(frameIndex: index, into: input)
        if trace || index % 100 == 0 {
            let millis = renderStart.duration(to: ContinuousClock().now).millis
            print(String(format: "HW render cost index=%d %.1f ms", index, millis))
        }
        let frame = VideoFrame(
            timestamp: FrameTimestamp(seconds: Double(index) / scene.frameRate),
            size: scene.size,
            surface: .pixelBuffer(input),
            forcesKeyFrame: forceKeyFrame
        )

        let clock = ContinuousClock()
        let encodeStart = clock.now
        try await encoder.encode(frame, forcingKeyFrame: forceKeyFrame)
        if trace { print("HW submitted") }

        // Submit-to-output, which is the latency a publisher actually waits.
        // Sound only because low-latency rate control emits one frame per input
        // with no reordering; a session that buffered would need correlation by
        // timestamp instead.
        guard let queue else { throw CodecError.encoderProducedNothing }
        let encoded = await queue.next()
        let encodeEnd = clock.now
        if trace { print("HW encoded bytes=\(encoded.data.count) key=\(encoded.isKeyFrame)") }

        let decodeStart = clock.now
        let reconstruction = try await decoder.decode(encoded)
        let decodeEnd = clock.now

        emitPreview(source: input, reconstruction: reconstruction, at: index)
        if trace { print("HW decoded") }

        return Sample(
            encodeMillis: encodeStart.duration(to: encodeEnd).millis,
            decodeMillis: decodeStart.duration(to: decodeEnd).millis,
            byteCount: encoded.data.count,
            isKeyFrame: encoded.isKeyFrame
        )
    }

    /// Show the frame that went in and the one the decoder gave back.
    ///
    /// Throttled, because copying two frames is real work on the same core being timed.
    /// It sits outside the measured span either way, but an unthrottled preview would still
    /// slow the loop enough to change how much thermal headroom a long run has.
    private func emitPreview(
        source: CVPixelBuffer, reconstruction: VideoFrame?, at index: Int
    ) {
        guard let preview else { return }
        let now = ContinuousClock().now
        guard lastPreview.duration(to: now).millis > 100 else { return }
        lastPreview = now

        let seconds = Double(index) / scene.frameRate
        guard let sourceFrame = bridge.source(from: source, at: seconds) else { return }

        var decoded: VideoFrame?
        if let reconstruction, case let .pixelBuffer(buffer) = reconstruction.surface {
            decoded = bridge.decoded(from: buffer, at: seconds)
        }
        preview(PreviewPair(source: sourceFrame, decoded: decoded))
    }

    func close() async {
        pump?.cancel()
        pump = nil
        await encoder?.close()
        await decoder?.close()
        encoder = nil
        decoder = nil
        queue = nil
        input = nil
    }
}

// MARK: - A learned codec on the Neural Engine

/// Times MLVC's two Core ML graphs at broadcast cadence.
///
/// One honest limit, which makes this a floor rather than an estimate: it measures
/// inference and nothing else. A learned codec's bitstream comes out of an entropy
/// coder — rANS, on the CPU — and that is a separate cost this does not include. On
/// an M1 Pro the coder adds roughly 2.3ms per frame at 360p and 20ms at 1080p, so at
/// the larger rungs it is not a rounding error and the numbers here are well short of
/// what a real pipeline would pay.
///
/// It feeds zeros to every input that is not the frame. A codec in this family is
/// recurrent: it wants the previous reference features and its memory state, and with
/// zeros there it reconstructs nothing usable. That is fine for the question being
/// asked, because the shape of the computation — and therefore its cost — does not
/// depend on the values flowing through it. It would not be fine for any question
/// about quality, and nothing here should be read as one.
///
/// The decoder is a separate graph taking latents rather than a frame, so it has no
/// image input at all and every one of its inputs is zeros. Encode and decode are
/// close in cost but not identical, which is the reason for measuring both instead of
/// doubling one.
actor CoreMLCodec: CodecUnderTest {
    nonisolated let label: String

    private let scene: BenchSource
    private let modelStem: String
    private let units: MLComputeUnits

    /// Where a graph wants the frame.
    ///
    /// MLVC's exports take it as a tensor rather than an image: the encoder's `x` is
    /// `[1, 3, height, width]` of fp16, not a `CVPixelBuffer`. Both forms are handled
    /// because which one an export uses is a property of the conversion, not of the
    /// model, and a future export could switch.
    private enum FrameInput {
        case image(name: String)
        case tensor(name: String, shape: [Int], dataType: MLMultiArrayDataType)

        var name: String {
            switch self {
            case let .image(name): name
            case let .tensor(name, _, _): name
            }
        }
    }

    /// A loaded graph and the inputs it wants, ready to be handed to `prediction`.
    private struct Part {
        let model: MLModel
        /// Where the frame goes, when the graph takes one. The decoder does not.
        let frame: FrameInput?
        /// Every other input, pre-built, to be overwritten where there is real state.
        let defaults: [String: MLFeatureValue]
    }

    private var encoder: Part?
    private var decoder: Part?
    private var pool: CVPixelBufferPool?
    private var input: CVPixelBuffer?

    /// The frame tensor, allocated once and rewritten in place each frame.
    private var frameTensor: MLMultiArray?

    /// What the last frame produced, to be fed back as this frame's reference.
    ///
    /// MLVC is recurrent: the encoder's `feature` output is what it wants back as
    /// `ref_feature`, and the decoder reconstructs from the latents the encoder just
    /// emitted. This harness used to feed zeros to both, which runs the same graph at
    /// the same cost but leaves the halves unconnected — so nothing would notice if
    /// the encoder's outputs and the decoder's inputs disagreed. They are wired up
    /// now, and the shapes having to match is the point.
    private var encoderState: [String: MLFeatureValue] = [:]
    private var decoderState: [String: MLFeatureValue] = [:]

    /// The output that becomes the next frame's reference, and the input it feeds.
    private static let recurrentOutput = (from: "feature", to: "ref_feature")

    /// The encoder outputs the decoder consumes.
    private static let latentOutputs = ["z_raw", "y_raw_0", "y_raw_1"]

    /// Where to send frames for display, and how often.
    private let preview: (@Sendable (PreviewPair) -> Void)?
    private var lastPreview = ContinuousClock().now
    private var bridge = PreviewBridge()

    /// Logged once, because the tensor's real layout is the thing most likely to differ
    /// from what the shape suggests.
    private var describedOutput = false

    /// The quality level handed to the model.
    ///
    /// Zero — which is what an all-zeros default would supply — is the lowest quality the
    /// index space has, so leaving it unset would make the reconstruction look far worse
    /// than the codec is capable of and invite exactly the wrong conclusion. 42 is the
    /// midpoint of the reference's own validation sweep.
    private let qIndex: Int

    init(
        scene: BenchSource,
        modelStem: String,
        units: MLComputeUnits = .cpuAndNeuralEngine,
        qIndex: Int = 42,
        preview: (@Sendable (PreviewPair) -> Void)? = nil
    ) {
        label = "\(modelStem) (\(units.shortName))"
        self.scene = scene
        self.modelStem = modelStem
        self.units = units
        self.qIndex = qIndex
        self.preview = preview
    }

    /// Where a side-loaded model may live.
    ///
    /// The Documents directory is listed first and is the reason this is a list:
    /// a model can be pushed to the device with `devicectl` and picked up on the
    /// next run, so trying a new export does not mean a rebuild and a resign.
    private static func candidates(for name: String) -> [URL] {
        var urls: [URL] = []
        if let documents = try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ) {
            urls.append(documents.appendingPathComponent("\(name).mlmodelc"))
            urls.append(documents.appendingPathComponent("\(name).mlpackage"))
        }
        if let bundled = Bundle.main.url(forResource: name, withExtension: "mlmodelc") {
            urls.append(bundled)
        }
        if let bundled = Bundle.main.url(forResource: name, withExtension: "mlpackage") {
            urls.append(bundled)
        }
        return urls
    }

    private func load(_ name: String, configuration: MLModelConfiguration) async throws -> Part {
        let found = try Self.candidates(for: name).first { FileManager.default.fileExists(atPath: $0.path) }
        guard let found else {
            throw CodecError.noModelFound(searched: Self.candidates(for: name).map(\.path))
        }

        // A .mlpackage has to be compiled before it can be loaded. Compilation
        // is slow and cacheable, so a pre-compiled .mlmodelc is what should be
        // pushed to a device for a real run.
        let url = found.pathExtension == "mlmodelc"
            ? found
            : try await MLModel.compileModel(at: found)
        let model = try MLModel(contentsOf: url, configuration: configuration)

        let descriptions = model.modelDescription.inputDescriptionsByName
        let frame = Self.frameInput(in: descriptions)
        return Part(
            model: model,
            frame: frame,
            defaults: Self.defaults(descriptions, excluding: frame?.name)
        )
    }

    /// Find the input the frame goes into, if the graph takes one.
    ///
    /// A declared image input settles it. Failing that, the frame is the rank-4
    /// tensor with three channels: that picks `x` at `[1, 3, height, width]` and
    /// passes over `ref_feature` at `[1, 256, …]`, and it keeps working if a future
    /// export renames things. The decoder has no such input, which is correct — it
    /// reconstructs from latents.
    private static func frameInput(in descriptions: [String: MLFeatureDescription]) -> FrameInput? {
        if let image = descriptions.first(where: { $0.value.type == MLFeatureType.image })?.key {
            return .image(name: image)
        }
        for (name, description) in descriptions.sorted(by: { $0.key < $1.key }) {
            guard description.type == .multiArray,
                  let constraint = description.multiArrayConstraint
            else { continue }
            let shape = constraint.shape.map(\.intValue)
            guard shape.count == 4, shape[1] == 3 else { continue }
            return .tensor(name: name, shape: shape, dataType: constraint.dataType)
        }
        return nil
    }

    func prepare() async throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = units

        // The reference loads these graphs with the fast-prediction specialisation, and
        // the export applies a pass named `fast_prediction_workaround` to suit it. The
        // hint is part of how the model was meant to be run, not a tuning knob: without
        // it Core ML specialises for load time instead of inference time.
        if #available(iOS 18.0, *) {
            configuration.optimizationHints.specializationStrategy = .fastPrediction
        }

        let encoder = try await load("\(modelStem)-encoder", configuration: configuration)
        guard let frame = encoder.frame else {
            throw CodecError.modelHasNoFrameInput(
                name: "\(modelStem)-encoder",
                inputs: encoder.model.modelDescription.inputDescriptionsByName.keys.sorted()
            )
        }
        self.encoder = encoder
        decoder = try await load("\(modelStem)-decoder", configuration: configuration)

        if case let .tensor(_, shape, dataType) = frame {
            frameTensor = try MLMultiArray(shape: shape.map(NSNumber.init), dataType: dataType)
        }

        pool = SyntheticScene.pool(for: scene.size)
        if let pool { input = SyntheticScene.buffer(from: pool) }

        _ = try await roundTrip(frameIndex: 0, forceKeyFrame: true)
        for index in 1 ..< 8 {
            _ = try? await roundTrip(frameIndex: index, forceKeyFrame: false)
        }
    }

    /// Everything the model wants that is not the frame, as zeros.
    private static func defaults(
        _ descriptions: [String: MLFeatureDescription],
        excluding frame: String?
    ) -> [String: MLFeatureValue] {
        var values: [String: MLFeatureValue] = [:]
        for (name, description) in descriptions where name != frame {
            switch description.type {
            case .multiArray:
                guard
                    let constraint = description.multiArrayConstraint,
                    let array = try? MLMultiArray(
                        shape: constraint.shape, dataType: constraint.dataType
                    )
                else { continue }
                // MLMultiArray does not promise zeroed storage.
                for offset in 0 ..< array.count { array[offset] = 0 }
                values[name] = MLFeatureValue(multiArray: array)
            case .int64:
                values[name] = MLFeatureValue(int64: 0)
            case .double, .int64:
                values[name] = MLFeatureValue(double: 0)
            default:
                continue
            }
        }
        return values
    }

    func roundTrip(frameIndex index: Int, forceKeyFrame: Bool) async throws -> Sample {
        guard let encoder, let input else {
            throw CodecError.noModelFound(searched: Self.candidates(for: "\(modelStem)-encoder").map(\.path))
        }

        try scene.render(frameIndex: index, into: input)

        // A keyframe is where the recurrence restarts, so the state goes back to
        // zeros exactly as it would in the codec.
        if forceKeyFrame {
            encoderState = [:]
            decoderState = [:]
        }

        var features = encoder.defaults.merging(encoderState) { _, state in state }
        Self.setQuality(qIndex, in: &features)
        switch encoder.frame {
        case let .image(name):
            features[name] = MLFeatureValue(pixelBuffer: input)
        case let .tensor(name, shape, _):
            guard let frameTensor else { throw CodecError.encoderProducedNothing }
            try Self.fill(frameTensor, shape: shape, from: input)
            features[name] = MLFeatureValue(multiArray: frameTensor)
        case nil:
            break
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: features)

        // The synchronous overload, named explicitly. In an async context the compiler
        // reaches for the `async` one, which would mean sending a non-Sendable
        // `MLModel` and provider across an isolation boundary and does not compile
        // under Swift 6. Staying synchronous keeps both on this actor, and it is also
        // what we want to time: an `await` would fold suspension into the measurement.
        let predict: (MLFeatureProvider) throws -> MLFeatureProvider = encoder.model.prediction(from:)

        let clock = ContinuousClock()
        let encodeStart = clock.now
        let encoded = try predict(provider)
        let encodeEnd = clock.now

        // Carry the encoder's reference forward, and hand its latents to the decoder.
        // The names are MLVC's; a graph without them simply keeps its zeros.
        if let feature = encoded.featureValue(for: Self.recurrentOutput.from) {
            encoderState[Self.recurrentOutput.to] = feature
        }

        var decodeMillis = 0.0
        var psnr: Double?
        if let decoder {
            var inputs = decoder.defaults.merging(decoderState) { _, state in state }
            Self.setQuality(qIndex, in: &inputs)
            for name in Self.latentOutputs {
                guard let value = encoded.featureValue(for: name) else { continue }
                inputs[name] = value
            }
            let decoderProvider = try MLDictionaryFeatureProvider(dictionary: inputs)
            let decodeOnce: (MLFeatureProvider) throws -> MLFeatureProvider =
                decoder.model.prediction(from:)
            let decodeStart = clock.now
            let decoded = try decodeOnce(decoderProvider)
            decodeMillis = decodeStart.duration(to: clock.now).millis

            if let feature = decoded.featureValue(for: Self.recurrentOutput.from) {
                decoderState[Self.recurrentOutput.to] = feature
            }

            // Compare the reconstruction with what went in. Both are the same planar RGB
            // tensor layout, so this needs no colour conversion and cannot itself be the
            // thing that is wrong.
            if let reconstruction = decoded.featureValue(for: "x_hat")?.multiArrayValue,
               let source = frameTensor {
                psnr = Self.psnr(source, reconstruction)
                emitPreview(source: input, reconstruction: reconstruction, at: index)
            }
        }

        return Sample(
            encodeMillis: encodeStart.duration(to: encodeEnd).millis,
            decodeMillis: decodeMillis,
            byteCount: 0,
            isKeyFrame: forceKeyFrame,
            psnr: psnr
        )
    }

    /// Set every integer-valued input to the quality index.
    ///
    /// Matched by kind rather than by name. MLVC calls it `q_index_shifted` because the
    /// reference offsets it per frame type before handing it over, and a scalar integer
    /// input is the only thing in either graph that this could be.
    private static func setQuality(_ qIndex: Int, in features: inout [String: MLFeatureValue]) {
        for (name, value) in features {
            if let array = value.multiArrayValue,
               array.count == 1,
               array.dataType == .int32 {
                array[0] = NSNumber(value: qIndex)
                features[name] = MLFeatureValue(multiArray: array)
            } else if value.type == .int64 {
                features[name] = MLFeatureValue(int64: Int64(qIndex))
            }
        }
    }

    /// Peak signal-to-noise ratio between two planar tensors in the unit range.
    private static func psnr(_ source: MLMultiArray, _ reconstruction: MLMultiArray) -> Double? {
        guard source.count == reconstruction.count, source.count > 0 else { return nil }

        let shape = source.shape.map(\.intValue)
        guard shape.count == 4 else { return nil }
        let (channels, height, width) = (shape[1], shape[2], shape[3])

        // Indexed through each array's own strides rather than as packed memory. Core ML
        // is free to pad a row, and two arrays that agree on shape need not agree on
        // layout — reading either as dense silently compares misaligned pixels.
        let left = source.strides.map(\.intValue)
        let right = reconstruction.strides.map(\.intValue)

        var total = 0.0
        var counted = 0
        let squaredError: Double? = try? source.withUnsafeBytes { rawSource in
            try reconstruction.withUnsafeBytes { rawOther in
                guard
                    let a = rawSource.baseAddress?.assumingMemoryBound(to: Float16.self),
                    let b = rawOther.baseAddress?.assumingMemoryBound(to: Float16.self)
                else { return 0.0 }
                for c in 0 ..< channels {
                    for y in 0 ..< height {
                        let leftRow = c * left[1] + y * left[2]
                        let rightRow = c * right[1] + y * right[2]
                        for x in 0 ..< width {
                            let difference = Double(a[leftRow + x * left[3]])
                                - Double(b[rightRow + x * right[3]])
                            total += difference * difference
                            counted += 1
                        }
                    }
                }
                return total
            }
        }

        guard let squaredError, counted > 0 else { return nil }
        let meanSquared = squaredError / Double(counted)
        guard meanSquared > 0 else { return nil }
        // The tensors carry the unit range, so the peak is 1 rather than 255.
        return 10 * log10(1.0 / meanSquared)
    }

    /// Hand a decoded frame to the display, at most a few times a second.
    ///
    /// Throttled because converting and copying a frame is real work on the same core the
    /// codec is being timed on, and a preview that updated every frame would be measuring
    /// the preview.
    private func emitPreview(source: CVPixelBuffer, reconstruction: MLMultiArray, at index: Int) {
        guard let preview else { return }
        let now = ContinuousClock().now
        guard lastPreview.duration(to: now).millis > 100 else { return }
        lastPreview = now

        let seconds = Double(index) / 30
        guard let sourceFrame = bridge.source(from: source, at: seconds) else { return }

        if !describedOutput {
            describedOutput = true
            print(
                "PREVIEW shape=\(reconstruction.shape.map(\.intValue)) "
                    + "strides=\(reconstruction.strides.map(\.intValue))"
            )
        }

        preview(
            PreviewPair(
                source: sourceFrame,
                decoded: bridge.decoded(from: reconstruction, at: seconds)
            )
        )
    }

    /// Write a rendered NV12 frame into the model's `[1, 3, height, width]` tensor.
    ///
    /// Deliberately outside the timed section. The conversion is harness cost, not
    /// codec cost — a real pipeline would hand the model a buffer the camera already
    /// produced — and charging it to the encoder would flatter hardware HEVC, which
    /// takes NV12 directly.
    ///
    /// BT.601, scaled to the unit range the export declares through `pixel_range`.
    ///
    /// The range is read from the buffer rather than assumed. The synthetic scene renders
    /// into a full-range pool, while a camera and a decoded clip both hand back video
    /// range, where luma occupies 16...235 — decoding video-range luma with a full-range
    /// formula lifts the blacks and flattens the contrast, which then shows up as a lower
    /// PSNR and looks like the codec's fault.
    private static func fill(
        _ array: MLMultiArray,
        shape: [Int],
        from buffer: CVPixelBuffer
    ) throws {
        let height = shape[2]
        let width = shape[3]

        let format = CVPixelBufferGetPixelFormatType(buffer)
        let isVideoRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || format == kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange
        let lumaOffset: Float = isVideoRange ? 16 : 0
        let lumaScale: Float = isVideoRange ? 255.0 / 219.0 : 1
        let chromaScale: Float = isVideoRange ? 255.0 / 224.0 : 1

        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)
        else { return }

        let luma = lumaBase.assumingMemoryBound(to: UInt8.self)
        let chroma = chromaBase.assumingMemoryBound(to: UInt8.self)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let rows = min(height, CVPixelBufferGetHeightOfPlane(buffer, 0))
        let columns = min(width, CVPixelBufferGetWidthOfPlane(buffer, 0))

        try array.withUnsafeMutableBytes { raw, strides in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: Float16.self) else { return }
            let (channelStride, rowStride, columnStride) = (strides[1], strides[2], strides[3])

            for y in 0 ..< rows {
                let lumaRow = luma + y * lumaStride
                let chromaRow = chroma + (y / 2) * chromaStride
                for x in 0 ..< columns {
                    let luminance = (Float(lumaRow[x]) - lumaOffset) * lumaScale
                    let u = (Float(chromaRow[(x / 2) * 2]) - 128) * chromaScale
                    let v = (Float(chromaRow[(x / 2) * 2 + 1]) - 128) * chromaScale

                    let red = (luminance + 1.402 * v) / 255
                    let green = (luminance - 0.344_136 * u - 0.714_136 * v) / 255
                    let blue = (luminance + 1.772 * u) / 255

                    let offset = y * rowStride + x * columnStride
                    base[offset] = Float16(min(max(red, 0), 1))
                    base[offset + channelStride] = Float16(min(max(green, 0), 1))
                    base[offset + 2 * channelStride] = Float16(min(max(blue, 0), 1))
                }
            }
        }
    }

    func close() async {
        encoder = nil
        decoder = nil
        input = nil
        pool = nil
        frameTensor = nil
        encoderState = [:]
        decoderState = [:]
    }
}

extension MLComputeUnits {
    var shortName: String {
        switch self {
        case .cpuOnly: "CPU"
        case .cpuAndGPU: "CPU+GPU"
        case .all: "all units"
        case .cpuAndNeuralEngine: "ANE"
        @unknown default: "unknown"
        }
    }
}

extension Duration {
    /// Milliseconds as a Double, which is the unit every number here is in.
    var millis: Double {
        let parts = components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1_000_000_000_000_000
    }
}
