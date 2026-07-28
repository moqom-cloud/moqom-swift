// FETCH: asking for the past, per draft-19 §10.12 and §11.4.4.
//
// Everything else in this codec streams forward from now. Fetch is the one
// operation that names a range of history, and it is shaped differently enough
// from a subscription to be worth stating rather than assuming:
//
//   - **The end is exclusive on the wire.** The prose in §10.12.3 calls the
//     range inclusive and the field description says "the end Location, plus
//     1". Both are true — the range is inclusive, the encoding is not — and an
//     implementation that reads only one of those sentences is off by one
//     object at the end of every fetch. ``FetchEnd`` exists so the `+1` is not
//     something a caller can forget.
//   - **A fetch stream crosses group boundaries**, which a subgroup stream
//     never does, so the delta state is larger and nothing resets implicitly.
//     Advancing the group does *not* reset the Object ID, the Subgroup ID, or
//     the priority; §11.4.4.1's "regardless of which group it belongs to" is
//     the trap, and ``FetchWriter`` avoids it by emitting an absolute Object ID
//     whenever the group moves.
//   - **There is no Object Status on a fetch stream** (§11.2.1.1). Absence is
//     expressed by gaps in the numbering and by the two End of Range markers,
//     and the end of the track is reported once in FETCH_OK. A zero-length
//     payload here is an object with no bytes, nothing more.
//   - **There is no FETCH_CANCEL.** Draft-16 removed the cancel messages when
//     requests moved onto bidirectional streams, so cancelling a fetch is
//     STOP_SENDING on the request stream — mandatory there, optional on the
//     data stream.
//
// Unlike the rest of `MoqomWire`, none of this is a port: `rs/moqom-proto` has
// not written fetch framing either, so the byte-level tests here are checked
// against the draft's own field diagrams rather than against another
// implementation's output. That is a weaker check and worth knowing about.

import Foundation
import MoqomCore

public extension Location {
    var encodedLength: Int {
        WireSize.varInt(group) + WireSize.varInt(object)
    }

    func write(to writer: inout WireWriter) {
        writer.varInt(group)
        writer.varInt(object)
    }

    static func read(from reader: inout WireReader) throws(WireError) -> Location {
        Location(group: try reader.varInt(), object: try reader.varInt())
    }
}

public extension FetchEnd {
    /// The exclusive form the draft puts on the wire.
    var wire: Location {
        switch self {
        case let .through(location):
            Location(group: location.group, object: location.object + 1)
        case let .endOfGroup(group):
            Location(group: group, object: 0)
        }
    }

    init(wire: Location) {
        if wire.object == 0 {
            self = .endOfGroup(wire.group)
        } else {
            self = .through(Location(group: wire.group, object: wire.object - 1))
        }
    }

    var encodedLength: Int { wire.encodedLength }

    func write(to writer: inout WireWriter) { wire.write(to: &writer) }

    static func read(from reader: inout WireReader) throws(WireError) -> FetchEnd {
        FetchEnd(wire: try Location.read(from: &reader))
    }
}

// MARK: - FETCH

/// Request a range of objects that have already been published.
public struct Fetch: ControlMessage {
    public static let messageType = MessageType.fetch

    public var requestID: UInt64
    public var kind: Kind
    public var parameters: Parameters

    /// The three fetch types, carrying only the fields their type permits.
    ///
    /// A joining fetch names no track: the publisher takes the namespace, the
    /// name, and the end of the range from the subscription being joined. That
    /// is the whole reason the variants differ on the wire, and modelling them
    /// as one struct with optional fields would make "a standalone fetch with
    /// no track name" constructible.
    public enum Kind: Hashable, Sendable {
        /// An explicit range of an explicitly named track.
        case standalone(track: FullTrackName, start: Location, end: FetchEnd)

        /// The `groups` groups before wherever the joined subscription is now.
        ///
        /// This is the catch-up case: a viewer subscribes and asks for the last
        /// group or two in the same breath, so playback starts from a keyframe
        /// instead of from the middle of whatever group was in flight.
        case relativeJoining(request: UInt64, groups: UInt64)

        /// From this absolute group up to wherever the joined subscription is.
        case absoluteJoining(request: UInt64, group: UInt64)

        var code: UInt64 {
            switch self {
            case .standalone: 0x1
            case .relativeJoining: 0x2
            case .absoluteJoining: 0x3
            }
        }
    }

    public init(requestID: UInt64, kind: Kind, parameters: Parameters = Parameters()) {
        self.requestID = requestID
        self.kind = kind
        self.parameters = parameters
    }

    private var bodyLength: Int {
        switch kind {
        case let .standalone(track, start, end):
            track.encodedLength + start.encodedLength + end.encodedLength
        case let .relativeJoining(request, groups):
            WireSize.varInt(request) + WireSize.varInt(groups)
        case let .absoluteJoining(request, group):
            WireSize.varInt(request) + WireSize.varInt(group)
        }
    }

    public var encodedLength: Int {
        WireSize.varInt(requestID)
            + WireSize.varInt(kind.code)
            + bodyLength
            + parameters.encodedLengthCounted
    }

    public func write(to writer: inout WireWriter) {
        writer.varInt(requestID)
        writer.varInt(kind.code)
        switch kind {
        case let .standalone(track, start, end):
            track.write(to: &writer)
            start.write(to: &writer)
            end.write(to: &writer)
        case let .relativeJoining(request, groups):
            writer.varInt(request)
            writer.varInt(groups)
        case let .absoluteJoining(request, group):
            writer.varInt(request)
            writer.varInt(group)
        }
        parameters.writeCounted(to: &writer)
    }

    public static func read(from reader: inout WireReader) throws(WireError) -> Fetch {
        let requestID = try reader.varInt()
        let type = try reader.varInt()

        let kind: Kind
        switch type {
        case 0x1:
            let track = try FullTrackName.read(from: &reader)
            let start = try Location.read(from: &reader)
            let end = try FetchEnd.read(from: &reader)
            guard end.wire >= start else {
                throw WireError.invalid("fetch end precedes its start")
            }
            kind = .standalone(track: track, start: start, end: end)
        case 0x2:
            kind = .relativeJoining(request: try reader.varInt(), groups: try reader.varInt())
        case 0x3:
            kind = .absoluteJoining(request: try reader.varInt(), group: try reader.varInt())
        default:
            throw WireError.invalid("unregistered fetch type \(type)")
        }

        return Fetch(
            requestID: requestID,
            kind: kind,
            parameters: try Parameters.readCounted(from: &reader)
        )
    }
}

/// A fetch was accepted, and this is the range that will actually arrive.
///
/// Distinct from the generic `REQUEST_OK` — which is what PUBLISH_OK collapsed
/// into — because these two fields have nowhere else to go. The requested range
/// is a guess about history the subscriber has not seen; this is the answer.
public struct FetchOk: ControlMessage {
    public static let messageType = MessageType.fetchOk

    /// Every object on the track has been published and ``end`` is the last of
    /// them. An 8-bit field on the wire, not a varint.
    public var endOfTrack: Bool

    /// The end of the range being served, which is the requested end clamped to
    /// what exists.
    public var end: FetchEnd

    public var parameters: Parameters
    public var properties: Parameters

    public init(
        endOfTrack: Bool = false,
        end: FetchEnd,
        parameters: Parameters = Parameters(),
        properties: Parameters = Parameters()
    ) {
        self.endOfTrack = endOfTrack
        self.end = end
        self.parameters = parameters
        self.properties = properties
    }

    public var encodedLength: Int {
        1 + end.encodedLength + parameters.encodedLengthCounted + properties.encodedLength
    }

    public func write(to writer: inout WireWriter) {
        writer.byte(endOfTrack ? 1 : 0)
        end.write(to: &writer)
        parameters.writeCounted(to: &writer)
        properties.write(to: &writer)
    }

    public static func read(from reader: inout WireReader) throws(WireError) -> FetchOk {
        FetchOk(
            endOfTrack: try reader.byte() != 0,
            end: try FetchEnd.read(from: &reader),
            parameters: try Parameters.readCounted(from: &reader),
            properties: try Parameters.readToEnd(from: &reader)
        )
    }
}

// MARK: - The data stream

/// Unidirectional stream type codes.
///
/// Needed because a fetch stream and a subgroup stream arrive the same way and
/// are told apart by their first varint. The subgroup type codes are a bit
/// layout rather than an enumeration, so this only names the ones that are a
/// single value.
public enum StreamType {
    public static let fetchHeader: UInt64 = 0x5

    /// Which kind of stream this is, from its leading varint, without consuming
    /// it — the header parsers each want the code themselves.
    public static func peek(_ data: Data) -> Kind? {
        var reader = WireReader(data)
        guard let code = try? reader.varInt() else { return nil }
        if code == fetchHeader { return .fetch }
        if let byte = UInt8(exactly: code), byte & SubgroupType.marker != 0 { return .subgroup }
        return nil
    }

    public enum Kind: Hashable, Sendable {
        case fetch
        case subgroup
    }
}

/// The header of a fetch's data stream.
///
/// Bound to its request by Request ID, and by nothing else — there is no track
/// alias here, because a fetch answers exactly one request and the request
/// already named the track.
public struct FetchHeader: Hashable, Sendable {
    public var requestID: UInt64

    public init(requestID: UInt64) {
        self.requestID = requestID
    }

    public var encodedLength: Int {
        WireSize.varInt(StreamType.fetchHeader) + WireSize.varInt(requestID)
    }

    public func write(to writer: inout WireWriter) {
        writer.varInt(StreamType.fetchHeader)
        writer.varInt(requestID)
    }

    public static func read(from reader: inout WireReader) throws(WireError) -> FetchHeader {
        let code = try reader.varInt()
        guard code == StreamType.fetchHeader else {
            throw WireError.invalid("stream type 0x\(String(code, radix: 16)) is not FETCH_HEADER")
        }
        return FetchHeader(requestID: try reader.varInt())
    }
}

/// One object on a fetch stream.
///
/// Fully resolved: the deltas have been applied, so nothing here depends on
/// what came before it. ``FetchReader`` owns that state and this is its output.
public struct FetchObject: Hashable, Sendable {
    public var location: Location
    public var subgroup: UInt64
    public var priority: UInt8
    public var properties: Parameters
    public var payload: Data

    public init(
        location: Location,
        subgroup: UInt64 = 0,
        priority: UInt8 = 128,
        properties: Parameters = Parameters(),
        payload: Data = Data()
    ) {
        self.location = location
        self.subgroup = subgroup
        self.priority = priority
        self.properties = properties
        self.payload = payload
    }
}

/// A record on a fetch stream.
public enum FetchRecord: Hashable, Sendable {
    case object(FetchObject)

    /// Everything from after the previous record up to and including this
    /// location does not exist.
    case endOfNonExistentRange(Location)

    /// Everything from after the previous record up to and including this
    /// location has unknown status.
    ///
    /// The difference from ``endOfNonExistentRange`` is a real one for a relay
    /// serving from a partial cache: "I know these are not there" and "I do not
    /// know" lead a subscriber to different decisions, and collapsing them
    /// would have a cache miss look like a deleted object.
    case endOfUnknownRange(Location)
}

/// A protocol violation specific to fetch streams.
public enum FetchError: Error, Hashable, Sendable {
    /// The first record referred to a previous one, which does not exist.
    case firstRecordReferencesPrior

    /// Locations must advance along the stream, in the negotiated group order.
    case notAdvancing(previous: Location, next: Location)

    /// A group delta was too large to encode.
    case gapTooLarge(previous: UInt64, next: UInt64)

    /// An End of Range referred to a prior object's subgroup or priority when
    /// there had not been one.
    case rangeWithoutPriorObject
}

/// Bit layout of a fetch record's Serialization Flags.
///
/// Values below 128 are flags; two values above it are the End of Range markers
/// and are whole values rather than combinations. That is why this is not
/// simply an option set.
public struct FetchFlags: Hashable, Sendable {
    /// Object ID Delta present; otherwise the ID is the prior object's plus one.
    public static let objectDelta: UInt64 = 0x04
    /// Group ID Delta present; otherwise the group is the prior object's.
    public static let groupDelta: UInt64 = 0x08
    /// Priority present; otherwise it is the prior object's.
    public static let priority: UInt64 = 0x10
    /// Properties present. Never inherited, unlike everything else here.
    public static let properties: UInt64 = 0x20
    /// The object's forwarding preference was Datagram, so it has no subgroup
    /// and the two low bits are to be ignored.
    public static let datagram: UInt64 = 0x40

    public static let subgroupMask: UInt64 = 0x03

    public static let endOfNonExistentRange: UInt64 = 0x8C
    public static let endOfUnknownRange: UInt64 = 0x10C

    /// The markers as flag values, without a throwing initialiser in the way.
    static let nonExistentMarker = FetchFlags(unchecked: endOfNonExistentRange)
    static let unknownMarker = FetchFlags(unchecked: endOfUnknownRange)

    /// How a record names its subgroup.
    public enum Subgroup: UInt64, Sendable, Hashable {
        case zero = 0x0
        case sameAsPrior = 0x1
        case priorPlusOne = 0x2
        case present = 0x3
    }

    public let value: UInt64

    public init(
        subgroup: Subgroup,
        objectDelta: Bool,
        groupDelta: Bool,
        priority: Bool,
        properties: Bool,
        datagram: Bool = false
    ) {
        var value = subgroup.rawValue
        if objectDelta { value |= Self.objectDelta }
        if groupDelta { value |= Self.groupDelta }
        if priority { value |= Self.priority }
        if properties { value |= Self.properties }
        if datagram { value |= Self.datagram }
        self.value = value
    }

    public init(code: UInt64) throws(WireError) {
        guard code < 128
            || code == Self.endOfNonExistentRange
            || code == Self.endOfUnknownRange
        else {
            throw WireError.invalid(
                "serialization flags 0x\(String(code, radix: 16)) is neither flags nor a marker"
            )
        }
        value = code
    }

    private init(unchecked value: UInt64) {
        self.value = value
    }

    public var isEndOfRange: Bool {
        value == Self.endOfNonExistentRange || value == Self.endOfUnknownRange
    }

    public var hasObjectDelta: Bool { value & Self.objectDelta != 0 }
    public var hasGroupDelta: Bool { value & Self.groupDelta != 0 }
    public var hasPriority: Bool { value & Self.priority != 0 }
    public var hasProperties: Bool { value & Self.properties != 0 }
    public var isDatagram: Bool { value & Self.datagram != 0 }

    public var subgroup: Subgroup {
        // The two low bits are meaningless when the datagram bit is set, and
        // the draft says to ignore them rather than to reject them.
        if isDatagram { return .zero }
        return Subgroup(rawValue: value & Self.subgroupMask) ?? .zero
    }

    /// Whether this record depends on a preceding one, which the first record
    /// on a stream may not.
    public var referencesPrior: Bool {
        if isEndOfRange { return false }
        if !hasGroupDelta || !hasObjectDelta || !hasPriority { return true }
        return subgroup == .sameAsPrior || subgroup == .priorPlusOne
    }
}

/// The delta state shared by ``FetchWriter`` and ``FetchReader``.
///
/// Split out because the two halves have to agree on exactly one thing —
/// what "prior" means after each record — and the End of Range case makes that
/// non-obvious: a marker updates the prior group and object but leaves the
/// prior subgroup and priority as they were before it.
private struct FetchState: Sendable {
    var group: UInt64?
    var object: UInt64?
    var subgroup: UInt64?
    var priority: UInt8?

    var isEmpty: Bool { group == nil }

    var location: Location? {
        guard let group, let object else { return nil }
        return Location(group: group, object: object)
    }

    mutating func advance(to object: FetchObject) {
        group = object.location.group
        self.object = object.location.object
        subgroup = object.subgroup
        priority = object.priority
    }

    /// A marker moves the location and nothing else. §11.4.4.2 is explicit that
    /// the object after an End of Range inherits subgroup and priority from the
    /// last *real* object, not from the marker, which has neither.
    mutating func advance(to location: Location) {
        group = location.group
        object = location.object
    }
}

/// Writes records onto one fetch stream.
public struct FetchWriter: Sendable {
    public let header: FetchHeader
    public let order: GroupOrder

    private var state = FetchState()

    public init(header: FetchHeader, order: GroupOrder = .ascending) {
        self.header = header
        self.order = order
    }

    /// The encoding decisions for one record, made once so that
    /// ``encodedLength(of:)`` and ``write(_:to:)`` cannot disagree.
    private struct Plan {
        var flags: FetchFlags
        var groupDelta: UInt64?
        var objectDelta: UInt64?
        var subgroup: UInt64?
        var priority: UInt8?
        var properties: Parameters
        var payload: Data?
        var location: Location
    }

    private func groupDelta(to group: UInt64) throws(FetchError) -> UInt64? {
        guard let previous = state.group else { return group }
        if group == previous { return nil }

        let distance: UInt64
        switch order {
        case .ascending:
            guard group > previous else {
                throw FetchError.notAdvancing(
                    previous: Location(group: previous, object: state.object ?? 0),
                    next: Location(group: group, object: 0)
                )
            }
            distance = group - previous - 1
        case .descending:
            guard group < previous else {
                throw FetchError.notAdvancing(
                    previous: Location(group: previous, object: state.object ?? 0),
                    next: Location(group: group, object: 0)
                )
            }
            distance = previous - group - 1
        }
        guard distance <= varIntMaximum else {
            throw FetchError.gapTooLarge(previous: previous, next: group)
        }
        return distance
    }

    private func plan(for object: FetchObject) throws(FetchError) -> Plan {
        let groupDelta = try groupDelta(to: object.location.group)

        // When the group moves, an absolute Object ID goes out even though the
        // draft would allow inheriting prior+1. Inheriting across a group
        // boundary is legal, almost never what a publisher means, and produces
        // a plausible-looking wrong number rather than a parse failure.
        let objectDelta: UInt64?
        if state.isEmpty || groupDelta != nil {
            objectDelta = object.location.object
        } else if let previous = state.object {
            if object.location.object == previous + 1 {
                objectDelta = nil
            } else {
                guard object.location.object > previous else {
                    throw FetchError.notAdvancing(
                        previous: Location(group: object.location.group, object: previous),
                        next: object.location
                    )
                }
                objectDelta = object.location.object - previous
            }
        } else {
            objectDelta = object.location.object
        }

        // `.zero` is preferred over `.sameAsPrior` when both would do, and they
        // are the same size. It refers to nothing, so a record encoded this way
        // survives being the first on its stream — which matters because whether
        // a given record ends up first is a decision made elsewhere.
        let subgroupMode: FetchFlags.Subgroup
        var subgroup: UInt64?
        if object.subgroup == 0 {
            subgroupMode = .zero
        } else if let prior = state.subgroup, object.subgroup == prior {
            subgroupMode = .sameAsPrior
        } else if let prior = state.subgroup, object.subgroup == prior + 1 {
            subgroupMode = .priorPlusOne
        } else {
            subgroupMode = .present
            subgroup = object.subgroup
        }

        let priority: UInt8? = object.priority == state.priority ? nil : object.priority

        return Plan(
            flags: FetchFlags(
                subgroup: subgroupMode,
                objectDelta: objectDelta != nil,
                groupDelta: groupDelta != nil,
                priority: priority != nil,
                properties: !object.properties.isEmpty
            ),
            groupDelta: groupDelta,
            objectDelta: objectDelta,
            subgroup: subgroup,
            priority: priority,
            properties: object.properties,
            payload: object.payload,
            location: object.location
        )
    }

    private func plan(marker: FetchFlags, at location: Location) throws(FetchError) -> Plan {
        if let previous = state.location, location <= previous, order == .ascending {
            throw FetchError.notAdvancing(previous: previous, next: location)
        }
        // Absolute, not delta-encoded, and this is the one place in the file
        // where the draft does not say which. §11.4.4.2 calls them "the Group ID
        // and Object ID fields"; Figure 27 names those same fields Group ID
        // Delta and Object ID Delta.
        //
        // Absolute is the reading that works. A marker's flags value is a fixed
        // constant with both delta bits set, so the fields cannot be elided —
        // and under the delta reading a group delta of 0 means *the next* group
        // in ascending order, which would make "objects 5 through 9 of this
        // group do not exist" inexpressible. That is the ordinary case for a
        // relay serving a partial cache, so a reading that cannot encode it is
        // not the intended one.
        return Plan(
            flags: marker,
            groupDelta: location.group,
            objectDelta: location.object,
            subgroup: nil,
            priority: nil,
            properties: Parameters(),
            payload: nil,
            location: location
        )
    }

    private func plan(for record: FetchRecord) throws(FetchError) -> Plan {
        switch record {
        case let .object(object):
            return try plan(for: object)
        case let .endOfNonExistentRange(location):
            return try plan(marker: .nonExistentMarker, at: location)
        case let .endOfUnknownRange(location):
            return try plan(marker: .unknownMarker, at: location)
        }
    }

    private func length(of plan: Plan) -> Int {
        var length = WireSize.varInt(plan.flags.value)
        if let groupDelta = plan.groupDelta { length += WireSize.varInt(groupDelta) }
        if let subgroup = plan.subgroup { length += WireSize.varInt(subgroup) }
        if let objectDelta = plan.objectDelta { length += WireSize.varInt(objectDelta) }
        if plan.priority != nil { length += 1 }
        if !plan.properties.isEmpty {
            let body = plan.properties.encodedLength
            length += WireSize.varInt(UInt64(body)) + body
        }
        // Present even on a marker. §11.4.4.2 lists subgroup, priority, and
        // properties as absent and says nothing about the payload length, which
        // Figure 27 shows as unconditional — so it goes out as a zero. This is
        // the one field in this file where the draft is genuinely ambiguous and
        // two implementations could disagree.
        length += WireSize.varInt(UInt64(plan.payload?.count ?? 0))
        length += plan.payload?.count ?? 0
        return length
    }

    public func encodedLength(of record: FetchRecord) throws(FetchError) -> Int {
        length(of: try plan(for: record))
    }

    public mutating func write(
        _ record: FetchRecord,
        to writer: inout WireWriter
    ) throws(FetchError) {
        let plan = try plan(for: record)

        writer.varInt(plan.flags.value)
        if let groupDelta = plan.groupDelta { writer.varInt(groupDelta) }
        if let subgroup = plan.subgroup { writer.varInt(subgroup) }
        if let objectDelta = plan.objectDelta { writer.varInt(objectDelta) }
        if let priority = plan.priority { writer.byte(priority) }
        if !plan.properties.isEmpty {
            writer.varInt(UInt64(plan.properties.encodedLength))
            plan.properties.write(to: &writer)
        }
        let payload = plan.payload ?? Data()
        writer.varInt(UInt64(payload.count))
        writer.raw(payload)

        if case let .object(object) = record {
            state.advance(to: object)
        } else {
            state.advance(to: plan.location)
        }
    }
}

/// Reads records from one fetch stream.
public struct FetchReader: Sendable {
    public let header: FetchHeader
    public let order: GroupOrder

    private var state = FetchState()

    public init(header: FetchHeader, order: GroupOrder = .ascending) {
        self.header = header
        self.order = order
    }

    public mutating func read(from reader: inout WireReader) throws(WireError) -> FetchRecord {
        let flags = try FetchFlags(code: try reader.varInt())

        guard !state.isEmpty || !flags.referencesPrior else {
            throw WireError.invalid("first fetch record refers to a prior object")
        }

        let groupDelta: UInt64? = flags.hasGroupDelta ? try reader.varInt() : nil
        let subgroupField: UInt64? = flags.subgroup == .present ? try reader.varInt() : nil
        let objectDelta: UInt64? = flags.hasObjectDelta ? try reader.varInt() : nil

        if flags.isEndOfRange {
            // Absolute rather than delta-encoded; the reasoning is in
            // `FetchWriter.plan(marker:at:)`.
            let location = Location(group: groupDelta ?? 0, object: objectDelta ?? 0)
            let length = try reader.varInt()
            guard length == 0 else {
                throw WireError.invalid("end of range marker carried a payload")
            }
            state.advance(to: location)
            return flags.value == FetchFlags.endOfNonExistentRange
                ? .endOfNonExistentRange(location)
                : .endOfUnknownRange(location)
        }

        let group: UInt64
        if let groupDelta {
            if let previous = state.group {
                switch order {
                case .ascending:
                    let (sum, overflow) = previous.addingReportingOverflow(groupDelta + 1)
                    guard !overflow else { throw WireError.invalid("group ID passed 2^64-1") }
                    group = sum
                case .descending:
                    guard previous >= groupDelta + 1 else {
                        throw WireError.invalid("descending group ID passed below zero")
                    }
                    group = previous - groupDelta - 1
                }
            } else {
                group = groupDelta
            }
        } else {
            // Validated above: the first record must carry a group delta.
            group = state.group ?? 0
        }

        let object: UInt64
        if groupDelta != nil {
            // Absolute within the new group when the group moved, a delta
            // otherwise. One field, two meanings, chosen by a different flag.
            object = objectDelta ?? ((state.object ?? 0) + 1)
        } else if let objectDelta {
            let (sum, overflow) = (state.object ?? 0).addingReportingOverflow(objectDelta)
            guard !overflow else { throw WireError.invalid("object ID passed 2^64-1") }
            object = sum
        } else {
            object = (state.object ?? 0) + 1
        }

        let location = Location(group: group, object: object)

        let subgroup: UInt64
        switch flags.subgroup {
        case .zero: subgroup = 0
        case .present: subgroup = subgroupField ?? 0
        case .sameAsPrior: subgroup = state.subgroup ?? 0
        case .priorPlusOne: subgroup = (state.subgroup ?? 0) + 1
        }

        let priority: UInt8
        if flags.hasPriority {
            priority = try reader.byte()
        } else {
            priority = state.priority ?? 128
        }

        var properties = Parameters()
        if flags.hasProperties {
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

        let result = FetchObject(
            location: location,
            subgroup: subgroup,
            priority: priority,
            properties: properties,
            payload: try reader.take(payloadLength)
        )
        state.advance(to: result)
        return .object(result)
    }
}
