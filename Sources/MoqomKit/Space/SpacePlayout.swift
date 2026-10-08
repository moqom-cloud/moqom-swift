// Drawing a shared space smoothly, and in step with the picture beside it.
//
// The simulation ticks twenty times a second and the display refreshes sixty or
// a hundred and twenty. Drawing only the ticks steps; drawing them as they
// arrive puts network jitter on screen. So a renderer keeps a short history of
// what arrived, picks an instant slightly in the past, and draws the state at
// that instant by interpolating between the ticks either side of it.
//
// Which instant is the interesting question, and there are two answers.
//
// **In step with a video.** When the authority is also on camera — the host
// playing the game is the host on screen — a viewer is watching a picture that
// its own jitter buffer has already delayed. Drawing the board at the shared
// clock's "now" would put the ball ahead of the player's hand. Each tick is
// therefore stamped with the authority's capture clock too, the clock its video
// frames carry, and ``SpacePlayout/frame(alignedTo:)`` samples the board at the
// capture time of the frame being shown. The board and the picture then share a
// timeline exactly, whatever delay the video happens to be running at.
//
// **On the shared clock.** A viewer with no video to match — or a board run by
// somebody off camera — samples at trusted time minus a small playout delay,
// which puts every participant on the same instant to within their clock sync.
//
// The history is a value type with no clock in it, so a renderer can own one on
// the main actor and sample it synchronously in a frame callback.

import Foundation
import MoqomCore

/// One state of a shared space, with the instants it describes.
public struct SpaceSample: Hashable, Sendable {
    public var tick: SpaceTick
    public var state: SpaceSnapshot

    /// The instant on the shared timeline.
    public var at: Timecode

    /// The instant on the authority's capture clock, if it stamps one.
    public var media: FrameTimestamp?

    public init(tick: SpaceTick, state: SpaceSnapshot, at: Timecode, media: FrameTimestamp? = nil) {
        self.tick = tick
        self.state = state
        self.at = at
        self.media = media
    }
}

/// A space as it should be drawn at one instant.
public struct SpaceFrame: Hashable, Sendable {
    /// The state, with every pose interpolated to the instant asked for.
    ///
    /// Existence, ownership, and facts are those of the last tick at or before
    /// the instant: a thing spawned in the next tick has not appeared yet, and a
    /// thing removed in it is still there. Only motion is blended.
    public var state: SpaceSnapshot

    /// The tick the discrete parts of ``state`` come from.
    public var tick: SpaceTick

    /// How far past that tick the instant lies, in ticks: 0 on it, above 1 when
    /// extrapolating because the next one has not arrived.
    public var progress: Float

    public func pose(of id: SpaceEntityID) -> SpacePose? {
        state.entities[id]?.pose
    }
}

/// A short history of a space's states, sampled at any instant.
///
/// ```swift
/// var playout = SpacePlayout()
/// for await sample in space.states { playout.insert(sample) }
///
/// // In the frame callback:
/// if let frame = playout.frame(alignedTo: shownFrame.timestamp) {
///     draw(frame.state)
/// }
/// ```
public struct SpacePlayout: Sendable {
    /// Samples kept. A second and a half at twenty a second.
    public var capacity: Int

    /// How far past the newest sample motion is extrapolated before it holds.
    public var coasting: Duration

    private var samples: [SpaceSample] = []

    public init(capacity: Int = 32, coasting: Duration = .milliseconds(250)) {
        self.capacity = max(2, capacity)
        self.coasting = coasting
    }

    /// The playout delay for sampling on the shared clock.
    ///
    /// Two tick intervals: one to have the next tick to interpolate towards,
    /// and one for the jitter on the way to it. Shorter extrapolates on every
    /// late packet; longer is latency nobody asked for.
    public static func delay(tickRate: Double) -> Duration {
        .seconds(2 / max(1, tickRate))
    }

    public var latest: SpaceSample? { samples.last }
    public var count: Int { samples.count }
    public var isEmpty: Bool { samples.isEmpty }

    /// Add a state.
    ///
    /// Kept in tick order whatever order they arrive in. A sample from an
    /// epoch below the newest is dropped, and a newer epoch clears the history:
    /// a new authority's capture clock is a different clock, and interpolating
    /// between two authorities' worlds would slide entities between positions
    /// neither of them gave.
    public mutating func insert(_ sample: SpaceSample) {
        if let newest = samples.last {
            if sample.tick.epoch < newest.tick.epoch { return }
            if sample.tick.epoch > newest.tick.epoch { samples.removeAll(keepingCapacity: true) }
        }
        if let index = samples.lastIndex(where: { $0.tick <= sample.tick }) {
            if samples[index].tick == sample.tick {
                samples[index] = sample
            } else {
                samples.insert(sample, at: index + 1)
            }
        } else {
            samples.insert(sample, at: 0)
        }
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
    }

    public mutating func removeAll() {
        samples.removeAll()
    }

    /// The space at an instant on the shared timeline.
    ///
    /// Pass trusted time minus ``delay(tickRate:)``. Falls back to the newest
    /// state, uninterpolated, when the clocks involved cannot be compared — a
    /// fallback timecode is one machine's opinion of itself.
    public func frame(at time: Timecode) -> SpaceFrame? {
        guard let newest = samples.last else { return nil }
        guard time.isTrusted, samples.allSatisfy({ $0.at.isTrusted }) else {
            return SpaceFrame(state: newest.state, tick: newest.tick, progress: 0)
        }
        return frame(at: time.nanoseconds, keyedBy: { $0.at.nanoseconds })
    }

    /// The space at the capture time of a video frame from its authority.
    ///
    /// `nil` when the authority does not stamp its capture clock, in which case
    /// sample on the shared clock instead.
    public func frame(alignedTo media: FrameTimestamp) -> SpaceFrame? {
        guard !samples.isEmpty, samples.allSatisfy({ $0.media != nil }) else { return nil }
        let instant = Int64(clamping: media.nanoseconds)
        return frame(at: instant, keyedBy: { Int64(clamping: $0.media!.nanoseconds) })
    }

    private func frame(at instant: Int64, keyedBy key: (SpaceSample) -> Int64) -> SpaceFrame {
        let last = samples.count - 1
        guard last > 0 else {
            return SpaceFrame(state: samples[0].state, tick: samples[0].tick, progress: 0)
        }
        if instant <= key(samples[0]) {
            return SpaceFrame(state: samples[0].state, tick: samples[0].tick, progress: 0)
        }

        // The pair either side of the instant, or the last two when it is past
        // the newest — which is extrapolation, capped by ``coasting``.
        var upper = samples.firstIndex(where: { key($0) > instant }) ?? last
        if upper == 0 { upper = 1 }
        let start = samples[upper - 1]
        let end = samples[upper]
        let amount = Self.progress(
            from: key(start), to: key(end), at: instant, coasting: coasting.wholeNanoseconds
        )

        // Discrete state from the tick at or before the instant: the start of
        // the pair, unless the instant is past the newest.
        let extrapolating = instant >= key(end)
        var state = extrapolating ? end.state : start.state
        for id in Array(state.entities.keys) {
            guard
                let from = start.state.entities[id]?.pose,
                let to = end.state.entities[id]?.pose,
                from != to
            else { continue }
            state.entities[id]?.pose = SpacePose.interpolated(from: from, to: to, amount: amount)
        }
        return SpaceFrame(
            state: state,
            tick: extrapolating ? end.tick : start.tick,
            progress: extrapolating ? amount - 1 : amount
        )
    }

    /// Where `instant` sits between two keys: 0 at `start`, 1 at `end`, above 1
    /// past it up to the coasting cap. Saturating throughout, because the keys
    /// come off the wire.
    static func progress(from start: Int64, to end: Int64, at instant: Int64, coasting: Int64) -> Float {
        let (span, overflow) = end.subtractingReportingOverflow(start)
        guard !overflow, span > 0 else { return 1 }
        let cap = end.addingReportingOverflow(coasting)
        let ceiling = cap.overflow ? Int64.max : cap.partialValue
        let sampled = min(max(instant, start), ceiling)
        return Float((Double(sampled) - Double(start)) / Double(span))
    }
}
