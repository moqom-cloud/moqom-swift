// The transport, end to end, over real draft-19 bytes.
//
// Two `MoqtSession`s connected by a `MemoryCarrier` pair. Nothing is stubbed
// between them: a SETUP is encoded, framed, written to a pipe, read back,
// decoded, and answered. An announcement is a bidirectional stream held open. A
// subscription resolves to a track alias handed out in SUBSCRIBE_OK, and the
// objects that follow arrive on separate unidirectional streams carrying
// subgroup headers that name that alias.
//
// What this cannot show is behaviour under loss, reordering, or backpressure,
// because the carrier has none of those. That gap belongs to
// `NetworkQUICCarrier`, which has never run.

import Foundation
import Testing

@testable import MoqomCore
@testable import MoqomKit
@testable import MoqomLoopback
import MoqomWire

@Suite("MOQT session over a carrier")
struct MoqtSessionTests {
    /// Two sessions that have completed SETUP with each other.
    private func connectedPair() async throws -> (client: MoqtSession, server: MoqtSession) {
        let (clientCarrier, serverCarrier) = MemoryCarrier.pair()

        // The accepting side has to be waiting before the dialling side sends,
        // which is true of a real listener too.
        async let server = MoqtSession.accept(over: serverCarrier)
        async let client = MoqtSession.connect(
            over: clientCarrier,
            credentials: credentials("alice")
        )
        return try await (client, server)
    }

    private func track(_ name: String, publisher: String = "alice") throws -> FullTrackName {
        try FullTrackName(
            namespace: MoqomNamespaces.participant(
                tenant: "acme", room: "room-42", identity: identity(publisher)
            ),
            name: try TrackName(name)
        )
    }

    @Test("SETUP completes and reports what the handshake settled")
    func setup() async throws {
        let (client, server) = try await connectedPair()

        let negotiated = await client.negotiated
        #expect(negotiated.alpn == "moqt-19")
        #expect(negotiated.supportsDatagrams)
        #expect(negotiated.maximumDatagramSize == 1200)

        // The peer's implementation string proves this was a real exchange
        // rather than a value the client made up from its own configuration.
        let peer = await server.peerSetupOptions
        #expect(peer.string(SetupOption.implementation)?.hasPrefix("moqom-swift/") == true)

        await client.close(code: 0, reason: "done")
        await server.close(code: 0, reason: "done")
    }

    /// The roster, at the protocol level: a participant exists because they
    /// announced, and stops existing because the stream carrying the
    /// announcement closed.
    @Test("an announcement reaches a prefix subscriber, and withdrawal follows it")
    func announcements() async throws {
        let (client, server) = try await connectedPair()
        let prefix = try MoqomNamespaces.room(tenant: "acme", room: "room-42")
        let namespace = try MoqomNamespaces.participant(
            tenant: "acme", room: "room-42", identity: identity("alice")
        )

        let events = try await server.announcements(matching: prefix)
        let collected = Collector<AnnouncementEvent>()
        let reader = Task { for await event in events { await collected.append(event) } }

        // Announced after the watch is open, so this exercises the live update
        // path rather than the initial-state path.
        try await Task.sleep(for: .milliseconds(20))
        let handle = try await client.announce(namespace)

        #expect(await eventually { await collected.items == [.announced(namespace)] })

        // `stopped`, because this withdrawal was asked for. The reason is part of
        // the assertion rather than ignored: it is what a receiver acts on, and a
        // session that reported the wrong one would look identical here without
        // it while making every roster hold seats for people who had left.
        await handle.withdraw()
        #expect(
            await eventually {
                await collected.items == [.announced(namespace), .withdrawn(namespace, .stopped)]
            }
        )

        reader.cancel()
        await client.close(code: 0, reason: "done")
        await server.close(code: 0, reason: "done")
    }

    /// A prefix subscription opened *after* an announcement must still see it.
    /// Getting this wrong produces a client that shows an empty room whenever
    /// it joins second, which is most of the time.
    @Test("a late prefix subscriber is told about what is already announced")
    func lateSubscriberSeesExistingState() async throws {
        let (client, server) = try await connectedPair()
        let prefix = try MoqomNamespaces.room(tenant: "acme", room: "room-42")
        let namespace = try MoqomNamespaces.participant(
            tenant: "acme", room: "room-42", identity: identity("alice")
        )

        _ = try await client.announce(namespace)
        try await Task.sleep(for: .milliseconds(20))

        let events = try await server.announcements(matching: prefix)
        let collected = Collector<AnnouncementEvent>()
        let reader = Task { for await event in events { await collected.append(event) } }

        #expect(await eventually { await collected.items == [.announced(namespace)] })

        reader.cancel()
        await client.close(code: 0, reason: "done")
        await server.close(code: 0, reason: "done")
    }

    /// Objects move: written on one session, encoded as subgroup streams, and
    /// decoded back on the other with group, object and payload intact.
    @Test("objects written to a track arrive at a subscriber")
    func objectsFlow() async throws {
        let (publisher, subscriber) = try await connectedPair()
        let track = try track("video/360p")

        let writer = try await publisher.publish(track, priority: 64)
        let subscription = try await subscriber.subscribe(
            SubscribeRequest(track: track, priority: 16)
        )

        let received = Collector<TrackObject>()
        let reader = Task {
            for await object in subscription.objects { await received.append(object) }
        }

        // A pause because a subscription is not usable the instant it returns:
        // the peer has to see SUBSCRIBE and register the subscriber before a
        // write has anywhere to go. That is a real property of the protocol,
        // not an artefact of the carrier.
        #expect(await eventually { await publisher.hasSubscriber(for: track) })

        for index in 0 ..< 3 {
            try await writer.write(
                TrackObject(
                    group: 0,
                    object: UInt64(index),
                    priority: 64,
                    payload: Data("frame-\(index)".utf8),
                    isKeyFrame: index == 0
                )
            )
        }

        #expect(await eventually { await received.items.count == 3 })
        let objects = await received.items.sorted { $0.object < $1.object }
        #expect(objects.map(\.object) == [0, 1, 2])
        #expect(objects.map { String(decoding: $0.payload, as: UTF8.self) }
            == ["frame-0", "frame-1", "frame-2"])
        #expect(objects.allSatisfy { $0.priority == 64 })

        reader.cancel()
        await subscription.cancel()
        await publisher.close(code: 0, reason: "done")
        await subscriber.close(code: 0, reason: "done")
    }

    /// Each group is its own subgroup stream, which is what lets a relay drop a
    /// whole group by resetting one stream. The visible consequence here is
    /// that object IDs restart per group and both groups still arrive.
    @Test("a new group opens a new stream and both groups arrive")
    func groupsAreSeparateStreams() async throws {
        let (publisher, subscriber) = try await connectedPair()
        let track = try track("video/360p")

        let writer = try await publisher.publish(track, priority: 64)
        let subscription = try await subscriber.subscribe(SubscribeRequest(track: track))

        let received = Collector<TrackObject>()
        let reader = Task {
            for await object in subscription.objects { await received.append(object) }
        }
        #expect(await eventually { await publisher.hasSubscriber(for: track) })

        try await writer.write(TrackObject(group: 0, object: 0, payload: Data("a".utf8)))
        try await writer.startGroup(1)
        try await writer.write(TrackObject(group: 1, object: 0, payload: Data("b".utf8)))

        #expect(await eventually { await received.items.count == 2 })
        let groups = Set(await received.items.map(\.group))
        #expect(groups == [0, 1])

        reader.cancel()
        await publisher.close(code: 0, reason: "done")
        await subscriber.close(code: 0, reason: "done")
    }

    /// A payload that survives the round trip unchanged at a size that spans
    /// several carrier writes, since a framer that reassembles incorrectly
    /// still works for small messages.
    @Test("a large payload is reassembled exactly")
    func largePayload() async throws {
        let (publisher, subscriber) = try await connectedPair()
        let track = try track("video/1080p")

        let writer = try await publisher.publish(track, priority: 64)
        let subscription = try await subscriber.subscribe(SubscribeRequest(track: track))

        let received = Collector<TrackObject>()
        let reader = Task {
            for await object in subscription.objects { await received.append(object) }
        }
        #expect(await eventually { await publisher.hasSubscriber(for: track) })

        var payload = Data(count: 200_000)
        for index in payload.indices { payload[index] = UInt8(index % 251) }
        try await writer.write(TrackObject(group: 0, object: 0, payload: payload))

        #expect(await eventually { await received.items.count == 1 })
        #expect(await received.items.first?.payload == payload)

        reader.cancel()
        await publisher.close(code: 0, reason: "done")
        await subscriber.close(code: 0, reason: "done")
    }

    @Test("subscribing to a track nobody publishes is refused")
    func unknownTrack() async throws {
        let (_, subscriber) = try await connectedPair()
        let track = try track("video/360p")

        await #expect(throws: MoqomError.self) {
            _ = try await subscriber.subscribe(SubscribeRequest(track: track))
        }
    }

    /// Writing with nobody subscribed is not an error — it is the normal state
    /// of a broadcast whose viewers have not arrived — but it has to be
    /// countable, because "the relay never subscribed" and "the encoder
    /// produced nothing" look identical from outside.
    @Test("objects written with no subscriber are counted rather than failing")
    func writesWithoutSubscribers() async throws {
        let (publisher, _) = try await connectedPair()
        let track = try track("video/360p")
        let writer = try await publisher.publish(track, priority: 64)

        try await writer.write(TrackObject(group: 0, object: 0, payload: Data([1])))
        try await writer.write(TrackObject(group: 0, object: 1, payload: Data([2])))

        #expect(await publisher.objectsWithoutSubscribers(for: track) == 2)
    }

    @Test("closing a session ends its subscriptions rather than hanging them")
    func closeEndsSubscriptions() async throws {
        let (publisher, subscriber) = try await connectedPair()
        let track = try track("video/360p")

        _ = try await publisher.publish(track, priority: 64)
        let subscription = try await subscriber.subscribe(SubscribeRequest(track: track))

        let finished = Collector<Bool>()
        let reader = Task {
            for await _ in subscription.objects {}
            await finished.append(true)
        }

        await subscriber.close(code: 0, reason: "leaving")
        #expect(await eventually { await finished.items == [true] })

        reader.cancel()
        await publisher.close(code: 0, reason: "done")
    }
}

/// Somewhere for a reading task to put what it received.
actor Collector<Element: Sendable> {
    private(set) var items: [Element] = []
    func append(_ item: Element) { items.append(item) }
}

extension MoqtSession {
    /// Test-only introspection, so the assertions can be about the protocol
    /// rather than about how long a handshake happened to take.
    func hasSubscriber(for track: FullTrackName) async -> Bool {
        guard let published = publishedTrack(track) else { return false }
        return await published.hasSubscribers
    }

    func objectsWithoutSubscribers(for track: FullTrackName) async -> Int {
        guard let published = publishedTrack(track) else { return 0 }
        return await published.objectsWithoutSubscribers
    }
}
