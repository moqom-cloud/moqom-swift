// Measuring what a broadcast costs between two devices.
//
// The number worth having is glass to glass: the interval between a photon landing on one
// phone's sensor and the corresponding pixel lighting up on the other's. Everything the SDK
// already reports is one side of that — encode counters here, arrival counters there — and
// none of it crosses the gap.
//
// Crossing it needs one thing the two phones do not otherwise have: a shared idea of when
// now is. A capture timestamp is a reading of the capturing device's own clock, and the two
// clocks are unrelated, so subtracting one from the other yields the offset between two
// phones rather than the latency between them — a number that looks plausible, stays
// stable, and is wrong by however far apart the clocks happen to be.
//
// ``TrustedClock`` is the shared idea. Both ends discipline against the same NTP service, so
// both produce timestamps on one timeline and carry an honest error bar for it. The frames
// then get stamped on that timeline instead of the device's, which is all it takes for the
// subtraction on the far side to mean something. The error bar is reported alongside the
// result, because a latency quoted more precisely than the clock that measured it is a
// number with a false claim attached.

import Foundation
import MoqomCore
import MoqomKit

/// Restamps a source's frames onto a clock the other device also has.
///
/// A decorator rather than a change to ``CameraSource``, because what wants replacing is the
/// timeline and not the capture. It also keeps the substitution honest: the frames published
/// are the ones the camera produced, in the order it produced them, and the only difference
/// is which clock read them.
///
/// The stamp is applied on delivery rather than on capture, so it includes however long the
/// capture pipeline held the frame. That is the right place for it: a viewer waits for that
/// too, and a measurement that started at the sensor's own timestamp would quietly exclude
/// the first few milliseconds of the path it claims to measure.
struct TimedSource: FrameSource {
    private let wrapped: any FrameSource
    private let stamp: @Sendable () -> Timecode

    init(_ wrapped: any FrameSource, stamp: @escaping @Sendable () -> Timecode) {
        self.wrapped = wrapped
        self.stamp = stamp
    }

    var captureFormat: CaptureFormat { wrapped.captureFormat }

    func frames() -> AsyncStream<VideoFrame> {
        let upstream = wrapped.frames()
        let stamp = stamp
        return AsyncStream { continuation in
            let pump = Task {
                for await frame in upstream {
                    continuation.yield(
                        VideoFrame(
                            // Clamped only against a clock that claims to predate the
                            // epoch, which nothing here produces; the timestamp is
                            // unsigned and a negative reading would wrap to an enormous
                            // one rather than fail.
                            timestamp: FrameTimestamp(
                                nanoseconds: UInt64(max(0, stamp().nanoseconds))
                            ),
                            size: frame.size,
                            surface: frame.surface
                        )
                    )
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in pump.cancel() }
        }
    }

    func stop() { wrapped.stop() }
}

/// Collects one-way latencies and reports what they were.
///
/// Percentiles rather than a mean, because the mean of a latency distribution is the one
/// summary that hides the thing anyone cares about. A path that is usually 40ms and
/// occasionally 400ms averages out to something that sounds fine and looks terrible.
///
/// A class with a lock rather than an actor: it is written from the frame pump on every
/// frame, and an actor hop per frame would put the measurement's own scheduling inside the
/// thing being measured.
final class LatencyMeter: @unchecked Sendable {
    private let lock = NSLock()

    /// Recent samples only, kept in a ring.
    ///
    /// Over a whole run the percentiles stop describing the link and start describing its
    /// history: a stall in the first second is still sitting in the p95 ten minutes later,
    /// long after the thing it measured stopped happening, and a link that has since
    /// recovered reads as broken. Thirty seconds is short enough to follow a change and long
    /// enough that a p99 over it means something.
    private var samples: [Double] = []
    private var cursor = 0
    private static let window = 900

    /// The worst single sample of the whole run, which the window would otherwise forget.
    private var worstEver = 0.0

    private var frames = 0

    /// The widest clock uncertainty seen while measuring, in milliseconds.
    ///
    /// Kept as the worst rather than the latest so the figure quoted with a result is a
    /// bound over the whole run and not whatever the clock happened to think at the end.
    private var uncertainty = 0.0

    /// Frames whose capture time was in the receiver's future.
    ///
    /// Impossible, and therefore worth counting rather than clamping: it means the two
    /// clocks are not yet agreed, and any latency measured alongside it is understated by
    /// however far apart they are.
    private var impossible = 0

    func record(capturedAt captured: FrameTimestamp, receivedAt received: Timecode) {
        // In doubles rather than integers because the two are differently signed, and the
        // subtraction that matters is the one that can legitimately come out negative.
        let milliseconds =
            (Double(received.nanoseconds) - Double(captured.nanoseconds)) / 1_000_000
        let bound = Double(received.uncertainty.components.attoseconds) / 1e15
            + Double(received.uncertainty.components.seconds) * 1000

        lock.withLock {
            frames += 1
            uncertainty = max(uncertainty, bound)
            if milliseconds < 0 {
                impossible += 1
            } else {
                worstEver = max(worstEver, milliseconds)
                if samples.count < Self.window {
                    samples.append(milliseconds)
                } else {
                    samples[cursor] = milliseconds
                    cursor = (cursor + 1) % Self.window
                }
            }
        }
    }

    /// What the run has measured so far.
    ///
    /// A value rather than a formatted line, because the same figures are wanted in two
    /// places — a console on the Mac and a readout on the phone holding the camera — and the
    /// second one is the only one available when nothing is tethered.
    struct Reading: Sendable {
        var frames: Int

        /// Milliseconds from capture on one device to arrival on this one.
        var median: Double
        var p95: Double
        var p99: Double
        var worst: Double

        /// How far apart the two clocks might be, in milliseconds.
        ///
        /// Carried with the figures rather than reported separately: a median of 60ms means
        /// something different either side of a ±5ms clock and a ±40ms one, and the second
        /// is not a measurement of latency at all.
        var uncertainty: Double

        /// Frames that arrived before they were captured, which cannot happen.
        var impossible: Int

        var isUsable: Bool { frames > 0 && impossible == 0 }
    }

    /// The figures so far, or `nil` while nothing has arrived to measure.
    func reading() -> Reading? {
        let (sorted, frames, uncertainty, impossible, worstEver) = lock.withLock {
            (samples.sorted(), self.frames, self.uncertainty, self.impossible, self.worstEver)
        }
        guard !sorted.isEmpty else {
            guard frames > 0 else { return nil }
            return Reading(
                frames: frames,
                median: 0, p95: 0, p99: 0, worst: 0,
                uncertainty: uncertainty,
                impossible: impossible
            )
        }

        func percentile(_ fraction: Double) -> Double {
            sorted[Int((Double(sorted.count - 1) * fraction).rounded())]
        }

        return Reading(
            frames: frames,
            median: percentile(0.5),
            p95: percentile(0.95),
            p99: percentile(0.99),
            worst: worstEver,
            uncertainty: uncertainty,
            impossible: impossible
        )
    }

    /// What the run measured, or why it did not.
    func report() -> String {
        guard let reading = reading(), reading.median > 0 || reading.frames > 0 else {
            return "latency frames=0 no usable samples"
        }

        guard reading.worst > 0 else {
            return "latency frames=\(reading.frames) no usable samples"
                + (reading.impossible > 0
                    ? ", \(reading.impossible) before capture — clocks disagree" : "")
        }

        var line = String(
            format: "latency frames=%d p50=%.1f p95=%.1f p99=%.1f max=%.1f ms ±%.1f",
            reading.frames,
            reading.median,
            reading.p95,
            reading.p99,
            reading.worst,
            reading.uncertainty
        )
        if reading.impossible > 0 { line += " (\(reading.impossible) before capture)" }
        return line
    }
}

/// Measures whether frames arrive evenly, which is what "choppy" means.
///
/// A separate measurement from latency and not a derived one, because the two are independent
/// and a link can fail either without failing the other. Thirty frames a second arriving in
/// bursts of ten looks broken while averaging a perfect frame rate and an excellent latency;
/// a steady stream half a second behind looks smooth. Neither figure predicts the other, so
/// quoting one as though it covered both is how a stuttering call gets reported as healthy.
///
/// A viewer's picture is presented against the *publisher's* timeline, not against its own
/// arrivals, so an even arrival cadence is only half of smooth motion. If the timestamps
/// themselves are unevenly spaced, a player honouring them reproduces that unevenness exactly —
/// the frames are all there, all in order, none late, and the motion is still wrong. It is
/// invisible on a face and obvious on anything rotating, which is why a ceiling fan is the
/// better test subject than a person.
///
/// Measured by ``TimelineMeter`` on the receiver, because the spacing of the stamps travels with
/// them and needs no clock agreement to read: consecutive differences of a sender's own numbers
/// are the same on any device that receives them.
final class TimelineMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var gaps: [Double] = []
    private var cursor = 0
    private static let window = 900
    private var previous: UInt64?

    /// - Parameter stamp: The publisher's timestamp for this frame, in nanoseconds.
    func record(stamp: UInt64) {
        lock.withLock {
            defer { previous = stamp }
            guard let previous, stamp > previous else { return }
            let milliseconds = Double(stamp - previous) / 1_000_000
            if gaps.count < Self.window {
                gaps.append(milliseconds)
            } else {
                gaps[cursor] = milliseconds
                cursor = (cursor + 1) % Self.window
            }
        }
    }

    /// `nil` until there are two stamps to compare.
    func report() -> String? {
        let sorted = lock.withLock { gaps.sorted() }
        guard !sorted.isEmpty else { return nil }

        func percentile(_ fraction: Double) -> Double {
            sorted[Int((Double(sorted.count - 1) * fraction).rounded())]
        }

        let median = percentile(0.5)
        return String(
            format: "stamp p50=%.1f p95=%.1f max=%.1f ms uneven=%.1fx",
            median,
            percentile(0.95),
            sorted[sorted.count - 1],
            median > 0 ? percentile(0.95) / median : 0
        )
    }
}

/// Measured on the receiver's own monotonic clock, which is the one thing here that needs no
/// agreement with the other device: the question is only whether the intervals between
/// arrivals are even, and any clock that ticks steadily can answer it. It means this figure
/// stays meaningful when the trusted clock is unavailable and the latency figures are not.
final class CadenceMeter: @unchecked Sendable {
    private let lock = NSLock()

    /// Intervals between arrivals, in milliseconds, most recent first.
    private var gaps: [Double] = []
    private var cursor = 0
    private static let window = 900

    private var frames = 0
    private var previous: ContinuousClock.Instant?
    private var first: ContinuousClock.Instant?
    private var last: ContinuousClock.Instant?

    private var freezes = 0
    private var frozen = 0.0

    /// How many of the stalls ended with a keyframe, and how far apart they were.
    ///
    /// The pair that turns "it stutters" into a cause. A group boundary is the one thing in
    /// this pipeline that happens on a fixed period and costs more than a frame: the previous
    /// subgroup stream is closed and a new one opened, and the first object on it is an
    /// intra-coded frame several times the size of the rest. If nearly every stall ends on a
    /// keyframe and they are spaced at the keyframe interval, the encoder's own cadence is the
    /// stutter and no amount of network tuning addresses it. If they are scattered and land on
    /// ordinary frames, the link is losing or bunching them and the group boundary is innocent.
    private var freezesOnKeyFrame = 0
    private var stallPeriods: [Double] = []
    private var previousStall: ContinuousClock.Instant?

    /// A gap this long is a visible stall rather than jitter.
    ///
    /// At 30fps a frame is due every 33ms, and the display can absorb a few missed ones
    /// without anyone noticing. Past about a sixth of a second the picture is perceptibly
    /// held, so that is where a late frame stops being jitter and starts being a freeze —
    /// the same threshold WebRTC's freeze counters use, for the same reason.
    private static let freezeThreshold = 150.0

    /// - Parameter keyFrame: Whether the frame that ended this gap was a keyframe. Only used to
    ///   attribute stalls; pass `false` where it is not known and the attribution reads zero.
    func record(at instant: ContinuousClock.Instant = .now, keyFrame: Bool = false) {
        lock.withLock {
            frames += 1
            if first == nil { first = instant }
            last = instant
            defer { previous = instant }

            guard let previous else { return }
            let milliseconds = Double(
                (instant - previous).components.attoseconds
            ) / 1e15 + Double((instant - previous).components.seconds) * 1000

            if milliseconds >= Self.freezeThreshold {
                freezes += 1
                frozen += milliseconds
                if keyFrame { freezesOnKeyFrame += 1 }
                if let previousStall {
                    let apart = Double((instant - previousStall).components.seconds)
                        + Double((instant - previousStall).components.attoseconds) / 1e18
                    stallPeriods.append(apart)
                }
                previousStall = instant
            }

            if gaps.count < Self.window {
                gaps.append(milliseconds)
            } else {
                gaps[cursor] = milliseconds
                cursor = (cursor + 1) % Self.window
            }
        }
    }

    struct Reading: Sendable {
        var frames: Int

        /// Frames per second, over the whole run.
        var rate: Double

        /// Milliseconds between one arrival and the next.
        var median: Double
        var p95: Double
        var worst: Double

        /// Gaps long enough to be seen as the picture stopping.
        var freezes: Int

        /// The fraction of the run spent inside one of those gaps.
        var frozen: Double

        /// How many of those gaps were closed by a keyframe.
        var onKeyFrame: Int

        /// Typical seconds between one stall and the next, or zero with fewer than two.
        var period: Double

        /// How uneven the arrivals are, as the spread between the typical gap and a bad one.
        ///
        /// The number that matches the complaint: a p95 twice the median is visible, and a
        /// p95 equal to it is a stream nobody would call choppy however slow it is.
        var unevenness: Double { median > 0 ? p95 / median : 0 }
    }

    func reading() -> Reading? {
        let snapshot = lock.withLock {
            () -> (
                gaps: [Double], frames: Int, rate: Double, freezes: Int, frozen: Double,
                onKey: Int, period: Double
            ) in
            let periods = stallPeriods.sorted()
            let typical = periods.isEmpty
                ? 0
                : periods[periods.count / 2]
            guard let first, let last, frames > 1 else {
                return (gaps.sorted(), frames, 0, freezes, 0, freezesOnKeyFrame, typical)
            }
            let span = Double((last - first).components.seconds)
                + Double((last - first).components.attoseconds) / 1e18
            return (
                gaps.sorted(),
                frames,
                span > 0 ? Double(frames) / span : 0,
                freezes,
                span > 0 ? (frozen / 1000) / span : 0,
                freezesOnKeyFrame,
                typical
            )
        }
        let sorted = snapshot.gaps

        guard !sorted.isEmpty else { return nil }

        func percentile(_ fraction: Double) -> Double {
            sorted[Int((Double(sorted.count - 1) * fraction).rounded())]
        }

        return Reading(
            frames: snapshot.frames,
            rate: snapshot.rate,
            median: percentile(0.5),
            p95: percentile(0.95),
            worst: sorted[sorted.count - 1],
            freezes: snapshot.freezes,
            frozen: snapshot.frozen,
            onKeyFrame: snapshot.onKey,
            period: snapshot.period
        )
    }

    func report() -> String {
        guard let reading = reading() else { return "cadence frames=0" }
        return String(
            format: "cadence fps=%.1f gap p50=%.1f p95=%.1f max=%.1f ms uneven=%.1fx"
                + " freezes=%d frozen=%.1f%% onkey=%d every=%.1fs",
            reading.rate,
            reading.median,
            reading.p95,
            reading.worst,
            reading.unevenness,
            reading.freezes,
            reading.frozen * 100,
            reading.onKeyFrame,
            reading.period
        )
    }
}
