// The dialling side of a direct path, on the older connection-group API.
//
// The older API rather than `NetworkConnection<QUIC>` for one reason, found by
// running both: a direct dial has to leave from the port the offer advertised,
// because that is the port the peer's NAT has been punched open for, and a
// `NetworkConnection<QUIC>` given a fixed local port completes its handshake
// and then refuses to open a stream (ENOTCONN) on the SDK this was built
// against. `NWConnectionGroup` with a required local endpoint does not, and it
// is still the API Apple documents for QUIC multiplexing.
//
// Everything above this sees an ordinary ``QUICCarrier``. Datagrams are not
// offered on this side: the group API delivers them through a separate path,
// and a session that is told the peer refused datagrams sends audio on
// streams, which is the behaviour a relay session without datagrams already
// has.

#if canImport(Network)
    import Foundation
    import Network

    final class DirectDialCarrier: QUICCarrier, @unchecked Sendable {
        let alpn: String
        let maximumDatagramSize = 0
        let peerCertificateDigest: String?

        private let group: NWConnectionGroup
        private let queue: DispatchQueue
        private let lossStream: AsyncStream<TransportFailure>
        private let lossIn: AsyncStream<TransportFailure>.Continuation
        private let bidirectional: AsyncStream<any QUICStream>
        private let bidirectionalIn: AsyncStream<any QUICStream>.Continuation
        private let unidirectional: AsyncStream<any QUICReceiveStream>
        private let unidirectionalIn: AsyncStream<any QUICReceiveStream>.Continuation
        private let lock = NSLock()
        private var ended = false
        /// The first stream this side opened, which is the control stream.
        private var control: NWConnection?

        /// Dial `remote` from `localPort`, pinning the peer to `fingerprint`
        /// and presenting `certificate`.
        ///
        /// Returns once the handshake completes; fails with
        /// ``TransportFailure/unreachable`` if it does not within `timeout`, and
        /// with ``TransportFailure/untrustedPeer`` if the peer's certificate was
        /// not the pinned one.
        static func dial(
            _ remote: NWEndpoint,
            from localPort: UInt16,
            alpn: String,
            certificate: DirectCertificate,
            pinning fingerprint: Data,
            idleTimeout: Duration,
            timeout: Duration
        ) async throws(MoqomError) -> DirectDialCarrier {
            guard let port = NWEndpoint.Port(rawValue: localPort),
                  let identity = sec_identity_create(certificate.secIdentity)
            else { throw MoqomError.transport(.unreachable) }

            let queue = DispatchQueue(label: "dev.moqom.direct.dial")
            let options = NWProtocolQUIC.Options(alpn: [alpn])
            options.idleTimeout = Int(idleTimeout.milliseconds)
            options.initialMaxStreamsBidirectional = 256
            options.initialMaxStreamsUnidirectional = 1024
            sec_protocol_options_set_local_identity(options.securityProtocolOptions, identity)
            sec_protocol_options_set_verify_block(
                options.securityProtocolOptions,
                { _, trust, complete in complete(DirectCertificate.leaf(of: trust, matches: fingerprint)) },
                queue
            )
            let parameters = NWParameters(quic: options)
            // From the advertised port, shared with nothing else by the time
            // this runs: the socket releases its own listener first, because
            // a live listener on the port takes the peer's replies.
            parameters.requiredLocalEndpoint = .hostPort(host: "0.0.0.0", port: port)
            parameters.allowLocalEndpointReuse = true
            parameters.serviceClass = NetworkQUICCarrier.serviceClass

            let group = NWConnectionGroup(with: NWMultiplexGroup(to: remote), using: parameters)
            let carrier = DirectDialCarrier(
                group: group,
                queue: queue,
                alpn: alpn,
                certificate: fingerprint.base64URLEncodedString
            )
            try await carrier.start(within: timeout)
            return carrier
        }

        private init(group: NWConnectionGroup, queue: DispatchQueue, alpn: String, certificate: String) {
            self.group = group
            self.queue = queue
            self.alpn = alpn
            peerCertificateDigest = certificate
            (lossStream, lossIn) = AsyncStream.makeStream(
                of: TransportFailure.self,
                bufferingPolicy: .bufferingNewest(1)
            )
            (bidirectional, bidirectionalIn) = AsyncStream.makeStream(
                of: (any QUICStream).self,
                bufferingPolicy: .unbounded
            )
            (unidirectional, unidirectionalIn) = AsyncStream.makeStream(
                of: (any QUICReceiveStream).self,
                bufferingPolicy: .unbounded
            )
        }

        private func start(within timeout: Duration) async throws(MoqomError) {
            let ready = AsyncStream.makeStream(of: Result<Void, MoqomError>.self, bufferingPolicy: .bufferingNewest(1))
            let settled = OnceFlag()
            group.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if settled.claim() { ready.continuation.yield(.success(())) }
                case let .failed(error):
                    if settled.claim() {
                        if case .tls = error {
                            ready.continuation.yield(.failure(.transport(.untrustedPeer)))
                        } else {
                            ready.continuation.yield(.failure(.transport(.unreachable)))
                        }
                    } else {
                        let failure: TransportFailure =
                            if case let .posix(code) = error, code == .ETIMEDOUT { .idleTimeout } else { .unreachable }
                        self?.report(failure)
                    }
                case .cancelled:
                    if settled.claim() {
                        ready.continuation.yield(.failure(.transport(.unreachable)))
                    } else {
                        self?.report(.closed)
                    }
                case .setup, .waiting:
                    break
                @unknown default:
                    break
                }
            }
            group.newConnectionHandler = { [weak self] connection in
                self?.adopt(connection)
            }
            group.start(queue: queue)

            let deadline = Task {
                try? await Task.sleep(for: timeout)
                if !Task.isCancelled, settled.claim() {
                    ready.continuation.yield(.failure(.transport(.unreachable)))
                }
            }
            defer { deadline.cancel() }
            var iterator = ready.stream.makeAsyncIterator()
            let result = await iterator.next() ?? .failure(.transport(.unreachable))
            if case let .failure(error) = result {
                silence()
                group.cancel()
                throw error
            }
        }

        /// An inbound stream, classified once its metadata is readable: bit 1
        /// of a QUIC stream ID is what says unidirectional (RFC 9000 §2.1).
        private func adopt(_ connection: NWConnection) {
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard case .ready = state, let self, let connection else { return }
                connection.stateUpdateHandler = nil
                let metadata = connection.metadata(definition: NWProtocolQUIC.definition) as? NWProtocolQUIC.Metadata
                let stream = DialStream(connection: connection)
                if let id = metadata?.streamIdentifier, id & 0x2 != 0 {
                    unidirectionalIn.yield(stream)
                } else {
                    bidirectionalIn.yield(stream)
                }
            }
            connection.start(queue: queue)
        }

        var incomingBidirectionalStreams: AsyncStream<any QUICStream> { bidirectional }
        var incomingUnidirectionalStreams: AsyncStream<any QUICReceiveStream> { unidirectional }
        var datagrams: AsyncStream<Data> { AsyncStream { $0.finish() } }
        var loss: AsyncStream<TransportFailure> { lossStream }

        func openBidirectionalStream() async throws(MoqomError) -> any QUICStream {
            try open(using: nil)
        }

        func openUnidirectionalStream() async throws(MoqomError) -> any QUICSendStream {
            // The group's own QUIC options with only the direction changed.
            // Fresh options, with or without the ALPN and identity repeated,
            // fail with ENETDOWN before the stream opens, on the SDK this was
            // built against.
            let parameters = group.parameters.copy()
            guard let options = parameters.defaultProtocolStack.transportProtocol as? NWProtocolQUIC.Options else {
                throw MoqomError.transport(.closed)
            }
            options.direction = .unidirectional
            return try open(using: options)
        }

        private func open(using options: NWProtocolQUIC.Options?) throws(MoqomError) -> DialStream {
            guard !isEnded, let connection = NWConnection(from: group, using: options) else {
                throw MoqomError.transport(.closed)
            }
            lock.withLock { if control == nil { control = connection } }
            connection.start(queue: queue)
            return DialStream(connection: connection)
        }

        func send(datagram _: Data) async throws(MoqomError) {
            throw MoqomError.transport(.closed)
        }

        func close(code: UInt64, reason: String) async {
            silence()
            // The reason is what the peer reads, so it is set on the connection
            // before the group goes; never empty for the reason the other
            // carrier gives, which is a framework that reads it as a C string.
            let error = NWProtocolQUIC.ApplicationError(code: code, reason: reason.isEmpty ? " " : reason)
            let control = lock.withLock { self.control }
            let metadata = [group.metadata(definition: NWProtocolQUIC.definition), control?.metadata(definition: NWProtocolQUIC.definition)]
            for case let quic as NWProtocolQUIC.Metadata in metadata {
                quic.applicationError = error
            }
            control?.cancel()
            group.cancel()
            bidirectionalIn.finish()
            unidirectionalIn.finish()
        }

        private var isEnded: Bool { lock.withLock { ended } }

        private func silence() {
            lock.withLock { ended = true }
            lossIn.finish()
        }

        private func report(_ failure: TransportFailure) {
            let first = lock.withLock {
                defer { ended = true }
                return !ended
            }
            guard first else { return }
            lossIn.yield(failure)
            lossIn.finish()
            bidirectionalIn.finish()
            unidirectionalIn.finish()
        }
    }

    /// One stream of a dialled group.
    private final class DialStream: QUICStream, @unchecked Sendable {
        private let connection: NWConnection
        private let ended = OnceFlag()

        init(connection: NWConnection) {
            self.connection = connection
        }

        func write(_ data: Data) async throws(MoqomError) {
            let error: NWError? = await withCheckedContinuation { continuation in
                connection.send(content: data, completion: .contentProcessed { continuation.resume(returning: $0) })
            }
            if error != nil { throw MoqomError.transport(.closed) }
        }

        func finish() async {
            guard ended.claim() else { return }
            // A final message with no content is still a STREAM frame with FIN,
            // which is what makes an empty stream a signal the peer can see.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                connection.send(
                    content: nil,
                    contentContext: .finalMessage,
                    isComplete: true,
                    completion: .contentProcessed { _ in continuation.resume() }
                )
            }
        }

        func reset(code: UInt64) async {
            guard ended.claim() else { return }
            if let metadata = connection.metadata(definition: NWProtocolQUIC.definition) as? NWProtocolQUIC.Metadata {
                metadata.streamApplicationErrorCode = code
            }
            connection.cancel()
        }

        func read() async throws(MoqomError) -> Data? {
            await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { content, _, _, _ in
                    // End of stream and a reset read the same to everything
                    // above: stop. A chunk that arrives with the end is
                    // returned, and the next read reports the end.
                    continuation.resume(returning: content.flatMap { $0.isEmpty ? nil : $0 })
                }
            }
        }

        func stopReceiving(code: UInt64) async {
            await reset(code: code)
        }
    }
#endif
