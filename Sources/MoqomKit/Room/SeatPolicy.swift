// How long a vanished participant's place in the room is held open.
//
// A namespace withdrawal is the relay saying "this session is gone", and it is
// the truth about the transport. It is not the truth about the person. A phone
// that goes through a tunnel, loses a battery, or gets suspended behind a
// backgrounded app produces exactly the same withdrawal as somebody pressing
// leave, and removing the participant on sight makes a ten-second dead spot
// indistinguishable from a departure: the tile disappears, the gallery
// reflows, everyone else's layout changes, and then it all happens again in
// reverse when they come back.
//
// So a withdrawal starts a clock instead of ending a membership. Within the
// window the participant stays in the roster as ``Presence/reconnecting``,
// keeps their seat and their slot in the grid, and a re-announcement puts them
// back with nothing else disturbed. Past it they are gone for real.
//
// The clock does not run for a deliberate departure. Pressing leave, or being
// evicted, arrives on the control track before the withdrawal does, and those
// remove immediately -- there is nobody to wait for.

import Foundation

/// How long each kind of participant keeps their seat after vanishing.
///
/// Keyed by role because the cost of guessing wrong is wildly different at
/// either end of the room. Dropping the host early ends everybody's broadcast;
/// dropping a viewer late costs a line in a list. The defaults are chosen
/// against those consequences rather than by picking one number and applying
/// it evenly.
public struct SeatPolicy: Hashable, Sendable {
    /// The person whose room it is.
    ///
    /// The longest window by a distance, because their absence is the one that
    /// cannot be allowed to end the room by accident. A host who drops has to
    /// be able to walk between buildings, or have iOS suspend the app while
    /// they answer a call, and come back to a room that is still theirs.
    public var owner: Duration

    /// On stage, publishing, holding one of the video boxes.
    ///
    /// Long enough that the grid does not reflow around a brief drop, which is
    /// disruptive to every viewer and not just to them.
    public var cohost: Duration

    /// Invited up to the stage, publishing, less structurally load-bearing than
    /// a cohost.
    public var guest: Duration

    /// Moderating without publishing. Holds no tile, so the only cost of
    /// waiting is that the moderator list is briefly stale.
    public var moderator: Duration

    /// Watching, publishing nothing.
    ///
    /// The shortest window, and the one place where holding a seat has a price
    /// beyond tidiness: ``Roster/count`` is what the meter bills, so a viewer
    /// who is kept around after leaving is a viewer somebody is charged for.
    /// Short enough that a reload does not double-count and a departure is
    /// billed roughly when it happens.
    public var viewer: Duration

    public init(
        owner: Duration = .seconds(120),
        cohost: Duration = .seconds(60),
        guest: Duration = .seconds(45),
        moderator: Duration = .seconds(30),
        viewer: Duration = .seconds(10)
    ) {
        self.owner = owner
        self.cohost = cohost
        self.guest = guest
        self.moderator = moderator
        self.viewer = viewer
    }

    /// The window for a role.
    public func grace(for role: ParticipantRole) -> Duration {
        switch role {
        case .owner: owner
        case .cohost: cohost
        case .guest: guest
        case .moderator: moderator
        case .viewer: viewer
        }
    }

    public static let `default` = SeatPolicy()

    /// Remove everyone the moment their namespace goes.
    ///
    /// For tests that assert on departure, and for a deployment that would
    /// rather have a roster that is occasionally wrong than one that is
    /// occasionally slow. Not a sensible default for anything with a camera in
    /// it.
    public static let immediate = SeatPolicy(
        owner: .zero,
        cohost: .zero,
        guest: .zero,
        moderator: .zero,
        viewer: .zero
    )
}

/// Why a participant left the roster.
///
/// Worth distinguishing at the point of departure rather than reconstructing
/// later: "the host pressed leave" and "the host's phone died and never came
/// back" produce the same empty seat and want different words on screen.
public enum DepartureReason: String, Hashable, Sendable, Codable {
    /// They said so — a deliberate leave, or a control-track presence of
    /// ``Presence/left``.
    case left

    /// A moderator removed them.
    case evicted

    /// Their session vanished and the seat was held until
    /// ``SeatPolicy`` ran out.
    case timedOut

    /// *This* client lost its connection, so its view of the room was rebuilt
    /// from scratch.
    ///
    /// Says nothing about them. While disconnected there is no way to tell who
    /// is still in the room — nobody sends a withdrawal for somebody who left
    /// during an outage — so the roster is discarded and repopulated from the
    /// announcements that arrive on reconnecting. Most of these are followed by
    /// the same person rejoining a moment later.
    case connectionLost
}
