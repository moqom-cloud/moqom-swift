// Variable-length integers and bounded reads: the bottom of every codec here.
//
// Lives in `MoqomCore` rather than in `MoqomWire`, where it started, because it
// has two dependents that must not be tied together. `MoqomWire` is a
// transcription of draft-19 and is explicitly deletable — when the Rust crate
// grows a C ABI, that whole target goes away and the round-trip tests say
// whether deleting it changed any bytes. ``DataRecord`` is the opposite: a
// format MOQOM defines for its own tracks, which nothing upstream will ever
// supply. Leaving the varints in the deletable target would have quietly made
// it undeletable.
//
// What is here is only the byte layer. Anything that encodes a draft-19 concept
// stays in `MoqomWire`.
//
// # Two endiannesses, deliberately
//
// ``WireWriter/uint16(_:)`` is big-endian, because every fixed-width field in
// MOQT is and this half of the file serves that. The record codec in
// ``DataRecord`` is little-endian, for a reason written out there: it exists to
// be read without copying, and a big-endian float array cannot be.

import Foundation

/// Why a decode failed.
///
/// `short` is not an error in the usual sense — a stream reader hits it on
/// every partial read — so it carries how many more bytes would have been
/// enough and leaves the reader unmoved. The distinction between "need more"
/// and "this will never parse" is the one a session loop branches on: the first
/// waits, the second closes the connection.
public enum WireError: Error, Hashable, Sendable {
    /// Not enough bytes. The reader has not advanced.
    case short(needed: Int)

    /// The bytes are well-formed but say something illegal.
    case invalid(String)
}

extension WireError: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .short(needed): "short by \(needed) byte\(needed == 1 ? "" : "s")"
        case let .invalid(why): why
        }
    }

    /// Whether the session must close rather than wait for more bytes.
    public var isFatal: Bool {
        if case .invalid = self { return true }
        return false
    }
}

/// Largest value a QUIC variable-length integer can carry: `2^62 - 1`.
public let varIntMaximum: UInt64 = (1 << 62) - 1

/// Which variable-length integer a session's bytes use.
///
/// Two encodings, and nothing on the wire says which one is in use: the
/// negotiated draft decides, so every reader and writer has to be told. Through
/// draft-16 MOQT used RFC 9000's (a two-bit length prefix, at most `2^62 - 1`).
/// Draft-17 replaced it with one that spends leading one bits on the length (1
/// to 9 bytes, the full 64-bit range, and 0 to 127 in a single byte). The same
/// byte means different numbers in each — `0x40 0x25` is 37 in one and a short
/// read in the other — so a reader told the wrong encoding fails late, on a
/// field that only looks implausible.
///
/// MOQOM's draft-19 profile keeps the QUIC encoding, which the Rust relay also
/// speaks. Draft-22 sessions use ``vi64``.
public enum VarIntEncoding: Hashable, Sendable {
    /// RFC 9000 §16: 1, 2, 4 or 8 bytes, at most `2^62 - 1`.
    case quic
    /// MOQT draft-17 and later (§8.1 of draft-22): the count of leading one
    /// bits in the first byte is the length minus one, up to 9 bytes.
    case vi64

    /// The largest value this encoding can carry, which is also the sentinel
    /// for "not counted" in fields such as PUBLISH_DONE's stream count.
    public var maximum: UInt64 {
        switch self {
        case .quic: varIntMaximum
        case .vi64: .max
        }
    }
}

/// Appends wire encodings to a buffer.
///
/// A plain `Data` wrapper rather than anything cleverer. Every method here is
/// unconditional — the bounds that could fail are checked at construction of
/// the values being written, so encoding is infallible by the time it reaches
/// this type.
public struct WireWriter: Sendable {
    public private(set) var bytes: Data

    /// How ``varInt(_:)`` encodes. Fixed for the writer's life, because a
    /// buffer that mixed the two would be unreadable by either.
    public let encoding: VarIntEncoding

    public init(capacity: Int = 0, encoding: VarIntEncoding = .quic) {
        bytes = Data()
        self.encoding = encoding
        if capacity > 0 { bytes.reserveCapacity(capacity) }
    }

    public var count: Int { bytes.count }

    public mutating func byte(_ value: UInt8) {
        bytes.append(value)
    }

    public mutating func raw(_ data: Data) {
        bytes.append(data)
    }

    /// Big-endian, which is what every fixed-width field in MOQT is.
    public mutating func uint16(_ value: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value))
    }

    /// Append a variable-length integer in its minimal form, in ``encoding``.
    ///
    /// - Precondition: `value` is at most `encoding.maximum`. Callers reach
    ///   this through types that have already checked, so a violation is a bug
    ///   here rather than bad input.
    public mutating func varInt(_ value: UInt64) {
        switch encoding {
        case .quic: quicVarInt(value)
        case .vi64: vi64(value)
        }
    }

    private mutating func quicVarInt(_ value: UInt64) {
        precondition(value <= varIntMaximum, "varint out of range: \(value)")
        switch value {
        case 0 ... 63:
            bytes.append(UInt8(truncatingIfNeeded: value))
        case 64 ... 16383:
            uint16(UInt16(truncatingIfNeeded: value) | (0b01 << 14))
        case 16384 ... 1_073_741_823:
            let v = UInt32(truncatingIfNeeded: value) | (0b10 << 30)
            for shift in stride(from: 24, through: 0, by: -8) {
                bytes.append(UInt8(truncatingIfNeeded: v >> UInt32(shift)))
            }
        default:
            let v = value | (0b11 << 62)
            for shift in stride(from: 56, through: 0, by: -8) {
                bytes.append(UInt8(truncatingIfNeeded: v >> UInt64(shift)))
            }
        }
    }

    /// A length of `n` bytes (1 to 8) carries `7n` bits behind `n - 1` leading
    /// ones and a zero; 9 bytes is `0xFF` and then all 64 bits verbatim.
    private mutating func vi64(_ value: UInt64) {
        let length = WireSize.vi64(value)
        if length == 9 {
            bytes.append(0xFF)
            for shift in stride(from: 56, through: 0, by: -8) {
                bytes.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
            }
            return
        }
        let prefix = UInt8(truncatingIfNeeded: 0xFF00 >> (length - 1))
        for index in 0 ..< length {
            var byte = UInt8(truncatingIfNeeded: value >> UInt64(8 * (length - 1 - index)))
            if index == 0 { byte |= prefix }
            bytes.append(byte)
        }
    }

    /// Append a varint length followed by that many bytes.
    public mutating func lengthPrefixed(_ data: Data) {
        varInt(UInt64(data.count))
        bytes.append(data)
    }

    /// Append a length-prefixed field built by `body`, in this writer's
    /// encoding.
    ///
    /// For fields whose length cannot be computed ahead of writing them without
    /// duplicating the encoder, which under ``VarIntEncoding/vi64`` is every
    /// field containing a varint: its sizes differ from the QUIC ones that the
    /// `encodedLength` properties in this package report.
    public mutating func lengthPrefixed(_ body: (inout WireWriter) -> Void) {
        var inner = WireWriter(encoding: encoding)
        body(&inner)
        lengthPrefixed(inner.bytes)
    }

    /// Append a varint length followed by the UTF-8 of `string`.
    public mutating func lengthPrefixed(_ string: String) {
        lengthPrefixed(Data(string.utf8))
    }
}

/// Encoded sizes, so a message can be measured before it is written.
///
/// Framing needs the body length before the body exists — the envelope's length
/// field is fixed-width and comes first — and the alternative is encoding into
/// a scratch buffer and copying. Every message type therefore reports its own
/// size, and the debug assertion in ``ControlFrame/write(_:to:)`` is what keeps
/// the two in agreement.
public enum WireSize {
    /// The QUIC size, which every `encodedLength` in this package reports.
    public static func varInt(_ value: UInt64) -> Int {
        switch value {
        case 0 ... 63: 1
        case 64 ... 16383: 2
        case 16384 ... 1_073_741_823: 4
        default: 8
        }
    }

    public static func varInt(_ value: UInt64, _ encoding: VarIntEncoding) -> Int {
        switch encoding {
        case .quic: varInt(value)
        case .vi64: vi64(value)
        }
    }

    static func vi64(_ value: UInt64) -> Int {
        for length in 1 ... 8 where value < UInt64(1) << UInt64(7 * length) {
            return length
        }
        return 9
    }

    public static func lengthPrefixed(_ count: Int) -> Int {
        varInt(UInt64(count)) + count
    }

    public static func lengthPrefixed(_ string: String) -> Int {
        lengthPrefixed(string.utf8.count)
    }
}

/// Reads wire encodings from a buffer.
///
/// Indices are offsets from the start of the slice rather than `Data` indices.
/// `Data` slices keep the parent's index base, so a reader written against
/// `startIndex` works on `Data(...)` and silently reads the wrong bytes on
/// `data[10...]` — which is exactly the shape of every buffer a stream reader
/// sees after the first message.
public struct WireReader: Sendable {
    private let data: Data
    private let base: Data.Index

    /// Bytes consumed so far.
    public private(set) var offset: Int

    /// How ``varInt()`` decodes.
    public let encoding: VarIntEncoding

    public init(_ data: Data, encoding: VarIntEncoding = .quic) {
        self.data = data
        self.encoding = encoding
        base = data.startIndex
        offset = 0
    }

    /// A reader over the next `length` bytes, in the same encoding.
    ///
    /// The way to bound a nested structure — properties, a length-prefixed
    /// parameter — without losing the encoding, which a plain
    /// `WireReader(take(n))` would silently reset to QUIC.
    public mutating func nested(_ length: Int) throws(WireError) -> WireReader {
        WireReader(try take(length), encoding: encoding)
    }

    public var count: Int { data.count }
    public var remaining: Int { count - offset }
    public var isEmpty: Bool { remaining == 0 }

    private func at(_ index: Int) -> UInt8 {
        data[base + index]
    }

    /// Everything not yet consumed, as a fresh zero-based `Data`.
    public var rest: Data {
        Data(data[(base + offset)...])
    }

    public mutating func byte() throws(WireError) -> UInt8 {
        guard remaining >= 1 else { throw WireError.short(needed: 1 - remaining) }
        defer { offset += 1 }
        return at(offset)
    }

    public mutating func uint16() throws(WireError) -> UInt16 {
        guard remaining >= 2 else { throw WireError.short(needed: 2 - remaining) }
        defer { offset += 2 }
        return UInt16(at(offset)) << 8 | UInt16(at(offset + 1))
    }

    /// Read one variable-length integer.
    ///
    /// On ``WireError/short(needed:)`` nothing is consumed, so a caller
    /// accumulating from a stream can retry against the same reader once more
    /// bytes arrive. Non-minimal encodings are accepted, as RFC 9000 §16
    /// requires: 37 may legitimately arrive as one, two, four, or eight bytes.
    public mutating func varInt() throws(WireError) -> UInt64 {
        switch encoding {
        case .quic: try quicVarInt()
        case .vi64: try vi64()
        }
    }

    private mutating func quicVarInt() throws(WireError) -> UInt64 {
        guard remaining >= 1 else { throw WireError.short(needed: 1) }
        let first = at(offset)
        let width = 1 << (first >> 6)
        guard remaining >= width else { throw WireError.short(needed: width - remaining) }

        var value = UInt64(first & 0x3F)
        for index in 1 ..< width {
            value = value << 8 | UInt64(at(offset + index))
        }
        offset += width
        return value
    }

    /// Non-minimal forms are accepted here too (§8.1: "any encoding length that
    /// can represent the value is valid"), so `0x8025` is 37.
    private mutating func vi64() throws(WireError) -> UInt64 {
        guard remaining >= 1 else { throw WireError.short(needed: 1) }
        let first = at(offset)
        let ones = (~first).leadingZeroBitCount
        let width = ones == 8 ? 9 : ones + 1
        guard remaining >= width else { throw WireError.short(needed: width - remaining) }

        var value: UInt64 = ones == 8 ? 0 : UInt64(first & (0x7F >> UInt8(ones)))
        for index in 1 ..< width {
            value = value << 8 | UInt64(at(offset + index))
        }
        offset += width
        return value
    }

    public mutating func take(_ length: Int) throws(WireError) -> Data {
        guard length >= 0 else { throw WireError.invalid("negative length") }
        guard remaining >= length else { throw WireError.short(needed: length - remaining) }
        defer { offset += length }
        return Data(data[(base + offset) ..< (base + offset + length)])
    }

    public mutating func lengthPrefixed() throws(WireError) -> Data {
        let length = try varInt()
        guard let length = Int(exactly: length) else {
            throw WireError.invalid("byte string longer than addressable memory")
        }
        return try take(length)
    }

    /// A length-prefixed UTF-8 string.
    ///
    /// Invalid UTF-8 is an error rather than a lossy substitution. The strings
    /// this reads are namespace fields and track names, which are compared
    /// bytewise by the protocol — replacing an unpaired surrogate with U+FFFD
    /// would produce a name that matches nothing and no error to explain why.
    public mutating func lengthPrefixedString() throws(WireError) -> String {
        let bytes = try lengthPrefixed()
        guard let string = String(data: bytes, encoding: .utf8) else {
            throw WireError.invalid("string is not valid UTF-8")
        }
        return string
    }
}
