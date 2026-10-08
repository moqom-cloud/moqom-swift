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

    /// The device has no audio encoder or decoder for what was asked.
    case unsupportedAudioCodec(AudioCodec)

    /// End-to-end encryption was configured and could not be applied.
    ///
    /// Always fatal to the write that caused it. Publishing plaintext because
    /// encryption failed would give a caller who asked for E2EE a stream that
    /// silently is not one, which is worse than dropping the frame.
    case encryptionFailed(SFrameError)

    /// The room requires end-to-end encryption and this session has no key.
    ///
    /// Thrown before anything is announced or opened, so a refused publish
    /// leaves nothing half-started. Two ways out, and they belong to different
    /// people: the application calls ``RoomSession/useEncryption(_:)`` before
    /// publishing, or the room's backend sets its policy to optional through the
    /// admin API — which is recorded in the room's audit log and reaches this
    /// device as the `e2ee` claim on its next token. There is deliberately no
    /// third way from the client.
    case encryptionRequired

    /// The peer sent something the protocol does not allow.
    ///
    /// Distinct from ``transport(_:)`` because the correct response differs: a
    /// dropped connection is worth retrying and a peer that cannot frame a
    /// message is not. Reconnecting into the same violation is how a client
    /// turns one bug into a loop.
    case protocolViolation(String)

    /// The relay this session is connected to does not implement what the
    /// call needs.
    ///
    /// Thrown before anything is sent, so the session is unaffected. Not a
    /// rejection: asking again will not help, and neither will a new token —
    /// the remedy is a relay that has the feature, which for every case today
    /// means a MOQOM relay rather than a third-party one.
    case unsupportedByRelay(feature: RelayFeature, relay: String)

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

    /// This namespace was allowed, and the session's grants changed so that it
    /// no longer is: a moderator returned this participant to the audience, or
    /// moved them between the queue and the stage.
    ///
    /// Distinct from ``forbidden(_:)`` because the right response differs. That
    /// one is a token minted for the wrong room and wants fixing; this one is the
    /// room working as intended, and wants the interface to follow it. The
    /// session is still connected and still watching.
    case revoked(TrackNamespace)

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
        case let .protocolViolation(why):
            "protocol violation: \(why)"
        case let .unsupportedCodec(codec):
            "unsupported codec: \(codec.rawValue)"
        case let .unsupportedAudioCodec(codec):
            "unsupported audio codec: \(codec.rawValue)"
        case let .encryptionFailed(reason):
            "encryption failed: \(reason)"
        case .encryptionRequired:
            "encryption required: every room is end-to-end encrypted; pass credentials with a "
                + "keyDelivery, or call RoomSession.useEncryption(_:) before publishing"
        case let .unsupportedByRelay(feature, relay):
            "\(relay) does not support \(feature.description)"
        case let .platform(api, status):
            "\(api) failed with status \(status)"
        }
    }
}
