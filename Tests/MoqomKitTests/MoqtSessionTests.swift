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

    /// The failure this pairs with is the one nothing used to report: a relay
    /// answers an announcement it accepts with silence, so the only frame it
    /// ever writes on that stream is a refusal, and for a long time nobody read
    /// it. A publisher whose token named a different tenant or room went on
    /// encoding into a namespace the relay had dropped, and every counter in the
    /// app agreed it was live.
    @Test("a refused announcement is reported, and names the namespace")
    func refusedAnnouncement() async throws {
        let (clientCarrier, serverCarrier) = MemoryCarrier.pair()
        let relay = refusingRelay(on: serverCarrier)
        defer { relay.cancel() }

        let client = try await MoqtSession.connect(
            over: clientCarrier,
            credentials: credentials("alice")
        )
        let namespace = try MoqomNamespaces.participant(
            tenant: "acme", room: "room-42", identity: identity("alice")
        )

        // The handle still comes back. There is nothing to wait for on the way
        // in, so refusing to return one would mean blocking every announcement
        // on a timeout to catch the case that usually does not happen.
        let handle = try await client.announce(namespace)

        // `forbidden` rather than `unauthorized`: the token was good enough to
        // establish the session, and it is the namespace it does not cover.
        guard case let .rejected(reason) = await handle.refusal else {
            Issue.record("the refusal was not reported")
            return
        }
        #expect(reason == .forbidden(namespace))

        await client.close(code: 0, reason: "done")
    }

    /// A demotion arrives on the same stream with the same code as a refusal,
    /// because it is the answer the announcement would get if it were made now.
    /// The phrase is what tells them apart, and the difference matters to the
    /// app: one is a token minted for the wrong room, the other is the room
    /// working as intended.
    @Test("an announcement withdrawn by a change of grants reads as revoked")
    func revokedAnnouncement() async throws {
        let (clientCarrier, serverCarrier) = MemoryCarrier.pair()
        let relay = refusingRelay(
            on: serverCarrier,
            reason: "grants changed: this session was not granted publishing"
        )
        defer { relay.cancel() }

        let client = try await MoqtSession.connect(
            over: clientCarrier,
            credentials: credentials("alice")
        )
        let namespace = try MoqomNamespaces.participant(
            tenant: "acme", room: "room-42", identity: identity("alice")
        )
        let handle = try await client.announce(namespace)

        guard case let .rejected(reason) = await handle.refusal else {
            Issue.record("the revocation was not reported")
            return
        }
        #expect(reason == .revoked(namespace))

        await client.close(code: 0, reason: "done")
    }

    /// The other half, and the reason the accepted case has to be checked too: a
    /// peer that acknowledges must not be read as a peer that refused, or every
    /// announcement over a session-to-session link would report a failure.
    @Test("an acknowledged announcement is not reported as a refusal")
    func acknowledgedAnnouncement() async throws {
        let (client, server) = try await connectedPair()
        let namespace = try MoqomNamespaces.participant(
            tenant: "acme", room: "room-42", identity: identity("alice")
        )

        let handle = try await client.announce(namespace)

        // The acknowledgement is not the outcome, since a later change of
        // grants could still revoke the announcement on that stream: the
        // answer stays pending, and is not a refusal.
        let answer = Collector<MoqomError?>()
        let waiting = Task { await answer.append(await handle.refusal) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(await answer.items.isEmpty)

        waiting.cancel()
        await client.close(code: 0, reason: "done")
        await server.close(code: 0, reason: "done")
    }

    /// What a draft-22 relay does to a cohost who goes live: acknowledge the
    /// backstage announcement, then end it when the new token no longer
    /// covers it. Stopping at the acknowledgement would leave the publisher
    /// encoding into a slot the relay had dropped.
    @Test("a revocation after the acknowledgement is still heard")
    func revokedAfterAcknowledgement() async throws {
        let (clientCarrier, serverCarrier) = MemoryCarrier.pair()
        let relay = refusingRelay(
            on: serverCarrier,
            reason: "grants changed: this session is not backstage",
            acknowledgingFirst: true
        )
        defer { relay.cancel() }

        let client = try await MoqtSession.connect(over: clientCarrier, credentials: credentials("alice"))
        let namespace = try MoqomNamespaces.participant(tenant: "acme", room: "room-42", identity: identity("alice"))
        let handle = try await client.announce(namespace)

        guard case let .rejected(reason) = await handle.refusal else {
            Issue.record("the revocation was not reported")
            return
        }
        #expect(reason == .revoked(namespace))
        await client.close(code: 0, reason: "done")
    }

    /// A relay that completes SETUP and then refuses whatever is announced.
    ///
    /// Hand-rolled rather than a second `MoqtSession`, because a session
    /// acknowledges every announcement it is given: a refusal is something only
    /// a peer with a policy ever sends, and there is no policy on this side of
    /// the package to borrow.
    private func refusingRelay(
        on carrier: MemoryCarrier,
        code: UInt64 = RequestErrorCode.unauthorized,
        reason: String = "not your namespace",
        acknowledgingFirst: Bool = false
    ) -> Task<Void, Never> {
        Task {
            for await stream in carrier.incomingBidirectionalStreams {
                Task {
                    var framer = StreamFramer()
                    while let chunk = try? await stream.read() {
                        framer.append(chunk)
                        while let frame = try? framer.next() {
                            switch frame.type {
                            case .setup:
                                try? await Self.write(Setup(), to: stream)
                            case .publishNamespace:
                                if acknowledgingFirst {
                                    try? await Self.write(RequestOk(), to: stream)
                                    try? await Task.sleep(for: .milliseconds(50))
                                }
                                try? await Self.write(
                                    RequestError(code: code, reason: reason),
                                    to: stream
                                )
                            default:
                                break
                            }
                        }
                    }
                }
            }
        }
    }

    private static func write(
        _ message: some ControlMessage,
        to stream: any QUICSendStream
    ) async throws {
        var writer = WireWriter(capacity: message.encodedLength + 8)
        try ControlFrame.write(message, to: &writer)
        try await stream.write(writer.bytes)
    }

    /// A relay closes a session when the token that admitted it runs out, so on
    /// a call longer than a token's lifetime the credential has to be replaced
    /// without reconnecting. Draft-19 carries that as a `REQUEST_UPDATE` with an
    /// authorization token parameter, on a request stream the session already
    /// holds — there is no session-level message for a credential.
    @Test("a renewed credential goes out on a live request stream")
    func renewedCredential() async throws {
        let (clientCarrier, serverCarrier) = MemoryCarrier.pair()
        let heard = Tokens()
        let relay = tokenRecordingRelay(on: serverCarrier, into: heard)
        defer { relay.cancel() }

        let client = try await MoqtSession.connect(
            over: clientCarrier,
            credentials: credentials("alice")
        )

        // A watch, because that is the stream every participant has: it is how
        // anybody learns who else is in the room, whether or not they publish.
        _ = try await client.announcements(
            matching: MoqomNamespaces.room(tenant: "acme", room: "room-42")
        )
        try await client.renewCredential(Data("the-fresh-one".utf8))

        try #require(await heard.first(within: .seconds(2)) == Data("the-fresh-one".utf8))
        await client.close(code: 0, reason: "done")
    }

    /// The failure worth having an error for rather than a silent no-op: renewal
    /// needs somewhere to write, and a session that is announcing nothing and
    /// watching nothing has nowhere. Reporting it is what lets a caller notice
    /// before the relay closes them for a credential they thought they replaced.
    @Test("renewing with no request stream open says so")
    func renewalWithNowhereToGo() async throws {
        let (clientCarrier, serverCarrier) = MemoryCarrier.pair()
        let relay = tokenRecordingRelay(on: serverCarrier, into: Tokens())
        defer { relay.cancel() }

        let client = try await MoqtSession.connect(
            over: clientCarrier,
            credentials: credentials("alice")
        )

        await #expect(throws: MoqomError.self) {
            try await client.renewCredential(Data("nowhere-to-put-this".utf8))
        }
        await client.close(code: 0, reason: "done")
    }

    /// Somewhere for a relay stand-in to put what it heard, since the assertion
    /// happens on one task and the reading on another.
    private actor Tokens {
        private var seen: [Data] = []

        func record(_ token: Data) { seen.append(token) }

        /// The first token heard, waited for rather than polled once: the write
        /// and the read are different tasks and there is no ordering between
        /// them.
        func first(within limit: Duration) async -> Data? {
            let deadline = ContinuousClock.now.advanced(by: limit)
            while ContinuousClock.now < deadline {
                if let first = seen.first { return first }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return seen.first
        }
    }

    /// A relay that completes SETUP and notes the authorization token on every
    /// `REQUEST_UPDATE` it is sent.
    ///
    /// Hand-rolled rather than a second `MoqtSession` for the reason
    /// ``refusingRelay`` is: a session has no credentials to renew and nothing
    /// to check one against, so it would neither read the parameter nor care.
    private func tokenRecordingRelay(
        on carrier: MemoryCarrier,
        into heard: Tokens
    ) -> Task<Void, Never> {
        Task {
            for await stream in carrier.incomingBidirectionalStreams {
                Task {
                    var framer = StreamFramer()
                    while let chunk = try? await stream.read() {
                        framer.append(chunk)
                        while let frame = try? framer.next() {
                            switch frame.type {
                            case .setup:
                                try? await Self.write(Setup(), to: stream)
                            case .requestUpdate:
                                var body = WireReader(frame.body)
                                guard let update = try? RequestUpdate.read(from: &body),
                                      let token = update.parameters
                                      .bytes(RequestParameter.authorizationToken)
                                else { break }
                                await heard.record(token)
                            default:
                                break
                            }
                        }
                    }
                }
            }
        }
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

    /// A PUBLISH the peer sends unasked, which is how a relay reaches a session
    /// that has subscribed to nothing — a participant being force-muted, above
    /// all. Written onto the carrier by hand because there is deliberately no
    /// client API for offering a track: this end only ever receives one.
    @Test("a track the peer pushes arrives as an offer, objects and all")
    func serverInitiatedPublish() async throws {
        let (clientCarrier, serverCarrier) = MemoryCarrier.pair()
        async let accepting = MoqtSession.accept(over: serverCarrier)
        async let dialling = MoqtSession.connect(
            over: clientCarrier,
            credentials: credentials("alice")
        )
        let (server, client) = try await (accepting, dialling)

        let policy = try track(".policy")
        let alias: UInt64 = 9

        let offered = Collector<TrackOffer>()
        let watching = Task {
            for await offer in client.offers { await offered.append(offer) }
        }

        let request = try await serverCarrier.openBidirectionalStream()
        var control = WireWriter(capacity: 128)
        try ControlFrame.write(
            Publish(requestID: 1, track: policy, trackAlias: alias),
            to: &control
        )
        try await request.write(control.bytes)

        #expect(await eventually { await offered.items.count == 1 })
        let offer = try #require(await offered.items.first)
        #expect(offer.track == policy)

        // The objects follow on a unidirectional stream naming the alias the
        // offer chose, which is the half a client cannot infer: nothing it sent
        // ever mentioned this track.
        var body = WireWriter(capacity: 64)
        let header = SubgroupHeader(trackAlias: alias, group: 0, priority: 128)
        header.write(to: &body)
        var subgroup = SubgroupWriter(header: header)
        try subgroup.write(
            SubgroupObject(object: 0, content: .payload(Data("muted".utf8))),
            to: &body
        )
        let data = try await serverCarrier.openUnidirectionalStream()
        try await data.write(body.bytes)

        let received = Collector<TrackObject>()
        let reading = Task {
            for await object in offer.objects { await received.append(object) }
        }
        #expect(await eventually { await received.items.count == 1 })
        #expect(
            await received.items.first.map { String(decoding: $0.payload, as: UTF8.self) }
                == "muted"
        )

        watching.cancel()
        reading.cancel()
        await client.close(code: 0, reason: "done")
        await server.close(code: 0, reason: "done")
    }

    /// A second offer for the same track — a second mute — continues the stream
    /// the consumer is already reading. Handing out a second one would leave a
    /// client choosing between abandoning the first and racing both.
    @Test("re-offering a track keeps the stream the consumer already has")
    func reofferingReusesTheStream() async throws {
        let (clientCarrier, serverCarrier) = MemoryCarrier.pair()
        async let accepting = MoqtSession.accept(over: serverCarrier)
        async let dialling = MoqtSession.connect(
            over: clientCarrier,
            credentials: credentials("alice")
        )
        let (server, client) = try await (accepting, dialling)

        let policy = try track(".policy")
        let offered = Collector<TrackOffer>()
        let watching = Task {
            for await offer in client.offers { await offered.append(offer) }
        }

        let received = Collector<TrackObject>()
        var reading: Task<Void, Never>?

        for (index, alias) in [UInt64(4), UInt64(5)].enumerated() {
            let request = try await serverCarrier.openBidirectionalStream()
            var control = WireWriter(capacity: 128)
            try ControlFrame.write(
                Publish(requestID: UInt64(index) + 1, track: policy, trackAlias: alias),
                to: &control
            )
            try await request.write(control.bytes)

            if index == 0 {
                #expect(await eventually { await offered.items.count == 1 })
                let offer = try #require(await offered.items.first)
                reading = Task {
                    for await object in offer.objects { await received.append(object) }
                }
            }

            var body = WireWriter(capacity: 64)
            let header = SubgroupHeader(trackAlias: alias, group: UInt64(index), priority: 128)
            header.write(to: &body)
            var subgroup = SubgroupWriter(header: header)
            try subgroup.write(
                SubgroupObject(object: 0, content: .payload(Data("policy-\(index)".utf8))),
                to: &body
            )
            let data = try await serverCarrier.openUnidirectionalStream()
            try await data.write(body.bytes)

            #expect(await eventually { await received.items.count == index + 1 })
        }

        #expect(await offered.items.count == 1, "a re-offer started a second stream")
        #expect(
            await received.items.map { String(decoding: $0.payload, as: UTF8.self) }
                == ["policy-0", "policy-1"]
        )

        watching.cancel()
        reading?.cancel()
        await client.close(code: 0, reason: "done")
        await server.close(code: 0, reason: "done")
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
