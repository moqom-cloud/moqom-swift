// What happens between a compressed frame and an object on the wire.
//
// This used to be the part that was not really there: the publish path shipped
// a fixed-size descriptor of each frame, which exercised the transport contract
// and nothing about media. These tests exist to keep it real — the bytes a
// subscriber receives are the bytes an encoder produced, and the group
// boundaries are the ones the encoder chose.

import Foundation
import MoqomCore
import Testing

@testable import MoqomCore
@testable import MoqomKit
@testable import MoqomLoopback
import MoqomWire

@Suite("Publish pipeline")
struct PublishPipelineTests {
    // MARK: - Group and object numbering

    @Test("a keyframe opens a group and the frames after it extend that group")
    func groupsFollowKeyFrames() {
        var sequencer = TrackSequencer()
        let first = sequencer.next(isKeyFrame: true)
        #expect(first == TrackSequencer.Location(group: 0, object: 0, startsGroup: true))

        for expected in UInt64(1) ... 3 {
            let location = sequencer.next(isKeyFrame: false)
            #expect(location.group == 0)
            #expect(location.object == expected)
            #expect(!location.startsGroup)
        }

        let second = sequencer.next(isKeyFrame: true)
        #expect(second == TrackSequencer.Location(group: 1, object: 0, startsGroup: true))
    }

    @Test("a forced group boundary is not opened twice")
    func forcedBoundaryIsNotReopened() {
        // The caller that jumps has already told the transport. A second open
        // would put two subgroups with the same ID on one group, which is a
        // protocol violation rather than a wasted message.
        var sequencer = TrackSequencer()
        _ = sequencer.next(isKeyFrame: true)
        sequencer.jump(to: 7)

        let resumed = sequencer.next(isKeyFrame: true)
        #expect(resumed.group == 7)
        #expect(resumed.object == 0)
        #expect(!resumed.startsGroup)
    }

    @Test("a delta frame arriving before any keyframe is published, not dropped")
    func deltaBeforeKeyFrameStillPublishes() {
        // Should not happen. If it does, discarding encoder output silently is
        // how a working encoder gets diagnosed as a broken one.
        var sequencer = TrackSequencer()
        let orphan = sequencer.next(isKeyFrame: false)
        #expect(orphan.group == 0)
        #expect(orphan.object == 0)
    }

    // MARK: - Object properties

    @Test("capture time and temporal layer survive a round trip on a subgroup stream")
    func propertiesRoundTripOverTheWire() async throws {
        let (clientCarrier, serverCarrier) = MemoryCarrier.pair()
        async let accepted = MoqtSession.accept(over: serverCarrier)
        async let dialled = MoqtSession.connect(
            over: clientCarrier,
            credentials: credentials("alice")
        )
        let (client, server) = try await (dialled, accepted)

        let name = try FullTrackName(
            namespace: MoqomNamespaces.participant(
                tenant: "acme", room: "room-42", identity: identity("alice")
            ),
            name: TrackName("video/720p")
        )
        _ = try await client.announce(name.namespace)
        let writer = try await client.publish(name, priority: 64)

        let subscription = try await server.subscribe(SubscribeRequest(track: name))
        var objects = subscription.objects.makeAsyncIterator()

        let sent = TrackObject(
            group: 3,
            object: 0,
            payload: Data([0xAA, 0xBB, 0xCC]),
            isKeyFrame: true,
            properties: ObjectProperties(
                captureTime: FrameTimestamp(nanoseconds: 1_234_567_000),
                temporalLayer: 1
            )
        )
        try await writer.startGroup(3)
        try await writer.write(sent)

        let received = try #require(await objects.next())
        #expect(received.payload == sent.payload)
        #expect(received.properties.temporalLayer == 1)

        // Microsecond resolution on the wire, so the nanoseconds below a
        // microsecond are not expected to come back.
        #expect(received.properties.captureTime?.nanoseconds == 1_234_567_000)

        await client.close(code: 0, reason: "done")
        await server.close(code: 0, reason: "done")
    }

    @Test("an object with nothing to say does not pay for a properties field")
    func emptyPropertiesAreNotEncoded() throws {
        // Per-object overhead is the budget: at 30fps across four rungs, one
        // extra byte per object is 120 bytes a second of pure framing.
        let bare = SubgroupHeader(trackAlias: 1, group: 0, subgroup: .zero, priority: 64)
        #expect(!bare.propertiesPresent)

        var writer = SubgroupWriter(header: bare)
        let withProperties = ObjectProperties(
            captureTime: FrameTimestamp(nanoseconds: 1000),
            temporalLayer: 0
        )
        #expect(!withProperties.parameters.isEmpty)
        #expect(ObjectProperties().parameters.isEmpty)

        var buffer = WireWriter()
        try writer.write(
            SubgroupObject(object: 0, content: .payload(Data([0x01]))),
            to: &buffer
        )
        // Delta, length, payload. Nothing else.
        #expect(buffer.bytes.count == 3)
    }

    // MARK: - End to end

    @Test("the bytes a subscriber receives are the bytes the encoder produced")
    func encodedBytesReachTheSubscriber() async throws {
        let relay = LoopbackRelay()
        let host = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: credentials("alice"),
            tenant: "acme"
        )
        try await host.connect(to: RelayEndpoint(host: "loopback"))
        let hostRoom = try await host.join(room: "room-42")

        let source = FrameRelay(
            format: CaptureFormat(size: PixelSize(width: 640, height: 360), frameRate: 30),
            depth: 16
        )
        let ladder = LayerLadder(rungs: [
            VideoLayer(
                id: "video/360p",
                size: PixelSize(width: 640, height: 360),
                frameRate: 30,
                bitrate: 600_000
            ),
        ])
        let broadcast = try await hostRoom.startBroadcast(
            from: source,
            configuration: BroadcastConfiguration(
                ladder: ladder,
                encoderFactory: { SyntheticEncoder(configuration: $0) }
            )
        )

        for index in 0 ..< 4 {
            source.submit(
                VideoFrame(
                    timestamp: FrameTimestamp(nanoseconds: UInt64(index) * 33_000_000),
                    size: PixelSize(width: 640, height: 360),
                    surface: .synthetic(byteCount: 640 * 360 * 3 / 2),
                    forcesKeyFrame: index == 0
                )
            )
        }

        #expect(await eventually { await broadcast.stats.objectsPublished == 4 })

        // A keyframe from the synthetic encoder is an order of magnitude larger
        // than a delta frame, which is the shape the old descriptor could not
        // have: it was a constant twenty bytes whatever the picture did.
        let published = await relay.objects(onTrackNamed: "video/360p")
        #expect(published.count == 4)
        #expect(published[0].payload.count > 10_000)
        #expect(published.dropFirst().allSatisfy { $0.payload.count < 10_000 })
        #expect(published[0].isKeyFrame)
        #expect(published[0].group == 0)
        #expect(published.map(\.object) == [0, 1, 2, 3])

        // Presentation time rides with each object, which is what a receiver
        // needs and what the descriptor could only have carried by inventing a
        // payload format nobody else would parse.
        #expect(published[1].properties.captureTime?.nanoseconds == 33_000_000)

        // And the catalog now has something true to say about the rung.
        let configurations = await broadcast.decoderConfigurations
        #expect(configurations["video/360p"] != nil)
    }
}
