// Draft-22 control messages and Message Parameters, per draft-22 §9.
//
// What changed from the draft-19 profile, as far as bytes go:
//
//   - **Message Parameters are not key-value pairs.** Each type fixes its own
//     value encoding (§9.20): `uint8`, varint, Location, length-prefixed, or a
//     Track Namespace, and LOCATION_FILTER is none of those — a filter type and
//     then as many varints as the type calls for, with no length in front. A
//     parser therefore has to know every type to find the next one, and §9.20
//     makes that a requirement: an unknown Message Parameter, or a known one in
//     a message that does not allow it, closes the session. ``MessageParameters``
//     rejects both rather than skipping.
//   - **FETCH names a track and nothing else.** The range moved into
//     LOCATION_FILTER, Joining FETCH is gone, and catching up on a subscription
//     is a fill: FILL_PARAMETERS on the SUBSCRIBE or a REQUEST_UPDATE makes the
//     publisher open a fetch stream whose header carries that request's ID.
//   - **FETCH_OK's End Location is inclusive.** Draft-19 put the end plus one on
//     the wire (``FetchEnd/wire``); draft-22 §9.12 says "inclusive" and means
//     it.
//   - PUBLISH_STATE_NOTIFY (0x22) is new; PUBLISH_OK (0x1E) and
//     SUBSCRIPTION_ENDED are gone, PUBLISH is answered with REQUEST_OK.
//
// Messages whose bodies did not change — SETUP, GOAWAY, PUBLISH_DONE,
// REQUEST_ERROR, NAMESPACE, NAMESPACE_DONE — keep their draft-19 types and are
// framed with ``ControlFrame/write(_:as:to:)`` in the vi64 encoding.
//
// Every byte vector for this file is in `Tests/Fixtures/moqt-22`, one file per
// case, in a format meant to be read by the Rust codec as well as this one.

import Foundation
import MoqomCore

/// Draft-22 message types and codecs.
public enum Draft22 {
    /// Control message type codes (§9, Table 5).
    public enum MessageCode: UInt64, CaseIterable, Sendable {
        case setup = 0x2F00
        case goaway = 0x10
        case subscribe = 0x3
        case subscribeOk = 0x4
        case publishStateNotify = 0x22
        case publish = 0x1D
        case publishDone = 0xB
        case fetch = 0x16
        case fetchOk = 0x18
        case trackStatus = 0xD
        case publishNamespace = 0x6
        case subscribeNamespace = 0x50
        case subscribeTracks = 0x51
        case namespace = 0x8
        case namespaceDone = 0xE
        case publishSkipped = 0xF
        case requestUpdate = 0x2
        case requestOk = 0x7
        case requestError = 0x5

        /// Retired codes, named in the error because receiving one almost
        /// always means the peer is on another draft.
        static let reserved: Set<UInt64> = [0x01, 0x40, 0x41, 0x20, 0x21, 0x1E]

        /// A received code, or a PROTOCOL_VIOLATION (§9: "An endpoint that
        /// receives an unknown message type MUST close the session").
        public init(code: UInt64) throws(WireError) {
            guard let known = MessageCode(rawValue: code) else {
                if Self.reserved.contains(code) {
                    throw WireError.invalid(
                        "control message type 0x\(String(code, radix: 16)) is reserved in draft-22"
                    )
                }
                throw WireError.invalid("unknown control message type 0x\(String(code, radix: 16))")
            }
            self = known
        }
    }
}

// MARK: - Authorization tokens

/// The Token structure (draft-22 §8.9; the same layout in draft-16 §9.2.1.1).
///
/// The value of the AUTHORIZATION_TOKEN Message Parameter and Setup Option,
/// and in both cases the Token Value runs to the end of the enclosing length.
/// MOQOM sends ``useValue(type:value:)`` with type 0, which the registry
/// reserves for a type "negotiated out-of-band": the value is the admission
/// ticket's bytes, unchanged.
public enum AuthorizationToken: Hashable, Sendable {
    /// Retire an alias. No type or value.
    case delete(alias: UInt64)
    /// Register an alias for this type and value, then use it.
    case register(alias: UInt64, type: UInt64, value: Data)
    /// Use a previously registered alias.
    case useAlias(UInt64)
    /// Use this type and value once.
    case useValue(type: UInt64, value: Data)

    /// The out-of-band token type, which is what a MOQOM admission ticket is.
    public static let outOfBandType: UInt64 = 0

    public func write(to writer: inout WireWriter) {
        switch self {
        case let .delete(alias):
            writer.varInt(0x0)
            writer.varInt(alias)
        case let .register(alias, type, value):
            writer.varInt(0x1)
            writer.varInt(alias)
            writer.varInt(type)
            writer.raw(value)
        case let .useAlias(alias):
            writer.varInt(0x2)
            writer.varInt(alias)
        case let .useValue(type, value):
            writer.varInt(0x3)
            writer.varInt(type)
            writer.raw(value)
        }
    }

    /// Read a whole Token from a reader bounded to exactly its bytes.
    public static func read(from reader: inout WireReader) throws(WireError) -> AuthorizationToken {
        let aliasType = try reader.varInt()
        let token: AuthorizationToken
        switch aliasType {
        case 0x0: token = .delete(alias: try reader.varInt())
        case 0x1: token = .register(alias: try reader.varInt(), type: try reader.varInt(), value: reader.rest)
        case 0x2: token = .useAlias(try reader.varInt())
        case 0x3: token = .useValue(type: try reader.varInt(), value: reader.rest)
        default: throw WireError.invalid("unknown token alias type \(aliasType)")
        }
        switch token {
        case .register, .useValue: _ = try reader.take(reader.remaining)
        case .delete, .useAlias:
            guard reader.isEmpty else { throw WireError.invalid("token alias carries a value") }
        }
        return token
    }

    /// The Token's bytes in `encoding`, for a KVP Setup Option.
    public func encoded(in encoding: VarIntEncoding) -> Data {
        var writer = WireWriter(encoding: encoding)
        write(to: &writer)
        return writer.bytes
    }

    public static func decode(_ data: Data, in encoding: VarIntEncoding) throws(WireError) -> AuthorizationToken {
        var reader = WireReader(data, encoding: encoding)
        return try read(from: &reader)
    }
}

// MARK: - Filters

/// A Location filter (§3.3.1, §9.20.9).
///
/// End groups are held absolute and put on the wire as a delta from the start
/// group, which is what the draft encodes; holding the delta instead would make
/// every caller do the arithmetic and some of them get it wrong.
public enum LocationFilter: Hashable, Sendable {
    /// 0x00: explicitly no filter.
    case none
    /// 0x01: from `{Largest.Group + 1 - groups, 0}`, open-ended. `0` is the
    /// next group and `1` the current one.
    case relativeStart(groups: UInt64)
    /// 0x02: from an absolute location, open-ended.
    case absoluteStart(Location)
    /// 0x03: from an absolute location through the whole of `endGroup`.
    case absoluteThroughGroup(start: Location, endGroup: UInt64)
    /// 0x04: from an absolute location through an absolute location, both
    /// inclusive.
    case absoluteRange(start: Location, end: Location)
    /// 0x05: from the next object, open-ended. The way to subscribe without a
    /// gap and without duplicates when paired with a fill.
    case nextObject

    public var filterType: UInt64 {
        switch self {
        case .none: 0x00
        case .relativeStart: 0x01
        case .absoluteStart: 0x02
        case .absoluteThroughGroup: 0x03
        case .absoluteRange: 0x04
        case .nextObject: 0x05
        }
    }

    /// - Precondition: an end group is not before its start group. The draft
    ///   encodes a delta, so a reversed range has no encoding at all.
    public func write(to writer: inout WireWriter) {
        writer.varInt(filterType)
        switch self {
        case .none, .nextObject:
            break
        case let .relativeStart(groups):
            writer.varInt(groups)
        case let .absoluteStart(start):
            start.write(to: &writer)
        case let .absoluteThroughGroup(start, endGroup):
            precondition(endGroup >= start.group, "location filter ends before it starts")
            start.write(to: &writer)
            writer.varInt(endGroup - start.group)
        case let .absoluteRange(start, end):
            precondition(end.group >= start.group, "location filter ends before it starts")
            start.write(to: &writer)
            writer.varInt(end.group - start.group)
            writer.varInt(end.object)
        }
    }

    public static func read(from reader: inout WireReader) throws(WireError) -> LocationFilter {
        let type = try reader.varInt()
        switch type {
        case 0x00: return .none
        case 0x01: return .relativeStart(groups: try reader.varInt())
        case 0x02: return .absoluteStart(try Location.read(from: &reader))
        case 0x03:
            let start = try Location.read(from: &reader)
            return .absoluteThroughGroup(start: start, endGroup: try endGroup(start, try reader.varInt()))
        case 0x04:
            let start = try Location.read(from: &reader)
            let group = try endGroup(start, try reader.varInt())
            return .absoluteRange(start: start, end: Location(group: group, object: try reader.varInt()))
        case 0x05: return .nextObject
        default: throw WireError.invalid("unknown location filter type \(type)")
        }
    }

    private static func endGroup(_ start: Location, _ delta: UInt64) throws(WireError) -> UInt64 {
        let (group, overflow) = start.group.addingReportingOverflow(delta)
        guard !overflow else { throw WireError.invalid("location filter end group passed 2^64-1") }
        return group
    }
}

/// A Range Filter (§3.3.2, §8.6): a set of inclusive ranges of one value.
///
/// The parameter's Length of zero means "no filter" and removes one in a
/// REQUEST_UPDATE; that is `nil` where this type is optional.
public struct RangeFilter: Hashable, Sendable {
    /// Filters with the same set are AND'd, distinct sets OR'd.
    public var setID: UInt8
    /// The property whose value is filtered, for the two property filters
    /// only (0x28, 0x29). Must be even, i.e. integer-valued.
    public var propertyType: UInt64?
    /// Inclusive ranges in ascending order. Only the last may be open-ended.
    public var ranges: [Range]

    public struct Range: Hashable, Sendable {
        public var start: UInt64
        /// `nil` for open-ended, which only the last range may be.
        public var end: UInt64?

        public init(_ start: UInt64, _ end: UInt64?) {
            self.start = start
            self.end = end
        }
    }

    public init(setID: UInt8 = 0, propertyType: UInt64? = nil, ranges: [Range]) {
        self.setID = setID
        self.propertyType = propertyType
        self.ranges = ranges
    }

    /// Starts are deltas from the previous end (or 0), ends from their own
    /// start: 3-5 and 10-15 are `3, 2, 5, 5`.
    func write(to writer: inout WireWriter) {
        writer.byte(setID)
        if let propertyType { writer.varInt(propertyType) }
        var previous: UInt64 = 0
        for range in ranges {
            writer.varInt(range.start - previous)
            if let end = range.end {
                writer.varInt(end - range.start)
                previous = end
            }
        }
    }

    static func read(from reader: inout WireReader, hasPropertyType: Bool) throws(WireError) -> RangeFilter {
        let setID = try reader.byte()
        let propertyType = hasPropertyType ? try reader.varInt() : nil
        if let propertyType, !propertyType.isMultiple(of: 2) {
            throw WireError.invalid("property filter names odd property type \(propertyType)")
        }
        var ranges: [Range] = []
        var previous: UInt64 = 0
        while !reader.isEmpty {
            let (start, overflow) = previous.addingReportingOverflow(try reader.varInt())
            guard !overflow else { throw WireError.invalid("range filter start passed 2^64-1") }
            if reader.isEmpty {
                ranges.append(Range(start, nil))
                break
            }
            let (end, overflow2) = start.addingReportingOverflow(try reader.varInt())
            guard !overflow2 else { throw WireError.invalid("range filter end passed 2^64-1") }
            ranges.append(Range(start, end))
            previous = end
        }
        return RangeFilter(setID: setID, propertyType: propertyType, ranges: ranges)
    }
}

// MARK: - Message Parameters

/// One draft-22 Message Parameter, with the value encoding §9.20 gives its
/// type.
public enum MessageParameter: Hashable, Sendable {
    /// 0x02, varint, milliseconds.
    case objectDeliveryTimeout(UInt64)
    /// 0x03, length-prefixed Token. May repeat.
    case authorizationToken(AuthorizationToken)
    /// 0x04, varint, milliseconds. The draft names no encoding for this one;
    /// varint is the only reading consistent with the other timeouts.
    case rendezvousTimeout(UInt64)
    /// 0x06, varint, milliseconds.
    case subgroupDeliveryTimeout(UInt64)
    /// 0x08, varint, milliseconds.
    case expires(UInt64)
    /// 0x09, Location.
    case largestObject(Location)
    /// 0x0A, varint, milliseconds.
    case fillTimeout(UInt64)
    /// 0x10, uint8 0 or 1. Zero pauses the subscription.
    case forward(Bool)
    /// 0x20, uint8. Lower is more urgent.
    case subscriberPriority(UInt8)
    /// 0x21, a Location filter with no length in front of it.
    case locationFilter(LocationFilter)
    /// 0x22, uint8 1 or 2.
    case groupOrder(GroupOrder)
    /// 0x23, length-prefixed. What its presence asks for is a fill fetch
    /// stream; what it carries overrides the subscription's parameters for that
    /// stream alone.
    case fillParameters(MessageParameters)
    /// 0x25, length-prefixed Range Filter over Subgroup IDs. May repeat.
    case subgroupFilter(RangeFilter?)
    /// 0x26, over Object IDs. May repeat.
    case objectIDFilter(RangeFilter?)
    /// 0x27, over publisher priorities. May repeat.
    case priorityFilter(RangeFilter?)
    /// 0x28, over an Object Property's value. May repeat.
    case objectPropertyFilter(RangeFilter?)
    /// 0x29, over a Track Property's value. May repeat.
    case trackPropertyFilter(RangeFilter?)
    /// 0x32, varint: the largest group the subscriber knows of, plus one.
    case newGroupRequest(UInt64)
    /// 0x34, a Track Namespace.
    case trackNamespacePrefix(TrackNamespace)
    /// 0x35, uint8 0 or 1. Defaults to 1.
    case includeProperties(Bool)

    public enum Kind: UInt64, CaseIterable, Sendable {
        case objectDeliveryTimeout = 0x02
        case authorizationToken = 0x03
        case rendezvousTimeout = 0x04
        case subgroupDeliveryTimeout = 0x06
        case expires = 0x08
        case largestObject = 0x09
        case fillTimeout = 0x0A
        case forward = 0x10
        case subscriberPriority = 0x20
        case locationFilter = 0x21
        case groupOrder = 0x22
        case fillParameters = 0x23
        case subgroupFilter = 0x25
        case objectIDFilter = 0x26
        case priorityFilter = 0x27
        case objectPropertyFilter = 0x28
        case trackPropertyFilter = 0x29
        case newGroupRequest = 0x32
        case trackNamespacePrefix = 0x34
        case includeProperties = 0x35

        /// Types a message may carry more than once (§9.20, §3.3.2).
        var mayRepeat: Bool {
            switch self {
            case .authorizationToken, .subgroupFilter, .objectIDFilter, .priorityFilter,
                 .objectPropertyFilter, .trackPropertyFilter:
                true
            default:
                false
            }
        }
    }

    public var kind: Kind {
        switch self {
        case .objectDeliveryTimeout: .objectDeliveryTimeout
        case .authorizationToken: .authorizationToken
        case .rendezvousTimeout: .rendezvousTimeout
        case .subgroupDeliveryTimeout: .subgroupDeliveryTimeout
        case .expires: .expires
        case .largestObject: .largestObject
        case .fillTimeout: .fillTimeout
        case .forward: .forward
        case .subscriberPriority: .subscriberPriority
        case .locationFilter: .locationFilter
        case .groupOrder: .groupOrder
        case .fillParameters: .fillParameters
        case .subgroupFilter: .subgroupFilter
        case .objectIDFilter: .objectIDFilter
        case .priorityFilter: .priorityFilter
        case .objectPropertyFilter: .objectPropertyFilter
        case .trackPropertyFilter: .trackPropertyFilter
        case .newGroupRequest: .newGroupRequest
        case .trackNamespacePrefix: .trackNamespacePrefix
        case .includeProperties: .includeProperties
        }
    }

    public var type: UInt64 { kind.rawValue }

    func writeValue(to writer: inout WireWriter) {
        switch self {
        case let .objectDeliveryTimeout(value), let .rendezvousTimeout(value),
             let .subgroupDeliveryTimeout(value), let .expires(value), let .fillTimeout(value),
             let .newGroupRequest(value):
            writer.varInt(value)
        case let .authorizationToken(token):
            writer.lengthPrefixed { token.write(to: &$0) }
        case let .largestObject(location):
            location.write(to: &writer)
        case let .forward(flag), let .includeProperties(flag):
            writer.byte(flag ? 1 : 0)
        case let .subscriberPriority(priority):
            writer.byte(priority)
        case let .locationFilter(filter):
            filter.write(to: &writer)
        case let .groupOrder(order):
            writer.byte(UInt8(order.rawValue))
        case let .fillParameters(parameters):
            writer.lengthPrefixed { parameters.write(to: &$0) }
        case let .subgroupFilter(filter), let .objectIDFilter(filter), let .priorityFilter(filter),
             let .objectPropertyFilter(filter), let .trackPropertyFilter(filter):
            writer.lengthPrefixed { inner in filter?.write(to: &inner) }
        case let .trackNamespacePrefix(namespace):
            namespace.write(to: &writer)
        }
    }

    static func readValue(_ kind: Kind, from reader: inout WireReader) throws(WireError) -> MessageParameter {
        switch kind {
        case .objectDeliveryTimeout: return .objectDeliveryTimeout(try reader.varInt())
        case .rendezvousTimeout: return .rendezvousTimeout(try reader.varInt())
        case .subgroupDeliveryTimeout: return .subgroupDeliveryTimeout(try reader.varInt())
        case .expires: return .expires(try reader.varInt())
        case .fillTimeout: return .fillTimeout(try reader.varInt())
        case .newGroupRequest: return .newGroupRequest(try reader.varInt())
        case .authorizationToken:
            var value = try lengthPrefixed(&reader)
            return .authorizationToken(try AuthorizationToken.read(from: &value))
        case .largestObject:
            return .largestObject(try Location.read(from: &reader))
        case .forward:
            return .forward(try boolean(&reader, "FORWARD"))
        case .includeProperties:
            return .includeProperties(try boolean(&reader, "INCLUDE_PROPERTIES"))
        case .subscriberPriority:
            return .subscriberPriority(try reader.byte())
        case .locationFilter:
            return .locationFilter(try LocationFilter.read(from: &reader))
        case .groupOrder:
            let raw = try reader.byte()
            guard let order = GroupOrder(rawValue: UInt64(raw)) else {
                throw WireError.invalid("GROUP_ORDER \(raw) is neither ascending nor descending")
            }
            return .groupOrder(order)
        case .fillParameters:
            var value = try lengthPrefixed(&reader)
            let inner = try MessageParameters.read(from: &value)
            guard value.isEmpty else { throw WireError.invalid("trailing bytes in FILL_PARAMETERS") }
            try inner.validate(allowing: MessageParameters.insideFill, in: "FILL_PARAMETERS")
            return .fillParameters(inner)
        case .subgroupFilter: return .subgroupFilter(try rangeFilter(&reader, property: false))
        case .objectIDFilter: return .objectIDFilter(try rangeFilter(&reader, property: false))
        case .priorityFilter: return .priorityFilter(try rangeFilter(&reader, property: false))
        case .objectPropertyFilter: return .objectPropertyFilter(try rangeFilter(&reader, property: true))
        case .trackPropertyFilter: return .trackPropertyFilter(try rangeFilter(&reader, property: true))
        case .trackNamespacePrefix:
            return .trackNamespacePrefix(try TrackNamespace.read(from: &reader))
        }
    }

    private static func lengthPrefixed(_ reader: inout WireReader) throws(WireError) -> WireReader {
        guard let length = Int(exactly: try reader.varInt()) else {
            throw WireError.invalid("parameter longer than addressable memory")
        }
        return try reader.nested(length)
    }

    private static func boolean(_ reader: inout WireReader, _ name: String) throws(WireError) -> Bool {
        let raw = try reader.byte()
        guard raw <= 1 else { throw WireError.invalid("\(name) is \(raw), not 0 or 1") }
        return raw == 1
    }

    private static func rangeFilter(_ reader: inout WireReader, property: Bool) throws(WireError) -> RangeFilter? {
        var value = try lengthPrefixed(&reader)
        guard !value.isEmpty else { return nil }
        return try RangeFilter.read(from: &value, hasPropertyType: property)
    }
}

/// The Message Parameters of one draft-22 message: a count, then each
/// parameter as a type delta and its value.
///
/// Held in ascending type order, stable within a type, because the encoding is
/// delta-from-previous and §9.20 requires it.
public struct MessageParameters: Hashable, Sendable, ExpressibleByArrayLiteral {
    public private(set) var items: [MessageParameter]

    public init(_ items: [MessageParameter] = []) {
        self.items = items.enumerated()
            .sorted { lhs, rhs in
                lhs.element.type == rhs.element.type
                    ? lhs.offset < rhs.offset
                    : lhs.element.type < rhs.element.type
            }
            .map(\.element)
    }

    public init(arrayLiteral elements: MessageParameter...) {
        self.init(elements)
    }

    public var isEmpty: Bool { items.isEmpty }

    public func first(_ kind: MessageParameter.Kind) -> MessageParameter? {
        items.first { $0.kind == kind }
    }

    public var largestObject: Location? {
        if case let .largestObject(location) = first(.largestObject) { return location }
        return nil
    }

    public var expires: UInt64? {
        if case let .expires(value) = first(.expires) { return value }
        return nil
    }

    public func write(to writer: inout WireWriter) {
        writer.varInt(UInt64(items.count))
        var previous: UInt64 = 0
        for item in items {
            writer.varInt(item.type - previous)
            item.writeValue(to: &writer)
            previous = item.type
        }
    }

    /// Read a counted block, rejecting any type draft-22 does not define.
    ///
    /// Which types a particular message allows is a second, separate check —
    /// ``validate(allowing:in:)`` — because the same codec reads every message.
    public static func read(from reader: inout WireReader) throws(WireError) -> MessageParameters {
        let count = try reader.varInt()
        guard count <= 4096 else { throw WireError.invalid("implausible parameter count \(count)") }
        var items: [MessageParameter] = []
        var previous: UInt64 = 0
        for _ in 0 ..< count {
            let (type, overflow) = previous.addingReportingOverflow(try reader.varInt())
            guard !overflow else { throw WireError.invalid("parameter type delta passed 2^64-1") }
            guard let kind = MessageParameter.Kind(rawValue: type) else {
                throw WireError.invalid("unknown message parameter 0x\(String(type, radix: 16))")
            }
            items.append(try MessageParameter.readValue(kind, from: &reader))
            previous = type
        }
        return MessageParameters(items)
    }

    /// Reject a parameter `message` may not carry, or a repeat of one that may
    /// not repeat. Both close the session (§9.20, §9.20.1).
    public func validate(allowing allowed: Set<MessageParameter.Kind>, in message: String) throws(WireError) {
        var seen: Set<MessageParameter.Kind> = []
        for item in items {
            guard allowed.contains(item.kind) else {
                throw WireError.invalid("\(message) may not carry parameter 0x\(String(item.type, radix: 16))")
            }
            guard seen.insert(item.kind).inserted || item.kind.mayRepeat else {
                throw WireError.invalid("\(message) repeats parameter 0x\(String(item.type, radix: 16))")
            }
        }
    }

    /// Table 7: what FILL_PARAMETERS may carry.
    public static let insideFill: Set<MessageParameter.Kind> = [
        .fillTimeout, .subscriberPriority, .locationFilter, .groupOrder,
        .subgroupFilter, .objectIDFilter, .priorityFilter, .objectPropertyFilter,
    ]
}

// MARK: - Messages

extension Draft22 {
    /// Request a track (§9.6).
    public struct Subscribe: DraftControlMessage {
        public static let typeCode = MessageCode.subscribe.rawValue
        static let allowed: Set<MessageParameter.Kind> = [
            .objectDeliveryTimeout, .authorizationToken, .rendezvousTimeout, .subgroupDeliveryTimeout,
            .forward, .subscriberPriority, .locationFilter, .groupOrder, .fillParameters,
            .subgroupFilter, .objectIDFilter, .priorityFilter, .objectPropertyFilter,
            .newGroupRequest, .includeProperties,
        ]

        public var requestID: UInt64
        public var track: FullTrackName
        public var parameters: MessageParameters

        public init(requestID: UInt64, track: FullTrackName, parameters: MessageParameters = []) {
            self.requestID = requestID
            self.track = track
            self.parameters = parameters
        }

        public func write(to writer: inout WireWriter) {
            writer.varInt(requestID)
            track.write(to: &writer)
            parameters.write(to: &writer)
        }

        public static func read(from reader: inout WireReader) throws(WireError) -> Subscribe {
            let message = Subscribe(
                requestID: try reader.varInt(),
                track: try FullTrackName.read(from: &reader),
                parameters: try MessageParameters.read(from: &reader)
            )
            try message.parameters.validate(allowing: allowed, in: "SUBSCRIBE")
            return message
        }
    }

    /// Ask for a track's status without subscribing (§9.13). SUBSCRIBE's
    /// layout, with only the parameters that do not govern delivery.
    public struct TrackStatus: DraftControlMessage {
        public static let typeCode = MessageCode.trackStatus.rawValue
        static let allowed: Set<MessageParameter.Kind> = [.authorizationToken, .includeProperties]

        public var requestID: UInt64
        public var track: FullTrackName
        public var parameters: MessageParameters

        public init(requestID: UInt64, track: FullTrackName, parameters: MessageParameters = []) {
            self.requestID = requestID
            self.track = track
            self.parameters = parameters
        }

        public func write(to writer: inout WireWriter) {
            writer.varInt(requestID)
            track.write(to: &writer)
            parameters.write(to: &writer)
        }

        public static func read(from reader: inout WireReader) throws(WireError) -> TrackStatus {
            let message = TrackStatus(
                requestID: try reader.varInt(),
                track: try FullTrackName.read(from: &reader),
                parameters: try MessageParameters.read(from: &reader)
            )
            try message.parameters.validate(allowing: allowed, in: "TRACK_STATUS")
            return message
        }
    }

    /// A subscription was accepted (§9.7).
    public struct SubscribeOk: DraftControlMessage {
        public static let typeCode = MessageCode.subscribeOk.rawValue
        static let allowed: Set<MessageParameter.Kind> = [.expires, .largestObject]

        public var trackAlias: UInt64
        public var parameters: MessageParameters
        /// Track Properties, running to the end of the body.
        public var properties: Parameters

        public init(trackAlias: UInt64, parameters: MessageParameters = [], properties: Parameters = Parameters()) {
            self.trackAlias = trackAlias
            self.parameters = parameters
            self.properties = properties
        }

        public func write(to writer: inout WireWriter) {
            writer.varInt(trackAlias)
            parameters.write(to: &writer)
            properties.write(to: &writer)
        }

        public static func read(from reader: inout WireReader) throws(WireError) -> SubscribeOk {
            let message = SubscribeOk(
                trackAlias: try reader.varInt(),
                parameters: try MessageParameters.read(from: &reader),
                properties: try Parameters.readToEnd(from: &reader)
            )
            try message.parameters.validate(allowing: allowed, in: "SUBSCRIBE_OK")
            return message
        }
    }

    /// Offer a track the peer did not ask for (§9.8). Its parameters are the
    /// subscription's initial settings, which the subscriber may then change
    /// with REQUEST_UPDATE; it is answered with REQUEST_OK.
    public struct Publish: DraftControlMessage {
        public static let typeCode = MessageCode.publish.rawValue
        static let allowed: Set<MessageParameter.Kind> = [
            .objectDeliveryTimeout, .authorizationToken, .subgroupDeliveryTimeout, .expires,
            .largestObject, .forward, .subscriberPriority, .locationFilter, .groupOrder,
        ]

        public var requestID: UInt64
        public var track: FullTrackName
        public var trackAlias: UInt64
        public var parameters: MessageParameters
        public var properties: Parameters

        public init(
            requestID: UInt64,
            track: FullTrackName,
            trackAlias: UInt64,
            parameters: MessageParameters = [],
            properties: Parameters = Parameters()
        ) {
            self.requestID = requestID
            self.track = track
            self.trackAlias = trackAlias
            self.parameters = parameters
            self.properties = properties
        }

        public func write(to writer: inout WireWriter) {
            writer.varInt(requestID)
            track.write(to: &writer)
            writer.varInt(trackAlias)
            parameters.write(to: &writer)
            properties.write(to: &writer)
        }

        public static func read(from reader: inout WireReader) throws(WireError) -> Publish {
            let message = Publish(
                requestID: try reader.varInt(),
                track: try FullTrackName.read(from: &reader),
                trackAlias: try reader.varInt(),
                parameters: try MessageParameters.read(from: &reader),
                properties: try Parameters.readToEnd(from: &reader)
            )
            try message.parameters.validate(allowing: allowed, in: "PUBLISH")
            return message
        }
    }

    /// The publisher telling a subscriber its subscription changed for some
    /// reason other than the subscriber asking (§9.10). Unanswered.
    public struct PublishStateNotify: DraftControlMessage {
        public static let typeCode = MessageCode.publishStateNotify.rawValue
        static let allowed: Set<MessageParameter.Kind> = [.largestObject, .forward, .locationFilter]

        public var parameters: MessageParameters

        public init(parameters: MessageParameters = []) {
            self.parameters = parameters
        }

        public func write(to writer: inout WireWriter) {
            parameters.write(to: &writer)
        }

        public static func read(from reader: inout WireReader) throws(WireError) -> PublishStateNotify {
            let message = PublishStateNotify(parameters: try MessageParameters.read(from: &reader))
            try message.parameters.validate(allowing: allowed, in: "PUBLISH_STATE_NOTIFY")
            return message
        }

        /// Whether the publisher now has the subscription paused, if it said.
        public var forward: Bool? {
            if case let .forward(value) = parameters.first(.forward) { return value }
            return nil
        }
    }

    /// Ask for objects already published (§9.11). The range is the
    /// LOCATION_FILTER parameter; without one, the whole track to Largest
    /// Object.
    public struct Fetch: DraftControlMessage {
        public static let typeCode = MessageCode.fetch.rawValue
        static let allowed: Set<MessageParameter.Kind> = [
            .authorizationToken, .fillTimeout, .subscriberPriority, .locationFilter, .groupOrder,
            .subgroupFilter, .objectIDFilter, .priorityFilter, .objectPropertyFilter, .includeProperties,
        ]

        public var requestID: UInt64
        public var track: FullTrackName
        public var parameters: MessageParameters

        public init(requestID: UInt64, track: FullTrackName, parameters: MessageParameters = []) {
            self.requestID = requestID
            self.track = track
            self.parameters = parameters
        }

        public func write(to writer: inout WireWriter) {
            writer.varInt(requestID)
            track.write(to: &writer)
            parameters.write(to: &writer)
        }

        public static func read(from reader: inout WireReader) throws(WireError) -> Fetch {
            let message = Fetch(
                requestID: try reader.varInt(),
                track: try FullTrackName.read(from: &reader),
                parameters: try MessageParameters.read(from: &reader)
            )
            try message.parameters.validate(allowing: allowed, in: "FETCH")
            return message
        }

        public var locationFilter: LocationFilter? {
            if case let .locationFilter(filter) = parameters.first(.locationFilter) { return filter }
            return nil
        }

        public var groupOrder: GroupOrder? {
            if case let .groupOrder(order) = parameters.first(.groupOrder) { return order }
            return nil
        }
    }

    /// A fetch was accepted (§9.12). ``end`` is inclusive, unlike draft-19's.
    public struct FetchOk: DraftControlMessage {
        public static let typeCode = MessageCode.fetchOk.rawValue

        public var endOfTrack: Bool
        public var end: Location
        public var parameters: MessageParameters
        public var properties: Parameters

        public init(
            endOfTrack: Bool = false,
            end: Location,
            parameters: MessageParameters = [],
            properties: Parameters = Parameters()
        ) {
            self.endOfTrack = endOfTrack
            self.end = end
            self.parameters = parameters
            self.properties = properties
        }

        public func write(to writer: inout WireWriter) {
            writer.byte(endOfTrack ? 1 : 0)
            end.write(to: &writer)
            parameters.write(to: &writer)
            properties.write(to: &writer)
        }

        public static func read(from reader: inout WireReader) throws(WireError) -> FetchOk {
            let flag = try reader.byte()
            guard flag <= 1 else { throw WireError.invalid("End Of Track is \(flag), not 0 or 1") }
            let message = FetchOk(
                endOfTrack: flag == 1,
                end: try Location.read(from: &reader),
                parameters: try MessageParameters.read(from: &reader),
                properties: try Parameters.readToEnd(from: &reader)
            )
            // "No parameters are currently defined for FETCH_OK."
            try message.parameters.validate(allowing: [], in: "FETCH_OK")
            return message
        }
    }

    /// Advertise a namespace (§9.14).
    public struct PublishNamespace: DraftControlMessage {
        public static let typeCode = MessageCode.publishNamespace.rawValue

        public var requestID: UInt64
        public var namespace: TrackNamespace
        public var parameters: MessageParameters

        public init(requestID: UInt64, namespace: TrackNamespace, parameters: MessageParameters = []) {
            self.requestID = requestID
            self.namespace = namespace
            self.parameters = parameters
        }

        public func write(to writer: inout WireWriter) {
            writer.varInt(requestID)
            namespace.write(to: &writer)
            parameters.write(to: &writer)
        }

        public static func read(from reader: inout WireReader) throws(WireError) -> PublishNamespace {
            let message = PublishNamespace(
                requestID: try reader.varInt(),
                namespace: try TrackNamespace.read(from: &reader),
                parameters: try MessageParameters.read(from: &reader)
            )
            try message.parameters.validate(allowing: [.authorizationToken], in: "PUBLISH_NAMESPACE")
            return message
        }
    }

    /// Watch a namespace prefix (§9.15).
    public struct SubscribeNamespace: DraftControlMessage {
        public static let typeCode = MessageCode.subscribeNamespace.rawValue

        public var requestID: UInt64
        public var prefix: TrackNamespace
        public var parameters: MessageParameters

        public init(requestID: UInt64, prefix: TrackNamespace, parameters: MessageParameters = []) {
            self.requestID = requestID
            self.prefix = prefix
            self.parameters = parameters
        }

        public func write(to writer: inout WireWriter) {
            writer.varInt(requestID)
            prefix.write(to: &writer)
            parameters.write(to: &writer)
        }

        public static func read(from reader: inout WireReader) throws(WireError) -> SubscribeNamespace {
            let message = SubscribeNamespace(
                requestID: try reader.varInt(),
                prefix: try TrackNamespace.read(from: &reader),
                parameters: try MessageParameters.read(from: &reader)
            )
            try message.parameters.validate(allowing: [.authorizationToken], in: "SUBSCRIBE_NAMESPACE")
            return message
        }
    }

    /// Ask for PUBLISH of every track under a prefix (§9.18). Codec only: the
    /// SDK does not send it.
    public struct SubscribeTracks: DraftControlMessage {
        public static let typeCode = MessageCode.subscribeTracks.rawValue
        static let allowed: Set<MessageParameter.Kind> = [
            .authorizationToken, .forward, .groupOrder, .subgroupFilter, .objectIDFilter,
            .priorityFilter, .objectPropertyFilter, .trackPropertyFilter, .includeProperties,
        ]

        public var requestID: UInt64
        public var prefix: TrackNamespace
        public var parameters: MessageParameters

        public init(requestID: UInt64, prefix: TrackNamespace, parameters: MessageParameters = []) {
            self.requestID = requestID
            self.prefix = prefix
            self.parameters = parameters
        }

        public func write(to writer: inout WireWriter) {
            writer.varInt(requestID)
            prefix.write(to: &writer)
            parameters.write(to: &writer)
        }

        public static func read(from reader: inout WireReader) throws(WireError) -> SubscribeTracks {
            let message = SubscribeTracks(
                requestID: try reader.varInt(),
                prefix: try TrackNamespace.read(from: &reader),
                parameters: try MessageParameters.read(from: &reader)
            )
            try message.parameters.validate(allowing: allowed, in: "SUBSCRIBE_TRACKS")
            return message
        }
    }

    /// A track under a SUBSCRIBE_TRACKS prefix that will not be published
    /// (§9.19).
    public struct PublishSkipped: DraftControlMessage {
        public static let typeCode = MessageCode.publishSkipped.rawValue

        public var suffix: TrackNamespace
        public var name: String

        public init(suffix: TrackNamespace, name: String) {
            self.suffix = suffix
            self.name = name
        }

        public func write(to writer: inout WireWriter) {
            suffix.write(to: &writer)
            writer.lengthPrefixed(name)
        }

        public static func read(from reader: inout WireReader) throws(WireError) -> PublishSkipped {
            PublishSkipped(suffix: try TrackNamespace.read(from: &reader), name: try reader.lengthPrefixedString())
        }
    }

    /// Generic success (§9.3): PUBLISH_OK, REQUEST_UPDATE_OK, TRACK_STATUS_OK
    /// and the namespace OKs are all this.
    public struct RequestOk: DraftControlMessage {
        public static let typeCode = MessageCode.requestOk.rawValue
        static let allowed: Set<MessageParameter.Kind> = [.expires, .largestObject]

        public var parameters: MessageParameters
        public var properties: Parameters

        public init(parameters: MessageParameters = [], properties: Parameters = Parameters()) {
            self.parameters = parameters
            self.properties = properties
        }

        public func write(to writer: inout WireWriter) {
            parameters.write(to: &writer)
            properties.write(to: &writer)
        }

        public static func read(from reader: inout WireReader) throws(WireError) -> RequestOk {
            let message = RequestOk(
                parameters: try MessageParameters.read(from: &reader),
                properties: try Parameters.readToEnd(from: &reader)
            )
            try message.parameters.validate(allowing: allowed, in: "REQUEST_OK")
            return message
        }
    }

    /// Change a request in flight (§9.5). Consumes a Request ID of its own;
    /// the request it modifies is the one whose stream it is sent on.
    public struct RequestUpdate: DraftControlMessage {
        public static let typeCode = MessageCode.requestUpdate.rawValue
        /// The union over every request type. Which subset applies depends on
        /// the stream's request, which only the session knows.
        static let allowed: Set<MessageParameter.Kind> = [
            .objectDeliveryTimeout, .authorizationToken, .subgroupDeliveryTimeout, .forward,
            .subscriberPriority, .locationFilter, .fillParameters, .subgroupFilter, .objectIDFilter,
            .priorityFilter, .objectPropertyFilter, .trackPropertyFilter, .newGroupRequest,
            .trackNamespacePrefix,
        ]

        public var requestID: UInt64
        public var parameters: MessageParameters

        public init(requestID: UInt64, parameters: MessageParameters = []) {
            self.requestID = requestID
            self.parameters = parameters
        }

        public func write(to writer: inout WireWriter) {
            writer.varInt(requestID)
            parameters.write(to: &writer)
        }

        public static func read(from reader: inout WireReader) throws(WireError) -> RequestUpdate {
            let message = RequestUpdate(
                requestID: try reader.varInt(),
                parameters: try MessageParameters.read(from: &reader)
            )
            try message.parameters.validate(allowing: allowed, in: "REQUEST_UPDATE")
            return message
        }
    }
}
