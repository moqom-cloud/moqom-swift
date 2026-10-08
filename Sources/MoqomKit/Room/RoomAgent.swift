// A recorder or classifier that decrypts, on the tenant's side.
//
// Every room is end-to-end encrypted, so nothing MOQOM runs can record or
// classify what is said in one: the relay and the hosted recorder see
// ciphertext. A tenant that needs either runs an agent — this — wherever it
// keeps its own data. The agent is a member of the room's MLS group like any
// device, holds the keys, and hands the tenant's code decrypted media through
// the same seams a viewer has: ``RoomSession/media(from:)``,
// ``RoomSession/frames(from:)``, ``RoomSession/tapVideo(from:policy:)`` and
// ``RoomSession/tapAudio(from:policy:)``.
//
// It is never secret. Its username is `watchdog.<id>`, which the control plane
// mints only for a watchdog attached to the room, and every participant's
// device sees its leaf in the group and sends nothing until the room's signed
// control log discloses that watchdog (see ``GroupKeyStatus/undisclosedAgents``).
// Attach the watchdog first, with the descriptor people will be shown; then
// start the agent.

import Foundation
import MoqomCore

/// Follows everyone in a room at full size, for a recorder or classifier that
/// holds the room's keys.
public actor RoomAgent {
    /// The session media is read from.
    public let room: RoomSession

    /// The box every participant is laid out in, which decides the rung
    /// subscribed. Large, so a recording is made at the top rung whatever any
    /// viewer is watching.
    public let box: RenderBox

    /// The link budget subscriptions are planned against, in bits a second.
    ///
    /// Stated rather than estimated. The estimator is built for a phone on a
    /// cellular link, and left to it a recorder that has just joined would be
    /// planned onto the bottom rung — the case ``Watchdog/pinnedLayer`` warns
    /// about. An agent runs where the tenant keeps its data, on a link that
    /// carries the whole ladder.
    public let linkBitrate: Int

    /// How often the roster is re-read for arrivals and departures.
    public let interval: Duration

    private var following: Task<Void, Never>?

    /// The username an agent for `watchdog` joins under.
    public static func username(for watchdog: WatchdogID) throws(NameError) -> Username {
        try Username("watchdog.\(watchdog.value)")
    }

    public init(
        room: RoomSession,
        box: RenderBox = RenderBox(width: 3840, height: 2160, scale: 1),
        linkBitrate: Int = 200_000_000,
        interval: Duration = .milliseconds(500)
    ) {
        self.room = room
        self.box = box
        self.linkBitrate = linkBitrate
        self.interval = interval
    }

    /// Subscribe to everyone present, and keep doing so as people come and go.
    public func start() {
        guard following == nil else { return }
        let room = room
        let box = box
        let interval = interval
        let linkBitrate = linkBitrate
        following = Task {
            var laidOut: [ParticipantIdentity: LayerLadder] = [:]
            while !Task.isCancelled {
                // Re-planned when a catalog changes a ladder too, not only when
                // somebody arrives: the first plan is made against the default
                // ladder, before the publisher has said what it offers.
                var present: [ParticipantIdentity: LayerLadder] = [:]
                for participant in await room.roster.participants {
                    present[participant.id] = await room.catalog(of: participant.id)?.videoLadder ?? LayerLadder(rungs: [])
                }
                if present != laidOut {
                    await room.updateLayout(
                        Dictionary(uniqueKeysWithValues: present.keys.map { ($0, box) }),
                        linkBitrate: linkBitrate
                    )
                    laidOut = present
                }
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stop() {
        following?.cancel()
        following = nil
    }
}
