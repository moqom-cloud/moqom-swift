// A MOQT session in draft-16, for relays that speak nothing later — which
// today means Cloudflare's.
//
// A separate actor rather than a third dialect of `MoqtSession`, because the
// difference is not in the bytes but in where the state lives. Draft-19 and
// draft-22 give every request a bidirectional stream whose lifetime is the
// request's, so the stream is the correlation and closing it is the
// cancellation. Draft-16 puts every request on one shared control stream and
// matches responses by Request ID, ends a subscription with UNSUBSCRIBE and a
// track with PUBLISH_DONE, and flow-controls the IDs themselves with
// MAX_REQUEST_ID. Threading that through `MoqtSession` would put an `if` on
// every request path for a draft that is a compatibility target rather than a
// destination.
//
// What it shares is everything below the control stream: the data plane is
// draft-19's less the FIRST_OBJECT bit, so subgroups and datagrams parse with
// the same types, and a published track writes with the same `PublishedTrack`.
//
// What it leaves out is what the relay lacks. Cloudflare implements no FETCH,
// no REQUEST_UPDATE and no GOAWAY, so catch-up, pausing, priority changes and
// credential renewal either throw ``MoqomError/unsupportedByRelay(feature:relay:)``
// before anything is sent or, where the call has no way to fail, do nothing.
// Nothing MOQOM-specific goes in SETUP: the relay authorises by the token in
// PATH, and a MOQOM token or proof would be bytes it has no use for.

import Foundation
import MoqomCore
import MoqomWire

/// A live draft-16 MOQT session.
public actor Draft16Session: TransportSession {
    private let carrier: any QUICCarrier
    private let endpoint: RelayEndpoint
    private var control: (any QUICStream)?
    private var framer = StreamFramer(draft: .draft16)
    private var parameters: NegotiatedParameters

    /// How many requests this end lets the relay have open at once, and so
    /// how far ahead each MAX_REQUEST_ID grants.
    static let requestWindow: UInt64 = 100

    /// The next Request ID this end will use. Even, because the client's are.
    private var nextRequestID: UInt64 = 0

    /// One more than the largest Request ID the relay will accept from us.
    /// Zero until SERVER_SETUP says otherwise, which is draft-16's default.
    private var peerMaximum: UInt64 = 0

    /// The bound REQUESTS_BLOCKED was last sent for, so it is said once per
    /// bound rather than once per waiting request.
    private var blockedAt: UInt64?
    private var creditWaiters: [CheckedContinuation<Bool, Never>] = []

    /// One more than the largest Request ID this end accepts from the relay.
    private var grantedToPeer: UInt64 = Draft16Session.requestWindow

    /// Requests waiting for SUBSCRIBE_OK, REQUEST_OK or REQUEST_ERROR.
    private var responses: [UInt64: AsyncStream<Response>.Continuation] = [:]

    private enum Response: Sendable {
        case subscribeOk(alias: UInt64)
        case requestOk
        case error(Draft16.RequestError)
    }

    /// Our subscriptions, by Request ID, to the alias the relay assigned.
    private var subscriptions: [UInt64: UInt64] = [:]
    private var inboundTracks: [UInt64: AsyncStream<TrackObject>.Continuation] = [:]

    /// Objects for an alias whose SUBSCRIBE_OK has not been read yet. The
    /// subgroup stream and the response travel separately, so the data can win.
    private var pendingAliases: [UInt64: [TrackObject]] = [:]

    /// Tracks the relay pushed with PUBLISH, by its Request ID.
    private var offeredRequests: [UInt64: FullTrackName] = [:]
    private var offered: [FullTrackName: (alias: UInt64, continuation: AsyncStream<TrackObject>.Continuation)] = [:]

    private var outboundTracks: [FullTrackName: PublishedTrack] = [:]
    private var nextTrackAlias: UInt64 = 0

    /// The relay's subscriptions to our tracks, by its Request ID.
    private var peerSubscriptions: [UInt64: FullTrackName] = [:]

    /// Namespaces we announced, by Request ID, with where to report a refusal.
    private var announced: [UInt64: (namespace: TrackNamespace, verdict: AsyncStream<MoqomError?>.Continuation)] = [:]

    private var readers: [Task<Void, Never>] = []
    private var isClosed = false

    private let interruptionStream: AsyncStream<TransportFailure>
    private let interruptionContinuation: AsyncStream<TransportFailure>.Continuation
    public nonisolated var interruptions: AsyncStream<TransportFailure> { interruptionStream }

    private let offerStream: AsyncStream<TrackOffer>
    private let offerContinuation: AsyncStream<TrackOffer>.Continuation
    public nonisolated var offers: AsyncStream<TrackOffer> { offerStream }

    /// The draft this session speaks, for symmetry with ``MoqtSession/draft``.
    public nonisolated var draft: MoqtDraft { .draft16 }

    init(carrier: any QUICCarrier, endpoint: RelayEndpoint) {
        self.carrier = carrier
        self.endpoint = endpoint
        parameters = NegotiatedParameters(
            alpn: carrier.alpn,
            supportsDatagrams: carrier.maximumDatagramSize > 0,
            maximumDatagramSize: carrier.maximumDatagramSize
        )
        (interruptionStream, interruptionContinuation) = AsyncStream.makeStream(
            of: TransportFailure.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        (offerStream, offerContinuation) = AsyncStream.makeStream(of: TrackOffer.self)
    }

    /// Open a session over a carrier that negotiated `moqt-16`.
    public static func connect(
        over carrier: any QUICCarrier,
        endpoint: RelayEndpoint
    ) async throws(MoqomError) -> Draft16Session {
        let session = Draft16Session(carrier: carrier, endpoint: endpoint)
        try await session.performSetup()
        await session.startReading()
        return session
    }

    public var negotiated: NegotiatedParameters {
        get async { parameters }
    }

    /// The relay, named for an error message.
    private nonisolated var relayName: String {
        switch endpoint.profile {
        case .cloudflare: endpoint.profile.description
        case .moqom: "the draft-16 relay at \(endpoint.host)"
        }
    }

    private func unsupported(_ feature: RelayFeature) -> MoqomError {
        .unsupportedByRelay(feature: feature, relay: relayName)
    }

    // MARK: - Setup

    /// CLIENT_SETUP with AUTHORITY, PATH and MAX_REQUEST_ID, then wait for
    /// SERVER_SETUP.
    ///
    /// AUTHORITY carries the port only when it is not the default, the way a
    /// URL would; PATH carries whatever the endpoint was given, which for
    /// Cloudflare is the token. Nothing else: the relay ignores what it does
    /// not know only if it chooses to, and MOQOM's setup options are no use to
    /// it.
    func performSetup() async throws(MoqomError) {
        let stream = try await carrier.openBidirectionalStream()
        control = stream
        let authority = endpoint.port == 443 ? endpoint.host : "\(endpoint.host):\(endpoint.port)"
        try await send(
            Draft16.ClientSetup(
                authority: authority,
                path: endpoint.path ?? "/",
                maxRequestID: grantedToPeer,
                implementation: "moqom-swift/\(moqomKitVersion)"
            )
        )

        while true {
            if let frame = try framer.nextRaw() {
                guard frame.code == Draft16.MessageCode.serverSetup.rawValue else {
                    await violation("expected SERVER_SETUP, got 0x\(String(frame.code, radix: 16))")
                    throw MoqomError.protocolViolation("expected SERVER_SETUP")
                }
                let setup: Draft16.ServerSetup
                do { setup = try .decode(frame.body, .draft16) } catch {
                    await violation("SERVER_SETUP: \(error)")
                    throw MoqomError.protocolViolation("malformed SERVER_SETUP")
                }
                peerMaximum = setup.maxRequestID
                return
            }
            let chunk: Data?
            do { chunk = try await stream.read() } catch { throw MoqomError.transport(.closed) }
            // A relay that refuses the PATH closes here rather than answering,
            // and the close code is all there is to go on.
            guard let chunk else { throw MoqomError.transport(.closed) }
            framer.append(chunk)
        }
    }

    func startReading() {
        guard readers.isEmpty else { return }
        readers.append(Task { [weak self] in await self?.readControl() })
        readers.append(Task { [weak self] in await self?.readIncomingStreams() })
        readers.append(Task { [weak self] in await self?.readDatagrams() })
        readers.append(Task { [weak self] in await self?.watchCarrier() })
    }

    private func watchCarrier() async {
        for await failure in carrier.loss {
            reportInterruption(failure)
            return
        }
    }

    private var hasReportedInterruption = false

    private func reportInterruption(_ failure: TransportFailure) {
        guard !isClosed, !hasReportedInterruption else { return }
        hasReportedInterruption = true
        interruptionContinuation.yield(failure)
        interruptionContinuation.finish()
    }

    /// Close with PROTOCOL_VIOLATION (0x3), as §3.4 requires of anything the
    /// draft forbids.
    private func violation(_ detail: String) async {
        reportInterruption(.closedByPeer(code: 0x3, reason: "protocol violation: \(detail)"))
        await close(code: 0x3, reason: "protocol violation")
    }

    // MARK: - Request IDs

    /// The next Request ID, waiting for MAX_REQUEST_ID if the relay's grant is
    /// spent.
    ///
    /// Waiting rather than failing, because a relay that grants a small window
    /// is pacing rather than refusing, and REQUESTS_BLOCKED is how it is told
    /// that the pace is the problem. Said once per bound.
    private func allocateRequestID() async throws(MoqomError) -> UInt64 {
        while nextRequestID >= peerMaximum {
            guard !isClosed else { throw MoqomError.transport(.closed) }
            if blockedAt != peerMaximum {
                blockedAt = peerMaximum
                try? await send(Draft16.RequestsBlocked(maximum: peerMaximum))
            }
            let granted = await withCheckedContinuation { creditWaiters.append($0) }
            guard granted else { throw MoqomError.transport(.closed) }
        }
        defer { nextRequestID += 2 }
        return nextRequestID
    }

    private func grant(upTo maximum: UInt64) {
        guard maximum > peerMaximum else { return }
        peerMaximum = maximum
        let waiters = creditWaiters
        creditWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: true) }
    }

    /// Keep the relay's window open: once it has used half of what it was
    /// granted, grant another window from where it is.
    private func noteIncoming(requestID: UInt64) async {
        guard requestID + Self.requestWindow / 2 >= grantedToPeer else { return }
        grantedToPeer = requestID + 1 + Self.requestWindow
        try? await send(Draft16.MaxRequestID(grantedToPeer))
    }

    private func expectResponse(to requestID: UInt64) -> AsyncStream<Response> {
        let (stream, continuation) = AsyncStream.makeStream(of: Response.self, bufferingPolicy: .bufferingNewest(1))
        responses[requestID] = continuation
        return stream
    }

    private func respond(_ requestID: UInt64, _ response: Response) -> Bool {
        guard let continuation = responses.removeValue(forKey: requestID) else { return false }
        continuation.yield(response)
        continuation.finish()
        return true
    }

    /// The single response a request gets, or `nil` if the session ended first.
    private static func first(_ responses: AsyncStream<Response>) async -> Response? {
        for await response in responses { return response }
        return nil
    }

    // MARK: - Control stream

    private func readControl() async {
        guard let control else { return }
        reading: while true {
            while true {
                let frame: RawFrame
                do {
                    guard let next = try framer.nextRaw() else { break }
                    frame = next
                } catch {
                    await violation("\(error)")
                    break reading
                }
                do {
                    try await handle(frame)
                } catch {
                    await violation("0x\(String(frame.code, radix: 16)): \(error)")
                    break reading
                }
            }
            let chunk: Data?
            do { chunk = try await control.read() } catch { break }
            guard let chunk else { break }
            framer.append(chunk)
        }
        // The control stream is the session; losing it is losing the relay.
        reportInterruption(.closed)
        await close(code: 0, reason: "control stream ended")
    }

    private func handle(_ frame: RawFrame) async throws(WireError) {
        typealias Code = Draft16.MessageCode
        let body = frame.body
        switch try Code(code: frame.code) {
        case .maxRequestID:
            grant(upTo: try Draft16.MaxRequestID.decode(body, .draft16).requestID)
        case .requestsBlocked:
            _ = try Draft16.RequestsBlocked.decode(body, .draft16)
            grantedToPeer += Self.requestWindow
            try? await send(Draft16.MaxRequestID(grantedToPeer))
        case .goaway:
            // Asked to move. Reported as an interruption, which is what makes
            // the session above redial, rather than left to the relay's
            // eventual close.
            let goaway = try Draft16.Goaway.decode(body, .draft16)
            reportInterruption(.closedByPeer(code: 0, reason: "GOAWAY \(goaway.newSessionURI)"))
        case .subscribeOk:
            let ok = try Draft16.SubscribeOk.decode(body, .draft16)
            _ = respond(ok.requestID, .subscribeOk(alias: ok.trackAlias))
        case .requestOk:
            let ok = try Draft16.RequestOk.decode(body, .draft16)
            // An accepted announcement has nothing to report until it ends.
            _ = respond(ok.requestID, .requestOk)
        case .requestError:
            let error = try Draft16.RequestError.decode(body, .draft16)
            if !respond(error.requestID, .error(error)), let announcement = announced.removeValue(forKey: error.requestID) {
                announcement.verdict.yield(Self.refusal(error, announcing: announcement.namespace))
                announcement.verdict.finish()
            }
        case .publishNamespaceCancel:
            let cancel = try Draft16.PublishNamespaceCancel.decode(body, .draft16)
            if let announcement = announced.removeValue(forKey: cancel.requestID) {
                announcement.verdict.yield(.rejected(.revoked(announcement.namespace)))
                announcement.verdict.finish()
            }
        case .publishDone:
            let done = try Draft16.PublishDone.decode(body, .draft16)
            if let alias = subscriptions.removeValue(forKey: done.requestID) {
                unregister(alias: alias)
            } else if let track = offeredRequests.removeValue(forKey: done.requestID),
                      let offer = offered.removeValue(forKey: track) {
                inboundTracks.removeValue(forKey: offer.alias)
                pendingAliases.removeValue(forKey: offer.alias)
                offer.continuation.finish()
            }
        case .subscribe:
            let subscribe = try Draft16.Subscribe.decode(body, .draft16)
            await noteIncoming(requestID: subscribe.requestID)
            await answerSubscribe(subscribe)
        case .unsubscribe:
            let unsubscribe = try Draft16.Unsubscribe.decode(body, .draft16)
            if let track = peerSubscriptions.removeValue(forKey: unsubscribe.requestID) {
                await outboundTracks[track]?.removeSubscriber(request: unsubscribe.requestID)
            }
        case .publish:
            let publish = try Draft16.Publish.decode(body, .draft16)
            await noteIncoming(requestID: publish.requestID)
            accept(publish)
            var parameters = Parameters()
            parameters.insert(try! .integer(Draft16.Parameter.forward, 1))
            try? await send(Draft16.PublishOk(requestID: publish.requestID, parameters: parameters))
        case .publishNamespace:
            // A relay forwarding someone's announcement. Acknowledged and
            // otherwise unused: the roster comes from SUBSCRIBE_NAMESPACE.
            let announcement = try Draft16.PublishNamespace.decode(body, .draft16)
            await noteIncoming(requestID: announcement.requestID)
            try? await send(Draft16.RequestOk(requestID: announcement.requestID))
        case .trackStatus:
            let status = try Draft16.TrackStatus.decode(body, .draft16)
            await noteIncoming(requestID: status.requestID)
            await answerTrackStatus(status)
        case .fetch, .requestUpdate:
            // Neither is implemented here, and both begin with the Request ID,
            // which is all a refusal needs.
            var reader = MoqtDraft.draft16.reader(body)
            let requestID = try reader.varInt()
            await noteIncoming(requestID: requestID)
            try? await send(
                Draft16.RequestError(requestID: requestID, code: RequestErrorCode.notSupported, reason: "not supported")
            )
        case .publishNamespaceDone, .namespace, .namespaceDone, .fetchCancel, .fetchOk, .publishOk,
             .clientSetup, .serverSetup, .subscribeNamespace:
            // The relay's to receive, an answer to something this end never
            // sends, or only valid on a stream of its own. §3.4 makes a
            // message in the wrong place a violation.
            throw WireError.invalid("message 0x\(String(frame.code, radix: 16)) on the control stream")
        }
    }

    // MARK: - Data plane

    private func readIncomingStreams() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self, carrier] in
                for await stream in carrier.incomingUnidirectionalStreams {
                    guard let self else { return }
                    Task { await self.readDataStream(stream) }
                }
            }
            group.addTask { [carrier] in
                // Draft-16 relays open none toward a client. Refused rather
                // than ignored, so the relay is not left holding a stream.
                for await stream in carrier.incomingBidirectionalStreams {
                    await stream.stopReceiving(code: 0)
                    await stream.reset(code: 0)
                }
            }
        }
    }

    private func readDatagrams() async {
        for await payload in carrier.datagrams {
            var reader = MoqtDraft.draft16.reader(payload)
            guard let datagram = try? ObjectDatagram.read(from: &reader) else { continue }
            guard case let .payload(bytes, _) = datagram.content else { continue }
            deliver(
                TrackObject(
                    group: datagram.group,
                    object: datagram.object,
                    priority: datagram.priority ?? 128,
                    payload: bytes,
                    isKeyFrame: datagram.object == 0,
                    properties: ObjectProperties(datagram.properties)
                ),
                to: datagram.trackAlias
            )
        }
    }

    private func readDataStream(_ stream: any QUICReceiveStream) async {
        var buffer = Data()
        while true {
            if let kind = StreamType.peek(buffer, draft: .draft16) {
                switch kind {
                case .subgroup: await readSubgroup(stream, first: buffer)
                // Fetch is never asked for, so a fetch stream is not ours.
                case .fetch, .control, .padding: await stream.stopReceiving(code: 0)
                }
                return
            }
            guard buffer.count < 9 else {
                await stream.stopReceiving(code: 0)
                return
            }
            let chunk: Data?
            do { chunk = try await stream.read() } catch { return }
            guard let chunk else { return }
            buffer.append(chunk)
        }
    }

    private func readSubgroup(_ stream: any QUICReceiveStream, first chunk: Data) async {
        var buffer = chunk
        var header: SubgroupHeader?
        var subgroupReader: SubgroupReader?

        while true {
            while true {
                var reader = MoqtDraft.draft16.reader(buffer)
                guard let current = header, var active = subgroupReader else {
                    do {
                        let parsed = try SubgroupHeader.read(from: &reader, draft: .draft16)
                        header = parsed
                        subgroupReader = SubgroupReader(header: parsed)
                        buffer = reader.rest
                        continue
                    } catch {
                        if case .short = error { break }
                        await violation("subgroup header: \(error)")
                        return
                    }
                }
                let object: SubgroupObject
                do {
                    object = try active.read(from: &reader)
                } catch {
                    if case .short = error { break }
                    await violation("subgroup object: \(error)")
                    return
                }
                subgroupReader = active
                buffer = reader.rest
                guard case let .payload(payload) = object.content else { continue }
                deliver(
                    TrackObject(
                        group: current.group,
                        object: object.object,
                        priority: current.priority ?? 128,
                        payload: payload,
                        isKeyFrame: object.object == 0,
                        properties: ObjectProperties(object.properties)
                    ),
                    to: current.trackAlias
                )
            }

            let next: Data?
            do { next = try await stream.read() } catch { return }
            guard let next else { return }
            buffer.append(next)
        }
    }

    private func deliver(_ object: TrackObject, to alias: UInt64) {
        if let continuation = inboundTracks[alias] {
            continuation.yield(object)
            return
        }
        var pending = pendingAliases[alias] ?? []
        if pending.count < 64 {
            pending.append(object)
            pendingAliases[alias] = pending
        }
    }

    private func register(_ continuation: AsyncStream<TrackObject>.Continuation, for alias: UInt64) {
        inboundTracks[alias] = continuation
        if let queued = pendingAliases.removeValue(forKey: alias) {
            for object in queued { continuation.yield(object) }
        }
    }

    private func unregister(alias: UInt64) {
        inboundTracks.removeValue(forKey: alias)?.finish()
        pendingAliases.removeValue(forKey: alias)
    }

    // MARK: - Subscribing

    /// SUBSCRIBE on the control stream, then wait for its answer there.
    ///
    /// ``SubscribeRequest/Start/nextGroup`` is Next Group Start;
    /// ``SubscribeRequest/Start/latestGroup`` sends no filter, which draft-16
    /// defines as unfiltered and which a relay serves from what it has
    /// cached — the only way to get a track's current object when the track
    /// may not publish again, as an init segment does not.
    public func subscribe(
        _ request: SubscribeRequest
    ) async throws(MoqomError) -> any SubscriptionHandle {
        let requestID = try await allocateRequestID()
        var parameters = Parameters()
        parameters.insert(try! .integer(Draft16.Parameter.subscriberPriority, UInt64(request.priority)))
        parameters.insert(try! .integer(Draft16.Parameter.forward, 1))
        if let timeout = request.deliveryTimeout {
            parameters.insert(try! .integer(Draft16.Parameter.deliveryTimeout, UInt64(max(0, timeout.milliseconds))))
        }
        if request.start == .nextGroup {
            parameters.insert(Draft16.SubscriptionFilter.nextGroupStart.parameter)
        }

        let answer = expectResponse(to: requestID)
        try await send(Draft16.Subscribe(requestID: requestID, track: request.track, parameters: parameters))

        switch await Self.first(answer) {
        case let .subscribeOk(alias)?:
            let (objects, continuation) = AsyncStream.makeStream(
                of: TrackObject.self,
                bufferingPolicy: .bufferingNewest(256)
            )
            subscriptions[requestID] = alias
            register(continuation, for: alias)
            return Draft16Subscription(track: request.track, requestID: requestID, objects: objects, session: self)
        case let .error(error)?:
            throw MoqtSession.rejection(for: Self.common(error))
        case .requestOk?:
            throw MoqomError.protocolViolation("REQUEST_OK in answer to SUBSCRIBE")
        case nil:
            throw MoqomError.transport(.closed)
        }
    }

    func unsubscribe(_ requestID: UInt64) async {
        guard let alias = subscriptions.removeValue(forKey: requestID) else { return }
        unregister(alias: alias)
        try? await send(Draft16.Unsubscribe(requestID: requestID))
    }

    /// Draft-16's REQUEST_ERROR in draft-19's shape. The codes the SDK acts on
    /// have the same values in both registries.
    private static func common(_ error: Draft16.RequestError) -> RequestError {
        RequestError(code: error.code, retryInterval: error.retryInterval, reason: error.reason)
    }

    private static func refusal(_ error: Draft16.RequestError, announcing namespace: TrackNamespace) -> MoqomError {
        MoqtSession.refusal(for: common(error), announcing: namespace)
    }

    /// Take delivery of a track the relay pushed, as ``MoqtSession`` does: a
    /// repeated offer of the same track continues the stream already handed out.
    private func accept(_ publish: Draft16.Publish) {
        offeredRequests[publish.requestID] = publish.track
        if let existing = offered[publish.track] {
            inboundTracks.removeValue(forKey: existing.alias)
            pendingAliases.removeValue(forKey: existing.alias)
            offered[publish.track] = (publish.trackAlias, existing.continuation)
            register(existing.continuation, for: publish.trackAlias)
            return
        }
        let (stream, continuation) = AsyncStream.makeStream(of: TrackObject.self)
        offered[publish.track] = (publish.trackAlias, continuation)
        register(continuation, for: publish.trackAlias)
        offerContinuation.yield(TrackOffer(track: publish.track, objects: stream))
    }

    // MARK: - Namespaces

    /// PUBLISH_NAMESPACE, answered by REQUEST_OK or REQUEST_ERROR on the
    /// control stream. Returns at once; ``AnnouncementHandle/refusal`` waits
    /// for the answer, and for a later PUBLISH_NAMESPACE_CANCEL.
    public func announce(
        _ namespace: TrackNamespace
    ) async throws(MoqomError) -> any AnnouncementHandle {
        let requestID = try await allocateRequestID()
        let (verdicts, verdict) = AsyncStream.makeStream(of: MoqomError?.self, bufferingPolicy: .bufferingNewest(1))
        announced[requestID] = (namespace, verdict)
        try await send(Draft16.PublishNamespace(requestID: requestID, namespace: namespace))
        return Draft16Announcement(
            namespace: namespace,
            requestID: requestID,
            verdict: Task {
                for await outcome in verdicts { return outcome }
                return nil
            },
            session: self
        )
    }

    func withdraw(_ requestID: UInt64) async {
        guard let announcement = announced.removeValue(forKey: requestID) else { return }
        announcement.verdict.finish()
        try? await send(Draft16.PublishNamespaceDone(requestID: requestID))
    }

    /// SUBSCRIBE_NAMESPACE on a bidirectional stream of its own, asking for
    /// NAMESPACE and NAMESPACE_DONE only.
    ///
    /// Waits for the relay's REQUEST_OK before returning, so a refused prefix
    /// throws here rather than producing a roster that stays empty.
    public func announcements(
        matching prefix: TrackNamespace
    ) async throws(MoqomError) -> AsyncStream<AnnouncementEvent> {
        let requestID = try await allocateRequestID()
        let stream = try await carrier.openBidirectionalStream()
        var writer = MoqtDraft.draft16.writer()
        do {
            try ControlFrame.write(
                Draft16.SubscribeNamespace(requestID: requestID, prefix: prefix, options: .namespace),
                to: &writer
            )
        } catch {
            throw MoqomError.invalidName(.tooLong)
        }
        try await stream.write(writer.bytes)

        var framer = StreamFramer(draft: .draft16)
        answered: while true {
            while let frame = try framer.nextRaw() {
                switch frame.code {
                case Draft16.MessageCode.requestOk.rawValue:
                    break answered
                case Draft16.MessageCode.requestError.rawValue:
                    await stream.finish()
                    let error = (try? Draft16.RequestError.decode(frame.body, .draft16))
                        ?? Draft16.RequestError(requestID: requestID, code: RequestErrorCode.internalError)
                    throw MoqtSession.rejection(for: Self.common(error))
                default:
                    throw MoqomError.protocolViolation(
                        "expected REQUEST_OK to SUBSCRIBE_NAMESPACE, got 0x\(String(frame.code, radix: 16))"
                    )
                }
            }
            let chunk: Data?
            do { chunk = try await stream.read() } catch { throw MoqomError.transport(.closed) }
            guard let chunk else { throw MoqomError.rejected(.unavailable) }
            framer.append(chunk)
        }

        let (events, continuation) = AsyncStream.makeStream(of: AnnouncementEvent.self, bufferingPolicy: .unbounded)
        let reader = Task { [framer] in
            var framer = framer
            reading: while true {
                while let frame = try? framer.nextRaw() {
                    switch frame.code {
                    case Draft16.MessageCode.namespace.rawValue:
                        guard let announced = try? NamespaceAnnounced.decode(frame.body, .draft16),
                              let full = try? TrackNamespace(prefix.fields + announced.suffix.fields)
                        else { break reading }
                        continuation.yield(.announced(full))
                    case Draft16.MessageCode.namespaceDone.rawValue:
                        // Draft-16 has no reason field; MOQOM's trailing one is
                        // accepted if a relay sends it anyway.
                        guard let done = try? NamespaceDone.decode(frame.body, .draft16),
                              let full = try? TrackNamespace(prefix.fields + done.suffix.fields)
                        else { break reading }
                        continuation.yield(.withdrawn(full, done.reason))
                    default:
                        break reading
                    }
                }
                let chunk: Data?
                do { chunk = try await stream.read() } catch { break }
                guard let chunk else { break }
                framer.append(chunk)
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in
            reader.cancel()
            Task { await stream.finish() }
        }
        return events
    }

    // MARK: - Publishing

    public func publish(
        _ track: FullTrackName,
        priority: UInt8
    ) async throws(MoqomError) -> any TrackWriter {
        let published = outboundTracks[track] ?? PublishedTrack(track: track, priority: priority, draft: .draft16)
        outboundTracks[track] = published
        return Draft16TrackWriter(track: track, published: published, session: self)
    }

    private func answerSubscribe(_ subscribe: Draft16.Subscribe) async {
        guard let track = outboundTracks[subscribe.track] else {
            try? await send(
                Draft16.RequestError(
                    requestID: subscribe.requestID,
                    code: RequestErrorCode.doesNotExist,
                    reason: "no such track"
                )
            )
            return
        }
        let alias = nextTrackAlias
        nextTrackAlias += 1
        var parameters = Parameters()
        if let largest = await track.latestLocation {
            var writer = MoqtDraft.draft16.writer()
            largest.write(to: &writer)
            parameters.insert(try! .bytes(Draft16.Parameter.largestObject, writer.bytes))
        }
        // Registered before the answer goes out, so the first write after the
        // relay hears SUBSCRIBE_OK reaches it. Objects may precede the answer;
        // a subscriber holds them until it learns the alias.
        peerSubscriptions[subscribe.requestID] = subscribe.track
        await track.addSubscriber(alias: alias, request: subscribe.requestID, carrier: carrier)
        try? await send(Draft16.SubscribeOk(requestID: subscribe.requestID, trackAlias: alias, parameters: parameters))
    }

    private func answerTrackStatus(_ status: Draft16.TrackStatus) async {
        guard let track = outboundTracks[status.track] else {
            try? await send(
                Draft16.RequestError(requestID: status.requestID, code: RequestErrorCode.doesNotExist, reason: "no such track")
            )
            return
        }
        var parameters = Parameters()
        if let largest = await track.latestLocation {
            var writer = MoqtDraft.draft16.writer()
            largest.write(to: &writer)
            parameters.insert(try! .bytes(Draft16.Parameter.largestObject, writer.bytes))
        }
        try? await send(Draft16.RequestOk(requestID: status.requestID, parameters: parameters))
    }

    /// End a track: PUBLISH_DONE to each subscriber, with the stream count
    /// the relay needs to know when it has everything.
    func retire(track: FullTrackName) async {
        guard let published = outboundTracks.removeValue(forKey: track) else { return }
        for (request, streams) in await published.finish() {
            peerSubscriptions.removeValue(forKey: request)
            try? await send(
                Draft16.PublishDone(requestID: request, status: Draft16.DoneStatus.trackEnded, streamCount: streams)
            )
        }
    }

    // MARK: - What the relay lacks

    /// Always throws: draft-16 relays implement no FETCH this session can use,
    /// and Cloudflare's none at all. Catch-up degrades to waiting for the next
    /// group.
    public func fetch(_ request: FetchRequest) async throws(MoqomError) -> any FetchHandle {
        throw unsupported(.fetch)
    }

    /// Always throws: the relay authorises once, by PATH, and has no request
    /// that replaces a credential. A token that expires ends the session.
    public func renewCredential(_ token: Data) async throws(MoqomError) {
        throw unsupported(.credentialRenewal)
    }

    // MARK: - Teardown

    public func close(code: UInt64, reason: String) async {
        guard !isClosed else { return }
        isClosed = true
        for reader in readers { reader.cancel() }
        readers.removeAll()
        for waiter in creditWaiters { waiter.resume(returning: false) }
        creditWaiters.removeAll()
        for continuation in responses.values { continuation.finish() }
        responses.removeAll()
        for announcement in announced.values { announcement.verdict.finish() }
        announced.removeAll()
        for continuation in inboundTracks.values { continuation.finish() }
        inboundTracks.removeAll()
        offered.removeAll()
        offerContinuation.finish()
        interruptionContinuation.finish()
        for track in outboundTracks.values { await track.finish() }
        outboundTracks.removeAll()
        await control?.finish()
        await carrier.close(code: code, reason: reason)
    }

    private func send(_ message: some DraftControlMessage) async throws(MoqomError) {
        guard let control else { throw MoqomError.transport(.closed) }
        var writer = MoqtDraft.draft16.writer()
        do {
            try ControlFrame.write(message, to: &writer)
        } catch {
            throw MoqomError.protocolViolation("\(type(of: message)) is too long to frame")
        }
        try await control.write(writer.bytes)
    }
}

// MARK: - Handles

private final class Draft16Subscription: SubscriptionHandle {
    let track: FullTrackName
    let objects: AsyncStream<TrackObject>
    private let requestID: UInt64
    private let session: Draft16Session

    init(track: FullTrackName, requestID: UInt64, objects: AsyncStream<TrackObject>, session: Draft16Session) {
        self.track = track
        self.requestID = requestID
        self.objects = objects
        self.session = session
    }

    /// Nothing: changing a live subscription is REQUEST_UPDATE, which
    /// Cloudflare does not implement. The subscription keeps the priority it
    /// was opened with.
    func updatePriority(_: UInt8) async {}

    /// Nothing, for the same reason. Objects keep flowing; a caller that needs
    /// them stopped cancels instead.
    func updateForwarding(_: Bool) async {}

    func cancel() async {
        await session.unsubscribe(requestID)
    }
}

private final class Draft16Announcement: AnnouncementHandle {
    let namespace: TrackNamespace
    private let requestID: UInt64
    private let verdict: Task<MoqomError?, Never>
    private let session: Draft16Session

    init(namespace: TrackNamespace, requestID: UInt64, verdict: Task<MoqomError?, Never>, session: Draft16Session) {
        self.namespace = namespace
        self.requestID = requestID
        self.verdict = verdict
        self.session = session
    }

    var refusal: MoqomError? {
        get async { await verdict.value }
    }

    func withdraw() async {
        await session.withdraw(requestID)
    }
}

private final class Draft16TrackWriter: TrackWriter {
    let track: FullTrackName
    private let published: PublishedTrack
    private let session: Draft16Session

    init(track: FullTrackName, published: PublishedTrack, session: Draft16Session) {
        self.track = track
        self.published = published
        self.session = session
    }

    func write(_ object: TrackObject) async throws(MoqomError) {
        try await published.write(object)
    }

    func startGroup(_ group: UInt64) async throws(MoqomError) {
        try await published.startGroup(group)
    }

    func finish() async {
        await session.retire(track: track)
    }
}
