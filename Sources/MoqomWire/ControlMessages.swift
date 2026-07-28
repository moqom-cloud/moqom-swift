// Control messages and their envelope, per draft-19 §10.
//
// Draft-19 reworked this registry in ways that produce a silently wrong
// implementation rather than a compile error, so the shape here is worth
// stating plainly rather than assuming from an earlier draft:
//
//   - `ANNOUNCE` is now `PUBLISH_NAMESPACE`.
//   - Per-message `*_OK` and `*_ERROR` collapsed into generic `REQUEST_OK` and
//     `REQUEST_ERROR`.
//   - `CLIENT_SETUP` and `SERVER_SETUP` merged into one symmetric `SETUP` at
//     0x2F00 with no version field, because version selection moved to ALPN.
//   - There is no `UNSUBSCRIBE` and no `UNANNOUNCE`. Each request owns a
//     bidirectional stream and lives exactly as long as it, so cancellation is
//     a stream close. That is the single most consequential fact for the
//     session layer: withdrawing an announcement means dropping a stream.

import Foundation
import MoqomCore

/// Largest control message body: `2^16 - 1` bytes.
///
/// Message length is a fixed 16-bit field rather than a varint, which is a real
/// constraint rather than a formatting detail. An authorization token of a few
/// tens of kilobytes is the realistic way to reach it, and the failure has to
/// be caught when the message is built rather than discovered at the socket.
public let maximumControlBodyLength = (1 << 16) - 1

/// A control message type.
public enum MessageType: UInt64, Sendable, CaseIterable {
    case setup = 0x2F00
    case goaway = 0x10

    case subscribe = 0x3
    case subscribeOk = 0x4

    case publish = 0x1D
    case publishDone = 0xB
    case publishSkipped = 0xF

    case fetch = 0x16
    case fetchOk = 0x18

    case trackStatus = 0xD

    case publishNamespace = 0x6
    case namespace = 0x8
    case namespaceDone = 0xE
    case subscribeNamespace = 0x50
    case subscribeTracks = 0x51

    case requestUpdate = 0x2
    case requestOk = 0x7
    case requestError = 0x5

    /// Codes retired by earlier drafts.
    ///
    /// Distinguished from an unknown type because receiving one almost always
    /// means the peer is speaking a different draft, which is worth saying in
    /// the error rather than leaving someone to look up 0x40 themselves.
    private static let reserved: Set<UInt64> = [0x01, 0x40, 0x41, 0x20, 0x21, 0x1E]

    public init(code: UInt64) throws(WireError) {
        guard let type = MessageType(rawValue: code) else {
            if Self.reserved.contains(code) {
                throw WireError.invalid(
                    "control message type 0x\(String(code, radix: 16)) is from an earlier draft"
                )
            }
            throw WireError.invalid("unknown control message type 0x\(String(code, radix: 16))")
        }
        self = type
    }
}

/// A message body that knows its own type and size.
///
/// The point of this protocol is ``ControlFrame/write(_:to:)``, which is the
/// one place a message becomes bytes. Every body could encode itself directly
/// into a socket buffer and silently skip the 64 KiB check; routing through
/// here makes the check unavoidable and free, since the size is known before
/// anything is written.
/// `Equatable` is required rather than incidental: the only cheap check that a
/// port of this size is faithful is decode-encode-decode agreement, and a
/// message that cannot be compared cannot participate in it.
public protocol ControlMessage: Sendable, Equatable {
    static var messageType: MessageType { get }
    var encodedLength: Int { get }
    func write(to writer: inout WireWriter)
    static func read(from reader: inout WireReader) throws(WireError) -> Self
}

/// A control message body exceeded what the envelope can describe.
public struct BodyTooLong: Error, Hashable, Sendable {
    public let length: Int
}

/// The `type, length, body` envelope.
public enum ControlFrame {
    /// Write a complete framed message.
    ///
    /// Checks the length before writing anything, so an oversized message costs
    /// nothing and leaves `writer` untouched.
    public static func write(
        _ message: some ControlMessage,
        to writer: inout WireWriter
    ) throws(BodyTooLong) {
        let length = message.encodedLength
        guard length <= maximumControlBodyLength else { throw BodyTooLong(length: length) }

        writer.varInt(type(of: message).messageType.rawValue)
        writer.uint16(UInt16(length))

        let before = writer.count
        message.write(to: &writer)
        assert(
            writer.count - before == length,
            "encodedLength disagreed with write, so the framed length is wrong"
        )
    }

    /// Read one framed message, returning its type and undecoded body.
    ///
    /// Framing is kept separate from body parsing because the two fail
    /// differently: a body that does not match its declared length has
    /// desynchronised the control stream and the session cannot continue, while
    /// a body that parses badly is specific to one message.
    public static func read(
        from reader: inout WireReader
    ) throws(WireError) -> (type: MessageType, body: Data) {
        let code = try reader.varInt()
        let type = try MessageType(code: code)
        let length = Int(try reader.uint16())
        let body = try reader.take(length)
        return (type, body)
    }
}

// MARK: - Setup

/// The symmetric SETUP message.
///
/// The body is Setup Options and nothing else: no version list, no role, no
/// parameter count. Version selection happens in ALPN before any MOQT byte is
/// sent, so anything reaching this decoder has already agreed on a version.
public struct Setup: ControlMessage {
    public static let messageType = MessageType.setup

    public var options: Parameters

    public init(options: Parameters = Parameters()) {
        self.options = options
    }

    public var encodedLength: Int { options.encodedLength }

    public func write(to writer: inout WireWriter) {
        options.write(to: &writer)
    }

    public static func read(from reader: inout WireReader) throws(WireError) -> Setup {
        Setup(options: try Parameters.readToEnd(from: &reader))
    }
}

// MARK: - Namespace requests

/// Advertise that tracks are available under a namespace.
///
/// Opens a bidirectional stream, and the advertisement lasts exactly as long as
/// that stream.
public struct PublishNamespace: ControlMessage {
    public static let messageType = MessageType.publishNamespace

    public var requestID: UInt64
    public var namespace: TrackNamespace
    public var parameters: Parameters

    public init(requestID: UInt64, namespace: TrackNamespace, parameters: Parameters = Parameters()) {
        self.requestID = requestID
        self.namespace = namespace
        self.parameters = parameters
    }

    public var encodedLength: Int {
        WireSize.varInt(requestID) + namespace.encodedLength + parameters.encodedLengthCounted
    }

    public func write(to writer: inout WireWriter) {
        writer.varInt(requestID)
        namespace.write(to: &writer)
        parameters.writeCounted(to: &writer)
    }

    public static func read(from reader: inout WireReader) throws(WireError) -> PublishNamespace {
        PublishNamespace(
            requestID: try reader.varInt(),
            namespace: try TrackNamespace.read(from: &reader),
            parameters: try Parameters.readCounted(from: &reader)
        )
    }
}

/// Ask to be told about namespaces matching a prefix.
///
/// The peer answers on the same stream with ``Namespace`` for the current set
/// and then for each change, and ``NamespaceDone`` as they go away.
public struct SubscribeNamespace: ControlMessage {
    public static let messageType = MessageType.subscribeNamespace

    public var requestID: UInt64
    public var prefix: TrackNamespace
    public var parameters: Parameters

    public init(requestID: UInt64, prefix: TrackNamespace, parameters: Parameters = Parameters()) {
        self.requestID = requestID
        self.prefix = prefix
        self.parameters = parameters
    }

    public var encodedLength: Int {
        WireSize.varInt(requestID) + prefix.encodedLength + parameters.encodedLengthCounted
    }

    public func write(to writer: inout WireWriter) {
        writer.varInt(requestID)
        prefix.write(to: &writer)
        parameters.writeCounted(to: &writer)
    }

    public static func read(from reader: inout WireReader) throws(WireError) -> SubscribeNamespace {
        SubscribeNamespace(
            requestID: try reader.varInt(),
            prefix: try TrackNamespace.read(from: &reader),
            parameters: try Parameters.readCounted(from: &reader)
        )
    }
}

/// A namespace appearing under a watched prefix.
///
/// Carries only the *suffix* — the fields after the prefix the subscription was
/// opened with. Reassembling the full namespace is the reader's job, and it is
/// why two overlapping prefix subscriptions on one session are forbidden:
/// the suffix would be ambiguous.
public struct NamespaceAnnounced: ControlMessage {
    public static let messageType = MessageType.namespace

    public var suffix: TrackNamespace

    public init(suffix: TrackNamespace) { self.suffix = suffix }

    public var encodedLength: Int { suffix.encodedLength }

    public func write(to writer: inout WireWriter) {
        suffix.write(to: &writer)
    }

    public static func read(from reader: inout WireReader) throws(WireError) -> NamespaceAnnounced {
        NamespaceAnnounced(suffix: try TrackNamespace.read(from: &reader))
    }
}

/// A namespace under a watched prefix going away.
public struct NamespaceDone: ControlMessage {
    public static let messageType = MessageType.namespaceDone

    public var suffix: TrackNamespace

    public init(suffix: TrackNamespace) { self.suffix = suffix }

    public var encodedLength: Int { suffix.encodedLength }

    public func write(to writer: inout WireWriter) {
        suffix.write(to: &writer)
    }

    public static func read(from reader: inout WireReader) throws(WireError) -> NamespaceDone {
        NamespaceDone(suffix: try TrackNamespace.read(from: &reader))
    }
}

// MARK: - Subscribe

/// Request a track.
public struct Subscribe: ControlMessage {
    public static let messageType = MessageType.subscribe

    public var requestID: UInt64
    public var track: FullTrackName
    public var parameters: Parameters

    public init(requestID: UInt64, track: FullTrackName, parameters: Parameters = Parameters()) {
        self.requestID = requestID
        self.track = track
        self.parameters = parameters
    }

    public var encodedLength: Int {
        WireSize.varInt(requestID) + track.encodedLength + parameters.encodedLengthCounted
    }

    public func write(to writer: inout WireWriter) {
        writer.varInt(requestID)
        track.write(to: &writer)
        parameters.writeCounted(to: &writer)
    }

    public static func read(from reader: inout WireReader) throws(WireError) -> Subscribe {
        Subscribe(
            requestID: try reader.varInt(),
            track: try FullTrackName.read(from: &reader),
            parameters: try Parameters.readCounted(from: &reader)
        )
    }
}

/// Successful subscription response.
///
/// The track alias is the whole point: from here on the data plane names this
/// track by a varint rather than by a tuple, which is what keeps a subgroup
/// header down to a handful of bytes.
public struct SubscribeOk: ControlMessage {
    public static let messageType = MessageType.subscribeOk

    public var trackAlias: UInt64
    public var parameters: Parameters
    public var properties: Parameters

    public init(
        trackAlias: UInt64,
        parameters: Parameters = Parameters(),
        properties: Parameters = Parameters()
    ) {
        self.trackAlias = trackAlias
        self.parameters = parameters
        self.properties = properties
    }

    public var encodedLength: Int {
        WireSize.varInt(trackAlias) + parameters.encodedLengthCounted + properties.encodedLength
    }

    public func write(to writer: inout WireWriter) {
        writer.varInt(trackAlias)
        parameters.writeCounted(to: &writer)
        properties.write(to: &writer)
    }

    public static func read(from reader: inout WireReader) throws(WireError) -> SubscribeOk {
        SubscribeOk(
            trackAlias: try reader.varInt(),
            parameters: try Parameters.readCounted(from: &reader),
            properties: try Parameters.readToEnd(from: &reader)
        )
    }
}

// MARK: - Generic responses

/// Generic success response.
public struct RequestOk: ControlMessage {
    public static let messageType = MessageType.requestOk

    public var parameters: Parameters
    public var properties: Parameters

    public init(parameters: Parameters = Parameters(), properties: Parameters = Parameters()) {
        self.parameters = parameters
        self.properties = properties
    }

    public var encodedLength: Int {
        parameters.encodedLengthCounted + properties.encodedLength
    }

    public func write(to writer: inout WireWriter) {
        parameters.writeCounted(to: &writer)
        properties.write(to: &writer)
    }

    public static func read(from reader: inout WireReader) throws(WireError) -> RequestOk {
        RequestOk(
            parameters: try Parameters.readCounted(from: &reader),
            properties: try Parameters.readToEnd(from: &reader)
        )
    }
}

/// Error codes for ``RequestError``, per draft-19 §10.
public enum RequestErrorCode {
    public static let internalError: UInt64 = 0x0
    public static let unauthorized: UInt64 = 0x1
    public static let timeout: UInt64 = 0x2
    public static let notSupported: UInt64 = 0x3
    public static let malformedAuthToken: UInt64 = 0x4
    public static let expiredAuthToken: UInt64 = 0x5
    public static let goingAway: UInt64 = 0x6
    public static let excessiveLoad: UInt64 = 0x9
    public static let doesNotExist: UInt64 = 0x10
    public static let invalidRange: UInt64 = 0x11
    public static let malformedTrack: UInt64 = 0x12
    public static let uninterested: UInt64 = 0x20
    public static let prefixOverlap: UInt64 = 0x30
    public static let namespaceTooLarge: UInt64 = 0x31
    public static let invalidJoiningRequestID: UInt64 = 0x32
    public static let unsupportedExtension: UInt64 = 0x33
    public static let redirect: UInt64 = 0x34
    public static let conflictingFilters: UInt64 = 0x35
    public static let invalidFilter: UInt64 = 0x36
}

/// Maximum reason phrase length in bytes.
public let maximumReasonLength = 1024

/// Generic error response.
public struct RequestError: ControlMessage {
    public static let messageType = MessageType.requestError

    public var code: UInt64

    /// Milliseconds **plus one**: 0 means do not retry, 1 means retry now.
    ///
    /// The offset is the draft's, not ours, and it exists so that "never" and
    /// "immediately" are distinguishable without a second field.
    public var retryInterval: UInt64

    public var reason: String

    /// Present only when ``code`` is ``RequestErrorCode/redirect``.
    public var redirect: Redirect?

    public struct Redirect: Hashable, Sendable {
        /// Empty means stay on the current session.
        public var connectURI: String
        public var track: FullTrackName

        public init(connectURI: String, track: FullTrackName) {
            self.connectURI = connectURI
            self.track = track
        }

        var encodedLength: Int {
            WireSize.lengthPrefixed(connectURI) + track.encodedLength
        }

        func write(to writer: inout WireWriter) {
            writer.lengthPrefixed(connectURI)
            track.write(to: &writer)
        }
    }

    public init(
        code: UInt64,
        retryInterval: UInt64 = 0,
        reason: String = "",
        redirect: Redirect? = nil
    ) {
        self.code = code
        self.retryInterval = retryInterval
        // Truncated rather than rejected: a reason phrase is diagnostic, and
        // failing to send an error because its explanation was too long would
        // replace a useful message with no message.
        self.reason = reason.truncatedUTF8(to: maximumReasonLength)
        self.redirect = redirect
    }

    public var encodedLength: Int {
        WireSize.varInt(code)
            + WireSize.varInt(retryInterval)
            + WireSize.lengthPrefixed(reason)
            + (redirect?.encodedLength ?? 0)
    }

    public func write(to writer: inout WireWriter) {
        writer.varInt(code)
        writer.varInt(retryInterval)
        writer.lengthPrefixed(reason)
        redirect?.write(to: &writer)
    }

    public static func read(from reader: inout WireReader) throws(WireError) -> RequestError {
        let code = try reader.varInt()
        let retryInterval = try reader.varInt()
        let reasonBytes = try reader.lengthPrefixed()
        guard reasonBytes.count <= maximumReasonLength else {
            throw WireError.invalid("reason phrase exceeds \(maximumReasonLength) bytes")
        }
        let reason = String(data: reasonBytes, encoding: .utf8) ?? ""

        var redirect: Redirect?
        if code == RequestErrorCode.redirect {
            let uri = try reader.lengthPrefixed()
            redirect = Redirect(
                connectURI: String(data: uri, encoding: .utf8) ?? "",
                track: try FullTrackName.read(from: &reader)
            )
        }
        return RequestError(
            code: code,
            retryInterval: retryInterval,
            reason: reason,
            redirect: redirect
        )
    }
}

/// Modify an in-flight request.
public struct RequestUpdate: ControlMessage {
    public static let messageType = MessageType.requestUpdate

    public var requestID: UInt64
    public var parameters: Parameters

    public init(requestID: UInt64, parameters: Parameters = Parameters()) {
        self.requestID = requestID
        self.parameters = parameters
    }

    public var encodedLength: Int {
        WireSize.varInt(requestID) + parameters.encodedLengthCounted
    }

    public func write(to writer: inout WireWriter) {
        writer.varInt(requestID)
        parameters.writeCounted(to: &writer)
    }

    public static func read(from reader: inout WireReader) throws(WireError) -> RequestUpdate {
        RequestUpdate(
            requestID: try reader.varInt(),
            parameters: try Parameters.readCounted(from: &reader)
        )
    }
}

/// Maximum length of a GOAWAY's new session URI.
public let maximumSessionURILength = 8192

/// Notice that the sender intends to close the session.
///
/// A GOAWAY cancels nothing. Subscriptions stay live and the receiver is
/// expected to wind them down itself, so treating this as a teardown discards
/// state the peer still expects to exist.
public struct Goaway: ControlMessage {
    public static let messageType = MessageType.goaway

    /// Where to reconnect. Empty means the current URI.
    public var newSessionURI: String

    public var timeoutMilliseconds: UInt64

    public init(newSessionURI: String = "", timeoutMilliseconds: UInt64 = 0) {
        self.newSessionURI = newSessionURI
        self.timeoutMilliseconds = timeoutMilliseconds
    }

    public var encodedLength: Int {
        WireSize.lengthPrefixed(newSessionURI) + WireSize.varInt(timeoutMilliseconds)
    }

    public func write(to writer: inout WireWriter) {
        writer.lengthPrefixed(newSessionURI)
        writer.varInt(timeoutMilliseconds)
    }

    public static func read(from reader: inout WireReader) throws(WireError) -> Goaway {
        let uri = try reader.lengthPrefixed()
        guard uri.count <= maximumSessionURILength else {
            throw WireError.invalid("new session URI exceeds \(maximumSessionURILength) bytes")
        }
        return Goaway(
            newSessionURI: String(data: uri, encoding: .utf8) ?? "",
            timeoutMilliseconds: try reader.varInt()
        )
    }
}

private extension String {
    /// Truncate to a UTF-8 byte budget without splitting a scalar.
    func truncatedUTF8(to limit: Int) -> String {
        guard utf8.count > limit else { return self }
        var result = ""
        var used = 0
        for character in self {
            let width = String(character).utf8.count
            if used + width > limit { break }
            result.append(character)
            used += width
        }
        return result
    }
}
