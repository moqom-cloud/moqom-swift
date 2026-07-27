// A snapshot of a room.
//
// Rooms outlive connections. A room exists because there is a row in the
// control plane's database, not because someone is currently publishing —
// participants, subscriptions, and relay sessions are all soft state layered on
// that record, and losing any of them is a degradation rather than a deletion.
// The tempting implementation, deriving room state from who is connected,
// produces a room that evaporates the moment a host walks into a lift.

import Foundation
import MoqomCore

/// Where a room is in its life.
public enum RoomLifecycle: Hashable, Sendable {
    /// Created, not yet started.
    case scheduled(startsAt: Date)

    case live

    /// The host is gone past the threshold and a cohost is holding the room.
    ///
    /// Succession grants moderation rights and never transfers ownership.
    /// Automatic ownership transfer would mean a host with bad WiFi permanently
    /// loses their room; the owner reclaims automatically on return.
    case actingHost(ParticipantIdentity)

    case ended(TerminalEvent)
}

/// Everything a client knows about a room right now.
public struct RoomState: Sendable {
    public let tenant: TenantID
    public let room: RoomID

    /// The prefix everything in this room announces under.
    public let namespace: TrackNamespace

    /// Who is here. Contains participants and agents; cannot contain watchdogs.
    public var roster: Roster

    /// What is observing. Disclosed as room-level chrome, never as a tile, and
    /// deliberately a separate field from ``roster`` rather than a filtered
    /// view of it.
    public var watchdogs: WatchdogSet

    public var stage: StageState

    public var lifecycle: RoomLifecycle

    public init(
        tenant: TenantID,
        room: RoomID,
        namespace: TrackNamespace,
        roster: Roster = Roster(),
        watchdogs: WatchdogSet = WatchdogSet(),
        stage: StageState = StageState(),
        lifecycle: RoomLifecycle = .live
    ) {
        self.tenant = tenant
        self.room = room
        self.namespace = namespace
        self.roster = roster
        self.watchdogs = watchdogs
        self.stage = stage
        self.lifecycle = lifecycle
    }

    /// The number to show, and the number to bill.
    ///
    /// Drawn from the roster, which cannot contain a watchdog, so the UI count
    /// and the meter cannot disagree about whether a recorder is a person.
    public var participantCount: Int { roster.count }

    /// Whether to show the recording indicator.
    public var isRecording: Bool { watchdogs.isRecording }

    /// Everyone currently publishing video.
    public var broadcasters: [Participant] {
        roster.participants.filter { $0.grants.publish.contains(.video) && !$0.slot.isBackstage }
    }

    /// Waiting to go live, visible only to hosts.
    public var backstage: [Participant] {
        roster.participants.filter(\.slot.isBackstage)
    }
}

/// Events on the room control track.
///
/// Participant state is published rather than inferred, so clients render a
/// "reconnecting" treatment instead of a frozen frame with no explanation — and
/// they get it at media latency through the same fan-out tree as the video.
public enum RoomEvent: Sendable {
    case participantJoined(Participant)
    case participantLeft(ParticipantIdentity)
    case presenceChanged(ParticipantIdentity, Presence)
    case muteChanged(ParticipantIdentity, MuteState)
    case grantsChanged(ParticipantIdentity, Grants)
    case spotlightChanged(ParticipantIdentity?)

    /// A watchdog attached, detached, or changed health. Separate from the
    /// participant cases so a client that renders the roster from these events
    /// physically cannot add a recorder to it.
    case watchdogChanged(WatchdogSet)

    case stageChanged(StageState)
    case lifecycleChanged(RoomLifecycle)

    /// The stream is over. Arrives as media, before the transport winds down.
    case terminated(TerminalEvent)
}
