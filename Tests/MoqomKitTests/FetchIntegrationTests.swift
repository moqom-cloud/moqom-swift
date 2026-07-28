// Fetch, end to end.
//
// Two layers here, and they check different things.
//
// The `MoqtSession` suite runs a real FETCH over a `MemoryCarrier` pair: the
// request is encoded and framed onto a bidirectional stream, the publisher
// answers FETCH_OK on it, opens a unidirectional stream, writes a FETCH_HEADER
// and delta-encoded records, and finishes. That is the only place the fetch
// framing is exercised against a reader that did not encode it.
//
// The `RoomSession` suite checks the thing a user would notice: joining a
// broadcast mid-group and having a decodable frame immediately rather than after
// the next keyframe. It runs over the loopback, because the point is the room's
// behaviour and not the bytes.

import Foundation
import Testing

@testable import MoqomCore
@testable import MoqomKit
@testable import MoqomLoopback
import MoqomWire

@Suite("Fetch over a carrier")
struct FetchTransportTests {
    private func connectedPair() async throws -> (client: MoqtSession, server: MoqtSession) {
        let (clientCarrier, serverCarrier) = MemoryCarrier.pair()
        async let server = MoqtSession.accept(over: serverCarrier)
        async let client = MoqtSession.connect(
            over: clientCarrier,
            credentials: credentials("alice")
        )
        return try await (client, server)
    }

    private func track(_ name: String) throws -> FullTrackName {
        try FullTrackName(
            namespace: MoqomNamespaces.participant(
                tenant: "acme", room: "room-42", identity: identity("alice")
            ),
            name: try TrackName(name)
        )
    }

    /// Publish some history without anyone watching, then fetch it.
    private func published(
        _ locations: [(group: UInt64, object: UInt64)],
        on session: MoqtSession,
        track: FullTrackName
    ) async throws {
        let writer = try await session.publish(track, priority: 64)
        for location in locations {
            try await writer.write(
                TrackObject(
                    group: location.group,
                    object: location.object,
                    priority: 64,
                    payload: Data("\(location.group)-\(location.object)".utf8),
                    isKeyFrame: location.object == 0
                )
            )
        }
    }

    @Test("a fetch returns objects published before the fetcher existed")
    func fetchesHistory() async throws {
        let (publisher, subscriber) = try await connectedPair()
        let track = try track("video/360p")
        try await published([(0, 0), (0, 1), (0, 2)], on: publisher, track: track)

        let fetch = try await subscriber.fetch(
            FetchRequest(
                range: .standalone(
                    track: track,
                    from: Location.group(0),
                    to: .endOfGroup(0)
                )
            )
        )

        var payloads: [String] = []
        for await record in fetch.records {
            guard case let .object(object) = record else { continue }
            payloads.append(String(decoding: object.payload, as: UTF8.self))
        }
        // The stream ending is how a fetch says it is done, so the loop above
        // terminating is itself part of the assertion.
        #expect(payloads == ["0-0", "0-1", "0-2"])

        await publisher.close(code: 0, reason: "done")
        await subscriber.close(code: 0, reason: "done")
    }

    @Test("the served range comes back in FETCH_OK, clamped to what exists")
    func servedRange() async throws {
        let (publisher, subscriber) = try await connectedPair()
        let track = try track("video/360p")
        try await published([(0, 0), (0, 1)], on: publisher, track: track)

        let fetch = try await subscriber.fetch(
            FetchRequest(
                range: .standalone(
                    track: track,
                    from: Location.group(0),
                    // More than exists, which is the normal case: a subscriber
                    // asks for a range it cannot know the end of.
                    to: .through(Location(group: 0, object: 99))
                )
            )
        )

        #expect(await eventually { await fetch.served != nil })
        #expect(await fetch.served == .through(Location(group: 0, object: 1)))

        await publisher.close(code: 0, reason: "done")
        await subscriber.close(code: 0, reason: "done")
    }

    @Test("priority and object numbering survive the fetch encoding")
    func metadataSurvives() async throws {
        let (publisher, subscriber) = try await connectedPair()
        let track = try track("video/360p")

        let writer = try await publisher.publish(track, priority: 64)
        try await writer.write(
            TrackObject(
                group: 3,
                object: 0,
                priority: 12,
                payload: Data([1]),
                isKeyFrame: true,
                properties: ObjectProperties(
                    captureTime: FrameTimestamp(nanoseconds: 5_000_000),
                    temporalLayer: 1
                )
            )
        )

        let fetch = try await subscriber.fetch(
            FetchRequest(
                range: .standalone(track: track, from: Location.group(3), to: .endOfGroup(3))
            )
        )

        var objects: [TrackObject] = []
        for await record in fetch.records {
            guard case let .object(object) = record else { continue }
            objects.append(object)
        }

        #expect(objects.count == 1)
        #expect(objects.first?.group == 3)
        #expect(objects.first?.priority == 12)
        #expect(objects.first?.isKeyFrame == true)
        #expect(objects.first?.properties.temporalLayer == 1)
        #expect(objects.first?.properties.captureTime?.nanoseconds == 5_000_000)

        await publisher.close(code: 0, reason: "done")
        await subscriber.close(code: 0, reason: "done")
    }

    @Test("a fetch spanning groups arrives in group order")
    func acrossGroups() async throws {
        let (publisher, subscriber) = try await connectedPair()
        let track = try track("video/360p")
        try await published([(1, 0), (1, 1), (2, 0), (3, 0)], on: publisher, track: track)

        let fetch = try await subscriber.fetch(
            FetchRequest(
                range: .standalone(track: track, from: Location.group(1), to: .endOfGroup(3))
            )
        )

        var locations: [Location] = []
        for await record in fetch.records {
            guard case let .object(object) = record else { continue }
            locations.append(Location(group: object.group, object: object.object))
        }
        // Only two groups of history are retained by default, so group 1 is
        // gone. What matters is that what did arrive is in order and correctly
        // numbered across the boundary — the group-crossing delta is the part
        // most likely to be wrong.
        #expect(locations == locations.sorted())
        #expect(locations.contains(Location(group: 2, object: 0)))
        #expect(locations.contains(Location(group: 3, object: 0)))

        await publisher.close(code: 0, reason: "done")
        await subscriber.close(code: 0, reason: "done")
    }

    @Test("history is bounded by groups, so a fetch cannot ask for everything")
    func historyIsBounded() async throws {
        let (publisher, subscriber) = try await connectedPair()
        let track = try track("video/360p")
        try await published(
            (0 ..< 10).map { (group: UInt64($0), object: UInt64(0)) },
            on: publisher,
            track: track
        )

        let fetch = try await subscriber.fetch(
            FetchRequest(
                range: .standalone(track: track, from: Location.group(0), to: .endOfGroup(9))
            )
        )

        var groups: [UInt64] = []
        for await record in fetch.records {
            guard case let .object(object) = record else { continue }
            groups.append(object.group)
        }
        // Two groups, and the two most recent. Bounding by groups rather than by
        // objects is deliberate: half a group is history a subscriber cannot
        // decode from.
        #expect(groups == [8, 9])

        await publisher.close(code: 0, reason: "done")
        await subscriber.close(code: 0, reason: "done")
    }

    @Test("a fetch for a track nobody publishes ends rather than hanging")
    func unknownTrack() async throws {
        let (_, subscriber) = try await connectedPair()
        let track = try track("video/360p")

        let fetch = try await subscriber.fetch(
            FetchRequest(
                range: .standalone(track: track, from: Location.group(0), to: .endOfGroup(0))
            )
        )

        // The record stream finishing is the only signal a caller gets, so it
        // has to arrive on the error path too. A fetch that hung here would
        // stall a join behind a track that will never exist.
        var count = 0
        for await _ in fetch.records { count += 1 }
        #expect(count == 0)
        #expect(await fetch.served == nil)
    }

    @Test("a fetch for a range with nothing in it ends rather than hanging")
    func emptyRange() async throws {
        let (publisher, subscriber) = try await connectedPair()
        let track = try track("video/360p")
        try await published([(5, 0)], on: publisher, track: track)

        let fetch = try await subscriber.fetch(
            FetchRequest(
                range: .standalone(track: track, from: Location.group(90), to: .endOfGroup(91))
            )
        )

        var count = 0
        for await _ in fetch.records { count += 1 }
        #expect(count == 0)

        await publisher.close(code: 0, reason: "done")
        await subscriber.close(code: 0, reason: "done")
    }

    @Test("a joining fetch needs a subscription from this session")
    func joiningNeedsOurSubscription() async throws {
        let (publisher, subscriber) = try await connectedPair()
        let (_, other) = try await connectedPair()
        let track = try track("video/360p")
        _ = try await publisher.publish(track, priority: 64)

        let subscription = try await subscriber.subscribe(SubscribeRequest(track: track))

        // A handle from a different session names a request ID that means
        // something else here. Guessing would produce a fetch for the wrong
        // track, which is worse than refusing.
        await #expect(throws: MoqomError.self) {
            _ = try await other.fetch(FetchRequest.catchUp(on: subscription))
        }

        await subscription.cancel()
        await publisher.close(code: 0, reason: "done")
        await subscriber.close(code: 0, reason: "done")
        await other.close(code: 0, reason: "done")
    }

    @Test("a joining fetch is answered from the live edge")
    func joiningIsAnswered() async throws {
        // The one that matters. `RoomSession.catchUp` only ever issues a joining
        // fetch, so until the responder resolved one, catch-up worked over the
        // loopback and silently did nothing over a real session — the failure
        // mode being a black tile on join, with no error anywhere.
        let (publisher, subscriber) = try await connectedPair()
        let track = try track("video/360p")
        try await published([(4, 0), (4, 1), (4, 2)], on: publisher, track: track)

        let subscription = try await subscriber.subscribe(SubscribeRequest(track: track))
        let fetch = try await subscriber.fetch(FetchRequest.catchUp(on: subscription))

        var locations: [Location] = []
        for await record in fetch.records {
            guard case let .object(object) = record else { continue }
            locations.append(Location(group: object.group, object: object.object))
        }

        // The publisher resolved the range itself: the subscriber named a
        // subscription and a group count, never a location.
        #expect(locations == [
            Location(group: 4, object: 0),
            Location(group: 4, object: 1),
            Location(group: 4, object: 2),
        ])

        await subscription.cancel()
        await publisher.close(code: 0, reason: "done")
        await subscriber.close(code: 0, reason: "done")
    }

    @Test("an absolute joining fetch runs from the named group to the live edge")
    func absoluteJoining() async throws {
        let (publisher, subscriber) = try await connectedPair()
        let track = try track("video/360p")
        // Two groups, which is exactly what a publisher retains, so both survive.
        try await published([(6, 0), (6, 1), (7, 0)], on: publisher, track: track)

        let subscription = try await subscriber.subscribe(SubscribeRequest(track: track))
        let fetch = try await subscriber.fetch(
            FetchRequest(range: .joiningFrom(subscription: subscription, group: 7))
        )

        var groups: [UInt64] = []
        for await record in fetch.records {
            guard case let .object(object) = record else { continue }
            groups.append(object.group)
        }
        // Group 6 is retained and deliberately not asked for: this is the seek
        // form, so the start is the caller's and only the end comes from the edge.
        #expect(groups == [7])

        await subscription.cancel()
        await publisher.close(code: 0, reason: "done")
        await subscriber.close(code: 0, reason: "done")
    }

    @Test("an absolute joining fetch starting ahead of the edge is refused")
    func absoluteJoiningPastTheEdge() async throws {
        let (publisher, subscriber) = try await connectedPair()
        let track = try track("video/360p")
        try await published([(2, 0)], on: publisher, track: track)

        let subscription = try await subscriber.subscribe(SubscribeRequest(track: track))
        let fetch = try await subscriber.fetch(
            FetchRequest(range: .joiningFrom(subscription: subscription, group: 50))
        )

        // Refused rather than answered empty, and the stream still ends. A
        // caller cannot distinguish the two from the records alone, which is why
        // termination is the assertion.
        var count = 0
        for await _ in fetch.records { count += 1 }
        #expect(count == 0)
        #expect(await fetch.served == nil)

        await subscription.cancel()
        await publisher.close(code: 0, reason: "done")
        await subscriber.close(code: 0, reason: "done")
    }

    @Test("a hole in retained history comes back as a gap, not as silence")
    func gapsAreReported() async throws {
        // A publisher's history has holes whenever an encoder dropped a frame.
        // Without a marker the subscriber's reassembly waits for object 1
        // forever, which looks like a stalled decoder rather than a lost frame.
        let (publisher, subscriber) = try await connectedPair()
        let track = try track("video/360p")
        try await published([(0, 0), (0, 3)], on: publisher, track: track)

        let fetch = try await subscriber.fetch(
            FetchRequest(
                range: .standalone(track: track, from: Location.group(0), to: .endOfGroup(0))
            )
        )

        var records: [FetchedRecord] = []
        for await record in fetch.records { records.append(record) }

        #expect(records.count == 3)
        // Between the two objects, and naming the last location that does not
        // exist rather than the first that does.
        #expect(records.dropFirst().first == .missing(through: Location(group: 0, object: 2)))

        await publisher.close(code: 0, reason: "done")
        await subscriber.close(code: 0, reason: "done")
    }

    @Test("a descending fetch reports the range it served, not the last thing sent")
    func descendingServedRange() async throws {
        let (publisher, subscriber) = try await connectedPair()
        let track = try track("video/360p")
        try await published([(8, 0), (9, 0)], on: publisher, track: track)

        let fetch = try await subscriber.fetch(
            FetchRequest(
                range: .standalone(track: track, from: Location.group(8), to: .endOfGroup(9)),
                order: .descending
            )
        )

        var groups: [UInt64] = []
        for await record in fetch.records {
            guard case let .object(object) = record else { continue }
            groups.append(object.group)
        }
        #expect(groups == [9, 8])

        // The furthest point of the range, which in descending order is the
        // *first* record rather than the last. Reporting the last would tell the
        // subscriber the range ended where it began.
        #expect(await fetch.served == .through(Location(group: 9, object: 0)))

        await publisher.close(code: 0, reason: "done")
        await subscriber.close(code: 0, reason: "done")
    }
}

@Suite("Fetch over the loopback")
struct FetchLoopbackTests {
    private func session(
        _ relay: LoopbackRelay,
        as name: String
    ) async throws -> LoopbackSession {
        let transport = LoopbackTransport(relay: relay)
        let session = try await transport.connect(
            to: RelayEndpoint(host: "loopback"),
            credentials: credentials(name)
        )
        guard let loopback = session as? LoopbackSession else {
            throw MoqomError.transport(.unreachable)
        }
        return loopback
    }

    private func track(_ name: String) throws -> FullTrackName {
        try FullTrackName(
            namespace: MoqomNamespaces.participant(
                tenant: "acme", room: "room-42", identity: identity("alice")
            ),
            name: try TrackName(name)
        )
    }

    @Test("a joining fetch counts back from where the track actually is")
    func joiningCountsBack() async throws {
        let relay = LoopbackRelay()
        let publisher = try await session(relay, as: "alice")
        let viewer = try await session(relay, as: "bob")
        let track = try track("video/360p")

        let writer = try await publisher.publish(track, priority: 64)
        for group in UInt64(0) ..< 4 {
            for object in UInt64(0) ..< 2 {
                try await writer.write(
                    TrackObject(
                        group: group,
                        object: object,
                        payload: Data([UInt8(group), UInt8(object)]),
                        isKeyFrame: object == 0
                    )
                )
            }
        }

        let subscription = try await viewer.subscribe(SubscribeRequest(track: track))
        let fetch = try await viewer.fetch(FetchRequest.catchUp(on: subscription))

        var groups: [UInt64] = []
        for await record in fetch.records {
            guard case let .object(object) = record else { continue }
            groups.append(object.group)
        }
        // One group back from group 3, so groups 2 and 3. Resolved against the
        // track's position rather than against a number the caller guessed,
        // which is the reason to prefer a joining fetch at all.
        #expect(Set(groups) == [2, 3])
    }

    @Test("a joining fetch on a track with no history is refused")
    func joiningWithoutHistory() async throws {
        let relay = LoopbackRelay()
        let viewer = try await session(relay, as: "bob")
        let track = try track("video/360p")

        let subscription = try await viewer.subscribe(SubscribeRequest(track: track))
        await #expect(throws: MoqomError.self) {
            _ = try await viewer.fetch(FetchRequest.catchUp(on: subscription))
        }
    }

    @Test("a hole in history comes back as missing, not as silence")
    func holesAreReported() async throws {
        let relay = LoopbackRelay()
        let publisher = try await session(relay, as: "alice")
        let viewer = try await session(relay, as: "bob")
        let track = try track("video/360p")

        let writer = try await publisher.publish(track, priority: 64)
        // Objects 1 and 2 were never published. A subscriber that could not tell
        // this from "not yet" would wait for them forever.
        for object in [UInt64(0), 3] {
            try await writer.write(
                TrackObject(
                    group: 0,
                    object: object,
                    payload: Data([UInt8(object)]),
                    isKeyFrame: object == 0
                )
            )
        }

        let fetch = try await viewer.fetch(
            FetchRequest(
                range: .standalone(track: track, from: Location.group(0), to: .endOfGroup(0))
            )
        )

        var records: [FetchedRecord] = []
        for await record in fetch.records { records.append(record) }

        #expect(records.count == 3)
        #expect(records.contains(.missing(through: Location(group: 0, object: 2))))
        guard case .object = records[0], case .missing = records[1] else {
            Issue.record("expected the gap to be reported before the object after it")
            return
        }
    }

    @Test("a descending fetch delivers the newest group first")
    func descending() async throws {
        let relay = LoopbackRelay()
        let publisher = try await session(relay, as: "alice")
        let viewer = try await session(relay, as: "bob")
        let track = try track("video/360p")

        let writer = try await publisher.publish(track, priority: 64)
        for group in UInt64(0) ..< 3 {
            try await writer.write(
                TrackObject(group: group, object: 0, payload: Data([UInt8(group)]))
            )
            try await writer.write(
                TrackObject(group: group, object: 1, payload: Data([UInt8(group)]))
            )
        }

        let fetch = try await viewer.fetch(
            FetchRequest(
                range: .standalone(track: track, from: Location.group(0), to: .endOfGroup(2)),
                order: .descending
            )
        )

        var locations: [Location] = []
        for await record in fetch.records {
            guard case let .object(object) = record else { continue }
            locations.append(Location(group: object.group, object: object.object))
        }
        // Groups descend; objects inside a group still ascend. §10.12.3 is
        // explicit about that, and it is the sort of thing an implementation
        // gets wrong by reversing the whole list.
        #expect(locations == [
            Location(group: 2, object: 0),
            Location(group: 2, object: 1),
            Location(group: 1, object: 0),
            Location(group: 1, object: 1),
            Location(group: 0, object: 0),
            Location(group: 0, object: 1),
        ])
    }
}

@Suite("Catching up on a join")
struct CatchUpTests {
    private let endpoint = RelayEndpoint(host: "loopback", alpn: ["moqt-19"])
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

    /// A host that has gone live and published `count` frames, the first a
    /// keyframe.
    private func broadcasting(
        _ relay: LoopbackRelay,
        frames count: Int
    ) async throws -> RoomSession {
        let host = try await session("alice", relay: relay)
        let room = try await host.join(room: "room-42")
        let source = FrameRelay(format: CaptureFormat(size: rung.size, frameRate: 30), depth: 16)
        _ = try await room.startBroadcast(
            from: source,
            configuration: BroadcastConfiguration(
                ladder: LayerLadder(rungs: [rung]),
                encoderFactory: { SyntheticEncoder(configuration: $0) }
            )
        )
        for index in 0 ..< count {
            source.submit(
                VideoFrame(
                    timestamp: FrameTimestamp(nanoseconds: UInt64(index) * 33_000_000),
                    size: rung.size,
                    surface: .synthetic(byteCount: 512),
                    forcesKeyFrame: index == 0
                )
            )
        }
        return room
    }

    @Test("a viewer joining mid-group gets the group already in progress")
    func joinMidGroup() async throws {
        // Without catch-up, a subscription starts at the *next* group, so a
        // viewer arriving just after a keyframe waits a whole group interval
        // before anything decodes. That is the difference between a tile that
        // fills immediately and one that is black for a second or two.
        let relay = LoopbackRelay()
        let host = try await broadcasting(relay, frames: 5)
        let who = identity("alice")
        #expect(await eventually { await relay.objects(onTrackNamed: "video/360p").count >= 5 })

        let viewer = try await session("bob", relay: relay)
        let viewerRoom = try await viewer.join(room: "room-42")
        #expect(await eventually { await viewerRoom.roster[who] != nil })

        await viewerRoom.updateLayout(
            [who: RenderBox(width: 640, height: 360, scale: 1)],
            linkBitrate: 5_000_000
        )

        // Nothing is published after the viewer arrives, so any frame it
        // produces came out of history.
        #expect(
            await eventually {
                await viewerRoom.videoStatistics(for: who)?.framesProduced ?? 0 > 0
            }
        )
        #expect(
            await relay.recorded {
                if case .fetched = $0 { return true }
                return false
            }
        )

        await host.end()
        await viewerRoom.end()
    }

    @Test("catch-up is off when asked for zero groups")
    func disabled() async throws {
        let relay = LoopbackRelay()
        let host = try await broadcasting(relay, frames: 5)
        let who = identity("alice")
        #expect(await eventually { await relay.objects(onTrackNamed: "video/360p").count >= 5 })

        let viewer = try await session("bob", relay: relay)
        let viewerRoom = try await viewer.join(room: "room-42")
        await viewerRoom.setCatchUpGroups(0)
        #expect(await eventually { await viewerRoom.roster[who] != nil })

        await relay.clearLog()
        await viewerRoom.updateLayout(
            [who: RenderBox(width: 640, height: 360, scale: 1)],
            linkBitrate: 5_000_000
        )

        try await Task.sleep(for: .milliseconds(50))
        #expect(
            await !relay.recorded {
                if case .fetched = $0 { return true }
                return false
            }
        )

        await host.end()
        await viewerRoom.end()
    }

    @Test("a rung change does not refetch history for the rung being left")
    func rungChangeFetchesTheNewRung() async throws {
        // Each rung is its own track, so switching rungs is a new subscription
        // and gets its own catch-up. The thing to avoid is a fetch against the
        // *old* track, which would spend downlink on a bitstream about to be
        // thrown away.
        let relay = LoopbackRelay()
        let host = try await session("alice", relay: relay)
        let hostRoom = try await host.join(room: "room-42")
        let low = rung
        let high = VideoLayer(
            id: "video/720p",
            size: PixelSize(width: 1280, height: 720),
            frameRate: 30,
            bitrate: 2_500_000
        )
        let source = FrameRelay(format: CaptureFormat(size: high.size, frameRate: 30), depth: 16)
        _ = try await hostRoom.startBroadcast(
            from: source,
            configuration: BroadcastConfiguration(
                ladder: LayerLadder(rungs: [low, high]),
                encoderFactory: { SyntheticEncoder(configuration: $0) }
            )
        )
        for index in 0 ..< 4 {
            source.submit(
                VideoFrame(
                    timestamp: FrameTimestamp(nanoseconds: UInt64(index) * 33_000_000),
                    size: high.size,
                    surface: .synthetic(byteCount: 512),
                    forcesKeyFrame: index == 0
                )
            )
        }

        // Both rungs have to have published before the rungs are switched, and
        // waiting for the 360p fetch below does not establish that: each rung
        // has its own encoder and its own drain task, so 720p can still be
        // empty when 360p has four objects. A joining fetch against a track
        // with no history is refused — correctly, there is no position to count
        // back from — so without this the test fails on whichever drain lost
        // the race rather than on the behaviour it is checking.
        #expect(
            await eventually {
                let high = await relay.objects(onTrackNamed: "video/720p")
                let low = await relay.objects(onTrackNamed: "video/360p")
                return !high.isEmpty && !low.isEmpty
            }
        )

        let viewer = try await session("bob", relay: relay)
        let viewerRoom = try await viewer.join(room: "room-42")
        let who = identity("alice")
        #expect(await eventually { await viewerRoom.roster[who] != nil })

        await viewerRoom.updateLayout(
            [who: RenderBox(width: 320, height: 180, scale: 1)],
            linkBitrate: 5_000_000
        )
        #expect(await eventually { await relay.recorded { $0.isFetch(of: "video/360p") } })
        let lowFetches = await relay.log.count { $0.isFetch(of: "video/360p") }

        await viewerRoom.updateLayout(
            [who: RenderBox(width: 1280, height: 720, scale: 1)],
            linkBitrate: 5_000_000
        )

        #expect(await eventually { await relay.recorded { $0.isFetch(of: "video/720p") } })
        // Counted rather than cleared, because clearing the log also clears the
        // relay's history — and a joining fetch with no history to count back
        // from is refused, which would make this pass for the wrong reason.
        #expect(await relay.log.count { $0.isFetch(of: "video/360p") } == lowFetches)

        await hostRoom.end()
        await viewerRoom.end()
    }

    @Test("a replay delivers history on its own stream and terminates")
    func replayIsItsOwnStream() async throws {
        let relay = LoopbackRelay()
        let hostRoom = try await broadcasting(relay, frames: 4)
        let viewer = try await session("bob", relay: relay)
        let viewerRoom = try await viewer.join(room: "room-42")
        let who = identity("alice")

        #expect(await eventually { await viewerRoom.roster[who] != nil })
        #expect(
            await eventually {
                let published = await relay.objects(onTrackNamed: "video/360p")
                return !published.isEmpty
            }
        )
        await viewerRoom.updateLayout(
            [who: RenderBox(width: 640, height: 360, scale: 1)],
            linkBitrate: 5_000_000
        )

        let replay = try #require(await viewerRoom.replay(of: who, lastGroups: 1))

        // The loop terminating is half the assertion: a replay is a finite range
        // and a caller iterating one must not be left waiting on the live edge.
        var frames = 0
        for await _ in replay { frames += 1 }
        #expect(frames > 0)

        // The live stream is untouched by having replayed — it is a different
        // sink with its own reassembly, which is the whole reason replay does not
        // feed `frames(from:)`.
        #expect(await viewerRoom.frames(from: who) != nil)

        await hostRoom.end()
        await viewerRoom.end()
    }

    @Test("a replay of someone nobody is watching is refused rather than guessed")
    func replayNeedsASubscription() async throws {
        // A joining fetch is resolved against a subscription. Without one there
        // is nothing to count back from, and inventing a group number would ask
        // for a range the client has no reason to believe exists.
        let relay = LoopbackRelay()
        let hostRoom = try await broadcasting(relay, frames: 4)
        let viewer = try await session("bob", relay: relay)
        let viewerRoom = try await viewer.join(room: "room-42")
        let who = identity("alice")

        #expect(await eventually { await viewerRoom.roster[who] != nil })

        // In the roster, deliberately never given a layout, so no subscription.
        #expect(await viewerRoom.replay(of: who, lastGroups: 1) == nil)
        #expect(await viewerRoom.replay(of: who, fromGroup: 0) == nil)

        await hostRoom.end()
        await viewerRoom.end()
    }
}

private extension RelayInteraction {
    func isFetch(of name: String) -> Bool {
        guard case let .fetched(track, _, _) = self else { return false }
        return track.name.value == name
    }
}
