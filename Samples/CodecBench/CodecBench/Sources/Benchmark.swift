// Running a codec at broadcast cadence for long enough to matter.
//
// The number this harness exists to produce is not a per-frame latency. Any
// codec looks fast for a hundred frames; a phone is a thermal system, and what
// decides whether a codec is shippable is what it costs in the twelfth minute
// with the camera running. So the run is paced to a frame rate rather than
// hurried, it is bucketed by time rather than averaged into one figure, and it
// records what the thermal state was doing while the numbers moved.
//
// Pacing matters for a second reason. A loop that encodes flat out measures
// throughput, which is what the published FPS figures are, and throughput is the
// wrong quantity: a broadcast produces exactly thirty frames a second and the
// interesting question is what each one costs and whether the device keeps up.
// Running flat out also heats the part far faster than a real broadcast would
// and would overstate throttling.

import Foundation
import MoqomCore

/// Latency distribution over one stretch of a run.
struct Bucket: Sendable, Codable {
    var startSeconds: Double
    var frames: Int

    var encodeP50: Double
    var encodeP95: Double
    var decodeP50: Double
    var decodeP95: Double

    /// Round trips that did not fit in one frame interval.
    var overBudget: Int

    var meanBytes: Int
    var thermal: String
}

/// Everything one codec did over one run.
struct CodecReport: Sendable, Codable {
    var label: String
    var frames: Int
    var buckets: [Bucket]

    var encodeP50: Double
    var encodeP95: Double
    var encodeP99: Double
    var decodeP50: Double
    var decodeP95: Double
    var decodeP99: Double

    var overBudget: Int
    var meanBitrate: Int

    /// Mean reconstruction quality, where the path decodes to something comparable.
    var meanPSNR: Double?

    /// Set when the run ended early, with the reason.
    var failure: String?

    /// One line for a scripted run's console output.
    ///
    /// Includes the failure when there is one, because a run that reports zeros with
    /// no explanation is worse than one that says why.
    var consoleLine: String {
        if let failure {
            return "FAILED frames=\(frames) reason=\(failure)"
        }
        let quality = meanPSNR.map { String(format: " psnr=%.2f", $0) } ?? ""
        return String(
            format: "frames=%d enc_p50=%.2f enc_p95=%.2f dec_p50=%.2f dec_p95=%.2f "
                + "over_budget=%d kbps=%d",
            frames, encodeP50, encodeP95, decodeP50, decodeP95, overBudget, meanBitrate / 1000
        ) + quality
    }
}

struct BenchmarkReport: Sendable, Codable {
    var device: String
    var systemVersion: String
    var resolution: String
    var frameRate: Double
    var durationSeconds: Double
    var cameraLoad: Bool
    var startedAt: Date
    var codecs: [CodecReport]
}

struct BenchmarkSettings: Sendable {
    var layer: VideoLayer
    var frameRate: Double = 30
    var duration: Duration = .seconds(120)
    var bucketSeconds: Double = 30
    var detail: Double = 0.5

    /// Keep a capture session running alongside the codec.
    ///
    /// On by default, because it is the difference between a laboratory number
    /// and the one a broadcaster gets. The camera, the ISP and the display all
    /// draw from the same power and thermal budget as the encoder, and a codec
    /// measured on an otherwise idle phone has been measured under conditions
    /// that never occur in the product.
    var cameraLoad: Bool = true

    var frameInterval: Duration {
        .nanoseconds(Int(1_000_000_000 / max(1, frameRate)))
    }
}

/// Collects samples and turns them into percentiles.
///
/// Kept as raw samples rather than a running summary: a mean hides exactly the
/// behaviour worth finding, which is a small number of very slow frames, and at
/// thirty a second for twenty minutes the whole run is under half a megabyte.
struct Distribution {
    private var values: [Double] = []

    mutating func add(_ value: Double) { values.append(value) }

    var count: Int { values.count }

    func percentile(_ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let position = fraction * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        let weight = position - Double(lower)
        return sorted[lower] * (1 - weight) + sorted[upper] * weight
    }
}

actor Benchmark {
    private let settings: BenchmarkSettings

    init(settings: BenchmarkSettings) {
        self.settings = settings
    }

    /// Run one codec for the configured duration.
    ///
    /// - Parameter progress: called with each bucket as it closes, so a run can
    ///   be watched rather than waited for — twenty minutes is a long time to
    ///   stare at a spinner, and a run that is clearly degrading can be stopped.
    func run(
        _ codec: any CodecUnderTest,
        progress: @Sendable @escaping (Bucket) -> Void
    ) async -> CodecReport {
        var report = CodecReport(
            label: codec.label,
            frames: 0,
            buckets: [],
            encodeP50: 0, encodeP95: 0, encodeP99: 0,
            decodeP50: 0, decodeP95: 0, decodeP99: 0,
            overBudget: 0,
            meanBitrate: 0
        )

        // Stage markers, because a run that dies on device leaves nothing behind but
        // a signal number, and the signal alone does not say which codec it was in.
        print("STAGE prepare-begin codec=\(codec.label)")
        do {
            try await codec.prepare()
        } catch {
            report.failure = "\(error)"
            print("STAGE prepare-failed codec=\(codec.label) error=\(error)")
            return report
        }
        print("STAGE prepare-done codec=\(codec.label)")

        var encode = Distribution()
        var decode = Distribution()
        var bucketEncode = Distribution()
        var bucketDecode = Distribution()
        var bucketOverBudget = 0
        var bucketBytes = 0
        var bucketFrames = 0
        var totalBytes = 0
        var qualitySum = 0.0
        var qualityCount = 0

        let budget = 1000.0 / settings.frameRate
        let clock = ContinuousClock()
        let started = clock.now
        var bucketStarted = 0.0
        var deadline = started
        var index = 0

        // A keyframe every two seconds, matching what the encoder is configured
        // for, so the two paths agree on how often they pay for one.
        let keyFrameEvery = Int(settings.frameRate * 2)

        while clock.now.duration(to: started + settings.duration).millis > 0 {
            deadline += settings.frameInterval

            let sample: Sample
            do {
                sample = try await codec.roundTrip(
                    frameIndex: index,
                    forceKeyFrame: index % keyFrameEvery == 0
                )
            } catch {
                report.failure = "\(error)"
                print("STAGE frame-failed codec=\(codec.label) index=\(index) error=\(error)")
                break
            }
            if index == 0 {
                let quality = sample.psnr.map { String(format: ", psnr %.2f dB", $0) } ?? ""
                print("STAGE first-frame codec=\(codec.label)\(quality)")
            }
            if let psnr = sample.psnr {
                qualitySum += psnr
                qualityCount += 1
            }

            encode.add(sample.encodeMillis)
            decode.add(sample.decodeMillis)
            bucketEncode.add(sample.encodeMillis)
            bucketDecode.add(sample.decodeMillis)
            bucketBytes += sample.byteCount
            totalBytes += sample.byteCount
            bucketFrames += 1
            if sample.totalMillis > budget {
                bucketOverBudget += 1
                report.overBudget += 1
            }
            index += 1

            let elapsed = started.duration(to: clock.now).millis / 1000
            if elapsed - bucketStarted >= settings.bucketSeconds {
                let bucket = Bucket(
                    startSeconds: bucketStarted,
                    frames: bucketFrames,
                    encodeP50: bucketEncode.percentile(0.5),
                    encodeP95: bucketEncode.percentile(0.95),
                    decodeP50: bucketDecode.percentile(0.5),
                    decodeP95: bucketDecode.percentile(0.95),
                    overBudget: bucketOverBudget,
                    meanBytes: bucketFrames == 0 ? 0 : bucketBytes / bucketFrames,
                    thermal: ProcessInfo.processInfo.thermalState.name
                )
                report.buckets.append(bucket)
                progress(bucket)

                bucketStarted = elapsed
                bucketEncode = Distribution()
                bucketDecode = Distribution()
                bucketOverBudget = 0
                bucketBytes = 0
                bucketFrames = 0
            }

            // Pace to the frame interval. Sleeping until an absolute deadline
            // rather than for a fixed duration keeps the cadence honest when a
            // frame runs long: the next one is not pushed later by the overrun,
            // which is how a real capture behaves.
            if clock.now < deadline {
                try? await Task.sleep(until: deadline, clock: clock)
            }

            if Task.isCancelled { break }
        }

        await codec.close()

        report.frames = index
        if qualityCount > 0 { report.meanPSNR = qualitySum / Double(qualityCount) }
        report.encodeP50 = encode.percentile(0.5)
        report.encodeP95 = encode.percentile(0.95)
        report.encodeP99 = encode.percentile(0.99)
        report.decodeP50 = decode.percentile(0.5)
        report.decodeP95 = decode.percentile(0.95)
        report.decodeP99 = decode.percentile(0.99)
        if index > 0 {
            report.meanBitrate = Int(
                Double(totalBytes) * 8 * settings.frameRate / Double(index)
            )
        }
        return report
    }
}

extension ProcessInfo.ThermalState {
    var name: String {
        switch self {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}
