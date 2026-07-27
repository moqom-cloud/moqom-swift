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

    private let transport: any Transport
    private let credentials: DeviceCredentials
    private var machine: SessionStateMachine
    private var connection: (any TransportSession)?
    private var rooms: [RoomID: RoomSession] = [:]

    private let stateStream: AsyncStream<SessionState>
    private let stateContinuation: AsyncStream<SessionState>.Continuation

    public init(
        transport: any Transport,
        credentials: DeviceCredentials,
        tenant: TenantID,
        reconnectPolicy: ReconnectPolicy = .default
    ) {
        self.transport = transport
        self.credentials = credentials
        self.tenant = tenant
        identity = credentials.identity
        machine = SessionStateMachine(policy: reconnectPolicy)
        (stateStream, stateContinuation) = AsyncStream.makeStream(
            of: SessionState.self,
            bufferingPolicy: .bufferingNewest(8)
        )
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
        apply(machine.handle(.connectRequested(at: now)))
        do {
            connection = try await transport.connect(to: endpoint, credentials: credentials)
        } catch {
            apply(machine.handle(.transportLost(at: now)))
            throw error
        }
        apply(machine.handle(.connected(at: now)))
    }

    /// Join a room, or return the session already open on it.
    ///
    /// Joining subscribes to the room prefix, which *is* the roster: every
    /// participant on stage arrives through namespace announcement, including
    /// ones who join later, with no roster protocol to keep in agreement with
    /// who is actually publishing.
    public func join(room: RoomID) async throws(MoqomError) -> RoomSession {
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
            connection: connection
        )
        rooms[room] = session
        await session.begin()
        return session
    }

    public func leave(room: RoomID) async {
        guard let session = rooms.removeValue(forKey: room) else { return }
        await session.end()
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
        for room in rooms.values {
            await room.end()
        }
        rooms.removeAll()
        apply(machine.handle(.terminated(event, at: now)))
        await connection?.close(code: 0, reason: event.defaultDisplayString)
        connection = nil
        stateContinuation.finish()
    }

    private func apply(_ effects: [SessionEffect]) {
        guard !effects.isEmpty else { return }
        stateContinuation.yield(machine.state)
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
            case .openTransport, .scheduleReconnect, .cancelReconnect, .tearDownTransport:
                // Retry scheduling belongs to whoever owns the run loop; the
                // session reports what should happen rather than owning a timer
                // that a test would then have to wait on.
                break
            }
        }
    }
}
