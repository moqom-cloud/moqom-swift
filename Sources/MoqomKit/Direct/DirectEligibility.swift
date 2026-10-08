// Who may use a direct (peer-to-peer) path, and the acknowledgement it needs.
//
// A direct path is an upgrade to a session that already works through the
// relay, never a replacement for one, and it is only ever offered where it
// takes nothing away: a small room, end-to-end encrypted, where everybody has
// agreed to it and nobody is an audience. The rules are the same in every SDK
// and refuse the same cases for the same reasons; `moqom_client::direct` is the
// Rust half.
//
// The rule that decides most of this is the one about addresses. A direct path
// tells the peer this device's network addresses, and handing a viewer a
// creator's home address is a stalking risk, so viewers never get one.

import Foundation

/// What the room and this session are, as far as direct mode is concerned.
///
/// Stated by the caller, who has the room's policy, and checked here.
public struct DirectEligibility: Hashable, Sendable {
    /// The most participants a room may have and still use direct paths.
    ///
    /// Each extra peer costs every publisher a full upload of their media, so
    /// the upload grows with the room while the relay's fan-out does not.
    public static let maximumParticipants = 4

    /// The room's media is end-to-end encrypted.
    public var endToEndEncrypted: Bool

    /// How many participants are in the room, including this one.
    public var participants: Int

    /// Every participant has opted in, not only this one.
    public var everyoneOptedIn: Bool

    /// The room requires a recorder or safety watchdog to see its media.
    public var watchdogRequired: Bool

    /// This session is a viewer in an audience rather than a participant.
    public var audience: Bool

    /// The room's own limit on participants, from its policy. Never above
    /// ``maximumParticipants``.
    public var limit: Int

    public init(
        endToEndEncrypted: Bool,
        participants: Int,
        everyoneOptedIn: Bool,
        watchdogRequired: Bool = false,
        audience: Bool = false,
        limit: Int = Self.maximumParticipants
    ) {
        self.endToEndEncrypted = endToEndEncrypted
        self.participants = participants
        self.everyoneOptedIn = everyoneOptedIn
        self.watchdogRequired = watchdogRequired
        self.audience = audience
        self.limit = limit
    }

    /// Whether a direct path is allowed.
    ///
    /// - Throws: The first reason it is not, in the order a product would want
    ///   to explain them: who is asking, then what the room is.
    public func check() throws(DirectIneligibility) {
        if audience { throw .audience }
        if !endToEndEncrypted { throw .notEncrypted }
        if watchdogRequired { throw .watchdogRequired }
        if participants < 2 { throw .alone }
        if participants > min(limit, Self.maximumParticipants) { throw .tooManyParticipants(participants) }
        if !everyoneOptedIn { throw .notEveryoneOptedIn }
    }
}

/// Why a room or session may not use a direct path.
public enum DirectIneligibility: Error, Hashable, Sendable, CustomStringConvertible {
    /// Direct paths remove server-side recording and moderation. In an
    /// encrypted room those are already off, so nothing is lost that was not
    /// already gone; anywhere else they would be.
    case notEncrypted
    case tooManyParticipants(Int)
    case alone
    case notEveryoneOptedIn
    case watchdogRequired
    /// Direct paths would hand a viewer the publisher's network address.
    case audience

    public var description: String {
        switch self {
        case .notEncrypted: "the room is not end-to-end encrypted"
        case let .tooManyParticipants(count):
            "\(count) participants is more than direct mode allows in this room"
        case .alone: "there is no other participant"
        case .notEveryoneOptedIn: "not every participant has opted in"
        case .watchdogRequired: "the room requires a watchdog"
        case .audience: "viewers never use direct paths"
        }
    }
}

/// Acknowledgement that a direct path reveals this device's IP addresses to
/// the peer.
///
/// A type rather than a `Bool` so that it cannot be passed by accident: the only
/// way to get one is a function whose name says what it means. Construct it from
/// an explicit choice by the person holding the device, after saying so in the
/// UI.
public struct DirectIPExposure: Sendable {
    private init() {}

    /// The person using this device has agreed that the other participants will
    /// learn its public and local IP addresses.
    public static func peersWillLearnMyIPAddresses() -> Self { Self() }
}
