// Whether a session's rooms use direct (peer-to-peer) paths, and what the
// control plane allows of them.
//
// Automatic by default: a 1:1 call or a small private room goes device to
// device wherever ``DirectEligibility`` holds, and stays on the relay
// everywhere else. A direct path tells each peer this device's IP addresses, so
// an application whose users must not learn each other's addresses passes
// ``DirectPolicy/relayOnly``. Either way the media is end-to-end encrypted
// under the room's MLS keys.
//
// One participant not opting in keeps the whole room on the relay, so a device
// on `relayOnly`, or in a room whose policy forbids direct paths, is enough to
// keep everyone's addresses private from everyone else in that room.

import Foundation

/// How a session's rooms may use direct (peer-to-peer) paths.
public struct DirectPolicy: Sendable {
    enum Mode: Sendable {
        case automatic(stun: (host: String, port: UInt16)?)
        case relayOnly
        case custom(DirectRoomOptions)
    }

    let mode: Mode

    /// Direct paths wherever the room qualifies, with the relay as the
    /// fallback. The default.
    ///
    /// Choosing it accepts, on the user's behalf, that the other participants
    /// of a qualifying room learn this device's public and local IP addresses;
    /// say so in the app. Peers are verified against the session's
    /// ``DeviceCredentials/authorityKeys``, and a session holding none stays on
    /// the relay, having nothing to verify a peer with.
    ///
    /// The public address comes from the STUN server the token service names
    /// with the token (``DirectRoomPolicy/stun``), which is a MOQOM relay's.
    /// A service that names none leaves only this device's own addresses to
    /// offer, which reach a peer on the same network and nothing behind a NAT.
    public static let automatic = DirectPolicy(mode: .automatic(stun: nil))

    /// ``automatic``, learning the public address from this STUN server rather
    /// than the one the token service names.
    public static func automatic(stun: (host: String, port: UInt16)) -> DirectPolicy {
        DirectPolicy(mode: .automatic(stun: stun))
    }

    /// Every participant's media through the relay, this device's addresses
    /// never offered to anyone, and no STUN server asked.
    public static let relayOnly = DirectPolicy(mode: .relayOnly)

    /// Direct paths with options the application chose. The room's limit from
    /// the control plane still applies.
    public static func custom(_ options: DirectRoomOptions) -> DirectPolicy {
        DirectPolicy(mode: .custom(options))
    }

    /// Whether this policy ever offers a direct path.
    public var allowsDirect: Bool {
        if case .relayOnly = mode { false } else { true }
    }
}

/// What the control plane allows of direct paths in a room, as it states with
/// each token it issues.
public struct DirectRoomPolicy: Hashable, Sendable {
    /// The room may use direct paths at all.
    public var allowed: Bool

    /// The most participants the room may have and still use them, never more
    /// than ``DirectEligibility/maximumParticipants``.
    public var maximumParticipants: Int

    /// Where ``DirectPolicy/automatic`` learns this device's public address:
    /// the relays' STUN responder, as the token service names it. `nil` when
    /// it names none.
    public var stun: DirectSTUNServer?

    public init(
        allowed: Bool,
        maximumParticipants: Int = DirectEligibility.maximumParticipants,
        stun: DirectSTUNServer? = nil
    ) {
        self.allowed = allowed
        self.maximumParticipants = min(max(maximumParticipants, 0), DirectEligibility.maximumParticipants)
        self.stun = stun
    }

    /// What a control plane that says nothing means: allowed, up to the
    /// SDK's own limit, with no STUN server.
    public static let `default` = DirectRoomPolicy(allowed: true)

    /// The policy in a token service's response, `{"allowed": …,
    /// "maxParticipants": …, "stun": {"host": …, "port": …}}`; ``default``
    /// for anything else.
    init(json: Any?) {
        guard let object = json as? [String: Any] else {
            self = .default
            return
        }
        let allowed = object["allowed"] as? Bool ?? true
        let limit = (object["maxParticipants"] as? Int).flatMap { $0 > 0 ? $0 : nil }
        self.init(
            allowed: allowed,
            maximumParticipants: limit ?? DirectEligibility.maximumParticipants,
            stun: DirectSTUNServer(json: object["stun"])
        )
    }
}

/// A STUN server: a host name or address literal, and a UDP port.
public struct DirectSTUNServer: Hashable, Sendable {
    public var host: String
    public var port: UInt16

    public init(host: String, port: UInt16 = 3478) {
        self.host = host
        self.port = port
    }

    /// `{"host": …, "port": …}`, or `nil` for anything a device could not
    /// dial.
    init?(json: Any?) {
        guard let object = json as? [String: Any],
              let host = object["host"] as? String, !host.isEmpty,
              let port = object["port"] as? Int, let port = UInt16(exactly: port), port != 0
        else { return nil }
        self.init(host: host, port: port)
    }
}
