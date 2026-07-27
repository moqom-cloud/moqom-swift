// Moderation capabilities, as a set rather than a level.
//
// "Mod" and "super mod" are the right product vocabulary and the wrong data
// model. Every platform that starts with levels eventually needs "this person
// can do X but not Y" and discovers the ordering was never real — is "ban
// permanently" above or below "promote to cohost"? They are incomparable, and
// forcing them onto a line produces either a level nobody wants or a pile of
// exceptions.
//
// So the presets are sugar over a set, and who can act on whom falls out of
// subset relations. That single rule handles the cases a hierarchy gets wrong:
// a mod cannot demote a peer mod (equal sets), a super mod can demote a mod
// (strict superset), and two moderators with different specialities cannot act
// on each other (incomparable). It is a partial order, which is what the real
// permission structure always was.

import Foundation

/// One or more moderation capabilities.
///
/// Grouped by enforcement point, which is not cosmetic: the stage and mute
/// capabilities affect live media and are checked by the relay from a compact
/// bitmask in the token, with no lookup on the hot path. The rest are
/// control-plane concerns checked on API calls, where the full set can be read
/// from the database and token size stays bounded.
public struct Capability: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    // Chat.
    public static let deleteMessage = Capability(rawValue: 1 << 0)
    public static let timeoutUser = Capability(rawValue: 1 << 1)
    public static let banFromChat = Capability(rawValue: 1 << 2)
    public static let setChatMode = Capability(rawValue: 1 << 3)
    public static let manageFilters = Capability(rawValue: 1 << 4)

    // Stage. Relay-enforced.
    public static let promoteToGuest = Capability(rawValue: 1 << 8)
    public static let promoteToCohost = Capability(rawValue: 1 << 9)
    public static let demote = Capability(rawValue: 1 << 10)
    public static let forceMute = Capability(rawValue: 1 << 11)
    public static let spotlight = Capability(rawValue: 1 << 12)
    public static let manageQueue = Capability(rawValue: 1 << 13)
    public static let lockStage = Capability(rawValue: 1 << 14)

    // Room.
    public static let kick = Capability(rawValue: 1 << 16)
    public static let banFromRoom = Capability(rawValue: 1 << 17)
    public static let banFromTenant = Capability(rawValue: 1 << 18)
    public static let closeRoom = Capability(rawValue: 1 << 19)
    public static let changeRoomPolicy = Capability(rawValue: 1 << 20)

    /// Attach, detach, start, and stop watchdogs.
    ///
    /// A generalisation of "control recording" rather than a separate
    /// permission, because a customer's archiver and our recorder are the same
    /// kind of thing and should not need two grants.
    public static let manageWatchdogs = Capability(rawValue: 1 << 21)

    // Meta.
    public static let appointModerators = Capability(rawValue: 1 << 24)
    public static let readModerationLog = Capability(rawValue: 1 << 25)
    public static let handleAppeals = Capability(rawValue: 1 << 26)

    public static let chatGroup: Capability = [
        .deleteMessage, .timeoutUser, .banFromChat, .setChatMode, .manageFilters,
    ]

    public static let stageGroup: Capability = [
        .promoteToGuest, .promoteToCohost, .demote, .forceMute, .spotlight, .manageQueue,
        .lockStage,
    ]

    public static let roomGroup: Capability = [
        .kick, .banFromRoom, .banFromTenant, .closeRoom, .changeRoomPolicy, .manageWatchdogs,
    ]

    public static let metaGroup: Capability = [
        .appointModerators, .readModerationLog, .handleAppeals,
    ]

    /// A viewer with no moderation rights.
    public static let none: Capability = []

    /// The chat group.
    public static let moderator: Capability = .chatGroup

    /// Chat plus stage.
    public static let superModerator: Capability = [.chatGroup, .stageGroup]

    /// Everything. Held by the room owner, who cannot be demoted.
    public static let owner: Capability = [.chatGroup, .stageGroup, .roomGroup, .metaGroup]
}

/// What a participant is permitted to publish.
///
/// Granular rather than binary because the common flow is to bring someone up
/// audio-only and grant video once they are settled. Independent of
/// ``Capability``: a guest publishes but cannot kick anyone, a text moderator
/// kicks but never appears on camera, and an agent publishes and controls
/// nothing. Modelling these as one enum forces a fake ordering and produces the
/// "moderator who mysteriously can't mute" bug.
public struct PublishScope: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let audio = PublishScope(rawValue: 1 << 0)
    public static let video = PublishScope(rawValue: 1 << 1)
    public static let screenShare = PublishScope(rawValue: 1 << 2)
    public static let data = PublishScope(rawValue: 1 << 3)

    public static let none: PublishScope = []
    public static let audioOnly: PublishScope = [.audio]
    public static let camera: PublishScope = [.audio, .video]
    public static let full: PublishScope = [.audio, .video, .screenShare, .data]
}

/// The two orthogonal grants a participant holds.
public struct Grants: Hashable, Sendable, Codable {
    public var publish: PublishScope
    public var moderation: Capability

    /// Whether this participant owns the room. Ownership is a database row, not
    /// a capability, which is why it sits beside the set rather than in it:
    /// automatic transfer would mean a host with bad WiFi permanently loses
    /// their room.
    public var isOwner: Bool

    public init(publish: PublishScope = .none, moderation: Capability = .none, isOwner: Bool = false) {
        self.publish = publish
        self.moderation = moderation
        self.isOwner = isOwner
    }

    /// Whether this participant may act on `target`.
    ///
    /// Strict superset, so peers cannot act on each other. The owner is above
    /// all of it and no one is above the owner.
    public func canModerate(_ target: Grants) -> Bool {
        if target.isOwner { return false }
        if isOwner { return true }
        return moderation.isStrictSuperset(of: target.moderation)
    }

    /// Whether this participant may hand out `requested`.
    ///
    /// Two rules, both the same escalation argument: a grant can only ever be a
    /// subset of the granter's own set, and no capability grants itself. If a
    /// cohost could promote arbitrary viewers to cohost, one compromised
    /// account would escalate to room takeover in a single step.
    public func canGrant(_ requested: Capability) -> Bool {
        if isOwner { return true }
        guard moderation.isSuperset(of: requested) else { return false }
        return !requested.contains(.appointModerators)
    }
}

/// A label for the UI, derived from the grants.
///
/// Explicitly not a source of truth. The token is the role — there is no
/// `setClientRole` here, because Agora's does not actually take effect under
/// co-host token authentication and so becomes a second source of truth that
/// can silently disagree with the authorisation that actually governs. This
/// exists so a view can pick a badge without reimplementing the mapping.
public enum ParticipantRole: String, Hashable, Sendable {
    case owner
    case cohost
    case guest
    case moderator
    case viewer

    public init(_ grants: Grants) {
        if grants.isOwner {
            self = .owner
        } else if grants.publish.contains(.video), !grants.moderation.isEmpty {
            self = .cohost
        } else if !grants.publish.isEmpty {
            self = .guest
        } else if !grants.moderation.isEmpty {
            self = .moderator
        } else {
            self = .viewer
        }
    }
}
