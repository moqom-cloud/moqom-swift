// Draft-16 control messages: the subset a MOQOM client needs against a relay
// that speaks `moqt-16`, which today means Cloudflare's.
//
// Draft-16 shares the byte vocabulary of the draft-19 profile — QUIC varints,
// key-value pairs with delta-encoded types, the same data plane less the
// FIRST_OBJECT bit — and differs in where things go:
//
//   - **One control stream, multiplexed by Request ID.** Responses carry the
//     request's ID as their first field, because they arrive on the shared
//     control stream rather than on a stream of their own. The exception is
//     SUBSCRIBE_NAMESPACE (§9.25), which opens a bidirectional stream and gets
//     its REQUEST_OK, NAMESPACE and NAMESPACE_DONE back on it.
//   - **Setup is two messages**, CLIENT_SETUP (0x20) and SERVER_SETUP (0x21),
//     each with a parameter count. PATH (0x01) and AUTHORITY (0x05) exist
//     because raw QUIC has no URL; the client puts its MAX_REQUEST_ID in
//     CLIENT_SETUP, and a relay that sees none grants no requests.
//   - **Request IDs are flow-controlled.** The client's IDs are even from 0,
//     and it may not exceed what the server's MAX_REQUEST_ID allows;
//     REQUESTS_BLOCKED says it tried.
//   - **SUBSCRIPTION_FILTER** (0x21) is a parameter whose bytes are a filter
//     type and the locations it needs, not draft-22's LOCATION_FILTER.
//   - **PUBLISH_DONE's EXPIRED and TOO_FAR_BEHIND are swapped** relative to
//     draft-19 and draft-22: here EXPIRED is 0x5 and TOO_FAR_BEHIND 0x6.
//
// Only messages a MOQOM client sends or must understand are here. FETCH and
// REQUEST_UPDATE have codes so a session can name them in an error, and no
// bodies, because Cloudflare does not implement them.

import Foundation
import MoqomCore

/// Draft-16 message types and codecs.
public enum Draft16 {
    /// Control message type codes (§9, Table 3).
    public enum MessageCode: UInt64, CaseIterable, Sendable {
        case clientSetup = 0x20
        case serverSetup = 0x21
        case goaway = 0x10
        case maxRequestID = 0x15
        case requestsBlocked = 0x1A
        case requestUpdate = 0x2
        case subscribe = 0x3
        case subscribeOk = 0x4
        case requestError = 0x5
        case publishNamespace = 0x6
        case requestOk = 0x7
        case namespace = 0x8
        case publishNamespaceDone = 0x9
        case unsubscribe = 0xA
        case publishDone = 0xB
        case publishNamespaceCancel = 0xC
        case trackStatus = 0xD
        case namespaceDone = 0xE
        case subscribeNamespace = 0x11
        case fetch = 0x16
        case fetchCancel = 0x17
        case fetchOk = 0x18
        case publish = 0x1D
        case publishOk = 0x1E

        public init(code: UInt64) throws(WireError) {
            guard let known = MessageCode(rawValue: code) else {
                throw WireError.invalid("unknown control message type 0x\(String(code, radix: 16))")
            }
            self = known
        }
    }

    /// Setup Parameter types (§9.3.1).
    public enum SetupParameter {
        /// The request path, with query, as the client would put in a URL.
        /// Raw QUIC only; the token for Cloudflare's demo relay rides here.
        public static let path: UInt64 = 0x01
        public static let maxRequestID: UInt64 = 0x02
        public static let authorizationToken: UInt64 = 0x03
        public static let maxAuthTokenCacheSize: UInt64 = 0x04
        /// Host, and `:port` only if the client was given one explicitly.
        public static let authority: UInt64 = 0x05
        public static let implementation: UInt64 = 0x07
    }

    /// Message Parameter types (§9.2.2). Key-value pairs, so the parity rule
    /// decides the encoding: even types are varints, odd ones bytes.
    public enum Parameter {
        public static let deliveryTimeout: UInt64 = 0x02
        public static let authorizationToken: UInt64 = 0x03
        public static let expires: UInt64 = 0x08
        /// Bytes: a Location.
        public static let largestObject: UInt64 = 0x09
        public static let forward: UInt64 = 0x10
        public static let subscriberPriority: UInt64 = 0x20
        /// Bytes: a ``SubscriptionFilter``.
        public static let subscriptionFilter: UInt64 = 0x21
        public static let groupOrder: UInt64 = 0x22
        public static let newGroupRequest: UInt64 = 0x32
    }

    /// PUBLISH_DONE status codes (§13.4.3). Not ``PublishDoneStatus``: two of
    /// them trade places in draft-19.
    public enum DoneStatus {
        public static let internalError: UInt64 = 0x0
        public static let unauthorized: UInt64 = 0x1
        public static let trackEnded: UInt64 = 0x2
        public static let subscriptionEnded: UInt64 = 0x3
        public static let goingAway: UInt64 = 0x4
        public static let expired: UInt64 = 0x5
        public static let tooFarBehind: UInt64 = 0x6
        public static let updateFailed: UInt64 = 0x8
        public static let malformedTrack: UInt64 = 0x12

        /// The same status in draft-19's registry, which is what the rest of
        /// the SDK speaks.
        public static func draft19(_ status: UInt64) -> UInt64 {
            switch status {
            case expired: PublishDoneStatus.expired
            case tooFarBehind: PublishDoneStatus.tooFarBehind
            default: status
            }
        }
    }
}

// MARK: - Subscription filter

extension Draft16 {
    /// The value of SUBSCRIPTION_FILTER (§9.2.2.5): a Filter Type, then a start
    /// Location for the absolute types, then an end group for a range.
    public enum SubscriptionFilter: Hashable, Sendable {
        /// From the start of the next group.
        case nextGroupStart
        /// From the largest object the publisher has.
        case largestObject
        case absoluteStart(Location)
        /// From `start` through the whole of `endGroup`.
        case absoluteRange(start: Location, endGroup: UInt64)

        public var parameter: MoqomWire.Parameter {
            var writer = WireWriter()
            switch self {
            case .nextGroupStart:
                writer.varInt(0x1)
            case .largestObject:
                writer.varInt(0x2)
            case let .absoluteStart(start):
                writer.varInt(0x3)
                start.write(to: &writer)
            case let .absoluteRange(start, endGroup):
                writer.varInt(0x4)
                start.write(to: &writer)
                writer.varInt(endGroup)
            }
            // An odd type always takes bytes, so this cannot throw.
            return try! .bytes(Parameter.subscriptionFilter, writer.bytes)
        }

        public init(bytes: Data) throws(WireError) {
            var reader = WireReader(bytes)
            switch try reader.varInt() {
            case 0x1: self = .nextGroupStart
            case 0x2: self = .largestObject
            case 0x3: self = .absoluteStart(try Location.read(from: &reader))
            case 0x4:
                let start = try Location.read(from: &reader)
                let endGroup = try reader.varInt()
                guard endGroup >= start.group else {
                    throw WireError.invalid("subscription filter ends before it starts")
                }
                self = .absoluteRange(start: start, endGroup: endGroup)
            case let other:
                throw WireError.invalid("unknown subscription filter type \(other)")
            }
            guard reader.isEmpty else {
                throw WireError.invalid("trailing bytes in subscription filter")
            }
        }
    }
}

public extension Parameters {
    /// LARGEST_OBJECT from a draft-16 SUBSCRIBE_OK, PUBLISH or REQUEST_OK.
    var draft16LargestObject: Location? {
        get throws(WireError) {
            guard let bytes = bytes(Draft16.Parameter.largestObject) else { return nil }
            var reader = WireReader(bytes)
            let location = try Location.read(from: &reader)
            guard reader.isEmpty else { throw WireError.invalid("trailing bytes in LARGEST_OBJECT") }
            return location
        }
    }
}

// MARK: - Setup

extension Draft16 {
    /// CLIENT_SETUP (§9.3).
    public struct ClientSetup: DraftControlMessage {
        public static let typeCode = MessageCode.clientSetup.rawValue

        public var parameters: Parameters

        public init(parameters: Parameters) {
            self.parameters = parameters
        }

        /// What a raw-QUIC client sends, in the shape moq-rs sends it.
        ///
        /// `path` includes the leading slash and any query. Nothing private to
        /// MOQOM goes in: a relay that is not MOQOM's has no use for it, and
        /// draft-16 gives no guarantee that unknown setup parameters are
        /// ignored rather than refused.
        public init(authority: String, path: String, maxRequestID: UInt64, implementation: String? = nil) {
            var parameters = Parameters()
            // Strings that fit a u16-framed message; a longer one is a caller
            // bug that the frame would reject anyway.
            parameters.insert(try! .string(SetupParameter.authority, authority))
            parameters.insert(try! .string(SetupParameter.path, path))
            parameters.insert(try! .integer(SetupParameter.maxRequestID, maxRequestID))
            if let implementation {
                parameters.insert(try! .string(SetupParameter.implementation, implementation))
            }
            self.init(parameters: parameters)
        }

        public func write(to writer: inout WireWriter) {
            parameters.writeCounted(to: &writer)
        }

        public static func read(from reader: inout WireReader) throws(WireError) -> ClientSetup {
            ClientSetup(parameters: try Parameters.readCounted(from: &reader))
        }
    }

    /// SERVER_SETUP (§9.3).
    public struct ServerSetup: DraftControlMessage {
        public static let typeCode = MessageCode.serverSetup.rawValue

        public var parameters: Parameters

        public init(parameters: Parameters = Parameters()) {
            self.parameters = parameters
        }

        /// The number of requests the server grants before its first
        /// MAX_REQUEST_ID; absent means none.
        public var maxRequestID: UInt64 { parameters.integer(SetupParameter.maxRequestID) ?? 0 }

        public func write(to writer: inout WireWriter) {
            parameters.writeCounted(to: &writer)
        }

        public static func read(from reader: inout WireReader) throws(WireError) -> ServerSetup {
            ServerSetup(parameters: try Parameters.readCounted(from: &reader))
        }
    }

    /// MAX_REQUEST_ID (§9.5): one more than the largest Request ID the sender
    /// will accept.
    public struct MaxRequestID: DraftControlMessage {
        public static let typeCode = MessageCode.maxRequestID.rawValue

        public var requestID: UInt64

        public init(_ requestID: UInt64) {
            self.requestID = requestID
        }

        public func write(to writer: inout WireWriter) {
            writer.varInt(requestID)
        }

        public static func read(from reader: inout WireReader) throws(WireError) -> MaxRequestID {
            MaxRequestID(try reader.varInt())
        }
    }

    /// REQUESTS_BLOCKED (§9.6): the sender wanted an ID at or past `maximum`.
    public struct RequestsBlocked: DraftControlMessage {
        public static let typeCode = MessageCode.requestsBlocked.rawValue

        public var maximum: UInt64

        public init(maximum: UInt64) {
            self.maximum = maximum
        }

        public func write(to writer: inout WireWriter) {
            writer.varInt(maximum)
        }

        public static func read(from reader: inout WireReader) throws(WireError) -> RequestsBlocked {
            RequestsBlocked(maximum: try reader.varInt())
        }
    }

    /// GOAWAY (§9.4). Draft-16 has no timeout field.
    public struct Goaway: DraftControlMessage {
        public static let typeCode = MessageCode.goaway.rawValue

        public var newSessionURI: String

        public init(newSessionURI: String) {
            self.newSessionURI = newSessionURI
        }

        public func write(to writer: inout WireWriter) {
            writer.lengthPrefixed(newSessionURI)
        }

        public static func read(from reader: inout WireReader) throws(WireError) -> Goaway {
            Goaway(newSessionURI: try reader.lengthPrefixedString())
        }
    }
}

// MARK: - Responses

extension Draft16 {
    /// REQUEST_OK (§9.7): the answer to TRACK_STATUS, PUBLISH_NAMESPACE,
    /// SUBSCRIBE_NAMESPACE and REQUEST_UPDATE.
    public struct RequestOk: DraftControlMessage {
        public static let typeCode = MessageCode.requestOk.rawValue

        public var requestID: UInt64
        public var parameters: Parameters

        public init(requestID: UInt64, parameters: Parameters = Parameters()) {
            self.requestID = requestID
            self.parameters = parameters
        }

        public func write(to writer: inout WireWriter) {
            writer.varInt(requestID)
            parameters.writeCounted(to: &writer)
        }

        public static func read(from reader: inout WireReader) throws(WireError) -> RequestOk {
            RequestOk(requestID: try reader.varInt(), parameters: try Parameters.readCounted(from: &reader))
        }
    }

    /// REQUEST_ERROR (§9.8). Draft-16 has no redirect.
    public struct RequestError: DraftControlMessage {
        public static let typeCode = MessageCode.requestError.rawValue

        public var requestID: UInt64
        public var code: UInt64
        /// Milliseconds plus one, as in ``MoqomWire/RequestError/retryInterval``.
        public var retryInterval: UInt64
        public var reason: String

        public init(requestID: UInt64, code: UInt64, retryInterval: UInt64 = 0, reason: String = "") {
            self.requestID = requestID
            self.code = code
            self.retryInterval = retryInterval
            self.reason = reason.truncatedUTF8(to: maximumReasonLength)
        }

        public func write(to writer: inout WireWriter) {
            writer.varInt(requestID)
            writer.varInt(code)
            writer.varInt(retryInterval)
            writer.lengthPrefixed(reason)
        }

        public static func read(from reader: inout WireReader) throws(WireError) -> RequestError {
            RequestError(
                requestID: try reader.varInt(),
                code: try reader.varInt(),
                retryInterval: try reader.varInt(),
                reason: try readReason(from: &reader)
            )
        }
    }
}

private func readReason(from reader: inout WireReader) throws(WireError) -> String {
    let bytes = try reader.lengthPrefixed()
    guard bytes.count <= maximumReasonLength else {
        throw WireError.invalid("reason phrase exceeds \(maximumReasonLength) bytes")
    }
    return String(data: bytes, encoding: .utf8) ?? ""
}

// MARK: - Subscribing

extension Draft16 {
    /// SUBSCRIBE (§9.9).
    public struct Subscribe: DraftControlMessage {
        public static let typeCode = MessageCode.subscribe.rawValue

        public var requestID: UInt64
        public var track: FullTrackName
        public var parameters: Parameters

        public init(requestID: UInt64, track: FullTrackName, parameters: Parameters = Parameters()) {
            self.requestID = requestID
            self.track = track
            self.parameters = parameters
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

    /// SUBSCRIBE_OK (§9.10). Track Extensions run to the end of the body.
    public struct SubscribeOk: DraftControlMessage {
        public static let typeCode = MessageCode.subscribeOk.rawValue

        public var requestID: UInt64
        public var trackAlias: UInt64
        public var parameters: Parameters
        public var extensions: Parameters

        public init(
            requestID: UInt64,
            trackAlias: UInt64,
            parameters: Parameters = Parameters(),
            extensions: Parameters = Parameters()
        ) {
            self.requestID = requestID
            self.trackAlias = trackAlias
            self.parameters = parameters
            self.extensions = extensions
        }

        public func write(to writer: inout WireWriter) {
            writer.varInt(requestID)
            writer.varInt(trackAlias)
            parameters.writeCounted(to: &writer)
            extensions.write(to: &writer)
        }

        public static func read(from reader: inout WireReader) throws(WireError) -> SubscribeOk {
            SubscribeOk(
                requestID: try reader.varInt(),
                trackAlias: try reader.varInt(),
                parameters: try Parameters.readCounted(from: &reader),
                extensions: try Parameters.readToEnd(from: &reader)
            )
        }
    }

    /// UNSUBSCRIBE (§9.12).
    public struct Unsubscribe: DraftControlMessage {
        public static let typeCode = MessageCode.unsubscribe.rawValue

        public var requestID: UInt64

        public init(requestID: UInt64) {
            self.requestID = requestID
        }

        public func write(to writer: inout WireWriter) {
            writer.varInt(requestID)
        }

        public static func read(from reader: inout WireReader) throws(WireError) -> Unsubscribe {
            Unsubscribe(requestID: try reader.varInt())
        }
    }

    /// TRACK_STATUS (§9.19): SUBSCRIBE's layout, answered with REQUEST_OK
    /// carrying what SUBSCRIBE_OK would have.
    public struct TrackStatus: DraftControlMessage {
        public static let typeCode = MessageCode.trackStatus.rawValue

        public var requestID: UInt64
        public var track: FullTrackName
        public var parameters: Parameters

        public init(requestID: UInt64, track: FullTrackName, parameters: Parameters = Parameters()) {
            self.requestID = requestID
            self.track = track
            self.parameters = parameters
        }

        public func write(to writer: inout WireWriter) {
            writer.varInt(requestID)
            track.write(to: &writer)
            parameters.writeCounted(to: &writer)
        }

        public static func read(from reader: inout WireReader) throws(WireError) -> TrackStatus {
            TrackStatus(
                requestID: try reader.varInt(),
                track: try FullTrackName.read(from: &reader),
                parameters: try Parameters.readCounted(from: &reader)
            )
        }
    }
}

// MARK: - Publishing

extension Draft16 {
    /// PUBLISH (§9.13).
    public struct Publish: DraftControlMessage {
        public static let typeCode = MessageCode.publish.rawValue

        public var requestID: UInt64
        public var track: FullTrackName
        public var trackAlias: UInt64
        public var parameters: Parameters
        public var extensions: Parameters

        public init(
            requestID: UInt64,
            track: FullTrackName,
            trackAlias: UInt64,
            parameters: Parameters = Parameters(),
            extensions: Parameters = Parameters()
        ) {
            self.requestID = requestID
            self.track = track
            self.trackAlias = trackAlias
            self.parameters = parameters
            self.extensions = extensions
        }

        public func write(to writer: inout WireWriter) {
            writer.varInt(requestID)
            track.write(to: &writer)
            writer.varInt(trackAlias)
            parameters.writeCounted(to: &writer)
            extensions.write(to: &writer)
        }

        public static func read(from reader: inout WireReader) throws(WireError) -> Publish {
            Publish(
                requestID: try reader.varInt(),
                track: try FullTrackName.read(from: &reader),
                trackAlias: try reader.varInt(),
                parameters: try Parameters.readCounted(from: &reader),
                extensions: try Parameters.readToEnd(from: &reader)
            )
        }
    }

    /// PUBLISH_OK (§9.14).
    public struct PublishOk: DraftControlMessage {
        public static let typeCode = MessageCode.publishOk.rawValue

        public var requestID: UInt64
        public var parameters: Parameters

        public init(requestID: UInt64, parameters: Parameters = Parameters()) {
            self.requestID = requestID
            self.parameters = parameters
        }

        public func write(to writer: inout WireWriter) {
            writer.varInt(requestID)
            parameters.writeCounted(to: &writer)
        }

        public static func read(from reader: inout WireReader) throws(WireError) -> PublishOk {
            PublishOk(requestID: try reader.varInt(), parameters: try Parameters.readCounted(from: &reader))
        }
    }

    /// PUBLISH_DONE (§9.15). The status is in ``DoneStatus``'s registry.
    public struct PublishDone: DraftControlMessage {
        public static let typeCode = MessageCode.publishDone.rawValue

        public var requestID: UInt64
        public var status: UInt64
        /// Draft-16 has no "unknown" sentinel; the count is always sent.
        public var streamCount: UInt64
        public var reason: String

        public init(requestID: UInt64, status: UInt64, streamCount: UInt64, reason: String = "") {
            self.requestID = requestID
            self.status = status
            self.streamCount = streamCount
            self.reason = reason.truncatedUTF8(to: maximumReasonLength)
        }

        public func write(to writer: inout WireWriter) {
            writer.varInt(requestID)
            writer.varInt(status)
            writer.varInt(streamCount)
            writer.lengthPrefixed(reason)
        }

        public static func read(from reader: inout WireReader) throws(WireError) -> PublishDone {
            PublishDone(
                requestID: try reader.varInt(),
                status: try reader.varInt(),
                streamCount: try reader.varInt(),
                reason: try readReason(from: &reader)
            )
        }
    }
}

// MARK: - Namespaces

extension Draft16 {
    /// PUBLISH_NAMESPACE (§9.20), answered with REQUEST_OK.
    public struct PublishNamespace: DraftControlMessage {
        public static let typeCode = MessageCode.publishNamespace.rawValue

        public var requestID: UInt64
        public var namespace: TrackNamespace
        public var parameters: Parameters

        public init(requestID: UInt64, namespace: TrackNamespace, parameters: Parameters = Parameters()) {
            self.requestID = requestID
            self.namespace = namespace
            self.parameters = parameters
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

    /// PUBLISH_NAMESPACE_DONE (§9.22): the publisher withdraws a namespace.
    public struct PublishNamespaceDone: DraftControlMessage {
        public static let typeCode = MessageCode.publishNamespaceDone.rawValue

        public var requestID: UInt64

        public init(requestID: UInt64) {
            self.requestID = requestID
        }

        public func write(to writer: inout WireWriter) {
            writer.varInt(requestID)
        }

        public static func read(from reader: inout WireReader) throws(WireError) -> PublishNamespaceDone {
            PublishNamespaceDone(requestID: try reader.varInt())
        }
    }

    /// PUBLISH_NAMESPACE_CANCEL (§9.24): the receiver withdraws its acceptance.
    public struct PublishNamespaceCancel: DraftControlMessage {
        public static let typeCode = MessageCode.publishNamespaceCancel.rawValue

        public var requestID: UInt64
        public var code: UInt64
        public var reason: String

        public init(requestID: UInt64, code: UInt64, reason: String = "") {
            self.requestID = requestID
            self.code = code
            self.reason = reason.truncatedUTF8(to: maximumReasonLength)
        }

        public func write(to writer: inout WireWriter) {
            writer.varInt(requestID)
            writer.varInt(code)
            writer.lengthPrefixed(reason)
        }

        public static func read(from reader: inout WireReader) throws(WireError) -> PublishNamespaceCancel {
            PublishNamespaceCancel(
                requestID: try reader.varInt(),
                code: try reader.varInt(),
                reason: try readReason(from: &reader)
            )
        }
    }

    /// SUBSCRIBE_NAMESPACE (§9.25), the first message on its own
    /// bidirectional stream.
    public struct SubscribeNamespace: DraftControlMessage {
        public static let typeCode = MessageCode.subscribeNamespace.rawValue

        /// What the subscriber wants to hear about under the prefix.
        public enum Options: UInt64, Sendable {
            /// PUBLISH for each matching track, on the control stream.
            case publish = 0x0
            /// NAMESPACE and NAMESPACE_DONE, on this stream.
            case namespace = 0x1
            case both = 0x2
        }

        public var requestID: UInt64
        public var prefix: TrackNamespace
        public var options: Options
        public var parameters: Parameters

        public init(
            requestID: UInt64,
            prefix: TrackNamespace,
            options: Options,
            parameters: Parameters = Parameters()
        ) {
            self.requestID = requestID
            self.prefix = prefix
            self.options = options
            self.parameters = parameters
        }

        public func write(to writer: inout WireWriter) {
            writer.varInt(requestID)
            prefix.write(to: &writer)
            writer.varInt(options.rawValue)
            parameters.writeCounted(to: &writer)
        }

        public static func read(from reader: inout WireReader) throws(WireError) -> SubscribeNamespace {
            let requestID = try reader.varInt()
            let prefix = try TrackNamespace.read(from: &reader)
            let code = try reader.varInt()
            guard let options = Options(rawValue: code) else {
                throw WireError.invalid("unknown subscribe options \(code)")
            }
            return SubscribeNamespace(
                requestID: requestID,
                prefix: prefix,
                options: options,
                parameters: try Parameters.readCounted(from: &reader)
            )
        }
    }
}
