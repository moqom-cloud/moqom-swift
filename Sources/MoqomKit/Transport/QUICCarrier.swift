// What MOQT needs from QUIC, and nothing else.
//
// This is the seam the original `Transport` comment said belonged below it, and
// it does. The difference is that it now exists in Swift, because the Rust
// client it was meant to live inside has no C ABI yet.
//
// Splitting it out rather than talking to Network.framework directly buys the
// one thing that matters for a protocol implementation: the session logic
// becomes testable without a socket, a certificate, or a listening port. Every
// interesting MOQT behaviour — the SETUP exchange, an announcement lasting
// exactly as long as its stream, a subscription resolving to a track alias,
// objects arriving on a stream opened after the subscription — is exercised
// against ``MemoryCarrier`` in CI, over the same bytes a real connection would
// carry. What remains untested is the adapter that moves those bytes, which is
// a much smaller and much more obvious thing to be unsure about.

import Foundation
import MoqomWire

/// A QUIC connection, as MOQT uses one.
///
/// Streams are the unit of protocol state here, not just of transfer. Draft-19
/// removed `UNSUBSCRIBE` and `UNANNOUNCE` because every request owns a
/// bidirectional stream and lives exactly as long as it does, so "close the
/// stream" is a protocol operation with meaning, not cleanup.
public protocol QUICCarrier: Sendable {
    /// The ALPN the handshake settled on.
    var alpn: String { get }

    /// Largest datagram payload the path will carry, or zero if the peer
    /// refused datagrams.
    var maximumDatagramSize: Int { get }

    func openBidirectionalStream() async throws(MoqomError) -> any QUICStream
    func openUnidirectionalStream() async throws(MoqomError) -> any QUICSendStream

    /// Streams the peer opened. Each is a request the peer is making of us.
    var incomingBidirectionalStreams: AsyncStream<any QUICStream> { get }

    /// Unidirectional streams the peer opened, which on the data plane is how
    /// every subgroup arrives.
    var incomingUnidirectionalStreams: AsyncStream<any QUICReceiveStream> { get }

    func send(datagram: Data) async throws(MoqomError)
    var datagrams: AsyncStream<Data> { get }

    /// The connection ending on its own.
    ///
    /// Yields at most once and then finishes. A deliberate
    /// ``close(code:reason:)`` finishes it without yielding, and that
    /// distinction is the whole point: the session above reconnects on
    /// everything that comes out of here, so a carrier that reported its own
    /// shutdown would have every clean disconnect immediately redial.
    ///
    /// There is no default implementation, deliberately. One that never fired
    /// would compile, behave exactly as this SDK did before it existed, and be
    /// wrong in a way that only shows up as a session that never comes back.
    var loss: AsyncStream<TransportFailure> { get }

    func close(code: UInt64, reason: String) async
}

/// The sending half of a stream.
public protocol QUICSendStream: Sendable, AnyObject {
    func write(_ data: Data) async throws(MoqomError)

    /// Close cleanly. The peer sees an orderly end of stream.
    func finish() async

    /// Abort. The peer sees a reset, which is how a request is cancelled as
    /// distinct from completing.
    func reset(code: UInt64) async
}

/// The receiving half of a stream.
public protocol QUICReceiveStream: Sendable, AnyObject {
    /// The next chunk, or `nil` at end of stream.
    ///
    /// Chunk boundaries carry no meaning — QUIC is a byte stream — so every
    /// reader above this has to reassemble. ``StreamFramer`` is that reader.
    func read() async throws(MoqomError) -> Data?

    func stopReceiving(code: UInt64) async
}

/// A bidirectional stream.
public protocol QUICStream: QUICSendStream, QUICReceiveStream {}

/// Reassembles control messages from a stream that knows nothing about them.
///
/// A read returns whatever bytes happened to arrive, which may be half a
/// message or three of them. This buffers until a whole frame is present, and
/// the property that makes it correct is inherited from the codec: a short read
/// consumes nothing, so retrying against the same buffer after more bytes
/// arrive is always safe.
struct StreamFramer: Sendable {
    private var buffer = Data()

    mutating func append(_ data: Data) {
        buffer.append(data)
    }

    /// The next complete frame, or `nil` if more bytes are needed.
    ///
    /// - Throws: ``WireError`` only for genuinely malformed input. A partial
    ///   frame is not an error and is reported as `nil`.
    mutating func next() throws(MoqomError) -> (type: MessageType, body: Data)? {
        guard !buffer.isEmpty else { return nil }
        var reader = WireReader(buffer)
        do {
            let frame = try ControlFrame.read(from: &reader)
            buffer = reader.rest
            return frame
        } catch {
            if case .short = error { return nil }
            throw MoqomError.protocolViolation(error.description)
        }
    }

    var pendingByteCount: Int { buffer.count }
}
