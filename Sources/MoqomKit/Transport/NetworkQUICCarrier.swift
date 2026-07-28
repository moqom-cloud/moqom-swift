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

        /// Dial a relay.
        ///
        /// - Parameter alpn: offered in preference order. Version negotiation
        ///   in draft-19 *is* ALPN — it was removed from SETUP entirely — so
        ///   this list is the version list, and a mismatch fails the handshake
        ///   rather than the session.
        public static func connect(
            host: String,
            port: UInt16,
            alpn: [String],
            trust: RelayTrust = .system,
            idleTimeout: Duration = .seconds(30)
        ) async throws(MoqomError) -> NetworkQUICCarrier {
            guard let port = NWEndpoint.Port(rawValue: port) else {
                throw MoqomError.transport(.unreachable)
            }
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: port)

            let connection = NetworkConnection(to: endpoint) {
                Self.quic(alpn: alpn, trust: trust, idleTimeout: idleTimeout)
            }.start()

            // Made before the handshake is awaited, because the state handler
            // that resolves readiness is also the one that reports a later
            // failure: they are the same callback, and installing a second one
            // would replace the first.
            let (loss, lossIn) = AsyncStream.makeStream(
                of: TransportFailure.self,
                bufferingPolicy: .bufferingNewest(1)
            )
            let reporter = LossReporter(continuation: lossIn)

            try await Self.waitUntilReady(connection, reporting: reporter)

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
            reporting reporter: LossReporter
        ) async throws(MoqomError) {
            do {
                try await withCheckedThrowingContinuation { continuation in
                    let resumed = OnceBox()
                    connection.onStateUpdate { _, state in
                        switch state {
                        case .ready:
                            if resumed.claim() { continuation.resume() }
                        case let .failed(error):
                            if resumed.claim() {
                                continuation.resume(throwing: error)
                            } else {
                                reporter.report(Self.loss(for: error))
                            }
                        case .cancelled:
                            if resumed.claim() {
                                continuation.resume(throwing: NWError.posix(.ECANCELED))
                            } else {
                                reporter.report(.closed)
                            }
                        case .setup, .preparing, .waiting:
                            // `.waiting` after readiness is a path change, and
                            // Network.framework recovers from those itself while
                            // keeping the connection ID and therefore the
                            // session. Reporting it would tear down a session
                            // that is about to work again.
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
        static func network(
            trust: RelayTrust = .system,
            idleTimeout: Duration = .seconds(30)
        ) -> MoqtTransport {
            MoqtTransport { endpoint, _ in
                try await NetworkQUICCarrier.connect(
                    host: endpoint.host,
                    port: endpoint.port,
                    alpn: endpoint.alpn,
                    trust: trust,
                    idleTimeout: idleTimeout
                )
            }
        }
    }
#endif
