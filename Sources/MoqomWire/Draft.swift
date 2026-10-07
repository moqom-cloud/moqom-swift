// Which MoQ Transport draft a session speaks, and what that changes.
//
// Drafts do not interoperate and nothing in a MOQT byte says which one wrote
// it, so the draft is fixed once, from the ALPN QUIC negotiated, and every codec
// below that point is told rather than left to guess. Three are spoken:
//
//   - **draft-16** (`moqt-16`), for Cloudflare's relays, which serve nothing
//     later. Requests and responses share one bidirectional control stream and
//     are matched by Request ID, setup is the older CLIENT_SETUP/SERVER_SETUP
//     pair, and there is UNSUBSCRIBE and PUBLISH_OK. Types in ``Draft16``.
//   - **draft-19** (`moqt-19`), as MOQOM's relays speak it. This is a profile,
//     not a transcription: it keeps RFC 9000 varints and a single bidirectional
//     control stream, where published draft-19 has the draft-17 varint and a
//     pair of unidirectional control streams. It is what both MOQOM codecs and
//     every deployed SDK speak, so it is left exactly as it was.
//   - **draft-22** (`moqt-22`), followed as written: the vi64 varint, a
//     unidirectional control stream each way, Message Parameters whose value
//     encoding is fixed per type, and fill fetch streams. Types in ``Draft22``.
//
// Request messages that did not change between drafts are shared, which is
// most of them: a body written to a ``WireWriter`` in the draft's encoding is
// already the right bytes.

import Foundation
import MoqomCore

/// A MoQ Transport draft this package can speak.
public enum MoqtDraft: Int, CaseIterable, Comparable, Hashable, Sendable {
    case draft16 = 16
    case draft19 = 19
    case draft22 = 22

    /// The ALPN token that selects this draft.
    public var alpn: String { "moqt-\(rawValue)" }

    /// The draft an ALPN token names, or `nil` for one this package does not
    /// speak.
    public init?(alpn: String) {
        guard alpn.hasPrefix("moqt-"), let number = Int(alpn.dropFirst(5)),
              let draft = MoqtDraft(rawValue: number)
        else { return nil }
        self = draft
    }

    /// What a MOQOM client offers a MOQOM relay, most preferred first.
    ///
    /// Draft-16 is absent on purpose: it is only for relays that speak nothing
    /// later, and offering it to one that speaks both would let a server that
    /// prefers older drafts pick it.
    public static let moqomPreference: [MoqtDraft] = [.draft22, .draft19]

    public var varIntEncoding: VarIntEncoding {
        switch self {
        case .draft16, .draft19: .quic
        case .draft22: .vi64
        }
    }

    /// Whether every request has a bidirectional stream of its own, whose
    /// lifetime is the request's. Draft-16 multiplexes requests on the control
    /// stream by Request ID instead, except SUBSCRIBE_NAMESPACE.
    public var requestsOwnStreams: Bool { self != .draft16 }

    /// Whether each endpoint opens a unidirectional control stream beginning
    /// with SETUP, rather than the client opening one bidirectional stream.
    public var controlStreamsAreUnidirectional: Bool { self == .draft22 }

    /// A writer in this draft's varint encoding.
    public func writer(capacity: Int = 0) -> WireWriter {
        WireWriter(capacity: capacity, encoding: varIntEncoding)
    }

    /// A reader in this draft's varint encoding.
    public func reader(_ data: Data) -> WireReader {
        WireReader(data, encoding: varIntEncoding)
    }

    public static func < (lhs: MoqtDraft, rhs: MoqtDraft) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A control message in a specific draft, framed by ``ControlFrame``.
///
/// Separate from ``ControlMessage`` because the type code is the draft's to
/// assign rather than a member of the draft-19 ``MessageType`` registry, and
/// because a body is measured by writing it rather than by a precomputed
/// `encodedLength`, which reports QUIC sizes.
public protocol DraftControlMessage: Sendable, Equatable {
    static var typeCode: UInt64 { get }
    func write(to writer: inout WireWriter)
    static func read(from reader: inout WireReader) throws(WireError) -> Self
}

public extension ControlFrame {
    /// Frame `body` under `typeCode`, in the writer's encoding.
    static func write(
        typeCode: UInt64,
        body: Data,
        to writer: inout WireWriter
    ) throws(BodyTooLong) {
        guard body.count <= maximumControlBodyLength else { throw BodyTooLong(length: body.count) }
        writer.varInt(typeCode)
        writer.uint16(UInt16(body.count))
        writer.raw(body)
    }

    /// Frame a message for whichever draft `writer` is encoding.
    static func write(
        _ message: some DraftControlMessage,
        to writer: inout WireWriter
    ) throws(BodyTooLong) {
        var body = WireWriter(encoding: writer.encoding)
        message.write(to: &body)
        try write(typeCode: type(of: message).typeCode, body: body.bytes, to: &writer)
    }

    /// Frame a draft-19 message body in another draft's encoding.
    ///
    /// For the messages whose layout did not change, which is how most of the
    /// draft-19 types serve draft-22 and draft-16 too.
    static func write(
        _ message: some ControlMessage,
        as typeCode: UInt64,
        to writer: inout WireWriter
    ) throws(BodyTooLong) {
        var body = WireWriter(capacity: message.encodedLength, encoding: writer.encoding)
        message.write(to: &body)
        try write(typeCode: typeCode, body: body.bytes, to: &writer)
    }

    /// Read one frame without interpreting its type code.
    ///
    /// The draft decides which codes exist, so the caller checks; this only
    /// guarantees that a whole frame was there.
    static func readRaw(from reader: inout WireReader) throws(WireError) -> (code: UInt64, body: Data) {
        let start = reader
        do {
            let code = try reader.varInt()
            let length = Int(try reader.uint16())
            return (code, try reader.take(length))
        } catch {
            reader = start
            throw error
        }
    }
}

public extension DraftControlMessage {
    /// Decode a body that must be consumed exactly.
    ///
    /// Draft-22 §9: a length that disagrees with the body is a
    /// PROTOCOL_VIOLATION, so trailing bytes are an error here rather than
    /// something to skip.
    static func decode(_ body: Data, _ draft: MoqtDraft) throws(WireError) -> Self {
        try decodeExactly(body, draft) { reader throws(WireError) in try read(from: &reader) }
    }
}

public extension ControlMessage {
    /// Decode a draft-19 type's body in another draft's encoding, exactly.
    static func decode(_ body: Data, _ draft: MoqtDraft) throws(WireError) -> Self {
        try decodeExactly(body, draft) { reader throws(WireError) in try read(from: &reader) }
    }
}

private func decodeExactly<Message>(
    _ body: Data,
    _ draft: MoqtDraft,
    _ read: (inout WireReader) throws(WireError) -> Message
) throws(WireError) -> Message {
    var reader = draft.reader(body)
    let message: Message
    do {
        message = try read(&reader)
    } catch {
        // The frame is complete, so running out of body is malformed rather
        // than a reason to wait for more bytes.
        if case .short = error { throw WireError.invalid("\(Message.self) is truncated") }
        throw error
    }
    guard reader.isEmpty else {
        throw WireError.invalid("\(reader.remaining) trailing bytes after \(Message.self)")
    }
    return message
}
