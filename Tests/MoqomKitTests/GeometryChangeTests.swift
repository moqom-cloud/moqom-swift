// A publisher that changes the shape of its picture while people are watching.
//
// The host switches layout, or turns the phone, and the pictures that follow are
// a different size. Everything about that is easy except the seam, and the seam
// is what these tests are about: subscribers keep their subscriptions, the track
// keeps its name, and nobody sees a blank tile.
//
// Three properties carry the whole design, and each is here because breaking it
// is invisible in a working call until somebody rotates a phone.
//
// The track name does not move. A `LayerID` is a track name, so publishing the
// new size somewhere else would oblige every subscriber to be told to go and
// find it — and until they were, they would be subscribed to a track that had
// stopped.
//
// The keyframe carries its own parameter sets. The catalog carries them too, on
// a different track, and the two arrive in either order; a receiver that waited
// for the catalog would decode new pictures against an old description for as
// long as the race lasted.
//
// The old size keeps going out until the new one has a keyframe to show. That is
// the overlap, and it is one frame or two, not a group.

import Foundation
import Testing

@testable import MoqomCore
@testable import MoqomKit
@testable import MoqomLoopback

@Suite("A ladder turned to a new shape")
struct LadderReshapeTests {
    @Test("a rung keeps its name and short side, and only the long side moves")
    func rungsKeepTheirIdentity() {
        // The division the whole feature rests on: shape is the source's business
        // and may change mid-call, rungs are a contract with subscribers who
        // chose one by name.
        let ladder = LayerLadder.defaultCamera(topSize: PixelSize(width: 1920, height: 1080))
        let upright = ladder.reshaped(toAspectOf: PixelSize(width: 720, height: 1280))

        #expect(upright.rungs.map(\.id) == ladder.rungs.map(\.id))
        for (was, now) in zip(ladder.rungs, upright.rungs) {
            #expect(min(now.size.width, now.size.height) == min(was.size.width, was.size.height))
            #expect(now.size.height > now.size.width)
            #expect(now.bitrate == was.bitrate)
            #expect(now.frameRate == was.frameRate)
        }
    }

    @Test("every reshaped dimension is even")
    func dimensionsStayEven() {
        // Chroma is subsampled by two in both directions, so an odd dimension is
        // a size half the encoders in the world refuse and the rest round for
        // you without saying which way.
        let ladder = LayerLadder(rungs: [
            VideoLayer(id: "video/360p", size: PixelSize(width: 640, height: 360),
                       frameRate: 30, bitrate: 600_000),
        ])
        for capture in [
            PixelSize(width: 1179, height: 2556), // A 15 Pro, in points times three.
            PixelSize(width: 1080, height: 1919),
            PixelSize(width: 4032, height: 3024),
        ] {
            let rung = ladder.reshaped(toAspectOf: capture).rungs[0]
            #expect(rung.size.width % 2 == 0)
            #expect(rung.size.height % 2 == 0)
        }
    }

    @Test("a rung named for its short side does not change quality when rotated")
    func rotationIsNotAQualityChange() {
        // Holding the pixel count instead would make `video/720p` mean 933×525
        // in landscape and 720×1280 upright, so turning a phone would read as a
        // quality change to anyone watching the badge.
        let landscape = VideoLayer(id: "video/720p", size: PixelSize(width: 1280, height: 720),
                                   frameRate: 30, bitrate: 2_000_000)
        let portrait = landscape.reshaped(toAspectOf: PixelSize(width: 1080, height: 1920))
        #expect(portrait.size == PixelSize(width: 720, height: 1280))
        #expect(portrait.id == landscape.id)
    }
}

/// Frames as a viewer received them, for a test to look at afterwards.
private actor FrameLog {
    private(set) var frames: [DepacketisedFrame] = []

    func append(_ frame: DepacketisedFrame) { frames.append(frame) }

    /// One reading rather than two, so a caller polling for both cannot ask for
    /// them either side of a frame arriving.
    var hasSeenTheShapeChange: Bool {
        frames.contains { $0.changesFormat } && frames.count >= 8
    }
}

@Suite("A live change of shape")
struct GeometryChangeTests {
    /// A rung of the shape a phone publishes upright.
    private static let upright = VideoLayer(
        id: "video/360p",
        size: PixelSize(width: 360, height: 640),
        frameRate: 30,
        bitrate: 600_000
    )

    /// The same rung, turned on its side. Same name, same short side.
    private static let sideways = VideoLayer(
        id: "video/360p",
        size: PixelSize(width: 640, height: 360),
        frameRate: 30,
        bitrate: 600_000
    )

    private struct Stage {
        let relay: LoopbackRelay
        let hostRoom: RoomSession
        let viewerRoom: RoomSession
        let broadcast: Broadcast
        let source: FrameRelay
        let host = identity("alice")
    }

    private func stage(watched: Bool = true) async throws -> Stage {
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

        let source = FrameRelay(
            format: CaptureFormat(size: Self.upright.size, frameRate: 30),
            depth: 32
        )
        let broadcast = try await hostRoom.startBroadcast(
            from: source,
            configuration: BroadcastConfiguration(
                ladder: LayerLadder(rungs: [Self.upright]),
                encoderFactory: { SyntheticEncoder(configuration: $0) }
            )
        )

        let who = identity("alice")
        #expect(await eventually { await viewerRoom.roster[who] != nil })
        if watched {
            // A subscription is what starts the pump, and the box is what picks
            // the rung; without a layout there is no subscription and no frames.
            await viewerRoom.updateLayout(
                [who: RenderBox(width: 360, height: 640, scale: 1)],
                linkBitrate: 5_000_000
            )
        }

        return Stage(
            relay: relay,
            hostRoom: hostRoom,
            viewerRoom: viewerRoom,
            broadcast: broadcast,
            source: source
        )
    }

    private func submit(
        _ source: FrameRelay,
        _ count: Int,
        from offset: Int,
        size: PixelSize
    ) {
        for index in offset ..< (offset + count) {
            source.submit(
                VideoFrame(
                    timestamp: FrameTimestamp(nanoseconds: UInt64(index) * 33_000_000),
                    size: size,
                    surface: .synthetic(byteCount: 1024),
                    forcesKeyFrame: index == 0
                )
            )
        }
    }

    @Test("a source that changes aspect is followed, on the same track")
    func theSourceIsFollowed() async throws {
        let stage = try await stage()
        submit(stage.source, 4, from: 0, size: Self.upright.size)
        #expect(await eventually { await stage.broadcast.stats.objectsPublished >= 4 })

        // The layout changes: the frames arriving are a different shape.
        submit(stage.source, 8, from: 4, size: Self.sideways.size)
        #expect(await eventually { await stage.broadcast.stats.reshapes == 1 })

        let ladder = await stage.broadcast.currentLadder
        #expect(ladder.rungs.map(\.id) == ["video/360p"])
        #expect(ladder.rungs[0].size == Self.sideways.size)

        // One track throughout. A new name here would be a publication a
        // subscriber has to be told about.
        let tracks = await stage.relay.trackNames()
        #expect(tracks.filter { $0.hasPrefix("video/") } == ["video/360p"])
    }

    @Test("one frame of a different shape is not a layout change")
    func oneOddFrameIsIgnored() async throws {
        // A rotation can produce a single frame at an intermediate size, and a
        // reshape costs every rung a keyframe. Two frames is the evidence.
        let stage = try await stage()
        submit(stage.source, 4, from: 0, size: Self.upright.size)
        #expect(await eventually { await stage.broadcast.stats.objectsPublished >= 4 })

        submit(stage.source, 1, from: 4, size: Self.sideways.size)
        submit(stage.source, 4, from: 5, size: Self.upright.size)
        #expect(await eventually { await stage.broadcast.stats.objectsPublished >= 9 })
        #expect(await stage.broadcast.stats.reshapes == 0)
    }

    @Test("the switch lands on a keyframe that opens a group and carries its own format")
    func theSwitchIsSelfDescribing() async throws {
        let stage = try await stage()
        submit(stage.source, 4, from: 0, size: Self.upright.size)
        #expect(await eventually { await stage.broadcast.stats.objectsPublished >= 4 })

        submit(stage.source, 8, from: 4, size: Self.sideways.size)
        #expect(await eventually { await stage.broadcast.stats.reshapes == 1 })

        let published = await stage.relay.objects(onTrackNamed: "video/360p")
        let configurations = published
            .filter(\.isKeyFrame)
            .compactMap(\.properties.configuration)

        // Every keyframe describes itself, not only the one that changed
        // something: the relay caches groups by track name and has no idea the
        // shape of a track can move, so a joiner handed an older group from the
        // cache has to be able to read it.
        #expect(configurations.count == published.filter(\.isKeyFrame).count)
        #expect(Set(configurations).count == 2)

        // And the reshaped picture opens a group rather than continuing one, so
        // it is a point a decoder can start from.
        let reshaped = try #require(
            published.last { $0.properties.configuration == configurations.last }
        )
        #expect(reshaped.isKeyFrame)
        #expect(reshaped.object == 0)
        #expect(reshaped.group > published[0].group)

        // Deltas carry no configuration. A hundred bytes on every frame to
        // restate something that changes twice a call is the kind of overhead
        // that is easier to add than to notice.
        #expect(published.filter { !$0.isKeyFrame }.allSatisfy {
            $0.properties.configuration == nil
        })
    }

    @Test("a viewer sees the shape change without a gap and without a stall")
    func aViewerIsNotInterrupted() async throws {
        let stage = try await stage()
        let frames = try #require(await stage.viewerRoom.frames(from: stage.host))

        // Collected off to the side and waited for with a deadline, rather than
        // iterating until the expected frame arrives. A test that waits for the
        // frame it is asserting about hangs instead of failing when the frame does
        // not come, and a hang in a parallel suite takes every other test with it.
        let seen = FrameLog()
        let collecting = Task {
            for await frame in frames {
                await seen.append(frame)
            }
        }
        defer { collecting.cancel() }

        submit(stage.source, 4, from: 0, size: Self.upright.size)
        #expect(await eventually { await stage.broadcast.stats.objectsPublished >= 4 })
        submit(stage.source, 10, from: 4, size: Self.sideways.size)

        #expect(await eventually { await seen.hasSeenTheShapeChange })
        let received = await seen.frames

        // The one thing the viewer must be told, and the one thing it must not
        // be told. A reshape is not a gap: a gap means flush, blank and
        // re-anchor, and doing that here is a black flash for an event where the
        // correct behaviour is to keep the last picture until the new one
        // decodes.
        #expect(received.filter(\.changesFormat).count == 1)
        #expect(received.allSatisfy { !$0.followsGap })

        // Frames keep arriving across the seam, which is what "no visible hitch"
        // means when it is measured rather than watched.
        let reshaped = try #require(received.firstIndex { $0.changesFormat })
        #expect(reshaped > 0)
        #expect(received.count > reshaped + 1)
        #expect(received[reshaped].frame.isKeyFrame)

        // The timeline does not restart. A receiver presents against the
        // publisher's clock, so a jump here would move every queued frame's
        // moment and lurch the picture once.
        let times = received.map(\.frame.timestamp.nanoseconds)
        #expect(times == times.sorted())

        // Both formats decode, and the second one arrived on the bitstream
        // rather than out of the catalog.
        let before = try #require(received[..<reshaped].last { $0.frame.isKeyFrame })
        #expect(before.frame.parameterSets != received[reshaped].frame.parameterSets)
    }

    @Test("the overlap is one encoder and a frame or two, not a group")
    func theOverlapIsMinimal() async throws {
        let stage = try await stage()
        submit(stage.source, 4, from: 0, size: Self.upright.size)
        #expect(await eventually { await stage.broadcast.stats.objectsPublished >= 4 })

        submit(stage.source, 12, from: 4, size: Self.sideways.size)
        #expect(await eventually { await stage.broadcast.stats.reshapes == 1 })

        // What the handover costs: the pictures still inside the old session when
        // it lost the track. A group's worth here — sixty frames at 30fps with a
        // two-second group — would mean the two encoders were running in parallel
        // for the whole group rather than for the frame it takes to produce a
        // keyframe.
        let stats = await stage.broadcast.stats
        #expect(stats.framesOutOfShape <= 4)

        // And the old session is gone rather than idling: nothing goes out of
        // shape once the handover is over, however many frames follow it.
        let published = stats.objectsPublished
        submit(stage.source, 8, from: 16, size: Self.sideways.size)
        #expect(await eventually { await stage.broadcast.stats.objectsPublished > published })
        let after = await stage.broadcast.stats
        #expect(after.framesOutOfShape == stats.framesOutOfShape)
        #expect(after.reshapesAbandoned == 0)
    }

    @Test("a slow encoder is waited for in time, not in frames")
    func theDeadlineIsMeasuredInTime() async throws {
        // The rule this pins was a frame count, and the difference only shows on a
        // machine that is busy. What the deadline guards against is a frozen picture,
        // which is half a second; frames are a proxy for that only while they arrive
        // at the rate a camera promises. Feed the publication faster than its drain
        // tasks are scheduled — a test, or a host under load — and fifteen frames go
        // by before the new encoder has been read from once, so the handover is
        // abandoned just before it would have landed. Then the shape still disagrees,
        // so it is tried again, and abandoned again.
        //
        // Which is what a loaded run of this suite did: `framesOutOfShape` climbing
        // 8, 12, 16 while `reshapes` stayed at zero.
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

        let source = FrameRelay(
            format: CaptureFormat(size: Self.upright.size, frameRate: 30),
            depth: 64
        )
        let broadcast = try await hostRoom.startBroadcast(
            from: source,
            configuration: BroadcastConfiguration(
                ladder: LayerLadder(rungs: [Self.upright]),
                // Silent for its first twenty frames, which is more than the fifteen
                // the old rule allowed and far less than the half second the new one
                // does. A hardware encoder does this at a session start, and it is
                // exactly when a reshape asks one for its first picture.
                encoderFactory: { SlowToStartEncoder(configuration: $0, silentFor: 20) }
            )
        )
        let who = identity("alice")
        #expect(await eventually { await viewerRoom.roster[who] != nil })
        await viewerRoom.updateLayout(
            [who: RenderBox(width: 360, height: 640, scale: 1)],
            linkBitrate: 5_000_000
        )

        submit(source, 24, from: 0, size: Self.upright.size)
        #expect(await eventually { await broadcast.stats.objectsPublished >= 1 })

        submit(source, 40, from: 24, size: Self.sideways.size)
        #expect(await eventually { await broadcast.stats.reshapes == 1 })
        #expect(await broadcast.stats.reshapesAbandoned == 0)
        #expect(await broadcast.currentLadder.rungs[0].size == Self.sideways.size)
    }

    @Test("somebody joining after the change gets a group they can decode")
    func aJoinerGetsADecodableGroup() async throws {
        let stage = try await stage()
        submit(stage.source, 4, from: 0, size: Self.upright.size)
        #expect(await eventually { await stage.broadcast.stats.objectsPublished >= 4 })
        submit(stage.source, 10, from: 4, size: Self.sideways.size)
        #expect(await eventually { await stage.broadcast.stats.reshapes == 1 })

        // A viewer arriving now, with no catalog at all. This is the case the
        // relay's cache creates and cannot see: it serves groups by track name,
        // and the name says nothing about which shape the group is.
        let published = await stage.relay.objects(onTrackNamed: "video/360p")
        let reshapedAt = try #require(
            published.lastIndex { $0.isKeyFrame }
        )

        var fresh = VideoDepacketiser()
        #expect(!fresh.isConfigured)
        let first = fresh.accept(published[reshapedAt])
        #expect(first != nil)
        #expect(fresh.isConfigured)
        #expect(first?.frame.parameterSets.isEmpty == false)

        // Not reported as a change of shape, because for this viewer it is not
        // one — it is the shape. A join that announced a layout change would
        // make the counter useless for spotting a publisher that oscillates.
        #expect(first?.changesFormat == false)

        // An older group still decodes against the description it carries, which
        // is the property that makes the cache safe.
        let earlier = try #require(published.first { $0.isKeyFrame })
        var joiner = VideoDepacketiser()
        let old = joiner.accept(earlier)
        #expect(old?.frame.parameterSets != first?.frame.parameterSets)
    }

    @Test("the catalog is republished with the new dimensions under the old name")
    func theCatalogFollows() async throws {
        // The joiner's path rather than the switch's: everyone already watching
        // learns the new shape from the keyframe. This is so that the next person
        // to arrive lays out a tile for the picture as it is now.
        let stage = try await stage()
        submit(stage.source, 4, from: 0, size: Self.upright.size)
        #expect(await eventually { await stage.broadcast.stats.objectsPublished >= 4 })

        submit(stage.source, 8, from: 4, size: Self.sideways.size)
        #expect(await eventually { await stage.broadcast.stats.reshapes == 1 })

        #expect(
            await eventually {
                let track = await stage.hostRoom.publishedCatalog?.tracks
                    .first { $0.kind == .video }
                return track?.width == 640 && track?.height == 360
            }
        )

        let track = try #require(
            await stage.hostRoom.publishedCatalog?.tracks.first { $0.kind == .video }
        )
        #expect(track.name == "video/360p")

        // And the configuration it advertises is the new one, so a joiner can
        // build a decoder before the first object arrives.
        let configuration = await stage.broadcast.decoderConfigurations["video/360p"]
        #expect(track.decoderConfiguration == configuration?.hexadecimal)
    }

    @Test("asking for the shape already being published costs nothing")
    func anUnchangedShapeIsRefused() async throws {
        // A reshape is a keyframe on every rung. One asked for by a layout pass
        // that recomputed the same answer is a stall for nothing.
        let stage = try await stage()
        submit(stage.source, 4, from: 0, size: Self.upright.size)
        #expect(await eventually { await stage.broadcast.stats.objectsPublished >= 4 })

        await stage.broadcast.reshape(to: LayerLadder(rungs: [Self.upright]))
        await stage.broadcast.reshape(toAspectOf: Self.upright.size)
        #expect(await stage.broadcast.stats.reshapes == 0)
    }

    @Test("a ladder whose rungs have different names is not a reshape")
    func renamedRungsAreRefused() async throws {
        // Going from `video/360p` to `video/720p` is a different track, so it is
        // a different publication rather than a change of size. Ignored rather
        // than half-applied: publishing the new size on a name nobody is
        // subscribed to is a stream with no viewers.
        let stage = try await stage()
        submit(stage.source, 4, from: 0, size: Self.upright.size)
        #expect(await eventually { await stage.broadcast.stats.objectsPublished >= 4 })

        await stage.broadcast.reshape(to: LayerLadder(rungs: [
            VideoLayer(id: "video/720p", size: PixelSize(width: 720, height: 1280),
                       frameRate: 30, bitrate: 2_000_000),
        ]))
        #expect(await stage.broadcast.stats.reshapes == 0)
        #expect(await stage.broadcast.currentLadder.rungs[0].size == Self.upright.size)
    }

    @Test("a publication told not to follow its source does not")
    func followingCanBeTurnedOff() async throws {
        // For a publisher that wants the encoder to letterbox or crop into a
        // fixed shape, which is a legitimate choice — it just must not be the
        // default, because the failure when it is wrong is that everyone looks
        // stretched and nothing reports an error.
        let relay = LoopbackRelay()
        let host = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: credentials("alice"),
            tenant: "acme"
        )
        try await host.connect(to: RelayEndpoint(host: "loopback"))
        let room = try await host.join(room: "room-42")

        let source = FrameRelay(
            format: CaptureFormat(size: Self.upright.size, frameRate: 30),
            depth: 32
        )
        let broadcast = try await room.startBroadcast(
            from: source,
            configuration: BroadcastConfiguration(
                ladder: LayerLadder(rungs: [Self.upright]),
                followsCaptureShape: false,
                encoderFactory: { SyntheticEncoder(configuration: $0) }
            )
        )

        submit(source, 4, from: 0, size: Self.upright.size)
        #expect(await eventually { await broadcast.stats.objectsPublished >= 4 })
        submit(source, 8, from: 4, size: Self.sideways.size)
        #expect(await eventually { await broadcast.stats.objectsPublished >= 12 })

        #expect(await broadcast.stats.reshapes == 0)
        #expect(await broadcast.currentLadder.rungs[0].size == Self.upright.size)
    }
}

/// An encoder that produces nothing for its first few frames.
///
/// A real one does this. A hardware session takes some tens of milliseconds to give
/// back its first picture, and a reshape is precisely the moment something asks a
/// brand new session for one — so how long a handover waits for that is a question
/// with a right answer, and it is a duration rather than a number of frames.
private final class SlowToStartEncoder: FrameEncoder, @unchecked Sendable {
    let configuration: EncoderConfiguration
    private(set) var accounting = EncoderAccounting()

    private let inner: SyntheticEncoder
    private let silentFor: Int
    private var seen = 0

    init(configuration: EncoderConfiguration, silentFor: Int) {
        self.configuration = configuration
        self.silentFor = silentFor
        inner = SyntheticEncoder(configuration: configuration)
    }

    func encode(_ frame: VideoFrame, forcingKeyFrame: Bool) async throws {
        seen += 1
        guard seen > silentFor else {
            accounting.declined += 1
            return
        }
        // Forced on the first one it does emit, whatever it was asked for: an encoder
        // coming up starts at a keyframe, and a handover turns on that keyframe.
        try await inner.encode(frame, forcingKeyFrame: forcingKeyFrame || seen == silentFor + 1)
        accounting.emitted += 1
    }

    func encodedFrames() -> AsyncStream<EncodedFrame> { inner.encodedFrames() }

    func close() async { await inner.close() }
}
