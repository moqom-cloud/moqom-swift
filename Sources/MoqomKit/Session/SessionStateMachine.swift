// The session lifecycle, as a pure state machine.
//
// This is separated from the session actor because the interesting behaviour
// here is entirely about time and ordering, and neither is pleasant to test
// through a network. Feeding it a synthetic clock is the only way to assert
// that a 30-second tunnel is invisible and a 4-minute one is not.
//
// The thing it exists to get right: a transient blip, an extended absence, and
// a deliberate exit look identical on the wire, and treating the first as the
// third is the failure this guards against — a host walks into a lift and the
// room evaporates. QUIC already removes most of the first case, because a
// WiFi-to-cellular handoff keeps the connection ID and therefore the session,
// but the app being suspended in the background is not something QUIC can help
// with and is by far the most common cause on a phone.

import Foundation
import MoqomCore

/// Monotonic time, measured from an arbitrary origin.
///
/// Not `Date`: the deadlines here are durations since an event, and a wall
/// clock that steps backwards over NTP correction would resolve a blip into an
/// exit or the reverse.
public typealias MonotonicTime = Duration

/// Where the session is.
public enum SessionState: Hashable, Sendable {
    /// Nothing has been attempted.
    case idle

    /// A transport is being established.
    case connecting

    /// Media can flow.
    case established

    /// The transport dropped and the SDK is retrying. Viewers see a reconnect
    /// treatment; the participant's slot in the room is held.
    case reconnecting(since: MonotonicTime)

    /// Reconnection has run long enough that the participant is presented as
    /// away rather than as a glitch. The slot is still held.
    case away(since: MonotonicTime)

    /// Over, with a reason worth rendering.
    case closed(TerminalEvent)
}

extension SessionState: CustomStringConvertible {
    public var description: String {
        switch self {
        case .idle: "idle"
        case .connecting: "connecting"
        case .established: "established"
        case .reconnecting: "reconnecting"
        case .away: "away"
        case let .closed(event): "closed(\(event.reason))"
        }
    }
}

/// What a participant's peers should be shown.
///
/// Published on the room control track rather than inferred from silence, so a
/// client renders "reconnecting" instead of a frozen frame with no explanation.
public enum Presence: String, Hashable, Sendable, Codable {
    case connected
    case reconnecting
    case away

    /// The app is not in the foreground. Distinct from ``away`` because iOS
    /// suspends networking shortly after backgrounding, so a host checking a
    /// message looks exactly like a host whose phone died — and the room should
    /// be able to tell the difference.
    case backgrounded
    case left
}

/// Something that happened to the session.
public enum SessionEvent: Hashable, Sendable {
    case connectRequested(at: MonotonicTime)
    case connected(at: MonotonicTime)

    /// The transport went away for a reason that might resolve itself.
    case transportLost(at: MonotonicTime)

    /// Time passed. Deadlines are evaluated here rather than by a timer inside
    /// the machine, so a test can advance time instantly.
    case tick(at: MonotonicTime)

    case appBackgrounded(at: MonotonicTime)
    case appForegrounded(at: MonotonicTime)

    /// The far side ended it, or the user did.
    case terminated(TerminalEvent, at: MonotonicTime)
}

/// What the caller should do about a transition.
public enum SessionEffect: Hashable, Sendable {
    case openTransport
    case scheduleReconnect(attempt: Int)
    case cancelReconnect

    /// Publish this on the room control track.
    case publishPresence(Presence)

    /// Resumption always starts a new group: frames were lost during the gap,
    /// so decoders need a fresh keyframe and continuing the interrupted group
    /// would hand every viewer an undecodable stream.
    case startNewGroup

    case tearDownTransport

    /// Hand the app the terminal event. A silent black screen is never an
    /// acceptable default, so this fires even when nothing is listening — the
    /// session surfaces a default terminal card in that case.
    case deliverTerminal(TerminalEvent)
}

/// Timings that decide which of the three situations a disconnection is.
///
/// All tenant-configurable in the control plane and all wanting measurement
/// against real mobile traffic; these are starting points, not findings.
public struct ReconnectPolicy: Hashable, Sendable {
    /// How long a drop stays presented as a glitch.
    public var reconnectingWindow: Duration

    /// How long the slot is held after that before the session gives up.
    public var awayWindow: Duration

    /// First retry delay; subsequent attempts back off geometrically.
    public var initialBackoff: Duration

    /// Ceiling on the backoff, so a long outage still retries at a useful rate
    /// when the network returns.
    public var maximumBackoff: Duration

    public init(
        reconnectingWindow: Duration = .seconds(90),
        awayWindow: Duration = .seconds(240),
        initialBackoff: Duration = .milliseconds(250),
        maximumBackoff: Duration = .seconds(10)
    ) {
        self.reconnectingWindow = reconnectingWindow
        self.awayWindow = awayWindow
        self.initialBackoff = initialBackoff
        self.maximumBackoff = maximumBackoff
    }

    public static let `default` = ReconnectPolicy()
}

/// Drives ``SessionState`` from ``SessionEvent``.
public struct SessionStateMachine: Sendable {
    /// Current state.
    public private(set) var state: SessionState = .idle

    /// The policy in force.
    public var policy: ReconnectPolicy

    private var reconnectAttempts = 0
    private var wasBackgrounded = false

    public init(policy: ReconnectPolicy = .default) {
        self.policy = policy
    }

    /// The delay before the next reconnect attempt.
    public var currentBackoff: Duration {
        guard reconnectAttempts > 0 else { return policy.initialBackoff }
        let scaled = policy.initialBackoff * (1 << min(reconnectAttempts - 1, 16))
        return min(scaled, policy.maximumBackoff)
    }

    /// Apply an event and return what the caller should do.
    ///
    /// Returns effects in the order they should be performed. An empty result
    /// means the event was not meaningful in this state, which is a normal
    /// outcome rather than an error — a `tick` while established is the common
    /// case and should not require the caller to filter.
    @discardableResult
    public mutating func handle(_ event: SessionEvent) -> [SessionEffect] {
        switch (state, event) {
        case (.idle, .connectRequested), (.closed, .connectRequested):
            state = .connecting
            reconnectAttempts = 0
            return [.openTransport]

        case (.connecting, .connected):
            state = .established
            reconnectAttempts = 0
            return [.publishPresence(.connected)]

        case (.reconnecting, .connected), (.away, .connected):
            state = .established
            reconnectAttempts = 0
            return [.cancelReconnect, .startNewGroup, .publishPresence(.connected)]

        case let (.connecting, .transportLost(at: time)),
             let (.established, .transportLost(at: time)):
            state = .reconnecting(since: time)
            reconnectAttempts = 1
            return [.scheduleReconnect(attempt: 1), .publishPresence(.reconnecting)]

        case let (.reconnecting(since), .transportLost),
             let (.away(since), .transportLost):
            // A failed retry is not a new disconnection: the clock that decides
            // reconnecting-versus-away runs from the original loss, so retrying
            // must not reset it or a flapping link never resolves to away.
            reconnectAttempts += 1
            state = isAway(state) ? .away(since: since) : .reconnecting(since: since)
            return [.scheduleReconnect(attempt: reconnectAttempts)]

        case let (.reconnecting(since), .tick(at: now)):
            guard now - since >= policy.reconnectingWindow else { return [] }
            state = .away(since: since)
            return [.publishPresence(wasBackgrounded ? .backgrounded : .away)]

        case let (.away(since), .tick(at: now)):
            guard now - since >= policy.awayWindow else { return [] }
            let event = TerminalEvent.networkFailure
            state = .closed(event)
            return [.cancelReconnect, .tearDownTransport, .deliverTerminal(event)]

        case (.established, .appBackgrounded):
            // Not a state change. Broadcasting continues under a background
            // mode; what changes is only what peers are told, so the room can
            // distinguish a host who stepped away from one who vanished.
            wasBackgrounded = true
            return [.publishPresence(.backgrounded)]

        case (_, .appBackgrounded):
            wasBackgrounded = true
            return []

        case (.established, .appForegrounded):
            wasBackgrounded = false
            return [.publishPresence(.connected)]

        case (_, .appForegrounded):
            wasBackgrounded = false
            return []

        case (.closed, _):
            return []

        case let (_, .terminated(terminal, _)):
            state = .closed(terminal)
            return [
                .cancelReconnect,
                .publishPresence(.left),
                .tearDownTransport,
                .deliverTerminal(terminal),
            ]

        default:
            return []
        }
    }

    private func isAway(_ state: SessionState) -> Bool {
        if case .away = state { return true }
        return false
    }
}
