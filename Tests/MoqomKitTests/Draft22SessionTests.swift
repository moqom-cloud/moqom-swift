// `MoqtSession` speaking draft-22 to itself over a `MemoryCarrier` pair that
// reports `moqt-22`.
//
// The same behaviours `MoqtSessionTests` and `FetchTransportTests` check in
// draft-19, chosen for where the drafts differ: SETUP on unidirectional
// control streams, typed Message Parameters on every request, FETCH_OK's
// inclusive end, joining by fill rather than by Joining FETCH, and a peer that
// sends something §9 forbids being disconnected rather than ignored.

import Foundation
import Testing

@testable import MoqomCore
@testable import MoqomKit
@testable import MoqomLoopback
import MoqomWire

@Suite("MOQT session in draft-22")
struct Draft22SessionTests {
    private func connectedPair(
        token: String = "token-alice"
    ) async throws -> (client: MoqtSession, server: MoqtSession) {
        let (clientCarrier, serverCarrier) = MemoryCarrier.pair(alpn: "moqt-22")
        async let server = MoqtSession.accept(over: serverCarrier)
        async let client = MoqtSession.connect(
            over: clientCarrier,
            credentials: DeviceCredentials(identity: identity("alice"), token: Data(token.utf8), deviceKey: nil)
        )
        return try await (client, server)
    }

    private func track(_ name: String) throws -> FullTrackName {
        try FullTrackName(
            namespace: MoqomNamespaces.participant(tenant: "acme", room: "room-42", identity: identity("alice")),
            name: try TrackName(name)
        )
    }

    private func object(_ group: UInt64, _ object: UInt64) -> TrackObject {
        TrackObject(
            group: group,
            object: object,
            priority: 64,
            payload: Data("\(group)-\(object)".utf8),
            isKeyFrame: object == 0
        )
    }

    @Test("SETUP goes over each end's own control stream")
    func setup() async throws {
        let (client, server) = try await connectedPair()
        #expect(client.draft == .draft22)
        #expect(server.draft == .draft22)
        #expect(await client.negotiated.alpn == "moqt-22")

        // The token arrives as a Token structure, USE_VALUE of type 0, not as
        // draft-19's bare bytes.
        let options = await server.peerSetupOptions
        let token = try AuthorizationToken.decode(
            try #require(options.bytes(SetupOption.authorizationToken)),
            in: .vi64
        )
        #expect(token == .useValue(type: 0, value: Data("token-alice".utf8)))
        #expect(options.string(SetupOption.implementation)?.hasPrefix("moqom-swift/") == true)

        await client.close(code: 0, reason: "done")
        await server.close(code: 0, reason: "done")
    }

    @Test("a subscription resolves to an alias and objects follow it")
    func subscribe() async throws {
        let (subscriber, publisher) = try await connectedPair()
        let track = try track("video/360p")
        let writer = try await publisher.publish(track, priority: 64)

        let subscription = try await subscriber.subscribe(SubscribeRequest(track: track, priority: 10))
        try await writer.write(object(0, 0))
        try await writer.write(object(0, 1))

        var received: [TrackObject] = []
        for await object in subscription.objects {
            received.append(object)
            if received.count == 2 { break }
        }
        #expect(received.map(\.payload) == [Data("0-0".utf8), Data("0-1".utf8)])

        await subscriber.close(code: 0, reason: "done")
        await publisher.close(code: 0, reason: "done")
    }

    @Test("a namespace watch hears an announcement and its withdrawal")
    func announcements() async throws {
        let (client, server) = try await connectedPair()
        let prefix = try MoqomNamespaces.room(tenant: "acme", room: "room-42")
        let namespace = try MoqomNamespaces.participant(tenant: "acme", room: "room-42", identity: identity("alice"))

        let events = try await server.announcements(matching: prefix)
        var iterator = events.makeAsyncIterator()
        let announcement = try await client.announce(namespace)
        #expect(await iterator.next() == .announced(namespace))

        await announcement.withdraw()
        // With its reason: both ends declared MOQOM_PARAMETERS.
        #expect(await iterator.next() == .withdrawn(namespace, .stopped))

        await client.close(code: 0, reason: "done")
        await server.close(code: 0, reason: "done")
    }

    @Test("a standalone fetch serves history and reports an inclusive end")
    func standaloneFetch() async throws {
        let (fetcher, publisher) = try await connectedPair()
        let track = try track("video/360p")
        let writer = try await publisher.publish(track, priority: 64)
        for location in [(0, 0), (0, 1), (0, 2), (1, 0)] as [(UInt64, UInt64)] {
            try await writer.write(object(location.0, location.1))
        }

        let fetch = try await fetcher.fetch(
            FetchRequest(range: .standalone(track: track, from: Location.group(0), to: .through(Location(group: 0, object: 1))))
        )
        var payloads: [Data] = []
        for await record in fetch.records {
            if case let .object(object) = record { payloads.append(object.payload) }
        }
        #expect(payloads == [Data("0-0".utf8), Data("0-1".utf8)])
        #expect(await fetch.served == .through(Location(group: 0, object: 1)))

        await fetcher.close(code: 0, reason: "done")
        await publisher.close(code: 0, reason: "done")
    }

    /// The catch-up a viewer joining mid-group needs, which draft-22 asks for
    /// with FILL_PARAMETERS on the subscription rather than a Joining FETCH.
    @Test("catching up on a subscription is a fill on its own stream")
    func fill() async throws {
        let (subscriber, publisher) = try await connectedPair()
        let track = try track("video/360p")
        let writer = try await publisher.publish(track, priority: 64)
        try await writer.write(object(3, 0))
        try await writer.write(object(3, 1))

        let subscription = try await subscriber.subscribe(SubscribeRequest(track: track, priority: 10))
        let fill = try await subscriber.fetch(.catchUp(on: subscription, groups: 0))

        var payloads: [Data] = []
        for await record in fill.records {
            if case let .object(object) = record { payloads.append(object.payload) }
        }
        #expect(payloads == [Data("3-0".utf8), Data("3-1".utf8)])
        #expect(await fill.served == nil, "a fill has no FETCH_OK")

        await subscriber.close(code: 0, reason: "done")
        await publisher.close(code: 0, reason: "done")
    }

    /// §9.20: a Message Parameter the receiver does not define closes the
    /// session. MOQOM's own proof parameter, from a peer that never declared
    /// MOQOM_PARAMETERS, is the realistic case.
    @Test("an unknown Message Parameter ends the session")
    func unknownParameterCloses() async throws {
        let (raw, serverCarrier) = MemoryCarrier.pair(alpn: "moqt-22")
        async let accepted = MoqtSession.accept(over: serverCarrier)

        let control = try await raw.openUnidirectionalStream()
        var setup = MoqtDraft.draft22.writer()
        try ControlFrame.write(Setup(options: Parameters()), as: Draft22.MessageCode.setup.rawValue, to: &setup)
        try await control.write(setup.bytes)
        let server = try await accepted

        var body = MoqtDraft.draft22.writer()
        body.varInt(0)
        try track("video/360p").write(to: &body)
        body.varInt(1)
        body.varInt(RequestParameter.authorizationProof)
        body.lengthPrefixed(Data([1, 2, 3]))
        var frame = MoqtDraft.draft22.writer()
        try ControlFrame.write(typeCode: Draft22.MessageCode.subscribe.rawValue, body: body.bytes, to: &frame)
        let request = try await raw.openBidirectionalStream()
        try await request.write(frame.bytes)

        var interruptions = server.interruptions.makeAsyncIterator()
        let failure = await interruptions.next()
        guard case let .closedByPeer(code, reason)? = failure else {
            Issue.record("expected the session to end, got \(String(describing: failure))")
            return
        }
        #expect(code == 0x3)
        #expect(reason.contains("unknown message parameter"))
    }

    @Test("two MOQOM ends declare MOQOM_PARAMETERS and both record it")
    func moqomParametersNegotiated() async throws {
        let (client, server) = try await connectedPair()
        #expect(await server.peerSetupOptions.integer(SetupOption.moqomParameters) == 1)
        #expect(await client.peerSetupOptions.integer(SetupOption.moqomParameters) == 1)
        #expect(await client.dialect.moqomParameters)
        #expect(await server.dialect.moqomParameters)

        await client.close(code: 0, reason: "done")
        await server.close(code: 0, reason: "done")
    }

    /// A raw draft-22 peer: its SETUP, then one SUBSCRIBE carrying MOQOM's
    /// private parameters on the stream returned.
    private func subscribeWithPrivateParameters(
        declaring: Bool
    ) async throws -> (server: MoqtSession, request: any QUICStream) {
        let (raw, serverCarrier) = MemoryCarrier.pair(alpn: "moqt-22")
        async let accepted = MoqtSession.accept(over: serverCarrier)

        var options = Parameters()
        if declaring { options.insert(try Parameter.integer(SetupOption.moqomParameters, 1)) }
        let control = try await raw.openUnidirectionalStream()
        var setup = MoqtDraft.draft22.writer()
        try ControlFrame.write(Setup(options: options), as: Draft22.MessageCode.setup.rawValue, to: &setup)
        try await control.write(setup.bytes)
        let server = try await accepted

        // What a relay forwarding a subscription to its publisher sends.
        let subscribe = Draft22.Subscribe(requestID: 0, track: try track("video/360p"), parameters: [
            .subscriberPriority(10), .relayHops(1), .authorizationProof(Data([1, 2, 3])),
        ])
        var frame = MoqtDraft.draft22.writer()
        try ControlFrame.write(subscribe, to: &frame)
        let request = try await raw.openBidirectionalStream()
        try await request.write(frame.bytes)
        return (server, request)
    }

    @Test("a peer that declared MOQOM_PARAMETERS may send RELAY_HOPS and AUTHORIZATION_PROOF")
    func privateParametersAccepted() async throws {
        let (server, request) = try await subscribeWithPrivateParameters(declaring: true)
        #expect(await server.dialect.moqomParameters)
        var framer = StreamFramer(draft: .draft22)
        var reply: RawFrame?
        while reply == nil, let chunk = try await request.read() {
            framer.append(chunk)
            reply = try framer.nextRaw()
        }
        // Answered as any SUBSCRIBE for a track nobody publishes, which is
        // the point: it was read, not refused.
        #expect(reply?.code == Draft22.MessageCode.requestError.rawValue)
        await server.close(code: 0, reason: "done")
    }

    @Test("a peer that did not declare MOQOM_PARAMETERS may not")
    func privateParametersRefused() async throws {
        let (server, _) = try await subscribeWithPrivateParameters(declaring: false)
        #expect(await !server.dialect.moqomParameters)
        var interruptions = server.interruptions.makeAsyncIterator()
        guard case let .closedByPeer(code, reason)? = await interruptions.next() else {
            Issue.record("expected the session to end")
            return
        }
        #expect(code == 0x3)
        #expect(reason.contains("unknown message parameter 0x4d50"))
    }

    /// Encoding, both ways round: NAMESPACE_DONE's reason and a renewal's
    /// proof go only to a peer that agreed to them, and SETUP declares the
    /// agreement only in draft-22.
    @Test("MOQOM's extras are written only once MOQOM_PARAMETERS is agreed")
    func moqomParametersEncoding() throws {
        func frame(_ dialect: SessionDialect, _ message: OutgoingMessage) throws -> RawFrame {
            var framer = dialect.framer()
            framer.append(try dialect.bytes(message))
            return try #require(try framer.nextRaw())
        }
        let suffix = try TrackNamespace(["alice"])
        let renewal = OutgoingMessage.update(requestID: 3, .token(Data("fresh".utf8), proof: Data("proof".utf8)))

        let plain = SessionDialect(.draft22)
        var moqom = SessionDialect(.draft22)
        moqom.moqomParameters = true

        guard case let .namespaceDone(_, reason) = try plain.decode(
            try frame(plain, .namespaceDone(suffix: suffix, reason: .vanished))
        ) else { Issue.record("not NAMESPACE_DONE"); return }
        #expect(reason == nil)
        guard case let .namespaceDone(_, reason) = try moqom.decode(
            try frame(moqom, .namespaceDone(suffix: suffix, reason: .vanished))
        ) else { Issue.record("not NAMESPACE_DONE"); return }
        #expect(reason == .vanished)

        let bare = try Draft22.RequestUpdate.decode(try frame(plain, renewal).body, .draft22)
        #expect(bare.parameters == [.authorizationToken(.useValue(type: 0, value: Data("fresh".utf8)))])
        let proven = try frame(moqom, renewal)
        #expect(try Draft22.RequestUpdate.decode(proven.body, .draft22).parameters == [
            .authorizationToken(.useValue(type: 0, value: Data("fresh".utf8))),
            .authorizationProof(Data("proof".utf8)),
        ])
        // And a session that agreed nothing refuses what one that did sends.
        #expect(throws: WireError.self) { try plain.decode(proven) }

        let setup22 = try Setup.decode(try frame(plain, .setup(token: nil, proof: nil)).body, .draft22)
        #expect(setup22.options.integer(SetupOption.moqomParameters) == 1)
        let draft19 = SessionDialect(.draft19)
        let setup19 = try Setup.decode(try frame(draft19, .setup(token: nil, proof: nil)).body, .draft19)
        #expect(setup19.options.integer(SetupOption.moqomParameters) == nil)
    }

    @Test("a draft-19 peer and a draft-22 one cannot be confused")
    func dialects() {
        #expect(SessionDialect(alpn: "moqt-22").draft == .draft22)
        #expect(SessionDialect(alpn: "moqt-19").draft == .draft19)
        // Draft-16 is a different session, never a dialect of this one.
        #expect(SessionDialect(alpn: "moqt-16").draft == .draft19)
        #expect(SessionDialect(alpn: "h3").draft == .draft19)
    }

    @Test("a relay endpoint offers draft-22 first and draft-19 after it")
    func defaultALPN() {
        #expect(RelayEndpoint(host: "relay.example").alpn == MoqtDraft.moqomPreference.map(\.alpn))
        #expect(RelayEndpoint(host: "relay.example").alpn == ["moqt-22", "moqt-19"])
        #expect(DirectEndpoint.alpn == "moqt-19")
    }
}
