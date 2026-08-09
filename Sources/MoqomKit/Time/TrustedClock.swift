// Putting this device on the server's timeline.
//
// The device's own wall clock is not an input here and never becomes one. It is
// a user setting — reachable from the Settings app, moved by anyone who wants a
// different answer — and it steps whenever the network corrects it. What this
// uses instead is a monotonic reading, which no setting touches, plus an offset
// measured against the authority. Someone setting their phone to 1999 changes
// nothing about the timecodes it produces.
//
// # Which monotonic clock
//
// `ContinuousClock`, not `SuspendingClock`, and the distinction is the one that
// breaks this feature if it is got wrong. On Apple platforms the familiar
// monotonic reading — `DispatchTime.now().uptimeNanoseconds`, which the session
// state machine uses for its deadlines — stops advancing while the device is
// asleep. A phone that syncs, sleeps in a pocket for an hour, and wakes would
// compute every timecode an hour in the past, confidently, with a tight
// uncertainty. `ContinuousClock` keeps counting through sleep, so the anchor
// survives it.
//
// # Why samples are filtered rather than averaged
//
// One exchange cannot separate the offset from the path. If a request takes 10ms
// out and 90ms back, the midpoint estimate is 40ms wrong and nothing in that
// single sample reveals it. What does reveal it is many samples: the round trip
// varies almost entirely by queueing, queueing is what makes a path asymmetric,
// and so the sample with the shortest round trip is the one with the least of
// both. Take the best, never the mean — averaging deliberately mixes the
// asymmetric samples back in.
//
// Which is also why the uncertainty on a reading is half the round trip of the
// sample behind it. That is not a guess at the error, it is the bound: the
// return path took somewhere between nothing and the whole round trip, so the
// truth is within half of it either way.

import Foundation
import MoqomCore

/// What the authority said when asked.
///
/// Two server timestamps rather than one because the gap between them is the
/// server's own processing, and subtracting it is what leaves the network delay
/// this is trying to halve. Without it a slow server looks like a distant one
/// and every reading is needlessly wide.
public struct AuthorityReading: Hashable, Sendable, Codable {
    /// Server time when the request arrived, nanoseconds since the epoch.
    public let receivedAt: Int64

    /// Server time when the reply was sent.
    public let repliedAt: Int64

    /// The authority's own uncertainty about those two numbers.
    ///
    /// A server disciplined by NTP knows roughly how well it is disciplined,
    /// and passing that on rather than assuming zero is what keeps the error
    /// bound honest end to end.
    public let uncertainty: Duration

    /// Whether the authority's clock is actually disciplined.
    ///
    /// `false` is not an error and must not be treated as one — it is the
    /// server being honest that its own clock is adrift, which is far more
    /// useful than a confident wrong answer. A client that gets this refuses to
    /// mark its readings synchronised.
    public let isDisciplined: Bool

    /// Whether a leap second lands at the end of the current UTC day.
    ///
    /// Cloudflare does not smear — it forwards the leap indicator and expects
    /// the kernel to step — so UTC really does repeat or skip a second, and a
    /// timeline that pretends otherwise is a second wrong across the boundary.
    /// See ``TrustedClock/leapWindow``.
    public let leapSecondPending: Bool

    public init(
        receivedAt: Int64,
        repliedAt: Int64,
        uncertainty: Duration,
        isDisciplined: Bool,
        leapSecondPending: Bool = false
    ) {
        self.receivedAt = receivedAt
        self.repliedAt = repliedAt
        self.uncertainty = uncertainty
        self.isDisciplined = isDisciplined
        self.leapSecondPending = leapSecondPending
    }
}

/// Something that can be asked what time it is, authoritatively.
///
/// Deliberately narrow. The transport is not this protocol's business: the
/// control plane answers over its authenticated channel today, and a relay
/// could answer at the edge tomorrow without anything above here changing.
public protocol TimeAuthority: Sendable {
    func read() async throws(MoqomError) -> AuthorityReading
}

/// This device's estimate of the trusted timeline.
public actor TrustedClock {
    /// How far a consumer crystal may drift, as a fraction expressed per second.
    ///
    /// A hundred parts per million: 100µs of error for every second since the
    /// last exchange, or about a third of a second an hour. Deliberately the
    /// pessimistic end of what cheap oscillators do across their temperature
    /// range rather than the typical figure, because this number's job is to
    /// bound the error and a bound that is usually right is not one.
    public static let maximumDrift = 100.0 / 1_000_000.0

    /// Beyond this much uncertainty, a reading stops claiming to be synchronised.
    ///
    /// Expressed as a quality rather than an age, which is the more useful test:
    /// what makes a reading unusable is how wide it has become, and a device
    /// with a good recent exchange and one that has been guessing for an hour
    /// are distinguished by exactly that.
    public static let trustCeiling = Duration.seconds(1)

    /// How many exchanges to keep and choose between.
    static let window = 8

    /// The gap between routine exchanges.
    ///
    /// At the drift bound above this admits about 30ms of growth between them,
    /// which is under a frame at 30fps and far under anything an event log
    /// cares about.
    public static let interval = Duration.seconds(300)

    /// Exchanges taken back to back when starting, to find a short round trip.
    ///
    /// One exchange on a bad path anchors everything to a bad path. A handful
    /// costs nothing once and usually finds something near the true propagation
    /// delay.
    static let burst = 4

    /// How far the poll interval is spread either side of ``interval``.
    ///
    /// A fleet is not a client. Every device polling exactly five minutes apart
    /// means every device that launched during the same minute polls in the
    /// same second forever, which is a self-inflicted flood against a service
    /// that is doing us a favour. A quarter either way decorrelates them.
    static let spread = 0.25

    /// A disagreement larger than this is treated as suspicious, not as news.
    ///
    /// Below it, a correction is just the path being what paths are. Above it,
    /// something has genuinely moved — a device woke up, or somebody is lying —
    /// and neither is worth acting on until a second exchange agrees.
    static let stepThreshold = Duration.seconds(1)

    /// How wide UTC goes when a leap second lands. See ``Anchor/leapAt``.
    static let leapWindow = Duration.seconds(1)

    private let authority: any TimeAuthority
    private nonisolated let continuous: @Sendable () -> Duration
    private let suspending: @Sendable () -> Duration
    private let logger: MoqomLogger

    /// The chosen anchor, mirrored where ``stamp`` can reach it.
    private nonisolated let published = Published()

    private var anchors: [Anchor] = []

    /// Exchanges that disagreed with the established estimate.
    ///
    /// Held rather than adopted or discarded, because at the moment one arrives
    /// there is no way to tell a hostile reply from a device that has just
    /// woken up somewhere else. A second exchange tells them apart.
    private var quarantine: [Anchor] = []

    private var pump: Task<Void, Never>?

    /// The sleep detector's last reading. See ``hasSlept()``.
    private var lastSuspending: Duration
    private var lastContinuous: Duration

    /// The trust level last written to the log, so transitions are said once.
    private var announced: TimeTrust?

    public init(
        authority: any TimeAuthority,
        logger: MoqomLogger = .silent,
        continuous: @escaping @Sendable () -> Duration = TrustedClock.systemContinuous,
        suspending: @escaping @Sendable () -> Duration = TrustedClock.systemSuspending
    ) {
        self.authority = authority
        self.logger = logger
        self.continuous = continuous
        self.suspending = suspending
        lastContinuous = continuous()
        lastSuspending = suspending()
    }

    deinit { pump?.cancel() }

    /// What time it is, and how well that is known.
    ///
    /// Never fails and never blocks. Before the first successful exchange this
    /// returns ``Timecode/fallback(_:)`` — the device's own clock, marked as
    /// such and given an uncertainty wide enough that nothing will mistakenly
    /// order two events by it.
    public func now() -> Timecode {
        let reading = continuous()
        return Self.timecode(from: mostInformative(at: reading), at: reading)
    }

    /// A timecode from an anchor, or the fallback when there is no usable one.
    ///
    /// Pulled out as a static function of its inputs so that ``stamp`` can run
    /// it off the actor, against a published copy of the same anchor.
    private static func timecode(from anchor: Anchor?, at reading: Duration) -> Timecode {
        guard let anchor else { return .fallback() }

        let elapsed = reading - anchor.continuous
        let uncertainty = anchor.uncertainty(after: elapsed)

        // Two ways to fall out of trust, and both matter. The reading may have
        // decayed past the ceiling, or the server may have told us its own
        // clock is adrift — in which case it was never trustworthy and no
        // amount of freshness makes it so.
        guard anchor.disciplined, uncertainty <= trustCeiling else { return .fallback() }

        return Timecode(
            nanoseconds: anchor.projected(after: elapsed),
            uncertainty: uncertainty,
            trust: .synchronised
        )
    }

    /// Read the clock without awaiting it.
    ///
    /// Logging is synchronous and this is an actor, so a log sink cannot await
    /// ``now()`` to stamp a record. Rather than make every call site async — or
    /// worse, let records go unstamped and lose the trusted-versus-fallback
    /// distinction exactly where it is most needed — the chosen anchor is
    /// published into a lock-protected box whenever it changes, and this reads
    /// that box against the monotonic clock.
    ///
    /// The result can be one poll interval staler than ``now()``, which the
    /// uncertainty already accounts for: an anchor's error bound grows with
    /// elapsed time whether or not anyone has looked at it.
    public nonisolated var stamp: @Sendable () -> Timecode {
        let published = published
        let continuous = continuous
        return { Self.timecode(from: published.load(), at: continuous()) }
    }

    /// Whether ``now()`` currently produces something worth comparing.
    public var isSynchronised: Bool { now().isTrusted }

    /// Whether ``now()`` is currently coming from the device's own clock.
    ///
    /// Worth exposing rather than leaving callers to invert ``isSynchronised``,
    /// because the two are used at different moments: one asks "can I order
    /// this", the other asks "should I tell someone". A recording UI that wants
    /// to warn before capture, or a host application deciding whether to upload
    /// an audit trail, is asking this one.
    public var isUsingFallback: Bool { !now().isTrusted }

    /// Take one exchange with the authority.
    ///
    /// Safe to call at any time; a failure leaves the previous estimate in
    /// place rather than discarding it, because a stale anchor with a growing
    /// uncertainty is strictly better than none and says so.
    @discardableResult
    public func synchronise() async -> Bool {
        let before = continuous()
        let reading: AuthorityReading
        do {
            reading = try await authority.read()
        } catch {
            logger.debug(.session, "time exchange failed", [
                LogField("error", .text(String(describing: error))),
            ])
            // A single failure is not yet a fallback — the previous anchor is
            // kept and stays good until it decays. But an unreachable reference
            // is the ordinary way a device ends up on its own clock, so this is
            // the path that most needs to notice when it finally has.
            announceTrust()
            return false
        }
        let after = continuous()

        // The round trip, with the server's own processing removed. Clamped at
        // zero because a server whose two stamps straddle a clock adjustment
        // can report a gap longer than the whole exchange, and a negative round
        // trip would produce a negative uncertainty — a reading that claims to
        // know more than perfectly.
        let elapsed = after - before
        let processing = Duration.nanoseconds(reading.repliedAt &- reading.receivedAt)
        let roundTrip = max(.zero, elapsed - max(.zero, processing))

        let trusted = reading.repliedAt &+ (roundTrip / 2).wholeNanoseconds
        adopt(
            Anchor(
                continuous: after,
                // The server's clock read `repliedAt` when it sent; by the time
                // it arrived, half a round trip had passed.
                trusted: trusted,
                measurement: roundTrip / 2 + reading.uncertainty,
                disciplined: reading.isDisciplined,
                leapAt: reading.leapSecondPending ? Self.endOfDay(containing: trusted) : nil
            )
        )

        let drift = anchors.last?.drift ?? .unmeasured
        logger.debug(.session, "time exchange", [
            LogField("roundTripMs", .number(Int(roundTrip.wholeNanoseconds / 1_000_000))),
            LogField("disciplined", .flag(reading.isDisciplined)),
            LogField("driftPpm", .number(Int((drift.rate * 1_000_000).rounded()))),
            LogField("driftBoundPpm", .number(Int((drift.bound * 1_000_000).rounded()))),
            LogField("anchors", .number(anchors.count)),
        ])
        announceTrust()
        return true
    }

    /// Say, once, when this clock starts or stops being believable.
    ///
    /// Falling back is not a failure the caller sees: ``now()`` keeps returning
    /// a plausible-looking instant, and every consumer that does not inspect
    /// ``Timecode/trust`` will carry on as though nothing happened. So the
    /// transition has to be announced, or the first anyone knows of it is a
    /// recording that will not line up weeks later.
    ///
    /// Deliberately not called from ``now()``. That is the method a log sink
    /// uses to stamp a record, and logging from inside it would be a loop.
    private func announceTrust() {
        let trust = now().trust
        guard trust != announced else { return }
        let previous = announced
        announced = trust

        guard trust == .fallback else {
            logger.info(.session, "trusted time established", [
                LogField("uncertaintyMs", .number(
                    Int(now().uncertainty.wholeNanoseconds / 1_000_000)
                )),
            ])
            return
        }
        logger.warning(.session, "trusted time lost, using the device clock", [
            LogField("previously", .text(previous?.rawValue ?? "never established")),
            LogField("consequence", .text("timecodes cannot be ordered against other devices")),
        ])
    }

    /// Take a new exchange, unless it is the only thing claiming what it claims.
    ///
    /// An exchange that broadly agrees with what we already believe is kept
    /// without ceremony. One that disagrees by more than everything involved
    /// could account for is held back, because at that moment it is
    /// indistinguishable from a forged reply — and a forged reply that is
    /// adopted is the whole attack. Waiting for a second exchange to say the
    /// same thing costs one poll interval and defeats it, while still letting
    /// a genuine step through: a device that really did move will keep being
    /// told so, and an attacker who can sustain that is on the path anyway.
    private func adopt(_ candidate: Anchor) {
        defer { trim() }
        guard let best = mostInformative(at: candidate.continuous) else {
            anchors.append(candidate)
            return
        }

        let elapsed = candidate.continuous - best.continuous
        let projected = best.projected(after: elapsed)
        let disagreement = Duration.nanoseconds((candidate.trusted &- projected).magnitude)
        let tolerated = max(
            (best.uncertainty(after: elapsed) + candidate.measurement) * 4,
            Self.stepThreshold
        )

        if disagreement <= tolerated {
            quarantine.removeAll()
            anchors.append(candidate)
            return
        }

        quarantine.append(candidate)
        guard corroborated() else {
            logger.warning(.session, "time exchange disagrees, holding", [
                LogField("byMs", .number(Int(disagreement.wholeNanoseconds / 1_000_000))),
            ])
            return
        }

        // Two exchanges now agree with each other and not with the history, so
        // the history is what is wrong. Replacing rather than appending matters:
        // leaving the old anchors in place would let `mostInformative` keep
        // choosing one of them for as long as its uncertainty stayed narrow.
        logger.info(.session, "trusted time stepped", [
            LogField("byMs", .number(Int(disagreement.wholeNanoseconds / 1_000_000))),
        ])
        anchors = quarantine
        quarantine = []
    }

    /// Whether the held exchanges agree with each other.
    private func corroborated() -> Bool {
        guard quarantine.count >= 2 else { return false }
        let previous = quarantine[quarantine.count - 2]
        let latest = quarantine[quarantine.count - 1]
        let elapsed = latest.continuous - previous.continuous
        let projected = previous.projected(after: elapsed)
        let disagreement = Duration.nanoseconds((latest.trusted &- projected).magnitude)
        return disagreement <= max(
            (previous.uncertainty(after: elapsed) + latest.measurement) * 4,
            Self.stepThreshold
        )
    }

    private func trim() {
        if anchors.count > Self.window { anchors.removeFirst(anchors.count - Self.window) }
        if quarantine.count > Self.window { quarantine.removeFirst(quarantine.count - Self.window) }
        remeasureDrift()
        published.store(mostInformative(at: continuous()))
    }

    /// Refit the local oscillator's rate across the anchors that are left.
    ///
    /// Every anchor gets the same estimate, including the old ones. They were
    /// taken by the same crystal, so a rate measured now is the best available
    /// description of what they have been doing since — and ``mostInformative``
    /// compares them by a projection that needs it.
    private func remeasureDrift() {
        guard let reference = anchors.first else { return }
        let drift = ClockDrift.estimate(
            from: anchors.map { anchor in
                let seconds = Double(
                    (anchor.continuous - reference.continuous).wholeNanoseconds
                ) / 1_000_000_000
                let accumulated = Double(
                    (anchor.trusted &- reference.trusted)
                        &- (anchor.continuous - reference.continuous).wholeNanoseconds
                ) / 1_000_000_000
                return ClockDrift.Observation(
                    seconds: seconds,
                    error: accumulated,
                    measurement: Double(anchor.measurement.wholeNanoseconds) / 1_000_000_000
                )
            }
        )
        for index in anchors.indices { anchors[index].drift = drift }
    }

    /// The chosen anchor, behind a lock so ``stamp`` can read it off the actor.
    ///
    /// A whole-value swap under a lock rather than anything cleverer: it is
    /// written once per exchange and read once per log record, so the lock is
    /// never contended and the atomicity is worth more than the speed.
    private final class Published: @unchecked Sendable {
        private let lock = NSLock()
        private var anchor: Anchor?

        fileprivate func store(_ value: Anchor?) { lock.withLock { anchor = value } }
        fileprivate func load() -> Anchor? { lock.withLock { anchor } }
    }

    /// The next UTC midnight at or after an instant, in nanoseconds.
    ///
    /// Where a pending leap second will be applied. Unix time defines every day
    /// as exactly 86400 seconds, which is the reason a leap is a discontinuity
    /// in it rather than an extra tick.
    static func endOfDay(containing nanoseconds: Int64) -> Int64 {
        let day: Int64 = 86400
        let seconds = nanoseconds / 1_000_000_000
        return (seconds / day + 1) * day * 1_000_000_000
    }

    /// Keep the estimate current for as long as the returned task lives.
    ///
    /// Bursts first, then settles into ``interval``. Also watches for the device
    /// having been asleep, because a timer does not fire while it is and the
    /// estimate on waking is as old as the nap.
    public func start() {
        guard pump == nil else { return }
        pump = Task { [weak self] in
            guard let self else { return }
            for _ in 0 ..< Self.burst {
                if Task.isCancelled { return }
                await synchronise()
                // Two seconds, not one. A burst is four packets at a server
                // that a great many clients share, and NTP's own conventions
                // put the floor around here.
                try? await Task.sleep(for: .seconds(2))
            }
            while !Task.isCancelled {
                // Checked far more often than a sync is due, so that waking up
                // is noticed promptly rather than at the end of an interval
                // that started before the device went to sleep.
                try? await Task.sleep(for: .seconds(10))
                if await self.shouldSynchronise() {
                    await self.synchronise()
                } else {
                    // Even when no exchange is due, the estimate may have aged
                    // past the ceiling since the last check. Falling back
                    // through decay is quieter than failing to reach the
                    // server and deserves the same announcement.
                    await self.announceTrust()
                }
            }
        }
    }

    public func stop() {
        pump?.cancel()
        pump = nil
    }

    /// Whether the estimate is due for refreshing.
    private func shouldSynchronise() -> Bool {
        if hasSlept() { return true }
        guard let newest = anchors.last else { return true }
        let elapsed = continuous() - newest.continuous

        // A leap second has landed under us and every reading is now a second
        // wide. Nothing else will clear that but a fresh exchange.
        if newest.hasLeapt(after: elapsed) { return true }

        // Jittered per check rather than per interval, which is the cheap way
        // to decorrelate a fleet: two devices that happen to be due in the same
        // second will roll differently and stop being due in the same second.
        let jitter = Double.random(in: -Self.spread ... Self.spread)
        let due = Self.interval + .nanoseconds(
            Int64(Double(Self.interval.wholeNanoseconds) * jitter)
        )
        return elapsed >= due
    }

    /// Whether the device has been asleep since this was last asked.
    ///
    /// The two clocks are the detector: both advance while awake, only the
    /// continuous one advances while asleep, so a gap between them is time
    /// spent suspended. Worth catching because nothing else will — a sleeping
    /// device runs no timers, so the first thing to notice is whatever asks.
    private func hasSlept() -> Bool {
        let continuousNow = continuous()
        let suspendingNow = suspending()
        let awake = suspendingNow - lastSuspending
        let total = continuousNow - lastContinuous
        lastContinuous = continuousNow
        lastSuspending = suspendingNow

        // A second of slack: the two readings are taken microseconds apart and
        // scheduling noise should not be mistaken for a nap.
        return total - awake > .seconds(1)
    }

    /// The anchor that currently tells us the most.
    ///
    /// Not simply the shortest round trip, and not simply the newest. An
    /// exchange over a fast path an hour ago has drifted; one over a slow path
    /// a second ago never knew much. Ranking them by what each is worth *now* —
    /// its measurement error plus everything it has drifted since — picks
    /// correctly between those without a rule for each case, and ages a good
    /// old sample out on its own.
    private func mostInformative(at reading: Duration) -> Anchor? {
        anchors.min { left, right in
            left.uncertainty(after: reading - left.continuous)
                < right.uncertainty(after: reading - right.continuous)
        }
    }

    /// One exchange, kept for as long as it is useful.
    private struct Anchor {
        /// The continuous reading this was taken at.
        let continuous: Duration

        /// Trusted time at that reading, in nanoseconds since the epoch.
        let trusted: Int64

        /// What the exchange itself could not pin down.
        let measurement: Duration

        let disciplined: Bool

        /// When a pending leap second lands, if the server warned of one.
        ///
        /// Projecting past it is the one case where more elapsed time makes a
        /// reading *categorically* worse rather than gradually worse: UTC
        /// repeats or skips a second, so an anchor taken before the boundary is
        /// a full second wrong after it, whatever its drift says.
        ///
        /// Widening rather than correcting is deliberate. The sign is knowable
        /// and applying it would be more accurate on paper, but leap seconds
        /// arrive about once a decade — the last was 2016 — and code that has
        /// never once run in production is not the thing to trust at the exact
        /// moment the timeline is discontinuous. Going wide is always safe, and
        /// ``shouldSynchronise()`` collapses the window to seconds by resyncing
        /// straight after the boundary rather than waiting for the next poll.
        let leapAt: Int64?

        /// The local oscillator's rate error as last measured.
        ///
        /// Carried on the anchor rather than read from the actor so that
        /// ``TrustedClock/timecode(from:at:)`` stays a pure function of its
        /// inputs, which is what lets ``TrustedClock/stamp`` run it off the
        /// actor against a published copy. Every anchor in the window is
        /// restamped when a new exchange improves the estimate.
        var drift: ClockDrift = .unmeasured

        /// Where this anchor says trusted time is, some time later.
        ///
        /// The rate correction is the difference between a clock that assumes
        /// the local crystal is perfect and one that has measured it. Without
        /// it the error is real but merely admitted to; with it the projection
        /// is right and the admission shrinks to what the measurement missed.
        func projected(after elapsed: Duration) -> Int64 {
            let nanoseconds = max(.zero, elapsed).wholeNanoseconds
            let correction = drift.correction(after: Double(nanoseconds) / 1_000_000_000)
            return trusted &+ nanoseconds &+ Int64(correction * 1_000_000_000)
        }

        /// What this anchor is worth after some time has passed.
        func uncertainty(after elapsed: Duration) -> Duration {
            let seconds = Double(max(.zero, elapsed).wholeNanoseconds) / 1_000_000_000
            let grown = Duration.nanoseconds(
                Int64(drift.uncertainty(after: seconds) * 1_000_000_000)
            )
            guard let leapAt, trusted &+ max(.zero, elapsed).wholeNanoseconds >= leapAt else {
                return measurement + grown
            }
            return measurement + grown + TrustedClock.leapWindow
        }

        /// Whether this anchor has been projected across a leap boundary.
        func hasLeapt(after elapsed: Duration) -> Bool {
            guard let leapAt else { return false }
            return trusted &+ max(.zero, elapsed).wholeNanoseconds >= leapAt
        }
    }
}

public extension TrustedClock {
    /// A clock that keeps counting while the device sleeps.
    static let systemContinuous: @Sendable () -> Duration = {
        ContinuousClock.now - continuousOrigin
    }

    /// A clock that stops while the device sleeps. Only used to spot the sleep.
    static let systemSuspending: @Sendable () -> Duration = {
        SuspendingClock.now - suspendingOrigin
    }

    // Arbitrary origins, fixed for the life of the process. Only differences
    // are ever taken, so where they start does not matter.
    private static let continuousOrigin = ContinuousClock.now
    private static let suspendingOrigin = SuspendingClock.now
}
