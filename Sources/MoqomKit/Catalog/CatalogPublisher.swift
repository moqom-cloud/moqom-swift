// Publishing and reading the catalog track.
//
// The publisher side is small but has one rule that is easy to get wrong: the
// catalog must be published *before* the media it describes, and republished
// whenever it changes. A viewer that receives a frame for a track the catalog
// does not mention has no way to build a decoder for it, and the failure looks
// like a codec problem rather than an ordering problem.
//
// The subscriber side keeps the latest version and nothing else. Older versions
// are not history worth having: a catalog describes what is being published
// now, and a viewer holding a stale one subscribes to tracks that stopped.

import Foundation
import MoqomCore

/// Publishes a catalog on a publisher's `.catalog` track.
public actor CatalogPublisher {
    private let writer: any TrackWriter

    /// What was last published, which is what this device is offering.
    ///
    /// Readable so a session can answer "what is my own catalog" without
    /// subscribing to its own track and waiting for the relay to hand back what
    /// it just sent.
    public private(set) var current: Catalog?

    private var group: UInt64 = 0

    /// Priority for the catalog track.
    ///
    /// Above all media. It is a few hundred bytes and nothing can be decoded
    /// without it, so spending scheduler urgency here costs nothing and
    /// shedding it would stall a joiner completely.
    public static let priority: UInt8 = 8

    public init(writer: any TrackWriter) {
        self.writer = writer
    }

    /// What is currently published.
    public var published: Catalog? { current }

    /// Publish a version, unless it is the one already out there.
    ///
    /// - Returns: Whether anything was sent.
    @discardableResult
    public func publish(_ catalog: Catalog) async throws(MoqomError) -> Bool {
        if let current, current == catalog { return false }

        let payload: Data
        do {
            payload = try catalog.encoded()
        } catch {
            throw MoqomError.invalidState(expected: "encodable catalog", actual: "\(error)")
        }

        // Every version in its own group, because a group is where a subscriber
        // can join. A late viewer therefore gets a whole current catalog rather
        // than an object from the middle of one.
        try await writer.startGroup(group)
        try await writer.write(
            TrackObject(
                group: group,
                object: 0,
                priority: Self.priority,
                payload: payload,
                isKeyFrame: true
            )
        )
        group += 1
        current = catalog
        return true
    }

    public func finish() async {
        await writer.finish()
    }
}

/// Reassembles catalogs from a track's objects.
///
/// Separate from the publisher because the two are used by different people at
/// different times, and because this one has to be tolerant: a version it
/// cannot parse must not stop it from applying the next one.
public actor CatalogReader {
    public private(set) var current: Catalog?
    public private(set) var versionsApplied = 0
    public private(set) var versionsRejected = 0

    private let stream: AsyncStream<Catalog>
    private let continuation: AsyncStream<Catalog>.Continuation

    public init() {
        (stream, continuation) = AsyncStream.makeStream(
            of: Catalog.self,
            bufferingPolicy: .bufferingNewest(4)
        )
    }

    deinit { continuation.finish() }

    /// Each new version as it arrives.
    public nonisolated var updates: AsyncStream<Catalog> { stream }

    /// Apply one object from the catalog track.
    @discardableResult
    public func apply(_ object: TrackObject) -> Catalog? {
        do {
            let catalog = try Catalog.decode(object.payload)
            current = catalog
            versionsApplied += 1
            continuation.yield(catalog)
            return catalog
        } catch {
            // A malformed or too-new version leaves the previous one in place.
            // Dropping the catalog entirely would take down media that is still
            // arriving and still decodable.
            versionsRejected += 1
            return nil
        }
    }

    /// Consume a catalog track until it ends.
    public func consume(_ objects: AsyncStream<TrackObject>) async {
        for await object in objects {
            apply(object)
        }
    }
}

public extension Catalog {
    /// Describe what a broadcast configuration will publish.
    ///
    /// Built from the ladder plus whatever decoder configurations the encoders
    /// have produced so far. Rungs that have not yet encoded a keyframe appear
    /// without one rather than being omitted: a viewer needs to know the track
    /// exists in order to subscribe to it, and the configuration follows in the
    /// next version.
    static func describing(
        _ configuration: BroadcastConfiguration,
        decoderConfigurations: [LayerID: Data] = [:],
        audio: AudioPublicationConfiguration? = nil,
        keyID: UInt64? = nil,
        muted: MediaKind = []
    ) -> Catalog {
        var tracks: [CatalogTrack] = configuration.ladder.rungs.enumerated().map { index, rung in
            CatalogTrack(
                name: rung.id.value,
                kind: .video,
                codec: "video/\(configuration.codec.rawValue)",
                decoderConfiguration: decoderConfigurations[rung.id]?.hexadecimal,
                width: rung.size.width,
                height: rung.size.height,
                frameRate: rung.frameRate,
                bitrate: rung.bitrate,
                rung: index,
                isPrimary: index == configuration.ladder.rungs.count - 1
            )
        }

        if let audio {
            tracks.append(
                CatalogTrack(
                    name: "audio",
                    kind: .audio,
                    codec: "audio/\(audio.encoder.codec.rawValue)",
                    bitrate: audio.encoder.bitrate,
                    sampleRate: audio.encoder.format.sampleRate,
                    channels: audio.encoder.format.channels
                )
            )
        }

        return Catalog(keyID: keyID, muted: muted, tracks: tracks)
    }
}

extension Data {
    var hexadecimal: String {
        map { String(format: "%02x", $0) }.joined()
    }

    init?(hexadecimal: String) {
        guard hexadecimal.count.isMultiple(of: 2) else { return nil }
        var bytes = Data(capacity: hexadecimal.count / 2)
        var index = hexadecimal.startIndex
        while index < hexadecimal.endIndex {
            let next = hexadecimal.index(index, offsetBy: 2)
            guard let byte = UInt8(hexadecimal[index ..< next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = bytes
    }
}
