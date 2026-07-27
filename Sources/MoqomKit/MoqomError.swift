// Every way an SDK call can fail, enumerated.
//
// Stringly-typed errors are the reason integrators write `if
// error.localizedDescription.contains("token")`, and then break when we improve
// the message. Each case here exists because an application would plausibly
// branch on it: a token expiry drives a refresh, a moderation termination drives
// an appeals screen, and a transport loss drives a reconnect spinner. Cases that
// nobody could act on differently are collapsed rather than multiplied.

import Foundation
import MoqomCore

/// A failure from the MOQOM SDK.
public enum MoqomError: Error, Sendable {
    /// The name, namespace, or identity could not be constructed.
    case invalidName(NameError)

    /// The transport could not be established, or dropped in a way the session
    /// could not recover from.
    case transport(TransportFailure)

    /// The relay or control plane refused the request.
    case rejected(RejectionReason)

    /// The call is valid but not in this state — subscribing before connecting,
    /// publishing after leaving.
    case invalidState(expected: String, actual: String)

    /// The session ended. Carries enough to render the right thing, which is
    /// the point: the four terminal states want four different treatments and a
    /// single "disconnected" event is a UX bug baked in early.
    case terminated(TerminalEvent)

    /// The operation is not permitted by the capabilities in this token.
    case notPermitted(Capability)

    /// The device has no encoder or decoder for what was asked.
    case unsupportedCodec(VideoCodec)

    /// A platform framework returned a failure the SDK cannot interpret.
    ///
    /// The `OSStatus` is preserved verbatim because VideoToolbox status codes
    /// are the only useful thing to search for when an encode fails on one
    /// device model and not another.
    case platform(api: String, status: Int32)
}

/// Why a transport attempt failed.
public enum TransportFailure: Error, Hashable, Sendable {
    /// No route to the relay, or the handshake never completed.
    case unreachable

    /// The relay's certificate did not validate.
    case untrustedPeer

    /// The peer closed with an application error code.
    case closedByPeer(code: UInt64, reason: String)

    /// The connection went idle past its timeout.
    case idleTimeout

    /// The transport is already closed.
    case closed
}

/// Why the far side said no.
public enum RejectionReason: Hashable, Sendable {
    /// The token is absent, malformed, or expired.
    case unauthorized

    /// The token is valid but its `moqt` claim does not cover this namespace.
    case forbidden(TrackNamespace)

    /// The namespace exists but nothing is publishing under it.
    case trackNotFound(FullTrackName)

    /// The room does not exist, or has been closed.
    case roomNotFound(RoomID)

    /// A limit was hit: subscribe budget, watchdog cap, stage slots.
    case limitExceeded(String)

    /// The relay is shedding load and the client should re-steer.
    case unavailable
}

extension MoqomError: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .invalidName(error):
            "invalid name: \(error)"
        case let .transport(failure):
            "transport: \(failure)"
        case let .rejected(reason):
            "rejected: \(reason)"
        case let .invalidState(expected, actual):
            "invalid state: expected \(expected), was \(actual)"
        case let .terminated(event):
            "terminated: \(event.reason)"
        case let .notPermitted(capability):
            "not permitted: requires \(capability)"
        case let .unsupportedCodec(codec):
            "unsupported codec: \(codec.rawValue)"
        case let .platform(api, status):
            "\(api) failed with status \(status)"
        }
    }
}
