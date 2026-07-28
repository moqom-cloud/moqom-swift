import Foundation
@testable import MoqomCore
import Testing

@Suite("Record codec")
struct DataRecordTests {
    @Test("Every kind of field survives a round trip")
    func valuesRoundTrip() throws {
        var writer = RecordWriter()
        writer.varInt(1, 300)
        writer.signed(2, -7)
        writer.string(3, "hello")
        writer.bytes(4, Data([0xDE, 0xAD]))
        writer.float(5, 1.5)
        writer.double(6, -2.25)
        writer.fixed64(7, 1_800_000_000_000_000_000)
        writer.flag(8, true)

        var reader = RecordReader(writer.bytes)
        var seen: [UInt32: String] = [:]
        while let key = try reader.nextKey() {
            switch key.tag {
            case 1: seen[1] = String(try reader.varInt())
            case 2: seen[2] = String(try reader.signed())
            case 3: seen[3] = try reader.string()
            case 4: seen[4] = try reader.bytes().map { String($0, radix: 16) }.joined()
            case 5: seen[5] = String(try reader.float())
            case 6: seen[6] = String(try reader.double())
            case 7: seen[7] = String(try reader.fixed64())
            case 8: seen[8] = String(try reader.flag())
            default: try reader.skip(key)
            }
        }

        #expect(seen[1] == "300")
        #expect(seen[2] == "-7")
        #expect(seen[3] == "hello")
        #expect(seen[4] == "dead")
        #expect(seen[5] == "1.5")
        #expect(seen[6] == "-2.25")
        #expect(seen[7] == "1800000000000000000")
        #expect(seen[8] == "true")
    }

    @Test("A false flag costs nothing")
    func falseFlagsAreAbsent() {
        // Absence is the default throughout, and the default for a flag is
        // false. Writing a zero spends a key to say what silence already says.
        var writer = RecordWriter()
        writer.flag(1, false)

        #expect(writer.bytes.isEmpty)
    }

    @Test("An old reader keeps working against a newer publisher")
    func unknownFieldsAreSkipped() throws {
        // The whole versioning story. A publisher that gains a field must not
        // break every client that has not shipped yet.
        var writer = RecordWriter()
        writer.varInt(1, 42)
        writer.string(99, "a field from the future")
        writer.record(98) { inner in inner.varInt(1, 1) }
        writer.float(97, 3.5)
        writer.fixed64(96, 12)
        writer.varInt(2, 43)

        var reader = RecordReader(writer.bytes)
        var first: UInt64?
        var second: UInt64?
        while let key = try reader.nextKey() {
            switch key.tag {
            case 1: first = try reader.varInt()
            case 2: second = try reader.varInt()
            default: try reader.skip(key)
            }
        }

        #expect(first == 42)
        #expect(second == 43, "a later known field was lost behind unknown ones")
    }

    @Test("A field the caller ignored does not derail the next one")
    func unreadFieldsAreStepped() throws {
        // A switch that handles some tags and simply does not mention others is
        // the ordinary shape; it must not require an explicit skip.
        var writer = RecordWriter()
        writer.string(1, "ignored")
        writer.varInt(2, 7)

        var reader = RecordReader(writer.bytes)
        _ = try reader.nextKey()
        guard let second = try reader.nextKey() else {
            Issue.record("the second field vanished")
            return
        }

        #expect(second.tag == 2)
        #expect(try reader.varInt() == 7)
    }

    @Test("Reading a field as the wrong type is refused")
    func wireTypeMismatchIsCaught() throws {
        // Without the check, asking for a string where a varint sits would read
        // a length from whatever bytes happened to follow.
        var writer = RecordWriter()
        writer.varInt(1, 5)

        var reader = RecordReader(writer.bytes)
        _ = try reader.nextKey()

        #expect(throws: WireError.self) { try reader.string() }
    }

    @Test("Small tags cost one byte")
    func hotTagsAreCheap() {
        // Two bits of the key are the wire type, so a one-byte varint leaves
        // four for the tag. Fields that repeat belong below 16, and that is only
        // worth documenting if it is true.
        var low = RecordWriter()
        low.varInt(15, 0)
        var high = RecordWriter()
        high.varInt(16, 0)

        #expect(low.count == 2, "key plus payload")
        #expect(high.count == 3)
    }

    @Test("Negative numbers stay small")
    func zigzagKeepsNegativesShort() {
        // Two's complement would make -1 the longest varint there is.
        var writer = RecordWriter()
        writer.signed(1, -1)

        #expect(writer.count == 2)
    }

    @Test("Signed values round trip across the range")
    func zigzagRoundTrips() throws {
        for value in [-signedMaximum, -70_000, -1, 0, 1, 70_000, signedMaximum] {
            var writer = RecordWriter()
            writer.signed(1, value)
            var reader = RecordReader(writer.bytes)
            _ = try reader.nextKey()

            #expect(try reader.signed() == value, "failed at \(value)")
        }
    }

    @Test("Values wider than a varint go through fixed64 intact")
    func fixedWidthCarriesTheFullRange() throws {
        // The varints here are QUIC's, so they stop at 62 bits. That is the
        // price of having one varint implementation per language instead of two,
        // and this is the escape hatch that makes the price payable.
        for value in [Int64.min, -1, 0, Int64.max] {
            var writer = RecordWriter()
            writer.fixed64(1, value)
            var reader = RecordReader(writer.bytes)
            _ = try reader.nextKey()

            #expect(try reader.fixed64() == value, "failed at \(value)")
        }
    }

    @Test("Fixed-width payloads are little-endian on the wire")
    func fixedWidthIsLittleEndian() {
        // Deliberately the opposite of MOQT's own framing, and the reason the
        // fast path is fast: a little-endian float array is already the layout
        // the processor wants, so it can be pointed at rather than converted.
        var writer = RecordWriter()
        writer.fixed64(1, 1)

        #expect(Array(writer.bytes.dropFirst()) == [1, 0, 0, 0, 0, 0, 0, 0])
    }
}

@Suite("Reading arrays without decoding them")
struct FixedArrayTests {
    /// Three floats per element, which is a position.
    private static let stride = 12

    private func triples(_ values: [(Float, Float, Float)]) -> Data {
        var writer = RecordWriter()
        writer.fixedArray(1, stride: Self.stride, count: values.count) { index, buffer in
            buffer.rawFloat(values[index].0)
            buffer.rawFloat(values[index].1)
            buffer.rawFloat(values[index].2)
        }
        return writer.bytes
    }

    @Test("An array reads back element by element")
    func arrayRoundTrips() throws {
        let written = triples([(1, 2, 3), (-4, 5.5, 6)])

        var reader = RecordReader(written)
        _ = try reader.nextKey()
        let array = try reader.fixedArray(stride: Self.stride)

        #expect(array.count == 2)
        #expect(array.float(0, at: 0) == 1)
        #expect(array.float(1, at: 4) == 5.5)
        #expect(array.float(1, at: 8) == 6)
    }

    @Test("An empty array is written as nothing at all")
    func emptyArraysAreAbsent() {
        // A still board should cost zero bytes, not a key and a zero length,
        // sixty times a second.
        #expect(triples([]).isEmpty)
    }

    @Test("An array whose length is not a whole number of records is refused")
    func raggedArraysAreRefused() throws {
        // Caught at the boundary rather than at the last element, which is what
        // makes indexing safe without re-checking bounds on every access.
        var writer = RecordWriter()
        writer.bytes(1, Data(repeating: 0, count: Self.stride + 3))

        var reader = RecordReader(writer.bytes)
        _ = try reader.nextKey()

        #expect(throws: WireError.self) { try reader.fixedArray(stride: Self.stride) }
    }

    @Test("The whole run is available as raw memory")
    func bulkAccessIsContiguous() throws {
        // The claim the format exists to support: a renderer can walk the run
        // itself, with no per-element call and no allocation.
        let written = triples([(1, 2, 3), (4, 5, 6), (7, 8, 9)])

        var reader = RecordReader(written)
        _ = try reader.nextKey()
        let array = try reader.fixedArray(stride: Self.stride)

        let total = array.withUnsafeBytes { raw -> Float in
            var sum: Float = 0
            for index in 0 ..< (raw.count / 4) {
                sum += Float(bitPattern: UInt32(
                    littleEndian: raw.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)
                ))
            }
            return sum
        }

        #expect(total == 45)
    }

    @Test("An array does not have to start at an aligned address")
    func unalignedArraysAreReadCorrectly() throws {
        // A record can begin at any byte of the enclosing buffer, so nothing may
        // assume four-byte alignment. This is the case that would fail loudly on
        // a strict-alignment target and silently return rubbish elsewhere.
        var writer = RecordWriter()
        writer.string(1, "x") // pushes the array off a four-byte boundary
        writer.fixedArray(2, stride: Self.stride, count: 1) { _, buffer in
            buffer.rawFloat(1.25)
            buffer.rawFloat(2.5)
            buffer.rawFloat(3.75)
        }

        var reader = RecordReader(writer.bytes)
        _ = try reader.nextKey()
        _ = try reader.string()
        _ = try reader.nextKey()
        let array = try reader.fixedArray(stride: Self.stride)

        #expect(array.float(0, at: 0) == 1.25)
        #expect(array.float(0, at: 8) == 3.75)
    }
}

@Suite("Records from a hostile peer")
struct HostileRecordTests {
    // These bytes arrive from another participant. With encryption on they are
    // authenticated as coming from somebody with the room key, which is
    // everybody in the room; with it off they are whatever arrived. Nothing here
    // may read past the end of a buffer, and nothing may take an allocation
    // instruction from the wire.

    @Test("A truncated payload is an error, not a read past the end")
    func truncationIsCaught() throws {
        var writer = RecordWriter()
        writer.string(1, "a reasonably long string")
        let truncated = writer.bytes.dropLast(10)

        var reader = RecordReader(Data(truncated))
        _ = try reader.nextKey()

        #expect(throws: WireError.self) { try reader.string() }
    }

    @Test("A length longer than the buffer is refused rather than allocated")
    func absurdLengthsAreRefused() throws {
        // The classic: a length prefix claiming four gigabytes with three bytes
        // behind it. Reserving from it is a denial of service with no packets.
        var raw = WireWriter()
        raw.varInt(UInt64(1) << 2 | 1) // tag 1, bytes
        raw.varInt(4_000_000_000)
        raw.raw(Data([1, 2, 3]))

        var reader = RecordReader(raw.bytes)
        _ = try reader.nextKey()

        #expect(throws: WireError.self) { try reader.bytes() }
    }

    @Test("A truncated key does not yield a field")
    func truncatedKeysAreCaught() {
        // An eight-byte varint with one byte present.
        var reader = RecordReader(Data([0xC0]))

        #expect(throws: WireError.self) { try reader.nextKey() }
    }

    @Test("A skip cannot be used to walk off the end")
    func skippingIsBounded() throws {
        var raw = WireWriter()
        raw.varInt(UInt64(9) << 2 | 3) // tag 9, fixed64
        raw.raw(Data([1, 2])) // only two of the eight

        var reader = RecordReader(raw.bytes)
        guard let key = try reader.nextKey() else {
            Issue.record("no field")
            return
        }

        #expect(throws: WireError.self) { try reader.skip(key) }
    }

    @Test("Arbitrary bytes never crash the reader")
    func fuzzedInputIsSurvivable() {
        // Not a proof, but it covers the shapes a targeted test would not think
        // of. The property is only that the reader returns or throws — never
        // that it succeeds.
        var generator = SystemRandomNumberGenerator()
        for _ in 0 ..< 2000 {
            let length = Int.random(in: 0 ... 64, using: &generator)
            let bytes = Data((0 ..< length).map { _ in UInt8.random(in: .min ... .max) })

            var reader = RecordReader(bytes)
            // Walk the whole record, reading each field as its declared type,
            // which is the most aggressive thing a real parser would do.
            while let key = try? reader.nextKey() {
                switch key.wireType {
                case .varInt: _ = try? reader.varInt()
                case .bytes: _ = try? reader.bytes()
                case .fixed32: _ = try? reader.float()
                case .fixed64: _ = try? reader.double()
                }
            }
        }
    }

    @Test("A nested record cannot escape its own bytes")
    func nestingIsBounded() throws {
        // A sub-reader is given a slice. Reading past the end of the slice must
        // stop at the slice, not continue into the parent's later fields.
        var writer = RecordWriter()
        writer.record(1) { inner in inner.varInt(1, 7) }
        writer.varInt(2, 99)

        var reader = RecordReader(writer.bytes)
        _ = try reader.nextKey()
        var inner = try reader.record()

        _ = try inner.nextKey()
        #expect(try inner.varInt() == 7)
        #expect(try inner.nextKey() == nil, "the nested reader saw the parent's fields")
    }
}
