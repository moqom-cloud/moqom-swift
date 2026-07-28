// Object framing: subgroup streams and datagrams, per draft-19 §11.
//
// The control plane is where the interesting protocol decisions live, but this
// is where the bytes are. Every field here is optional-by-flag, and the flags
// are packed into the stream or datagram type itself rather than carried
// separately, so a typical object costs a couple of bytes of overhead. That is
// the reason the type codes are bit layouts rather than an enumeration, and the
// reason they are modelled as such: an invalid combination should be
// unconstructible rather than rejected at the socket.

import Foundation

/// Object delivery status, per draft-19 §11.
public enum ObjectStatus: UInt64, Sendable {
    /// The only status permitted to carry a payload.
    case normal = 0x0
    /// No object in this group has an Object ID at or above this one.
    case endOfGroup = 0x3
    /// No object at or after this location exists.
    case endOfTrack = 0x4

    public init(code: UInt64) throws(WireError) {
        guard let status = ObjectStatus(rawValue: code) else {
            throw WireError.invalid("unregistered object status \(code)")
        }
        self = status
    }

    public var permitsPayload: Bool { self == .normal }

    var encodedLength: Int { WireSize.varInt(rawValue) }

    func write(to writer: inout WireWriter) { writer.varInt(rawValue) }
}

/// A non-normal status, which by definition carries no payload.
///
/// Separate from ``ObjectStatus`` so that "an object that ends a group" and "an
/// object with bytes in it" cannot both be true of one value. The Rust codec
/// makes the same split for the same reason.
public enum TerminalStatus: Sendable, Hashable {
    case endOfGroup
    case endOfTrack

    var status: ObjectStatus {
        switch self {
        case .endOfGroup: .endOfGroup
        case .endOfTrack: .endOfTrack
        }
    }

    init?(_ status: ObjectStatus) {
        switch status {
        case .normal: return nil
        case .endOfGroup: self = .endOfGroup
        case .endOfTrack: self = .endOfTrack
        }
    }
}

// MARK: - Datagrams

/// The bit-packed type code of an `OBJECT_DATAGRAM`, of the form `0b00X0XXXX`.
public struct DatagramType: Hashable, Sendable {
    /// Object properties follow the fixed fields.
    public static let properties: UInt8 = 0x01
    /// No object in this group has a larger Object ID.
    public static let endOfGroup: UInt8 = 0x02
    /// The Object ID field is omitted and the Object ID is zero.
    public static let zeroObjectID: UInt8 = 0x04
    /// The priority field is omitted; inherit it from the subscription.
    public static let defaultPriority: UInt8 = 0x08
    /// Carries an object status instead of a payload.
    public static let status: UInt8 = 0x20

    public static let mask: UInt8 =
        properties | endOfGroup | zeroObjectID | defaultPriority | status

    public let bits: UInt8

    public init(
        properties: Bool,
        zeroObjectID: Bool,
        defaultPriority: Bool,
        carriesStatus: Bool,
        endOfGroup: Bool
    ) {
        var bits: UInt8 = 0
        if properties { bits |= Self.properties }
        if zeroObjectID { bits |= Self.zeroObjectID }
        if defaultPriority { bits |= Self.defaultPriority }
        // Status and end-of-group are mutually exclusive on the wire, and a
        // terminal object is already the end of something, so status wins.
        if carriesStatus {
            bits |= Self.status
        } else if endOfGroup {
            bits |= Self.endOfGroup
        }
        self.bits = bits
    }

    public init(code: UInt64) throws(WireError) {
        guard code <= UInt64(Self.mask), UInt8(code) & ~Self.mask == 0 else {
            throw WireError.invalid("datagram type is outside the form 0b00X0XXXX")
        }
        let bits = UInt8(code)
        guard bits & Self.status == 0 || bits & Self.endOfGroup == 0 else {
            throw WireError.invalid("datagram cannot be both a status and end of group")
        }
        self.bits = bits
    }

    public var hasProperties: Bool { bits & Self.properties != 0 }
    public var isEndOfGroup: Bool { bits & Self.endOfGroup != 0 }
    public var hasZeroObjectID: Bool { bits & Self.zeroObjectID != 0 }
    public var hasDefaultPriority: Bool { bits & Self.defaultPriority != 0 }
    public var carriesStatus: Bool { bits & Self.status != 0 }
}

/// A single object delivered unreliably.
public struct ObjectDatagram: Sendable {
    public var trackAlias: UInt64
    public var group: UInt64
    public var object: UInt64

    /// `nil` means inherit the subscription's priority, which saves the byte.
    public var priority: UInt8?

    public var properties: Parameters
    public var content: Content

    public enum Content: Sendable {
        /// A normal object with bytes.
        case payload(Data, endOfGroup: Bool)
        /// A normal object with no bytes, which is legal and distinct from a
        /// terminal status.
        case empty
        case terminal(TerminalStatus)
    }

    public init(
        trackAlias: UInt64,
        group: UInt64,
        object: UInt64,
        priority: UInt8? = nil,
        properties: Parameters = Parameters(),
        content: Content
    ) {
        self.trackAlias = trackAlias
        self.group = group
        self.object = object
        self.priority = priority
        self.properties = properties
        self.content = content
    }

    public var type: DatagramType {
        let carriesStatus: Bool
        let endOfGroup: Bool
        switch content {
        case let .payload(_, eog):
            carriesStatus = false
            endOfGroup = eog
        case .empty:
            // A zero-length object encodes an explicit Normal status rather
            // than relying on an empty payload region, because a datagram
            // payload has no length field to be zero.
            carriesStatus = true
            endOfGroup = false
        case .terminal:
            carriesStatus = true
            endOfGroup = false
        }
        return DatagramType(
            properties: !properties.isEmpty && !carriesStatusForbidsProperties,
            zeroObjectID: object == 0,
            defaultPriority: priority == nil,
            carriesStatus: carriesStatus,
            endOfGroup: endOfGroup
        )
    }

    /// Terminal objects may not carry properties; an empty normal object may.
    private var carriesStatusForbidsProperties: Bool {
        if case .terminal = content { return true }
        return false
    }

    private var effectiveProperties: Parameters {
        carriesStatusForbidsProperties ? Parameters() : properties
    }

    public var encodedLength: Int {
        let type = type
        var length = WireSize.varInt(UInt64(type.bits))
        length += WireSize.varInt(trackAlias)
        length += WireSize.varInt(group)
        if !type.hasZeroObjectID { length += WireSize.varInt(object) }
        if priority != nil { length += 1 }
        let properties = effectiveProperties
        if !properties.isEmpty {
            length += WireSize.varInt(UInt64(properties.encodedLength)) + properties.encodedLength
        }
        switch content {
        case let .payload(payload, _): length += payload.count
        case .empty: length += ObjectStatus.normal.encodedLength
        case let .terminal(status): length += status.status.encodedLength
        }
        return length
    }

    public func write(to writer: inout WireWriter) {
        let type = type
        writer.varInt(UInt64(type.bits))
        writer.varInt(trackAlias)
        writer.varInt(group)
        if !type.hasZeroObjectID { writer.varInt(object) }
        if let priority { writer.byte(priority) }
        let properties = effectiveProperties
        if !properties.isEmpty {
            writer.varInt(UInt64(properties.encodedLength))
            properties.write(to: &writer)
        }
        switch content {
        case let .payload(payload, _): writer.raw(payload)
        case .empty: ObjectStatus.normal.write(to: &writer)
        case let .terminal(status): status.status.write(to: &writer)
        }
    }

    public static func read(from reader: inout WireReader) throws(WireError) -> ObjectDatagram {
        let type = try DatagramType(code: try reader.varInt())
        let trackAlias = try reader.varInt()
        let group = try reader.varInt()
        let object = type.hasZeroObjectID ? 0 : try reader.varInt()
        let priority: UInt8? = type.hasDefaultPriority ? nil : try reader.byte()

        var properties = Parameters()
        if type.hasProperties {
            let length = try reader.varInt()
            guard length > 0 else {
                throw WireError.invalid("properties bit set with a zero-length set")
            }
            var body = WireReader(try reader.take(Int(length)))
            properties = try Parameters.readToEnd(from: &body)
        }

        let content: Content
        if type.carriesStatus {
            let status = try ObjectStatus(code: try reader.varInt())
            if let terminal = TerminalStatus(status) {
                guard properties.isEmpty else {
                    throw WireError.invalid("only normal objects may carry properties")
                }
                content = .terminal(terminal)
            } else {
                content = .empty
            }
        } else {
            content = .payload(reader.rest, endOfGroup: type.isEndOfGroup)
        }

        return ObjectDatagram(
            trackAlias: trackAlias,
            group: group,
            object: object,
            priority: priority,
            properties: properties,
            content: content
        )
    }
}

// MARK: - Subgroup streams

/// How a subgroup stream names its subgroup.
public enum SubgroupIDMode: UInt8, Sendable {
    /// The field is absent and the subgroup ID is zero.
    case zero = 0b00
    /// The field is absent and the subgroup ID is the Object ID of the first
    /// object on the stream, which means it is not known from the header alone.
    case firstObjectID = 0b01
    /// The subgroup ID is present in the header.
    case explicit = 0b10
}

/// The bit-packed type code of a `SUBGROUP_HEADER`, of the form `0b0XX1XXXX`.
public struct SubgroupType: Hashable, Sendable {
    /// Object properties are present on *every* object on this stream.
    public static let properties: UInt8 = 0x01
    /// Two-bit subgroup ID mode.
    public static let subgroupIDMode: UInt8 = 0x06
    /// This subgroup contains the largest object in the group.
    public static let endOfGroup: UInt8 = 0x08
    /// Always set; distinguishes a subgroup header from a datagram.
    public static let marker: UInt8 = 0x10
    /// The priority field is omitted; inherit it from the subscription.
    public static let defaultPriority: UInt8 = 0x20
    /// The first object here is the first the original publisher sent.
    public static let firstObject: UInt8 = 0x40

    public static let mask: UInt8 =
        properties | subgroupIDMode | endOfGroup | marker | defaultPriority | firstObject

    public let bits: UInt8

    public init(
        properties: Bool,
        mode: SubgroupIDMode,
        endOfGroup: Bool,
        defaultPriority: Bool,
        firstObject: Bool
    ) {
        var bits = Self.marker | (mode.rawValue << 1)
        if properties { bits |= Self.properties }
        if endOfGroup { bits |= Self.endOfGroup }
        if defaultPriority { bits |= Self.defaultPriority }
        if firstObject { bits |= Self.firstObject }
        self.bits = bits
    }

    public init(code: UInt64) throws(WireError) {
        guard code <= UInt64(Self.mask), UInt8(code) & ~Self.mask == 0 else {
            throw WireError.invalid("subgroup type is outside the form 0b0XX1XXXX")
        }
        let bits = UInt8(code)
        guard bits & Self.marker != 0 else {
            throw WireError.invalid("subgroup type must have bit 4 set")
        }
        guard SubgroupIDMode(rawValue: (bits & Self.subgroupIDMode) >> 1) != nil else {
            throw WireError.invalid("subgroup ID mode 0b11 is reserved")
        }
        self.bits = bits
    }

    public var hasProperties: Bool { bits & Self.properties != 0 }
    public var isEndOfGroup: Bool { bits & Self.endOfGroup != 0 }
    public var hasDefaultPriority: Bool { bits & Self.defaultPriority != 0 }
    public var isFirstObject: Bool { bits & Self.firstObject != 0 }

    public var mode: SubgroupIDMode {
        // Validated at construction, so the reserved value cannot be here.
        SubgroupIDMode(rawValue: (bits & Self.subgroupIDMode) >> 1) ?? .zero
    }
}

/// Where a stream's subgroup ID comes from.
public enum SubgroupSource: Hashable, Sendable {
    case zero
    case firstObjectID
    case explicit(UInt64)

    var mode: SubgroupIDMode {
        switch self {
        case .zero: .zero
        case .firstObjectID: .firstObjectID
        case .explicit: .explicit
        }
    }
}

/// The header of a subgroup stream.
public struct SubgroupHeader: Hashable, Sendable {
    public var trackAlias: UInt64
    public var group: UInt64
    public var subgroup: SubgroupSource
    public var priority: UInt8?

    /// Whether every object on this stream carries a properties field.
    ///
    /// A stream-wide decision rather than a per-object one, which is why it
    /// belongs to the header: a reader must know whether to expect the field
    /// before it has seen the object that would have justified it.
    public var propertiesPresent: Bool

    public var isEndOfGroup: Bool
    public var isFirstObject: Bool

    public init(
        trackAlias: UInt64,
        group: UInt64,
        subgroup: SubgroupSource = .zero,
        priority: UInt8? = nil,
        propertiesPresent: Bool = false,
        isEndOfGroup: Bool = false,
        isFirstObject: Bool = false
    ) {
        self.trackAlias = trackAlias
        self.group = group
        self.subgroup = subgroup
        self.priority = priority
        self.propertiesPresent = propertiesPresent
        self.isEndOfGroup = isEndOfGroup
        self.isFirstObject = isFirstObject
    }

    public var type: SubgroupType {
        SubgroupType(
            properties: propertiesPresent,
            mode: subgroup.mode,
            endOfGroup: isEndOfGroup,
            defaultPriority: priority == nil,
            firstObject: isFirstObject
        )
    }

    public var encodedLength: Int {
        var length = WireSize.varInt(UInt64(type.bits))
        length += WireSize.varInt(trackAlias)
        length += WireSize.varInt(group)
        if case let .explicit(id) = subgroup { length += WireSize.varInt(id) }
        if priority != nil { length += 1 }
        return length
    }

    public func write(to writer: inout WireWriter) {
        writer.varInt(UInt64(type.bits))
        writer.varInt(trackAlias)
        writer.varInt(group)
        if case let .explicit(id) = subgroup { writer.varInt(id) }
        if let priority { writer.byte(priority) }
    }

    public static func read(from reader: inout WireReader) throws(WireError) -> SubgroupHeader {
        let type = try SubgroupType(code: try reader.varInt())
        let trackAlias = try reader.varInt()
        let group = try reader.varInt()

        let subgroup: SubgroupSource
        switch type.mode {
        case .zero: subgroup = .zero
        case .firstObjectID: subgroup = .firstObjectID
        case .explicit: subgroup = .explicit(try reader.varInt())
        }

        let priority: UInt8? = type.hasDefaultPriority ? nil : try reader.byte()

        return SubgroupHeader(
            trackAlias: trackAlias,
            group: group,
            subgroup: subgroup,
            priority: priority,
            propertiesPresent: type.hasProperties,
            isEndOfGroup: type.isEndOfGroup,
            isFirstObject: type.isFirstObject
        )
    }
}

/// One object on a subgroup stream.
///
/// The Object ID here is absolute and 64-bit, not varint-bounded. Subgroup
/// streams carry deltas rather than absolute IDs, so an accumulated value may
/// legally exceed `2^62 - 1` — the draft caps it at `2^64 - 1` — and it is
/// legal precisely because the wide value is never itself encoded.
public struct SubgroupObject: Sendable {
    public var object: UInt64
    public var properties: Parameters
    public var content: Content

    public enum Content: Sendable {
        case payload(Data)
        case terminal(TerminalStatus)
    }

    public init(object: UInt64, properties: Parameters = Parameters(), content: Content) {
        self.object = object
        self.properties = properties
        self.content = content
    }
}

/// A protocol violation specific to subgroup streams.
public enum SubgroupError: Error, Hashable, Sendable {
    /// Object IDs must strictly increase along a stream.
    case notIncreasing(previous: UInt64, next: UInt64)

    /// The gap to the next Object ID is too large for one varint delta.
    case gapTooLarge(previous: UInt64?, next: UInt64)

    /// An object carried properties on a stream whose header did not declare
    /// them, which would produce a field the reader will not look for.
    case propertiesNotDeclared

    /// Nothing may follow a terminal object on its stream.
    case afterTerminal
}

/// Writes objects onto one subgroup stream.
///
/// Stateful because the encoding is: Object IDs go out as deltas from the
/// previous one, so a writer that forgot the previous value would produce a
/// stream that decodes to different numbers than it was given.
public struct SubgroupWriter: Sendable {
    public let header: SubgroupHeader
    private var previous: UInt64?
    private var finished = false

    public init(header: SubgroupHeader) {
        self.header = header
    }

    /// The first object's delta *is* its absolute ID; every later delta is
    /// `object - previous - 1`, so a delta of zero means consecutive.
    private func delta(for object: UInt64) throws(SubgroupError) -> UInt64 {
        guard let previous else { return object }
        guard object > previous else {
            throw SubgroupError.notIncreasing(previous: previous, next: object)
        }
        let delta = object - previous - 1
        guard delta <= varIntMaximum else {
            throw SubgroupError.gapTooLarge(previous: previous, next: object)
        }
        return delta
    }

    private func check(_ object: SubgroupObject) throws(SubgroupError) {
        guard !finished else { throw SubgroupError.afterTerminal }
        if !header.propertiesPresent, !object.properties.isEmpty {
            throw SubgroupError.propertiesNotDeclared
        }
    }

    public func encodedLength(of object: SubgroupObject) throws(SubgroupError) -> Int {
        try check(object)
        var length = WireSize.varInt(try delta(for: object.object))
        if header.propertiesPresent {
            switch object.content {
            case .payload:
                let body = object.properties.encodedLength
                length += WireSize.varInt(UInt64(body)) + body
            case .terminal:
                length += WireSize.varInt(0)
            }
        }
        switch object.content {
        case let .payload(payload) where payload.isEmpty:
            length += WireSize.varInt(0) + ObjectStatus.normal.encodedLength
        case let .payload(payload):
            length += WireSize.varInt(UInt64(payload.count)) + payload.count
        case let .terminal(status):
            length += WireSize.varInt(0) + status.status.encodedLength
        }
        return length
    }

    public mutating func write(
        _ object: SubgroupObject,
        to writer: inout WireWriter
    ) throws(SubgroupError) {
        try check(object)
        let delta = try delta(for: object.object)
        writer.varInt(delta)

        if header.propertiesPresent {
            switch object.content {
            case .payload:
                writer.varInt(UInt64(object.properties.encodedLength))
                object.properties.write(to: &writer)
            case .terminal:
                // A terminal object still needs the field the header promised.
                writer.varInt(0)
            }
        }

        switch object.content {
        case let .payload(payload) where payload.isEmpty:
            // Zero length is not "no object": it is a normal object with no
            // bytes, and the explicit status is how it stays distinguishable
            // from a terminal one.
            writer.varInt(0)
            ObjectStatus.normal.write(to: &writer)
        case let .payload(payload):
            writer.varInt(UInt64(payload.count))
            writer.raw(payload)
        case let .terminal(status):
            writer.varInt(0)
            status.status.write(to: &writer)
            finished = true
        }

        previous = object.object
    }
}

/// Reads objects from one subgroup stream.
public struct SubgroupReader: Sendable {
    public let header: SubgroupHeader
    private var previous: UInt64?
    private var firstObjectID: UInt64?

    public init(header: SubgroupHeader) {
        self.header = header
    }

    /// The resolved subgroup ID, which for ``SubgroupIDMode/firstObjectID`` is
    /// unknown until the first object has been read.
    public var subgroupID: UInt64? {
        switch header.subgroup {
        case .zero: 0
        case .explicit(let id): id
        case .firstObjectID: firstObjectID
        }
    }

    public mutating func read(from reader: inout WireReader) throws(WireError) -> SubgroupObject {
        let delta = try reader.varInt()
        let object: UInt64
        if let previous {
            let (sum, overflow) = previous.addingReportingOverflow(delta)
            let (next, overflow2) = sum.addingReportingOverflow(1)
            guard !overflow, !overflow2 else {
                throw WireError.invalid("object ID passed 2^64-1")
            }
            object = next
        } else {
            object = delta
            firstObjectID = delta
        }

        var properties = Parameters()
        if header.propertiesPresent {
            let length = try reader.varInt()
            if length > 0 {
                var body = WireReader(try reader.take(Int(length)))
                properties = try Parameters.readToEnd(from: &body)
            }
        }

        let payloadLength = try reader.varInt()
        guard let payloadLength = Int(exactly: payloadLength) else {
            throw WireError.invalid("payload length exceeds addressable memory")
        }

        previous = object

        if payloadLength == 0 {
            let status = try ObjectStatus(code: try reader.varInt())
            if let terminal = TerminalStatus(status) {
                guard properties.isEmpty else {
                    throw WireError.invalid("only normal objects may carry properties")
                }
                return SubgroupObject(object: object, content: .terminal(terminal))
            }
            return SubgroupObject(object: object, properties: properties, content: .payload(Data()))
        }

        return SubgroupObject(
            object: object,
            properties: properties,
            content: .payload(try reader.take(payloadLength))
        )
    }
}
