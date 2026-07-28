// One snapshot of everything measurable about a room.
//
// The SDK already measured almost all of this. What it did not have was a way to
// ask: link statistics were on `RoomSession`, publishing statistics were on the
// `Broadcast` handle that `startBroadcast` happened to return, per-participant
// receive statistics were two different accessors with different shapes, and
// decryption statistics were an `async` tuple. An application wanting to draw a
// diagnostics panel had to hold four objects and know which of them was where.
//
// So this is one type, reachable from one place, sampled at one instant. That
// matters beyond convenience: numbers gathered a few hundred milliseconds apart
// do not describe the same moment, and the whole use for them is comparing them
// to each other — "the link says 3 Mbps and the encoder is sending 6" is a
// diagnosis, and it is only sound if both were read together.
//
// # What is not here, and why
//
// Round-trip time. It is the number everyone asks for first, and the client
// genuinely does not have it: `Network.framework` does not surface a QUIC RTT
// estimate, so there is nothing to read. Rather than invent one, the client
// reports ``LinkStatistics/delayTrend`` — the one-way delay gradient, which is
// the part of RTT that congestion control actually uses — and the *relay*
// measures true RTT per connection, where the QUIC state machine is in reach.
// Pairing a client snapshot with the relay's view of the same session is the
// intended way to answer "was it them or the network", and
// ``ConnectionQuality/from(link:loss:)`` is written against the signals that do
// exist rather than the ones that would be nicer.

import Foundation
import MoqomCore

/// How good a connection looks, as a small ordered set.
///
/// Five levels, not a percentage. A percentage invites an application to render
/// a precise number that is not precise, and invites us to pretend the mapping
/// from loss and delay to a score is more principled than it is. Five buckets is
/// what a signal-strength indicator can show and what a support agent can act on.
public enum ConnectionQuality: Int, Comparable, Sendable, CaseIterable, Codable {
    /// Nothing has been measured yet. Distinct from ``bad``: a room that has
    /// just been joined has no evidence, and showing a red indicator for it
    /// would be a lie in the direction that loses trust fastest.
    case unknown = 0
    /// Unusable, or nearly.
    case bad = 1
    /// Working, visibly degraded.
    case poor = 2
    /// Working, with headroom to spare.
    case good = 3
    /// Nothing to report.
    case excellent = 4

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// A label suitable for a diagnostics panel.
    public var label: String {
        switch self {
        case .unknown: "unknown"
        case .bad: "bad"
        case .poor: "poor"
        case .good: "good"
        case .excellent: "excellent"
        }
    }

    /// Loss ratios that separate the buckets.
    ///
    /// Chosen against what the media actually tolerates rather than against round
    /// numbers. Below 0.5% a codec's own concealment hides the damage. By 2% a
    /// viewer sees artefacts. By 8% keyframe intervals start being missed, which
    /// is when video stops recovering between glitches rather than merely
    /// glitching.
    public enum Thresholds {
        public static let excellent = 0.005
        public static let good = 0.02
        public static let poor = 0.08
    }

    /// Derive quality from what the client can actually observe.
    ///
    /// Loss dominates, because loss is what a viewer sees. The bandwidth state
    /// can only *lower* the result, and only by one level: a controller that has
    /// decided to back off is evidence a queue is building, but a link that is
    /// backing off and losing nothing is a link that is working — the backoff is
    /// the mechanism working, not a fault. Letting it drive the indicator on its
    /// own would show a warning during every normal probe cycle, and an
    /// indicator that cries wolf is one that gets ignored on the day it is right.
    public static func from(link: LinkStatistics, loss: Double? = nil) -> Self {
        let observed = loss ?? link.lossRatio
        guard link.objectsReceived > 0 else { return .unknown }

        let base: Self =
            switch observed {
            case ..<Thresholds.excellent: .excellent
            case ..<Thresholds.good: .good
            case ..<Thresholds.poor: .poor
            default: .bad
            }

        // A rising queue costs one level, floored at `poor` — a link delivering
        // everything is not `bad` however hard the controller is working.
        if link.state == .decreasing || link.delayTrend > 20 {
            return Self(rawValue: max(base.rawValue - 1, Self.poor.rawValue)) ?? base
        }
        return base
    }
}

extension LinkStatistics {
    /// Objects lost as a fraction of those expected.
    ///
    /// Zero when nothing has arrived, rather than undefined: a room with no
    /// traffic has not lost anything.
    public var lossRatio: Double {
        let expected = objectsReceived + objectsLost
        guard expected > 0 else { return 0 }
        return Double(objectsLost) / Double(expected)
    }
}

/// What reassembly has seen for one participant's video.
///
/// Replaces the tuple that `depacketiserStatistics(for:)` used to return. A tuple
/// with three `Int` members is three chances to read the wrong one at the call
/// site, and it cannot grow a field without breaking every caller.
public struct VideoReceiveStatistics: Hashable, Sendable {
    /// Frames handed to a decoder.
    public var framesProduced: Int = 0

    /// Objects that never arrived, inferred from gaps in object IDs.
    public var objectsLost: Int = 0

    /// Objects discarded because no keyframe had been seen yet.
    ///
    /// High and not falling means a publisher whose keyframe interval is longer
    /// than this viewer is willing to wait, which looks like a black tile and is
    /// not a network problem.
    public var objectsAwaitingKeyFrame: Int = 0

    public init(
        framesProduced: Int = 0,
        objectsLost: Int = 0,
        objectsAwaitingKeyFrame: Int = 0
    ) {
        self.framesProduced = framesProduced
        self.objectsLost = objectsLost
        self.objectsAwaitingKeyFrame = objectsAwaitingKeyFrame
    }
}

/// How decryption is going.
public struct DecryptionStatistics: Hashable, Sendable {
    public var objectsDecrypted: Int = 0

    /// Objects that failed authentication.
    ///
    /// Any non-zero value deserves attention: under a working key schedule this
    /// stays at zero, so it is either a key-rotation bug or somebody tampering.
    public var objectsRejected: Int = 0

    /// Objects held because their key had not arrived.
    public var objectsAwaitingKey: Int = 0

    public init(
        objectsDecrypted: Int = 0,
        objectsRejected: Int = 0,
        objectsAwaitingKey: Int = 0
    ) {
        self.objectsDecrypted = objectsDecrypted
        self.objectsRejected = objectsRejected
        self.objectsAwaitingKey = objectsAwaitingKey
    }
}

/// What this device is sending.
public struct PublishingStatistics: Hashable, Sendable {
    /// `nil` when not broadcasting video.
    public var video: BroadcastStatistics?

    /// `nil` when not publishing audio.
    public var audio: AudioPublicationStatistics?

    public init(
        video: BroadcastStatistics? = nil,
        audio: AudioPublicationStatistics? = nil
    ) {
        self.video = video
        self.audio = audio
    }

    /// Whether anything is being published at all.
    public var isPublishing: Bool { video != nil || audio != nil }

    /// Frames dropped as a fraction of those submitted.
    ///
    /// The uplink's counterpart to ``LinkStatistics/lossRatio``: this is the
    /// number that says a broadcast is degraded before it left the device, which
    /// no amount of network measurement would reveal.
    public var encodeDropRatio: Double {
        guard let video, video.framesSubmitted > 0 else { return 0 }
        return Double(video.framesDropped) / Double(video.framesSubmitted)
    }
}

/// Everything known about one remote participant.
public struct ParticipantStatistics: Hashable, Sendable, Identifiable {
    public let identity: ParticipantIdentity
    public var id: ParticipantIdentity { identity }

    /// Where they are, from the room control track.
    public var presence: Presence

    /// Whether they are speaking right now.
    public var isSpeaking: Bool

    /// Which rung of their ladder this viewer is subscribed at.
    ///
    /// `nil` when not subscribed to their video — which is the normal state for
    /// somebody in the overflow of a large room, and is why a missing value here
    /// is not a fault.
    public var layer: LayerID?

    /// `nil` when not receiving their video.
    public var video: VideoReceiveStatistics?

    /// `nil` when not receiving their audio, including when this viewer has
    /// muted them locally — in which case the bytes are genuinely not arriving.
    public var audio: JitterBufferStatistics?

    /// How their stream is arriving here.
    ///
    /// A per-participant value and not a room-wide one, because in a relayed
    /// room the answer differs per publisher: one cohost on a train degrades
    /// their own tile and nobody else's.
    public var quality: ConnectionQuality

    /// How long since anything of theirs arrived, or `nil` if nothing ever has.
    ///
    /// The failure no transport timeout can see. A publisher whose camera has
    /// frozen, whose encoder has wedged, or who has been dropped by the relay
    /// without their connection noticing still has a healthy QUIC session:
    /// ACKs flow, nothing times out, and their tile is a still image. The only
    /// evidence is that the objects stopped, which is what this measures.
    ///
    /// It is also much faster than the alternatives. Media arrives tens of
    /// times a second, so a gap is obvious within a frame or two — where a
    /// connection-level timeout has to wait out its whole idle period before
    /// concluding anything, and an application heartbeat could do no better
    /// than the interval it was configured with.
    ///
    /// Growing on its own is normal for somebody who is not sending: a
    /// participant with their camera and microphone muted is silent by
    /// definition. Read it against ``Participant/mute`` before treating it as a
    /// fault, and see ``isStalled(after:)``.
    public var silentFor: Duration?

    /// Whether their media has been absent long enough to be worth showing.
    ///
    /// - Parameter after: how much silence counts. A couple of hundred
    ///   milliseconds is a hiccup at any frame rate; the default is
    ///   deliberately several frames' worth, so a single late group does not
    ///   flicker an indicator on and off.
    public func isStalled(after threshold: Duration = .seconds(2)) -> Bool {
        guard let silentFor else { return false }
        return silentFor > threshold
    }

    public init(
        identity: ParticipantIdentity,
        presence: Presence = .connected,
        isSpeaking: Bool = false,
        layer: LayerID? = nil,
        video: VideoReceiveStatistics? = nil,
        audio: JitterBufferStatistics? = nil,
        quality: ConnectionQuality = .unknown,
        silentFor: Duration? = nil
    ) {
        self.identity = identity
        self.presence = presence
        self.isSpeaking = isSpeaking
        self.layer = layer
        self.video = video
        self.audio = audio
        self.quality = quality
        self.silentFor = silentFor
    }

    /// Audio packets lost or discarded as a fraction of those expected.
    public var audioLossRatio: Double {
        guard let audio else { return 0 }
        let expected = audio.packetsReceived + audio.gaps
        guard expected > 0 else { return 0 }
        return Double(audio.gaps + audio.packetsLate) / Double(expected)
    }
}

/// A room, measured, at one instant.
public struct RoomStatistics: Hashable, Sendable {
    /// When this was taken, on the session's monotonic clock.
    public let capturedAt: MonotonicTime

    public let room: RoomID
    public let identity: ParticipantIdentity

    /// How long the room has been joined.
    public let uptime: Duration

    /// Where the room is in its lifecycle.
    public let lifecycle: RoomLifecycle

    /// How many participants are on the roster, watchdogs excluded.
    public let participantCount: Int

    /// What the downlink looks like, across every subscription.
    public let link: LinkStatistics

    /// What this device is sending.
    public let publishing: PublishingStatistics

    /// Every remote participant, keyed by identity.
    public let participants: [ParticipantIdentity: ParticipantStatistics]

    /// `nil` when the room is not end-to-end encrypted.
    public let decryption: DecryptionStatistics?

    /// How far the room control track has been read, and whether it is intact.
    public let control: ControlStatistics

    /// This device's own connection quality.
    ///
    /// Derived from the downlink and from how much the encoder is dropping, so a
    /// broadcaster whose uplink is failing sees it here even though every
    /// participant tile looks fine.
    public let quality: ConnectionQuality

    public init(
        capturedAt: MonotonicTime,
        room: RoomID,
        identity: ParticipantIdentity,
        uptime: Duration,
        lifecycle: RoomLifecycle,
        participantCount: Int,
        link: LinkStatistics,
        publishing: PublishingStatistics,
        participants: [ParticipantIdentity: ParticipantStatistics],
        decryption: DecryptionStatistics?,
        control: ControlStatistics,
        quality: ConnectionQuality
    ) {
        self.capturedAt = capturedAt
        self.room = room
        self.identity = identity
        self.uptime = uptime
        self.lifecycle = lifecycle
        self.participantCount = participantCount
        self.link = link
        self.publishing = publishing
        self.participants = participants
        self.decryption = decryption
        self.control = control
        self.quality = quality
    }

    /// Participants whose stream is arriving badly enough to mention.
    ///
    /// What a host's "somebody is having trouble" indicator is built from.
    public var struggling: [ParticipantStatistics] {
        participants.values
            .filter { $0.quality != .unknown && $0.quality <= .poor }
            .sorted { $0.identity.username.value < $1.identity.username.value }
    }

    /// The worst quality anybody in the room is experiencing, this device
    /// included.
    public var worstQuality: ConnectionQuality {
        let measured = ([quality] + participants.values.map(\.quality))
            .filter { $0 != .unknown }
        return measured.min() ?? .unknown
    }

    /// The snapshot as log fields.
    ///
    /// Carries no payloads and no keys, because ``MoqomCore/LogValue`` has no
    /// case that could hold one.
    public var fields: [LogField] {
        [
            LogField("room", .text(room.value)),
            LogField("quality", .text(quality.label)),
            LogField("participants", .number(participantCount)),
            LogField("estimate_bps", .number(link.estimate)),
            LogField("received_bps", .number(link.received)),
            LogField("loss", .decimal(link.lossRatio)),
            LogField("delay_trend", .decimal(link.delayTrend)),
            LogField("control_sequence", .number(Int(control.sequence))),
        ]
    }
}

/// How the room control track is being read.
///
/// Worth reporting because a room whose control track has a gap is a room where
/// grants and mute states may be stale, and that presents as a permissions bug
/// rather than as a network one.
public struct ControlStatistics: Hashable, Sendable {
    /// The highest sequence applied with no hole beneath it. `0` before anything.
    public var sequence: UInt64 = 0

    /// Whether a complete state has ever been seen.
    ///
    /// A reader that has only seen changes knows some fields and does not know
    /// the room, which is different from knowing an empty room.
    public var isFounded: Bool = false

    /// Entries accepted.
    public var accepted: Int = 0

    /// Entries already seen and ignored, which reconnection makes normal — so a
    /// non-zero value here is health rather than a fault.
    public var duplicates: Int = 0

    /// Entries refused for being a version this build cannot read.
    ///
    /// Non-zero means a peer or relay is newer than this client, which is worth
    /// knowing before concluding that a missing grant is a bug.
    public var rejected: Int = 0

    /// Entries this build read past because their kind is unknown to it.
    ///
    /// The benign half of the same signal ``rejected`` carries: the authority is
    /// publishing something newer, and this reader is nonetheless current on
    /// everything it does understand. Worth reporting from a fleet, because it is
    /// how a rollout that has outrun its clients becomes visible before somebody
    /// files a bug about a feature that appears not to work.
    public var unrecognised: Int = 0

    /// Whether a snapshot is wanted.
    ///
    /// True from joining until the first one arrives, as well as when a hole
    /// opens later — the reader wants a snapshot in both cases, which is what
    /// makes this the right trigger for a repair and the wrong thing to show a
    /// person. Use ``hasGap`` for that.
    public var needsSnapshot: Bool = false

    /// Whether entries were dropped because the reorder buffer filled.
    public var isTruncated: Bool = false

    /// Whether this session is the authority publishing the track.
    public var isAuthority: Bool = false

    /// Whether the log has a hole in it, as opposed to not having started.
    ///
    /// The figure worth surfacing. A client that has just joined and not yet
    /// received its first snapshot wants one, but nothing is wrong with it, and
    /// showing a warning for the first few hundred milliseconds of every room
    /// would train people to ignore the warning.
    public var hasGap: Bool { isFounded && needsSnapshot }

    public init(
        sequence: UInt64 = 0,
        isFounded: Bool = false,
        accepted: Int = 0,
        duplicates: Int = 0,
        rejected: Int = 0,
        unrecognised: Int = 0,
        needsSnapshot: Bool = false,
        isTruncated: Bool = false,
        isAuthority: Bool = false
    ) {
        self.sequence = sequence
        self.isFounded = isFounded
        self.accepted = accepted
        self.duplicates = duplicates
        self.rejected = rejected
        self.unrecognised = unrecognised
        self.needsSnapshot = needsSnapshot
        self.isTruncated = isTruncated
        self.isAuthority = isAuthority
    }
}
