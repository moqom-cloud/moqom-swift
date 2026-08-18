// A QUIC carrier with no QUIC under it.
//
// This is what makes the MOQT session testable. `LoopbackTransport` next door
// short-circuits the protocol entirely — it moves `TrackObject` values between
// actors and never encodes a byte — which is right for a sample app but proves
// nothing about the codec. A ``MemoryCarrier`` pair moves real draft-19 bytes
// through real stream semantics, so a session driven over one exercises SETUP,
// request streams, subgroup framing, and alias resolution exactly as it would
// over a socket.
//
// What it deliberately does not model is the part QUIC is hard at: loss,
// reordering, flow control, and the fact that a write can block for a long
// time. Streams here are ordered and infinitely fast, so this can demonstrate
// that the protocol logic is right and cannot demonstrate that it behaves under
// pressure. Datagrams are delivered reliably, which is a lie, and an honest one
// to tell here rather than in a test that intermittently fails.

import Foundation
import MoqomKit

/// One direction of a stream: an ordered, unbounded byte pipe.
///
/// Hand-rolled rather than an `AsyncStream` because a stream half needs a
/// single consumer that can be resumed, and `AsyncStream`'s iterator is a
/// mutating struct that cannot be held across a suspension inside an actor
/// without either copying it or serialising by hand. A buffer and one waiter is
/// less machinery and says exactly what it does.
private actor Pipe {
    private var buffer: [Data] = []
    private var isClosed = false
    private var waiter: CheckedContinuation<Data?, Never>?

    func write(_ data: Data) {
        guard !isClosed else { return }
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: data)
            return
        }
        buffer.append(data)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        // Anything already buffered stays readable: a peer that wrote and then
        // finished has delivered those bytes, and discarding them here would
        // lose the last message of every cleanly closed stream.
        if let waiter, buffer.isEmpty {
            self.waiter = nil
            waiter.resume(returning: nil)
        }
    }

    func read() async -> Data? {
        if !buffer.isEmpty { return buffer.removeFirst() }
        if isClosed { return nil }
        return await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }
}

/// A bidirectional in-memory stream.
public final class MemoryStream: QUICStream {
    private let outbound: Pipe
    private let inbound: Pipe
    private let state = State()

    private actor State {
        var isFinished = false
        var resetCode: UInt64?

        func finish() -> Bool {
            guard !isFinished else { return false }
            isFinished = true
            return true
        }

        func reset(_ code: UInt64) -> Bool {
            guard !isFinished else { return false }
            isFinished = true
            resetCode = code
            return true
        }
    }

    fileprivate init(outbound: Pipe, inbound: Pipe) {
        self.outbound = outbound
        self.inbound = inbound
    }

    public func write(_ data: Data) async throws(MoqomError) {
        if await state.isFinished { throw MoqomError.transport(.closed) }
        await outbound.write(data)
    }

    public func finish() async {
        if await state.finish() { await outbound.close() }
    }

    public func reset(code: UInt64) async {
        if await state.reset(code) { await outbound.close() }
    }

    public func read() async throws(MoqomError) -> Data? {
        await inbound.read()
    }

    public func stopReceiving(code: UInt64) async {
        await reset(code: code)
    }
}

/// The send half of a unidirectional stream.
public final class MemorySendStream: QUICSendStream {
    private let pipe: Pipe

    fileprivate init(pipe: Pipe) { self.pipe = pipe }

    public func write(_ data: Data) async throws(MoqomError) {
        await pipe.write(data)
    }

    public func finish() async { await pipe.close() }
    public func reset(code _: UInt64) async { await pipe.close() }
}

/// The receive half of a unidirectional stream.
public final class MemoryReceiveStream: QUICReceiveStream {
    private let pipe: Pipe

    fileprivate init(pipe: Pipe) { self.pipe = pipe }

    public func read() async throws(MoqomError) -> Data? {
        await pipe.read()
    }

    public func stopReceiving(code _: UInt64) async {}
}

/// One end of an in-memory connection.
public final class MemoryCarrier: QUICCarrier {
    public let alpn: String
    public let maximumDatagramSize: Int

    /// What a proof of possession made over this connection is bound to.
    ///
    /// Settable rather than always `nil`, because "there is no certificate" and
    /// "there is one, and here is its digest" are different code paths in the
    /// session above and both deserve a test. There is no TLS here, so this is a
    /// stand-in for one and nothing verifies it.
    public let peerCertificateDigest: String?

    private let incomingBidirectional: AsyncStream<any QUICStream>
    private let incomingUnidirectional: AsyncStream<any QUICReceiveStream>
    private let incomingDatagrams: AsyncStream<Data>

    private let peerBidirectional: AsyncStream<any QUICStream>.Continuation
    private let peerUnidirectional: AsyncStream<any QUICReceiveStream>.Continuation
    private let peerDatagrams: AsyncStream<Data>.Continuation

    private let lossStream: AsyncStream<TransportFailure>
    private let lossContinuation: AsyncStream<TransportFailure>.Continuation

    /// The other end's loss continuation, so a drop takes down both sides.
    private let peerLoss: AsyncStream<TransportFailure>.Continuation

    private let closed = Closed()

    private actor Closed {
        var isClosed = false
        func close() { isClosed = true }
    }

    /// Two carriers wired to each other.
    ///
    /// - Parameter alpn: reported by both ends, since a handshake that had
    ///   really happened would have agreed on one.
    /// - Parameter certificate: stood in for the relay's, on both ends. `nil`
    ///   means a carrier with nothing underneath it to identify, which is what
    ///   an in-memory pair honestly is and what most tests want.
    public static func pair(
        alpn: String = "moqt-19",
        maximumDatagramSize: Int = 1200,
        certificate: String? = nil
    ) -> (client: MemoryCarrier, server: MemoryCarrier) {
        let (clientBidi, clientBidiIn) = AsyncStream.makeStream(
            of: (any QUICStream).self,
            bufferingPolicy: .unbounded
        )
        let (serverBidi, serverBidiIn) = AsyncStream.makeStream(
            of: (any QUICStream).self,
            bufferingPolicy: .unbounded
        )
        let (clientUni, clientUniIn) = AsyncStream.makeStream(
            of: (any QUICReceiveStream).self,
            bufferingPolicy: .unbounded
        )
        let (serverUni, serverUniIn) = AsyncStream.makeStream(
            of: (any QUICReceiveStream).self,
            bufferingPolicy: .unbounded
        )
        let (clientDatagrams, clientDatagramsIn) = AsyncStream.makeStream(
            of: Data.self,
            bufferingPolicy: .unbounded
        )
        let (serverDatagrams, serverDatagramsIn) = AsyncStream.makeStream(
            of: Data.self,
            bufferingPolicy: .unbounded
        )
        let (clientLoss, clientLossIn) = AsyncStream.makeStream(
            of: TransportFailure.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let (serverLoss, serverLossIn) = AsyncStream.makeStream(
            of: TransportFailure.self,
            bufferingPolicy: .bufferingNewest(1)
        )

        let client = MemoryCarrier(
            alpn: alpn,
            maximumDatagramSize: maximumDatagramSize,
            certificate: certificate,
            incomingBidirectional: clientBidi,
            incomingUnidirectional: clientUni,
            incomingDatagrams: clientDatagrams,
            peerBidirectional: serverBidiIn,
            peerUnidirectional: serverUniIn,
            peerDatagrams: serverDatagramsIn,
            loss: clientLoss,
            lossContinuation: clientLossIn,
            peerLoss: serverLossIn
        )
        let server = MemoryCarrier(
            alpn: alpn,
            maximumDatagramSize: maximumDatagramSize,
            certificate: certificate,
            incomingBidirectional: serverBidi,
            incomingUnidirectional: serverUni,
            incomingDatagrams: serverDatagrams,
            peerBidirectional: clientBidiIn,
            peerUnidirectional: clientUniIn,
            peerDatagrams: clientDatagramsIn,
            loss: serverLoss,
            lossContinuation: serverLossIn,
            peerLoss: clientLossIn
        )
        return (client, server)
    }

    private init(
        alpn: String,
        maximumDatagramSize: Int,
        certificate: String?,
        incomingBidirectional: AsyncStream<any QUICStream>,
        incomingUnidirectional: AsyncStream<any QUICReceiveStream>,
        incomingDatagrams: AsyncStream<Data>,
        peerBidirectional: AsyncStream<any QUICStream>.Continuation,
        peerUnidirectional: AsyncStream<any QUICReceiveStream>.Continuation,
        peerDatagrams: AsyncStream<Data>.Continuation,
        loss: AsyncStream<TransportFailure>,
        lossContinuation: AsyncStream<TransportFailure>.Continuation,
        peerLoss: AsyncStream<TransportFailure>.Continuation
    ) {
        self.alpn = alpn
        self.maximumDatagramSize = maximumDatagramSize
        peerCertificateDigest = certificate
        self.incomingBidirectional = incomingBidirectional
        self.incomingUnidirectional = incomingUnidirectional
        self.incomingDatagrams = incomingDatagrams
        self.peerBidirectional = peerBidirectional
        self.peerUnidirectional = peerUnidirectional
        self.peerDatagrams = peerDatagrams
        lossStream = loss
        self.lossContinuation = lossContinuation
        self.peerLoss = peerLoss
    }

    public var loss: AsyncStream<TransportFailure> { lossStream }

    /// Take the connection away, as the network would.
    ///
    /// The counterpart to ``close(code:reason:)`` and the reason the two are
    /// separate: a close is a decision and must not provoke a reconnect, and
    /// this must. Both ends learn, because a dropped path is not one-sided.
    public func drop(_ failure: TransportFailure = .idleTimeout) async {
        await closed.close()
        lossContinuation.yield(failure)
        lossContinuation.finish()
        peerLoss.yield(failure)
        peerLoss.finish()
        peerBidirectional.finish()
        peerUnidirectional.finish()
        peerDatagrams.finish()
    }

    public var incomingBidirectionalStreams: AsyncStream<any QUICStream> {
        incomingBidirectional
    }

    public var incomingUnidirectionalStreams: AsyncStream<any QUICReceiveStream> {
        incomingUnidirectional
    }

    public var datagrams: AsyncStream<Data> { incomingDatagrams }

    public func openBidirectionalStream() async throws(MoqomError) -> any QUICStream {
        if await closed.isClosed { throw MoqomError.transport(.closed) }
        let forward = Pipe()
        let back = Pipe()
        let mine = MemoryStream(outbound: forward, inbound: back)
        let theirs = MemoryStream(outbound: back, inbound: forward)
        peerBidirectional.yield(theirs)
        return mine
    }

    public func openUnidirectionalStream() async throws(MoqomError) -> any QUICSendStream {
        if await closed.isClosed { throw MoqomError.transport(.closed) }
        let pipe = Pipe()
        peerUnidirectional.yield(MemoryReceiveStream(pipe: pipe))
        return MemorySendStream(pipe: pipe)
    }

    public func send(datagram: Data) async throws(MoqomError) {
        if await closed.isClosed { throw MoqomError.transport(.closed) }
        guard datagram.count <= maximumDatagramSize else {
            // Real QUIC drops these silently at the socket, which is the single
            // most confusing failure in a media stack. Surfacing it costs
            // nothing and turns a black stream into an error message.
            throw MoqomError.protocolViolation(
                "datagram of \(datagram.count) bytes exceeds the \(maximumDatagramSize) byte path"
            )
        }
        peerDatagrams.yield(datagram)
    }

    public func close(code _: UInt64, reason _: String) async {
        await closed.close()
        // Finished, never yielded. See ``drop(_:)``.
        lossContinuation.finish()
        peerBidirectional.finish()
        peerUnidirectional.finish()
        peerDatagrams.finish()
    }
}
