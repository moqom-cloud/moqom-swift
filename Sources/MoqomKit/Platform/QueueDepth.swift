// How much audio to keep waiting in front of the speaker.
//
// Three different quantities decide it, and the fault this type was extracted to fix was one of
// them being used for all three.
//
// The link's jitter is what the jitter buffer measures and what it needs: how unevenly one
// packet follows another over the network. It says nothing about this queue, because this queue
// is not filled by the network. It is filled whenever a packet arrives and the jitter buffer is
// drained in one go, and it is emptied by the audio device at a fixed rate — so what empties it
// is a *pause between arrivals*, which is a different measurement with a different answer.
//
// Measured on a call: 4.1ms of link jitter, so the queue aimed at its 40ms minimum, while
// arrivals bunched into bursts a hundred and twenty milliseconds apart. The queue filled to
// 120ms on every burst, the rule that keeps it from growing without bound judged that far past
// the 40ms being aimed for and threw away 699 packets — fourteen seconds of somebody talking —
// and the device then ran dry 500 times in the gaps between the bursts it had just emptied.
// Starving and overflowing at once is not two faults. It is one queue measured against the
// wrong thing.
//
// The third quantity is this device: a thermal throttle, a route change, a decoder waiting on
// an actor. None of that is visible in either of the other two and all of it empties the queue
// just the same, so it is answered by its own evidence — the device asking for samples that
// were not there.

/// The depth a playout queue should hold, and why.
struct QueueDepth: Sendable {
    /// The smallest depth worth holding, whatever the measurements say.
    static let leastWorthHolding = Duration.milliseconds(40)

    /// The largest. Past this a call is better served by admitting the link cannot carry it.
    static let mostWorthHolding = Duration.milliseconds(400)

    /// What the link's jitter asks for, as the jitter buffer measured it.
    private(set) var aim = Duration.milliseconds(60)

    mutating func aim(at delay: Duration) {
        aim = max(Self.leastWorthHolding, min(delay, Self.mostWorthHolding))
    }

    // MARK: - What the feed asks for

    /// How far back to look for the worst pause. Long enough to hold more than one, short
    /// enough that a burst of trouble is forgotten once it stops.
    static let recently = Duration.seconds(5)

    /// Past this, the pauses are not something a queue should paper over.
    static let longestPauseWorthCovering = Duration.milliseconds(200)

    private var quiets: [(at: Duration, gap: Duration)] = []
    private var lastFed: Duration?

    /// The longest pause between arrivals lately.
    ///
    /// A plain maximum rather than a quantile. A queue that covers the typical pause and not
    /// the long one starves on the long one, which is the only case anybody can hear.
    var covering: Duration { quiets.map(\.gap).max() ?? .zero }

    /// The shape of the arrivals, not just their worst case.
    ///
    /// ``covering`` says how long the worst pause was and deliberately nothing else, which is
    /// all a queue needs and not enough to fix anything upstream. Two very different links
    /// produce the same figure: one delivering an even packet every twenty milliseconds and
    /// stalling once, and one delivering four at a time and resting between. The first wants
    /// the stall explained; the second is not stalling at all, it is being paced that way, and
    /// no amount of buffering addresses the cause.
    ///
    /// The median separates them at a glance. A median near the packet cadence is an even feed;
    /// a median near zero with a large ``covering`` is a feed arriving in bunches.
    var pacing: (typical: Duration, worst: Duration, samples: Int) {
        let gaps = quiets.map(\.gap).sorted()
        guard !gaps.isEmpty else { return (.zero, .zero, 0) }
        return (gaps[gaps.count / 2], gaps[gaps.count - 1], gaps.count)
    }

    /// Note that the pipeline was fed.
    ///
    /// - Parameter now: Time on any steadily running clock; only differences are read.
    mutating func fed(at now: Duration) {
        defer { lastFed = now }
        quiets.removeAll { now - $0.at > Self.recently }
        guard let lastFed else { return }
        let gap = now - lastFed
        guard gap > .zero else { return }
        quiets.append((at: now, gap: min(gap, Self.longestPauseWorthCovering)))
    }

    // MARK: - What this device asks for

    /// What neither measurement covered, added to both.
    ///
    /// Up quickly, because the evidence is a dropout somebody heard, and down slowly, because
    /// the absence of dropouts is not evidence that the next one will not happen.
    private(set) var pressure = Duration.zero
    private var starvedBefore = 0
    private var cleanPackets = 0
    private var primed = false

    /// Fold what the device has been doing into the depth being held.
    mutating func answer(starved: Int, whileSpeaking speaking: Bool) {
        // The device asks for samples from the moment the engine runs, and the first ones
        // arrive whenever the room gets round to sending them. Everything before the first
        // packet is a device waiting to be joined, not a queue that was too shallow.
        guard primed else {
            primed = true
            starvedBefore = starved
            return
        }

        if starved > starvedBefore {
            starvedBefore = starved
            guard speaking else { return }
            cleanPackets = 0
            pressure = min(.milliseconds(120), pressure + .milliseconds(20))
            return
        }

        cleanPackets += 1
        // Fifty packets to the second, so this is five seconds of a device that asked for
        // nothing it did not get. Slower than the rise by a wide margin, and still fast enough
        // that a single bad minute is not paid for until the call ends: an earlier version gave
        // back ten milliseconds every ten seconds, which on two phones meant a queue that
        // reached its ceiling in the first minute and was still there three minutes later,
        // holding the picture back with it.
        guard cleanPackets >= 250, pressure > .zero else { return }
        cleanPackets = 0
        pressure = max(.zero, pressure - .milliseconds(10))
    }

    // MARK: - What comes of the three

    /// The depth actually being held.
    ///
    /// The larger of the two measurements plus what neither of them saw. Not their sum: the
    /// link's unevenness and the feed's pauses are two views of the same packets arriving, so
    /// adding them would pay for the same delay twice.
    var target: Duration { max(aim, covering) + pressure }
}
