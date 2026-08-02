// A real MOQT session, over any carrier.
//
// The shape of this file is dictated by one draft-19 decision that is easy to
// read past: there is no UNSUBSCRIBE and no UNANNOUNCE, because every request
// owns a bidirectional stream and lives exactly as long as that stream does.
// So an announcement is not a message we send and later retract — it is a
// stream we hold open, and withdrawing it is `finish()`. A subscription is the
// same. Nearly every handle type below is therefore a wrapper around a stream
// whose lifetime *is* the protocol state, which is why they are classes with
// deinit-adjacent semantics rather than value types.
//
// The other structural fact: control and data are separate. Requests and their
// responses go on bidirectional streams; objects arrive on unidirectional
// streams and datagrams that carry a *track alias* rather than a track name.
// The alias is handed out in SUBSCRIBE_OK, which means a subgroup can arrive
// for an alias we have not learned yet if the peer is fast. `pendingAliases`
// exists for exactly that race and is the piece most likely to be missing from
// an implementation that was only ever tested against a slow peer.

import Foundation
import MoqomCore
import MoqomWire

/// Opens MOQT sessions over a QUIC carrier.
public struct MoqtTransport: Transport {
    /// Produces a carrier for an endpoint.
    ///
    /// A closure rather than a protocol so that tests, the loopback, and
    /// Network.framework all plug in without a common supertype that would
    /// only ever have one method.
    public typealias Dial = @Sendable (RelayEndpoint, DeviceCredentials) async throws -> any QUICCarrier

    private let dial: Dial

    public init(dial: @escaping Dial) {
        self.dial = dial
    }

    public func connect(
        to endpoint: RelayEndpoint,
        credentials: DeviceCredentials
    ) async throws(MoqomError) -> any TransportSession {
        let carrier: any QUICCarrier
        do {
            carrier = try await dial(endpoint, credentials)
        } catch let error as MoqomError {
            throw error
        } catch {
            throw MoqomError.transport(.unreachable)
        }

        let session = MoqtSession(carrier: carrier, role: .client)
        try await session.performSetup(credentials: credentials)
        await session.startReading()
        return session
    }
}

/// Which side of a session an endpoint is.
///
/// Only used for request ID parity, but it has to be right: the peer rejects an
/// ID whose parity says it came from the other end, and the failure surfaces as
/// an unexplained protocol error much later.
public enum SessionRole: Sendable {
    case client
    case server

    var firstRequestID: UInt64 {
        switch self {
        case .client: 0
        case .server: 1
        }
    }
}

/// A live MOQT session.
public actor MoqtSession: TransportSession {
    private let carrier: any QUICCarrier
    private let role: SessionRole

    private var parameters: NegotiatedParameters
    private var nextRequestID: UInt64
    private var nextTrackAlias: UInt64 = 0

    /// Subscriptions we have opened, keyed by the alias the peer assigned.
    private var inboundTracks: [UInt64: AsyncStream<TrackObject>.Continuation] = [:]

    /// Objects that arrived for an alias before SUBSCRIBE_OK did.
    ///
    /// A subgroup stream can legally overtake the response that names its
    /// alias, since they are different streams. Dropping those objects loses
    /// the first frames of every subscription on a fast path, which reads as
    /// "the first second is always black" rather than as a bug.
    private var pendingAliases: [UInt64: [TrackObject]] = [:]

    /// Tracks we are publishing, by name.
    private var outboundTracks: [FullTrackName: PublishedTrack] = [:]

    private var readers: [Task<Void, Never>] = []
    private var isClosed = false

    private let interruptionStream: AsyncStream<TransportFailure>
    private let interruptionContinuation: AsyncStream<TransportFailure>.Continuation
    private var hasReportedInterruption = false

    public nonisolated var interruptions: AsyncStream<TransportFailure> { interruptionStream }

    init(carrier: any QUICCarrier, role: SessionRole) {
        self.carrier = carrier
        self.role = role
        nextRequestID = role.firstRequestID
        parameters = NegotiatedParameters(
            alpn: carrier.alpn,
            supportsDatagrams: carrier.maximumDatagramSize > 0,
            maximumDatagramSize: carrier.maximumDatagramSize
        )
        // Buffered rather than dropping, because there is exactly one of these
        // per session and the consumer may not be iterating yet when it fires:
        // a connection that dies during the first join would otherwise lose the
        // only notification it will ever get.
        (interruptionStream, interruptionContinuation) = AsyncStream.makeStream(
            of: TransportFailure.self,
            bufferingPolicy: .bufferingNewest(1)
        )
    }

    /// Report that the session has ended on its own, once.
    ///
    /// Once, because the causes are not independent: a carrier that fails also
    /// ends the control stream, so an unguarded report would announce a single
    /// disconnection twice and start two reconnects.
    private func reportInterruption(_ failure: TransportFailure) {
        guard !isClosed, !hasReportedInterruption else { return }
        hasReportedInterruption = true
        interruptionContinuation.yield(failure)
        interruptionContinuation.finish()
    }

    public var negotiated: NegotiatedParameters {
        get async { parameters }
    }

    /// Each endpoint steps by two, so the parity that identifies the
    /// originator holds for the life of the session.
    private func allocateRequestID() -> UInt64 {
        defer { nextRequestID += 2 }
        return nextRequestID
    }

    private func allocateTrackAlias() -> UInt64 {
        defer { nextTrackAlias += 1 }
        return nextTrackAlias
    }

    // MARK: - Setup

    /// Exchange SETUP on the control stream.
    ///
    /// The control stream is the first bidirectional stream and stays open for
    /// the session. Nothing else may be sent until the peer's SETUP arrives,
    /// which is why this is not folded into the read loop.
    func performSetup(credentials: DeviceCredentials) async throws(MoqomError) {
        let control = try await carrier.openBidirectionalStream()
        controlStream = control

        var options = Parameters()
        // The token goes in a session option rather than per-request because
        // it authorises the connection; per-request DPoP proofs bind actions
        // and are carried on the requests themselves.
        if let token = try? Parameter.bytes(SetupOption.authorizationToken, credentials.token) {
            options.insert(token)
        }
        if let implementation = try? Parameter.string(
            SetupOption.implementation,
            "moqom-swift/\(moqomKitVersion)"
        ) {
            options.insert(implementation)
        }

        try await send(Setup(options: options), on: control)

        var framer = StreamFramer()
        while true {
            guard let chunk = try await control.read() else {
                throw MoqomError.transport(.closedByPeer(code: 0, reason: "closed during setup"))
            }
            framer.append(chunk)
            guard let frame = try framer.next() else { continue }
            guard frame.type == .setup else {
                throw MoqomError.protocolViolation("expected SETUP, got \(frame.type)")
            }
            var reader = WireReader(frame.body)
            let peer: Setup
            do {
                peer = try Setup.read(from: &reader)
            } catch {
                throw MoqomError.protocolViolation("malformed SETUP")
            }
            peerOptions = peer.options
            setupFramer = framer
            return
        }
    }

    private var controlStream: (any QUICStream)?
    private var setupFramer = StreamFramer()
    private var peerOptions = Parameters()

    /// What the peer sent in SETUP, for callers that need an option we do not
    /// model. Empty until the handshake completes.
    public var peerSetupOptions: Parameters { peerOptions }

    // MARK: - Reading

    func startReading() {
        readers.append(Task { [weak self] in await self?.readControlStream() })
        readers.append(Task { [weak self] in await self?.readIncomingStreams() })
        readers.append(Task { [weak self] in await self?.readDatagrams() })
        readers.append(Task { [weak self] in await self?.watchCarrier() })
    }

    /// Turn the carrier going away into a session interruption.
    private func watchCarrier() async {
        for await failure in carrier.loss {
            reportInterruption(failure)
            return
        }
    }

    private func readControlStream() async {
        guard let control = controlStream else { return }
        var framer = setupFramer
        while !isClosed {
            do {
                guard let chunk = try await control.read() else { break }
                framer.append(chunk)
                while let frame = try framer.next() {
                    handleControl(frame)
                }
            } catch {
                break
            }
        }

        // The control stream ending is the session ending, whatever the carrier
        // thinks. It outlives every request by definition, so reaching here
        // means either the peer tore it down or the connection is gone — and a
        // carrier that has not noticed yet is precisely the case where this is
        // the only signal available.
        reportInterruption(.closed)
    }

    private func handleControl(_ frame: (type: MessageType, body: Data)) {
        // GOAWAY is the only message that appears on the control stream after
        // setup, and it cancels nothing: subscriptions stay live and the client
        // is expected to wind them down itself. Treating it as a teardown would
        // discard state the peer still expects to exist.
        guard frame.type == .goaway else { return }
        var reader = WireReader(frame.body)
        guard let goaway = try? Goaway.read(from: &reader) else { return }
        goawayContinuation?.yield(
            GoawayNotice(
                newSessionURI: goaway.newSessionURI.isEmpty ? nil : goaway.newSessionURI,
                timeout: .milliseconds(Int(goaway.timeoutMilliseconds))
            )
        )
    }

    private var goawayContinuation: AsyncStream<GoawayNotice>.Continuation?

    /// The peer asking us to migrate.
    public func goawayNotices() -> AsyncStream<GoawayNotice> {
        let (stream, continuation) = AsyncStream.makeStream(of: GoawayNotice.self)
        goawayContinuation = continuation
        return stream
    }

    private func readIncomingStreams() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                guard let self else { return }
                for await stream in carrier.incomingUnidirectionalStreams {
                    Task { await self.readDataStream(stream) }
                }
            }
            group.addTask { [weak self] in
                guard let self else { return }
                let role = self.role
                var isFirst = true
                for await stream in carrier.incomingBidirectionalStreams {
                    // The first bidirectional stream of a session is the
                    // control stream by definition, and on the accepting side
                    // it arrives here rather than being opened. Dispatching it
                    // as an ordinary request would leave SETUP unanswered and
                    // the dialling peer waiting forever.
                    if isFirst, role == .server {
                        isFirst = false
                        Task { await self.acceptSetup(on: stream) }
                        continue
                    }
                    isFirst = false
                    Task { await self.readPeerRequest(stream) }
                }
            }
        }
    }

    /// Answer a peer's SETUP on the control stream it opened.
    private func acceptSetup(on stream: any QUICStream) async {
        controlStream = stream
        var framer = StreamFramer()

        while true {
            let chunk: Data?
            do { chunk = try await stream.read() } catch { break }
            guard let chunk else { break }
            framer.append(chunk)

            guard let frame = try? framer.next() else { continue }
            guard frame.type == .setup else {
                finishSetup(.failure(MoqomError.protocolViolation("expected SETUP")))
                return
            }
            var reader = WireReader(frame.body)
            peerOptions = (try? Setup.read(from: &reader))?.options ?? Parameters()

            var options = Parameters()
            if let implementation = try? Parameter.string(
                SetupOption.implementation,
                "moqom-swift/\(moqomKitVersion)"
            ) {
                options.insert(implementation)
            }
            do {
                try await send(Setup(options: options), on: stream)
            } catch {
                finishSetup(.failure(error))
                return
            }

            setupFramer = framer
            finishSetup(.success(()))
            await readControlStream()
            return
        }
        finishSetup(.failure(MoqomError.transport(.closed)))
    }

    private var setupResult: Result<Void, any Error>?
    private var setupWaiter: CheckedContinuation<Void, any Error>?

    private func finishSetup(_ result: Result<Void, any Error>) {
        guard setupResult == nil else { return }
        setupResult = result
        if let waiter = setupWaiter {
            setupWaiter = nil
            waiter.resume(with: result)
        }
    }

    private func waitForSetup() async throws {
        if let setupResult { return try setupResult.get() }
        try await withCheckedThrowingContinuation { continuation in
            setupWaiter = continuation
        }
    }

    private func readDatagrams() async {
        for await payload in carrier.datagrams {
            var reader = WireReader(payload)
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

    /// Sort an incoming unidirectional stream by its first varint.
    ///
    /// Subgroup and fetch streams arrive the same way and are told apart only by
    /// their leading stream type, so the first bytes have to be read before
    /// either parser can be chosen. Waiting for enough of them is the whole job
    /// here: a stream type is at most 8 bytes, but a peer is entitled to send
    /// them one at a time.
    private func readDataStream(_ stream: any QUICReceiveStream) async {
        var buffer = Data()
        while true {
            if let kind = StreamType.peek(buffer) {
                switch kind {
                case .fetch: await readFetchStream(stream, first: buffer)
                case .subgroup: await readSubgroup(stream, first: buffer)
                }
                return
            }
            // A varint is never longer than 8 bytes, so more than that without a
            // recognised type is a stream we will never understand.
            guard buffer.count < 8 else { return }
            let chunk: Data?
            do { chunk = try await stream.read() } catch { return }
            guard let chunk else { return }
            buffer.append(chunk)
        }
    }

    /// Read one subgroup stream to its end.
    ///
    /// Objects are delivered as they are parsed rather than after the stream
    /// completes. A subgroup is a whole group's worth of frames on a live
    /// track, so buffering it would add exactly the latency the protocol exists
    /// to avoid.
    private func readSubgroup(_ stream: any QUICReceiveStream, first chunk: Data) async {
        var buffer = chunk
        var header: SubgroupHeader?
        var subgroupReader: SubgroupReader?

        while true {
            while true {
                var reader = WireReader(buffer)
                if header == nil {
                    guard let parsed = try? SubgroupHeader.read(from: &reader) else { break }
                    header = parsed
                    subgroupReader = SubgroupReader(header: parsed)
                    buffer = reader.rest
                    continue
                }
                guard var active = subgroupReader, let header else { break }
                guard let object = try? active.read(from: &reader) else { break }
                subgroupReader = active
                buffer = reader.rest

                guard case let .payload(payload) = object.content else { continue }
                deliver(
                    TrackObject(
                        group: header.group,
                        object: object.object,
                        priority: header.priority ?? 128,
                        payload: payload,
                        isKeyFrame: object.object == 0,
                        properties: ObjectProperties(object.properties)
                    ),
                    to: header.trackAlias
                )
            }

            let next: Data?
            do { next = try await stream.read() } catch { return }
            guard let next else { break }
            buffer.append(next)
        }
    }

    private func deliver(_ object: TrackObject, to alias: UInt64) {
        if let continuation = inboundTracks[alias] {
            continuation.yield(object)
            return
        }
        // Bounded: if the alias never resolves, this is a stream for a
        // subscription we cancelled, and holding a group of video for it is a
        // leak rather than a courtesy.
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

    func unregister(alias: UInt64) {
        inboundTracks.removeValue(forKey: alias)?.finish()
        pendingAliases.removeValue(forKey: alias)
    }

    // MARK: - Peer requests

    /// Handle a bidirectional stream the peer opened.
    ///
    /// For a publishing client this is how a relay asks for a track: it sends
    /// SUBSCRIBE, we answer SUBSCRIBE_OK with an alias, and from then on our
    /// writer has somewhere to send.
    private func readPeerRequest(_ stream: any QUICStream) async {
        var framer = StreamFramer()
        var subscribedTrack: FullTrackName?

        while true {
            let chunk: Data?
            do { chunk = try await stream.read() } catch { break }
            guard let chunk else { break }
            framer.append(chunk)

            while let frame = try? framer.next() {
                switch frame.type {
                case .subscribe:
                    var reader = WireReader(frame.body)
                    guard let request = try? Subscribe.read(from: &reader) else { break }
                    subscribedTrack = request.track
                    await answerSubscribe(request, on: stream)
                case .fetch:
                    var reader = WireReader(frame.body)
                    guard let request = try? Fetch.read(from: &reader) else { break }
                    await answerFetch(request, on: stream)
                case .subscribeNamespace:
                    var reader = WireReader(frame.body)
                    guard let request = try? SubscribeNamespace.read(from: &reader) else { break }
                    await acceptNamespaceWatch(request, on: stream)
                case .publishNamespace:
                    // Nothing for a client to do with a peer's announcement
                    // beyond acknowledging it: the roster is built from the
                    // prefix subscription, not from these.
                    try? await send(RequestOk(), on: stream)
                default:
                    break
                }
            }
        }

        if let subscribedTrack {
            await outboundTracks[subscribedTrack]?.removeSubscriber(stream: stream)
        }
    }

    private func answerSubscribe(_ request: Subscribe, on stream: any QUICStream) async {
        guard let track = outboundTracks[request.track] else {
            try? await send(
                RequestError(
                    code: RequestErrorCode.doesNotExist,
                    reason: "no such track"
                ),
                on: stream
            )
            await stream.finish()
            return
        }

        let alias = allocateTrackAlias()
        try? await send(SubscribeOk(trackAlias: alias), on: stream)
        await track.addSubscriber(alias: alias, stream: stream, carrier: carrier)

        // Kept so a joining fetch can be resolved. A joining fetch names a
        // subscription by *its* request ID and nothing else — no track, no
        // namespace — so without this the only answerable fetch is a standalone
        // one, and catch-up silently does nothing over a real session while
        // appearing to work over the loopback.
        inboundSubscriptions[request.requestID] = request.track
    }

    /// Tracks the peer has subscribed to, by the request ID that asked.
    ///
    /// Keyed by request ID rather than by track because that is the only handle
    /// a joining fetch has to name.
    private var inboundSubscriptions: [UInt64: FullTrackName] = [:]

    // MARK: - Announcing

    /// Namespaces we have announced and not yet withdrawn.
    private var announced: Set<TrackNamespace> = []

    /// Prefix subscriptions the peer has opened against us.
    ///
    /// A client having these looks odd until you remember MOQT is symmetric: a
    /// relay is a peer that forwards, and the only thing separating "client"
    /// from "server" here is who dialled. Answering them is what lets two
    /// sessions talk directly, which is how the protocol is tested.
    private var namespaceWatchers: [(prefix: TrackNamespace, stream: any QUICStream)] = []

    public func announce(
        _ namespace: TrackNamespace
    ) async throws(MoqomError) -> any AnnouncementHandle {
        let stream = try await carrier.openBidirectionalStream()
        let message = PublishNamespace(requestID: allocateRequestID(), namespace: namespace)
        try await send(message, on: stream)
        announced.insert(namespace)

        for watcher in namespaceWatchers where namespace.starts(with: watcher.prefix) {
            guard let suffix = Self.split(namespace, under: watcher.prefix) else { continue }
            try? await send(NamespaceAnnounced(suffix: suffix), on: watcher.stream)
        }

        return MoqtAnnouncement(namespace: namespace, stream: stream, session: self)
    }

    func withdraw(_ namespace: TrackNamespace) async {
        guard announced.remove(namespace) != nil else { return }
        for watcher in namespaceWatchers where namespace.starts(with: watcher.prefix) {
            guard let suffix = Self.split(namespace, under: watcher.prefix) else { continue }

            // `stopped`, unconditionally, because reaching here means somebody
            // called ``AnnouncementHandle/withdraw()``. A session that merely
            // ends never runs this: the streams close and the peer reports its
            // own `vanished` instead.
            try? await send(NamespaceDone(suffix: suffix, reason: .stopped), on: watcher.stream)
        }
    }

    private func acceptNamespaceWatch(
        _ request: SubscribeNamespace,
        on stream: any QUICStream
    ) async {
        // Overlapping prefixes on one session are refused rather than merged:
        // an announcement carries only its suffix, so two overlapping watches
        // would produce suffixes with no way to say which watch they answer.
        let overlaps = namespaceWatchers.contains {
            $0.prefix.starts(with: request.prefix) || request.prefix.starts(with: $0.prefix)
        }
        guard !overlaps else {
            try? await send(
                RequestError(code: RequestErrorCode.prefixOverlap, reason: "prefix overlap"),
                on: stream
            )
            await stream.finish()
            return
        }

        namespaceWatchers.append((request.prefix, stream))
        for namespace in announced where namespace.starts(with: request.prefix) {
            guard let suffix = Self.split(namespace, under: request.prefix) else { continue }
            try? await send(NamespaceAnnounced(suffix: suffix), on: stream)
        }
    }

    private static func split(
        _ namespace: TrackNamespace,
        under prefix: TrackNamespace
    ) -> TrackNamespace? {
        guard let fields = namespace.suffix(after: prefix) else { return nil }
        return try? TrackNamespace(fields)
    }

    public func announcements(
        matching prefix: TrackNamespace
    ) async throws(MoqomError) -> AsyncStream<AnnouncementEvent> {
        let stream = try await carrier.openBidirectionalStream()
        try await send(
            SubscribeNamespace(requestID: allocateRequestID(), prefix: prefix),
            on: stream
        )

        let (events, continuation) = AsyncStream.makeStream(
            of: AnnouncementEvent.self,
            bufferingPolicy: .unbounded
        )

        let reader = Task {
            var framer = StreamFramer()
            while true {
                let chunk: Data?
                do { chunk = try await stream.read() } catch { break }
                guard let chunk else { break }
                framer.append(chunk)

                while let frame = try? framer.next() {
                    var body = WireReader(frame.body)
                    switch frame.type {
                    case .namespace:
                        guard let message = try? NamespaceAnnounced.read(from: &body),
                              let full = Self.join(prefix: prefix, suffix: message.suffix)
                        else { break }
                        continuation.yield(.announced(full))
                    case .namespaceDone:
                        guard let message = try? NamespaceDone.read(from: &body),
                              let full = Self.join(prefix: prefix, suffix: message.suffix)
                        else { break }
                        continuation.yield(.withdrawn(full, message.reason))
                    default:
                        break
                    }
                }
            }
            continuation.finish()
        }

        continuation.onTermination = { _ in
            reader.cancel()
            Task { await stream.finish() }
        }
        return events
    }

    /// An announcement carries only the fields after the watched prefix, so the
    /// full namespace has to be reassembled here. This is also why two
    /// overlapping prefix subscriptions on one session are forbidden: the
    /// suffix would not say which prefix it belonged to.
    private static func join(prefix: TrackNamespace, suffix: TrackNamespace) -> TrackNamespace? {
        try? TrackNamespace(prefix.fields + suffix.fields)
    }

    // MARK: - Subscribing

    public func subscribe(
        _ request: SubscribeRequest
    ) async throws(MoqomError) -> any SubscriptionHandle {
        let stream = try await carrier.openBidirectionalStream()
        let requestID = allocateRequestID()

        var parameters = Parameters()
        if let priority = try? Parameter.integer(
            SubscribeParameter.subscriberPriority,
            UInt64(request.priority)
        ) {
            parameters.insert(priority)
        }
        if let timeout = request.deliveryTimeout,
           let parameter = try? Parameter.integer(
               SubscribeParameter.deliveryTimeout,
               UInt64(max(0, timeout.milliseconds))
           )
        {
            parameters.insert(parameter)
        }

        try await send(
            Subscribe(requestID: requestID, track: request.track, parameters: parameters),
            on: stream
        )

        let alias = try await awaitSubscribeOk(on: stream)

        let (objects, continuation) = AsyncStream.makeStream(
            of: TrackObject.self,
            bufferingPolicy: .bufferingNewest(256)
        )
        register(continuation, for: alias)

        let subscription = MoqtSubscription(
            track: request.track,
            alias: alias,
            objects: objects,
            stream: stream,
            session: self
        )
        subscriptionRequests[ObjectIdentifier(subscription)] = requestID
        watchForEnd(of: alias, on: stream)
        return subscription
    }

    /// Keep reading the request stream, because the answer is not the last word
    /// on it.
    ///
    /// A publisher that stops sends PUBLISH_DONE here, and hearing it is the
    /// difference between a tile that can say the other person left and one
    /// that holds its last frame forever. Objects merely stopping cannot be
    /// told from a bad network, and waiting out a bad network is the right
    /// thing to do — so a subscription that ends in silence ends as a stall.
    private func watchForEnd(of alias: UInt64, on stream: any QUICStream) {
        Task { [weak self] in
            var framer = StreamFramer()
            reading: while true {
                let chunk: Data?
                do { chunk = try await stream.read() } catch { break }
                guard let chunk else { break }
                framer.append(chunk)

                while let frame = try? framer.next() {
                    // Anything else here is a message this build has no use
                    // for. Ignored rather than treated as a violation: the
                    // draft adds to what may travel on this stream, and a
                    // subscriber that hung up over an unfamiliar message would
                    // break against every relay newer than itself.
                    if frame.type == .publishDone { break reading }
                }
            }
            // On every way out, not only on PUBLISH_DONE. A reset or a lost
            // connection ends the subscription just as surely, and an objects
            // stream left open would leave its reader waiting on a track that
            // has no publisher.
            await self?.unregister(alias: alias)
        }
    }

    /// Request IDs of the subscriptions we opened, so a joining fetch can name
    /// one.
    ///
    /// Keyed by handle identity rather than by track: two subscriptions to the
    /// same track are two requests, and a joining fetch has to name the one the
    /// caller is actually watching.
    private var subscriptionRequests: [ObjectIdentifier: UInt64] = [:]

    func forget(subscription: ObjectIdentifier) {
        subscriptionRequests.removeValue(forKey: subscription)
    }

    /// Block until the response arrives on the request's own stream.
    ///
    /// There is no request ID to match against here, and that is correct rather
    /// than a shortcut: responses travel on the same bidirectional stream as
    /// the request they answer, so the stream *is* the correlation.
    private func awaitSubscribeOk(on stream: any QUICStream) async throws(MoqomError) -> UInt64 {
        var framer = StreamFramer()
        while true {
            let chunk: Data?
            do { chunk = try await stream.read() } catch {
                throw MoqomError.transport(.closed)
            }
            guard let chunk else {
                throw MoqomError.rejected(.unavailable)
            }
            framer.append(chunk)

            while let frame = try framer.next() {
                var body = WireReader(frame.body)
                switch frame.type {
                case .subscribeOk:
                    guard let ok = try? SubscribeOk.read(from: &body) else {
                        throw MoqomError.protocolViolation("malformed SUBSCRIBE_OK")
                    }
                    return ok.trackAlias
                case .requestError:
                    let error = (try? RequestError.read(from: &body))
                        ?? RequestError(code: RequestErrorCode.internalError)
                    throw Self.rejection(for: error)
                default:
                    throw MoqomError.protocolViolation(
                        "expected SUBSCRIBE_OK, got \(frame.type)"
                    )
                }
            }
        }
    }

    private static func rejection(for error: RequestError) -> MoqomError {
        switch error.code {
        case RequestErrorCode.unauthorized,
             RequestErrorCode.expiredAuthToken,
             RequestErrorCode.malformedAuthToken:
            .rejected(.unauthorized)
        case RequestErrorCode.doesNotExist:
            .rejected(.unavailable)
        case RequestErrorCode.excessiveLoad, RequestErrorCode.goingAway:
            .rejected(.unavailable)
        case RequestErrorCode.timeout:
            .transport(.idleTimeout)
        default:
            .rejected(.limitExceeded(error.reason))
        }
    }

    func updatePriority(_ priority: UInt8, on stream: any QUICStream) async {
        guard let parameter = try? Parameter.integer(
            SubscribeParameter.subscriberPriority,
            UInt64(priority)
        ) else { return }
        try? await send(
            RequestUpdate(requestID: allocateRequestID(), parameters: Parameters([parameter])),
            on: stream
        )
    }

    // MARK: - Fetching

    /// Fetch streams we are waiting for, by the request they answer.
    ///
    /// A fetch's data stream is opened by the publisher and can arrive before
    /// FETCH_OK does, exactly as a subgroup can overtake SUBSCRIBE_OK. The
    /// difference is that a fetch stream names its request rather than a track
    /// alias, so this map is keyed by request ID and the race is handled by
    /// registering before the request goes out.
    private var pendingFetches: [UInt64: FetchSink] = [:]

    /// The receiving half of one fetch.
    private final class FetchSink: Sendable {
        let continuation: AsyncStream<FetchedRecord>.Continuation
        let order: GroupOrder

        init(continuation: AsyncStream<FetchedRecord>.Continuation, order: GroupOrder) {
            self.continuation = continuation
            self.order = order
        }
    }

    public func fetch(_ request: FetchRequest) async throws(MoqomError) -> any FetchHandle {
        let kind: Fetch.Kind
        switch request.range {
        case let .standalone(track, from, to):
            kind = .standalone(track: track, start: from, end: to)
        case let .joining(subscription, groups):
            guard let joined = subscriptionRequests[ObjectIdentifier(subscription)] else {
                // A handle from another session, or one already cancelled.
                // Falling back to a standalone fetch would need a track position
                // we do not have, so this is refused rather than approximated.
                throw MoqomError.invalidState(
                    expected: "a live subscription on this session",
                    actual: "an unknown subscription"
                )
            }
            kind = .relativeJoining(request: joined, groups: groups)
        case let .joiningFrom(subscription, group):
            guard let joined = subscriptionRequests[ObjectIdentifier(subscription)] else {
                throw MoqomError.invalidState(
                    expected: "a live subscription on this session",
                    actual: "an unknown subscription"
                )
            }
            kind = .absoluteJoining(request: joined, group: group)
        }

        let stream = try await carrier.openBidirectionalStream()
        let requestID = allocateRequestID()

        var parameters = Parameters()
        if let priority = try? Parameter.integer(
            SubscribeParameter.subscriberPriority,
            UInt64(request.priority)
        ) {
            parameters.insert(priority)
        }
        if let order = try? Parameter.integer(
            SubscribeParameter.groupOrder,
            request.order.rawValue
        ) {
            parameters.insert(order)
        }

        let (records, continuation) = AsyncStream.makeStream(
            of: FetchedRecord.self,
            bufferingPolicy: .unbounded
        )
        // Registered before the request is sent, because the data stream may
        // arrive before FETCH_OK.
        pendingFetches[requestID] = FetchSink(continuation: continuation, order: request.order)

        do {
            try await send(
                Fetch(requestID: requestID, kind: kind, parameters: parameters),
                on: stream
            )
        } catch {
            pendingFetches.removeValue(forKey: requestID)
            continuation.finish()
            throw error
        }

        let handle = MoqtFetch(
            requestID: requestID,
            records: records,
            stream: stream,
            session: self
        )
        // The response is awaited in the background rather than here: the data
        // stream is already allowed to be flowing, so blocking the caller until
        // FETCH_OK would delay records that have already arrived.
        Task { await handle.awaitResponse() }
        return handle
    }

    func fetchResponded(_ requestID: UInt64, with response: FetchOk) {
        // Nothing to route: FETCH_OK carries a range, and the records travel on
        // their own stream. Kept as a hook because a relay that answers with a
        // narrower range than requested is the normal case, not an error.
        _ = requestID
        _ = response
    }

    func fetchFailed(_ requestID: UInt64) {
        pendingFetches.removeValue(forKey: requestID)?.continuation.finish()
    }

    /// Read one fetch stream to its end.
    private func readFetchStream(_ stream: any QUICReceiveStream, first chunk: Data) async {
        var buffer = chunk
        var header: FetchHeader?
        var fetchReader: FetchReader?
        var sink: FetchSink?

        while true {
            while true {
                var reader = WireReader(buffer)
                if header == nil {
                    guard let parsed = try? FetchHeader.read(from: &reader) else { break }
                    header = parsed
                    sink = self.sink(for: parsed.requestID)
                    guard let sink else {
                        // A stream for a fetch we cancelled, or never made.
                        // STOP_SENDING rather than a silent drain: the publisher
                        // may have a whole range of history queued behind this.
                        await stream.stopReceiving(code: RequestErrorCode.uninterested)
                        return
                    }
                    fetchReader = FetchReader(header: parsed, order: sink.order)
                    buffer = reader.rest
                    continue
                }
                guard var active = fetchReader, let sink else { break }
                guard let record = try? active.read(from: &reader) else { break }
                fetchReader = active
                buffer = reader.rest

                switch record {
                case let .object(object):
                    sink.continuation.yield(
                        .object(
                            TrackObject(
                                group: object.location.group,
                                object: object.location.object,
                                priority: object.priority,
                                payload: object.payload,
                                isKeyFrame: object.location.object == 0,
                                properties: ObjectProperties(object.properties)
                            )
                        )
                    )
                case let .endOfNonExistentRange(location):
                    sink.continuation.yield(.missing(through: location))
                case let .endOfUnknownRange(location):
                    sink.continuation.yield(.unknown(through: location))
                }
            }

            let next: Data?
            do { next = try await stream.read() } catch { break }
            guard let next else { break }
            buffer.append(next)
        }

        // A FIN is what ends a fetch. It is also the only thing that makes the
        // gaps meaningful: without it, a short stream is indistinguishable from
        // a range that simply has not finished arriving.
        if let header { finish(fetch: header.requestID) }
    }

    private func sink(for requestID: UInt64) -> FetchSink? {
        pendingFetches[requestID]
    }

    private func finish(fetch requestID: UInt64) {
        pendingFetches.removeValue(forKey: requestID)?.continuation.finish()
    }

    func cancelFetch(_ requestID: UInt64) {
        finish(fetch: requestID)
    }

    /// Answer a peer's FETCH from what we still hold.
    ///
    /// A publishing client can serve this because `PublishedTrack` keeps the
    /// most recent groups: that is what makes catch-up work without a relay in
    /// the middle, and it is how the fetch path is tested at all.
    private func answerFetch(_ request: Fetch, on stream: any QUICStream) async {
        let resolved: Resolved
        switch await resolve(request.kind) {
        case let .success(value):
            resolved = value
        case let .failure(code, reason):
            try? await send(RequestError(code: code, reason: reason), on: stream)
            await stream.finish()
            return
        }

        let order = request.parameters.integer(SubscribeParameter.groupOrder)
            .flatMap(GroupOrder.init(rawValue:)) ?? .ascending
        let held = await resolved.published.objects(
            from: resolved.start,
            through: resolved.end,
            order: order
        )

        // The maximum, not the last one written. In descending order the last
        // record is the *oldest*, and FETCH_OK describes the range rather than
        // the delivery, so reporting `held.last` would tell a descending
        // subscriber the range ended where it in fact began.
        guard let furthest = held.map(\.location).max() else {
            try? await send(
                RequestError(code: RequestErrorCode.invalidRange, reason: "nothing in range"),
                on: stream
            )
            await stream.finish()
            return
        }

        try? await send(FetchOk(end: .through(furthest)), on: stream)

        guard let data = try? await carrier.openUnidirectionalStream() else { return }
        let header = FetchHeader(requestID: request.requestID)
        var writer = WireWriter(capacity: header.encodedLength)
        header.write(to: &writer)
        guard (try? await data.write(writer.bytes)) != nil else { return }

        // Holes are reported rather than skipped. A publisher's history has them
        // whenever an encoder dropped a frame under back pressure, and a
        // receiver that is not told treats a missing object as one still in
        // flight.
        let markers = FetchGaps.markers(before: held.map(\.location), order: order)

        var records = FetchWriter(header: header, order: order)
        for (index, object) in held.enumerated() {
            if let marker = markers[index] {
                var buffer = WireWriter(capacity: 16)
                guard (try? records.write(.endOfNonExistentRange(marker), to: &buffer)) != nil
                else { break }
                guard (try? await data.write(buffer.bytes)) != nil else { break }
            }
            var buffer = WireWriter(capacity: object.payload.count + 16)
            guard (try? records.write(.object(object), to: &buffer)) != nil else { break }
            guard (try? await data.write(buffer.bytes)) != nil else { break }
        }
        await data.finish()
    }

    /// What a fetch resolved to, once the range is known absolutely.
    private struct Resolved {
        let published: PublishedTrack
        let start: Location
        let end: FetchEnd
    }

    private enum Resolution {
        case success(Resolved)
        case failure(code: UInt64, reason: String)
    }

    /// Turn any of the three fetch kinds into one absolute range.
    ///
    /// The joining kinds are the reason this is separate: they name a
    /// subscription instead of a track, and resolving them against the live edge
    /// here rather than at the requester is the whole point — the edge cannot
    /// move between working out what to ask for and asking for it.
    private func resolve(_ kind: Fetch.Kind) async -> Resolution {
        switch kind {
        case let .standalone(track, start, end):
            guard let published = outboundTracks[track] else {
                return .failure(code: RequestErrorCode.doesNotExist, reason: "no such track")
            }
            return .success(Resolved(published: published, start: start, end: end))

        case let .relativeJoining(joined, groups):
            guard let (published, position) = await joinedTrack(request: joined) else {
                return .failure(
                    code: RequestErrorCode.invalidJoiningRequestID,
                    reason: "no such subscription"
                )
            }
            // Saturating rather than wrapping: asking to go back further than
            // the track goes means "from the beginning", not "from 2^64".
            let first = position.group >= groups ? position.group - groups : 0
            return .success(
                Resolved(
                    published: published,
                    start: Location.group(first),
                    end: .through(position)
                )
            )

        case let .absoluteJoining(joined, group):
            guard let (published, position) = await joinedTrack(request: joined) else {
                return .failure(
                    code: RequestErrorCode.invalidJoiningRequestID,
                    reason: "no such subscription"
                )
            }
            guard group <= position.group else {
                return .failure(
                    code: RequestErrorCode.invalidRange,
                    reason: "start is ahead of the live edge"
                )
            }
            return .success(
                Resolved(
                    published: published,
                    start: Location.group(group),
                    end: .through(position)
                )
            )
        }
    }

    private func joinedTrack(request: UInt64) async -> (PublishedTrack, Location)? {
        guard
            let track = inboundSubscriptions[request],
            let published = outboundTracks[track],
            let position = await published.latestLocation
        else { return nil }
        return (published, position)
    }

    // MARK: - Publishing

    public func publish(
        _ track: FullTrackName,
        priority: UInt8
    ) async throws(MoqomError) -> any TrackWriter {
        let published = PublishedTrack(track: track, priority: priority)
        outboundTracks[track] = published
        return MoqtTrackWriter(track: track, published: published, session: self)
    }

    /// The publication state for a track, for tests and for callers that want
    /// to know whether anything is listening before spending an encode.
    func publishedTrack(_ track: FullTrackName) -> PublishedTrack? {
        outboundTracks[track]
    }

    func retire(track: FullTrackName) async {
        if let published = outboundTracks.removeValue(forKey: track) {
            await published.finish()
        }
    }

    // MARK: - Teardown

    public func close(code: UInt64, reason: String) async {
        guard !isClosed else { return }
        isClosed = true

        for reader in readers { reader.cancel() }
        readers.removeAll()
        for continuation in inboundTracks.values { continuation.finish() }
        inboundTracks.removeAll()
        goawayContinuation?.finish()
        // Finished without yielding: this teardown was asked for, and reporting
        // it as an interruption would have the session above reconnect to a
        // relay it just deliberately left.
        interruptionContinuation.finish()

        if let controlStream {
            try? await send(Goaway(timeoutMilliseconds: 0), on: controlStream)
            await controlStream.finish()
        }
        await carrier.close(code: code, reason: reason)
    }

    private func send(
        _ message: some ControlMessage,
        on stream: any QUICSendStream
    ) async throws(MoqomError) {
        var writer = WireWriter(capacity: message.encodedLength + 8)
        do {
            try ControlFrame.write(message, to: &writer)
        } catch {
            throw MoqomError.protocolViolation("control message too long to frame")
        }
        try await stream.write(writer.bytes)
    }
}

public extension MoqtSession {
    /// Dial: open the control stream and send SETUP first.
    static func connect(
        over carrier: any QUICCarrier,
        credentials: DeviceCredentials
    ) async throws(MoqomError) -> MoqtSession {
        let session = MoqtSession(carrier: carrier, role: .client)
        try await session.performSetup(credentials: credentials)
        await session.startReading()
        return session
    }

    /// Accept: wait for the peer's control stream and answer its SETUP.
    ///
    /// A client SDK needs this for the same reason MOQT has one message type
    /// for both directions — the protocol is symmetric, and the only asymmetry
    /// is who dialled. It is also what lets two sessions be tested against each
    /// other with no relay in between.
    static func accept(over carrier: any QUICCarrier) async throws(MoqomError) -> MoqtSession {
        let session = MoqtSession(carrier: carrier, role: .server)
        await session.startReading()
        do {
            try await session.waitForSetup()
        } catch let error as MoqomError {
            throw error
        } catch {
            throw MoqomError.transport(.unreachable)
        }
        return session
    }
}

/// The peer asking us to move.
public struct GoawayNotice: Hashable, Sendable {
    /// Where to reconnect, or `nil` to reuse the current endpoint.
    public let newSessionURI: String?

    /// How long the peer will keep this session up.
    public let timeout: Duration
}

/// Subscribe parameter codes, per draft-19 §15.
///
/// Not present in `moqom-proto`, which carries subscribe parameters opaquely
/// because a relay forwards them without interpreting. A client is the one
/// thing that has to name them.
public enum SubscribeParameter {
    /// Lower is more urgent.
    public static let subscriberPriority: UInt64 = 0x0E
    /// Milliseconds after which an undelivered object is worthless.
    public static let deliveryTimeout: UInt64 = 0x02
    /// Ascending or descending, and on a fetch it changes the delta signs on the
    /// data stream rather than only the delivery order.
    public static let groupOrder: UInt64 = 0x22
}

// MARK: - Handles

/// An announcement, which is a stream held open.
private final class MoqtAnnouncement: AnnouncementHandle {
    let namespace: TrackNamespace
    private let stream: any QUICStream
    private let session: MoqtSession

    init(namespace: TrackNamespace, stream: any QUICStream, session: MoqtSession) {
        self.namespace = namespace
        self.stream = stream
        self.session = session
    }

    func withdraw() async {
        // There is no UNANNOUNCE. Closing the stream *is* the withdrawal, and
        // finishing rather than resetting is what distinguishes "I am done
        // publishing" from "I crashed".
        await session.withdraw(namespace)
        await stream.finish()
    }
}

private final class MoqtSubscription: SubscriptionHandle {
    let track: FullTrackName
    let objects: AsyncStream<TrackObject>

    private let alias: UInt64
    private let stream: any QUICStream
    private let session: MoqtSession

    init(
        track: FullTrackName,
        alias: UInt64,
        objects: AsyncStream<TrackObject>,
        stream: any QUICStream,
        session: MoqtSession
    ) {
        self.track = track
        self.alias = alias
        self.objects = objects
        self.stream = stream
        self.session = session
    }

    func updatePriority(_ priority: UInt8) async {
        await session.updatePriority(priority, on: stream)
    }

    func cancel() async {
        // A reset rather than a finish: the subscription is being abandoned,
        // not completed, and the relay should stop sending immediately rather
        // than draining what it has queued.
        await stream.reset(code: RequestErrorCode.uninterested)
        await session.unregister(alias: alias)
        await session.forget(subscription: ObjectIdentifier(self))
    }
}

/// One fetch, and the request stream that owns its lifetime.
private final class MoqtFetch: FetchHandle, @unchecked Sendable {
    let records: AsyncStream<FetchedRecord>

    private let requestID: UInt64
    private let stream: any QUICStream
    private let session: MoqtSession
    private let state = Mutex<FetchEnd?>(nil)

    init(
        requestID: UInt64,
        records: AsyncStream<FetchedRecord>,
        stream: any QUICStream,
        session: MoqtSession
    ) {
        self.requestID = requestID
        self.records = records
        self.stream = stream
        self.session = session
    }

    var served: FetchEnd? {
        get async { state.value }
    }

    /// Read the one response the request stream will carry.
    func awaitResponse() async {
        var framer = StreamFramer()
        while true {
            let chunk: Data?
            do { chunk = try await stream.read() } catch { break }
            guard let chunk else { break }
            framer.append(chunk)

            while let frame = try? framer.next() {
                var body = WireReader(frame.body)
                switch frame.type {
                case .fetchOk:
                    guard let ok = try? FetchOk.read(from: &body) else { break }
                    state.value = ok.end
                    await session.fetchResponded(requestID, with: ok)
                    return
                case .requestError:
                    // A relay may stream cached objects before it knows whether
                    // the whole range can be served, so an error here does not
                    // mean nothing arrived. Ending the record stream is the only
                    // honest response: the range stops where it stopped.
                    await session.fetchFailed(requestID)
                    return
                default:
                    break
                }
            }
        }
        await session.fetchFailed(requestID)
    }

    func cancel() async {
        // Mandatory on the request stream, optional on the data stream — §5.2.
        // Resetting the request stream is what makes the publisher reset both.
        await stream.reset(code: RequestErrorCode.uninterested)
        await session.cancelFetch(requestID)
    }
}

/// A box for the one piece of state a fetch handle mutates.
///
/// `MoqtFetch` is not an actor because `records` has to be readable
/// synchronously at construction, and this is the only field that changes after
/// that.
private final class Mutex<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private final class MoqtTrackWriter: TrackWriter {
    let track: FullTrackName

    private let published: PublishedTrack
    private let session: MoqtSession

    init(track: FullTrackName, published: PublishedTrack, session: MoqtSession) {
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

/// One track we are publishing, and everyone subscribed to it.
///
/// A group maps to one subgroup stream per subscriber. Opening a stream per
/// group rather than one per track is what lets a relay drop a whole group
/// under congestion by resetting a stream, and what makes a lost packet's blast
/// radius one group rather than the rest of the broadcast.
actor PublishedTrack {
    private struct Subscriber {
        let alias: UInt64
        let control: any QUICStream
        var stream: (any QUICSendStream)?
        var writer: SubgroupWriter?
    }

    private let track: FullTrackName
    private let priority: UInt8
    private var subscribers: [ObjectIdentifier: Subscriber] = [:]
    private var carrier: (any QUICCarrier)?
    private var currentGroup: UInt64 = 0

    /// Recently published objects, oldest first, for answering a fetch.
    ///
    /// Bounded by groups rather than by objects or bytes, because a fetch asks
    /// for groups: keeping half of one would let a subscriber catch up to a
    /// point it cannot decode from. Two is the smallest number that is useful —
    /// the group in progress plus the one before it, so a joiner mid-group has a
    /// keyframe either way.
    private var history: [FetchObject] = []
    private var historyGroups = 2

    /// How many groups of history to keep for fetches. `0` disables it.
    ///
    /// Costs memory proportional to the bitrate, which is why it is a knob and
    /// not a constant: a publisher on a phone sending 4K has a very different
    /// idea of two groups than one sending audio.
    func retainHistory(groups: Int) {
        historyGroups = max(0, groups)
        trimHistory()
    }

    private func trimHistory() {
        guard historyGroups > 0 else {
            history.removeAll()
            return
        }
        var seen: [UInt64] = []
        for object in history.reversed() where !seen.contains(object.location.group) {
            seen.append(object.location.group)
        }
        guard seen.count > historyGroups else { return }
        let keep = Set(seen.prefix(historyGroups))
        history.removeAll { !keep.contains($0.location.group) }
    }

    /// Where this track is now, for resolving a joining fetch.
    ///
    /// `nil` before the first object, and also whenever history is disabled —
    /// which is the same answer for the same reason: a joining fetch counts back
    /// from the live edge, and a publisher keeping nothing has no edge to offer.
    var latestLocation: Location? { history.last?.location }

    /// The held objects in a range, in the requested order.
    func objects(
        from start: Location,
        through end: FetchEnd,
        order: GroupOrder
    ) -> [FetchObject] {
        let limit = end.wire
        let matching = history.filter { object in
            guard object.location >= start else { return false }
            switch end {
            case .endOfGroup(let group):
                // A zero object means the whole group, so the exclusive
                // comparison that works everywhere else would exclude all of it.
                return object.location.group <= group
            case .through:
                return object.location < limit
            }
        }
        switch order {
        case .ascending:
            return matching.sorted { $0.location < $1.location }
        case .descending:
            // Groups descend; objects within a group still ascend. §10.12.3 is
            // explicit that group order does not reverse the objects inside one.
            return matching.sorted {
                $0.location.group == $1.location.group
                    ? $0.location.object < $1.location.object
                    : $0.location.group > $1.location.group
            }
        }
    }

    /// Objects written with nobody watching.
    ///
    /// Surfaced rather than silently discarded, because "the relay never
    /// subscribed" and "the encoder produced nothing" look identical from the
    /// outside and want completely different investigations.
    private(set) var objectsWithoutSubscribers = 0

    /// Whether anything is listening. A publisher can skip an encode entirely
    /// when this is false, which on a phone is a hardware session and a
    /// thermal budget rather than a few wasted bytes.
    var hasSubscribers: Bool { !subscribers.isEmpty }

    init(track: FullTrackName, priority: UInt8) {
        self.track = track
        self.priority = priority
    }

    func addSubscriber(alias: UInt64, stream: any QUICStream, carrier: any QUICCarrier) {
        self.carrier = carrier
        subscribers[ObjectIdentifier(stream)] = Subscriber(alias: alias, control: stream)
    }

    func removeSubscriber(stream: any QUICStream) async {
        guard let subscriber = subscribers.removeValue(forKey: ObjectIdentifier(stream)) else {
            return
        }
        await subscriber.stream?.finish()
    }

    func startGroup(_ group: UInt64) async throws(MoqomError) {
        currentGroup = group
        for key in subscribers.keys {
            await subscribers[key]?.stream?.finish()
            subscribers[key]?.stream = nil
            subscribers[key]?.writer = nil
        }
    }

    func write(_ object: TrackObject) async throws(MoqomError) {
        // Recorded before the subscriber check, because a publisher with nobody
        // watching is exactly the case a fetch exists to serve: the first viewer
        // to arrive asks for what was published before they did.
        if historyGroups > 0 {
            history.append(
                FetchObject(
                    location: Location(group: object.group, object: object.object),
                    priority: object.priority,
                    properties: object.properties.parameters,
                    payload: object.payload
                )
            )
            trimHistory()
        }

        guard !subscribers.isEmpty, let carrier else {
            objectsWithoutSubscribers += 1
            return
        }
        if object.group != currentGroup {
            try await startGroup(object.group)
        }

        for key in subscribers.keys {
            guard var subscriber = subscribers[key] else { continue }

            if subscriber.stream == nil {
                // Declared from the first object because the header commits the
                // whole stream: once it says properties are present every later
                // object must carry the field. A track's frames are uniform in
                // this respect, so the first one is a safe witness.
                let header = SubgroupHeader(
                    trackAlias: subscriber.alias,
                    group: object.group,
                    subgroup: .zero,
                    priority: priority,
                    propertiesPresent: !object.properties.isEmpty
                )
                let stream = try await carrier.openUnidirectionalStream()
                var writer = WireWriter(capacity: header.encodedLength)
                header.write(to: &writer)
                try await stream.write(writer.bytes)
                subscriber.stream = stream
                subscriber.writer = SubgroupWriter(header: header)
            }

            guard var writer = subscriber.writer, let stream = subscriber.stream else { continue }
            var buffer = WireWriter(capacity: object.payload.count + 16)
            do {
                try writer.write(
                    SubgroupObject(
                        object: object.object,
                        properties: writer.header.propertiesPresent
                            ? object.properties.parameters
                            : Parameters(),
                        content: .payload(object.payload)
                    ),
                    to: &buffer
                )
            } catch {
                // A non-increasing object ID within a group is our bug, not the
                // peer's, and continuing would desynchronise the stream.
                throw MoqomError.protocolViolation("subgroup: \(error)")
            }
            try await stream.write(buffer.bytes)

            subscriber.writer = writer
            subscribers[key] = subscriber
        }
    }

    func finish() async {
        for subscriber in subscribers.values {
            await subscriber.stream?.finish()
            await subscriber.control.finish()
        }
        subscribers.removeAll()
    }
}

/// The SDK version, reported in SETUP so a relay's logs can name what connected.
let moqomKitVersion = "0.1.0"

extension Duration {
    var milliseconds: Int {
        let (seconds, attoseconds) = components
        return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
    }
}
