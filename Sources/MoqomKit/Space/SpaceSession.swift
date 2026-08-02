// Running a shared space, as opposed to describing one.
//
// ``SpaceState`` says what a space contains and ``SpaceState+Wire`` says what it
// looks like on the wire. Neither of them talks to a relay. This is the part
// that does: it subscribes to the space track, decides whether this device is
// the one simulating, publishes if it is, and carries everybody else's intents
// back to whoever is.
//
// # One writer, chosen without an election
//
// There is no coordinator to run a vote, and adding one would mean a round trip
// before the first bubble appears. Instead the rule is entirely local and
// arrives at the same answer everywhere:
//
// - A device that hears nothing on the space track for ``Configuration/quiet``
//   claims it, by publishing a snapshot at an epoch above the highest it has
//   seen.
// - A device that sees a higher epoch than its own stops publishing.
// - Two devices that claim the same epoch — the case that a quiet interval and
//   two phones makes likely rather than rare — are separated by their
//   identities, and the one that loses stands down.
//
// That last rule is why the tie-break is by name and not by "who claimed
// first": both claimants believe they were first, and the only fact they agree
// on is who they are.
//
// The relay makes this work in a way worth knowing about. Several sessions may
// announce the room's namespace at once and the newest announcement is the one
// subscribers are routed to, so a handover does not need the outgoing authority
// to cooperate — or to still exist. Subscribers pinned to the old publisher
// find out when its track ends, which is what ``watch()`` re-subscribes on.
//
// # Why the simulation is a protocol and not a closure
//
// A ``SpaceSimulation`` gets called in three places — when leadership is taken,
// on every tick, and for every intent — and the three have to see the same
// state. A closure per call site invites an application to keep the world in
// its own object and hand this a view of it, and then a handover copies the
// view and loses the world.

import Foundation
import MoqomCore

/// The rules of whatever is happening in a shared space.
///
/// Called only on the device currently simulating. Everybody else renders what
/// arrives, so nothing here needs to be deterministic across devices — which is
/// the freedom that separates this from a lockstep design.
public protocol SpaceSimulation: Sendable {
    /// Set up the world, on becoming the authority.
    ///
    /// The state passed in is whatever this device had already received, which
    /// on a takeover is the outgoing authority's last word and on a cold start
    /// is empty. Continuing from it is usually right; a game that cannot
    /// resume somebody else's board should replace it here.
    func opening(_ state: inout SpaceSnapshot, at now: Timecode)

    /// Advance the world by one tick.
    func step(_ state: inout SpaceSnapshot, at now: Timecode, since elapsed: Duration)

    /// Do something a participant asked for, or decline to.
    ///
    /// Declining is a real answer and needs no return value: the state simply
    /// does not change, and the asker sees their optimistic guess corrected by
    /// the next update.
    func apply(
        _ intent: SpaceIntent,
        from who: ParticipantIdentity,
        to state: inout SpaceSnapshot,
        at now: Timecode
    )
}

public extension SpaceSimulation {
    func opening(_: inout SpaceSnapshot, at _: Timecode) {}

    func apply(
        _: SpaceIntent,
        from _: ParticipantIdentity,
        to _: inout SpaceSnapshot,
        at _: Timecode
    ) {}
}

/// Reads the clock the space's timestamps are on.
///
/// A closure rather than a protocol so that ``TrustedClock`` — an actor — and a
/// test's fixed instant satisfy it without either having to know about this.
public typealias SpaceTimeReading = @Sendable () async -> Timecode

/// A shared space, live.
public actor SpaceSession {
    /// How the space is published and when this device will take it over.
    public struct Configuration: Sendable {
        /// Simulation ticks a second, on the authority.
        ///
        /// Twenty rather than sixty. The tick rate is the update rate, and a
        /// space is a supporting track on a link already carrying a call: the
        /// difference between twenty and sixty is three times the bytes for
        /// motion that interpolation renders indistinguishably.
        public var tickRate: Double

        /// Ticks per group. Every group opens with a complete snapshot.
        ///
        /// The recovery interval, in other words. At the default rate this is a
        /// snapshot every two seconds, which is how long a joiner waits and how
        /// long a client that missed something stays wrong.
        public var groupLength: Int

        /// Silence on the space track before this device claims it.
        ///
        /// Long enough that a stalled uplink does not cause a takeover, short
        /// enough that a host who quit does not leave the game frozen. The
        /// epoch fence makes a wrong guess recoverable rather than fatal, which
        /// is what allows it to be this short.
        public var quiet: Duration

        /// How old an intent may be and still be acted on.
        ///
        /// Applies only when the clocks on both sides are synchronised well
        /// enough to tell — see ``SpaceSession/isFresh(_:)``. Two seconds is
        /// long against any network this is usable on and short against the
        /// thing it guards, which is a minutes-old tap arriving at an authority
        /// that has only just started listening.
        public var intentLifetime: Duration

        /// Whether this device is willing to simulate at all.
        ///
        /// False for a viewer: watching a space needs no publish rights, and
        /// the relay will refuse the announcement anyway — attempting it once a
        /// second would be a refusal once a second in somebody's logs.
        public var mayLead: Bool

        public init(
            tickRate: Double = 20,
            groupLength: Int = 40,
            quiet: Duration = .milliseconds(1500),
            intentLifetime: Duration = .seconds(2),
            mayLead: Bool = true
        ) {
            self.tickRate = max(1, tickRate)
            self.groupLength = max(1, groupLength)
            self.quiet = quiet
            self.intentLifetime = intentLifetime
            self.mayLead = mayLead
        }
    }

    /// Whether this device is simulating or watching.
    public enum Role: Hashable, Sendable {
        case following
        case leading
    }

    /// What a space tells the application about.
    public enum Event: Sendable {
        /// The state moved, with what moved it.
        ///
        /// Both, because a renderer wants the delta — spawn a node, remove a
        /// node, set thirty transforms — and anything joining the stream late
        /// wants the state. Computing either from the other at the call site is
        /// work this already did.
        case changed(SpaceSnapshot, SpaceDelta)

        /// This device started or stopped simulating.
        case roleChanged(Role)

        /// The space is being simulated by somebody else now.
        case authorityChanged(ParticipantIdentity?)
    }

    public nonisolated let identity: ParticipantIdentity
    public nonisolated let tenant: TenantID
    public nonisolated let room: RoomID

    /// The track the space is replicated on.
    public nonisolated let track: FullTrackName

    /// The room's namespace, which the authority announces.
    private nonisolated let roomNamespace: TrackNamespace

    private let connection: any TransportSession
    private let simulation: any SpaceSimulation
    private let clock: SpaceTimeReading
    private let logger: MoqomLogger
    private var configuration: Configuration

    public private(set) var state = SpaceSnapshot()
    public private(set) var role: Role = .following

    /// Where this device believes the simulation has got to.
    ///
    /// While leading, what it is publishing. While following, the highest it
    /// has seen — which is the fence: anything at or below it is stale.
    public private(set) var tick = SpaceTick.zero

    private var encoder = SpaceEncoder()
    private var decoder = SpaceDecoder()

    private var watcher: Task<Void, Never>?
    private var subscription: (any SubscriptionHandle)?
    private var ticker: Task<Void, Never>?
    private var claimer: Task<Void, Never>?
    private var roster: Task<Void, Never>?

    private var writer: (any TrackWriter)?
    private var announcement: (any AnnouncementHandle)?
    private var group: UInt64 = 0
    private var object: UInt64 = 0
    private var ticksThisGroup = 0

    /// Intents received but not yet folded in, and how far each sender got.
    private var pending: [(SpaceIntent, ParticipantIdentity)] = []
    private var applied: [ParticipantIdentity: UInt64] = [:]
    private var intents: [ParticipantIdentity: Task<Void, Never>] = [:]
    private var peers: Set<ParticipantIdentity> = []

    /// This device's own outgoing intents.
    private var outgoing: (any TrackWriter)?
    private var ownAnnouncement: (any AnnouncementHandle)?
    private var sent: UInt64 = 0

    private var lastHeard = MonotonicTime.nanoseconds(DispatchTime.now().uptimeNanoseconds)
    private var lastTick: MonotonicTime?
    private var isRunning = false

    private let eventStream: AsyncStream<Event>
    private let eventContinuation: AsyncStream<Event>.Continuation

    public init(
        tenant: TenantID,
        room: RoomID,
        identity: ParticipantIdentity,
        connection: any TransportSession,
        simulation: any SpaceSimulation,
        configuration: Configuration = Configuration(),
        clock: @escaping SpaceTimeReading = { .fallback() },
        logger: MoqomLogger = .silent
    ) throws(MoqomError) {
        do {
            roomNamespace = try MoqomNamespaces.room(tenant: tenant, room: room)
            track = try FullTrackName(
                namespace: roomNamespace,
                name: TrackName(SpaceUpdate.trackName)
            )
        } catch {
            throw MoqomError.invalidName(error)
        }
        self.tenant = tenant
        self.room = room
        self.identity = identity
        self.connection = connection
        self.simulation = simulation
        self.configuration = configuration
        self.clock = clock
        self.logger = logger
        (eventStream, eventContinuation) = AsyncStream.makeStream(
            of: Event.self,
            bufferingPolicy: .unbounded
        )
    }

    /// Everything happening in the space. One consumer, as with `RoomSession`.
    public nonisolated var events: AsyncStream<Event> { eventStream }

    /// Who is simulating, as far as this device knows.
    public var authority: ParticipantIdentity? { state.authority }

    /// Start watching, and start trying to lead if nobody is.
    public func start() async {
        guard !isRunning else { return }
        isRunning = true
        watch()

        // The intent track is opened now rather than on the first tap, and the
        // reason is a race that only shows up on the tap that matters most. An
        // authority subscribes to a participant's intents when it sees them
        // announce; a participant that announced and published in the same
        // breath as its first intent has sent it before anybody was listening.
        // Announcing early costs one idle track and makes the first thing a
        // player does as reliable as the second.
        //
        // Refused for a viewer with no publish rights, which is not an error
        // worth reporting: `act` retries, and by then the answer will be the
        // same.
        _ = try? await intentWriter()

        if configuration.mayLead { waitForSilence() }
    }

    /// Stop publishing and stop watching.
    public func stop() async {
        isRunning = false
        claimer?.cancel()
        claimer = nil
        await follow()
        watcher?.cancel()
        watcher = nil
        await subscription?.cancel()
        subscription = nil
        await outgoing?.finish()
        outgoing = nil
        await ownAnnouncement?.withdraw()
        ownAnnouncement = nil
        eventContinuation.finish()
    }

    // MARK: - Watching

    /// Subscribe, read until the track ends, and subscribe again.
    ///
    /// The loop is the point. A space track ends when its publisher does, which
    /// on a handover is the normal course of events rather than a failure —
    /// and the next subscription is what routes this device to whoever took
    /// over.
    private func watch() {
        watcher?.cancel()
        watcher = Task { [weak self] in
            while let self, await self.isRunning, !Task.isCancelled {
                guard await self.readThrough() else {
                    // Nothing to subscribe to yet, which is the ordinary state
                    // of a space nobody has started. Retried rather than
                    // treated as an error, and slowly, because the claim timer
                    // is what resolves it.
                    try? await Task.sleep(for: .milliseconds(400))
                    continue
                }
            }
        }
    }

    /// One subscription, from start to end.
    ///
    /// - Returns: Whether it was established. `false` asks the caller to wait
    ///   before trying again.
    private func readThrough() async -> Bool {
        let handle: any SubscriptionHandle
        do {
            handle = try await connection.subscribe(
                SubscribeRequest(
                    track: track,
                    priority: SpaceUpdate.priority,
                    // The current group rather than the next, because a group
                    // opens with a snapshot and the next one is up to two
                    // seconds away. This is the difference between a joiner
                    // seeing the space immediately and seeing it eventually.
                    start: .latestGroup
                )
            )
        } catch {
            return false
        }

        adopt(handle)
        for await object in handle.objects {
            receive(object)
        }
        await handle.cancel()
        forget(handle)
        return true
    }

    private func adopt(_ handle: any SubscriptionHandle) {
        subscription = handle
        // The interning table belongs to the subscription, not to the space: a
        // new one starts with a snapshot that renumbers everything.
        decoder.reset()
    }

    private func forget(_ handle: any SubscriptionHandle) {
        if subscription === handle { subscription = nil }
    }

    /// Internal rather than private so a test can hand this an update from a
    /// peer that no relay would produce — a replaced authority still
    /// publishing, above all, which needs two relays and a partition to stage
    /// honestly and one line to state directly.
    func receive(_ object: TrackObject) {
        let update: SpaceUpdate
        do {
            update = try decoder.decode(object.payload)
        } catch {
            // A delta naming a handle no snapshot introduced, most likely, which
            // means this subscription missed the start of a group. The next
            // group opens with a snapshot and repairs it.
            logger.warning(.control, "space update rejected", [
                LogField("reason", .text("\(error)")),
            ])
            return
        }

        lastHeard = .nanoseconds(DispatchTime.now().uptimeNanoseconds)

        guard shouldApply(update) else { return }
        tick = update.tick

        var next = state
        switch update.body {
        case let .snapshot(snapshot):
            next = snapshot
        case let .delta(delta):
            next.apply(delta)
        }
        let delta = state.delta(to: next)
        let wasAuthority = state.authority
        state = next
        if state.authority != wasAuthority {
            eventContinuation.yield(.authorityChanged(state.authority))
        }
        eventContinuation.yield(.changed(state, delta))
    }

    /// Whether an arriving update is news, and whether this device should stand
    /// down because of it.
    ///
    /// The three answers here are the whole of the split-brain handling.
    private func shouldApply(_ update: SpaceUpdate) -> Bool {
        let author = authorOf(update)

        // This device's own writes, arriving back. Reading them is how a
        // replaced authority finds out; applying them would be folding the
        // state into itself a round trip late.
        if role == .leading, update.tick.epoch == tick.epoch, author == identity {
            return false
        }

        if update.tick.epoch > tick.epoch {
            if role == .leading {
                logger.info(.control, "space authority passed on", [
                    LogField("epoch", .number(Int(update.tick.epoch))),
                ])
                Task { await self.follow() }
            }
            return true
        }

        if update.tick.epoch == tick.epoch, role == .leading, let author, author != identity {
            // Both of us claimed the same epoch. Names decide it, because that
            // is the only thing the two of us agree on.
            if precedes(author, identity) {
                logger.info(.control, "space authority conceded", [
                    LogField("to", .participant(author)),
                ])
                Task { await self.follow() }
                return true
            }
            return false
        }

        // Same epoch, and behind: a tick that arrived after the one following
        // it. Worthless to a simulation, unlike a control log.
        return update.tick > tick || update.isSnapshot && update.tick == tick
    }

    private func authorOf(_ update: SpaceUpdate) -> ParticipantIdentity? {
        if case let .snapshot(snapshot) = update.body { return snapshot.authority }
        return state.authority
    }

    /// A stable order over identities, for settling a tie nobody can see both
    /// sides of.
    private func precedes(_ left: ParticipantIdentity, _ right: ParticipantIdentity) -> Bool {
        (left.username.value, left.device.value) < (right.username.value, right.device.value)
    }

    // MARK: - Leading

    /// Take over the simulation.
    ///
    /// Safe to call when somebody else is already leading: the epoch goes above
    /// theirs and they stand down on reading it. That is deliberate — it is
    /// what "hand me the game" costs, and what a stuck authority is recovered
    /// with.
    public func lead() async throws(MoqomError) {
        guard role == .following else { return }

        let announced = try await connection.announce(roomNamespace)
        let opened: any TrackWriter
        do {
            opened = try await connection.publish(track, priority: SpaceUpdate.priority)
        } catch {
            await announced.withdraw()
            throw error
        }

        announcement = announced
        writer = opened
        role = .leading
        tick = tick.succeeding
        encoder.reset()
        group = 0
        object = 0
        ticksThisGroup = 0
        lastTick = nil

        let now = await clock()
        var opening = state
        opening.authority = identity
        simulation.opening(&opening, at: now)
        state = opening

        eventContinuation.yield(.roleChanged(.leading))
        eventContinuation.yield(.authorityChanged(identity))

        // Before the first tick, so a subscriber that arrives in the gap gets a
        // world rather than an empty group.
        try await writeSnapshot(at: now)

        listenForIntents()
        startTicking()

        // Re-subscribed so that this device is routed to its own announcement,
        // which is what makes reading its own writes back — and therefore
        // noticing a successor — possible at all.
        watch()
    }

    /// Stop simulating, without deciding who should instead.
    public func follow() async {
        ticker?.cancel()
        ticker = nil
        for task in intents.values { task.cancel() }
        intents.removeAll()
        pending.removeAll()
        await writer?.finish()
        writer = nil
        await announcement?.withdraw()
        announcement = nil
        guard role == .leading else { return }
        role = .following
        eventContinuation.yield(.roleChanged(.following))
    }

    private func startTicking() {
        ticker?.cancel()
        let interval = Duration.seconds(1 / configuration.tickRate)
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
                guard let self else { return }
                await self.advance()
            }
        }
    }

    /// One tick: everybody's intents, then the world, then the wire.
    private func advance() async {
        guard role == .leading, let writer else { return }
        let now = await clock()
        let instant = MonotonicTime.nanoseconds(DispatchTime.now().uptimeNanoseconds)
        let elapsed = lastTick.map { instant - $0 } ?? .seconds(1 / configuration.tickRate)
        lastTick = instant

        var next = state
        let asked = pending
        pending.removeAll(keepingCapacity: true)
        for (intent, who) in asked {
            simulation.apply(intent, from: who, to: &next, at: now)
        }
        simulation.step(&next, at: now, since: elapsed)
        next.authority = identity

        let delta = state.delta(to: next)
        state = next

        do {
            if ticksThisGroup >= configuration.groupLength {
                try await writeSnapshot(at: now)
            } else if !delta.isEmpty {
                tick = tick.next
                try await write(
                    SpaceUpdate(tick: tick, at: now, body: .delta(delta)),
                    on: writer
                )
                ticksThisGroup += 1
            }
        } catch {
            logger.warning(.control, "space tick not published", [
                LogField("reason", .text("\(error)")),
            ])
        }

        if !delta.isEmpty {
            eventContinuation.yield(.changed(state, delta))
        }
    }

    private func writeSnapshot(at now: Timecode) async throws(MoqomError) {
        guard let writer else { return }
        group += 1
        object = 0
        ticksThisGroup = 0
        tick = tick.next
        try await writer.startGroup(group)
        try await write(
            SpaceUpdate(tick: tick, at: now, body: .snapshot(state)),
            on: writer,
            isKeyFrame: true
        )
    }

    private func write(
        _ update: SpaceUpdate,
        on writer: any TrackWriter,
        isKeyFrame: Bool = false
    ) async throws(MoqomError) {
        let payload: Data
        do {
            payload = try encoder.encode(update)
        } catch let error as MoqomError {
            throw error
        } catch {
            throw MoqomError.invalidState(
                expected: "an encodable space update",
                actual: "\(error)"
            )
        }
        try await writer.write(
            TrackObject(
                group: group,
                object: object,
                priority: SpaceUpdate.priority,
                payload: payload,
                isKeyFrame: isKeyFrame
            )
        )
        object += 1
    }

    /// Claim the space if nothing has been heard on it.
    private func waitForSilence() {
        claimer?.cancel()
        claimer = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let wait = await self.configuration.quiet
                try? await Task.sleep(for: wait / 3)
                if Task.isCancelled { return }
                await self.claimIfQuiet()
            }
        }
    }

    private func claimIfQuiet() async {
        guard isRunning, role == .following, configuration.mayLead else { return }
        let idle = MonotonicTime.nanoseconds(DispatchTime.now().uptimeNanoseconds) - lastHeard
        guard idle >= configuration.quiet else { return }
        do {
            try await lead()
        } catch {
            // A viewer without publish rights, most often. Backing off is the
            // whole handling: the relay said no and will keep saying no.
            logger.info(.control, "space not claimed", [
                LogField("reason", .text("\(error)")),
            ])
            lastHeard = .nanoseconds(DispatchTime.now().uptimeNanoseconds)
        }
    }

    // MARK: - Intents

    /// Ask the space for something.
    ///
    /// Applied directly when this device is the authority, and published to its
    /// own intent track otherwise. The caller does not need to know which, and
    /// deliberately: a game that branched on it would have two code paths where
    /// the interesting one is exercised only on the other phone.
    public func act(
        verb: String,
        subject: SpaceEntityID? = nil,
        at point: SpaceVector? = nil,
        facts: [String: SpaceValue] = [:]
    ) async {
        sent += 1
        let intent = SpaceIntent(
            verb: verb,
            subject: subject,
            at: point,
            facts: facts,
            sequence: sent,
            when: await clock()
        )

        guard role == .following else {
            pending.append((intent, identity))
            return
        }

        do {
            let writer = try await intentWriter()
            // A group per intent: each one stands alone, and a subscriber that
            // joins mid-game must not be handed a pop from five minutes ago.
            try await writer.startGroup(sent)
            try await writer.write(
                TrackObject(
                    group: sent,
                    object: 0,
                    priority: SpaceIntent.priority,
                    payload: intent.encoded(),
                    isKeyFrame: true
                )
            )
        } catch {
            logger.warning(.control, "space intent not sent", [
                LogField("verb", .text(verb)),
                LogField("reason", .text("\(error)")),
            ])
        }
    }

    private func intentWriter() async throws(MoqomError) -> any TrackWriter {
        if let outgoing { return outgoing }
        let namespace: TrackNamespace
        let name: FullTrackName
        do {
            namespace = try MoqomNamespaces.participant(
                tenant: tenant, room: room, identity: identity
            )
            name = try FullTrackName(namespace: namespace, name: TrackName(SpaceIntent.trackName))
        } catch {
            throw MoqomError.invalidName(error)
        }
        // Announced even if a broadcast already did: announcements are per
        // namespace and refcounted, and an intent track on a participant who
        // never turned a camera on still has to be reachable.
        ownAnnouncement = try await connection.announce(namespace)
        let writer = try await connection.publish(name, priority: SpaceIntent.priority)
        outgoing = writer
        return writer
    }

    /// Follow every participant's intent track, for as long as this device is
    /// the one that can act on them.
    private func listenForIntents() {
        roster?.cancel()
        roster = Task { [weak self] in
            guard let self else { return }
            let prefix = self.roomNamespace
            guard let stream = try? await self.connection.announcements(matching: prefix) else {
                return
            }
            for await event in stream {
                if Task.isCancelled { return }
                await self.applyAnnouncement(event, under: prefix)
            }
        }
    }

    private func applyAnnouncement(_ event: AnnouncementEvent, under prefix: TrackNamespace) {
        guard let slot = ParticipantSlot(announced: event.namespace, under: prefix) else { return }
        guard slot.identity != identity else { return }
        switch event {
        case .announced:
            guard peers.insert(slot.identity).inserted else { return }
            listen(to: slot)
        case .withdrawn:
            peers.remove(slot.identity)
            intents.removeValue(forKey: slot.identity)?.cancel()
        }
    }

    private func listen(to slot: ParticipantSlot) {
        guard role == .leading, intents[slot.identity] == nil else { return }
        let who = slot.identity
        intents[who] = Task { [weak self] in
            guard let self else { return }
            let name: FullTrackName
            do {
                name = try FullTrackName(
                    namespace: slot.namespace,
                    name: TrackName(SpaceIntent.trackName)
                )
            } catch {
                return
            }
            while !Task.isCancelled {
                guard
                    let subscription = try? await self.connection.subscribe(
                        SubscribeRequest(
                            track: name,
                            priority: SpaceIntent.priority,
                            // The current group rather than the next, because
                            // an intent is one group and a subscription that
                            // began a millisecond after it was written would
                            // otherwise miss it entirely — which on a fresh
                            // authority is everybody's first tap.
                            //
                            // What that risks is replaying something old to a
                            // late-arriving authority, and two things bound it:
                            // a sender's sequence never goes backwards, and
                            // `isFresh` refuses anything that has clearly been
                            // sitting there.
                            start: .latestGroup
                        )
                    )
                else {
                    try? await Task.sleep(for: .milliseconds(500))
                    continue
                }
                for await object in subscription.objects {
                    await self.receive(object, from: who)
                }
                await subscription.cancel()
            }
        }
    }

    private func receive(_ object: TrackObject, from who: ParticipantIdentity) async {
        guard role == .leading else { return }
        let intent: SpaceIntent
        do {
            intent = try SpaceIntent(decoding: object.payload)
        } catch {
            logger.warning(.control, "space intent rejected", [
                LogField("reason", .text("\(error)")),
            ])
            return
        }
        // A redelivery, or one that overtook a later one. Either way the
        // simulation has already seen this sender's mind on the matter.
        guard intent.sequence > applied[who] ?? 0 else { return }
        applied[who] = intent.sequence
        guard await isFresh(intent) else { return }
        pending.append((intent, who))
    }

    /// Whether an intent is recent enough to act on.
    ///
    /// The guard on a late authority being handed a subscription that opens
    /// with whatever the sender last said, which could be minutes old. Answered
    /// only when both clocks are disciplined enough to make the comparison
    /// mean something — an untrusted timecode is `± a day`, and refusing on
    /// that basis would drop live intents on any device whose time sync has not
    /// settled. Accepting is the safer wrong answer of the two: the worst case
    /// is one stale action, and the alternative's worst case is a player whose
    /// taps do nothing.
    private func isFresh(_ intent: SpaceIntent) async -> Bool {
        let now = await clock()
        guard now.isTrusted, intent.when.isTrusted else { return true }
        return now.earliest - intent.when.latest <= configuration.intentLifetime
            .wholeNanoseconds
    }
}
