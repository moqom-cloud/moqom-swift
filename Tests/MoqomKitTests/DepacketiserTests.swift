// Reassembly, which is where a publish bug becomes a viewer bug.
//
// The round trip at the bottom is the one that matters: a broadcast goes out
// through the real packetiser and comes back through the real depacketiser, and
// the frames that arrive have to be the frames that were encoded. Everything
// above it pins one rule each, because those rules are individually easy to get
// right by accident on a stream that never drops anything.

import Foundation
import Testing

@testable import MoqomCore
@testable import MoqomKit
@testable import MoqomLoopback

@Suite("Decoder configuration")
struct DecoderConfigurationTests {
    @Test("parameter sets survive the round trip in order")
    func roundTrip() {
        // Order is not cosmetic: VPS before SPS before PPS is what
        // CMVideoFormatDescriptionCreateFromHEVCParameterSets expects.
        let sets = [Data([0x40, 0x01]), Data([0x42, 0x01, 0x02]), Data([0x44])]
        let encoded = DecoderConfiguration.encode(sets)
        #expect(DecoderConfiguration.decode(encoded) == sets)
    }

    @Test("a truncated buffer is refused rather than partly read")
    func truncatedIsRefused() {
        // Returning the sets it managed to read would build a format
        // description that is wrong rather than absent, and the failure would
        // surface frames later inside VideoToolbox.
        let encoded = DecoderConfiguration.encode([Data([1, 2, 3, 4])])
        #expect(DecoderConfiguration.decode(encoded.dropLast()) == nil)
        #expect(DecoderConfiguration.decode(Data([0, 0, 0])) == nil)
        #expect(DecoderConfiguration.decode(Data()) == nil)
    }

    @Test("a length that claims more than is there is refused")
    func overlongLengthIsRefused() {
        var data = Data()
        withUnsafeBytes(of: UInt32(64).bigEndian) { data.append(contentsOf: $0) }
        data.append(Data([1, 2, 3]))
        #expect(DecoderConfiguration.decode(data) == nil)
    }
}

@Suite("Depacketiser")
struct DepacketiserTests {
    private func object(
        group: UInt64,
        object: UInt64,
        isKeyFrame: Bool = false,
        captureTime: UInt64 = 0,
        temporalLayer: Int = 0
    ) -> TrackObject {
        TrackObject(
            group: group,
            object: object,
            priority: 64,
            payload: Data([UInt8(object & 0xFF)]),
            isKeyFrame: isKeyFrame,
            properties: ObjectProperties(
                captureTime: FrameTimestamp(nanoseconds: captureTime),
                temporalLayer: temporalLayer
            )
        )
    }

    @Test("nothing comes out before the first keyframe")
    func waitsForAKeyFrame() {
        // A decoder cannot start mid-group. Handing these on would produce a
        // picture referencing frames that never arrived, which reads as a
        // corrupt encoder rather than as a normal join.
        var depacketiser = VideoDepacketiser()
        #expect(depacketiser.accept(object(group: 4, object: 7)) == nil)
        #expect(depacketiser.accept(object(group: 4, object: 8)) == nil)
        #expect(depacketiser.objectsAwaitingKeyFrame == 2)

        #expect(depacketiser.accept(object(group: 5, object: 0, isKeyFrame: true)) != nil)
        #expect(depacketiser.accept(object(group: 5, object: 1)) != nil)
        #expect(depacketiser.framesProduced == 2)
    }

    @Test("a hole in the object numbering is counted and reported")
    func gapsAreReported() {
        var depacketiser = VideoDepacketiser()
        _ = depacketiser.accept(object(group: 0, object: 0, isKeyFrame: true))
        _ = depacketiser.accept(object(group: 0, object: 1))

        let afterGap = depacketiser.accept(object(group: 0, object: 5))
        #expect(afterGap?.followsGap == true)
        #expect(depacketiser.objectsLost == 3)

        // Reported once. A renderer flushes on the gap; telling it to flush
        // again on the next frame would throw away the frame it just recovered
        // with.
        #expect(depacketiser.accept(object(group: 0, object: 6))?.followsGap == false)
    }

    @Test("the next group is continuity, a skipped group is not")
    func groupBoundaries() {
        var depacketiser = VideoDepacketiser()
        _ = depacketiser.accept(object(group: 0, object: 0, isKeyFrame: true))

        let next = depacketiser.accept(object(group: 1, object: 0, isKeyFrame: true))
        #expect(next?.followsGap == false)

        let skipped = depacketiser.accept(object(group: 4, object: 0, isKeyFrame: true))
        #expect(skipped?.followsGap == true)

        // Object IDs restart per group, so a lower ID in a new group is not a
        // loss. Counting it as one would report loss on every group boundary.
        #expect(depacketiser.objectsLost == 0)
    }

    @Test("parameter sets ride the keyframe and nothing else")
    func parameterSetsOnKeyFramesOnly() {
        var depacketiser = VideoDepacketiser()
        let sets = [Data([0x40, 0x01]), Data([0x42, 0x02])]
        let accepted = depacketiser.setDecoderConfiguration(DecoderConfiguration.encode(sets))
        #expect(accepted)
        #expect(depacketiser.isConfigured)

        let key = depacketiser.accept(object(group: 0, object: 0, isKeyFrame: true))
        #expect(key?.frame.parameterSets == sets)

        // Attaching them to every frame would make the assembler rebuild its
        // format description constantly, which makes the display layer
        // renegotiate for no reason.
        let delta = depacketiser.accept(object(group: 0, object: 1))
        #expect(delta?.frame.parameterSets.isEmpty == true)
    }

    @Test("a new configuration restarts reassembly")
    func configurationChangeRestarts() {
        var depacketiser = VideoDepacketiser()
        depacketiser.setDecoderConfiguration(DecoderConfiguration.encode([Data([0x40])]))
        _ = depacketiser.accept(object(group: 0, object: 0, isKeyFrame: true))
        _ = depacketiser.accept(object(group: 0, object: 1))

        depacketiser.setDecoderConfiguration(DecoderConfiguration.encode([Data([0x41])]))

        // Different bitstream: the frames in flight for the old one are not
        // decodable against the new format description.
        #expect(depacketiser.accept(object(group: 0, object: 2)) == nil)
        #expect(depacketiser.accept(object(group: 1, object: 0, isKeyFrame: true))?
            .followsGap == true)
    }

    @Test("a malformed configuration leaves the working one in place")
    func malformedConfigurationIsIgnored() {
        var depacketiser = VideoDepacketiser()
        let good = [Data([0x40, 0x01])]
        let accepted = depacketiser.setDecoderConfiguration(DecoderConfiguration.encode(good))
        let refused = depacketiser.setDecoderConfiguration(Data([0x00, 0x01]))
        #expect(accepted)
        #expect(refused == false)
        #expect(depacketiser.decoderParameterSets == good)
    }

    // MARK: - A publisher that changes shape

    private func reshaping(
        group: UInt64,
        to sets: [Data]
    ) -> TrackObject {
        TrackObject(
            group: group,
            object: 0,
            priority: 64,
            payload: Data([0x00]),
            isKeyFrame: true,
            properties: ObjectProperties(
                captureTime: FrameTimestamp(nanoseconds: group * 1000),
                configuration: DecoderConfiguration.encode(sets)
            )
        )
    }

    @Test("a keyframe carrying new parameter sets changes the format without a gap")
    func inBandConfigurationIsNotAGap() {
        // The distinction the renderer acts on. A gap means flush, blank, and
        // re-anchor; a reshape means keep the last picture and change size at
        // this frame. Reporting the second as the first is a black flash every
        // time a host rotates their phone.
        var depacketiser = VideoDepacketiser()
        let portrait = [Data([0x40, 0x02, 0xD0, 0x05, 0x00])]
        let landscape = [Data([0x40, 0x05, 0x00, 0x02, 0xD0])]

        _ = depacketiser.accept(reshaping(group: 0, to: portrait))
        _ = depacketiser.accept(object(group: 0, object: 1))

        let reshaped = depacketiser.accept(reshaping(group: 1, to: landscape))
        #expect(reshaped?.changesFormat == true)
        #expect(reshaped?.followsGap == false)
        #expect(reshaped?.frame.parameterSets == landscape)
        #expect(depacketiser.objectsLost == 0)

        // And the frames after it decode against the new format without being
        // told again.
        let next = depacketiser.accept(object(group: 1, object: 1))
        #expect(next?.changesFormat == false)
        #expect(next != nil)
    }

    @Test("the first keyframe of a stream is not a change of shape")
    func theFirstConfigurationIsNotAReshape() {
        // Otherwise every join reports a layout change, and the one counter that
        // would tell a real reshape from a publisher oscillating between two
        // geometries counts joins instead.
        var depacketiser = VideoDepacketiser()
        let first = depacketiser.accept(reshaping(group: 7, to: [Data([0x40, 0x01])]))
        #expect(first?.changesFormat == false)
        #expect(first?.frame.parameterSets == [Data([0x40, 0x01])])
    }

    @Test("a repeated configuration on every keyframe changes nothing")
    func unchangedConfigurationIsNotAReshape() {
        // Every keyframe carries the sets so that a group is decodable from
        // itself. Almost none of them are news, and treating each as a change
        // would rebuild the format description twice a second.
        var depacketiser = VideoDepacketiser()
        let sets = [Data([0x40, 0x01])]
        _ = depacketiser.accept(reshaping(group: 0, to: sets))
        let again = depacketiser.accept(reshaping(group: 1, to: sets))
        #expect(again?.changesFormat == false)
    }

    @Test("a stale catalog cannot undo a reshape the media already made")
    func theCatalogDefersToTheKeyframe() {
        // The race with a wrong answer rather than a slow one. A publisher that
        // changes geometry republishes its catalog and emits a reshaped keyframe
        // at nearly the same moment, on different tracks, so a version describing
        // the old geometry can land just after the new keyframe. Applied, it
        // would tear the picture until the next keyframe.
        var depacketiser = VideoDepacketiser()
        let was = [Data([0x40, 0x02, 0xD0])]
        let now = [Data([0x40, 0x05, 0x00])]

        depacketiser.setDecoderConfiguration(DecoderConfiguration.encode(was))
        _ = depacketiser.accept(reshaping(group: 0, to: now))
        depacketiser.setDecoderConfiguration(DecoderConfiguration.encode(was))

        #expect(depacketiser.decoderParameterSets == now)
        #expect(depacketiser.accept(object(group: 0, object: 1)) != nil)
    }

    @Test("timestamps and temporal layers come back off the properties")
    func metadataSurvives() {
        // These travel as MOQT object properties precisely so a relay can
        // schedule without decrypting. If they did not come back out here, the
        // publisher would be paying for metadata nobody reads.
        var depacketiser = VideoDepacketiser()
        let frame = depacketiser.accept(
            object(
                group: 0,
                object: 0,
                isKeyFrame: true,
                captureTime: 1_234_567,
                temporalLayer: 1
            )
        )
        #expect(frame?.frame.timestamp.nanoseconds == 1_234_567)
        #expect(frame?.frame.temporalLayer == 1)
    }
}

@Suite("Publish and receive")
struct RoundTripTests {
    @Test("a viewer reassembles the frames the publisher encoded")
    func framesSurviveTheRoundTrip() async throws {
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

        let rung = VideoLayer(
            id: "video/360p",
            size: PixelSize(width: 640, height: 360),
            frameRate: 30,
            bitrate: 600_000
        )
        let source = FrameRelay(
            format: CaptureFormat(size: rung.size, frameRate: 30),
            depth: 16
        )
        _ = try await hostRoom.startBroadcast(
            from: source,
            configuration: BroadcastConfiguration(
                ladder: LayerLadder(rungs: [rung]),
                encoderFactory: { SyntheticEncoder(configuration: $0) }
            )
        )

        let who = identity("alice")
        #expect(await eventually { await viewerRoom.roster[who] != nil })

        // Subscribing is what starts the pump, and the box is what picks the
        // rung. Without a layout there is no subscription and no frames.
        await viewerRoom.updateLayout(
            [who: RenderBox(width: 640, height: 360, scale: 1)],
            linkBitrate: 5_000_000
        )

        let frames = try #require(await viewerRoom.frames(from: who))

        for index in 0 ..< 6 {
            source.submit(
                VideoFrame(
                    timestamp: FrameTimestamp(nanoseconds: UInt64(index) * 33_000_000),
                    size: rung.size,
                    surface: .synthetic(byteCount: 1024),
                    forcesKeyFrame: index == 0
                )
            )
        }

        var received: [DepacketisedFrame] = []
        for await frame in frames {
            received.append(frame)
            if received.count == 4 { break }
        }

        // The first frame out has to be a keyframe: anything before one is
        // dropped, which is the property that makes a mid-stream join work.
        #expect(received.first?.frame.isKeyFrame == true)
        #expect(received.allSatisfy { !$0.followsGap })

        // Capture times survive as object properties, so the viewer can pace
        // against the publisher's clock rather than its own arrival times.
        #expect(received.map(\.frame.timestamp.nanoseconds) == [0, 33_000_000, 66_000_000, 99_000_000])

        // And the parameter sets came from the catalog rather than from the
        // bitstream, which is what lets a viewer join at an arbitrary group.
        #expect(
            await eventually {
                await viewerRoom.videoStatistics(for: who)?.framesProduced ?? 0 >= 4
            }
        )
    }

    @Test("the raw objects are still there for anything that wants bytes")
    func objectsAndFramesCoexist() async throws {
        // A recorder wants what arrived, not what was reassembled. Both
        // consumers are fed from one pump, so neither starves the other.
        let relay = LoopbackRelay()
        let host = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: credentials("carol"),
            tenant: "acme"
        )
        try await host.connect(to: RelayEndpoint(host: "loopback"))
        let hostRoom = try await host.join(room: "room-42")

        let viewer = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: credentials("dave"),
            tenant: "acme"
        )
        try await viewer.connect(to: RelayEndpoint(host: "loopback"))
        let viewerRoom = try await viewer.join(room: "room-42")

        let rung = VideoLayer(
            id: "video/360p",
            size: PixelSize(width: 640, height: 360),
            frameRate: 30,
            bitrate: 600_000
        )
        let source = FrameRelay(format: CaptureFormat(size: rung.size, frameRate: 30), depth: 16)
        _ = try await hostRoom.startBroadcast(
            from: source,
            configuration: BroadcastConfiguration(
                ladder: LayerLadder(rungs: [rung]),
                encoderFactory: { SyntheticEncoder(configuration: $0) }
            )
        )

        let who = identity("carol")
        #expect(await eventually { await viewerRoom.roster[who] != nil })
        await viewerRoom.updateLayout(
            [who: RenderBox(width: 640, height: 360, scale: 1)],
            linkBitrate: 5_000_000
        )

        let objects = try #require(await viewerRoom.media(from: who))
        let frames = try #require(await viewerRoom.frames(from: who))

        let counting = Task {
            var count = 0
            for await _ in objects {
                count += 1
                if count == 3 { return count }
            }
            return count
        }

        for index in 0 ..< 4 {
            source.submit(
                VideoFrame(
                    timestamp: FrameTimestamp(nanoseconds: UInt64(index) * 33_000_000),
                    size: rung.size,
                    surface: .synthetic(byteCount: 512),
                    forcesKeyFrame: index == 0
                )
            )
        }

        var frameCount = 0
        for await _ in frames {
            frameCount += 1
            if frameCount == 3 { break }
        }

        #expect(await counting.value == 3)
        #expect(frameCount == 3)
    }

    @Test("a viewer that drops one frame stream still gets frames on the next one")
    func framesSurviveARebuiltView() async throws {
        // What a layout change does: the tile drawing a participant is torn down and an
        // identical one is built in its place. The old stream is abandoned, the new one is
        // asked for, and the picture has to carry on — anything else means the application
        // can stop its own media by rearranging its own views.
        let relay = LoopbackRelay()
        let host = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: credentials("erin"),
            tenant: "acme"
        )
        try await host.connect(to: RelayEndpoint(host: "loopback"))
        let hostRoom = try await host.join(room: "room-42")

        let viewer = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: credentials("frank"),
            tenant: "acme"
        )
        try await viewer.connect(to: RelayEndpoint(host: "loopback"))
        let viewerRoom = try await viewer.join(room: "room-42")

        let rung = VideoLayer(
            id: "video/360p",
            size: PixelSize(width: 640, height: 360),
            frameRate: 30,
            bitrate: 600_000
        )
        let source = FrameRelay(format: CaptureFormat(size: rung.size, frameRate: 30), depth: 16)
        _ = try await hostRoom.startBroadcast(
            from: source,
            configuration: BroadcastConfiguration(
                ladder: LayerLadder(rungs: [rung]),
                encoderFactory: { SyntheticEncoder(configuration: $0) }
            )
        )

        let who = identity("erin")
        #expect(await eventually { await viewerRoom.roster[who] != nil })
        await viewerRoom.updateLayout(
            [who: RenderBox(width: 640, height: 360, scale: 1)],
            linkBitrate: 5_000_000
        )

        func send(from index: Int, count: Int) {
            for offset in 0 ..< count {
                let step = index + offset
                source.submit(
                    VideoFrame(
                        timestamp: FrameTimestamp(nanoseconds: UInt64(step) * 33_000_000),
                        size: rung.size,
                        surface: .synthetic(byteCount: 512),
                        forcesKeyFrame: step == 0
                    )
                )
            }
        }

        // The first tile reads frames from a task, and that task is cancelled when the view
        // goes away. Cancellation is the part that matters: abandoning an iterator is
        // harmless, but cancelling the task reading one terminates the stream itself.
        let first = try #require(await viewerRoom.frames(from: who))
        let reading = Task {
            var seen = 0
            for await _ in first { seen += 1 }
            return seen
        }
        send(from: 0, count: 4)
        try await Task.sleep(for: .milliseconds(50))
        reading.cancel()
        _ = await reading.value

        // Its replacement asks for frames the way the first one did.
        let second = try #require(await viewerRoom.frames(from: who))
        send(from: 4, count: 6)

        var seen = 0
        for await _ in second {
            seen += 1
            if seen == 3 { break }
        }
        #expect(seen == 3)
    }
}
