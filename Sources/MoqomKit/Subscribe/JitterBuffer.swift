// The audio jitter buffer.
//
// A network delivers packets at irregular intervals; a speaker consumes them at
// exactly one rate. The buffer is what reconciles those, and every parameter in
// it is a trade between latency and gaps. Hold more and late packets arrive in
// time; hold less and the conversation is more responsive. There is no setting
// that wins both, which is why the depth adapts instead of being configured.
//
// Three things this does that a plain reorder queue does not:
//
//   - It measures interarrival jitter and sizes itself from the measurement,
//     using the RFC 3550 estimator. A fixed 100ms buffer is 80ms of pointless
//     delay on a good link and not enough on a bad one.
//   - It shrinks only during silence. Dropping the depth mid-word is audible
//     even when nothing is lost, because it discards or time-compresses real
//     audio; waiting for a silence period makes the same adjustment free.
//   - It distinguishes a gap from a silence. A packet that never arrived needs
//     concealment; a packet the encoder marked as silence needs quiet. Treating
//     them alike produces either audible artefacts during pauses or a
//     conspicuous hole where a word was.
//
// MOQT changes one thing about the classic design. There is no RTP sequence
// number; ordering comes from the object's group and object IDs, which are
// assigned by the publisher and are therefore already the right thing to sort
// by. What MOQT does not give is an arrival-time series — that has to be
// measured on receipt, which is what `insert(_:at:)` is for.

import Foundation
import MoqomCore

/// What to play next.
public enum JitterBufferOutput: Hashable, Sendable {
    /// A packet, ready on time.
    case packet(EncodedAudioFrame)

    /// Nothing arrived for this slot. The decoder should conceal.
    ///
    /// Distinct from ``silence`` because the correct response differs: a
    /// concealed packet is invented from the previous one and should fade, and
    /// a silent one is genuinely quiet.
    case gap

    /// The publisher sent nothing because there was nothing to send.
    case silence

    /// The buffer is still filling. Play nothing and do not treat it as loss.
    case buffering
}

/// A snapshot of what the buffer is doing, for a stats overlay or a bug report.
public struct JitterBufferStatistics: Hashable, Sendable {
    public var packetsReceived: Int = 0
    public var packetsPlayed: Int = 0

    /// Packets that arrived after their playout time and were thrown away.
    ///
    /// The number to look at when audio sounds choppy but the link looks fine:
    /// it means the buffer is too shallow for the jitter, not that packets were
    /// lost.
    public var packetsLate: Int = 0

    /// Packets that arrived twice.
    public var packetsDuplicate: Int = 0

    /// Slots that had to be concealed.
    public var gaps: Int = 0

    /// Current target depth.
    public var targetDelay: Duration = .zero

    /// The jitter estimate the target is derived from.
    public var jitter: Duration = .zero

    /// Steps in transit time that were re-anchored rather than measured.
    ///
    /// Each one is an interruption at this end -- a background, a lock, a capture
    /// stall -- and they are counted because the alternative reading is that the
    /// link went bad and recovered. A call with a handful of these and a low
    /// jitter figure was interrupted; a call with none and a high one is on a bad
    /// network, and the two want opposite responses.
    public var discontinuities: Int = 0
}

/// Reorders, de-duplicates, and paces audio packets.
///
/// Not an actor. It is driven by two callers on a strict schedule — the network
/// inserting and the audio device pulling — and both are already serialised by
/// whoever owns them. Making it an actor would add a hop to the audio callback,
/// which is the one place in the SDK where a hop can be heard.
public struct JitterBuffer: Sendable {
    /// The smallest depth worth having.
    ///
    /// One packet, because the buffer cannot reorder anything shallower and a
    /// buffer that cannot reorder is not a jitter buffer.
    public let minimumDelay: Duration

    /// The largest depth to grow to.
    ///
    /// Past this, a call is better served by admitting the link cannot carry it
    /// than by adding delay nobody can converse through.
    public let maximumDelay: Duration

    private let format: AudioFormat
    private var packets: [UInt64: EncodedAudioFrame] = [:]

    /// The next sequence number to play.
    private var playhead: UInt64?

    /// Highest sequence seen, for detecting how far ahead the sender is.
    private var highest: UInt64?

    private var target: Duration
    private var jitterEstimate: Double = 0
    private var lastTransit: Double?
    private var isFilling = true
    private var consecutiveSilences = 0
    private var statistics = JitterBufferStatistics()

    public init(
        format: AudioFormat = .voice,
        minimumDelay: Duration = .milliseconds(20),
        maximumDelay: Duration = .milliseconds(500)
    ) {
        self.format = format
        self.minimumDelay = minimumDelay
        self.maximumDelay = maximumDelay
        target = minimumDelay
        statistics.targetDelay = minimumDelay
    }

    public var stats: JitterBufferStatistics { statistics }

    /// Packets held, waiting to be played.
    public var depth: Int { packets.count }

    /// How much audio is buffered.
    public var bufferedDuration: Duration {
        format.frameDuration * packets.count
    }

    // MARK: - Input

    /// Take a packet off the network.
    ///
    /// - Parameters:
    ///   - sequence: The packet's position in the stream. Derived from the
    ///     MOQT object's location, not invented here — the publisher already
    ///     numbered it and re-deriving order from arrival would defeat the
    ///     purpose.
    ///   - packet: The compressed audio.
    ///   - arrival: When it was received, on a monotonic clock.
    public mutating func insert(
        sequence: UInt64,
        _ packet: EncodedAudioFrame,
        at arrival: Duration
    ) {
        statistics.packetsReceived += 1
        updateJitter(sequence: sequence, sent: packet.timestamp, arrival: arrival)

        if !isFilling, let playhead, sequence < playhead {
            // Arrived after its slot came and went. Playing it now would put it
            // out of order with what has already been heard, which is worse
            // than the gap it left.
            statistics.packetsLate += 1
            return
        }
        if packets[sequence] != nil {
            statistics.packetsDuplicate += 1
            return
        }

        packets[sequence] = packet
        highest = max(highest ?? sequence, sequence)

        // While filling, the playhead follows the *lowest* sequence seen rather
        // than the first one to arrive. Nothing has been played yet, so nothing
        // is late — and a burst whose first packet to land is not its first
        // packet is the ordinary case on a link with any reordering at all.
        playhead = isFilling ? min(playhead ?? sequence, sequence) : (playhead ?? sequence)

        if isFilling, bufferedDuration >= target {
            isFilling = false
        }
    }

    // MARK: - Output

    /// Pull the next slot's worth of audio.
    ///
    /// Called once per packet duration by whatever drives the speaker. It
    /// always returns something, because the audio device always needs
    /// something: a hole in the callback is worse than concealment.
    public mutating func next() -> JitterBufferOutput {
        guard let position = playhead else { return .buffering }
        if isFilling {
            // Do not start until there is enough held to absorb the jitter that
            // has already been measured. Starting early guarantees an immediate
            // gap and then a resync, which sounds like a fault.
            guard bufferedDuration >= target else { return .buffering }
            isFilling = false
        }

        playhead = position + 1

        guard let packet = packets.removeValue(forKey: position) else {
            // Missing. If the sender has moved well past this point the packet
            // is lost; if it has not, the buffer has simply drained and it is
            // better to wait than to conceal audio that is still coming.
            if let highest, highest > position {
                statistics.gaps += 1
                return .gap
            }
            isFilling = true
            return .buffering
        }

        statistics.packetsPlayed += 1

        if packet.isSilence {
            consecutiveSilences += 1
            // Silence is when the depth can be changed for free: shortening a
            // pause is inaudible, and shortening a word is not.
            if consecutiveSilences >= 2 { applyTargetDuringSilence() }
            return .silence
        }

        consecutiveSilences = 0
        return .packet(packet)
    }

    /// Discard everything and start over.
    ///
    /// For a resubscribe or a track switch, where the old packets belong to a
    /// stream that no longer exists.
    public mutating func reset() {
        packets.removeAll()
        playhead = nil
        highest = nil
        isFilling = true
        consecutiveSilences = 0
    }

    // MARK: - Adaptation

    /// RFC 3550's interarrival jitter estimator.
    ///
    /// A first-order filter over the difference in transit times between
    /// consecutive packets, with a gain of 1/16. Worth using the standard one
    /// rather than something invented: its behaviour under bursty loss is known
    /// and it is what every other stack's numbers mean, so a jitter figure from
    /// MOQOM is comparable to one from anything else.
    private mutating func updateJitter(
        sequence _: UInt64,
        sent: FrameTimestamp,
        arrival: Duration
    ) {
        let arrivalSeconds = Double(arrival.components.seconds)
            + Double(arrival.components.attoseconds) / 1e18
        let sentSeconds = Double(sent.nanoseconds) / 1e9
        let transit = arrivalSeconds - sentSeconds

        defer { lastTransit = transit }
        guard let previous = lastTransit else { return }

        let difference = abs(transit - previous)

        // A step, not jitter. Transit time moves by this much when the receiving
        // application was not running: backgrounded, screen locked, or held
        // through a capture interruption. Everything queues, then arrives at once,
        // and the first packet afterwards is late by however long the excursion
        // lasted -- which this filter, whose whole purpose is to notice packets
        // arriving at uneven times, reads as the link having become wildly
        // unreliable. It then sizes the buffer for that and, because the way back
        // down needs the far end to fall silent, holds it there for the rest of
        // the call. A quarter of a second is far more than scheduling or a bad
        // route ever accounts for, and it is the same threshold the video
        // timeline re-anchors on, for the same reason.
        //
        // Re-anchored rather than clamped: `lastTransit` has already been updated
        // by the `defer` above, so the next packet is measured against the new
        // baseline and the estimator carries on describing the link.
        guard difference < Self.aStepRatherThanJitter else {
            statistics.discontinuities += 1
            return
        }

        jitterEstimate += (difference - jitterEstimate) / 16

        // Three times the jitter estimate covers the great majority of a
        // roughly normal delay distribution. Two is audibly tight and four
        // spends latency on outliers that concealment handles better.
        let wanted = Duration.seconds(jitterEstimate * 3)
        let clamped = min(max(wanted, minimumDelay), maximumDelay)

        statistics.jitter = .seconds(jitterEstimate)

        // Growth is immediate because being too shallow is actively losing
        // audio right now.
        if clamped > target {
            target = clamped
            statistics.targetDelay = target
            packetsWantingLess = 0
        } else {
            pendingTarget = clamped
            relax(towards: clamped)
        }
    }

    /// A change in transit time past this is an interruption rather than jitter.
    private static let aStepRatherThanJitter = 0.25

    /// Let the target down when the link has not justified it for a while.
    ///
    /// Silence is the free moment to change depth and used to be the only one, on
    /// the reasoning that shortening a pause is inaudible and shortening a word is
    /// not. That is true and it is not enough: the pauses have to arrive, and
    /// whether they do is the *publisher's* voice detector's business, not this
    /// link's. A room with a fan in it sends no silence at all, so a target that
    /// went up during one bad second stayed up for the whole call -- measured at
    /// 227ms against a link whose jitter was 5.4ms, which is fourteen times what
    /// the formula asks for, with the picture held back to match it.
    ///
    /// So the depth also comes down on evidence, slowly, whether or not anybody
    /// stops talking. Slowly matters twice over: the target falling does not by
    /// itself drop a sample -- it lets the queue drain through the paths that
    /// already exist -- and a target that chased the estimate downwards would
    /// undo the growth that a genuinely bursty link needs.
    private mutating func relax(towards wanted: Duration) {
        guard wanted < target else {
            packetsWantingLess = 0
            return
        }
        packetsWantingLess += 1

        // Fifty packets to the second, so this is two seconds of a link that has
        // not needed the depth it is holding, and five milliseconds off it each
        // time: a quarter of a second of excess unwinds in about a minute and a
        // half of speech. Faster than the call, slower than a gust.
        guard packetsWantingLess >= 100 else { return }
        packetsWantingLess = 0
        target = max(wanted, target - .milliseconds(5))
        statistics.targetDelay = target
    }

    private var packetsWantingLess = 0

    private var pendingTarget: Duration?

    private mutating func applyTargetDuringSilence() {
        guard let pending = pendingTarget, pending < target else { return }
        target = pending
        pendingTarget = nil
        statistics.targetDelay = target

        // Drop the excess now that it costs nothing to lose.
        while bufferedDuration > target, let position = playhead {
            guard packets.removeValue(forKey: position) != nil else { break }
            playhead = position + 1
        }
    }
}
