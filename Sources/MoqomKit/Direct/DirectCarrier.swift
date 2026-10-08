// What a direct session's carrier adds to the one underneath: a byte count,
// and on the accepting side the dialler's final word.
//
// The count exists because a direct session carries no relay egress, so the
// relay that meters every other session never sees these bytes. It is what
// ``DirectUsage`` reports from; see that type for how it is used.
//
// The final word is the empty unidirectional stream the dialler opens once it
// has checked this side's credentials. Until it arrives the acceptor has only
// been told the dialler's credentials are good, not that its own were, and a
// session the dialler refused must not be kept here either. It is consumed by
// this wrapper rather than reaching the session above, which would read it as
// a malformed data stream.

import Foundation

/// Payload bytes a direct session has moved, both ways.
///
/// Application bytes on streams and datagrams, not packets: QUIC framing and
/// retransmissions are not in it, so it slightly under-counts the wire and
/// never over-counts it.
public final class DirectUsage: @unchecked Sendable {
    private let lock = NSLock()
    private var sent: UInt64 = 0
    private var received: UInt64 = 0
    /// When the session was established.
    public let startedAt: Date

    init(startedAt: Date = Date()) {
        self.startedAt = startedAt
    }

    public var bytesSent: UInt64 { lock.withLock { sent } }
    public var bytesReceived: UInt64 { lock.withLock { received } }

    func add(sent count: Int) {
        lock.withLock { sent &+= UInt64(count) }
    }

    func add(received count: Int) {
        lock.withLock { received &+= UInt64(count) }
    }
}

final class DirectCarrier: QUICCarrier, @unchecked Sendable {
    private let base: any QUICCarrier
    let usage: DirectUsage
    private let onEnd: @Sendable () -> Void

    private let bidirectional: AsyncStream<any QUICStream>
    private let unidirectional: AsyncStream<any QUICReceiveStream>
    private let incomingDatagrams: AsyncStream<Data>
    private let lossStream: AsyncStream<TransportFailure>
    private let admitted: AsyncStream<Bool>
    private let pumps: [Task<Void, Never>]
    private let ended = OnceFlag()

    /// - Parameter awaitingAdmission: whether the first unidirectional stream
    ///   the peer opens is its admission signal rather than data.
    /// - Parameter onEnd: called once when the carrier is closed or lost, to
    ///   release whatever holds the connection open.
    init(
        _ base: any QUICCarrier,
        awaitingAdmission: Bool,
        usage: DirectUsage,
        onEnd: @escaping @Sendable () -> Void = {}
    ) {
        self.base = base
        self.usage = usage
        self.onEnd = onEnd

        let (bidirectional, bidirectionalIn) = AsyncStream.makeStream(
            of: (any QUICStream).self,
            bufferingPolicy: .unbounded
        )
        let (unidirectional, unidirectionalIn) = AsyncStream.makeStream(
            of: (any QUICReceiveStream).self,
            bufferingPolicy: .unbounded
        )
        let (datagrams, datagramsIn) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .bufferingNewest(256))
        let (loss, lossIn) = AsyncStream.makeStream(of: TransportFailure.self, bufferingPolicy: .bufferingNewest(1))
        let (admitted, admittedIn) = AsyncStream.makeStream(of: Bool.self, bufferingPolicy: .bufferingNewest(1))
        self.bidirectional = bidirectional
        self.unidirectional = unidirectional
        incomingDatagrams = datagrams
        lossStream = loss
        self.admitted = admitted
        if !awaitingAdmission { admittedIn.yield(true) }

        var pumps: [Task<Void, Never>] = []
        pumps.append(Task {
            for await stream in base.incomingBidirectionalStreams {
                bidirectionalIn.yield(MeteredStream(stream, usage: usage))
            }
            bidirectionalIn.finish()
        })
        pumps.append(Task {
            var awaiting = awaitingAdmission
            for await stream in base.incomingUnidirectionalStreams {
                if awaiting {
                    awaiting = false
                    // Read to its end so the stream is retired, then admitted:
                    // the signal is the stream existing, not what it carries.
                    while let chunk = try? await stream.read(), !chunk.isEmpty {}
                    admittedIn.yield(true)
                    admittedIn.finish()
                    continue
                }
                unidirectionalIn.yield(MeteredReceiveStream(stream, usage: usage))
            }
            unidirectionalIn.finish()
            admittedIn.yield(false)
            admittedIn.finish()
        })
        pumps.append(Task {
            for await datagram in base.datagrams {
                usage.add(received: datagram.count)
                datagramsIn.yield(datagram)
            }
            datagramsIn.finish()
        })
        pumps.append(Task { [ended] in
            for await failure in base.loss {
                lossIn.yield(failure)
            }
            lossIn.finish()
            admittedIn.yield(false)
            admittedIn.finish()
            if ended.claim() { onEnd() }
        })
        self.pumps = pumps
    }

    deinit {
        for pump in pumps { pump.cancel() }
    }

    /// Whether the dialler admitted this side: `true` once its signal
    /// arrives, `false` if the connection ends first.
    func admission() async -> Bool {
        for await verdict in admitted { return verdict }
        return false
    }

    var alpn: String { base.alpn }
    var maximumDatagramSize: Int { base.maximumDatagramSize }
    var peerCertificateDigest: String? { base.peerCertificateDigest }
    var incomingBidirectionalStreams: AsyncStream<any QUICStream> { bidirectional }
    var incomingUnidirectionalStreams: AsyncStream<any QUICReceiveStream> { unidirectional }
    var datagrams: AsyncStream<Data> { incomingDatagrams }
    var loss: AsyncStream<TransportFailure> { lossStream }

    func openBidirectionalStream() async throws(MoqomError) -> any QUICStream {
        MeteredStream(try await base.openBidirectionalStream(), usage: usage)
    }

    func openUnidirectionalStream() async throws(MoqomError) -> any QUICSendStream {
        MeteredSendStream(try await base.openUnidirectionalStream(), usage: usage)
    }

    func send(datagram: Data) async throws(MoqomError) {
        try await base.send(datagram: datagram)
        usage.add(sent: datagram.count)
    }

    func close(code: UInt64, reason: String) async {
        await base.close(code: code, reason: reason)
        if ended.claim() { onEnd() }
    }
}

/// Claimed once, from callbacks that may fire again.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            if claimed { return false }
            claimed = true
            return true
        }
    }
}

private final class MeteredStream: QUICStream, @unchecked Sendable {
    private let stream: any QUICStream
    private let usage: DirectUsage

    init(_ stream: any QUICStream, usage: DirectUsage) {
        self.stream = stream
        self.usage = usage
    }

    func write(_ data: Data) async throws(MoqomError) {
        try await stream.write(data)
        usage.add(sent: data.count)
    }

    func finish() async { await stream.finish() }
    func reset(code: UInt64) async { await stream.reset(code: code) }

    func read() async throws(MoqomError) -> Data? {
        let chunk = try await stream.read()
        if let chunk { usage.add(received: chunk.count) }
        return chunk
    }

    func stopReceiving(code: UInt64) async { await stream.stopReceiving(code: code) }
}

private final class MeteredSendStream: QUICSendStream, @unchecked Sendable {
    private let stream: any QUICSendStream
    private let usage: DirectUsage

    init(_ stream: any QUICSendStream, usage: DirectUsage) {
        self.stream = stream
        self.usage = usage
    }

    func write(_ data: Data) async throws(MoqomError) {
        try await stream.write(data)
        usage.add(sent: data.count)
    }

    func finish() async { await stream.finish() }
    func reset(code: UInt64) async { await stream.reset(code: code) }
}

private final class MeteredReceiveStream: QUICReceiveStream, @unchecked Sendable {
    private let stream: any QUICReceiveStream
    private let usage: DirectUsage

    init(_ stream: any QUICReceiveStream, usage: DirectUsage) {
        self.stream = stream
        self.usage = usage
    }

    func read() async throws(MoqomError) -> Data? {
        let chunk = try await stream.read()
        if let chunk { usage.add(received: chunk.count) }
        return chunk
    }

    func stopReceiving(code: UInt64) async { await stream.stopReceiving(code: code) }
}
