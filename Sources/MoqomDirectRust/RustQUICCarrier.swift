// A QUIC connection from moqom-direct-ffi, as MOQT uses one.
//
// Inbound streams and datagrams are each a loop that asks the library for the
// next one and asks again once it arrives, feeding an AsyncStream. The loops
// hold the connection weakly, so a carrier nobody holds is freed even while
// they wait; freeing it completes their pending request and they end.
//
// Failures map as NetworkQUICCarrier's do: a stream or datagram that cannot be
// sent is `.closed`, a read that cannot continue is the end of the stream, and
// a connection that ends without being asked to is reported once on `loss`.

#if canImport(MoqomDirectFFI)
    import Foundation
    import MoqomDirectFFI
    import MoqomKit

    /// A ``QUICCarrier`` over a moqom-direct-ffi connection.
    public final class RustQUICCarrier: QUICCarrier, @unchecked Sendable {
        public let alpn: String
        public let peerCertificateDigest: String?

        private let connection: Connection
        private let bidirectional: AsyncStream<any QUICStream>
        private let unidirectional: AsyncStream<any QUICReceiveStream>
        private let incomingDatagrams: AsyncStream<Data>
        private let lossStream: AsyncStream<TransportFailure>
        private let deliberate: Deliberate
        private let loops: [Task<Void, Never>]

        init(_ handle: RawHandle) {
            let connection = Connection(handle)
            self.connection = connection
            alpn = moqom_direct_connection_alpn(handle.pointer).map { String(cString: $0) } ?? ""
            var digest = [UInt8](repeating: 0, count: 32)
            peerCertificateDigest = moqom_direct_connection_peer_certificate(handle.pointer, &digest) == MOQOM_DIRECT_OK
                ? Data(digest).base64URL
                : nil

            let (loss, lossIn) = AsyncStream.makeStream(of: TransportFailure.self, bufferingPolicy: .bufferingNewest(1))
            lossStream = loss
            let deliberate = Deliberate(lossIn)
            self.deliberate = deliberate
            moqom_direct_connection_closed(
                handle.pointer,
                retained(ClosedCallback { status, code, reason in
                    deliberate.report(Self.failure(status: status, code: code, reason: reason))
                }),
                closedTrampoline
            )

            let (bidirectional, bidirectionalIn) = AsyncStream.makeStream(
                of: (any QUICStream).self,
                bufferingPolicy: .unbounded
            )
            let (unidirectional, unidirectionalIn) = AsyncStream.makeStream(
                of: (any QUICReceiveStream).self,
                bufferingPolicy: .unbounded
            )
            let (datagrams, datagramsIn) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .bufferingNewest(256))
            self.bidirectional = bidirectional
            self.unidirectional = unidirectional
            incomingDatagrams = datagrams

            loops = [
                Task { [weak connection] in
                    while true {
                        let next = await awaitPair { context in
                            guard let connection else { return biTrampoline(context, MOQOM_DIRECT_CANCELLED, nil, nil) }
                            moqom_direct_connection_accept_bi(connection.handle.pointer, context, biTrampoline)
                        }
                        guard next.status == MOQOM_DIRECT_OK, let send = next.first, let recv = next.second else {
                            next.first.map { moqom_direct_send_free($0.pointer) }
                            next.second.map { moqom_direct_recv_free($0.pointer) }
                            break
                        }
                        bidirectionalIn.yield(RustBiStream(send: RustSendStream(send), receive: RustReceiveStream(recv)))
                    }
                    bidirectionalIn.finish()
                },
                Task { [weak connection] in
                    while true {
                        let next = await awaitPair { context in
                            guard let connection else { return uniRecvTrampoline(context, MOQOM_DIRECT_CANCELLED, nil) }
                            moqom_direct_connection_accept_uni(connection.handle.pointer, context, uniRecvTrampoline)
                        }
                        guard next.status == MOQOM_DIRECT_OK, let recv = next.second else { break }
                        unidirectionalIn.yield(RustReceiveStream(recv))
                    }
                    unidirectionalIn.finish()
                },
                Task { [weak connection] in
                    while true {
                        let next = await awaitBytes { context in
                            guard let connection else { return bytesTrampoline(context, MOQOM_DIRECT_CANCELLED, nil, 0, 0) }
                            moqom_direct_connection_read_datagram(connection.handle.pointer, context, bytesTrampoline)
                        }
                        guard next.status == MOQOM_DIRECT_OK else { break }
                        datagramsIn.yield(next.data ?? Data())
                    }
                    datagramsIn.finish()
                },
            ]
        }

        deinit {
            for loop in loops { loop.cancel() }
        }

        public var maximumDatagramSize: Int {
            moqom_direct_connection_max_datagram_size(connection.handle.pointer)
        }

        public var incomingBidirectionalStreams: AsyncStream<any QUICStream> { bidirectional }
        public var incomingUnidirectionalStreams: AsyncStream<any QUICReceiveStream> { unidirectional }
        public var datagrams: AsyncStream<Data> { incomingDatagrams }
        public var loss: AsyncStream<TransportFailure> { lossStream }

        /// The address the peer is reached at.
        public var remote: DirectCandidate? {
            var address = MoqomDirectAddress()
            guard moqom_direct_connection_remote(connection.handle.pointer, &address) == MOQOM_DIRECT_OK else {
                return nil
            }
            return address.candidate
        }

        public func openBidirectionalStream() async throws(MoqomError) -> any QUICStream {
            let handle = connection.handle
            let opened = await awaitPair { context in
                moqom_direct_connection_open_bi(handle.pointer, context, biTrampoline)
            }
            guard opened.status == MOQOM_DIRECT_OK, let send = opened.first, let recv = opened.second else {
                opened.first.map { moqom_direct_send_free($0.pointer) }
                opened.second.map { moqom_direct_recv_free($0.pointer) }
                throw MoqomError.transport(.closed)
            }
            return RustBiStream(send: RustSendStream(send), receive: RustReceiveStream(recv))
        }

        public func openUnidirectionalStream() async throws(MoqomError) -> any QUICSendStream {
            let handle = connection.handle
            let opened = await awaitPair { context in
                moqom_direct_connection_open_uni(handle.pointer, context, uniSendTrampoline)
            }
            guard opened.status == MOQOM_DIRECT_OK, let send = opened.first else {
                throw MoqomError.transport(.closed)
            }
            return RustSendStream(send)
        }

        public func send(datagram: Data) async throws(MoqomError) {
            let status = datagram.withUnsafeBytes { raw in
                moqom_direct_connection_send_datagram(
                    connection.handle.pointer,
                    raw.bindMemory(to: UInt8.self).baseAddress,
                    raw.count
                )
            }
            guard status == MOQOM_DIRECT_OK else { throw MoqomError.transport(.closed) }
        }

        public func close(code: UInt64, reason: String) async {
            // Silenced first: the library reports its own close as an ending
            // too, and the session above reconnects on anything reported.
            deliberate.silence()
            reason.withCString { moqom_direct_connection_close(connection.handle.pointer, code, $0) }
        }

        private static func failure(status: Int32, code: UInt64, reason: String) -> TransportFailure {
            switch status {
            case MOQOM_DIRECT_CLOSED: .closedByPeer(code: code, reason: reason)
            case MOQOM_DIRECT_TIMEOUT: .idleTimeout
            case MOQOM_DIRECT_TLS: .untrustedPeer
            default: .unreachable
            }
        }
    }

    /// Owns the connection handle, so that it is freed exactly once, when the
    /// carrier and every loop that might re-arm on it are done with it.
    private final class Connection: @unchecked Sendable {
        let handle: RawHandle

        init(_ handle: RawHandle) {
            self.handle = handle
        }

        deinit {
            moqom_direct_connection_free(handle.pointer)
        }
    }

    /// The loss stream, and whether the ending was asked for.
    private final class Deliberate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: AsyncStream<TransportFailure>.Continuation?

        init(_ continuation: AsyncStream<TransportFailure>.Continuation) {
            self.continuation = continuation
        }

        func report(_ failure: TransportFailure) {
            guard let continuation = take() else { return }
            continuation.yield(failure)
            continuation.finish()
        }

        func silence() {
            take()?.finish()
        }

        private func take() -> AsyncStream<TransportFailure>.Continuation? {
            lock.withLock {
                defer { continuation = nil }
                return continuation
            }
        }
    }

    // MARK: - Streams

    /// The sending half of a stream.
    final class RustSendStream: QUICSendStream, @unchecked Sendable {
        private let handle: RawHandle
        private let lock = NSLock()
        private var ended = false

        init(_ handle: RawHandle) {
            self.handle = handle
        }

        deinit {
            moqom_direct_send_free(handle.pointer)
        }

        func write(_ data: Data) async throws(MoqomError) {
            let handle = handle
            let written = await awaitStatus { context in
                data.withUnsafeBytes { raw in
                    moqom_direct_send_write(
                        handle.pointer,
                        raw.bindMemory(to: UInt8.self).baseAddress,
                        raw.count,
                        context,
                        statusTrampoline
                    )
                }
            }
            guard written.status == MOQOM_DIRECT_OK else { throw MoqomError.transport(.closed) }
        }

        func finish() async {
            guard claim() else { return }
            _ = moqom_direct_send_finish(handle.pointer)
        }

        func reset(code: UInt64) async {
            guard claim() else { return }
            _ = moqom_direct_send_reset(handle.pointer, code)
        }

        private func claim() -> Bool {
            lock.withLock {
                defer { ended = true }
                return !ended
            }
        }
    }

    /// The receiving half of a stream.
    final class RustReceiveStream: QUICReceiveStream, @unchecked Sendable {
        /// What one read asks for: a large ceiling, as NetworkQUICCarrier's.
        static let chunk = 64 * 1024

        private let handle: RawHandle
        private let lock = NSLock()
        private var ended = false

        init(_ handle: RawHandle) {
            self.handle = handle
        }

        deinit {
            moqom_direct_recv_free(handle.pointer)
        }

        func read() async throws(MoqomError) -> Data? {
            if lock.withLock({ ended }) { return nil }
            let handle = handle
            let next = await awaitBytes { context in
                moqom_direct_recv_read(handle.pointer, Self.chunk, context, bytesTrampoline)
            }
            // End of stream, a reset, and a connection gone all read the same
            // to everything above: stop.
            guard next.status == MOQOM_DIRECT_OK else {
                lock.withLock { ended = true }
                return nil
            }
            return next.data ?? Data()
        }

        func stopReceiving(code: UInt64) async {
            _ = moqom_direct_recv_stop(handle.pointer, code)
        }
    }

    /// Both halves.
    final class RustBiStream: QUICStream, @unchecked Sendable {
        private let send: RustSendStream
        private let receive: RustReceiveStream

        init(send: RustSendStream, receive: RustReceiveStream) {
            self.send = send
            self.receive = receive
        }

        func write(_ data: Data) async throws(MoqomError) { try await send.write(data) }
        func finish() async { await send.finish() }
        func reset(code: UInt64) async { await send.reset(code: code) }
        func read() async throws(MoqomError) -> Data? { try await receive.read() }
        func stopReceiving(code: UInt64) async { await receive.stopReceiving(code: code) }
    }
#endif
