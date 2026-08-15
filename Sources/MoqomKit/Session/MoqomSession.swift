// The entry point.
//
// One session per device per relay. Rooms hang off it, and so does the personal
// channel, because both are namespace prefixes on the same connection — there
// is no per-room connection and no renegotiation when a participant moves
// between them.

import Foundation
import MoqomCore

/// A connection to MOQOM.
public actor MoqomSession {
    /// Who this device is.
    public nonisolated let identity: ParticipantIdentity

    /// Which customer's namespace it operates in.
    public nonisolated let tenant: TenantID

    /// Where this session's diagnostics go.
    ///
    /// Silent by default. A library that writes to the console uninvited is a
    /// library an application has to work around, and the interesting failures
    /// here — a reconnect that keeps failing, a room whose log has a hole — are
    /// ones a field report needs, which means they need to reach the
    /// application's own logging rather than Xcode's console.
    public nonisolated let logger: MoqomLogger

    private let transport: any Transport
    private let credentials: DeviceCredentials
    private var machine: SessionStateMachine
    private var connection: (any TransportSession)?
    private var rooms: [RoomID: RoomSession] = [:]

    /// The endpoint to redial.
    ///
    /// Retained from ``connect(to:at:)`` because reconnection has to go
    /// somewhere and nothing else remembers where. A GOAWAY carrying a new URI
    /// replaces it, which is how a relay drains a client onto another instance.
    private var endpoint: RelayEndpoint?

    private var reconnect: Task<Void, Never>?
    private var interruptionWatch: Task<Void, Never>?

    private let clock: @Sendable () -> MonotonicTime
    private let sleeper: @Sendable (Duration) async -> Void

    private let stateStream: AsyncStream<SessionState>
    private let stateContinuation: AsyncStream<SessionState>.Continuation

    /// - Parameters:
    ///   - clock: reads monotonic time. Injected so that reconnection can be
    ///     driven from an interruption arriving at an arbitrary moment — which
    ///     needs a time nobody is around to pass in — without giving up the
    ///     tests' ability to decide what time it is.
    ///   - sleeper: waits out a backoff. Injected for the same reason and one
    ///     more: a test for a retry that succeeds on the third attempt should
    ///     not take as long as three real backoffs.
    public init(
        transport: any Transport,
        credentials: DeviceCredentials,
        tenant: TenantID,
        reconnectPolicy: ReconnectPolicy = .default,
        logger: MoqomLogger = .silent,
        clock: @escaping @Sendable () -> MonotonicTime = MoqomSession.systemClock,
        sleeper: @escaping @Sendable (Duration) async -> Void = MoqomSession.systemSleeper
    ) {
        self.transport = transport
        self.credentials = credentials
        self.tenant = tenant
        self.logger = logger
        self.clock = clock
        self.sleeper = sleeper
        identity = credentials.identity
        machine = SessionStateMachine(policy: reconnectPolicy)
        (stateStream, stateContinuation) = AsyncStream.makeStream(
            of: SessionState.self,
            bufferingPolicy: .bufferingNewest(8)
        )
    }

    /// Monotonic time from the system's uptime clock.
    ///
    /// Uptime rather than wall clock: an NTP correction that stepped backwards
    /// would resolve a blip into an exit, or the reverse.
    public static let systemClock: @Sendable () -> MonotonicTime = {
        .nanoseconds(DispatchTime.now().uptimeNanoseconds)
    }

    public static let systemSleeper: @Sendable (Duration) async -> Void = { duration in
        try? await Task.sleep(for: duration)
    }

    /// Where the session is.
    public var state: SessionState { machine.state }

    /// State as it changes.
    ///
    /// An `AsyncSequence` rather than a delegate, and there is no delegate
    /// alternative. Two ways to observe the same thing means two code paths to
    /// keep consistent, and the one the SDK author uses less is the one that
    /// gets the ordering wrong.
    public nonisolated var states: AsyncStream<SessionState> { stateStream }

    /// Open the transport.
    public func connect(to endpoint: RelayEndpoint, at now: MonotonicTime = .zero) async throws(MoqomError) {
        self.endpoint = endpoint
        apply(machine.handle(.connectRequested(at: now)))
        logger.info(
            .session,
            "connecting",
            [
                LogField("relay", .text("\(endpoint.host):\(endpoint.port)")),
                LogField("identity", .participant(identity)),
            ]
        )
        do {
            let session = try await transport.connect(to: endpoint, credentials: credentials)
            connection = session
            watch(session)
        } catch {
            logger.error(.session, "connect failed", [LogField("error", .text("\(error)"))])
            apply(machine.handle(.transportLost(at: now)))
            throw error
        }
        logger.info(.session, "connected")
        apply(machine.handle(.connected(at: now)))
    }

    /// Turn a session dying into a reconnect.
    ///
    /// One watcher per session, replaced rather than accumulated: a reconnect
    /// installs a new one, and leaving the old task alive would have a session
    /// two connections ago still able to trigger a retry.
    private func watch(_ session: any TransportSession) {
        interruptionWatch?.cancel()
        let interruptions = session.interruptions
        interruptionWatch = Task { [weak self] in
            for await _ in interruptions {
                guard let self else { return }
                await self.transportLost(at: self.now())
                return
            }
        }
    }

    private nonisolated func now() -> MonotonicTime { clock() }

    /// Join a room, or return the session already open on it.
    ///
    /// Joining subscribes to the room prefix, which *is* the roster: every
    /// participant on stage arrives through namespace announcement, including
    /// ones who join later, with no roster protocol to keep in agreement with
    /// who is actually publishing.
    /// - Parameter seatPolicy: how long a participant whose session vanishes
    ///   keeps their place in the roster. See ``SeatPolicy``.
    public func join(
        room: RoomID,
        seatPolicy: SeatPolicy = .default
    ) async throws(MoqomError) -> RoomSession {
        if let existing = rooms[room] { return existing }
        guard let connection else {
            throw MoqomError.invalidState(expected: "connected", actual: machine.state.description)
        }
        let namespace: TrackNamespace
        do {
            namespace = try MoqomNamespaces.room(tenant: tenant, room: room)
        } catch {
            throw MoqomError.invalidName(error)
        }
        let session = RoomSession(
            tenant: tenant,
            room: room,
            namespace: namespace,
            identity: identity,
            connection: connection,
            logger: logger,
            seatPolicy: seatPolicy
        )
        rooms[room] = session
        await session.begin()
        logger.info(.room, "joined", [LogField("room", .text(room.value))])
        return session
    }

    /// Go live on this device's own channel, without a room.
    ///
    /// The channel is the username. Viewers call ``watch(_:)`` with that name.
    /// Guests arrive by invitation: they still upload under their own name,
    /// and this catalog points at them.
    public func goLive(seatPolicy: SeatPolicy = .default) async throws(MoqomError) -> RoomSession {
        try await openChannel(identity.username, seatPolicy: seatPolicy)
    }

    /// Watch someone else's personal channel.
    public func watch(
        _ username: Username,
        seatPolicy: SeatPolicy = .default
    ) async throws(MoqomError) -> RoomSession {
        try await openChannel(username, seatPolicy: seatPolicy)
    }

    private func openChannel(
        _ username: Username,
        seatPolicy: SeatPolicy
    ) async throws(MoqomError) -> RoomSession {
        let room = RoomID(username.value)
        if let existing = rooms[room] { return existing }
        guard let connection else {
            throw MoqomError.invalidState(expected: "connected", actual: machine.state.description)
        }
        let namespace: TrackNamespace
        do {
            namespace = try MoqomNamespaces.personalPrefix(tenant: tenant, username: username)
        } catch {
            throw MoqomError.invalidName(error)
        }
        let session = RoomSession(
            tenant: tenant,
            room: room,
            namespace: namespace,
            identity: identity,
            connection: connection,
            logger: logger,
            seatPolicy: seatPolicy,
            channel: username
        )
        rooms[room] = session
        await session.begin()
        logger.info(.room, "channel", [LogField("username", .text(username.value))])
        return session
    }

    public func leave(room: RoomID) async {
        guard let session = rooms.removeValue(forKey: room) else { return }
        await session.end()
        logger.info(.room, "left", [LogField("room", .text(room.value))])
    }

    /// Report an application lifecycle change.
    ///
    /// Worth wiring even when it seems redundant: iOS suspends networking
    /// shortly after backgrounding unless the app holds a background mode, so a
    /// host checking a message otherwise looks exactly like a host whose phone
    /// died. Publishing the distinction is the only way the room can tell.
    public func setApplicationActive(_ active: Bool, at now: MonotonicTime = .zero) {
        apply(machine.handle(active ? .appForegrounded(at: now) : .appBackgrounded(at: now)))
    }

    /// Drive reconnection deadlines.
    ///
    /// Time is injected rather than read from a clock inside the session so
    /// that the transitions are testable, and so an app that already has a
    /// display link does not need a second timer.
    public func tick(at now: MonotonicTime) {
        apply(machine.handle(.tick(at: now)))
    }

    /// Report that the transport dropped.
    public func transportLost(at now: MonotonicTime) {
        apply(machine.handle(.transportLost(at: now)))
    }

    /// Close everything.
    public func close(_ event: TerminalEvent = .hostEnded, at now: MonotonicTime = .zero) async {
        // Set first. A reconnect already in flight is about to finish and would
        // otherwise install a fresh connection into a session being torn down,
        // which leaks the connection and resurrects the state.
        isClosed = true
        reconnect?.cancel()
        reconnect = nil
        interruptionWatch?.cancel()
        interruptionWatch = nil

        for room in rooms.values {
            await room.end()
        }
        rooms.removeAll()
        apply(machine.handle(.terminated(event, at: now)))
        await connection?.close(code: 0, reason: event.defaultDisplayString)
        connection = nil
        stateContinuation.finish()
    }

    private var isClosed = false

    private func apply(_ effects: [SessionEffect]) {
        guard !effects.isEmpty else { return }
        stateContinuation.yield(machine.state)
        logger.debug(.session, "state", [LogField("state", .text(machine.state.description))])
        for effect in effects {
            switch effect {
            case .startNewGroup:
                Task { [rooms] in
                    for room in rooms.values { await room.startNewGroup() }
                }
            case let .publishPresence(presence):
                Task { [rooms, identity] in
                    for room in rooms.values { await room.publishPresence(presence, for: identity) }
                }
            case let .deliverTerminal(event):
                Task { [rooms] in
                    for room in rooms.values { await room.deliverTerminal(event) }
                }
            case let .scheduleReconnect(attempt):
                scheduleReconnect(attempt: attempt, after: machine.currentBackoff)
            case .cancelReconnect:
                reconnect?.cancel()
                reconnect = nil
            case .tearDownTransport:
                reconnect?.cancel()
                reconnect = nil
                interruptionWatch?.cancel()
                interruptionWatch = nil
                if let connection {
                    self.connection = nil
                    Task { await connection.close(code: 0, reason: "session ended") }
                }
            case .openTransport:
                // The dial is `connect(to:)`, which is the call that produced
                // this effect. Redialling here would open a second connection
                // for every first one.
                break
            }
        }
    }

    /// Redial after a backoff, and put the rooms back on the new session.
    ///
    /// The attempt number comes from the state machine rather than being counted
    /// here, because the machine is also what decides when retrying has gone on
    /// long enough to present the participant as away — and two counters would
    /// disagree.
    private func scheduleReconnect(attempt: Int, after backoff: Duration) {
        reconnect?.cancel()
        reconnect = Task { [weak self] in
            await self?.sleepForBackoff(backoff)
            guard !Task.isCancelled else { return }
            await self?.attemptReconnect(attempt: attempt)
        }
    }

    private nonisolated func sleepForBackoff(_ backoff: Duration) async {
        await sleeper(backoff)
    }

    private func attemptReconnect(attempt: Int) async {
        guard let endpoint, !isClosed else { return }

        // The dead session is dropped before dialling rather than after. It is
        // already gone, and leaving it in place means a room that publishes
        // during the gap writes into a transport that will never flush.
        let stale = connection
        connection = nil

        do {
            let session = try await transport.connect(to: endpoint, credentials: credentials)
            guard !isClosed else {
                await session.close(code: 0, reason: "session ended")
                return
            }
            connection = session
            watch(session)

            // Rebound before the machine is told, so that `startNewGroup` and
            // the presence publish that follow `connected` land on the live
            // session instead of the one that just died.
            for room in rooms.values {
                await room.rebind(to: session)
            }
            logger.info(
                .session,
                "reconnected",
                [
                    LogField("attempt", .number(attempt)),
                    LogField("rooms", .number(rooms.count)),
                ]
            )
            apply(machine.handle(.connected(at: now())))
        } catch {
            logger.warning(
                .session,
                "reconnect failed",
                [
                    LogField("attempt", .number(attempt)),
                    LogField("error", .text("\(error)")),
                ]
            )

            // Straight back into the machine, which decides whether this is
            // still a reconnect or has become an absence, and hands back the
            // next backoff.
            apply(machine.handle(.transportLost(at: now())))
        }

        if let stale {
            await stale.close(code: 0, reason: "replaced")
        }
    }
}
