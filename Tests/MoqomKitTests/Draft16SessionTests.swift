// `Draft16Session` against a relay driven by hand over a `MemoryCarrier` pair
// that reports `moqt-16`.
//
// Hand-driven rather than a second session, because there is no draft-16
// server in this package and the point is the bytes a Cloudflare relay would
// see: one control stream with requests matched by ID, SUBSCRIBE_NAMESPACE on
// a stream of its own, draft-16 subgroup types, and nothing of MOQOM's in
// SETUP.

import Foundation
import Testing

@testable import MoqomCore
@testable import MoqomKit
@testable import MoqomLoopback
@testable import MoqomWire

@Suite("MOQT session in draft-16")
struct Draft16SessionTests {
    static let endpoint = RelayEndpoint.cloudflare(token: "test-token", host: "relay.example")

    private func connected(
        maxRequestID: UInt64 = 10,
        endpoint: RelayEndpoint = Self.endpoint
    ) async throws -> (session: Draft16Session, relay: ScriptedRelay, setup: Draft16.ClientSetup) {
        let (client, server) = MemoryCarrier.pair(alpn: "moqt-16")
        let relay = ScriptedRelay(server)
        async let setup = relay.acceptSetup(maxRequestID: maxRequestID)
        let session = try await Draft16Session.connect(over: client, endpoint: endpoint)
        return (session, relay, try await setup)
    }

    private func track(_ namespace: [String] = ["bbb"], _ name: String = "1.m4s") throws -> FullTrackName {
        try FullTrackName(namespace: TrackNamespace(namespace), name: TrackName(name))
    }

    @Test("CLIENT_SETUP carries AUTHORITY, PATH and MAX_REQUEST_ID, and nothing of MOQOM's")
    func setup() async throws {
        let (session, _, setup) = try await connected()
        #expect(setup.parameters.string(Draft16.SetupParameter.authority) == "relay.example")
        #expect(setup.parameters.string(Draft16.SetupParameter.path) == "/test-token")
        #expect(setup.parameters.integer(Draft16.SetupParameter.maxRequestID) == Draft16Session.requestWindow)
        #expect(setup.parameters.string(Draft16.SetupParameter.implementation)?.hasPrefix("moqom-swift/") == true)
        #expect(Set(setup.parameters.items.map(\.type)) == [0x1, 0x2, 0x5, 0x7])
        #expect(await session.negotiated.alpn == "moqt-16")
        await session.close(code: 0, reason: "")
    }

    @Test("AUTHORITY names the port only when it is not 443")
    func authorityPort() async throws {
        let endpoint = RelayEndpoint(host: "relay.example", port: 4443, alpn: ["moqt-16"], path: "/p")
        let (session, _, setup) = try await connected(endpoint: endpoint)
        #expect(setup.parameters.string(Draft16.SetupParameter.authority) == "relay.example:4443")
        #expect(setup.parameters.string(Draft16.SetupParameter.path) == "/p")
        await session.close(code: 0, reason: "")
    }

    @Test("MoqtTransport hands a moqt-16 carrier to the draft-16 session")
    func transportDispatch() async throws {
        let (client, server) = MemoryCarrier.pair(alpn: "moqt-16")
        let relay = ScriptedRelay(server)
        async let setup = relay.acceptSetup(maxRequestID: 1)
        let transport = MoqtTransport { _, _ in client }
        let session = try await transport.connect(
            to: Self.endpoint,
            credentials: DeviceCredentials(identity: identity("alice"), token: Data("moqom".utf8), deviceKey: nil)
        )
        let sent = try await setup
        #expect(session is Draft16Session)
        // The MOQOM token is not the relay's credential, and does not go.
        #expect(!sent.parameters.items.contains { $0.bytesValue == Data("moqom".utf8) })
        await session.close(code: 0, reason: "")
    }

    @Test("a subscription is SUBSCRIBE, SUBSCRIBE_OK and objects, and ends with UNSUBSCRIBE")
    func subscribe() async throws {
        let (session, relay, _) = try await connected()
        let name = try track()
        let opened = Task { try await session.subscribe(SubscribeRequest(track: name, priority: 10)) }

        let subscribe = try await relay.expect(Draft16.Subscribe.self)
        #expect(subscribe.requestID == 0)
        #expect(subscribe.track == name)
        #expect(subscribe.parameters.integer(Draft16.Parameter.subscriberPriority) == 10)
        #expect(subscribe.parameters.integer(Draft16.Parameter.forward) == 1)
        #expect(subscribe.parameters.first(Draft16.Parameter.subscriptionFilter) == Draft16.SubscriptionFilter.nextGroupStart.parameter)

        try await relay.send(Draft16.SubscribeOk(requestID: 0, trackAlias: 7))
        let subscription = try await opened.value
        try await relay.sendSubgroup(alias: 7, group: 3, payloads: ["a", "b"])

        var objects = subscription.objects.makeAsyncIterator()
        let first = await objects.next()
        let second = await objects.next()
        #expect(first?.group == 3 && first?.object == 0 && first?.payload == Data("a".utf8))
        #expect(second?.object == 1 && second?.payload == Data("b".utf8))

        await subscription.cancel()
        #expect(try await relay.expect(Draft16.Unsubscribe.self).requestID == 0)
        await session.close(code: 0, reason: "")
    }

    @Test("the latest group is asked for with no filter, which draft-16 calls unfiltered")
    func unfiltered() async throws {
        let (session, relay, _) = try await connected()
        let opened = Task { try await session.subscribe(SubscribeRequest(track: try track(name: "0.mp4"), start: .latestGroup)) }
        let subscribe = try await relay.expect(Draft16.Subscribe.self)
        #expect(subscribe.parameters.first(Draft16.Parameter.subscriptionFilter) == nil)
        try await relay.send(Draft16.SubscribeOk(requestID: subscribe.requestID, trackAlias: 1))
        _ = try await opened.value
        await session.close(code: 0, reason: "")
    }

    @Test("PUBLISH_DONE ends the subscription's objects")
    func publishDone() async throws {
        let (session, relay, _) = try await connected()
        let opened = Task { try await session.subscribe(SubscribeRequest(track: try track())) }
        _ = try await relay.expect(Draft16.Subscribe.self)
        try await relay.send(Draft16.SubscribeOk(requestID: 0, trackAlias: 2))
        let subscription = try await opened.value
        try await relay.send(Draft16.PublishDone(requestID: 0, status: Draft16.DoneStatus.trackEnded, streamCount: 0))
        for await _ in subscription.objects {}
        await session.close(code: 0, reason: "")
    }

    @Test("REQUEST_ERROR for a subscription is a rejection")
    func refused() async throws {
        let (session, relay, _) = try await connected()
        let opened = Task { try await session.subscribe(SubscribeRequest(track: try track())) }
        _ = try await relay.expect(Draft16.Subscribe.self)
        try await relay.send(Draft16.RequestError(requestID: 0, code: RequestErrorCode.unauthorized, reason: "no"))
        guard case let .failure(error) = await opened.result, case let .rejected(reason)? = error as? MoqomError else {
            Issue.record("subscribe was not rejected")
            return
        }
        #expect(reason == .unauthorized)
        await session.close(code: 0, reason: "")
    }

    @Test("a spent request window sends REQUESTS_BLOCKED and waits for MAX_REQUEST_ID")
    func requestFlowControl() async throws {
        let (session, relay, _) = try await connected(maxRequestID: 2)
        let first = Task { try await session.subscribe(SubscribeRequest(track: try track())) }
        #expect(try await relay.expect(Draft16.Subscribe.self).requestID == 0)
        try await relay.send(Draft16.SubscribeOk(requestID: 0, trackAlias: 1))
        _ = try await first.value

        let second = Task { try await session.subscribe(SubscribeRequest(track: try track(name: "2.m4s"))) }
        #expect(try await relay.expect(Draft16.RequestsBlocked.self).maximum == 2)
        try await relay.send(Draft16.MaxRequestID(4))
        #expect(try await relay.expect(Draft16.Subscribe.self).requestID == 2)
        try await relay.send(Draft16.SubscribeOk(requestID: 2, trackAlias: 2))
        _ = try await second.value
        await session.close(code: 0, reason: "")
    }

    @Test("the relay's PUBLISH is answered with PUBLISH_OK and becomes an offer")
    func offer() async throws {
        let (session, relay, _) = try await connected()
        let name = try track(["moqom", "policy"], "mute")
        try await relay.send(Draft16.Publish(requestID: 1, track: name, trackAlias: 4))
        let ok = try await relay.expect(Draft16.PublishOk.self)
        #expect(ok.requestID == 1)
        #expect(ok.parameters.integer(Draft16.Parameter.forward) == 1)

        var offers = session.offers.makeAsyncIterator()
        let offer = await offers.next()
        #expect(offer?.track == name)
        try await relay.sendSubgroup(alias: 4, group: 0, payloads: ["m"])
        var objects = offer?.objects.makeAsyncIterator()
        #expect(await objects?.next()?.payload == Data("m".utf8))
        await session.close(code: 0, reason: "")
    }

    @Test("a namespace watch is its own stream, answered REQUEST_OK, then NAMESPACE and NAMESPACE_DONE")
    func namespaceWatch() async throws {
        let (session, relay, _) = try await connected()
        let prefix = try TrackNamespace(["bbb"])
        let watching = Task { try await session.announcements(matching: prefix) }

        let stream = try await relay.acceptStream()
        var framer = StreamFramer(draft: .draft16)
        let request = try await ScriptedRelay.read(Draft16.SubscribeNamespace.self, from: stream, framer: &framer)
        #expect(request.prefix == prefix)
        #expect(request.options == .namespace)
        try await ScriptedRelay.write(Draft16.RequestOk(requestID: request.requestID), to: stream)
        let events = try await watching.value

        let suffix = try TrackNamespace(["live"])
        var writer = MoqtDraft.draft16.writer()
        try ControlFrame.write(NamespaceAnnounced(suffix: suffix), as: Draft16.MessageCode.namespace.rawValue, to: &writer)
        try ControlFrame.write(NamespaceDone(suffix: suffix), as: Draft16.MessageCode.namespaceDone.rawValue, to: &writer)
        try await stream.write(writer.bytes)

        var iterator = events.makeAsyncIterator()
        let full = try TrackNamespace(["bbb", "live"])
        #expect(await iterator.next() == .announced(full))
        #expect(await iterator.next() == .withdrawn(full, nil))
        await session.close(code: 0, reason: "")
    }

    @Test("publishing: PUBLISH_NAMESPACE, a relay SUBSCRIBE, draft-16 subgroups, and PUBLISH_DONE")
    func publish() async throws {
        let (session, relay, _) = try await connected()
        let namespace = try TrackNamespace(["moqom", "room", "alice"])
        let name = try FullTrackName(namespace: namespace, name: TrackName("video"))

        let announcement = try await session.announce(namespace)
        let announced = try await relay.expect(Draft16.PublishNamespace.self)
        #expect(announced.namespace == namespace)
        #expect(announced.parameters.isEmpty)
        try await relay.send(Draft16.RequestOk(requestID: announced.requestID))

        // Encrypted as a room would: E2EE sits above the transport, so what has
        // to survive draft-16 is the payload and the properties it binds.
        let key = SFrameKey(keyID: 3, baseKey: Data(repeating: 0x42, count: 32))
        let writer = ProtectedTrackWriter(
            wrapping: try await session.publish(name, priority: 64),
            sender: SFrameSender(key: key)
        )
        try await relay.send(Draft16.Subscribe(requestID: 1, track: name))
        let ok = try await relay.expect(Draft16.SubscribeOk.self)
        #expect(ok.requestID == 1)

        let properties = ObjectProperties(captureTime: FrameTimestamp(nanoseconds: 123_456_000))
        try await writer.write(
            TrackObject(group: 0, object: 0, priority: 64, payload: Data("frame".utf8), isKeyFrame: true, properties: properties)
        )
        await writer.finish()

        let (header, objects) = try await relay.receiveSubgroup()
        #expect(header.trackAlias == ok.trackAlias)
        #expect(header.type.bits & SubgroupType.firstObject == 0)
        #expect(objects.count == 1)
        let sealed = try #require(objects.first)
        guard case let .payload(bytes) = sealed.content else {
            Issue.record("not a payload")
            return
        }
        #expect(bytes != Data("frame".utf8))

        let receiver = SFrameReceiver()
        receiver.add(key)
        let opened = await MediaUnprotector(receiver: receiver).unprotect(
            TrackObject(
                group: header.group,
                object: sealed.object,
                priority: header.priority ?? 128,
                payload: bytes,
                properties: ObjectProperties(sealed.properties)
            )
        )
        #expect(opened?.payload == Data("frame".utf8))
        #expect(opened?.properties == properties)

        let done = try await relay.expect(Draft16.PublishDone.self)
        #expect(done.requestID == 1)
        #expect(done.status == Draft16.DoneStatus.trackEnded)
        #expect(done.streamCount == 1)

        await announcement.withdraw()
        #expect(try await relay.expect(Draft16.PublishNamespaceDone.self).requestID == announced.requestID)
        #expect(await announcement.refusal == nil)
        await session.close(code: 0, reason: "")
    }

    @Test("a refused announcement names the namespace")
    func announcementRefused() async throws {
        let (session, relay, _) = try await connected()
        let namespace = try TrackNamespace(["elsewhere"])
        let announcement = try await session.announce(namespace)
        let announced = try await relay.expect(Draft16.PublishNamespace.self)
        try await relay.send(Draft16.RequestError(requestID: announced.requestID, code: RequestErrorCode.unauthorized))
        guard case let .rejected(.forbidden(refused))? = await announcement.refusal else {
            Issue.record("not refused")
            return
        }
        #expect(refused == namespace)
        await session.close(code: 0, reason: "")
    }

    @Test("FETCH and credential renewal fail fast and say which relay lacks them")
    func unsupported() async throws {
        let (session, relay, _) = try await connected()
        let opened = Task { try await session.subscribe(SubscribeRequest(track: try track())) }
        _ = try await relay.expect(Draft16.Subscribe.self)
        try await relay.send(Draft16.SubscribeOk(requestID: 0, trackAlias: 1))
        let subscription = try await opened.value

        let fetchError = await Self.error { _ = try await session.fetch(.catchUp(on: subscription)) }
        #expect(fetchError?.unsupported == .fetch)
        #expect(fetchError?.description == "Cloudflare relay does not support FETCH (catch-up and history)")
        let renewalError = await Self.error { try await session.renewCredential(Data("t".utf8)) }
        #expect(renewalError?.unsupported == .credentialRenewal)

        // Changing a live subscription needs REQUEST_UPDATE; nothing is sent.
        await subscription.updatePriority(1)
        await subscription.updateForwarding(false)
        await subscription.cancel()
        #expect(try await relay.expect(Draft16.Unsubscribe.self).requestID == 0)
        await session.close(code: 0, reason: "")
    }

    @Test("a relay FETCH is refused with NOT_SUPPORTED")
    func peerFetch() async throws {
        let (session, relay, _) = try await connected()
        var frame = MoqtDraft.draft16.writer()
        var body = MoqtDraft.draft16.writer()
        body.varInt(5)
        try ControlFrame.write(typeCode: Draft16.MessageCode.fetch.rawValue, body: body.bytes, to: &frame)
        try await relay.write(frame.bytes)
        let error = try await relay.expect(Draft16.RequestError.self)
        #expect(error.requestID == 5)
        #expect(error.code == RequestErrorCode.notSupported)
        await session.close(code: 0, reason: "")
    }

    @Test("an unknown control message closes the session with PROTOCOL_VIOLATION")
    func unknownMessage() async throws {
        let (session, relay, _) = try await connected()
        var frame = MoqtDraft.draft16.writer()
        try ControlFrame.write(typeCode: 0x77, body: Data(), to: &frame)
        try await relay.write(frame.bytes)
        var interruptions = session.interruptions.makeAsyncIterator()
        guard case let .closedByPeer(code, _)? = await interruptions.next() else {
            Issue.record("no interruption")
            return
        }
        #expect(code == 0x3)
    }

    @Test("the Cloudflare endpoint offers moqt-16 alone and keeps its token out of logs")
    func cloudflareEndpoint() {
        let endpoint = RelayEndpoint.cloudflare(token: "secret-jwt")
        #expect(endpoint.host == "draft-16.cloudflare.mediaoverquic.com")
        #expect(endpoint.port == 443)
        #expect(endpoint.alpn == ["moqt-16"])
        #expect(endpoint.path == "/secret-jwt")
        #expect(endpoint.profile == .cloudflare)
        #expect(endpoint.profile.unsupported == [.fetch, .requestUpdate, .credentialRenewal, .goaway])
        #expect(!endpoint.description.contains("secret-jwt"))
        #expect(RelayProfile.moqom.unsupported.isEmpty)
    }
}

private extension Draft16SessionTests {
    func track(name: String) throws -> FullTrackName {
        try track(["bbb"], name)
    }

    static func error(_ body: () async throws -> Void) async -> MoqomError? {
        do {
            try await body()
            return nil
        } catch {
            return error as? MoqomError
        }
    }
}

private extension MoqomError {
    var unsupported: RelayFeature? {
        guard case let .unsupportedByRelay(feature, _) = self else { return nil }
        return feature
    }
}

/// The relay end of a draft-16 session.
actor ScriptedRelay {
    private let carrier: MemoryCarrier
    private var control: (any QUICStream)?
    private var framer = StreamFramer(draft: .draft16)

    init(_ carrier: MemoryCarrier) {
        self.carrier = carrier
    }

    func acceptSetup(maxRequestID: UInt64) async throws -> Draft16.ClientSetup {
        let stream = try await acceptStream()
        control = stream
        let setup = try await expect(Draft16.ClientSetup.self)
        var parameters = Parameters()
        parameters.insert(try .integer(Draft16.SetupParameter.maxRequestID, maxRequestID))
        try await send(Draft16.ServerSetup(parameters: parameters))
        return setup
    }

    func acceptStream() async throws -> any QUICStream {
        for await stream in carrier.incomingBidirectionalStreams { return stream }
        throw MoqomError.transport(.closed)
    }

    func expect<Message: DraftControlMessage>(_: Message.Type) async throws -> Message {
        guard let control else { throw MoqomError.transport(.closed) }
        while true {
            if let frame = try framer.nextRaw() {
                guard frame.code == Message.typeCode else {
                    throw MoqomError.protocolViolation("expected 0x\(String(Message.typeCode, radix: 16)), got 0x\(String(frame.code, radix: 16))")
                }
                return try Message.decode(frame.body, .draft16)
            }
            guard let chunk = try await control.read() else { throw MoqomError.transport(.closed) }
            framer.append(chunk)
        }
    }

    func send(_ message: some DraftControlMessage) async throws {
        guard let control else { throw MoqomError.transport(.closed) }
        try await Self.write(message, to: control)
    }

    func write(_ bytes: Data) async throws {
        try await control?.write(bytes)
    }

    static func write(_ message: some DraftControlMessage, to stream: any QUICSendStream) async throws {
        var writer = MoqtDraft.draft16.writer()
        try ControlFrame.write(message, to: &writer)
        try await stream.write(writer.bytes)
    }

    static func read<Message: DraftControlMessage>(
        _: Message.Type,
        from stream: any QUICReceiveStream,
        framer: inout StreamFramer
    ) async throws -> Message {
        while true {
            if let frame = try framer.nextRaw() {
                #expect(frame.code == Message.typeCode)
                return try Message.decode(frame.body, .draft16)
            }
            guard let chunk = try await stream.read() else { throw MoqomError.transport(.closed) }
            framer.append(chunk)
        }
    }

    /// One subgroup stream to the client, in draft-16's form.
    func sendSubgroup(alias: UInt64, group: UInt64, payloads: [String]) async throws {
        let header = SubgroupHeader(trackAlias: alias, group: group, priority: 5)
        var writer = MoqtDraft.draft16.writer()
        header.write(to: &writer)
        var subgroup = SubgroupWriter(header: header)
        for (index, payload) in payloads.enumerated() {
            try subgroup.write(SubgroupObject(object: UInt64(index), content: .payload(Data(payload.utf8))), to: &writer)
        }
        let stream = try await carrier.openUnidirectionalStream()
        try await stream.write(writer.bytes)
        await stream.finish()
    }

    /// The next subgroup stream from the client, read to its end.
    func receiveSubgroup() async throws -> (SubgroupHeader, [SubgroupObject]) {
        var stream: (any QUICReceiveStream)?
        for await next in carrier.incomingUnidirectionalStreams {
            stream = next
            break
        }
        guard let stream else { throw MoqomError.transport(.closed) }
        var bytes = Data()
        while let chunk = try await stream.read() { bytes.append(chunk) }

        var reader = MoqtDraft.draft16.reader(bytes)
        let header = try SubgroupHeader.read(from: &reader, draft: .draft16)
        var subgroup = SubgroupReader(header: header)
        var objects: [SubgroupObject] = []
        while !reader.isEmpty { objects.append(try subgroup.read(from: &reader)) }
        return (header, objects)
    }
}
