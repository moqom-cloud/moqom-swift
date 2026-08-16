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
// - A device that hears nothing on any peer's space track for ``Configuration/quiet``
//   claims it, by publishing a snapshot at an epoch above the highest it has
//   seen, on its own participant namespace.
// - A device that sees a higher epoch than its own stops publishing.
// - Two devices that claim the same epoch — the case that a quiet interval and
//   two phones makes likely rather than rare — are separated by their
//   identities, and the one that loses stands down.
//
// The space lives under the participant, not the room. The room namespace is
// the control log, and a guest is not allowed to announce it; putting the
// field there made both phones simulate a game whose ticks never left the
// device. Each authority publishes `.space` beside its video, and everyone
// else subscribes to it the same way they subscribe to a camera.
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
        /// Longer than one snapshot interval, because a joiner who arrives in
        /// the middle of a group cannot decode until the next snapshot, and
        /// treating that as an abandoned space is how two phones end up
        /// simulating two different games. Four seconds matches the handover
        /// the rest of this file talks about: a host in a tunnel is replaced
        /// without looking like a glitch, and a host who quit does not leave
        /// the field frozen.
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
            quiet: Duration = .seconds(4),
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
        /// The state moved, with what moved it, at the instant the simulation
        /// produced it.
        ///
        /// The timestamp is the one on the tick, not the one on the packet: a
        /// renderer that samples against a shared clock can draw the same pose
        /// as every other participant rather than the pose as of arrival.
        case changed(SpaceSnapshot, SpaceDelta, at: Timecode)

        /// This device started or stopped simulating.
        case roleChanged(Role)

        /// The space is being simulated by somebody else now.
        case authorityChanged(ParticipantIdentity?)
    }

    public nonisolated let identity: ParticipantIdentity
    public nonisolated let tenant: TenantID
    public nonisolated let room: RoomID

    /// The track this device publishes when it is simulating.
    ///
    /// Under this participant's own namespace, not the room's. The room
    /// namespace is the control log, and the relay will not let a guest
    /// announce it — which is what made two phones simulate two games: both
    /// thought they had published, and neither's ticks left the device.
    public nonisolated let track: FullTrackName

    /// The room's prefix, for finding everyone else on stage.
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

    private var ticker: Task<Void, Never>?
    private var claimer: Task<Void, Never>?
    private var roster: Task<Void, Never>?

    private var writer: (any TrackWriter)?
    private var group: UInt64 = 0
    private var object: UInt64 = 0
    private var ticksThisGroup = 0

    /// Intents received but not yet folded in, and how far each sender got.
    private var pending: [(SpaceIntent, ParticipantIdentity)] = []
    private var applied: [ParticipantIdentity: UInt64] = [:]
    private var intents: [ParticipantIdentity: Task<Void, Never>] = [:]
    private var spaces: [ParticipantIdentity: Task<Void, Never>] = [:]
    private var rostered: [ParticipantIdentity: ParticipantSlot] = [:]

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
            let ownNamespace = try MoqomNamespaces.participant(
                tenant: tenant, room: room, identity: identity
            )
            track = try FullTrackName(
                namespace: ownNamespace,
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
        watchRoster()

        // The intent track is opened now rather than on the first tap, and the
        // reason is a race that only shows up on the tap that matters most. An
        // authority subscribes to a participant's intents when it sees them
        // announce; a participant that announced and published in the same
        // breath as its first intent has sent it before anybody was listening.
        // Announcing early costs one idle track and makes the first thing a
        // player does as reliable as the second.
        //
        // The same announcement is what makes this device's space track
        // reachable: it lives under the participant namespace, which a guest
        // is allowed to publish, rather than under the room, which is not.
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
        roster?.cancel()
        roster = nil
        for task in spaces.values { task.cancel() }
        spaces.removeAll()
        rostered.removeAll()
        await outgoing?.finish()
        outgoing = nil
        await ownAnnouncement?.withdraw()
        ownAnnouncement = nil
        eventContinuation.finish()
    }

    // MARK: - Watching

    /// Follow every other participant's space track, and their intents once
    /// this device is the one that can act on them.
    ///
    /// One prefix watch, not two. The relay refuses overlapping
    /// `SUBSCRIBE_NAMESPACE` on a session, and the intents already needed this
    /// roster — folding the space into it is what lets a follower find the
    /// authority without announcing a namespace it is not allowed to.
    private func watchRoster() {
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

    /// Internal rather than private so a test can hand this an update from a
    /// peer that no relay would produce — a replaced authority still
    /// publishing, above all, which needs two relays and a partition to stage
    /// honestly and one line to state directly.
    func receive(_ object: TrackObject) {
        ingest(object, decoder: &decoder)
    }

    private func markHeard() {
        lastHeard = .nanoseconds(DispatchTime.now().uptimeNanoseconds)
    }

    private func ingest(_ object: TrackObject, decoder: inout SpaceDecoder) {
        markHeard()
        let update: SpaceUpdate
        do {
            update = try decoder.decode(object.payload)
        } catch {
            logger.warning(.control, "space update rejected", [
                LogField("reason", .text("\(error)")),
            ])
            return
        }
        apply(update)
    }

    private func apply(_ update: SpaceUpdate) {
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
        eventContinuation.yield(.changed(state, delta, at: update.at))
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

        // The participant namespace is already announced — `intentWriter` did
        // that at start, and a broadcast usually did it too. Publishing the
        // space as another track under it is what a guest is allowed to do.
        let opened = try await connection.publish(track, priority: SpaceUpdate.priority)

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

        for slot in rostered.values { listenForIntents(of: slot) }
        startTicking()
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
            // Counted in ticks rather than in published objects, which is what
            // ``Configuration/groupLength`` says and what a joiner is relying
            // on. Counting objects made the recovery interval a function of how
            // busy the simulation happened to be: a space whose state only
            // changes when something happens — which is the point of putting
            // derivable motion in the clients rather than on the wire — reached
            // forty published deltas in a minute rather than in two seconds,
            // and a phone joining it waited that long to see anything at all.
            ticksThisGroup += 1
            if ticksThisGroup > configuration.groupLength {
                try await writeSnapshot(at: now)
            } else if !delta.isEmpty {
                tick = tick.next
                try await write(
                    SpaceUpdate(tick: tick, at: now, body: .delta(delta)),
                    on: writer
                )
            }
        } catch {
            logger.warning(.control, "space tick not published", [
                LogField("reason", .text("\(error)")),
            ])
        }

        if !delta.isEmpty {
            eventContinuation.yield(.changed(state, delta, at: now))
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

    private func applyAnnouncement(_ event: AnnouncementEvent, under prefix: TrackNamespace) {
        guard let slot = ParticipantSlot(announced: event.namespace, under: prefix) else { return }
        guard slot.identity != identity else { return }
        switch event {
        case .announced:
            guard rostered.updateValue(slot, forKey: slot.identity) == nil else { return }
            listenToSpace(of: slot)
            listenForIntents(of: slot)
        case .withdrawn:
            rostered.removeValue(forKey: slot.identity)
            intents.removeValue(forKey: slot.identity)?.cancel()
            spaces.removeValue(forKey: slot.identity)?.cancel()
        }
    }

    private func listenForIntents(of slot: ParticipantSlot) {
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

    /// Read one peer's space track for as long as they are on stage.
    ///
    /// Each peer is a separate intern table, so the decoder lives in this task
    /// rather than on the session. Mixing them would make a snapshot from one
    /// authority rename the other authority's bubbles.
    private func listenToSpace(of slot: ParticipantSlot) {
        guard spaces[slot.identity] == nil else { return }
        let who = slot.identity
        spaces[who] = Task { [weak self] in
            guard let self else { return }
            let name: FullTrackName
            do {
                name = try FullTrackName(
                    namespace: slot.namespace,
                    name: TrackName(SpaceUpdate.trackName)
                )
            } catch {
                return
            }
            var decoder = SpaceDecoder()
            while !Task.isCancelled {
                decoder.reset()
                guard
                    let subscription = try? await self.connection.subscribe(
                        SubscribeRequest(
                            track: name,
                            priority: SpaceUpdate.priority,
                            start: .latestGroup
                        )
                    )
                else {
                    try? await Task.sleep(for: .milliseconds(400))
                    continue
                }
                for await object in subscription.objects {
                    await self.markHeard()
                    do {
                        let update = try decoder.decode(object.payload)
                        await self.apply(update)
                    } catch {
                        await self.rejected(error)
                    }
                }
                await subscription.cancel()
            }
        }
    }

    private func rejected(_ error: any Error) {
        logger.warning(.control, "space update rejected", [
            LogField("reason", .text("\(error)")),
        ])
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
