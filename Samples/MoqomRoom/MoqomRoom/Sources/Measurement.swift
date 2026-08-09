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
/// The clock is read once and applied as an offset, rather than read per frame. Reading it per
/// frame looks more direct and is measurably worse: the reading happens wherever the frame
/// reached in an asynchronous pipeline, so it carries that stage's scheduling noise — a few
/// milliseconds usually, ten now and then — and *that becomes the frame's capture time*. The
/// spacing between frames, which the camera had produced to within a fraction of a millisecond,
/// is then wrong by that noise on every frame. A viewer presenting on those timestamps holds one
/// frame for two refreshes and skips the next about once a second: invisible on a face, and on a
/// ceiling fan a blade that stalls and jumps.
///
/// An offset keeps both properties. The sensor's spacing survives untouched, and the timestamps
/// still land on the shared timeline, because the offset between the capture clock and that
/// timeline is a constant — two readings of the same host clock, one of them corrected for the
/// network's idea of the time.
///
/// It costs one thing the per-frame reading gave away for free, and the cost turned out to be
/// larger than the sentence describing it. However long the capture pipeline holds a frame the
/// sensor has already stamped is not inside the measurement, because the offset is anchored on
/// delivery and every frame after it is measured from the sensor — so the offset *is* the
/// clock difference plus one camera delivery, and subtracting it removes the camera from every
/// latency reported downstream.
///
/// That is about fifteen milliseconds on the phones this runs on, and it is invisible in the
/// worst way: not noise, but a constant understatement of the headline number, in the one stage
/// nothing else measures. It also makes the figure blind to any improvement in that stage, which
/// is how a change that took four milliseconds off an iPhone Air's capture path showed up as one
/// — the frames arrived four milliseconds earlier and the offset shrank by nearly as much, so
/// the two cancelled.
///
/// So the floor is put back. The source reports the quickest it has been observed to hand a
/// frame over, that much is taken out of the offset, and what goes on the wire is the sensor's
/// own instant on the shared timeline. Everything the offset was for survives: it is still one
/// constant for the run rather than a reading per frame, so the sensor's spacing is untouched
/// and no judder is reintroduced.
///
/// The correction is taken once, when the offset settles, rather than tracked. A floor that
/// improved later would otherwise walk the timestamps forward a fraction of a millisecond at a
/// time, which is exactly the per-frame noise this design exists to avoid.
struct TimedSource: FrameSource {
    private let wrapped: any FrameSource
    private let stamp: @Sendable () -> Timecode
    private let floor: @Sendable () -> Double?

    /// - Parameter floor: The quickest the source has been seen to hand over a frame the sensor
    ///   had already stamped, in milliseconds, or `nil` for a source with no such cost. Taking
    ///   the offset as a minimum subtracts exactly this from every latency reported downstream,
    ///   so without it the whole capture stage is missing from the number — see below.
    init(
        _ wrapped: any FrameSource,
        stamp: @escaping @Sendable () -> Timecode,
        floor: @escaping @Sendable () -> Double? = { nil }
    ) {
        self.wrapped = wrapped
        self.stamp = stamp
        self.floor = floor
    }

    var captureFormat: CaptureFormat { wrapped.captureFormat }

    func frames() -> AsyncStream<VideoFrame> {
        let upstream = wrapped.frames()
        let stamp = stamp
        return AsyncStream { continuation in
            let pump = Task {
                // Anchored on the first frames that carry a usable capture time. A source with no
                // clock of its own — a synthetic pattern, say — stamps every frame zero, and for
                // those the reading per frame is all there is.
                var offset: Int64?
                var settling = 0

                // What the offset absorbed of the capture path, taken once when the offset stops
                // moving and held for the run. Zero until then, and zero for good on a source
                // with no such cost to report.
                var floorNanoseconds: Int64 = 0
                var floorTaken = false

                for await frame in upstream {
                    let captured = Int64(bitPattern: frame.timestamp.nanoseconds)
                    let now = stamp().nanoseconds

                    if captured > 0 {
                        let candidate = now - captured
                        switch offset {
                        case .none:
                            offset = candidate

                        // Taken as the smallest of the first second's worth rather than the first
                        // outright, because the difference between the two clocks is the same every
                        // frame and the delay in observing it is not: whatever the pipeline added
                        // on the frame that happened to be first would otherwise be charged to
                        // every frame in the run.
                        case let .some(current) where settling < 60:
                            offset = min(current, candidate)

                        // Re-anchored on a gross discrepancy and only then. A quarter of a second
                        // is far more than scheduling ever accounts for and far less than a clock
                        // moving: an NTP correction landing after the first frames, a source whose
                        // timeline restarted. Latching once and never looking again turns any of
                        // those into a run that is wrong from end to end, which is what this
                        // measured before the check existed — three and a half seconds of
                        // unreadable video and a latency figure eleven hours out.
                        case let .some(current):
                            if abs(candidate - current) > 250_000_000 { offset = candidate }
                        }
                        settling += 1

                        // Read at the moment the offset stops being revised, so the two are
                        // minima over the same window and describe the same frames. Read
                        // earlier it would be a floor from three frames; read continuously it
                        // would move the timestamps around.
                        if !floorTaken, settling >= 60 {
                            floorTaken = true
                            floorNanoseconds = floor().map { Int64($0 * 1_000_000) } ?? 0
                        }
                    }

                    let shared = offset.map { captured + $0 - floorNanoseconds } ?? now

                    continuation.yield(
                        VideoFrame(
                            // Clamped only against a clock that claims to predate the
                            // epoch, which nothing here produces; the timestamp is
                            // unsigned and a negative reading would wrap to an enormous
                            // one rather than fail.
                            timestamp: FrameTimestamp(nanoseconds: UInt64(max(0, shared))),
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

    // Forwarded, and the reason is worth a line: this is a decorator, so
    // anything it does not pass on is a capability the source underneath
    // quietly loses. Not forwarding these two meant a moderator's mute stopped
    // the encoder while the camera stayed open, on a run that reported the mute
    // as applied and left the indicator lit.
    func suspend() { wrapped.suspend() }
    func resume() { wrapped.resume() }
}

/// The same trick for audio, and it has to be the same trick.
///
/// A run measures latency by comparing a stamp made here against a clock read there, which
/// only means anything if both devices agree on the clock — hence ``TimedSource`` for video.
/// Audio went unstamped, so the two media left this device quoting unrelated timelines: the
/// camera's frames on the shared clock and the microphone's packets on this device's own.
/// Nothing at the far end could then say whether a voice was ahead of its face or behind it,
/// which is a hard thing to fix and an easy thing to not notice, because the two arrive close
/// enough to look aligned in every counter that does not measure it.
struct TimedAudioSource: AudioSource {
    private let wrapped: any AudioSource
    private let stamp: @Sendable () -> Timecode

    init(_ wrapped: any AudioSource, stamp: @escaping @Sendable () -> Timecode) {
        self.wrapped = wrapped
        self.stamp = stamp
    }

    var format: AudioFormat { wrapped.format }

    func frames() -> AsyncStream<AudioFrame> {
        let upstream = wrapped.frames()
        let stamp = stamp
        return AsyncStream { continuation in
            let pump = Task {
                // One offset for the whole run, taken as the smallest of the first second's
                // worth, exactly as the video side takes it: the difference between the two
                // clocks is constant and the delay in observing it is not. Audio packets are
                // continuous by construction — the capture timeline advances by a packet's
                // duration whatever the thread was doing — so re-anchoring on a discrepancy
                // is not wanted here. A jump would be a clock moving under a live call, and
                // moving the audio timeline in the middle of a sentence is worse than the
                // error it would correct.
                var offset: Int64?
                var settling = 0

                for await frame in upstream {
                    let captured = Int64(bitPattern: frame.timestamp.nanoseconds)
                    let now = stamp().nanoseconds

                    if captured > 0 {
                        let candidate = now - captured
                        if let current = offset, settling >= 50 {
                            offset = current
                        } else if let current = offset {
                            offset = min(current, candidate)
                        } else {
                            offset = candidate
                        }
                        settling += 1
                    }

                    let shared = offset.map { captured + $0 } ?? now
                    continuation.yield(
                        AudioFrame(
                            timestamp: FrameTimestamp(nanoseconds: UInt64(max(0, shared))),
                            format: frame.format,
                            samples: frame.samples
                        )
                    )
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in pump.cancel() }
        }
    }

    func stop() { wrapped.stop() }
    func suspend() { wrapped.suspend() }
    func resume() { wrapped.resume() }
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

    /// What the clock is worth now, as opposed to the worst it has ever been worth.
    ///
    /// Both, because on their own each one misleads. The worst is a high-water mark that never
    /// comes down: one wide exchange early in a run — and the exchanges early in a run are the
    /// wide ones, before the clock has collected a sample with a short round trip — stamps that
    /// figure on every reading for the next hour. Quoted alone it says a measurement is far less
    /// trustworthy than it is.
    ///
    /// Measured, that is exactly what happened: a run reported ±30ms beside a median of 45ms,
    /// which reads as a figure not worth acting on, while the clock in force had long since
    /// found a better exchange and narrowed.
    private var latest = 0.0

    /// Frames whose capture time was in the receiver's future.
    ///
    /// Impossible, and therefore worth counting rather than clamping: it means the two
    /// clocks are not yet agreed, and any latency measured alongside it is understated by
    /// however far apart they are.
    private var impossible = 0

    /// Frames whose capture time was too far in the past to be a latency.
    ///
    /// The same fault as ``impossible`` with the other sign, and it needs the same
    /// treatment for the same reason. A publisher's timeline can step — an interruption,
    /// a re-anchor after one — and a frame stamped either side of the step measures the
    /// step rather than the link. One such sample ruins every percentile above the
    /// median: a run whose p50 was a healthy 43.9ms reported a p95 of thirteen and a half
    /// hours, which is not a latency anybody can act on and sits in the same line as
    /// figures that are.
    ///
    /// Counted and named rather than dropped in silence, because a run producing them is
    /// a run whose clocks are not agreed, and the median beside them is only as
    /// trustworthy as that.
    private var beyondBelief = 0

    /// Past this, a sample is describing a clock rather than a network.
    ///
    /// Ten seconds: far beyond any link this is used on, and far short of the hours a
    /// stepped timeline produces, so nothing a bad network can do lands here.
    private static let believable = 10_000.0

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
            latest = bound
            if milliseconds < 0 {
                impossible += 1
            } else if milliseconds > Self.believable {
                beyondBelief += 1
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

        /// The same bound as the clock stands behind now. See ``LatencyMeter/latest``.
        var currentUncertainty: Double

        /// Frames that arrived before they were captured, which cannot happen.
        var impossible: Int

        /// Frames whose measured latency was hours rather than milliseconds.
        var beyondBelief: Int

        var isUsable: Bool { frames > 0 && impossible == 0 && beyondBelief == 0 }
    }

    /// The figures so far, or `nil` while nothing has arrived to measure.
    func reading() -> Reading? {
        let (sorted, frames, uncertainty, latest, impossible, beyondBelief, worstEver) = lock
            .withLock {
                (
                    samples.sorted(), self.frames, self.uncertainty, self.latest,
                    self.impossible, self.beyondBelief, self.worstEver
                )
            }
        guard !sorted.isEmpty else {
            guard frames > 0 else { return nil }
            return Reading(
                frames: frames,
                median: 0, p95: 0, p99: 0, worst: 0,
                uncertainty: uncertainty,
                currentUncertainty: latest,
                impossible: impossible,
                beyondBelief: beyondBelief
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
            currentUncertainty: latest,
            impossible: impossible,
            beyondBelief: beyondBelief
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
            format: "latency frames=%d p50=%.1f p95=%.1f p99=%.1f max=%.1f ms ±%.1f now±%.1f",
            reading.frames,
            reading.median,
            reading.p95,
            reading.p99,
            reading.worst,
            reading.uncertainty,
            reading.currentUncertainty
        )
        if reading.impossible > 0 { line += " (\(reading.impossible) before capture)" }
        // Named as a stepped clock rather than left to be read as a slow link, which is
        // what a count of discarded hours next to a healthy median otherwise looks like.
        if reading.beyondBelief > 0 {
            line += " (\(reading.beyondBelief) discarded, publisher's clock stepped)"
        }
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

        /// Seconds since the last frame, which every other figure here stops describing.
        ///
        /// A meter with nothing to record does not report a problem, it reports its last
        /// answer forever: thirty frames a second, no freezes, on a camera that stopped a
        /// minute ago and a report printed every five seconds saying so again. The gap
        /// between the last sample and now is the only figure that can tell a healthy stream
        /// apart from a dead one.
        var since: Double

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
                onKey: Int, period: Double, since: Double
            ) in
            let periods = stallPeriods.sorted()
            let typical = periods.isEmpty
                ? 0
                : periods[periods.count / 2]
            let waiting = last.map { seconds(since: $0) } ?? 0
            guard let first, let last, frames > 1 else {
                return (gaps.sorted(), frames, 0, freezes, 0, freezesOnKeyFrame, typical, waiting)
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
                typical,
                waiting
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
            period: snapshot.period,
            since: snapshot.since
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
            // Loudly, and only when it applies. A second of nothing is a hiccup; ten is the
            // whole diagnosis, and it is worth more than every percentile in front of it.
            + (reading.since > 1
                ? String(format: " · NOTHING FOR %.1fs", reading.since)
                : "")
    }

    private func seconds(since instant: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - instant
        return Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
    }
}
