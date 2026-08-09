// The carrier that actually touches the network.
//
// Network.framework's QUIC rather than a vendored stack, and the reasons are
// the ones that decide it for a client rather than for a relay. The system
// stack is on the fast path the OS optimises, it participates in connection
// migration and multipath without asking, it does not add a megabyte to the
// app, and — the one that matters most on a phone — a socket the system owns
// keeps working across a network change and a suspension in ways an app-level
// stack has to reimplement badly.
//
// What that costs is congestion control. `moqom-cc`, the media-aware
// controller, cannot be installed under a stack we do not own, so a client on
// this carrier gets the system's CUBIC and the SDK's own layer selection above
// it rather than a controller that understands frame deadlines. That is a real
// loss and it is worth being explicit about instead of discovering later.
//
// > Important: this file compiles — it is typechecked against the macOS 26 SDK
// > on every build, and the API is identical on iOS — and it has never run.
// > Nothing in the test suite opens a socket. Everything above it is exercised
// > against `MemoryCarrier`, which is why the untested surface is this file
// > rather than the protocol.

#if canImport(Network)
    import Foundation
    import Network

    /// A ``QUICCarrier`` over `NetworkConnection<QUIC>`.
    public final class NetworkQUICCarrier: QUICCarrier {
        private let connection: NetworkConnection<QUIC>

        public let alpn: String
        public let maximumDatagramSize: Int

        private let bidirectional: AsyncStream<any QUICStream>
        private let unidirectional: AsyncStream<any QUICReceiveStream>
        private let incomingDatagrams: AsyncStream<Data>
        private let pumps: [Task<Void, Never>]
        private let datagramChannel: QUIC.Datagrams<QUICDatagram>?
        private let lossStream: AsyncStream<TransportFailure>
        private let reporter: LossReporter

        /// What this end advertises as its idle timeout.
        ///
        /// Matches the relay's `Liveness::DEFAULT`, and matching it is
        /// cosmetic: the effective timeout is the lower of the two ends'
        /// (RFC 9000 §10.1), so the relay's short value governs whatever a
        /// client asks for. Agreeing with it anyway means the number a reader
        /// finds here is the number in force, rather than one that is quietly
        /// overridden on every connection.
        ///
        /// This end sends no keep-alive of its own and does not need to. The
        /// relay PINGs quiet connections, a PING is ack-eliciting, and the ACK
        /// this end sends back is a packet the relay receives — so one side
        /// pinging resets the idle timer at both. A second keep-alive here
        /// would be duplicate traffic on a phone's radio for no added
        /// liveness.
        public static let defaultIdleTimeout: Duration = .seconds(10)

        /// How long to wait for a handshake before calling the relay unreachable.
        ///
        /// Long enough to cross a slow path and complete a QUIC handshake with a retry,
        /// short enough that a client which cannot connect says so while somebody is still
        /// looking at it. The failure is not final — a session is expected to re-steer and
        /// dial again — so the cost of being wrong here is one more attempt.
        public static let defaultHandshakeTimeout: Duration = .seconds(8)

        /// Which queue the radio should put this connection's packets in.
        ///
        /// Unmarked traffic is `bestEffort`, which on Wi-Fi means the same WMM
        /// access category and the same contention backoff as a background
        /// download. That is the wrong queue for media, and on a real network
        /// it is the dominant cost: measured against the access point, the
        /// local hop ran at a 12.7ms mean against its own 2.7ms floor, and
        /// carried 20.5 of the path's 23.2ms of deviation — nearly all of the
        /// jitter, on the one hop each frame crosses twice.
        ///
        /// Interactive video rather than interactive voice. Voice contends
        /// slightly sooner but is granted a much shorter transmit opportunity,
        /// which is sized for a 20ms speech packet and not for a video frame;
        /// a frame that does not fit waits for the next opportunity, so the
        /// higher priority would buy latency on the small packets and lose
        /// more of it on the large ones.
        ///
        /// This is a request, not a guarantee. An access point that ignores
        /// WMM, or one saturated by other clients, will schedule this the same
        /// as anything else.
        public static let serviceClass: NWParameters.ServiceClass = .interactiveVideo

        /// Dial a relay.
        ///
        /// - Parameter alpn: offered in preference order. Version negotiation
        ///   in draft-19 *is* ALPN — it was removed from SETUP entirely — so
        ///   this list is the version list, and a mismatch fails the handshake
        ///   rather than the session.
        /// - Parameter idleTimeout: what this end advertises. The value that
        ///   actually applies is the lower of the two ends' (RFC 9000 §10.1),
        ///   and the relay sets a short one, so this is a ceiling rather than a
        ///   choice — see ``NetworkQUICCarrier/defaultIdleTimeout``.
        public static func connect(
            host: String,
            port: UInt16,
            alpn: [String],
            trust: RelayTrust = .system,
            idleTimeout: Duration = NetworkQUICCarrier.defaultIdleTimeout,
            handshakeTimeout: Duration = NetworkQUICCarrier.defaultHandshakeTimeout,
            serviceClass: NWParameters.ServiceClass = NetworkQUICCarrier.serviceClass
        ) async throws(MoqomError) -> NetworkQUICCarrier {
            guard let port = NWEndpoint.Port(rawValue: port) else {
                throw MoqomError.transport(.unreachable)
            }
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: port)

            // The service class belongs to the parameters rather than to the
            // protocol stack, which is why this is not another line inside
            // `quic(alpn:trust:idleTimeout:)`.
            let connection = NetworkConnection(
                to: endpoint,
                using: NWParametersBuilder
                    .parameters {
                        Self.quic(alpn: alpn, trust: trust, idleTimeout: idleTimeout)
                    }
                    .serviceClass(serviceClass)
            ).start()

            // Made before the handshake is awaited, because the state handler
            // that resolves readiness is also the one that reports a later
            // failure: they are the same callback, and installing a second one
            // would replace the first.
            let (loss, lossIn) = AsyncStream.makeStream(
                of: TransportFailure.self,
                bufferingPolicy: .bufferingNewest(1)
            )
            let reporter = LossReporter(continuation: lossIn)

            try await Self.waitUntilReady(
                connection, reporting: reporter, within: handshakeTimeout
            )

            let datagrams = try? await connection.datagrams
            return NetworkQUICCarrier(
                connection: connection,
                datagrams: datagrams,
                loss: loss,
                reporter: reporter
            )
        }

        /// The protocol stack, configured.
        ///
        /// Split out because the builder is a result builder and a conditional
        /// inside one is awkward to read; the pinning decision is a plain `if`
        /// here instead.
        private static func quic(
            alpn: [String],
            trust: RelayTrust,
            idleTimeout: Duration
        ) -> QUIC {
            let quic = QUIC(alpn: alpn)
                .idleTimeout(idleTimeout.milliseconds)
                // Datagrams are off unless a frame size is asked for, and the
                // audio path wants them: a late audio packet is worse than a
                // missing one, so retransmission is a cost with no benefit.
                .maxDatagramFrameSize(1200)
                // MOQT opens a stream per request and a stream per group. The
                // defaults are sized for a handful and a busy room reaches
                // hundreds, at which point the peer's limit silently becomes the
                // frame rate.
                .initialMaxBidirectionalStreams(256)
                .initialMaxUnidirectionalStreams(1024)

            guard case .pinned = trust.policy else { return quic }
            return quic.tls.certificateValidator { _, secTrust in
                Self.satisfies(trust, secTrust)
            }
        }

        /// Whether the peer's certificate chain satisfies a pinning policy.
        ///
        /// Only the leaf is examined. Pinning an intermediate would mean
        /// trusting whatever it goes on to sign, which is a different and much
        /// weaker claim than the one the caller asked for.
        private static func satisfies(_ trust: RelayTrust, _ secTrust: sec_trust_t) -> Bool {
            let reference = sec_trust_copy_ref(secTrust).takeRetainedValue()
            guard
                let chain = SecTrustCopyCertificateChain(reference) as? [SecCertificate],
                let leaf = chain.first
            else { return false }
            return trust.accepts(certificate: SecCertificateCopyData(leaf) as Data) ?? false
        }

        /// Block until the handshake finishes or fails, and keep watching after.
        ///
        /// `start()` returns immediately and the connection walks a state
        /// machine afterwards, so without this the first `openStream` races
        /// the handshake.
        ///
        /// The handler stays installed once this returns, which is what makes
        /// reconnection possible: the same `.failed` that would have been a
        /// handshake error before readiness is a lost session after it, and the
        /// only difference is whether the continuation has already been used.
        private static func waitUntilReady(
            _ connection: NetworkConnection<QUIC>,
            reporting reporter: LossReporter,
            within timeout: Duration
        ) async throws(MoqomError) {
            do {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Void, any Error>) in
                    let resumed = OnceBox()
                    let stall = StallReason()

                    // A deadline, because not every failure to connect is
                    // reported as one. A connection whose packets are dropped
                    // with no answer — a filtered port, a relay that is not
                    // there, or an iOS app that has not been granted local
                    // network access — sits in `.preparing` indefinitely and
                    // no state update ever arrives to end it. Without this the
                    // caller waits forever on a question that has an answer.
                    //
                    // It resumes the same continuation rather than racing a
                    // second task. This API has no `cancel()`, so abandoning
                    // the handshake would leave a continuation that is never
                    // resumed, which leaks the caller's task rather than
                    // failing it.
                    let deadline = Task {
                        try? await Task.sleep(for: timeout)
                        guard !Task.isCancelled, resumed.claim() else { return }
                        continuation.resume(
                            throwing: stall.last ?? NWError.posix(.ETIMEDOUT)
                        )
                    }

                    connection.onStateUpdate { _, state in
                        switch state {
                        case .ready:
                            if resumed.claim() {
                                deadline.cancel()
                                continuation.resume()
                            }
                        case let .failed(error):
                            if resumed.claim() {
                                deadline.cancel()
                                continuation.resume(throwing: error)
                            } else {
                                reporter.report(Self.loss(for: error))
                            }
                        case .cancelled:
                            if resumed.claim() {
                                deadline.cancel()
                                continuation.resume(throwing: NWError.posix(.ECANCELED))
                            } else {
                                reporter.report(.closed)
                            }
                        case let .waiting(error):
                            // Kept rather than acted on. Before readiness this
                            // is the only description of what is going wrong —
                            // Network.framework retries and reports why each
                            // time — so holding the most recent one means the
                            // deadline above can fail with the actual reason
                            // instead of a bare timeout.
                            //
                            // Still not reported as a loss: after readiness a
                            // `.waiting` is a path change that the framework
                            // recovers from on its own, keeping the connection
                            // ID and therefore the session, and tearing that
                            // down would end a session that is about to work.
                            stall.record(error)
                        case .setup, .preparing:
                            break
                        @unknown default:
                            break
                        }
                    }
                }
            } catch let error as NWError {
                throw Self.failure(for: error)
            } catch {
                throw MoqomError.transport(.unreachable)
            }
        }

        private static func failure(for error: NWError) -> MoqomError {
            switch error {
            case let .tls(status):
                // A TLS failure is not a routing failure, and telling them
                // apart is the difference between "retry" and "your relay's
                // certificate is wrong".
                _ = status
                return .transport(.untrustedPeer)
            default:
                return .transport(.unreachable)
            }
        }

        /// The same errors, classified for a connection that had already worked.
        ///
        /// Separate from ``failure(for:)`` because the same `NWError` means
        /// different things on either side of the handshake: a timeout before
        /// readiness is a relay that cannot be reached, and one after it is a
        /// session that went idle.
        private static func loss(for error: NWError) -> TransportFailure {
            switch error {
            case let .posix(code) where code == .ETIMEDOUT:
                .idleTimeout
            case .tls:
                .untrustedPeer
            default:
                .unreachable
            }
        }

        private init(
            connection: NetworkConnection<QUIC>,
            datagrams: QUIC.Datagrams<QUICDatagram>?,
            loss: AsyncStream<TransportFailure>,
            reporter: LossReporter
        ) {
            self.connection = connection
            datagramChannel = datagrams
            lossStream = loss
            self.reporter = reporter
            alpn = connection.negotiatedALPN ?? ""
            maximumDatagramSize = datagrams == nil ? 0 : connection.usableDatagramFrameSize

            let (bidirectional, bidirectionalIn) = AsyncStream.makeStream(
                of: (any QUICStream).self,
                bufferingPolicy: .unbounded
            )
            let (unidirectional, unidirectionalIn) = AsyncStream.makeStream(
                of: (any QUICReceiveStream).self,
                bufferingPolicy: .unbounded
            )
            let (incoming, incomingIn) = AsyncStream.makeStream(
                of: Data.self,
                bufferingPolicy: .bufferingNewest(256)
            )
            self.bidirectional = bidirectional
            self.unidirectional = unidirectional
            incomingDatagrams = incoming

            var pumps: [Task<Void, Never>] = []
            pumps.append(
                Task {
                    // The handler must return promptly: it is the accept loop,
                    // and reading the stream inside it would serialise every
                    // inbound stream behind the first one's lifetime.
                    try? await connection.inboundStreams { stream in
                        switch stream.directionality {
                        case .bidirectional:
                            bidirectionalIn.yield(NetworkStream(stream: stream))
                        case .unidirectional:
                            unidirectionalIn.yield(NetworkStream(stream: stream))
                        default:
                            break
                        }
                    }
                    bidirectionalIn.finish()
                    unidirectionalIn.finish()
                }
            )

            if let datagrams {
                pumps.append(
                    Task {
                        do {
                            for try await message in datagrams.messages {
                                incomingIn.yield(message.content)
                            }
                        } catch {}
                        incomingIn.finish()
                    }
                )
            } else {
                incomingIn.finish()
            }
            self.pumps = pumps
        }

        deinit {
            for pump in pumps { pump.cancel() }
        }

        public var incomingBidirectionalStreams: AsyncStream<any QUICStream> { bidirectional }
        public var incomingUnidirectionalStreams: AsyncStream<any QUICReceiveStream> {
            unidirectional
        }

        public var datagrams: AsyncStream<Data> { incomingDatagrams }

        public var loss: AsyncStream<TransportFailure> { lossStream }

        public func openBidirectionalStream() async throws(MoqomError) -> any QUICStream {
            do {
                return NetworkStream(stream: try await connection.openStream(
                    directionality: .bidirectional
                ))
            } catch {
                throw MoqomError.transport(.closed)
            }
        }

        public func openUnidirectionalStream() async throws(MoqomError) -> any QUICSendStream {
            do {
                return NetworkStream(stream: try await connection.openStream(
                    directionality: .unidirectional
                ))
            } catch {
                throw MoqomError.transport(.closed)
            }
        }

        public func send(datagram: Data) async throws(MoqomError) {
            guard let datagramChannel else {
                throw MoqomError.transport(.closed)
            }
            do {
                try await datagramChannel.send(datagram)
            } catch {
                throw MoqomError.transport(.closed)
            }
        }

        public func close(code: UInt64, reason: String) async {
            // Silenced first. Everything below produces a `.cancelled` state
            // update, and a report from that would be indistinguishable from the
            // network dropping — which would have the session reconnect to a
            // relay it was just told to leave.
            reporter.silence()

            // This API has no `cancel()`: a connection's lifetime is its scope,
            // and setting the application error is what the peer sees as the
            // close reason. Cancelling the pumps releases the last thing
            // holding it.
            //
            // The reason is always given, never `nil`. Network.framework reads
            // it as a C string when the error is set, and with no reason it
            // reads a null pointer and the process dies inside `strlen` — a
            // crash in the framework, on a teardown path, that looks nothing
            // like its cause.
            connection.applicationError = NWProtocolQUIC.ApplicationError(
                code: code,
                reason: reason
            )
            for pump in pumps { pump.cancel() }
        }
    }

    /// Carries a connection's death out to whoever is watching, once.
    ///
    /// A class with a lock rather than an actor because it is written from
    /// `onStateUpdate`, which is a synchronous callback on Network.framework's
    /// queue and cannot await anything.
    private final class LossReporter: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: AsyncStream<TransportFailure>.Continuation?

        init(continuation: AsyncStream<TransportFailure>.Continuation) {
            self.continuation = continuation
        }

        func report(_ failure: TransportFailure) {
            guard let continuation = take() else { return }
            continuation.yield(failure)
            continuation.finish()
        }

        /// Give up the right to report, because the teardown was asked for.
        func silence() {
            take()?.finish()
        }

        @discardableResult
        private func take() -> AsyncStream<TransportFailure>.Continuation? {
            lock.lock()
            defer { lock.unlock() }
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
    }

    /// The most recent reason a connection was waiting rather than progressing.
    ///
    /// A class with a lock for the same reason as ``LossReporter``: it is written from
    /// `onStateUpdate`, a synchronous callback on Network.framework's queue.
    private final class StallReason: @unchecked Sendable {
        private let lock = NSLock()
        private var error: NWError?

        func record(_ error: NWError) {
            lock.withLock { self.error = error }
        }

        var last: NWError? {
            lock.withLock { error }
        }
    }

    /// Resumes a continuation exactly once from a callback that may fire again.
    ///
    /// `onStateUpdate` is not a one-shot: a connection can go ready, then
    /// waiting, then ready again, and resuming a continuation twice is a crash
    /// rather than a warning.
    private final class OnceBox: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if claimed { return false }
            claimed = true
            return true
        }
    }

    /// One QUIC stream.
    private final class NetworkStream: QUICStream {
        private let stream: QUIC.Stream<Network.QUICStream>
        private let ended = OnceBox()

        init(stream: QUIC.Stream<Network.QUICStream>) {
            self.stream = stream
        }

        func write(_ data: Data) async throws(MoqomError) {
            do {
                try await stream.send(data)
            } catch {
                throw MoqomError.transport(.closed)
            }
        }

        func finish() async {
            guard ended.claim() else { return }
            try? await stream.send(Data(), endOfStream: true)
        }

        func reset(code: UInt64) async {
            guard ended.claim() else { return }
            // A reset and a finish are different protocol events in MOQT: a
            // finished request completed, a reset one was abandoned. The peer
            // reads this code, so it has to carry the reason.
            stream.streamApplicationErrorCode = code
        }

        func read() async throws(MoqomError) -> Data? {
            do {
                // A large ceiling with a floor of one byte: this is a byte
                // stream and every reader above reassembles, so waiting for a
                // particular amount would deadlock on a message smaller than
                // the request.
                let message = try await stream.receive(atLeast: 1, atMost: 64 * 1024)
                if message.metadata.endOfStream, message.content.isEmpty { return nil }
                return message.content
            } catch {
                // End of stream surfaces as an error once the peer has closed,
                // and is indistinguishable here from a reset. Both mean the
                // same thing to a reader: stop.
                return nil
            }
        }

        func stopReceiving(code: UInt64) async {
            await reset(code: code)
        }
    }

    public extension MoqtTransport {
        /// A transport that dials over the system QUIC stack.
        ///
        /// The one a shipping app wants. ``MoqtTransport/init(dial:)`` exists
        /// for the ones that do not — tests, and the in-memory carrier the
        /// sample runs on before there is a relay to point at.
        ///
        /// - Parameter trust: leave at ``RelayTrust/system`` unless the relay's
        ///   certificate is one the platform has no way to validate — a
        ///   development relay, or a self-hosted deployment behind a private CA.
        /// - Parameter serviceClass: which queue the radio should use. Leave at
        ///   ``NetworkQUICCarrier/serviceClass`` for anything a person is
        ///   watching live; `background` suits a transport that only carries
        ///   recordings, and yields to interactive traffic instead of
        ///   competing with it.
        static func network(
            trust: RelayTrust = .system,
            idleTimeout: Duration = NetworkQUICCarrier.defaultIdleTimeout,
            serviceClass: NWParameters.ServiceClass = NetworkQUICCarrier.serviceClass
        ) -> MoqtTransport {
            MoqtTransport { endpoint, _ in
                try await NetworkQUICCarrier.connect(
                    host: endpoint.host,
                    port: endpoint.port,
                    alpn: endpoint.alpn,
                    trust: trust,
                    idleTimeout: idleTimeout,
                    serviceClass: serviceClass
                )
            }
        }
    }
#endif
