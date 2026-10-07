// Key-Value-Pair parameters, per draft-19 §1.4.3.
//
// Two properties of this encoding are easy to get wrong and produce a codec
// that interoperates with itself and nothing else. Both are copied from
// `rs/moqom-proto/src/control/params.rs` rather than re-read from the draft.
//
//   1. Types are delta-encoded. The wire carries `type - previous_type`,
//      starting from zero, so types are non-decreasing within a sequence and a
//      parameter's meaning depends on every parameter before it. Reordering a
//      sequence changes what it says.
//   2. Parity selects the value format. An even type is followed by a bare
//      varint; an odd type by a length and that many bytes. There is no
//      discriminator on the wire — the type number *is* the discriminator,
//      which is why ``Parameter`` refuses to hold a mismatched pair.

import Foundation
import MoqomCore

/// Largest permitted byte value: `2^16 - 1`.
public let maximumParameterValueLength = (1 << 16) - 1

/// A parameter whose value shape disagrees with its type's parity, or whose
/// value is too long to encode.
public enum ParameterError: Error, Hashable, Sendable {
    /// An even type was given bytes, or an odd type was given an integer.
    case parityMismatch(type: UInt64, expected: String)

    /// The byte value exceeds ``maximumParameterValueLength``.
    case valueTooLong(Int)

    /// The integer value exceeds what a varint can carry.
    case valueOutOfRange(UInt64)
}

/// One key-value pair.
public struct Parameter: Hashable, Sendable {
    public let type: UInt64
    public let value: Value

    public enum Value: Hashable, Sendable {
        case integer(UInt64)
        case bytes(Data)
    }

    /// An even-typed parameter carrying an integer.
    public static func integer(_ type: UInt64, _ value: UInt64) throws(ParameterError) -> Parameter {
        guard type.isMultiple(of: 2) else {
            throw ParameterError.parityMismatch(type: type, expected: "bytes")
        }
        guard value <= varIntMaximum else { throw ParameterError.valueOutOfRange(value) }
        return Parameter(type: type, value: .integer(value))
    }

    /// An odd-typed parameter carrying bytes.
    public static func bytes(_ type: UInt64, _ value: Data) throws(ParameterError) -> Parameter {
        guard !type.isMultiple(of: 2) else {
            throw ParameterError.parityMismatch(type: type, expected: "integer")
        }
        guard value.count <= maximumParameterValueLength else {
            throw ParameterError.valueTooLong(value.count)
        }
        return Parameter(type: type, value: .bytes(value))
    }

    public static func string(_ type: UInt64, _ value: String) throws(ParameterError) -> Parameter {
        try bytes(type, Data(value.utf8))
    }

    private init(type: UInt64, value: Value) {
        self.type = type
        self.value = value
    }

    public var integerValue: UInt64? {
        if case let .integer(value) = value { return value }
        return nil
    }

    public var bytesValue: Data? {
        if case let .bytes(value) = value { return value }
        return nil
    }

    fileprivate func size(after previous: UInt64, _ encoding: VarIntEncoding = .quic) -> Int {
        WireSize.varInt(type - previous, encoding)
            + {
                switch value {
                case let .integer(v): WireSize.varInt(v, encoding)
                case let .bytes(b): WireSize.varInt(UInt64(b.count), encoding) + b.count
                }
            }()
    }

    fileprivate func write(to writer: inout WireWriter, after previous: UInt64) {
        writer.varInt(type - previous)
        switch value {
        case let .integer(v): writer.varInt(v)
        case let .bytes(b): writer.lengthPrefixed(b)
        }
    }
}

/// An ordered parameter sequence.
///
/// Held sorted by type so that delta encoding is always possible, using a
/// stable sort so repeated types — `AUTHORIZATION_TOKEN` is the one registered
/// option defined to repeat — keep the order they were added in.
public struct Parameters: Hashable, Sendable, ExpressibleByArrayLiteral {
    public private(set) var items: [Parameter]

    public init() { items = [] }

    public init(_ items: [Parameter]) {
        self.items = items.enumerated()
            .sorted { lhs, rhs in
                lhs.element.type == rhs.element.type
                    ? lhs.offset < rhs.offset
                    : lhs.element.type < rhs.element.type
            }
            .map(\.element)
    }

    public init(arrayLiteral elements: Parameter...) {
        self.init(elements)
    }

    public var isEmpty: Bool { items.isEmpty }
    public var count: Int { items.count }

    public mutating func insert(_ parameter: Parameter) {
        self = Parameters(items + [parameter])
    }

    /// The first parameter with this type, if any.
    public func first(_ type: UInt64) -> Parameter? {
        items.first { $0.type == type }
    }

    public func integer(_ type: UInt64) -> UInt64? { first(type)?.integerValue }
    public func bytes(_ type: UInt64) -> Data? { first(type)?.bytesValue }

    public func string(_ type: UInt64) -> String? {
        bytes(type).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Size of the bare sequence, with no count or length prefix.
    public var encodedLength: Int { encodedLength(in: .quic) }

    /// Size of the bare sequence in a given varint encoding, which is what a
    /// length prefix in front of it has to say.
    public func encodedLength(in encoding: VarIntEncoding) -> Int {
        var previous: UInt64 = 0
        var total = 0
        for item in items {
            total += item.size(after: previous, encoding)
            previous = item.type
        }
        return total
    }

    /// Size including the leading count varint.
    public var encodedLengthCounted: Int {
        WireSize.varInt(UInt64(items.count)) + encodedLength
    }

    /// Append the sequence with no length prefix.
    ///
    /// Every use site in draft-19 already bounds the sequence — SETUP options
    /// run to the end of the message, track properties to the end of the body —
    /// so a prefix here would put an extra field on the wire.
    public func write(to writer: inout WireWriter) {
        var previous: UInt64 = 0
        for item in items {
            item.write(to: &writer, after: previous)
            previous = item.type
        }
    }

    /// Append the sequence prefixed by a parameter count.
    ///
    /// The form used by requests and responses. A byte length would not do:
    /// several messages place track properties immediately after the
    /// parameters, and only a count says where one ends and the other begins.
    public func writeCounted(to writer: inout WireWriter) {
        writer.varInt(UInt64(items.count))
        write(to: &writer)
    }

    /// Read a count-prefixed sequence.
    public static func readCounted(from reader: inout WireReader) throws(WireError) -> Parameters {
        let count = try reader.varInt()
        guard count <= 4096 else {
            // Not a draft limit but a decode-side sanity bound: the count is
            // attacker-controlled and precedes the data it describes, so
            // without this a two-byte message can ask for a huge allocation.
            throw WireError.invalid("implausible parameter count \(count)")
        }
        var items: [Parameter] = []
        items.reserveCapacity(Int(count))
        var previous: UInt64 = 0
        for _ in 0 ..< count {
            let (parameter, type) = try readOne(from: &reader, after: previous)
            items.append(parameter)
            previous = type
        }
        return Parameters(items)
    }

    /// Read until the reader is exhausted, for the sequences that run to the
    /// end of an enclosing length.
    public static func readToEnd(from reader: inout WireReader) throws(WireError) -> Parameters {
        var items: [Parameter] = []
        var previous: UInt64 = 0
        while !reader.isEmpty {
            let (parameter, type) = try readOne(from: &reader, after: previous)
            items.append(parameter)
            previous = type
        }
        return Parameters(items)
    }

    private static func readOne(
        from reader: inout WireReader,
        after previous: UInt64
    ) throws(WireError) -> (Parameter, UInt64) {
        let delta = try reader.varInt()
        let (type, overflow) = previous.addingReportingOverflow(delta)
        guard !overflow, type <= varIntMaximum else {
            throw WireError.invalid("parameter type delta overflowed")
        }

        do {
            if type.isMultiple(of: 2) {
                return (try Parameter.integer(type, try reader.varInt()), type)
            }
            let bytes = try reader.lengthPrefixed()
            return (try Parameter.bytes(type, bytes), type)
        } catch let error as WireError {
            throw error
        } catch let error as ParameterError {
            // The only reachable case is an over-long byte value, since parity
            // is chosen from the type above rather than supplied.
            throw WireError.invalid("parameter \(type): \(error)")
        } catch {
            throw WireError.invalid("parameter \(type)")
        }
    }
}

/// Setup option type codes, per draft-19 §15.4.
///
/// Parity follows the key-value rule, so the value shape of an option is
/// readable from its number.
public enum SetupOption {
    /// URI path, native QUIC only. Client only.
    public static let path: UInt64 = 0x01
    /// One or more session authorization tokens. May repeat.
    public static let authorizationToken: UInt64 = 0x03
    /// Bytes of registered auth tokens the sender will cache. Default 0.
    public static let maximumAuthTokenCacheSize: UInt64 = 0x04
    /// URI authority, native QUIC only. Client only.
    public static let authority: UInt64 = 0x05
    /// Concurrent range filters the peer may use. Default 0.
    public static let maximumFilterRanges: UInt64 = 0x06
    /// Implementation name and version, for debugging.
    public static let implementation: UInt64 = 0x07
    /// Unacknowledged `REQUEST_UPDATE`s allowed per stream. Default 0.
    public static let maximumRequestUpdates: UInt64 = 0x08

    /// A proof that the sender holds the key its token was issued to.
    ///
    /// Not a draft assignment. The private-use number is the one the relay's
    /// registry picks, and the three properties it was chosen for are asserted
    /// at compile time on that side: odd, so it carries bytes rather than a
    /// varint; not a value the greasing sequence produces, since a peer is
    /// entitled to discard those; and above every assignment the draft has made,
    /// so a future one cannot land on it silently.
    ///
    /// Carried at SETUP rather than per-request, which reads as a departure from
    /// RFC 9449 and is not. HTTP is stateless so every request needs its own
    /// evidence; a MOQT session establishes who the peer is once and checks
    /// every later announce against *that*, so a per-request proof would be
    /// proving possession to a relay that had stopped asking, at the price of a
    /// Secure Enclave signature per subscribe.
    public static let authorizationProof: UInt64 = 0x4D51
}

/// Request parameter type codes, per draft-19's own registry for them.
///
/// A separate registry from ``SetupOption`` that happens to agree on the
/// authorization token, and the point of naming it twice rather than reusing
/// the setup constant is that nothing guarantees they keep agreeing. A future
/// draft could move one and not the other, and a shared constant would make
/// that a silent misparse instead of one edit in one place.
public enum RequestParameter {
    /// An authorization token, as a byte string. May repeat.
    ///
    /// Valid on any request and on `REQUEST_UPDATE`, which is what makes a
    /// credential renewable without reconnecting: an update overwrites the
    /// parameter on a request that is already established, so a session can
    /// present a fresh token without disturbing anything it is doing.
    public static let authorizationToken: UInt64 = 0x03

    /// A proof that the sender holds the key the accompanying token names.
    ///
    /// The same private-use number as ``SetupOption/authorizationProof``,
    /// spelled again here for the reason the type note gives. It travels with a
    /// renewal because a proof commits to one token by hash: without it, a
    /// session could present a proven credential at SETUP and then quietly trade
    /// it for an unproven one.
    public static let authorizationProof: UInt64 = 0x4D51
}
