// Muting yourself, end to end.
//
// The interesting claims are not "a flag was set". They are that the bytes
// actually stop, that the room finds out, that coming back does not leave
// viewers holding an undecodable stream, and that none of it takes the
// participant off the stage — because a mute implemented as stop-and-restart
// passes a naive test and produces a visible rejoin in a real room.

import Foundation
import MoqomCore
import Testing

@testable import MoqomKit
@testable import MoqomLoopback

@Suite("Muting yourself")
struct SelfMuteTests {
    private let endpoint = RelayEndpoint(host: "loopback")

    private let rung = VideoLayer(
        id: "video/360p",
        size: PixelSize(width: 640, height: 360),
        frameRate: 30,
        bitrate: 600_000
    )

    private func session(_ name: String, relay: LoopbackRelay) async throws -> MoqomSession {
        let session = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: credentials(name),
            tenant: "acme"
        )
        try await session.connect(to: endpoint)
        return session
    }

    private func submit(_ source: FrameRelay, count: Int, from offset: Int = 0) {
        for index in offset ..< (offset + count) {
            source.submit(
                VideoFrame(
                    timestamp: FrameTimestamp(nanoseconds: UInt64(index) * 33_000_000),
                    size: rung.size,
                    surface: .synthetic(byteCount: 1024),
                    forcesKeyFrame: index == 0
                )
            )
        }
    }

    /// A publisher broadcasting into a loopback relay.
    private func broadcasting(
        _ name: String,
        relay: LoopbackRelay
    ) async throws -> (MoqomSession, RoomSession, Broadcast, FrameRelay) {
        let session = try await session(name, relay: relay)
        let room = try await session.join(room: "room-mute")
        let source = FrameRelay(format: CaptureFormat(size: rung.size, frameRate: 30), depth: 32)
        let broadcast = try await room.startBroadcast(
            from: source,
            configuration: BroadcastConfiguration(
                ladder: LayerLadder(rungs: [rung]),
                encoderFactory: { SyntheticEncoder(configuration: $0) }
            )
        )
        await broadcast.start()
        return (session, room, broadcast, source)
    }

    @Test("a muted camera encodes nothing")
    func mutedVideoStopsAtTheEncoder() async throws {
        let relay = LoopbackRelay()
        let (session, room, broadcast, source) = try await broadcasting("olga", relay: relay)

        submit(source, count: 4)
        _ = await eventually { await broadcast.stats.framesEncoded > 0 }
        let encodedBefore = await broadcast.stats.framesEncoded

        await room.setSelfMuted(.video)
        submit(source, count: 6, from: 4)

        // Given time to be wrong. Asserting immediately would pass whether
        // the frames were suppressed or merely not yet encoded.
        _ = await eventually(timeout: .milliseconds(300)) {
            await broadcast.stats.framesMuted >= 6
        }

        #expect(await broadcast.stats.framesEncoded == encodedBefore)
        #expect(await broadcast.stats.framesMuted >= 6)

        // Still captured, and still counted. A muted publication is not a
        // stalled one and the statistics should not make it look like one.
        #expect(await broadcast.stats.framesSubmitted >= 10)
        withExtendedLifetime(session) {}
    }

    @Test("coming back off mute sends a keyframe rather than resuming mid-group")
    func unmutingResumesWithAKeyFrame() async throws {
        // Without this a viewer gets frames predicting pictures that were never
        // sent, and the artefacts last until whenever the encoder next felt
        // like a keyframe.
        let relay = LoopbackRelay()
        let (session, room, broadcast, source) = try await broadcasting("peter", relay: relay)

        submit(source, count: 4)
        _ = await eventually { await broadcast.stats.framesEncoded > 0 }

        await room.setSelfMuted(.video)
        let groupWhileMuted = await broadcast.stats.currentGroup

        await room.setSelfMuted([])
        #expect(
            await broadcast.stats.currentGroup > groupWhileMuted,
            "unmuting continued a group that has a hole in it"
        )

        // A frame that does not ask for a keyframe. The publication has to
        // be the one insisting, because the capture source has no idea a
        // mute happened.
        source.submit(
            VideoFrame(
                timestamp: FrameTimestamp(nanoseconds: 999_000_000),
                size: rung.size,
                surface: .synthetic(byteCount: 1024),
                forcesKeyFrame: false
            )
        )

        #expect(await eventually { await broadcast.stats.framesEncoded > 4 })
        withExtendedLifetime(session) {}
    }

    @Test("a muted microphone publishes nothing at all, rather than silence")
    func mutedAudioStopsAtTheEncoder() async throws {
        let relay = LoopbackRelay()
        let session = try await session("quinn", relay: relay)
        let room = try await session.join(room: "room-mute")

        let microphone = AudioRelay(format: .voice, depth: 16)
        let publication = try await room.startAudio(from: microphone)
        await publication.start()

        let samples = [Float](repeating: 0.4, count: AudioFormat.voice.samplesPerFrame)
        microphone.submit(AudioFrame(timestamp: FrameTimestamp(nanoseconds: 0), format: .voice, samples: samples))
            _ = await eventually { await publication.stats.packetsPublished > 0 }
            let published = await publication.stats.packetsPublished
            let silent = await publication.stats.silentPackets

        await room.setSelfMuted(.audio)
        for index in 1 ... 5 {
            microphone.submit(
                AudioFrame(
                    timestamp: FrameTimestamp(nanoseconds: UInt64(index) * 20_000_000),
                    format: .voice,
                    samples: samples
                )
            )
        }
        _ = await eventually(timeout: .milliseconds(300)) {
            await publication.stats.framesMuted >= 5
        }

        #expect(await publication.stats.packetsPublished == published)

            // Not comfort noise either. A packet of silence is
            // indistinguishable on the wire from a quiet room, so a viewer
            // handed one could not tell a muted microphone from a still one.
            #expect(await publication.stats.silentPackets == silent)

        // The one that shows up in an interface: a speaking ring left lit
        // on someone who muted mid-sentence.
        #expect(await publication.stats.isSpeaking == false)
        withExtendedLifetime(session) {}
    }

    @Test("the room learns about a mute, without the participant leaving the stage")
    func muteReachesTheOtherSide() async throws {
        let relay = LoopbackRelay()
        let (host, room, _, source) = try await broadcasting("rosa", relay: relay)
        let watcher = try await session("sven", relay: relay)
        let viewerRoom = try await watcher.join(room: "room-mute")

        let who = identity("rosa")
        submit(source, count: 3)
        #expect(await eventually { await viewerRoom.roster[who] != nil })
        #expect(
            await eventually { await viewerRoom.roster[who]?.mute.selfMuted == [] },
            "started out looking muted"
        )

        await room.setSelfMuted([.audio, .video])

        #expect(
            await eventually {
                await viewerRoom.roster[who]?.mute.selfMuted == [.audio, .video]
            },
            "the viewer never found out"
        )

        // The distinction the whole design rests on. A mute that dropped
        // the announcement would take them out of the roster, and the
        // viewer would draw a departure rather than a muted tile.
        #expect(await viewerRoom.roster[who] != nil)
        #expect(await viewerRoom.roster[who]?.mute.reason(for: .audio) == .selfChosen)

        await room.setSelfMuted([])
        #expect(await eventually { await viewerRoom.roster[who]?.mute.selfMuted == [] })
        withExtendedLifetime((host, watcher)) {}
    }

    @Test("muting before the roster has caught up still takes effect")
    func muteBeforeTheRosterArrives() async throws {
        // The "join muted" case, and the one that fails quietly if self-mute is
        // stored on the roster entry: this device's entry is its own
        // announcement arriving back, so for the first moments of a broadcast
        // there is nothing there to set a flag on. Muting into that gap has to
        // be remembered rather than dropped.
        let relay = LoopbackRelay()
        let (session, room, broadcast, _) = try await broadcasting("ursula", relay: relay)
        let me = identity("ursula")

        await room.setSelfMuted([.audio, .video])

        #expect(await room.selfMuted == [.audio, .video])
        #expect(await broadcast.isMuted, "the encoder was never told")

        #expect(
            await eventually { await room.roster[me]?.mute.selfMuted == [.audio, .video] },
            "the roster entry arrived and forgot the mute that preceded it"
        )
        withExtendedLifetime(session) {}
    }

    @Test("a moderator's mute is not something you can lift by unmuting yourself")
    func selfUnmuteDoesNotClearAForcedMute() async throws {
        // Two different features that share a word. If self-unmute touched the
        // forced set, the client would show itself as live while the relay
        // dropped everything it sent.
        let relay = LoopbackRelay()
        let (session, room, _, _) = try await broadcasting("tariq", relay: relay)

        let me = identity("tariq")
        await room.setSelfMuted(.audio)

        // Our own roster entry is our announcement coming back round, so it is
        // not there the instant the broadcast starts, and moderation needs
        // somebody to moderate.
        #expect(await eventually { await room.roster[me] != nil })

        try await room.moderate(
            .forceMute(me, .audio, until: nil),
            as: Grants(publish: .full, moderation: .owner, isOwner: true)
        )
        #expect(await room.roster[me]?.mute.forcedForEveryone == .audio)

        await room.setSelfMuted([])

        #expect(await room.roster[me]?.mute.selfMuted == [])
        #expect(await room.roster[me]?.mute.forcedForEveryone == .audio)
        #expect(await room.roster[me]?.mute.effective.contains(.audio) == true)
        #expect(await room.roster[me]?.mute.reason(for: .audio) == .moderator)
        withExtendedLifetime(session) {}
    }
}

@Suite("Catalog mute field")
struct CatalogMuteTests {
    @Test("a catalog from a build that predates self-mute still decodes")
    func absentMuteIsNotMuted() throws {
        // The compatibility case that matters: refusing the document would take
        // the whole participant off the stage over a key that is not there.
        let json = Data(
            """
            {"tracks":[{"codec":"video/hevc","isPrimary":true,"kind":"video","name":"video/360p"}],\
            "version":1}
            """.utf8
        )

        let catalog = try Catalog.decode(json)
        #expect(catalog.muted == [])
        #expect(catalog.tracks.count == 1)
    }

    @Test("the mute survives a round trip")
    func muteRoundTrips() throws {
        let catalog = Catalog(
            muted: [.audio, .video],
            tracks: [CatalogTrack(name: "audio", kind: .audio, codec: "audio/opus")]
        )
        #expect(try Catalog.decode(catalog.encoded()).muted == [.audio, .video])
    }

    @Test("muting does not remove the track it mutes")
    func mutingKeepsTheTrackOffered() {
        // The property that makes unmuting instant. A catalog that dropped the
        // track would make every viewer unsubscribe, and coming back would be a
        // resubscribe and a wait for the next keyframe rather than a frame.
        let catalog = Catalog.describing(
            BroadcastConfiguration(
                ladder: LayerLadder(rungs: [
                    VideoLayer(
                        id: "video/360p",
                        size: PixelSize(width: 640, height: 360),
                        frameRate: 30,
                        bitrate: 600_000
                    ),
                ])
            ),
            audio: AudioPublicationConfiguration(),
            muted: [.audio, .video]
        )

        #expect(catalog.muted == [.audio, .video])
        #expect(catalog.audioTrack != nil)
        #expect(!catalog.videoLadder.isEmpty)
    }
}
