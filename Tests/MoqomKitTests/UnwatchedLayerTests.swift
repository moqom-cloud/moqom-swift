// Not encoding rungs nobody is watching.
//
// A four-rung ladder means four hardware encodes of every captured frame, and on a phone that
// is heat and battery spent on pictures no one has asked for. `stopsUnwatchedLayers` exists to
// stop them, and these tests are about the three ways stopping them goes wrong.
//
// The demand set comes from the application. This SDK cannot supply it: which subscriptions
// exist is the relay's knowledge, and nothing carries it back to the publisher. So a publisher
// nobody has told anything must keep publishing everything — going dark because no one filled
// in a set is far worse than the waste it was meant to save, and the first test here is that.
//
// A rung is not dropped the instant its last viewer leaves, because changing rung is an
// unsubscribe followed by a subscribe and a broadcast acting on the instant would tear an
// encoder down and rebuild it inside the same switch.
//
// And a rung coming back opens with a keyframe. Its last object was an arbitrary delta frame,
// so without one the arriving viewer holds a black tile until the encoder's own interval comes
// round — two seconds, after a subscription that looked like it worked.

import Foundation
import Testing

@testable import MoqomCore
@testable import MoqomKit
@testable import MoqomLoopback

@Suite("Rungs nobody is watching")
struct UnwatchedLayerTests {
    private static let ladder = LayerLadder(rungs: [
        VideoLayer(id: "video/180p", size: PixelSize(width: 320, height: 180),
                   frameRate: 30, bitrate: 200_000),
        VideoLayer(id: "video/360p", size: PixelSize(width: 640, height: 360),
                   frameRate: 30, bitrate: 600_000),
        VideoLayer(id: "video/720p", size: PixelSize(width: 1280, height: 720),
                   frameRate: 30, bitrate: 1_800_000),
    ])

    private struct Stage {
        let broadcast: Broadcast
        let source: FrameRelay
        let keyFrames: KeyFrameLedger
    }

    private func stage(stopping: Bool) async throws -> Stage {
        let relay = LoopbackRelay()
        let host = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: credentials("alice"),
            tenant: "acme"
        )
        try await host.connect(to: RelayEndpoint(host: "loopback"))
        let room = try await host.join(room: "room-42")

        let ledger = KeyFrameLedger()
        let source = FrameRelay(
            format: CaptureFormat(size: PixelSize(width: 1280, height: 720), frameRate: 30),
            depth: 64
        )
        let broadcast = try await room.startBroadcast(
            from: source,
            configuration: BroadcastConfiguration(
                ladder: Self.ladder,
                stopsUnwatchedLayers: stopping,
                encoderFactory: { RecordingEncoder(configuration: $0, ledger: ledger) }
            )
        )
        return Stage(broadcast: broadcast, source: source, keyFrames: ledger)
    }

    private func submit(_ source: FrameRelay, _ count: Int, from offset: Int) {
        for index in offset ..< (offset + count) {
            source.submit(
                VideoFrame(
                    timestamp: FrameTimestamp(nanoseconds: UInt64(index) * 33_000_000),
                    size: PixelSize(width: 1280, height: 720),
                    surface: .synthetic(byteCount: 1024),
                    forcesKeyFrame: index == 0
                )
            )
        }
    }

    @Test("a publisher nobody has told anything keeps publishing everything")
    func silenceAboutDemandIsNotAnInstructionToStop() async throws {
        // The case that matters most, because it is the one an integrator reaches by doing
        // nothing. Reading an empty demand set as "nobody is watching" would take a working
        // broadcast off the air the moment this switch was turned on.
        let stage = try await stage(stopping: true)
        submit(stage.source, 8, from: 0)

        #expect(await eventually { await stage.broadcast.stats.objectsPublished >= 8 })
        #expect(await stage.broadcast.stats.activeLayers.count == Self.ladder.rungs.count)
    }

    @Test("the switch off means the demand set is ignored entirely")
    func demandIsIgnoredWhenTheSwitchIsOff() async throws {
        let stage = try await stage(stopping: false)
        await stage.broadcast.setDemandedLayers(["video/180p"], pinned: [])
        submit(stage.source, 8, from: 0)

        #expect(await eventually { await stage.broadcast.stats.objectsPublished >= 8 })
        #expect(await stage.broadcast.stats.activeLayers.count == Self.ladder.rungs.count)
    }

    @Test("a rung nobody wants stops, once its linger is up")
    func unwantedRungsStop() async throws {
        let stage = try await stage(stopping: true)
        await stage.broadcast.setDemandedLayers(["video/360p"], pinned: [])

        // Inside the linger, everything is still being produced: a rung that has just lost its
        // audience has very likely lost it to another rung of the same ladder.
        submit(stage.source, 4, from: 0)
        #expect(await eventually { await stage.broadcast.stats.objectsPublished >= 4 })
        #expect(await stage.broadcast.stats.activeLayers.count == Self.ladder.rungs.count)

        try await Task.sleep(for: Broadcast.lingersUnwatched + .milliseconds(250))
        submit(stage.source, 4, from: 4)

        #expect(await eventually { await stage.broadcast.stats.activeLayers == ["video/360p"] })
    }

    @Test("a pinned rung is produced whether or not anyone is watching it")
    func pinnedRungsSurvive() async throws {
        let stage = try await stage(stopping: true)
        await stage.broadcast.setDemandedLayers([], pinned: ["video/720p"])

        try await Task.sleep(for: Broadcast.lingersUnwatched + .milliseconds(250))
        submit(stage.source, 4, from: 0)

        #expect(await eventually { await stage.broadcast.stats.activeLayers == ["video/720p"] })
    }

    @Test("a rung coming back opens with a keyframe")
    func resumingRungsOpenDecodably() async throws {
        let stage = try await stage(stopping: true)
        await stage.broadcast.setDemandedLayers(["video/360p"], pinned: [])
        try await Task.sleep(for: Broadcast.lingersUnwatched + .milliseconds(250))

        // Long enough that the keyframe interval is nowhere near due, so a keyframe appearing
        // can only be the resume asking for one.
        submit(stage.source, 8, from: 0)
        #expect(await eventually { await stage.broadcast.stats.activeLayers == ["video/360p"] })

        let before = await stage.keyFrames.forced(on: "video/180p")
        await stage.broadcast.setDemandedLayers(["video/360p", "video/180p"], pinned: [])
        submit(stage.source, 4, from: 8)

        #expect(await eventually { await stage.keyFrames.forced(on: "video/180p") > before })
    }

    @Test("a rung that never went dormant is not made to pay for a keyframe")
    func aRungInsideItsLingerResumesQuietly() async throws {
        // The other half of the hysteresis. If a momentary absence still cost a keyframe on
        // return, a viewer stepping between rungs would charge every other viewer of the rung
        // they touched a full picture, which is the expense the linger exists to avoid.
        let stage = try await stage(stopping: true)
        await stage.broadcast.setDemandedLayers(["video/180p", "video/360p"], pinned: [])
        submit(stage.source, 8, from: 0)
        #expect(await eventually { await stage.broadcast.stats.objectsPublished >= 8 })

        let before = await stage.keyFrames.forced(on: "video/180p")
        await stage.broadcast.setDemandedLayers(["video/360p"], pinned: [])
        await stage.broadcast.setDemandedLayers(["video/360p", "video/180p"], pinned: [])
        submit(stage.source, 4, from: 8)

        #expect(await eventually { await stage.broadcast.stats.objectsPublished >= 12 })
        #expect(await stage.keyFrames.forced(on: "video/180p") == before)
    }
}

/// Which rungs were asked for a keyframe, and how often.
private actor KeyFrameLedger {
    private var counts: [LayerID: Int] = [:]

    func note(_ layer: LayerID) { counts[layer, default: 0] += 1 }
    func forced(on layer: LayerID) -> Int { counts[layer] ?? 0 }
}

private final class RecordingEncoder: FrameEncoder, @unchecked Sendable {
    let configuration: EncoderConfiguration
    private(set) var accounting = EncoderAccounting()

    private let inner: SyntheticEncoder
    private let ledger: KeyFrameLedger

    init(configuration: EncoderConfiguration, ledger: KeyFrameLedger) {
        self.configuration = configuration
        self.ledger = ledger
        inner = SyntheticEncoder(configuration: configuration)
    }

    func encode(_ frame: VideoFrame, forcingKeyFrame: Bool) async throws {
        if forcingKeyFrame { await ledger.note(configuration.layer.id) }
        try await inner.encode(frame, forcingKeyFrame: forcingKeyFrame)
        accounting.emitted += 1
    }

    func encodedFrames() -> AsyncStream<EncodedFrame> { inner.encodedFrames() }

    func close() async { await inner.close() }
}
