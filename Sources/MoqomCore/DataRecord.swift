// The encoding for application data on MOQOM tracks.
//
// The catalog, the room control log, and the shared space track all carry
// structured data that MOQOM defines rather than inherits. This is how those
// bytes are laid out. It is normative: a Rust, Kotlin, or TypeScript client must
// produce and accept exactly this. The prose spec lives at `docs/data-format.md`
// in the main repository and says the same thing in a language-neutral way.
//
// # Why not JSON, and why not FlatBuffers
//
// JSON is where these tracks started and it is fine for two of them. A control
// entry arrives eight times in thirty seconds; a catalog arrives once per
// broadcast. Neither notices a parse. The shared space track is different in
// kind: it carries every moving entity at tick rate to every viewer, so a parse
// per tick lands on the frame budget of the device least able to afford it, and
// it allocates a dictionary and a clutch of strings each time to describe
// numbers that were already numbers.
//
// FlatBuffers is the obvious answer and was the plan of record. What it costs is
// a runtime — about 7,400 lines of Swift, and the equivalent in three more
// languages — in an SDK that today has no third-party dependencies at all, and
// that hand-ported an entire draft-19 codec rather than acquire one. The thing
// FlatBuffers sells over this file is *random access into an unparsed buffer*
// via vtables and offset tables, and none of these tracks need it: they are read
// front to back, once, by the party that asked for them.
//
// So what is below is the part that actually mattered, which is narrower than a
// general serialisation library. Sequential fields with skip-unknown, so the
// format can grow; and one deliberate exception where the hot path lives —
// arrays of fixed-layout records that are never decoded at all, only pointed at.
//
// # The format
//
// A record is a sequence of fields and nothing else. No header, no length, no
// field count: the enclosing frame already knows how many bytes there are, and a
// record ends when they run out.
//
// A field is a **key** followed by a **payload**. The key is a QUIC varint
// holding `tag << 2 | wireType`. The four wire types are all a reader needs in
// order to skip a field it does not recognise, which is what makes the format
// extensible without a schema registry:
//
// | Wire type | Payload |
// |---|---|
// | 0 `varint` | one QUIC varint |
// | 1 `bytes` | a varint length, then that many bytes |
// | 2 `fixed32` | exactly 4 bytes |
// | 3 `fixed64` | exactly 8 bytes |
//
// Strings are `bytes` holding UTF-8. Nested records are `bytes` holding a
// record. Repeated fields are simply the same tag appearing more than once, in
// order. An absent field means "unchanged" or "default" — never "null" — which
// is what keeps a still entity from costing anything.
//
// The varints are QUIC's, which caps them at **62 bits** rather than 64. That is
// inherited deliberately: encoding integers exactly as MOQT does means a client
// needs one varint implementation rather than two that differ in a corner. Sixty
// two bits covers every counter in these tracks with room to spare, and the two
// kinds of value that genuinely span the full width — a nanosecond timestamp and
// a float bit pattern — use `fixed64`, which is exact and shorter anyway. Signed
// varints are zigzagged and so reach 61 bits and a sign.
//
// Because a one-byte varint holds 0…63, and two of those bits are the wire type,
// **tags 1 through 15 encode their key in a single byte**. Put the fields that
// repeat there. Tags above 15 cost two.
//
// # Endianness, and why it differs from MOQT
//
// Fixed-width payloads are **little-endian**, where MOQT's own framing is
// big-endian. That is a deliberate divergence rather than an oversight, and it
// is the entire reason the fast path is fast: an array of little-endian floats
// is already the memory layout every processor MOQOM runs on wants, so a reader
// can point at it. Big-endian would mean a byte swap per float per entity per
// tick, which is precisely the cost being removed.
//
// # Reading is not trusting
//
// Every read here is bounded and every length is checked against what remains.
// The bytes arrive from another participant, by way of a relay that does not
// inspect them, and with end-to-end encryption on they are authenticated only as
// having come from *someone with the room key* — which includes anybody else in
// the room. A malformed record must produce an error, never a read past the end
// of a buffer.

import Foundation

/// How a field's payload is laid out.
///
/// Two bits, carried in the low end of every key. A reader that does not know a
/// tag still knows how many bytes to step over, which is what lets an old client
/// read a new publisher's records instead of refusing them.
public enum DataWireType: UInt8, Sendable, CaseIterable {
    case varInt = 0
    case bytes = 1
    case fixed32 = 2
    case fixed64 = 3
}

/// The largest magnitude a zigzagged signed varint can carry.
///
/// One bit less than ``varIntMaximum``, because zigzag spends the low bit on the
/// sign. Values beyond this belong in a `fixed64` field.
public let signedMaximum: Int64 = (1 << 61) - 1

/// A field's identity: which field, and how to step over it.
public struct DataKey: Hashable, Sendable {
    public let tag: UInt32
    public let wireType: DataWireType

    public init(tag: UInt32, wireType: DataWireType) {
        self.tag = tag
        self.wireType = wireType
    }
}

/// Builds a record.
public struct RecordWriter: Sendable {
    private var writer: WireWriter

    public init(capacity: Int = 0) {
        writer = WireWriter(capacity: capacity)
    }

    public var bytes: Data { writer.bytes }
    public var count: Int { writer.count }

    private mutating func key(_ tag: UInt32, _ type: DataWireType) {
        writer.varInt(UInt64(tag) << 2 | UInt64(type.rawValue))
    }

    /// An unsigned integer, up to ``varIntMaximum`` — that is, 62 bits.
    ///
    /// The ceiling is QUIC's, inherited on purpose: this format encodes its
    /// integers exactly as MOQT does, so a language needs one varint
    /// implementation rather than two subtly different ones. Sixty-two bits is
    /// enough for every counter here by a wide margin — a tick counter at 60Hz
    /// would need two billion years to reach it — and anything that genuinely
    /// spans the full 64, such as a nanosecond timestamp, belongs in
    /// ``fixed64(_:_:)``, which is both exact and shorter.
    ///
    /// - Precondition: `value <= varIntMaximum`. A trap rather than a throw
    ///   because every caller is our own encoder writing a value it produced,
    ///   so exceeding this is a bug in a schema rather than bad input.
    public mutating func varInt(_ tag: UInt32, _ value: UInt64) {
        precondition(
            value <= varIntMaximum,
            "field \(tag): \(value) exceeds the 62-bit varint range; use fixed64"
        )
        key(tag, .varInt)
        writer.varInt(value)
    }

    /// A boolean, as a varint. Writes nothing when `false`.
    ///
    /// Absence is the default everywhere in this format, and the default for a
    /// flag is `false`. Writing `0` would cost a key and a byte to say what
    /// saying nothing already says.
    public mutating func flag(_ tag: UInt32, _ value: Bool) {
        guard value else { return }
        varInt(tag, 1)
    }

    /// A boolean written whether or not it is `true`.
    ///
    /// For the case ``flag(_:_:)`` gets wrong: where the field's presence is
    /// what identifies the value's type, so omitting a `false` would not read as
    /// `false` but as no value at all.
    public mutating func boolean(_ tag: UInt32, _ value: Bool) {
        varInt(tag, value ? 1 : 0)
    }

    /// A signed integer, zigzagged so that small negatives stay small.
    ///
    /// Two's complement would make `-1` the longest varint there is, and these
    /// carry things like a clock offset that is as often below zero as above.
    /// Zigzag spends the low bit on the sign, so the range is
    /// ``signedMaximum`` — 61 bits and a sign, one less than
    /// ``varInt(_:_:)`` gets.
    public mutating func signed(_ tag: UInt32, _ value: Int64) {
        precondition(
            value.magnitude <= UInt64(signedMaximum),
            "field \(tag): \(value) exceeds the 61-bit signed varint range; use fixed64"
        )
        varInt(tag, UInt64(bitPattern: (value << 1) ^ (value >> 63)))
    }

    public mutating func bytes(_ tag: UInt32, _ value: Data) {
        key(tag, .bytes)
        writer.lengthPrefixed(value)
    }

    public mutating func string(_ tag: UInt32, _ value: String) {
        key(tag, .bytes)
        writer.lengthPrefixed(value)
    }

    public mutating func float(_ tag: UInt32, _ value: Float) {
        key(tag, .fixed32)
        writer.raw(withUnsafeBytes(of: value.bitPattern.littleEndian) { Data($0) })
    }

    public mutating func double(_ tag: UInt32, _ value: Double) {
        key(tag, .fixed64)
        writer.raw(withUnsafeBytes(of: value.bitPattern.littleEndian) { Data($0) })
    }

    /// A 64-bit integer at fixed width.
    ///
    /// For values that are genuinely large and genuinely random — a nanosecond
    /// timestamp is both — where a varint would spend nine bytes to encode eight
    /// and gain nothing.
    public mutating func fixed64(_ tag: UInt32, _ value: Int64) {
        key(tag, .fixed64)
        writer.raw(withUnsafeBytes(of: UInt64(bitPattern: value).littleEndian) { Data($0) })
    }

    /// A nested record.
    ///
    /// Encodes the body into its own buffer and copies it, because the length
    /// has to precede it and is not known until it exists. That copy is the
    /// cold path by construction: anything appearing often enough for it to
    /// matter belongs in ``fixedArray(_:stride:count:writing:)`` instead.
    public mutating func record(_ tag: UInt32, _ body: (inout RecordWriter) -> Void) {
        var inner = RecordWriter()
        body(&inner)
        bytes(tag, inner.bytes)
    }

    /// An array of fixed-size records, written straight into the buffer.
    ///
    /// The fast path, and the reason this format exists rather than a JSON
    /// encoder. No per-element key, no per-element length, no padding: `count`
    /// records of exactly `stride` bytes, back to back, which is a shape a
    /// reader can hand to a renderer without decoding it.
    ///
    /// - Parameter writing: called once per element, with the element's index,
    ///   and must append exactly `stride` bytes each time. A debug build checks
    ///   that it did; a release build would produce a record that no reader can
    ///   make sense of, so this is worth the assertion.
    public mutating func fixedArray(
        _ tag: UInt32,
        stride: Int,
        count: Int,
        writing element: (Int, inout RecordWriter) -> Void
    ) {
        guard count > 0 else { return }
        key(tag, .bytes)
        writer.varInt(UInt64(stride * count))
        for index in 0 ..< count {
            let before = writer.count
            element(index, &self)
            assert(
                writer.count - before == stride,
                "element \(index) wrote \(writer.count - before) bytes, not \(stride)"
            )
        }
    }

    /// Append a raw little-endian float, with no key. Only valid inside
    /// ``fixedArray(_:stride:count:writing:)``.
    public mutating func rawFloat(_ value: Float) {
        writer.raw(withUnsafeBytes(of: value.bitPattern.littleEndian) { Data($0) })
    }

    /// Append a raw little-endian 32-bit integer, with no key. Only valid inside
    /// ``fixedArray(_:stride:count:writing:)``.
    public mutating func rawUInt32(_ value: UInt32) {
        writer.raw(withUnsafeBytes(of: value.littleEndian) { Data($0) })
    }
}

/// Reads a record, field by field.
///
/// Sequential rather than random-access: call ``nextKey()`` until it returns
/// `nil`, read the payload of the tags you know, and hand the rest to
/// ``skip(_:)``. A reader that skips what it does not recognise is a reader that
/// keeps working against a newer publisher, which is the whole of this format's
/// versioning story.
public struct RecordReader: Sendable {
    private var reader: WireReader

    /// The field whose payload has not been consumed yet.
    ///
    /// Held so that a read can check it is being asked for the type that is
    /// actually there. Without it, asking for a string where a varint sits would
    /// read a length from whatever bytes followed.
    private var pending: DataKey?

    public init(_ data: Data) {
        reader = WireReader(data)
    }

    public var isEmpty: Bool { reader.isEmpty && pending == nil }

    /// The next field's identity, or `nil` at the end of the record.
    ///
    /// Skips the previous field's payload if the caller did not read it, so a
    /// `switch` that handles four tags out of nine does not have to say so.
    public mutating func nextKey() throws(WireError) -> DataKey? {
        if let pending { try skip(pending) }
        guard !reader.isEmpty else { return nil }

        let raw = try reader.varInt()
        guard let wireType = DataWireType(rawValue: UInt8(raw & 0b11)) else {
            // Unreachable: two bits, four cases. Kept so the type stays total
            // rather than force-unwrapped.
            throw WireError.invalid("impossible wire type")
        }
        let tag = raw >> 2
        guard let tag = UInt32(exactly: tag) else {
            throw WireError.invalid("field tag \(tag) out of range")
        }
        let key = DataKey(tag: tag, wireType: wireType)
        pending = key
        return key
    }

    /// Step over a field without interpreting it.
    public mutating func skip(_ key: DataKey) throws(WireError) {
        pending = nil
        switch key.wireType {
        case .varInt: _ = try reader.varInt()
        case .bytes: _ = try reader.lengthPrefixed()
        case .fixed32: _ = try reader.take(4)
        case .fixed64: _ = try reader.take(8)
        }
    }

    private mutating func expect(_ type: DataWireType) throws(WireError) {
        guard let key = pending else {
            throw WireError.invalid("read a payload with no field open")
        }
        guard key.wireType == type else {
            throw WireError.invalid(
                "field \(key.tag) is \(key.wireType), read as \(type)"
            )
        }
        pending = nil
    }

    public mutating func varInt() throws(WireError) -> UInt64 {
        try expect(.varInt)
        return try reader.varInt()
    }

    public mutating func flag() throws(WireError) -> Bool {
        try varInt() != 0
    }

    public mutating func signed() throws(WireError) -> Int64 {
        let raw = try varInt()
        return Int64(bitPattern: raw >> 1) ^ -Int64(bitPattern: raw & 1)
    }

    public mutating func bytes() throws(WireError) -> Data {
        try expect(.bytes)
        return try reader.lengthPrefixed()
    }

    public mutating func string() throws(WireError) -> String {
        try expect(.bytes)
        return try reader.lengthPrefixedString()
    }

    /// A nested record.
    public mutating func record() throws(WireError) -> RecordReader {
        RecordReader(try bytes())
    }

    public mutating func float() throws(WireError) -> Float {
        try expect(.fixed32)
        let raw = try reader.take(4)
        return Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(as: UInt32.self)))
    }

    public mutating func double() throws(WireError) -> Double {
        try expect(.fixed64)
        let raw = try reader.take(8)
        return Double(bitPattern: UInt64(littleEndian: raw.loadUnaligned(as: UInt64.self)))
    }

    public mutating func fixed64() throws(WireError) -> Int64 {
        try expect(.fixed64)
        let raw = try reader.take(8)
        return Int64(bitPattern: UInt64(littleEndian: raw.loadUnaligned(as: UInt64.self)))
    }

    /// An array of fixed-size records, as a view rather than a decode.
    ///
    /// The payload is handed back whole. Nothing in it is parsed, allocated, or
    /// copied beyond the slice itself, which is the point.
    ///
    /// A payload whose length is not a multiple of `stride` is rejected here
    /// rather than at element `n - 1`. That check is what makes ``FixedArray``
    /// safe to index without bounds arithmetic on every access.
    public mutating func fixedArray(stride: Int) throws(WireError) -> FixedArray {
        precondition(stride > 0, "stride must be positive")
        let payload = try bytes()
        guard payload.count % stride == 0 else {
            throw WireError.invalid(
                "array of \(payload.count) bytes is not a whole number of \(stride)-byte records"
            )
        }
        return FixedArray(bytes: payload, stride: stride)
    }
}

/// A run of fixed-size records inside a record, read in place.
///
/// Holds the bytes and reads fields out of them on demand. Nothing is decoded
/// until something asks, and asking for one element does not touch the others —
/// so a viewer drawing thirty of a hundred entities pays for thirty.
public struct FixedArray: Hashable, Sendable {
    public let bytes: Data
    public let stride: Int

    public var count: Int { bytes.count / stride }
    public var isEmpty: Bool { bytes.isEmpty }

    init(bytes: Data, stride: Int) {
        self.bytes = bytes
        self.stride = stride
    }

    /// One element, as raw memory, for reading several fields out of it at once.
    ///
    /// The accessor to reach for when an element has more than one field.
    /// ``float(_:at:)`` and ``uint32(_:at:)`` each enter `Data`'s
    /// `withUnsafeBytes` on their own, and that is not free — reading an
    /// eight-float record a field at a time costs eight entries into it, which
    /// on a tick of fifty entities is four hundred, and is enough to undo the
    /// saving the layout exists to make. One entry, eight loads.
    ///
    /// The pointer is valid only for the duration of `body`, as ever.
    public func withElement<T>(
        _ index: Int,
        _ body: (UnsafeRawBufferPointer) throws -> T
    ) rethrows -> T {
        precondition(index >= 0 && index < count, "element \(index) of \(count)")
        return try bytes.withUnsafeBytes { raw in
            try body(UnsafeRawBufferPointer(rebasing: raw[(index * stride) ..< ((index + 1) * stride)]))
        }
    }

    /// A little-endian float at a byte offset inside element `index`.
    ///
    /// Unaligned by construction: a record can begin at any byte of the enclosing
    /// buffer, so nothing here may assume four-byte alignment.
    /// `loadUnaligned` is the correct way to say that, and costs nothing on the
    /// architectures this runs on.
    ///
    /// For an element with several fields, prefer ``withElement(_:_:)``.
    public func float(_ index: Int, at offset: Int) -> Float {
        precondition(offset >= 0 && offset + 4 <= stride, "offset \(offset) outside stride")
        return withElement(index) { raw in
            Float(bitPattern: UInt32(
                littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            ))
        }
    }

    /// A little-endian 32-bit integer at a byte offset inside element `index`.
    public func uint32(_ index: Int, at offset: Int) -> UInt32 {
        precondition(offset >= 0 && offset + 4 <= stride, "offset \(offset) outside stride")
        return withElement(index) { raw in
            UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
    }

    /// The whole run, for a consumer that wants to walk it itself.
    public func withUnsafeBytes<T>(_ body: (UnsafeRawBufferPointer) throws -> T) rethrows -> T {
        try bytes.withUnsafeBytes(body)
    }
}

private extension Data {
    /// Read a fixed-width integer from an absolute index, without assuming
    /// alignment.
    func loadUnaligned<T: FixedWidthInteger>(fromIndex index: Index) -> T {
        withUnsafeBytes { raw in
            raw.loadUnaligned(fromByteOffset: index - startIndex, as: T.self)
        }
    }

    /// Read a fixed-width integer from the front, without assuming alignment.
    func loadUnaligned<T: FixedWidthInteger>(as _: T.Type) -> T {
        loadUnaligned(fromIndex: startIndex)
    }
}
