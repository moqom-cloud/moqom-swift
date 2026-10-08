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

    /// Which socket direct (peer-to-peer) paths run on; see
    /// ``bindDirectEndpoint(_:eligibility:exposure:)``.
    public nonisolated let directBackend: DirectBackend

    /// Whether rooms joined through this session use direct (peer-to-peer)
    /// paths; ``DirectPolicy/automatic`` unless the session was made otherwise.
    public nonisolated let directPolicy: DirectPolicy

    private let transport: any Transport

    /// The credential in force, which is not the one this session was built
    /// with once anything has been renewed.
    ///
    /// A `var` because a relay closes a session when the token that admitted it
    /// runs out. While that was unenforced this could be a constant and a
    /// reconnect could present the same token forever; now a token has a
    /// lifetime that outlives neither the call nor, on a long one, itself.
    private var credentials: DeviceCredentials

    private var machine: SessionStateMachine
    private var connection: (any TransportSession)?
    private var rooms: [RoomID: RoomSession] = [:]
    private var roomPolicies: [RoomID: DirectPolicy] = [:]
    /// The room limit and STUN server each room's direct paths were last set
    /// up with, `nil` for none, so a renewal that restates the same policy
    /// leaves live paths alone.
    private var appliedDirect: [RoomID: AppliedDirect?] = [:]

    private struct AppliedDirect: Equatable {
        var limit: Int
        var stun: DirectSTUNServer?
    }

    /// The endpoint to redial.
    ///
    /// Retained from ``connect(to:at:)`` because reconnection has to go
    /// somewhere and nothing else remembers where. A GOAWAY carrying a new URI
    /// replaces it, which is how a relay drains a client onto another instance.
    private var endpoint: RelayEndpoint?

    private var reconnect: Task<Void, Never>?
    private var interruptionWatch: Task<Void, Never>?
    private var renewal: Task<Void, Never>?

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
    ///   - directBackend: the socket direct paths run on. Network.framework by
    ///     default; `.rust` from the `MoqomDirectRust` module where it is
    ///     built.
    ///   - directPolicy: whether rooms use direct paths. Automatic by
    ///     default, which tells the other participants of a qualifying room
    ///     this device's IP addresses; ``DirectPolicy/relayOnly`` never does.
    public init(
        transport: any Transport,
        credentials: DeviceCredentials,
        tenant: TenantID,
        reconnectPolicy: ReconnectPolicy = .default,
        logger: MoqomLogger = .silent,
        directBackend: DirectBackend = .networkFramework,
        directPolicy: DirectPolicy = .automatic,
        clock: @escaping @Sendable () -> MonotonicTime = MoqomSession.systemClock,
        sleeper: @escaping @Sendable (Duration) async -> Void = MoqomSession.systemSleeper
    ) {
        self.transport = transport
        self.credentials = credentials
        self.tenant = tenant
        self.logger = logger
        self.directBackend = directBackend
        self.directPolicy = directPolicy
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

    #if canImport(Network)
        /// A direct endpoint on this session's ``directBackend``.
        ///
        /// What a room with direct paths turned on binds its endpoints with
        /// (``RoomSession/setDirect(_:)``). For an app driving a direct path
        /// itself, outside a room.
        public nonisolated func bindDirectEndpoint(
            _ configuration: DirectConfiguration,
            eligibility: DirectEligibility,
            exposure: DirectIPExposure
        ) async throws(DirectEndpointError) -> DirectEndpoint {
            try await DirectEndpoint.bind(
                configuration,
                eligibility: eligibility,
                exposure: exposure,
                backend: directBackend
            )
        }
    #endif

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
        scheduleRenewal()
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

    // MARK: - Keeping the credential fresh

    /// How long before a token lapses to go and get the next one.
    ///
    /// Wide enough to cover a round trip to whoever mints tokens, a retry, and a
    /// phone that was asleep when the timer should have fired. The cost of being
    /// early is one extra token; the cost of being late is the relay closing a
    /// call that was working.
    private static let renewalMargin: TimeInterval = 120

    /// How long to wait before trying again when a renewal did not work.
    ///
    /// Also what stops this loop spinning. A credential already inside
    /// ``renewalMargin`` computes no wait at all, which is correct for the first
    /// attempt and would be a request per round trip if it were also correct for
    /// every attempt after a failure.
    private static let retryInterval: TimeInterval = 15

    /// Replace the credential before the relay stops accepting it, for as long as
    /// the session lasts.
    ///
    /// Started on connect and restarted on reconnect, because the deadline moves
    /// with the token rather than with the connection. A session with nothing to
    /// renew with — no ``DeviceCredentials/renew`` closure, or no expiry to
    /// renew before — schedules nothing, which is every caller that predates
    /// this and every session against a relay holding no keys.
    private func scheduleRenewal() {
        renewal?.cancel()
        renewal = nil
        guard credentials.renew != nil, credentials.expiresAt != nil else { return }
        renewal = Task { [weak self] in
            await self?.keepCredentialFresh()
        }
    }

    private func keepCredentialFresh() async {
        while !isClosed, !Task.isCancelled {
            guard let renew = credentials.renew, let expiresAt = credentials.expiresAt else {
                return
            }

            // Deliberately not the injected backoff sleeper. A test that stubs
            // out reconnection delays should not thereby stub out token
            // lifetimes and find this minting as fast as the network allows.
            let wait = expiresAt.timeIntervalSinceNow - Self.renewalMargin
            if wait > 0 {
                try? await Task.sleep(for: .seconds(wait))
                guard !isClosed, !Task.isCancelled else { return }
            }

            let issued: IssuedToken
            do {
                issued = try await renew()
            } catch {
                // Retried rather than given up on, because the usual cause is a
                // network that is briefly unavailable — and the session is still
                // working, so there is time. Bounded by the token's own
                // remaining life: when that runs out the relay closes the
                // session and the reconnect path takes over, which is the right
                // escalation rather than a second one written here.
                logger.warning(
                    .session,
                    "could not renew the credential",
                    [LogField("error", .text("\(error)"))]
                )
                try? await Task.sleep(for: .seconds(Self.retryInterval))
                continue
            }

            credentials = credentials.replacing(with: issued)
            let remaining = issued.expiresAt.timeIntervalSinceNow

            // A renewed token restates the room's encryption policy, and that is
            // how an administrator's change reaches a call already in progress.
            let policy = credentials.encryptionPolicy
            for room in rooms.values {
                await room.applyEncryptionPolicy(policy)
            }
            await reapplyDirect()

            if let connection {
                do {
                    try await connection.renewCredential(issued.token)
                    logger.debug(
                        .session,
                        "credential renewed",
                        [LogField("expires_in", .number(Int(remaining)))]
                    )
                } catch {
                    // The token is still worth keeping even though it could not
                    // be handed over: a reconnect presents whatever is current,
                    // so a renewal that failed on the wire has still spared the
                    // redial from arriving with an expired credential.
                    logger.warning(
                        .session,
                        "renewed the credential but could not present it",
                        [LogField("error", .text("\(error)"))]
                    )
                }
            }

            // A replacement that arrives already inside the window it was
            // fetched for has bought no time, so the next pass would compute no
            // wait and ask for another immediately, forever. Waiting here is
            // what bounds that to one attempt per interval, and it is done after
            // presenting rather than instead of it — the token is still the
            // freshest one there is.
            if remaining <= Self.renewalMargin {
                try? await Task.sleep(for: .seconds(Self.retryInterval))
            }
        }
    }

    /// Present a token with different grants on the connection already open.
    ///
    /// How a viewer becomes a guest, or a guest returns to the audience,
    /// without leaving: the backend mints a token for the new role, the app
    /// hands it here, and the relay applies it to this session. Nothing
    /// reconnects, the roster is not rebuilt and playback does not stop. What
    /// the new grants allow can be used at once — a promoted guest calls
    /// ``RoomSession/startBroadcast(from:configuration:backstage:)`` on the
    /// room they are already in — and what they no longer allow is ended by the
    /// relay and reported as ``RoomEvent/publishingRevoked(_:)``.
    ///
    /// The token must be for the same person, on this device, in the same room.
    /// A relay ignores one that is not, and one minted before the token it
    /// replaces, so a token kept from before a demotion cannot undo it. Moving
    /// to a different room is ``join(room:seatPolicy:)``.
    ///
    /// - Parameters:
    ///   - issued: the token for the new role.
    ///   - renew: how to obtain the next one, when it differs from before. The
    ///     automatic renewal presents whatever this returns, so a closure still
    ///     minting the old role would put the participant back in it at the next
    ///     renewal. `nil` keeps the closure the session already has, which is
    ///     right when that closure asks a backend that already knows the new
    ///     role.
    /// - Throws: ``MoqomError/invalidState(expected:actual:)`` when the token
    ///   could not be handed to the relay. It is kept regardless, and a
    ///   reconnect presents it.
    public func updateCredential(
        _ issued: IssuedToken,
        renewingWith renew: (@Sendable () async throws -> IssuedToken)? = nil
    ) async throws(MoqomError) {
        if let renew {
            let previous = credentials
            credentials = DeviceCredentials(
                identity: credentials.identity,
                token: issued.token,
                deviceKey: credentials.deviceKey,
                expiresAt: issued.expiresAt,
                renew: renew,
                keyDelivery: credentials.keyDelivery
            )
            credentials.authorityKeys = previous.authorityKeys
            credentials.plaintextForTesting = previous.plaintextForTesting
            credentials.directRoom = issued.direct
        } else {
            credentials = credentials.replacing(with: issued)
        }

        let policy = credentials.encryptionPolicy
        for room in rooms.values {
            await room.applyEncryptionPolicy(policy)
        }
        await reapplyDirect()
        // The deadline belongs to the token, and this one has its own.
        scheduleRenewal()

        guard let connection else { return }
        try await connection.renewCredential(issued.token)
        logger.info(.session, "credential updated on the open connection")
    }

    /// Join a room, or return the session already open on it.
    ///
    /// Joining subscribes to the room prefix, which *is* the roster: every
    /// participant on stage arrives through namespace announcement, including
    /// ones who join later, with no roster protocol to keep in agreement with
    /// who is actually publishing.
    /// - Parameters:
    ///   - seatPolicy: how long a participant whose session vanishes keeps
    ///     their place in the roster. See ``SeatPolicy``.
    ///   - direct: direct (peer-to-peer) paths for this room, where it
    ///     qualifies; `nil` keeps everything on the relay. The same as
    ///     ``join(room:seatPolicy:directPolicy:)`` with
    ///     ``DirectPolicy/custom(_:)`` or ``DirectPolicy/relayOnly``.
    public func join(
        room: RoomID,
        seatPolicy: SeatPolicy = .default,
        direct: DirectRoomOptions?
    ) async throws(MoqomError) -> RoomSession {
        try await join(room: room, seatPolicy: seatPolicy, directPolicy: direct.map(DirectPolicy.custom) ?? .relayOnly)
    }

    /// Join a room, or return the session already open on it.
    ///
    /// Media starts on the relay. Under ``directPolicy`` (automatic unless the
    /// session was made otherwise) a 1:1 call or a small private room moves to
    /// direct paths where it qualifies.
    /// - Parameter seatPolicy: how long a participant whose session vanishes
    ///   keeps their place in the roster. See ``SeatPolicy``.
    public func join(
        room: RoomID,
        seatPolicy: SeatPolicy = .default
    ) async throws(MoqomError) -> RoomSession {
        try await join(room: room, seatPolicy: seatPolicy, directPolicy: directPolicy)
    }

    /// Join a room, or return the session already open on it, with its own
    /// ``DirectPolicy`` in place of the session's. Applied to a room already
    /// open too.
    public func join(
        room: RoomID,
        seatPolicy: SeatPolicy = .default,
        directPolicy: DirectPolicy
    ) async throws(MoqomError) -> RoomSession {
        let session = try await open(room: room, seatPolicy: seatPolicy)
        roomPolicies[room] = directPolicy
        appliedDirect[room] = nil
        try await applyDirect(to: room)
        return session
    }

    private func open(room: RoomID, seatPolicy: SeatPolicy) async throws(MoqomError) -> RoomSession {
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
            seatPolicy: seatPolicy,
            encryptionPolicy: credentials.encryptionPolicy,
            authorityKeys: credentials.authorityKeys,
            keyDelivery: credentials.keyDelivery,
            currentToken: { [weak self] in await self?.credentials.token ?? Data() },
            updateCredential: { [weak self] issued, renew throws(MoqomError) in
                guard let self else {
                    throw MoqomError.invalidState(expected: "an open session", actual: "closed")
                }
                try await self.updateCredential(issued, renewingWith: renew)
            }
        )
        rooms[room] = session
        #if canImport(Network)
            await session.provideDirectHooks(RoomDirectHooks(
                credentials: { [weak self] in await self?.credentials },
                bind: { [weak self] configuration, eligibility, exposure throws(DirectEndpointError) in
                    guard let self else { throw DirectEndpointError.busy }
                    return try await self.bindDirectEndpoint(
                        configuration, eligibility: eligibility, exposure: exposure
                    )
                }
            ))
        #endif
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
            channel: username,
            encryptionPolicy: credentials.encryptionPolicy,
            authorityKeys: credentials.authorityKeys,
            updateCredential: { [weak self] issued, renew throws(MoqomError) in
                guard let self else {
                    throw MoqomError.invalidState(expected: "an open session", actual: "closed")
                }
                try await self.updateCredential(issued, renewingWith: renew)
            }
        )
        rooms[room] = session
        await session.begin()
        logger.info(.room, "channel", [LogField("username", .text(username.value))])
        return session
    }

    /// The options `room`'s policy comes to under the credential in force, or
    /// `nil` for the relay alone.
    func directOptions(for policy: DirectPolicy) -> DirectRoomOptions? {
        let limits = credentials.directRoom
        guard limits.allowed, limits.maximumParticipants >= 2 else { return nil }
        switch policy.mode {
        case .relayOnly:
            return nil
        case var .custom(options):
            options.maximumParticipants = min(options.maximumParticipants, limits.maximumParticipants)
            if options.stun == nil {
                options.stun = limits.stun.map { (host: $0.host, port: $0.port) }
            }
            return options
        case let .automatic(stun):
            guard !credentials.authorityKeys.isEmpty else { return nil }
            var options = DirectRoomOptions(
                exposure: .peersWillLearnMyIPAddresses(),
                tokenKeys: credentials.authorityKeys,
                stun: stun ?? limits.stun.map { (host: $0.host, port: $0.port) }
            )
            options.maximumParticipants = limits.maximumParticipants
            return options
        }
    }

    private func applyDirect(to room: RoomID) async throws(MoqomError) {
        guard let session = rooms[room], let policy = roomPolicies[room] else { return }
        let options = directOptions(for: policy)
        let applied = options.map {
            AppliedDirect(limit: $0.maximumParticipants, stun: $0.stun.map { DirectSTUNServer(host: $0.host, port: $0.port) })
        }
        if let previous = appliedDirect[room], previous == applied { return }
        do {
            try await session.setDirect(options)
        } catch {
            // Automatic is a default, not a demand: a room that cannot have
            // direct paths here carries on through the relay.
            guard case .custom = policy.mode else {
                appliedDirect[room] = .some(nil)
                logger.info(.room, "direct paths unavailable", [LogField("error", .text("\(error)"))])
                return
            }
            throw error
        }
        appliedDirect[room] = .some(applied)
    }

    /// A new credential can restate the room's direct policy.
    private func reapplyDirect() async {
        for room in roomPolicies.keys {
            try? await applyDirect(to: room)
        }
    }

    public func leave(room: RoomID) async {
        roomPolicies[room] = nil
        appliedDirect[room] = nil
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
        renewal?.cancel()
        renewal = nil

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
                renewal?.cancel()
                renewal = nil
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
            // The new connection was dialled with whatever credential is current,
            // which after a renewal is not the one this session was built with.
            // Rearmed rather than left running because the deadline belongs to
            // the token and the old task may be mid-sleep against a stale one.
            scheduleRenewal()
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
