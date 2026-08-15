// The catalog: what a publisher is offering.
//
// Without this, a subscriber has to be told out of band what tracks exist, what
// resolutions they carry, and how to configure a decoder for them — which means
// the application has a second signalling channel to build, keep consistent,
// and secure. The whole point of a MoQ deployment is that the relay carries
// everything, so the description of the media travels the same way the media
// does: as a track.
//
// Three decisions worth stating.
//
// It is a track, not a control message. That means it is relayed, cached, and
// subscribable by prefix like anything else, a late joiner gets the current
// version without asking anyone, and the relay needs no special support.
//
// Each version is a whole document rather than a delta. Deltas would be smaller
// and would introduce the problem of a subscriber that joined at the wrong
// moment holding a catalog that never becomes correct. A catalog is a few
// hundred bytes and changes when someone starts or stops a track, so the
// bandwidth argument does not exist and the correctness argument decides it.
//
// Every version goes in its own group. A group is where a subscriber can join,
// so this is what lets a new viewer receive the current catalog immediately
// rather than waiting for the next change.
//
// It is JSON. Not because JSON is good on a wire, but because this is the one
// place where a third party has to be able to read our bytes without our code —
// a debugging proxy, a recorder someone else wrote, a relay operator diagnosing
// a customer. The whole document is smaller than one video frame.

import Foundation
import MoqomCore

/// What one track carries.
public struct CatalogTrack: Hashable, Sendable, Codable {
    /// The track's name within the publisher's namespace.
    public let name: String

    public let kind: Kind

    public enum Kind: String, Hashable, Sendable, Codable {
        case video
        case audio

        /// A screen or window share.
        ///
        /// Distinct from `video` because a viewer should lay it out differently
        /// and because the layer-selection rules differ: legibility beats frame
        /// rate for a screen share, and the reverse for a face.
        case screen

        /// Anything the SDK does not interpret.
        case data
    }

    /// The codec, as a MIME-style identifier: `video/hevc`, `audio/opus`.
    public let codec: String

    /// Decoder configuration, hex encoded.
    ///
    /// Parameter sets for video, the identification header for Opus. Out of
    /// band precisely so that a viewer joining at an arbitrary group can build
    /// a decoder without waiting for the next keyframe to carry them inline.
    public let decoderConfiguration: String?

    /// Pixels, for a video or screen track.
    public let width: Int?
    public let height: Int?
    public let frameRate: Double?

    /// Target bits per second.
    public let bitrate: Int?

    public let sampleRate: Int?
    public let channels: Int?

    /// Where this sits in the ladder. `0` is the cheapest rung.
    ///
    /// Explicit rather than inferred from resolution, because a screen share
    /// ladder varies frame rate at a fixed resolution and would otherwise look
    /// like several copies of one rung.
    public let rung: Int?

    /// Whether the publisher considers this their main track.
    public let isPrimary: Bool

    /// The codec, where it is one this build can decode.
    ///
    /// `nil` rather than a default for anything unrecognised: a viewer that
    /// guessed HEVC for an AV1 track would build a format description that
    /// fails somewhere inside VideoToolbox instead of declining the track.
    public var videoCodec: VideoCodec? {
        guard let slash = codec.firstIndex(of: "/") else { return VideoCodec(rawValue: codec) }
        return VideoCodec(rawValue: String(codec[codec.index(after: slash)...]))
    }

    /// The audio codec, on the same terms.
    public var audioCodec: AudioCodec? {
        guard let slash = codec.firstIndex(of: "/") else { return AudioCodec(rawValue: codec) }
        return AudioCodec(rawValue: String(codec[codec.index(after: slash)...]))
    }

    public init(
        name: String,
        kind: Kind,
        codec: String,
        decoderConfiguration: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        frameRate: Double? = nil,
        bitrate: Int? = nil,
        sampleRate: Int? = nil,
        channels: Int? = nil,
        rung: Int? = nil,
        isPrimary: Bool = false
    ) {
        self.name = name
        self.kind = kind
        self.codec = codec
        self.decoderConfiguration = decoderConfiguration
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.bitrate = bitrate
        self.sampleRate = sampleRate
        self.channels = channels
        self.rung = rung
        self.isPrimary = isPrimary
    }
}

/// Everything one publisher is offering.
public struct Catalog: Hashable, Sendable, Codable {
    /// Format version, so an old client can refuse a document it would
    /// misread rather than guessing at it.
    public let version: Int

    /// Which SFrame key ID protects this publisher's media, if any.
    ///
    /// Advertised rather than kept private because it is not secret — the KID
    /// travels in every frame header anyway — and because a receiver needs to
    /// know whether to expect ciphertext before the first frame arrives.
    public let keyID: UInt64?

    public let tracks: [CatalogTrack]

    /// What the publisher has muted on themselves.
    ///
    /// Here rather than on the room's control track because that track is
    /// written by the authority — a participant's token cannot publish under
    /// the room prefix, and it should not be able to, since the same channel
    /// carries moderator decisions. The catalog is the one document a
    /// participant authors about themselves, everyone already subscribes to it,
    /// and it is already versioned and grouped so a late joiner reads the
    /// current value without asking.
    ///
    /// Deliberately not the same thing as the track being absent. A muted track
    /// is still offered and still subscribed to; what stops is the bytes. That
    /// distinction is what makes unmuting instant — the subscription is still
    /// open, so there is nothing to renegotiate — and it is also what lets a
    /// viewer draw "camera off" rather than a frozen last frame, because the
    /// difference between muted and merely stalled is stated rather than
    /// inferred from a timeout.
    ///
    /// A publisher saying this about themselves is a claim, not an enforcement.
    /// A modified client can say `.audio` and keep sending; the mute that
    /// cannot be lied about is ``MuteState/forcedForEveryone``, which the relay
    /// applies. This is the one a participant chooses, and it is trusted for
    /// the same reason a participant is trusted to stop talking.
    public let muted: MediaKind

    /// What the publisher's hardware has stopped producing, against their will.
    ///
    /// Beside ``muted`` rather than folded into it, because the two are the same
    /// silence for opposite reasons and a viewer should not be told the wrong
    /// one. A phone that goes into Picture in Picture, takes a call, or sits
    /// beside a second app in the foreground has its camera taken away by the
    /// operating system while the session, the subscription and the audio all
    /// carry on. Measured on two phones: 104 seconds of a frozen tile with
    /// nothing on either screen to say why, and the publisher's own counters
    /// reporting it the whole time.
    ///
    /// Detected from the absence of frames — the only signal a capture stall
    /// has — but detected *by the publisher*, about its own capture, which is
    /// the difference that matters. A receiver inferring this from a timeout
    /// would be guessing across a network that has its own reasons for a gap;
    /// a publisher knows it is not muted and knows nothing has arrived from its
    /// own camera, and that is a fact rather than an inference.
    public let interrupted: MediaKind

    /// The language this publisher is speaking, as a BCP 47 tag.
    ///
    /// On the catalog for the same reason ``muted`` is: this is the one
    /// document a participant authors about themselves, everyone already
    /// subscribes to it, and a late joiner reads the current value without
    /// asking. It is also the document a relay is allowed to read — catalogs
    /// are never encrypted — so the control plane learns the same tag the
    /// other clients do, without a second channel.
    ///
    /// Optional, and absent from catalogs published before this field existed.
    /// Those are not malformed; they are a publisher who has not said.
    public let locale: String?

    /// Other publishers this catalog's audience should also receive.
    ///
    /// Each entry is a full participant namespace. The publisher uploads once,
    /// under their own name; anyone watching this catalog follows the
    /// reference. That is how two lives share an audience without a second
    /// uplink, and how a guest appears on a personal channel that has no
    /// room roster.
    ///
    /// Absent from catalogs published before this field existed.
    public let references: [TrackNamespace]

    /// Stage handshakes this publisher has in flight.
    ///
    /// On the catalog rather than the room control log because a handshake has
    /// a deadline and must not be replayed from a snapshot. A late joiner
    /// reads whatever is still pending.
    public let invitations: [StageInvitationRecord]

    public static let currentVersion = 1

    public init(
        version: Int = Catalog.currentVersion,
        keyID: UInt64? = nil,
        muted: MediaKind = [],
        interrupted: MediaKind = [],
        locale: String? = nil,
        references: [TrackNamespace] = [],
        invitations: [StageInvitationRecord] = [],
        tracks: [CatalogTrack]
    ) {
        self.version = version
        self.keyID = keyID
        self.muted = muted
        self.interrupted = interrupted
        self.locale = locale
        self.references = references
        self.invitations = invitations
        self.tracks = tracks
    }

    // Hand-written so that `muted` may be absent. A catalog published by a
    // build from before this field existed is not malformed, it is a publisher
    // who has muted nothing, and refusing to decode it would take the whole
    // participant off the stage over a missing key. The same now goes for
    // `interrupted`, which an older publisher never sends and whose absence
    // means a camera nobody has taken away, and for `locale`, which an older
    // publisher never sends and whose absence means they have not said.
    private enum CodingKeys: String, CodingKey {
        case version, keyID, muted, interrupted, locale, references, invitations, tracks
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        keyID = try container.decodeIfPresent(UInt64.self, forKey: .keyID)
        muted = try container.decodeIfPresent(MediaKind.self, forKey: .muted) ?? []
        interrupted = try container.decodeIfPresent(MediaKind.self, forKey: .interrupted) ?? []
        locale = try container.decodeIfPresent(String.self, forKey: .locale)
        references = try container.decodeIfPresent([TrackNamespace].self, forKey: .references) ?? []
        invitations = try container.decodeIfPresent(
            [StageInvitationRecord].self, forKey: .invitations
        ) ?? []
        tracks = try container.decode([CatalogTrack].self, forKey: .tracks)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encodeIfPresent(keyID, forKey: .keyID)
        try container.encode(muted, forKey: .muted)
        try container.encode(interrupted, forKey: .interrupted)
        try container.encodeIfPresent(locale, forKey: .locale)
        if !references.isEmpty { try container.encode(references, forKey: .references) }
        if !invitations.isEmpty { try container.encode(invitations, forKey: .invitations) }
        try container.encode(tracks, forKey: .tracks)
    }

    /// The video rungs, cheapest first.
    public var videoLadder: LayerLadder {
        let rungs = tracks
            .filter { ($0.kind == .video || $0.kind == .screen) && $0.width != nil }
            .sorted { ($0.rung ?? 0, $0.width ?? 0) < ($1.rung ?? 0, $1.width ?? 0) }
            .compactMap { track -> VideoLayer? in
                guard let width = track.width, let height = track.height else { return nil }
                return VideoLayer(
                    id: LayerID(track.name),
                    size: PixelSize(width: width, height: height),
                    frameRate: track.frameRate ?? 30,
                    bitrate: track.bitrate ?? 0
                )
            }
        return LayerLadder(rungs: rungs)
    }

    public var audioTrack: CatalogTrack? {
        tracks.first { $0.kind == .audio }
    }

    public func track(named name: String) -> CatalogTrack? {
        tracks.first { $0.name == name }
    }

    // MARK: - Wire form

    /// Sorted keys, so the same catalog always produces the same bytes.
    ///
    /// Determinism is what lets a subscriber skip a version it has already
    /// applied by comparing bytes, and what makes a catalog diff in a bug
    /// report readable.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> Catalog {
        let catalog = try JSONDecoder().decode(Catalog.self, from: data)
        guard catalog.version <= Catalog.currentVersion else {
            throw CatalogError.unsupportedVersion(catalog.version)
        }
        return catalog
    }
}

public enum CatalogError: Error, Hashable, Sendable {
    /// A publisher is using a format this build does not understand.
    ///
    /// Refused rather than partially applied: a catalog read wrong produces a
    /// decoder configured wrong, which fails far from here and looks like a
    /// codec bug.
    case unsupportedVersion(Int)

    case malformed
}

public extension Catalog {
    /// The catalog track's name within a publisher's namespace.
    ///
    /// A leading marker so it can never collide with a media track named by an
    /// application, and short because it appears in every announcement.
    static let trackName = ".catalog"
}
