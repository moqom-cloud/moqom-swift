// The bottom of the MOQT codec: variable-length integers and bounded reads.
//
// This target is a port of `rs/moqom-proto`, not a second design. That
// distinction is the whole reason it is allowed to exist. The SDK's `Transport`
// seam was originally drawn at MOQT *operations* precisely so that draft-19
// framing would be written once in Rust and bound into Swift, and the risk
// being avoided was two implementations quietly disagreeing about the draft.
// Nothing about that risk has changed. What changed is that binding to the Rust
// crate requires a C ABI that does not exist yet, so the choice was not
// "port or bind" but "port or have no transport at all".
//
// The mitigation is to keep this a transcription rather than an interpretation:
// every type here corresponds to one in `moqom-proto`, field order is copied
// from its `encode`, and the constants are copied rather than re-derived from
// the draft. Where the Rust makes an invalid state unrepresentable, so does
// this. When the C ABI lands, this target is deletable, and the round-trip
// tests are what will say whether deleting it changed any bytes.

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

/// Appends wire encodings to a buffer.
///
/// A plain `Data` wrapper rather than anything cleverer. Every method here is
/// unconditional — the bounds that could fail are checked at construction of
/// the values being written, so encoding is infallible by the time it reaches
/// this type.
public struct WireWriter: Sendable {
    public private(set) var bytes: Data

    public init(capacity: Int = 0) {
        bytes = Data()
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

    /// Append a variable-length integer in its minimal form.
    ///
    /// - Precondition: `value` is at most ``varIntMaximum``. Callers reach this
    ///   through types that have already checked, so a violation is a bug here
    ///   rather than bad input.
    public mutating func varInt(_ value: UInt64) {
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

    /// Append a varint length followed by that many bytes.
    public mutating func lengthPrefixed(_ data: Data) {
        varInt(UInt64(data.count))
        bytes.append(data)
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
    public static func varInt(_ value: UInt64) -> Int {
        switch value {
        case 0 ... 63: 1
        case 64 ... 16383: 2
        case 16384 ... 1_073_741_823: 4
        default: 8
        }
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

    public init(_ data: Data) {
        self.data = data
        base = data.startIndex
        offset = 0
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
