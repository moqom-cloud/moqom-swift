// Measuring the link instead of being told about it.
//
// `updateLayout(_:linkBitrate:)` used to take the available bandwidth as a
// parameter, which quietly made every integrator responsible for the hardest
// problem in real-time media. This is the thing that answers it.
//
// The method is delay-gradient estimation, the receive side of what WebRTC
// calls GCC. The idea in one paragraph: if the sender emits two frames 33ms
// apart and they arrive 40ms apart, something in the path queued the second one
// for 7ms. One such measurement is noise. A *trend* of them is a queue building
// somewhere, and a queue building means the send rate is above the path
// capacity — which is knowable before a single packet is lost.
//
// That last point is why loss is not the primary signal. By the time a router
// drops something, its buffer has been full for a while, and on a modern
// bufferbloated access network "a while" can be hundreds of milliseconds of
// added latency. A controller that waits for loss converges to a rate that
// keeps the buffer full, which is exactly the wrong place for interactive
// media. Loss is kept as a backstop for paths that drop without queueing.
//
// Three parameters are worth knowing about because they are the ones tuned by
// a decade of other people's field data rather than by anything we can derive:
// the 0.85 multiplicative decrease, the 1.05 multiplicative increase, and the
// adaptive threshold's rate of change. They come from GCC. Changing them is a
// research project, not a tuning exercise.

import Foundation
import MoqomCore

/// What the controller is doing right now.
public enum BandwidthState: String, Hashable, Sendable {
    /// The path looks clear. Probe upward.
    case increasing

    /// A queue is building or has just been drained. Do not add load.
    case holding

    /// A queue is building. Back off, hard enough to drain it.
    case decreasing
}

/// A live estimate of what the downlink can carry.
///
/// Not an actor: it is fed from one place, on the receive path, at object rate.
/// An actor hop per object would be a measurable cost for a synchronous
/// arithmetic update.
public struct BandwidthEstimator: Sendable {
    /// The current estimate, in bits per second.
    public private(set) var estimate: Int

    /// Throughput actually observed over the recent window.
    public private(set) var receivedBitrate: Int = 0

    public private(set) var state: BandwidthState = .increasing

    /// The smoothed one-way delay trend, in milliseconds per second of media.
    ///
    /// Positive means the path is adding delay. Exposed because it is the
    /// single most useful number in a support ticket about a stream that is
    /// blurry on a link that speed-tests fine.
    public private(set) var delayTrend: Double = 0

    /// Objects that never arrived, inferred from gaps in object IDs.
    public private(set) var objectsLost = 0
    public private(set) var objectsReceived = 0

    public let minimumBitrate: Int
    public let maximumBitrate: Int

    // Arrival window, for the throughput measurement.
    private var window: [(bytes: Int, at: Duration)] = []
    private let windowDuration: Duration = .milliseconds(500)

    // Delay-gradient state.
    private var lastArrival: Duration?
    private var lastSent: Duration?
    private var accumulatedDelay: Double = 0
    private var trendSamples: [(index: Double, delay: Double)] = []
    private var threshold: Double = 12.5
    private var lastThresholdUpdate: Duration?
    private var overuseSince: Duration?
    private var sampleIndex: Double = 0

    // Loss detection, per track.
    //
    // `following` is whether this track's numbering has been seen to advance by exactly one,
    // which is the only state in which a gap means anything. A subscription does not begin at
    // the live edge: the relay replays the current group from its start so the subscriber has a
    // keyframe, and those objects arrive interleaved with the live ones. Until the two are told
    // apart, an arriving object ID says nothing about what is missing.
    private var highestObject: [UInt64: (group: UInt64, object: UInt64, following: Bool)] = [:]

    private var lastChange: Duration?

    public init(
        initialBitrate: Int = 600_000,
        minimumBitrate: Int = 50_000,
        maximumBitrate: Int = 20_000_000
    ) {
        estimate = initialBitrate
        self.minimumBitrate = minimumBitrate
        self.maximumBitrate = maximumBitrate
    }

    /// Record an object's arrival.
    ///
    /// - Parameters:
    ///   - object: What arrived. Its capture time is the send timestamp the
    ///     gradient is measured against, which is why the publisher puts it in
    ///     the object properties rather than inside the encrypted payload.
    ///   - trackAlias: Used only to detect gaps per track.
    ///   - arrival: Receipt time on a monotonic clock.
    public mutating func record(
        _ object: TrackObject,
        trackAlias: UInt64 = 0,
        at arrival: Duration
    ) {
        objectsReceived += 1
        recordLoss(object, trackAlias: trackAlias)
        recordThroughput(bytes: object.payload.count, at: arrival)

        guard let sent = object.properties.captureTime else {
            // Without a send timestamp there is no gradient to measure, only
            // throughput. Better than nothing and much worse than the real
            // thing, so it does not drive the state machine.
            return
        }
        recordGradient(sent: .nanoseconds(Int64(sent.nanoseconds)), arrival: arrival)
        updateEstimate(at: arrival)
    }

    /// Reset after a network change.
    ///
    /// A Wi-Fi to cellular handover is a different path, and carrying the old
    /// path's estimate across it is worse than starting over: the delay history
    /// describes a queue that no longer exists.
    public mutating func reset(to bitrate: Int? = nil) {
        estimate = bitrate ?? estimate
        receivedBitrate = 0
        window.removeAll()
        trendSamples.removeAll()
        lastArrival = nil
        lastSent = nil
        accumulatedDelay = 0
        overuseSince = nil
        state = .increasing
    }

    // MARK: - Throughput

    private mutating func recordThroughput(bytes: Int, at arrival: Duration) {
        window.append((bytes, arrival))
        let cutoff = arrival - windowDuration
        window.removeAll { $0.at < cutoff }

        guard let first = window.first, window.count > 1 else { return }
        let span = seconds(arrival - first.at)
        guard span > 0 else { return }
        receivedBitrate = Int(Double(window.reduce(0) { $0 + $1.bytes } * 8) / span)
    }

    // MARK: - Loss

    /// Count what is missing in front of this object, where that can be known.
    ///
    /// Against the highest object seen rather than the last one, and only once the numbering has
    /// been seen to step by one. Both halves of that were learned from a measurement that was
    /// wrong for a whole afternoon.
    ///
    /// Comparing against the *last* object assumes a track arrives in one ordered sequence, and
    /// at the start of a subscription it does not. The relay replays the current group from its
    /// beginning so the subscriber has a keyframe to decode from, while the live edge keeps
    /// arriving, and the two interleave: object 0, then 58, then 1, then 59, then 2, then 60.
    /// Read as one sequence that is 57 objects short on every other arrival, and the counter
    /// reported about 2,900 objects lost in the first five seconds of a session in which every
    /// single frame was accounted for, nothing froze, and 99.8 percent was delivered. It then
    /// never moved again, because the interleaving stops once the replay catches up. Against the
    /// highest, a replayed object is simply not news and passes without comment.
    ///
    /// That alone leaves one spurious gap - the first step from the replay to the live edge,
    /// which is indistinguishable from real loss on the evidence of two object IDs. Hence
    /// `following`: until a track has been observed advancing by exactly one, there is no
    /// established sequence to be missing from, so nothing is counted. The cost is that genuine
    /// loss in the first moments of a subscription goes unreported, which is the right way to be
    /// wrong for a figure whose whole purpose is to say when a link is in trouble.
    private mutating func recordLoss(_ object: TrackObject, trackAlias: UInt64) {
        guard let previous = highestObject[trackAlias], object.group == previous.group else {
            highestObject[trackAlias] = (object.group, object.object, false)
            return
        }

        // Behind the high-water mark: a replay, or a reorder. Neither is evidence of loss, and
        // neither moves the mark.
        guard object.object > previous.object else { return }

        if object.object == previous.object + 1 {
            highestObject[trackAlias] = (object.group, object.object, true)
            return
        }

        if previous.following {
            objectsLost += Int(object.object - previous.object - 1)
        }
        highestObject[trackAlias] = (object.group, object.object, previous.following)
    }

    // MARK: - Delay gradient

    private mutating func recordGradient(sent: Duration, arrival: Duration) {
        defer {
            lastArrival = arrival
            lastSent = sent
        }
        guard let lastArrival, let lastSent else { return }

        // The interarrival delta: how much longer the gap between two frames
        // got in transit than it was at the source.
        let delta = seconds(arrival - lastArrival) - seconds(sent - lastSent)

        // Frames out of order, or a clock that jumped. A negative send delta
        // means the timestamps do not describe a sequence and the sample says
        // nothing about queueing.
        guard sent >= lastSent else { return }

        accumulatedDelay += delta * 1000
        sampleIndex += 1
        trendSamples.append((sampleIndex, accumulatedDelay))
        if trendSamples.count > 20 { trendSamples.removeFirst() }

        delayTrend = Self.slope(of: trendSamples)
    }

    /// Least-squares slope. The trend, not the last sample.
    private static func slope(of samples: [(index: Double, delay: Double)]) -> Double {
        guard samples.count >= 4 else { return 0 }
        let n = Double(samples.count)
        let meanX = samples.reduce(0) { $0 + $1.index } / n
        let meanY = samples.reduce(0) { $0 + $1.delay } / n
        var numerator = 0.0
        var denominator = 0.0
        for sample in samples {
            numerator += (sample.index - meanX) * (sample.delay - meanY)
            denominator += (sample.index - meanX) * (sample.index - meanX)
        }
        guard denominator > 0 else { return 0 }
        return numerator / denominator
    }

    // MARK: - Control

    private mutating func updateEstimate(at now: Duration) {
        guard trendSamples.count >= 4 else { return }

        // Scaled by sample count so that a shallow trend over many samples
        // counts as much as a steep one over few, which is what stops the
        // detector from firing on a single late frame.
        let modified = delayTrend * Double(min(trendSamples.count, 60)) * 4

        let detected: BandwidthState
        if modified > threshold {
            // Sustained, not instantaneous. A burst of a few late frames is
            // ordinary; a queue that stays built for 100ms is not.
            if overuseSince == nil { overuseSince = now }
            detected = seconds(now - (overuseSince ?? now)) > 0.1 ? .decreasing : .holding
        } else if modified < -threshold {
            overuseSince = nil
            detected = .holding
        } else {
            overuseSince = nil
            detected = .increasing
        }

        adaptThreshold(modified: modified, at: now)
        apply(detected, at: now)
    }

    /// The threshold moves with the observed noise.
    ///
    /// A fixed threshold either misses real congestion on a noisy path or fires
    /// constantly on a jittery one. It also has to rise faster than it falls,
    /// or a controller competing with a TCP flow gets starved: the TCP flow
    /// keeps the queue full, the threshold keeps dropping, and this controller
    /// keeps yielding.
    private mutating func adaptThreshold(modified: Double, at now: Duration) {
        defer { lastThresholdUpdate = now }
        guard let last = lastThresholdUpdate else { return }
        guard abs(modified) <= threshold + 15 else { return }

        let elapsed = min(seconds(now - last), 0.1)
        let gain = abs(modified) < threshold ? 0.039 : 0.0087
        threshold += gain * (abs(modified) - threshold) * elapsed * 1000
        threshold = min(max(threshold, 6), 600)
    }

    private mutating func apply(_ detected: BandwidthState, at now: Duration) {
        let sinceChange = lastChange.map { seconds(now - $0) } ?? .infinity
        state = detected

        switch detected {
        case .decreasing:
            // Down to a fraction of what is *actually arriving*, not of the
            // previous estimate. The estimate may be fiction; the measured
            // throughput is not, and multiplying fiction by 0.85 converges
            // slowly enough to be audible.
            guard sinceChange > 0.2 else { return }
            let base = receivedBitrate > 0 ? receivedBitrate : estimate
            estimate = clamp(Int(Double(base) * 0.85))
            lastChange = now
            overuseSince = nil

        case .increasing:
            guard sinceChange > 0.5 else { return }
            // Multiplicative while far from the known ceiling, so recovery
            // after a dip is quick; additive near it, so probing does not
            // repeatedly overshoot into the queue it just drained.
            let headroom = receivedBitrate > 0
                ? Double(estimate) / Double(max(receivedBitrate, 1))
                : 1
            estimate = headroom > 1.5
                ? clamp(estimate + 8000)
                : clamp(Int(Double(estimate) * 1.05))
            lastChange = now

        case .holding:
            break
        }
    }

    private func clamp(_ value: Int) -> Int {
        min(max(value, minimumBitrate), maximumBitrate)
    }

    private func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
