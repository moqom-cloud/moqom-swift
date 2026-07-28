// The app around the measurement.
//
// Deliberately plain. Every control here corresponds to a variable that changes
// the answer, and nothing here is a preference — a run that cannot be described
// by this screen is a run whose numbers cannot be compared with another one.

import AVFoundation
import CoreML
import MoqomCore
import MoqomKit
import SwiftUI

@main
struct CodecBenchApp: App {
    var body: some Scene {
        WindowGroup {
            BenchView()
                .preferredColorScheme(.dark)
        }
    }
}

/// What the run was asked to do, from launch arguments when there are any.
///
/// Exists so a run can be driven from a script rather than a thumb. Sweeping four
/// rungs by hand means four chances to leave a toggle in the wrong place, and the
/// resulting numbers are not comparable when that happens. It also makes the console
/// the transcript: `devicectl process launch --console` captures the output, so a
/// failure on device is legible from the Mac instead of needing the crash log.
///
///     devicectl device process launch --console --terminate-existing \
///         cloud.moqom.codecbench --autorun --rung 544x960 --minutes 1 --no-camera
struct RunOptions {
    var autorun = false
    var rung: Rung?
    var minutes: Double?
    var camera: Bool?
    var mlvcOnly = false
    var hardwareOnly = false
    var computeUnits: MLComputeUnits?
    var variant: String?
    var qIndex: Int?
    var source: SourceKind?

    static func fromLaunchArguments(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> RunOptions {
        var options = RunOptions()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            /// The value after a flag, if there is one.
            func value() -> String? {
                guard index + 1 < arguments.count else { return nil }
                index += 1
                return arguments[index]
            }
            switch argument {
            case "--autorun": options.autorun = true
            case "--no-camera": options.camera = false
            case "--camera": options.camera = true
            case "--mlvc-only": options.mlvcOnly = true
            case "--hardware-only": options.hardwareOnly = true
            case "--variant": options.variant = value()
            case "--q-index": options.qIndex = value().flatMap(Int.init)
            case "--source": options.source = value().flatMap(SourceKind.init(rawValue:))
            case "--compute":
                switch value() {
                case "ane": options.computeUnits = .cpuAndNeuralEngine
                case "all": options.computeUnits = .all
                case "gpu": options.computeUnits = .cpuAndGPU
                case "cpu": options.computeUnits = .cpuOnly
                default: break
                }
            case "--minutes": options.minutes = value().flatMap(Double.init)
            case "--rung":
                if let slug = value() {
                    // Matched on the stem so a caller can pass `544x960` with an
                    // ASCII x, rather than the multiplication sign the picker shows.
                    options.rung = Rung.allCases.first { $0.modelStem.hasSuffix(slug) }
                }
            default: break
            }
            index += 1
        }
        return options
    }
}

/// What the codecs are fed.
enum SourceKind: String, CaseIterable, Identifiable, Sendable {
    /// The live camera. What you want to judge the picture by.
    case camera
    /// A real clip pushed to the device. Repeatable, and still real content.
    case clip
    /// A composited RealityKit scene with a floating orb, which is what broadcasting an AR
    /// session actually puts through the encoder.
    case realityKit
    /// Procedural frames. Identical on every device, so the fairest latency comparison,
    /// but nothing like what a learned codec was trained on.
    case synthetic

    var id: String { rawValue }

    var label: String {
        switch self {
        case .camera: "Camera"
        case .clip: "Clip"
        case .realityKit: "AR orb"
        case .synthetic: "Synthetic"
        }
    }
}

/// The rungs a MOQOM ladder would actually publish, in portrait.
///
/// Portrait because that is how a phone broadcasts, and the host's box is what picks
/// the rung. The widths are not round numbers: a learned codec of this family needs
/// both dimensions divisible by sixteen, so 1080 becomes 1088 and 540 becomes 544.
/// Only 720 needs no adjustment.
///
/// These are also the sizes MLVC has been exported at. A rung with no matching model
/// pair in Documents will fail to load rather than silently measure the wrong shape,
/// which is the intent — the model is compiled for one resolution and cannot stretch.
enum Rung: String, CaseIterable, Identifiable {
    case p360 = "368×640"
    case p540 = "544×960"
    case p720 = "720×1280"
    case p1080 = "1088×1920"

    var id: String { rawValue }

    var size: PixelSize {
        switch self {
        case .p360: PixelSize(width: 368, height: 640)
        case .p540: PixelSize(width: 544, height: 960)
        case .p720: PixelSize(width: 720, height: 1280)
        case .p1080: PixelSize(width: 1088, height: 1920)
        }
    }

    /// The stem of the side-loaded model pair, as `compile_models.sh` names them.
    ///
    /// Separate from `rawValue` because that carries a multiplication sign for the
    /// picker, and a file name wants an ASCII `x`. The variant selects between the
    /// 18.3M-parameter MLVC and the 5.4M-parameter MLVC-S, which are different
    /// enough in cost that a number is meaningless without saying which one it is.
    func modelStem(variant: String = "mlvc") -> String {
        "\(variant)-\(size.width)x\(size.height)"
    }

    var modelStem: String { modelStem() }

    /// What MOQOM's default ladder targets at this rung.
    var bitrate: Int {
        switch self {
        case .p360: 600_000
        case .p540: 1_200_000
        case .p720: 1_800_000
        case .p1080: 4_000_000
        }
    }

    var layer: VideoLayer {
        VideoLayer(id: LayerID("bench/\(rawValue)"), size: size, frameRate: 30, bitrate: bitrate)
    }
}

@MainActor
@Observable
final class BenchModel {
    var rung: Rung = .p540
    var minutes: Double = 2
    var cameraLoad = true
    var detail: Double = 0.5
    var includeMLVC = true
    /// Off under `--mlvc-only`, because the hardware baseline doubles a run's length
    /// and is not what a sweep over MLVC rungs is asking about.
    var includeHardware = true
    var computeUnits: MLComputeUnits = .cpuAndNeuralEngine
    /// `mlvc` for the 18.3M-parameter model, `mlvc-s` for the 5.4M one.
    var variant = "mlvc"
    var qIndex = 42

    /// Where the frames being compressed come from.
    var source: SourceKind = .camera

    /// What the run is actually being fed, since a clip can silently be absent.
    var sourceLabel = "synthetic"

    /// The AR scene, while one is running. Held so the view can host it: RealityKit renders
    /// only while its view is in a window.
    var arSource: ARBenchSource?

    /// The two tiles, so a run can be watched rather than trusted.
    let sourcePipe = PreviewPipe(title: "Source (into the encoder)")
    let decodedPipe = PreviewPipe(title: "Decoded (out of the decoder)")

    var running = false
    var live: [Bucket] = []
    var reports: [CodecReport] = []
    var status = "Idle"
    var savedTo: String?

    private var task: Task<Void, Never>?
    private var camera: CameraSource?
    private var appliedLaunchOptions = false

    func start() {
        guard !running else { return }
        running = true
        live = []
        reports = []
        savedTo = nil

        let settings = BenchmarkSettings(
            layer: rung.layer,
            duration: .seconds(minutes * 60),
            detail: detail,
            cameraLoad: cameraLoad
        )
        let synthetic = SyntheticScene(size: rung.size, frameRate: 30, detail: detail)
        let wanted = source

        sourcePipe.reset()
        decodedPipe.reset()
        // Only a front-camera view of yourself should be mirrored; a clip or an AR scene
        // that arrived the right way round would be wrong to flip.
        let selfie = wanted == .camera || wanted == .realityKit
        sourcePipe.isMirrored = selfie
        decodedPipe.isMirrored = selfie

        task = Task { [weak self] in
            guard let self else { return }
            if cameraLoad { await startCameraLoad() }

            // Decided once, here, because both codecs have to be asked the same question:
            // a run where one saw the camera and the other saw a clip compares nothing.
            let scene = await resolveSource(wanted, synthetic: synthetic)
            defer {
                if let camera = scene as? CameraBenchSource {
                    print("SOURCE final \(camera.summary)")
                    camera.stop()
                }
                if let ar = scene as? ARBenchSource {
                    print("SOURCE final \(ar.summary)")
                    Task { @MainActor in
                        ar.stop()
                        self.arSource = nil
                    }
                }
            }

            // One closure both codecs share, so whichever is running drives the same tiles.
            let show: @Sendable (PreviewPair) -> Void = { [weak self] pair in
                Task { @MainActor in
                    guard let self else { return }
                    self.sourcePipe.show(pair.source)
                    if let decoded = pair.decoded { self.decodedPipe.show(decoded) }
                }
            }

            var codecs: [any CodecUnderTest] = []
            if includeHardware {
                codecs.append(
                    HardwareCodec(
                        scene: scene, codec: .hevc, layer: settings.layer, preview: show
                    )
                )
            }
            if includeMLVC {
                codecs.append(
                    CoreMLCodec(
                        scene: scene,
                        modelStem: rung.modelStem(variant: variant),
                        units: computeUnits,
                        qIndex: qIndex,
                        preview: show
                    )
                )
            }

            let benchmark = Benchmark(settings: settings)
            var collected: [CodecReport] = []
            for codec in codecs {
                await MainActor.run {
                    self.status = "Running \(codec.label)…"
                    self.live = []
                }
                let report = await benchmark.run(codec) { bucket in
                    Task { @MainActor in self.live.append(bucket) }
                }
                collected.append(report)
                await MainActor.run { self.reports = collected }

                // Straight to stdout so a scripted run has the numbers without having
                // to pull the JSON back off the device afterwards.
                print("RESULT rung=\(rung.modelStem) codec=\(report.label) \(report.consoleLine)")

                // Let the part cool between codecs. Without this the second
                // codec inherits the first one's thermal state and looks worse
                // for a reason that has nothing to do with it.
                if codec !== codecs.last {
                    await MainActor.run { self.status = "Cooling down…" }
                    try? await Task.sleep(for: .seconds(60))
                }
            }

            await stopCameraLoad()
            await MainActor.run {
                self.save(collected, settings: settings)
                self.running = false
                self.status = "Done"
                print(
                    "RUN COMPLETE rung=\(self.rung.modelStem) "
                        + "tiles source=\(self.sourcePipe.shown) decoded=\(self.decodedPipe.shown)"
                )
            }
        }
    }

    /// Apply launch arguments and start if asked, so a scripted run needs no tap.
    func applyLaunchOptions() {
        // Once per launch. SwiftUI may run a `task` again when the view reappears — which
        // showing the AR scene causes — and a second autorun would append a whole extra
        // report to a run that was supposed to produce one.
        guard !appliedLaunchOptions else { return }
        appliedLaunchOptions = true

        let options = RunOptions.fromLaunchArguments()
        if let rung = options.rung { self.rung = rung }
        if let minutes = options.minutes { self.minutes = minutes }
        if let camera = options.camera { cameraLoad = camera }
        if options.mlvcOnly { includeHardware = false }
        if options.hardwareOnly { includeMLVC = false }
        if let units = options.computeUnits { computeUnits = units }
        if let variant = options.variant { self.variant = variant }
        if let qIndex = options.qIndex { self.qIndex = qIndex }
        if let source = options.source { self.source = source }
        guard options.autorun else { return }
        print(
            "AUTORUN rung=\(rung.modelStem) minutes=\(minutes) camera=\(cameraLoad) "
                + "hardware=\(includeHardware) mlvc=\(includeMLVC) q=\(qIndex) "
                + "source=\(source.rawValue)"
        )
        start()
    }

    func stop() {
        task?.cancel()
        task = nil
        Task { await stopCameraLoad() }
        running = false
        status = "Stopped"
    }

    /// Run capture without consuming it, purely as load.
    ///
    /// The frames are dropped on the floor. What matters is that the camera, the
    /// Open the requested source, falling back where it cannot be had.
    ///
    /// Falling back rather than failing, and saying so in `sourceLabel`, because a missing
    /// clip or a refused camera is a reason to measure something else — but a run that
    /// silently measured a different input than the one you picked would be worse than no
    /// run at all.
    private func resolveSource(
        _ wanted: SourceKind, synthetic: SyntheticScene
    ) async -> BenchSource {
        switch wanted {
        case .camera:
            if await CameraBenchSource.authorized() {
                do {
                    let camera = try CameraBenchSource(size: rung.size, frameRate: 30)
                    camera.start()
                    sourceLabel = "camera → \(rung.size.width)x\(rung.size.height)"
                    print("SOURCE camera rung=\(rung.size.width)x\(rung.size.height)")
                    return camera
                } catch {
                    sourceLabel = "synthetic (camera failed: \(error))"
                    print("SOURCE camera failed: \(error)")
                    return synthetic
                }
            }
            sourceLabel = "synthetic (camera refused)"
            print("SOURCE camera refused")
            return synthetic

        case .realityKit:
            guard await CameraBenchSource.authorized() else {
                sourceLabel = "synthetic (camera refused, AR needs it)"
                print("SOURCE AR refused: no camera access")
                return synthetic
            }
            guard ARBenchSource.isSupported else {
                sourceLabel = "synthetic (no AR on this device)"
                print("SOURCE AR unsupported")
                return synthetic
            }
            do {
                let ar = ARBenchSource(size: rung.size, frameRate: 30)
                // Presented before starting, because RealityKit only renders once the view
                // is in a window and the source would otherwise time out waiting.
                arSource = ar
                try await Task.sleep(for: .milliseconds(300))
                try ar.start()
                sourceLabel = "AR orb → \(rung.size.width)x\(rung.size.height)"
                print("SOURCE realityKit rung=\(rung.size.width)x\(rung.size.height)")
                return ar
            } catch {
                arSource = nil
                sourceLabel = "synthetic (AR failed: \(error))"
                print("SOURCE AR failed: \(error)")
                return synthetic
            }

        case .clip:
            if let clip = await ClipSource.forRung(size: rung.size, frameRate: 30) {
                sourceLabel = clip.name
                print("SOURCE clip=\(clip.name) \(rung.size.width)x\(rung.size.height)")
                return clip
            }
            sourceLabel = "synthetic (no clip for this rung)"
            print("SOURCE clip missing for \(rung.size.width)x\(rung.size.height)")
            return synthetic

        case .synthetic:
            sourceLabel = "synthetic"
            print("SOURCE synthetic \(rung.size.width)x\(rung.size.height)")
            return synthetic
        }
    }

    /// ISP and the capture pipeline are drawing power, because that is the state
    /// a phone is in during a broadcast and it is where the encoder's real
    /// thermal budget goes.
    private func startCameraLoad() async {
        guard await AVCaptureDevice.requestAccess(for: .video) else { return }
        do {
            let source = try CameraSource(
                format: CaptureFormat(size: rung.size, frameRate: 30),
                position: .front
            )
            source.start()
            camera = source
            Task.detached {
                for await _ in source.frames() where Task.isCancelled { break }
            }
        } catch {
            await MainActor.run { self.status = "Camera unavailable: \(error)" }
        }
    }

    private func stopCameraLoad() async {
        camera?.stop()
        camera = nil
    }

    private func save(_ reports: [CodecReport], settings: BenchmarkSettings) {
        let report = BenchmarkReport(
            device: UIDevice.current.model,
            systemVersion: UIDevice.current.systemVersion,
            resolution: rung.rawValue,
            frameRate: settings.frameRate,
            durationSeconds: minutes * 60,
            cameraLoad: settings.cameraLoad,
            startedAt: Date(),
            codecs: reports
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            let directory = try FileManager.default.url(
                for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )
            let stamp = ISO8601DateFormatter().string(from: report.startedAt)
                .replacingOccurrences(of: ":", with: "-")
            let url = directory.appendingPathComponent("bench-\(rung.rawValue)-\(stamp).json")
            try data.write(to: url)
            savedTo = url.lastPathComponent
        } catch {
            status = "Could not save: \(error)"
        }
    }
}

struct BenchView: View {
    @State private var model = BenchModel()

    var body: some View {
        content.task { model.applyLaunchOptions() }
    }

    private var content: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Above the form, not inside it. A `Form` is a lazy list, so a row below
                // the fold is never instantiated — and an `ARView` that is not in the
                // window draws nothing at all, which reads as a dead capture rather than
                // an unbuilt view.
                if let ar = model.arSource {
                    // Shaped to the rung's aspect, not the screen's. RealityKit's drawable
                    // is exactly this view's size, and a landscape drawable letterboxed
                    // into a portrait rung would put black bars through the encoder — free
                    // to compress, and so a flattering measurement of nothing.
                    ARSceneView(source: ar)
                        .aspectRatio(
                            Double(model.rung.size.width) / Double(model.rung.size.height),
                            contentMode: .fit
                        )
                        .frame(height: 300)
                        .clipped()
                        .overlay(alignment: .bottomLeading) {
                            Text("AR scene going to the encoder")
                                .font(.caption2)
                                .padding(6)
                                .background(.black.opacity(0.5), in: Capsule())
                                .foregroundStyle(.white)
                                .padding(8)
                        }
                }
                form
            }
            .navigationTitle("Codec bench")
        }
    }

    private var form: some View {
        Form {
                Section("Run") {
                    Picker("Rung", selection: $model.rung) {
                        ForEach(Rung.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Stepper(
                        "Duration  \(Int(model.minutes)) min",
                        value: $model.minutes, in: 1 ... 30
                    )
                    VStack(alignment: .leading) {
                        Text("Scene detail  \(model.detail, format: .number.precision(.fractionLength(2)))")
                        Slider(value: $model.detail, in: 0 ... 1)
                        Text("Higher is closer to a stage or a game; lower is closer to a talking head.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Stepper(
                        "Quality index  \(model.qIndex)",
                        value: $model.qIndex, in: 0 ... 63, step: 7
                    )
                    Picker("Source", selection: $model.source) {
                        ForEach(SourceKind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    LabeledContent("Feeding", value: model.sourceLabel)
                    Toggle("Camera running as load", isOn: $model.cameraLoad)
                    Toggle("Include the hardware baseline", isOn: $model.includeHardware)
                    Toggle("Include the Core ML path", isOn: $model.includeMLVC)
                }

                if model.sourcePipe.shown > 0 || model.running {
                    Section("Round trip") {
                        HStack(alignment: .top, spacing: 12) {
                            PreviewTile(pipe: model.sourcePipe)
                            PreviewTile(pipe: model.decodedPipe)
                        }
                        Text(
                            "Left is the frame handed to the encoder, right is what the "
                                + "decoder reconstructed. If they match, the models and the "
                                + "recurrent state are wired up correctly — timings alone "
                                + "cannot tell you that."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                Section {
                    if model.running {
                        Button("Stop", role: .destructive) { model.stop() }
                    } else {
                        Button("Run") { model.start() }
                    }
                    LabeledContent("Status", value: model.status)
                    if let savedTo = model.savedTo {
                        LabeledContent("Saved", value: savedTo)
                    }
                }

                if !model.live.isEmpty {
                    Section("In progress, by 30-second bucket") {
                        ForEach(model.live, id: \.startSeconds) { BucketRow(bucket: $0) }
                    }
                }

                ForEach(model.reports, id: \.label) { report in
                    Section(report.label) {
                        if let failure = report.failure {
                            Text(failure)
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                        LabeledContent("Frames", value: "\(report.frames)")
                        LabeledContent(
                            "Encode p50 / p95 / p99",
                            value: format(report.encodeP50, report.encodeP95, report.encodeP99)
                        )
                        LabeledContent(
                            "Decode p50 / p95 / p99",
                            value: format(report.decodeP50, report.decodeP95, report.decodeP99)
                        )
                        LabeledContent("Over 33.3 ms", value: "\(report.overBudget)")
                        if report.meanBitrate > 0 {
                            LabeledContent(
                                "Mean bitrate",
                                value: "\(report.meanBitrate / 1000) kbit/s"
                            )
                        }
                        if let psnr = report.meanPSNR {
                            LabeledContent(
                                "Reconstruction PSNR",
                                value: String(format: "%.2f dB", psnr)
                            )
                        }
                    }
                }
            }
    }

    private func format(_ a: Double, _ b: Double, _ c: Double) -> String {
        String(format: "%.2f / %.2f / %.2f ms", a, b, c)
    }
}

private struct BucketRow: View {
    let bucket: Bucket

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("t+\(Int(bucket.startSeconds))s  ·  \(bucket.thermal)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(
                String(
                    format: "enc %.2f (p95 %.2f)   dec %.2f (p95 %.2f)",
                    bucket.encodeP50, bucket.encodeP95, bucket.decodeP50, bucket.decodeP95
                )
            )
            .font(.system(.footnote, design: .monospaced))
            if bucket.overBudget > 0 {
                Text("\(bucket.overBudget) of \(bucket.frames) over budget")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}
