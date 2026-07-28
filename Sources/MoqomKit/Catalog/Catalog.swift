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

    public static let currentVersion = 1

    public init(version: Int = Catalog.currentVersion, keyID: UInt64? = nil, tracks: [CatalogTrack]) {
        self.version = version
        self.keyID = keyID
        self.tracks = tracks
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
