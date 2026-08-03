// What the relay will not let this device publish.
//
// The one thing a relay says to a participant that the participant did not ask
// about. Everything else a client learns arrives because it subscribed —
// the roster from a prefix, the room's state from the control track, a peer's
// media from a subscription — and none of that reaches somebody who is only
// publishing. A moderator muting a host is precisely that case, so this comes
// the other way: the relay opens a PUBLISH for a track under the participant's
// own slot and writes one object to it.
//
// It is a claim about enforcement and not a request. The relay has already
// stopped forwarding by the time this arrives; what the client does with it is
// turn the hardware off, which is the part the relay cannot do and the part the
// user can see.

import Foundation
import MoqomCore

/// What a moderator has stopped for one participant.
///
/// Absolute rather than a delta, and it always carries both scopes. A client
/// that receives one of these knows the whole of its position, so a lost object
/// costs a moment of staleness rather than a permanent disagreement about what
/// is muted.
public struct ParticipantPolicy: Hashable, Sendable, Codable {
    /// The reserved track a relay publishes this on, under the participant's
    /// own namespace — the same shape as `.catalog` and `.control`.
    public static let trackName = ".policy"

    /// Bumped if the shape changes. A client that does not recognise a version
    /// keeps the mute it already has rather than deciding it has been lifted.
    public var version: Int

    /// Media nobody receives, whatever the participant's client does. This is
    /// what stops the camera: the relay has already stopped forwarding it.
    public var mutedForEveryone: MediaKind

    /// Media the audience does not receive, while hosts and cohosts still do.
    ///
    /// Deliberately does not stop capture. The media is still being sent, still
    /// being watched by the people running the room, and a client that closed
    /// the camera for it would take the participant off the hosts' screens too.
    public var mutedForAudience: MediaKind

    public init(
        version: Int = 1,
        mutedForEveryone: MediaKind = [],
        mutedForAudience: MediaKind = []
    ) {
        self.version = version
        self.mutedForEveryone = mutedForEveryone
        self.mutedForAudience = mutedForAudience
    }

    /// Whether anything is being held down at all.
    public var isEmpty: Bool { mutedForEveryone.isEmpty && mutedForAudience.isEmpty }

    private enum CodingKeys: String, CodingKey {
        case version
        case mutedForEveryone
        case mutedForAudience
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        // The bit values are shared with the relay's `media::Kinds` and Go's
        // `control.MediaKind`, so a mute crosses three languages as a number
        // and not as a translation. Unknown bits are kept rather than masked:
        // this build cannot act on a kind it has no name for, and dropping the
        // bit would report a narrower mute than is being enforced.
        mutedForEveryone = MediaKind(
            rawValue: try container.decodeIfPresent(Int.self, forKey: .mutedForEveryone) ?? 0
        )
        mutedForAudience = MediaKind(
            rawValue: try container.decodeIfPresent(Int.self, forKey: .mutedForAudience) ?? 0
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(mutedForEveryone.rawValue, forKey: .mutedForEveryone)
        try container.encode(mutedForAudience.rawValue, forKey: .mutedForAudience)
    }

    public static func decode(_ payload: Data) throws -> ParticipantPolicy {
        try JSONDecoder().decode(ParticipantPolicy.self, from: payload)
    }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }
}
