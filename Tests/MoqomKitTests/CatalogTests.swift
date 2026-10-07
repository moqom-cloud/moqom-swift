// The catalog: what a publisher offers, and how a viewer finds out.
//
// The end-to-end test at the bottom is the one that matters. Before the catalog
// existed, a viewer's layer ladder was `.defaultCamera()` — an assumption that
// happened to be right in the sample app and would be wrong for anyone
// publishing a different ladder. These tests pin the point at which the
// assumption is replaced by the publisher's own description.

import Foundation
import Testing

@testable import MoqomCore
@testable import MoqomKit
@testable import MoqomLoopback

@Suite("Catalog document")
struct CatalogDocumentTests {
    private let sample = Catalog(
        keyID: 7,
        tracks: [
            CatalogTrack(
                name: "video/360p",
                kind: .video,
                codec: "video/hevc",
                decoderConfiguration: "0001",
                width: 640,
                height: 360,
                frameRate: 30,
                bitrate: 600_000,
                rung: 0
            ),
            CatalogTrack(
                name: "video/720p",
                kind: .video,
                codec: "video/hevc",
                width: 1280,
                height: 720,
                frameRate: 30,
                bitrate: 2_000_000,
                rung: 1,
                isPrimary: true
            ),
            CatalogTrack(
                name: "audio",
                kind: .audio,
                codec: "audio/opus",
                bitrate: 24000,
                sampleRate: 48000,
                channels: 1
            ),
        ]
    )

    @Test("a catalog round-trips through its wire form")
    func roundTrip() throws {
        #expect(try Catalog.decode(sample.encoded()) == sample)
    }

    @Test("the same catalog always produces the same bytes")
    func encodingIsDeterministic() throws {
        // What lets a subscriber skip a version it has already applied by
        // comparing bytes, and what makes a catalog diff in a bug report
        // readable.
        #expect(try sample.encoded() == sample.encoded())
    }

    @Test("the video ladder comes out cheapest first, with audio left out of it")
    func ladderIsOrdered() {
        let ladder = sample.videoLadder
        #expect(ladder.rungs.map(\.id.value) == ["video/360p", "video/720p"])
        #expect(ladder.lowest?.size.width == 640)
        #expect(ladder.highest?.size.width == 1280)
        #expect(sample.audioTrack?.codec == "audio/opus")
    }

    @Test("a version from the future is refused rather than half-understood")
    func futureVersionIsRefused() throws {
        // Applying part of a document we do not understand produces a decoder
        // configured wrong, which fails far from here and looks like a codec
        // bug.
        let ahead = Catalog(version: Catalog.currentVersion + 1, tracks: [])
        let encoded = try JSONEncoder().encode(ahead)
        #expect(throws: CatalogError.self) {
            _ = try Catalog.decode(encoded)
        }
    }

    @Test("a description of a broadcast names every rung, configured or not")
    func describesABroadcast() {
        // A rung without a decoder configuration still has to appear: a viewer
        // needs to know the track exists in order to subscribe, and the
        // configuration follows in the next version.
        let configuration = BroadcastConfiguration(
            ladder: LayerLadder(rungs: [
                VideoLayer(
                    id: "video/180p",
                    size: PixelSize(width: 320, height: 180),
                    frameRate: 15,
                    bitrate: 150_000
                ),
                VideoLayer(
                    id: "video/720p",
                    size: PixelSize(width: 1280, height: 720),
                    frameRate: 30,
                    bitrate: 2_000_000
                ),
            ])
        )
        let catalog = Catalog.describing(
            configuration,
            decoderConfigurations: ["video/180p": Data([0xAB, 0xCD])],
            audio: AudioPublicationConfiguration(),
            keyID: 3
        )

        #expect(catalog.tracks.count == 3)
        #expect(catalog.track(named: "video/180p")?.decoderConfiguration == "abcd")
        #expect(catalog.track(named: "video/720p")?.decoderConfiguration == nil)
        #expect(catalog.track(named: "video/720p")?.isPrimary == true)
        #expect(catalog.audioTrack?.sampleRate == 48000)
        #expect(catalog.keyID == 3)
    }

    @Test("a locale round-trips, and an older catalog without one is not malformed")
    func localeIsOptional() throws {
        let spoken = Catalog(locale: "en-US", tracks: [])
        #expect(try Catalog.decode(spoken.encoded()).locale == "en-US")

        let older = try Catalog.decode(Data(#"{"tracks":[],"version":1}"#.utf8))
        #expect(older.locale == nil)
        #expect(older.muted == [])
        #expect(older.interrupted == [])
    }

    @Test("a description of a broadcast carries the locale it was given")
    func describingCarriesLocale() {
        let catalog = Catalog.describing(
            BroadcastConfiguration(ladder: LayerLadder(rungs: [])),
            locale: "es-MX"
        )
        #expect(catalog.locale == "es-MX")
    }
}

@Suite("Catalog reader")
struct CatalogReaderTests {
    private func object(_ catalog: Catalog, group: UInt64 = 0) throws -> TrackObject {
        TrackObject(group: group, object: 0, payload: try catalog.encoded(), isKeyFrame: true)
    }

    @Test("a version replaces the one before it")
    func latestWins() async throws {
        let reader = CatalogReader()
        let first = Catalog(tracks: [CatalogTrack(name: "a", kind: .video, codec: "video/hevc")])
        let second = Catalog(tracks: [CatalogTrack(name: "b", kind: .video, codec: "video/hevc")])

        await reader.apply(try object(first))
        await reader.apply(try object(second, group: 1))

        #expect(await reader.current == second)
        #expect(await reader.versionsApplied == 2)
    }

    @Test("a version we cannot read leaves the last good one standing")
    func malformedDoesNotClobber() async throws {
        // Dropping the catalog entirely would take down media that is still
        // arriving and still decodable.
        let reader = CatalogReader()
        let good = Catalog(tracks: [CatalogTrack(name: "a", kind: .video, codec: "video/hevc")])
        await reader.apply(try object(good))
        await reader.apply(TrackObject(group: 1, object: 0, payload: Data([0x7B, 0x7B])))

        #expect(await reader.current == good)
        #expect(await reader.versionsRejected == 1)
    }
}

@Suite("Catalog publication")
struct CatalogPublicationTests {
    @Test("each version goes in its own group, so a joiner gets a whole one")
    func versionsGetTheirOwnGroups() async throws {
        let relay = LoopbackRelay()
        let session = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: credentials("alice"),
            tenant: "acme"
        )
        try await session.connect(to: RelayEndpoint(host: "loopback"))
        let namespace = try MoqomNamespaces.participant(
            tenant: "acme", room: "room-42", identity: identity("alice")
        )
        let track = try FullTrackName(namespace: namespace, name: TrackName(Catalog.trackName))
        let transport = try await LoopbackTransport(relay: relay).connect(
            to: RelayEndpoint(host: "loopback"), credentials: credentials("alice")
        )
        let publisher = CatalogPublisher(
            writer: try await transport.publish(track, priority: CatalogPublisher.priority)
        )

        let first = Catalog(tracks: [CatalogTrack(name: "a", kind: .video, codec: "video/hevc")])
        let second = Catalog(tracks: [CatalogTrack(name: "b", kind: .video, codec: "video/hevc")])

        #expect(try await publisher.publish(first))

        // Republishing what is already out there sends nothing. A catalog
        // changes when tracks change, and a publisher that re-sent it on a
        // timer would spend a group per tick for no information.
        #expect(try await publisher.publish(first) == false)
        #expect(try await publisher.publish(second))

        let objects = await relay.objects(onTrackNamed: Catalog.trackName)
        #expect(objects.map(\.group) == [0, 1])
        #expect(objects.allSatisfy { $0.object == 0 })
        #expect(objects.allSatisfy { $0.isKeyFrame })
    }
}

@Suite("Sealed catalog")
struct SealedCatalogTests {
    private let catalog = Catalog(
        keyID: 9,
        muted: [.audio],
        locale: "fr-FR",
        tracks: [
            CatalogTrack(
                name: "video/720p",
                kind: .video,
                codec: "video/hevc",
                decoderConfiguration: "00010203",
                width: 1280,
                height: 720,
                frameRate: 30,
                bitrate: 2_000_000,
                rung: 1
            ),
            CatalogTrack(name: "audio", kind: .audio, codec: "audio/opus", bitrate: 24000),
        ]
    )

    @Test("the disclosure names tracks, kinds, geometry and locale, and nothing else")
    func disclosureIsMinimal() throws {
        let disclosed = try #require(
            JSONSerialization.jsonObject(with: catalog.disclosure()) as? [String: Any]
        )
        #expect(Set(disclosed.keys) == ["version", "keyID", "locale", "tracks"])
        #expect(disclosed["locale"] as? String == "fr-FR")
        let tracks = try #require(disclosed["tracks"] as? [[String: Any]])
        #expect(Set(tracks[0].keys) == ["name", "kind", "width", "height"])
        #expect(Set(tracks[1].keys) == ["name", "kind"])

        let text = String(decoding: catalog.disclosure(), as: UTF8.self)
        for secret in ["hevc", "opus", "00010203", "2000000", "muted"] {
            #expect(!text.contains(secret))
        }
    }

    @Test("a sealed catalog reaches the relay as ciphertext with only its disclosure readable")
    func sealedOnTheWire() async throws {
        let relay = LoopbackRelay()
        let namespace = try MoqomNamespaces.participant(
            tenant: "acme", room: "room-42", identity: identity("alice")
        )
        let track = try FullTrackName(namespace: namespace, name: TrackName(Catalog.trackName))
        let transport = try await LoopbackTransport(relay: relay).connect(
            to: RelayEndpoint(host: "loopback"), credentials: credentials("alice")
        )
        let key = SFrameKey(keyID: 9, baseKey: Data(repeating: 0x5A, count: 32))
        let publisher = CatalogPublisher(
            writer: ProtectedTrackWriter(
                wrapping: try await transport.publish(track, priority: CatalogPublisher.priority),
                sender: SFrameSender(key: key)
            )
        )
        #expect(try await publisher.publish(catalog))

        let sealed = try #require(await relay.objects(onTrackNamed: Catalog.trackName).first)
        #expect(sealed.payload != (try catalog.encoded()))
        #expect(!String(decoding: sealed.payload, as: UTF8.self).contains("hevc"))
        #expect(sealed.properties.disclosure == catalog.disclosure())

        let receiver = SFrameReceiver()
        receiver.add(key)
        let unprotector = MediaUnprotector(receiver: receiver)
        let opened = try #require(await unprotector.unprotect(sealed))
        let reader = CatalogReader()
        #expect(await reader.apply(opened) == catalog)

        // The relay can read the disclosure and cannot rewrite it: the SFrame
        // tag covers it.
        let forged = TrackObject(
            group: sealed.group, object: sealed.object, priority: sealed.priority,
            payload: sealed.payload, isKeyFrame: true,
            properties: ObjectProperties(disclosure: Data(#"{"tracks":[],"version":1}"#.utf8))
        )
        #expect(await unprotector.unprotect(forged) == nil)

        // Nor can it substitute a plaintext catalog of its own.
        let plaintext = TrackObject(
            group: 1, object: 0, payload: try catalog.encoded(), isKeyFrame: true,
            properties: ObjectProperties(disclosure: catalog.disclosure())
        )
        #expect(await unprotector.unprotect(plaintext) == nil)
    }
}

@Suite("Catalog discovery")
struct CatalogDiscoveryTests {
    @Test("a viewer's ladder comes from the publisher rather than a default")
    func ladderComesFromTheCatalog() async throws {
        // The whole point. `.defaultCamera()` is 180p/360p/720p; this publisher
        // offers a single 540p rung, and a viewer that kept the default would
        // subscribe to tracks that do not exist.
        let relay = LoopbackRelay()

        let host = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: credentials("alice"),
            tenant: "acme"
        )
        try await host.connect(to: RelayEndpoint(host: "loopback"))
        let hostRoom = try await host.join(room: "room-42")

        let viewer = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: credentials("bob"),
            tenant: "acme"
        )
        try await viewer.connect(to: RelayEndpoint(host: "loopback"))
        let viewerRoom = try await viewer.join(room: "room-42")

        let ladder = LayerLadder(rungs: [
            VideoLayer(
                id: "video/540p",
                size: PixelSize(width: 960, height: 540),
                frameRate: 24,
                bitrate: 1_200_000
            ),
        ])
        _ = try await hostRoom.startBroadcast(
            from: FrameRelay(
                format: CaptureFormat(size: PixelSize(width: 960, height: 540), frameRate: 24),
                depth: 8
            ),
            configuration: BroadcastConfiguration(
                ladder: ladder,
                encoderFactory: { SyntheticEncoder(configuration: $0) }
            )
        )

        let who = identity("alice")
        #expect(
            await eventually {
                await viewerRoom.catalog(of: who)?.videoLadder.rungs.count == 1
            }
        )

        let discovered = try #require(await viewerRoom.catalog(of: who))
        #expect(discovered.videoLadder.rungs.map(\.id.value) == ["video/540p"])
        #expect(discovered.videoLadder.lowest?.size.height == 540)
        #expect(discovered.track(named: "video/540p")?.codec == "video/hevc")
    }

    @Test("the catalog gains decoder configuration once something has encoded")
    func configurationArrivesAfterTheFirstKeyframe() async throws {
        // Parameter sets do not exist until a frame has been encoded, so a
        // catalog published before then advertises a decoder nobody can build.
        // The second version is what fixes that.
        let relay = LoopbackRelay()
        let host = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: credentials("carol"),
            tenant: "acme"
        )
        try await host.connect(to: RelayEndpoint(host: "loopback"))
        let room = try await host.join(room: "room-42")

        let source = FrameRelay(
            format: CaptureFormat(size: PixelSize(width: 640, height: 360), frameRate: 30),
            depth: 8
        )
        _ = try await room.startBroadcast(
            from: source,
            configuration: BroadcastConfiguration(
                ladder: LayerLadder(rungs: [
                    VideoLayer(
                        id: "video/360p",
                        size: PixelSize(width: 640, height: 360),
                        frameRate: 30,
                        bitrate: 600_000
                    ),
                ]),
                encoderFactory: { SyntheticEncoder(configuration: $0) }
            )
        )

        #expect(await room.publishedCatalog?.track(named: "video/360p") != nil)
        #expect(await room.publishedCatalog?.track(named: "video/360p")?
            .decoderConfiguration == nil)

        source.submit(
            VideoFrame(
                timestamp: FrameTimestamp(nanoseconds: 0),
                size: PixelSize(width: 640, height: 360),
                surface: .synthetic(byteCount: 1024),
                forcesKeyFrame: true
            )
        )

        #expect(
            await eventually(timeout: .seconds(6)) {
                await room.publishedCatalog?.track(named: "video/360p")?
                    .decoderConfiguration != nil
            }
        )
    }

    @Test("a refused catalog subscription is retried rather than abandoned")
    func aRefusedCatalogSubscriptionIsRetried() async throws {
        // One attempt was all a participant ever got. Subscribing to somebody's catalog
        // happens the moment their announcement arrives, which is the busiest instant of a
        // join and the likeliest one to be refused — and the refusal was swallowed by a
        // `try?`, so the participant sat in the roster with a tile, a layout box, and no
        // ladder for as long as they stayed. Nothing was logged, no counter moved, and the
        // link carried the other direction perfectly the whole time.
        let relay = LoopbackRelay()
        await relay.refuseSubscribes(to: Catalog.trackName, count: 2)

        let host = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: credentials("alice"),
            tenant: "acme"
        )
        try await host.connect(to: RelayEndpoint(host: "loopback"))
        let hostRoom = try await host.join(room: "room-42")

        let viewer = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: credentials("bob"),
            tenant: "acme"
        )
        try await viewer.connect(to: RelayEndpoint(host: "loopback"))
        let viewerRoom = try await viewer.join(room: "room-42")

        _ = try await hostRoom.startBroadcast(
            from: FrameRelay(
                format: CaptureFormat(size: PixelSize(width: 960, height: 540), frameRate: 24),
                depth: 8
            ),
            configuration: BroadcastConfiguration(
                ladder: LayerLadder(rungs: [
                    VideoLayer(
                        id: "video/540p",
                        size: PixelSize(width: 960, height: 540),
                        frameRate: 24,
                        bitrate: 1_200_000
                    ),
                ]),
                encoderFactory: { SyntheticEncoder(configuration: $0) }
            )
        )

        #expect(
            await eventually(timeout: .seconds(10)) {
                await viewerRoom.catalog(of: identity("alice"))?.videoLadder.rungs.count == 1
            },
            "a catalog refused twice should still arrive on the third attempt"
        )
    }
}
