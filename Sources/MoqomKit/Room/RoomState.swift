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

    /// Whether the room is over.
    ///
    /// Terminal in both directions: nothing reopens a room, so a late entry
    /// arriving after the end is history rather than news. A client that let one
    /// move it back to `live` would resurrect a stream that has already told the
    /// user why it stopped.
    public var isEnded: Bool {
        if case .ended = self { return true }
        return false
    }
}

extension RoomLifecycle: Codable {
    private enum Key: String, CodingKey {
        case lifecycle
        case startsAt
        case actingHost
        case event
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        switch try container.decode(String.self, forKey: .lifecycle) {
        case "scheduled":
            self = .scheduled(startsAt: try container.decode(Date.self, forKey: .startsAt))
        case "live":
            self = .live
        case "actingHost":
            self = .actingHost(
                try container.decode(ParticipantIdentity.self, forKey: .actingHost)
            )
        case "ended":
            self = .ended(try container.decode(TerminalEvent.self, forKey: .event))
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .lifecycle,
                in: container,
                debugDescription: "unknown lifecycle \(other)"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        switch self {
        case let .scheduled(startsAt):
            try container.encode("scheduled", forKey: .lifecycle)
            try container.encode(startsAt, forKey: .startsAt)
        case .live:
            try container.encode("live", forKey: .lifecycle)
        case let .actingHost(identity):
            try container.encode("actingHost", forKey: .lifecycle)
            try container.encode(identity, forKey: .actingHost)
        case let .ended(event):
            try container.encode("ended", forKey: .lifecycle)
            try container.encode(event, forKey: .event)
        }
    }
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

    /// How many viewers each cohost brought, and how many arrived on their own.
    ///
    /// The only part of this type that is not derived from what this client can
    /// observe. Everything else here comes from announcements a client sees for
    /// itself; a viewer announces nothing, so viewers are absent from ``roster``
    /// by construction and their provenance is not something any client could
    /// work out. It arrives on the control track from the control plane, and is
    /// empty until it does.
    public var audiences: Audiences

    public init(
        tenant: TenantID,
        room: RoomID,
        namespace: TrackNamespace,
        roster: Roster = Roster(),
        watchdogs: WatchdogSet = WatchdogSet(),
        stage: StageState = StageState(),
        lifecycle: RoomLifecycle = .live,
        audiences: Audiences = Audiences()
    ) {
        self.tenant = tenant
        self.room = room
        self.namespace = namespace
        self.roster = roster
        self.watchdogs = watchdogs
        self.stage = stage
        self.lifecycle = lifecycle
        self.audiences = audiences
    }

    /// The number to show, and the number to bill.
    ///
    /// Drawn from the roster, which cannot contain a watchdog, so the UI count
    /// and the meter cannot disagree about whether a recorder is a person.
    ///
    /// Counts the people on stage and backstage, not the audience: a viewer never
    /// enters the roster. ``Audiences/total`` is the other number.
    public var participantCount: Int { roster.count }

    /// The audience a cohost in this room brought, largest first.
    ///
    /// Pairs each cohort with the participant it names, when that participant is
    /// present. A cohort whose cohost has left the room is deliberately not
    /// dropped from ``audiences``; it is simply absent from here, because there
    /// is no tile to put it on.
    public var audiencesOnStage: [(participant: Participant, audience: Audiences.Audience)] {
        audiences.attributed.compactMap { cohort in
            guard let via = cohort.via,
                  let participant = roster.participants.first(where: {
                      $0.slot.identity.username == via && !$0.slot.isBackstage
                  })
            else { return nil }
            return (participant, cohort)
        }
    }

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
    /// Somebody is out of the roster for good.
    ///
    /// Not sent when a session merely vanishes. A withdrawal holds the seat and
    /// reports ``presenceChanged(_:_:)`` with ``Presence/reconnecting`` first;
    /// this follows only if ``SeatPolicy`` runs out, and says so via
    /// ``DepartureReason/timedOut``.
    case participantLeft(ParticipantIdentity, DepartureReason)
    case presenceChanged(ParticipantIdentity, Presence)
    case muteChanged(ParticipantIdentity, MuteState)
    case grantsChanged(ParticipantIdentity, Grants)
    case spotlightChanged(ParticipantIdentity?)

    /// A participant published or changed their catalog.
    ///
    /// Where a viewer learns what a publisher actually offers. Until this
    /// arrives the SDK is guessing at a default ladder, and a guess that is
    /// wrong means subscribing to tracks that do not exist.
    case catalogChanged(ParticipantIdentity, Catalog)

    /// A watchdog attached, detached, or changed health. Separate from the
    /// participant cases so a client that renders the roster from these events
    /// physically cannot add a recorder to it.
    case watchdogChanged(WatchdogSet)

    case stageChanged(StageState)
    case lifecycleChanged(RoomLifecycle)

    /// Who brought the viewers, in full.
    ///
    /// Coarse and periodic rather than live: the authority quantises the counts
    /// and publishes on a timer, so this arrives every few seconds in a busy room
    /// and not at all in a quiet one. Treat it as a figure to display, never as a
    /// tick to animate.
    case audiencesChanged(Audiences)

    /// Who to draw, in what order, and which of them are talking.
    ///
    /// Carries the whole layout rather than a delta, because the interesting
    /// property is what did *not* change: an occupant keeps its position for as
    /// long as it holds a tile, so somebody starting to speak arrives here as a
    /// ring to redraw and not as a grid to rearrange.
    case galleryChanged([Gallery.Slot])

    /// Who the Picture in Picture window should draw, in order.
    ///
    /// Separate from ``galleryChanged`` because the two move independently: a
    /// cast that follows the speaker changes on speech that a nine-up grid
    /// absorbs without rearranging, and a window bounded at four tiles reaches
    /// its overflow long before the grid reaches its own. Only emitted once
    /// something has asked for a window.
    case pictureInPictureChanged([Gallery.Slot])

    /// Somebody's connection changed how it looks, this device included.
    ///
    /// One case for both, because the identity says which: an application draws
    /// the same indicator on a remote tile and on its own self view, and giving
    /// it two cases would only make it write the drawing code twice. Emitted on
    /// change and not on measurement, so a stable connection produces nothing.
    ///
    /// Only arrives while something is sampling ``RoomSession/statistics``, since
    /// quality is derived from a snapshot rather than tracked continuously —
    /// there is no measurement without a measurer, and a timer nobody read from
    /// would be battery spent on a number nobody wanted.
    case qualityChanged(ParticipantIdentity, ConnectionQuality)

    /// The stream is over. Arrives as media, before the transport winds down.
    case terminated(TerminalEvent)
}
