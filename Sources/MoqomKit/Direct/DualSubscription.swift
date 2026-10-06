// One track, read over the relay and a direct path at once, delivered once.
//
// The relay subscription is opened first and is never closed: it is the
// fallback, and a fallback that has to be re-established is a gap. A direct
// subscription is attached when one exists, and the two are merged by object
// identity, so whichever path delivers an object first wins and the copy that
// arrives second is dropped. The rules are `moqom_client::direct::DualSubscription`'s.
//
// - **Relay.** Relay objects are delivered. A newly attached direct path is on
//   probation: its objects are delivered too when they win the race, and it is
//   watched.
// - **Direct.** Entered once the direct path has kept up for
//   ``DirectPathSettings/settle``. Relay objects are held, briefly, in case the
//   direct path turns out to have lost them.
// - **Back to relay.** If the relay has held an object for
//   ``DirectPathSettings/stall`` that the direct path has not delivered, the
//   direct path is presumed lost: it is dropped and the held objects are
//   delivered in order. The same happens at once if the direct subscription
//   ends, and when the caller reports a network change.
//
// Stalls are judged against the relay rather than against a clock, so a
// publisher that simply stops sending does not look like a broken path.
//
// Once on the direct path, the relay is asked to stop forwarding the track
// (draft-19's FORWARD=0 in a REQUEST_UPDATE), because a copy nobody plays is
// still relay egress somebody pays for. The subscription stays open, so the
// fallback is one message rather than a new subscription. Two things resume
// it: any fallback, and the direct path going quiet for
// ``DirectPathSettings/quiet`` while the relay is paused, because with no relay
// copy a silent direct path cannot be judged against one. A relay resumes at
// the next group, so what a fallback from a paused relay costs is the rest of
// the group in flight; ``DirectPathSettings/pausesRelay`` turns the pause off
// for a track where that matters more than the egress.

import Foundation

/// Which path an object arrived over.
public enum DirectPath: Hashable, Sendable {
    case relay
    case direct
}

/// When to trust the direct path, and when to stop.
public struct DirectPathSettings: Hashable, Sendable {
    /// How long a direct path must keep up before the relay copy is set aside.
    public var settle: Duration

    /// How long the relay may hold an object the direct path has not delivered
    /// before the direct path is abandoned. What a fallback costs in added
    /// delay on the objects caught in it.
    public var stall: Duration

    /// How many relay objects to hold while on the direct path.
    public var held: Int

    /// Whether to ask the relay to stop forwarding while the direct path is in
    /// use.
    public var pausesRelay: Bool

    /// How long the direct path may deliver nothing, while the relay is
    /// paused, before the relay is asked to resume.
    public var quiet: Duration

    public init(
        settle: Duration = .seconds(3),
        stall: Duration = .milliseconds(250),
        held: Int = 1024,
        pausesRelay: Bool = true,
        quiet: Duration = .milliseconds(500)
    ) {
        self.settle = settle
        self.stall = stall
        self.held = max(1, held)
        self.pausesRelay = pausesRelay
        self.quiet = quiet
    }
}

/// One delivered object, and the path that won the race for it.
public struct DirectDelivery: Hashable, Sendable {
    public let object: TrackObject
    public let path: DirectPath
}

/// The merge itself, with time passed in, so every race can be stated in a test.
struct DirectPathSelector: Sendable {
    typealias Instant = ContinuousClock.Instant

    struct Key: Hashable, Comparable, Sendable {
        let group: UInt64
        let object: UInt64

        init(_ object: TrackObject) {
            group = object.group
            self.object = object.object
        }

        static func < (lhs: Key, rhs: Key) -> Bool {
            (lhs.group, lhs.object) < (rhs.group, rhs.object)
        }
    }

    /// How many delivered identities are remembered for deduplication.
    static let remembered = 4096

    let settings: DirectPathSettings
    private(set) var onDirect = false
    private(set) var hasDirect = false
    private(set) var switches = 0
    private var keepingUpSince: Instant?
    private var held: [Key: (TrackObject, Instant)] = [:]
    private var awaiting: [Key: Instant] = [:]
    private var delivered: Set<Key> = []
    private var deliveredOrder: [Key] = []

    init(settings: DirectPathSettings) {
        self.settings = settings
    }

    var path: DirectPath { onDirect ? .direct : .relay }

    mutating func attachDirect() {
        hasDirect = true
        keepingUpSince = nil
        awaiting.removeAll()
    }

    /// The next instant something is due: a held object stalling, or a
    /// probationary path falling behind.
    var deadline: Instant? {
        let stalling = held.values.map(\.1).min().map { $0 + settings.stall }
        let lagging = awaiting.values.min().map { $0 + settings.stall }
        return [stalling, lagging].compactMap { $0 }.min()
    }

    mutating func relay(_ object: TrackObject, at now: Instant) -> [DirectDelivery] {
        let key = Key(object)
        if delivered.contains(key) { return [] }
        if onDirect {
            held[key] = (object, now)
            while held.count > settings.held, let oldest = held.keys.min() {
                held.removeValue(forKey: oldest)
            }
            return []
        }
        // On probation the relay winning a race is not a failure, but the
        // direct path must still deliver the same object within the stall bound.
        if hasDirect { awaiting[key] = now }
        return deliver(object, .relay)
    }

    mutating func direct(_ object: TrackObject, at now: Instant) -> [DirectDelivery] {
        guard hasDirect else { return [] }
        let key = Key(object)
        held.removeValue(forKey: key)
        awaiting.removeValue(forKey: key)
        if !onDirect {
            let since = keepingUpSince ?? now
            keepingUpSince = since
            if now - since >= settings.settle {
                onDirect = true
                awaiting.removeAll()
                switches += 1
            }
        }
        if delivered.contains(key) { return [] }
        // Anything older the relay is holding was skipped by the direct path,
        // and is a gap rather than a reordering: delivered now, in order.
        var out: [DirectDelivery] = []
        for skipped in held.keys.filter({ $0 < key }).sorted() {
            if let (object, _) = held.removeValue(forKey: skipped) {
                out += deliver(object, .relay)
            }
        }
        out += deliver(object, .direct)
        return out
    }

    /// Time has passed: abandon a stalled direct path, or restart a lagging
    /// probation.
    mutating func expire(at now: Instant) -> [DirectDelivery] {
        if let oldest = held.values.map(\.1).min(), now >= oldest + settings.stall {
            return fallBack()
        }
        if let oldest = awaiting.values.min(), now >= oldest + settings.stall {
            // Probation restarts rather than ending: a direct path that dropped
            // an object while settling may still be better, but has not shown it.
            awaiting.removeAll()
            keepingUpSince = nil
        }
        return []
    }

    mutating func fallBack() -> [DirectDelivery] {
        hasDirect = false
        keepingUpSince = nil
        awaiting.removeAll()
        if onDirect {
            onDirect = false
            switches += 1
        }
        let recovered = held.sorted { $0.key < $1.key }.map(\.value.0)
        held.removeAll()
        return recovered.flatMap { deliver($0, .relay) }
    }

    private mutating func deliver(_ object: TrackObject, _ path: DirectPath) -> [DirectDelivery] {
        let key = Key(object)
        guard delivered.insert(key).inserted else { return [] }
        deliveredOrder.append(key)
        if deliveredOrder.count > Self.remembered {
            let excess = deliveredOrder.count - Self.remembered
            for old in deliveredOrder.prefix(excess) { delivered.remove(old) }
            deliveredOrder.removeFirst(excess)
        }
        return [DirectDelivery(object: object, path: path)]
    }
}

/// A track read over the relay, with a direct path when there is one.
///
/// ```swift
/// let dual = DualSubscription(relay: try await session.subscribe(request))
/// // ...once a direct session to the publisher is up:
/// await dual.attachDirect(try await direct.subscribe(request))
/// for await delivery in dual.deliveries { decode(delivery.object) }
/// ```
///
/// Ends when the relay subscription ends: the relay is the subscription of
/// record, and a direct path alone does not keep this one alive.
public actor DualSubscription {
    private var selector: DirectPathSelector
    private let relay: any SubscriptionHandle
    private var direct: (any SubscriptionHandle)?
    private var directReader: Task<Void, Never>?
    private var relayReader: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var generation = 0
    private var relayPaused = false
    private var quietWatch: Task<Void, Never>?

    private let stream: AsyncStream<DirectDelivery>
    private let continuation: AsyncStream<DirectDelivery>.Continuation

    public init(relay: any SubscriptionHandle, settings: DirectPathSettings = DirectPathSettings()) {
        self.relay = relay
        selector = DirectPathSelector(settings: settings)
        (stream, continuation) = AsyncStream.makeStream(of: DirectDelivery.self)
        Task { [weak self] in await self?.readRelay() }
    }

    private func readRelay() {
        guard relayReader == nil else { return }
        let objects = relay.objects
        relayReader = Task { [weak self] in
            for await object in objects {
                await self?.received(object, over: .relay)
            }
            await self?.relayEnded()
        }
    }

    /// Every object, once, from whichever path delivered it first.
    public nonisolated var deliveries: AsyncStream<DirectDelivery> { stream }

    /// Which path objects are currently being delivered from.
    public var path: DirectPath { selector.path }

    /// How many times the active path has changed, in either direction.
    public var switches: Int { selector.switches }

    /// Whether a direct subscription is attached, on probation or in use.
    public var hasDirect: Bool { selector.hasDirect }

    /// Whether the relay has been asked to stop forwarding.
    public var isRelayPaused: Bool { relayPaused }

    /// Attach a direct subscription to the same track, starting its probation.
    public func attachDirect(_ subscription: any SubscriptionHandle) async {
        await detachDirect()
        generation += 1
        let attached = generation
        direct = subscription
        selector.attachDirect()
        let objects = subscription.objects
        directReader = Task { [weak self] in
            for await object in objects {
                await self?.received(object, over: .direct, generation: attached)
            }
            await self?.directEnded(generation: attached)
        }
    }

    /// The network changed: drop the direct path and go back to the relay.
    ///
    /// A new interface means new addresses on at least one side. Exchange fresh
    /// offers and attach a new direct subscription if one opens.
    public func networkChanged() async {
        emit(selector.fallBack())
        await detachDirect()
    }

    /// Stop reading both paths.
    public func cancel() async {
        relayReader?.cancel()
        timer?.cancel()
        // Not resumed on the way out: the relay subscription is about to end.
        relayPaused = false
        await detachDirect()
        await relay.cancel()
        continuation.finish()
    }

    private func received(_ object: TrackObject, over path: DirectPath, generation attached: Int = 0) async {
        let now = ContinuousClock.now
        switch path {
        case .relay:
            emit(selector.relay(object, at: now))
        case .direct:
            guard attached == generation else { return }
            emit(selector.direct(object, at: now))
            if selector.onDirect, selector.settings.pausesRelay {
                await pauseRelay()
            }
        }
        arm()
    }

    private func pauseRelay() async {
        watchQuiet()
        guard !relayPaused else { return }
        relayPaused = true
        await relay.updateForwarding(false)
    }

    private func resumeRelay() async {
        quietWatch?.cancel()
        quietWatch = nil
        guard relayPaused else { return }
        relayPaused = false
        await relay.updateForwarding(true)
    }

    /// Restarted by every direct object while the relay is paused.
    private func watchQuiet() {
        quietWatch?.cancel()
        let quiet = selector.settings.quiet
        quietWatch = Task { [weak self] in
            try? await Task.sleep(for: quiet)
            guard !Task.isCancelled else { return }
            await self?.resumeRelay()
        }
    }

    private func directEnded(generation ended: Int) async {
        guard ended == generation, direct != nil else { return }
        emit(selector.fallBack())
        await detachDirect()
    }

    private func relayEnded() {
        timer?.cancel()
        continuation.finish()
    }

    /// Every way off the direct path comes through here, so this is where the
    /// relay is resumed.
    private func detachDirect() async {
        await resumeRelay()
        directReader?.cancel()
        directReader = nil
        let old = direct
        direct = nil
        await old?.cancel()
    }

    private func emit(_ deliveries: [DirectDelivery]) {
        for delivery in deliveries { continuation.yield(delivery) }
    }

    /// Wake when the selector next has something due.
    private func arm() {
        timer?.cancel()
        guard let deadline = selector.deadline else { return }
        timer = Task { [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard !Task.isCancelled else { return }
            await self?.expire()
        }
    }

    private func expire() async {
        let wasDirect = selector.hasDirect
        emit(selector.expire(at: .now))
        if wasDirect, !selector.hasDirect { await detachDirect() }
        arm()
    }
}
