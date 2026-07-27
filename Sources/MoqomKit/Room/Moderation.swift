// Moderation and stage management.
//
// Most moderation in a live room is not punishment. Promoting a viewer to
// guest, inviting a cohost, bringing someone up audio-only, spotlighting a
// speaker, and sending a guest backstage are the actions hosts reach for
// constantly, and they get the same treatment here as bans.
//
// The asymmetry worth understanding before changing anything in this file:
// grants flow through tokens and revocations flow through relay state.
// Promotion is additive, so a token reissue is fine and a few hundred
// milliseconds is a UX detail. Demotion is subtractive, and if it only takes
// effect when the token next revalidates then a demoted cohost keeps publishing
// for the remainder of the revalidation interval. That is a security hole, not
// a UX detail, so demotion rides the same immediate path as a ban.

import Foundation
import MoqomCore

/// Something a moderator does to a participant.
public enum ModerationAction: Hashable, Sendable {
    /// Remove from the room. Held in relay state and checked on every SUBSCRIBE
    /// and PUBLISH, so a kick issued while the client is briefly offline still
    /// lands when it returns rather than failing silently.
    case kick(ParticipantIdentity)

    /// Ban with an expiry. `nil` is permanent — there is no 24-hour clamp.
    case banFromRoom(ParticipantIdentity, until: Date?)

    /// Ban across the tenant.
    case banFromTenant(Username, until: Date?)

    /// Ban the specific hardware key.
    ///
    /// The precise instrument: an IP ban hits everyone behind a CGNAT and a
    /// username ban is evaded with a new account, but the `jkt` thumbprint is
    /// the key in that device's Secure Enclave and survives a username change.
    case banDevice(DeviceID, until: Date?)

    /// Force-mute for everyone, relay-enforced. A rung well short of
    /// termination: an audio-only violation should cost the audio track, not
    /// the broadcast.
    case forceMute(ParticipantIdentity, MediaKind, until: Date?)

    case unmute(ParticipantIdentity, MediaKind)

    /// Take publish rights away. Immediate, by the rule above.
    case demote(ParticipantIdentity, PublishScope)

    case spotlight(ParticipantIdentity?)

    /// Freeze promotions during an incident.
    case lockStage(Bool)

    case closeRoom(TerminalEvent)

    /// The capability this action requires.
    public var requiredCapability: Capability {
        switch self {
        case .kick: .kick
        case .banFromRoom: .banFromRoom
        case .banFromTenant: .banFromTenant
        case .banDevice: .banFromTenant
        case .forceMute, .unmute: .forceMute
        case .demote: .demote
        case .spotlight: .spotlight
        case .lockStage: .lockStage
        case .closeRoom: .closeRoom
        }
    }

    /// Who it is aimed at, when it is aimed at a specific participant.
    public var target: ParticipantIdentity? {
        switch self {
        case let .kick(identity),
             let .banFromRoom(identity, _),
             let .forceMute(identity, _, _),
             let .unmute(identity, _),
             let .demote(identity, _):
            identity
        case let .spotlight(identity):
            identity
        case .banFromTenant, .banDevice, .lockStage, .closeRoom:
            nil
        }
    }
}

/// Which way a stage change was initiated.
public enum StageDirection: String, Hashable, Sendable {
    /// The viewer asked to come up.
    case request

    /// The host asked them up.
    case invitation
}

/// How a pending stage change resolved.
public enum StageOutcome: String, Hashable, Sendable {
    case pending
    case accepted
    case declined
    case cancelled
    case timedOut
}

/// A pending promotion, in either direction.
///
/// Both directions are handshakes with a pending state, a timeout, and a
/// cancel, because a promotion that lands while the invitee is not looking is
/// worse than no promotion.
///
/// Every invitation, acceptance, decline, and timeout is training data for the
/// cohost recommendation agent. That flywheel cannot be backfilled, which is
/// why the outcomes are modelled explicitly rather than collapsed into "did it
/// happen".
public struct StageInvitation: Hashable, Sendable, Identifiable {
    public let id: UUID
    public let direction: StageDirection
    public let subject: ParticipantIdentity
    public let issuedBy: ParticipantIdentity

    /// What they would be granted. Permission, not behaviour — see
    /// ``StageInvitation/accept()``.
    public let offered: PublishScope

    public let issuedAt: MonotonicTime
    public let expiresAfter: Duration
    public private(set) var outcome: StageOutcome

    public init(
        id: UUID = UUID(),
        direction: StageDirection,
        subject: ParticipantIdentity,
        issuedBy: ParticipantIdentity,
        offered: PublishScope,
        issuedAt: MonotonicTime,
        expiresAfter: Duration = .seconds(30)
    ) {
        self.id = id
        self.direction = direction
        self.subject = subject
        self.issuedBy = issuedBy
        self.offered = offered
        self.issuedAt = issuedAt
        self.expiresAfter = expiresAfter
        outcome = .pending
    }

    /// Accepting yields the grant and nothing else.
    ///
    /// A publish scope permits publishing; it does not start it. The client
    /// must still affirmatively go live and the SDK must never auto-enable a
    /// camera on a scope change. This falls out of the protocol naturally, but
    /// getting it wrong is a privacy incident rather than a bug, so it is
    /// stated as a requirement instead of left to be discovered.
    public mutating func accept() {
        guard outcome == .pending else { return }
        outcome = .accepted
    }

    public mutating func decline() {
        guard outcome == .pending else { return }
        outcome = .declined
    }

    public mutating func cancel() {
        guard outcome == .pending else { return }
        outcome = .cancelled
    }

    /// Resolve the timeout. Returns `true` when this call expired it.
    @discardableResult
    public mutating func expire(at now: MonotonicTime) -> Bool {
        guard outcome == .pending, now - issuedAt >= expiresAfter else { return false }
        outcome = .timedOut
        return true
    }
}

/// The stage, its queue, and its cap.
public struct StageState: Hashable, Sendable {
    /// How many participants may publish video at once.
    ///
    /// The relay does not care how many publishers a namespace has — the limit
    /// is what a client can decode, not what the server will carry. This is a
    /// product cap and a waiting line, not a protocol one.
    public var slotLimit: Int

    /// Promotions are frozen.
    public var isLocked: Bool

    /// Who is spotlighted, if anyone.
    public var spotlighted: ParticipantIdentity?

    /// Waiting to come up, in order.
    public var queue: [ParticipantIdentity]

    /// Handshakes in flight.
    public var pending: [StageInvitation]

    public init(
        slotLimit: Int = 8,
        isLocked: Bool = false,
        spotlighted: ParticipantIdentity? = nil,
        queue: [ParticipantIdentity] = [],
        pending: [StageInvitation] = []
    ) {
        self.slotLimit = slotLimit
        self.isLocked = isLocked
        self.spotlighted = spotlighted
        self.queue = queue
        self.pending = pending
    }

    /// Expire anything past its deadline, returning what lapsed.
    public mutating func expirePending(at now: MonotonicTime) -> [StageInvitation] {
        var lapsed: [StageInvitation] = []
        for index in pending.indices where pending[index].expire(at: now) {
            lapsed.append(pending[index])
        }
        pending.removeAll { $0.outcome != .pending }
        return lapsed
    }
}

/// Whether a moderator may take an action against a target.
///
/// The check is one function so that the relay-enforced and control-plane paths
/// cannot drift: both call this, and adding a capability to
/// ``ModerationAction/requiredCapability`` is enough to protect it everywhere.
public func authorize(
    _ action: ModerationAction,
    by actor: Grants,
    against target: Grants?
) -> Result<Void, MoqomError> {
    guard actor.isOwner || actor.moderation.contains(action.requiredCapability) else {
        return .failure(.notPermitted(action.requiredCapability))
    }
    if let target, !actor.canModerate(target) {
        return .failure(.notPermitted(action.requiredCapability))
    }
    return .success(())
}
