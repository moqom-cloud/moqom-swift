// The roster, and why it cannot contain anything that is not publishing.
//
// A `Participant` is reachable only through a `ParticipantSlot`, and a slot is
// reachable only from a namespace announcement. That is the whole mechanism:
// the roster *is* namespace announcement, so a participant appears because they
// published under the room prefix, and anything that publishes nothing has no
// namespace entry and therefore cannot be constructed into this type at all.
//
// The alternative — one entity type with an `isWatchdog` flag and a filter at
// each read site — is a long tail of small wrongnesses. A viewer count that
// reads 13 instead of 12. A recorder that appears kickable. A safety detector
// that can be promoted to the stage. And the filter that gets forgotten is
// always the one in the billing path, where a customer who enables recording
// watches their concurrent-participant count tick up and cannot reconcile the
// invoice against anything they recognise.

import Foundation
import MoqomCore

/// Proof that something announced a namespace under a room prefix.
///
/// The initialiser is failable and takes an announcement, so there is no way to
/// mint one for an entity that does not publish. Watchdogs have no path to this
/// type, which is what makes their exclusion from the roster structural rather
/// than a filter someone has to remember to apply.
public struct ParticipantSlot: Hashable, Sendable {
    /// The full namespace the participant announced.
    public let namespace: TrackNamespace

    /// Who it resolves to.
    public let identity: ParticipantIdentity

    /// Whether the slot is backstage rather than on stage.
    ///
    /// Backstage sits outside the prefix viewers subscribe to, so a guest
    /// waiting to go live is visible to hosts and not to the audience. Going
    /// live is a change of namespace, not a renegotiation — which is why
    /// promotion costs the same in front of ten million viewers as in front of
    /// two.
    public let isBackstage: Bool

    /// Derive a slot from an announcement under a room or backstage prefix.
    ///
    /// Returns `nil` when the announcement is not under the prefix or does not
    /// have exactly the trailing username and device fields. That second check
    /// keeps a deeper namespace — a sub-track, or something a future draft adds
    /// — from being read as a participant.
    public init?(
        announced namespace: TrackNamespace,
        under prefix: TrackNamespace,
        isBackstage: Bool = false
    ) {
        guard let identity = MoqomNamespaces.identity(announcedAt: namespace, under: prefix) else {
            return nil
        }
        self.namespace = namespace
        self.identity = identity
        self.isBackstage = isBackstage
    }
}

/// Why a participant's media is not arriving.
///
/// Four distinct features that share a word and nothing else. Each has a
/// different decider and a different enforcement point, and collapsing them
/// produces either a mute that can be bypassed or a preference that needs a
/// server round-trip.
public struct MuteState: Hashable, Sendable {
    /// The participant stopped publishing. Client-side, instant, needs no
    /// authorisation — but is still published, so the room can see it.
    public var selfMuted: MediaKind

    /// Force-muted for everyone. Relay-enforced, never a polite request to the
    /// client, because a modified client ignores requests. Held in relay state,
    /// so it survives the participant reconnecting — otherwise a force-muted
    /// cohost unmutes themselves by restarting the app.
    public var forcedForEveryone: MediaKind

    /// Audible to other hosts, not to the audience. Needs no new machinery: the
    /// relay already authorises subscriptions by token scope, so a track marked
    /// host-only is forwarded only to subscribers holding a host scope.
    public var forcedForAudience: MediaKind

    /// Silenced by *this* viewer, for this viewer only.
    ///
    /// Never leaves the device. Because the relay forwards rather than mixes,
    /// a viewer muting a cohost simply stops subscribing and the bytes never
    /// leave the relay — a bandwidth saving rather than a wasted download, and
    /// instant because there is nothing to ask.
    public var localToMe: MediaKind

    public init(
        selfMuted: MediaKind = [],
        forcedForEveryone: MediaKind = [],
        forcedForAudience: MediaKind = [],
        localToMe: MediaKind = []
    ) {
        self.selfMuted = selfMuted
        self.forcedForEveryone = forcedForEveryone
        self.forcedForAudience = forcedForAudience
        self.localToMe = localToMe
    }

    /// Everything this viewer will not receive, whatever the reason.
    public var effective: MediaKind {
        [selfMuted, forcedForEveryone, localToMe].reduce(into: MediaKind()) { $0.formUnion($1) }
    }

    /// The reason to show, most authoritative first.
    ///
    /// Self-muted, moderator-muted, and locally-muted-by-me are three different
    /// things to a viewer, and a force-muted cohost needs to know they were
    /// muted rather than assuming a hardware fault.
    public func reason(for kind: MediaKind) -> MuteReason? {
        if forcedForEveryone.contains(kind) { return .moderator }
        if selfMuted.contains(kind) { return .selfChosen }
        if localToMe.contains(kind) { return .localToMe }
        if forcedForAudience.contains(kind) { return .audienceOnly }
        return nil
    }
}

/// Why something is muted, for display.
public enum MuteReason: String, Hashable, Sendable {
    case selfChosen
    case moderator
    case audienceOnly
    case localToMe
}

/// Someone on stage or backstage.
public struct Participant: Hashable, Sendable, Identifiable {
    /// The announcement that put them here.
    public let slot: ParticipantSlot

    /// What they may publish and moderate.
    public var grants: Grants

    /// How the room should present them.
    public var presence: Presence

    /// Whether their media is reaching this viewer, and why not.
    public var mute: MuteState

    /// Marked primary in the catalog so clients lay out accordingly.
    public var isSpotlighted: Bool

    /// What they are actually publishing, and at what qualities.
    public var ladders: [MediaKind.RawValue: LayerLadder]

    public var id: ParticipantIdentity { slot.identity }

    /// The user, which is a string and stays one.
    public var username: Username { slot.identity.username }

    /// Which of their devices this is. The same user may be present more than
    /// once; that is multi-device working, not a duplicate to collapse.
    public var device: DeviceID { slot.identity.device }

    /// A badge, derived. Not authoritative — see ``ParticipantRole``.
    public var role: ParticipantRole { ParticipantRole(grants) }

    public init(
        slot: ParticipantSlot,
        grants: Grants = Grants(),
        presence: Presence = .connected,
        mute: MuteState = MuteState(),
        isSpotlighted: Bool = false,
        ladders: [MediaKind.RawValue: LayerLadder] = [:]
    ) {
        self.slot = slot
        self.grants = grants
        self.presence = presence
        self.mute = mute
        self.isSpotlighted = isSpotlighted
        self.ladders = ladders
    }
}

/// Who is in the room.
///
/// There is deliberately no way to insert anything but a ``Participant``, and
/// ``count`` is what the product means by "participants" — the same number the
/// meter uses, drawn from the same place, so the invoice and the roster cannot
/// disagree.
public struct Roster: Hashable, Sendable {
    private var storage: [ParticipantIdentity: Participant]

    public init() { storage = [:] }

    /// Build from announcements under a prefix.
    ///
    /// Announcements that do not resolve to a participant slot are dropped
    /// rather than reported: a relay is entitled to announce namespaces this
    /// client does not model, and treating that as an error would make every
    /// future protocol addition a breaking change.
    public init(announcements: [TrackNamespace], under prefix: TrackNamespace) {
        storage = [:]
        for namespace in announcements {
            guard let slot = ParticipantSlot(announced: namespace, under: prefix) else { continue }
            storage[slot.identity] = Participant(slot: slot)
        }
    }

    /// Everyone, ordered by username then device so a grid does not reshuffle
    /// on every dictionary rehash.
    public var participants: [Participant] {
        storage.values.sorted {
            ($0.username.value, $0.device.value) < ($1.username.value, $1.device.value)
        }
    }

    /// The number the product means, and the number the meter bills.
    public var count: Int { storage.count }

    /// Distinct users, which is usually what a UI wants to show — one person on
    /// a phone and an iPad is one person.
    public var distinctUsers: Int { Set(storage.keys.map(\.username)).count }

    public subscript(identity: ParticipantIdentity) -> Participant? {
        get { storage[identity] }
        set { storage[identity] = newValue }
    }

    /// Every device a user is present on.
    public func devices(of username: Username) -> [Participant] {
        participants.filter { $0.username == username }
    }

    public mutating func insert(_ participant: Participant) {
        storage[participant.id] = participant
    }

    @discardableResult
    public mutating func remove(_ identity: ParticipantIdentity) -> Participant? {
        storage.removeValue(forKey: identity)
    }

    /// Apply an announcement event.
    public mutating func apply(_ event: AnnouncementEvent, under prefix: TrackNamespace) {
        switch event {
        case let .announced(namespace):
            guard let slot = ParticipantSlot(announced: namespace, under: prefix) else { return }
            if storage[slot.identity] == nil {
                storage[slot.identity] = Participant(slot: slot)
            }
        case let .withdrawn(namespace):
            guard let slot = ParticipantSlot(announced: namespace, under: prefix) else { return }
            storage.removeValue(forKey: slot.identity)
        }
    }
}
