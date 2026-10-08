// The per-draft byte layer: which varint, which bits, which markers.
//
// The vi64 vectors are draft-22 Table 4 verbatim. Everything else here is a
// place where two drafts disagree about the same bytes, checked from both
// sides, because the failure this guards against is a session that silently
// applies one draft's rule to another draft's peer.

import Foundation
import MoqomCore
import Testing

@testable import MoqomWire

func hexBytes(_ hex: String) -> Data {
    let digits = hex.filter(\.isHexDigit)
    var data = Data()
    var index = digits.startIndex
    while index < digits.endIndex {
        let next = digits.index(index, offsetBy: 2)
        data.append(UInt8(digits[index ..< next], radix: 16)!)
        index = next
    }
    return data
}

@Suite("vi64 varints (draft-22 §8.1)")
struct Vi64Tests {
    @Test("Table 4 vectors decode")
    func tableFour() throws {
        let cases: [(String, UInt64)] = [
            ("25", 37),
            ("8025", 37),
            ("bbbd", 15293),
            ("ed7f3e7d", 226_442_877),
            ("faa1a0e403d8", 2_893_212_287_960),
            ("fc8998abc66bc0", 151_288_809_941_952),
            ("fefa318fa8e3ca11", 70_423_237_261_249_041),
            ("ffffffffffffffffff", .max),
        ]
        for (hex, value) in cases {
            var reader = WireReader(hexBytes(hex), encoding: .vi64)
            #expect(try reader.varInt() == value, "\(hex)")
            #expect(reader.isEmpty)
        }
    }

    /// Table 4's rows are minimal except `0x8025`, so encoding each value must
    /// give back the row's bytes.
    @Test("minimal encodings match Table 4")
    func minimal() {
        let cases: [(UInt64, String)] = [
            (37, "25"),
            (15293, "bbbd"),
            (226_442_877, "ed7f3e7d"),
            (2_893_212_287_960, "faa1a0e403d8"),
            (151_288_809_941_952, "fc8998abc66bc0"),
            (70_423_237_261_249_041, "fefa318fa8e3ca11"),
            (.max, "ffffffffffffffffff"),
        ]
        for (value, hex) in cases {
            var writer = WireWriter(encoding: .vi64)
            writer.varInt(value)
            #expect(writer.bytes == hexBytes(hex), "\(value)")
            #expect(WireSize.varInt(value, .vi64) == writer.count)
        }
    }

    @Test("every length boundary round-trips", arguments: 1 ... 9)
    func boundaries(length: Int) throws {
        let top: UInt64 = length == 9 ? .max : (UInt64(1) << UInt64(7 * length)) - 1
        for value in [top, length == 1 ? 0 : (UInt64(1) << UInt64(7 * (length - 1)))] {
            var writer = WireWriter(encoding: .vi64)
            writer.varInt(value)
            #expect(writer.count == length)
            var reader = WireReader(writer.bytes, encoding: .vi64)
            #expect(try reader.varInt() == value)
        }
    }

    @Test("a short read consumes nothing")
    func short() {
        var reader = WireReader(hexBytes("c0 00"), encoding: .vi64)
        #expect(throws: WireError.short(needed: 1)) { try reader.varInt() }
        #expect(reader.offset == 0)
    }

    /// The same two bytes are 37 in one encoding and something else in the
    /// other, which is the whole reason a reader has to be told.
    @Test("the encodings disagree on the same bytes")
    func disagree() throws {
        var quic = WireReader(hexBytes("4025"), encoding: .quic)
        var vi64 = WireReader(hexBytes("4025"), encoding: .vi64)
        #expect(try quic.varInt() == 37)
        #expect(try vi64.varInt() == 0x40)
    }

    @Test("nested readers keep the encoding")
    func nested() throws {
        var reader = WireReader(hexBytes("02 8025"), encoding: .vi64)
        let length = Int(try reader.varInt())
        var inner = try reader.nested(length)
        #expect(try inner.varInt() == 37)
    }
}

@Suite("MoqtDraft")
struct MoqtDraftTests {
    @Test("ALPN tokens name drafts")
    func alpn() {
        #expect(MoqtDraft(alpn: "moqt-16") == .draft16)
        #expect(MoqtDraft(alpn: "moqt-19") == .draft19)
        #expect(MoqtDraft(alpn: "moqt-22") == .draft22)
        #expect(MoqtDraft(alpn: "moqt-18") == nil)
        #expect(MoqtDraft(alpn: "moqt") == nil)
        #expect(MoqtDraft(alpn: "h3") == nil)
        for draft in MoqtDraft.allCases { #expect(MoqtDraft(alpn: draft.alpn) == draft) }
    }

    @Test("MOQOM offers 22 then 19, and never 16")
    func preference() {
        #expect(MoqtDraft.moqomPreference.map(\.alpn) == ["moqt-22", "moqt-19"])
    }

    @Test("varint encoding per draft")
    func encodings() {
        #expect(MoqtDraft.draft16.varIntEncoding == .quic)
        #expect(MoqtDraft.draft19.varIntEncoding == .quic)
        #expect(MoqtDraft.draft22.varIntEncoding == .vi64)
    }
}

@Suite("Data plane differences between drafts")
struct DraftDataPlaneTests {
    /// 0x50 is a draft-19/22 subgroup with FIRST_OBJECT set. Draft-16's form is
    /// 0b00X1XXXX, so the same byte is an unknown type there.
    @Test("FIRST_OBJECT is not a draft-16 bit")
    func firstObject() throws {
        #expect(try SubgroupType(code: 0x50, draft: .draft19).isFirstObject)
        #expect(try SubgroupType(code: 0x50, draft: .draft22).isFirstObject)
        #expect(throws: WireError.self) { try SubgroupType(code: 0x50, draft: .draft16) }
        #expect(try SubgroupType(code: 0x10, draft: .draft16).mode == .zero)
    }

    @Test("draft-22 Type Flags: unknown and reserved bits are violations")
    func strictFlags() {
        // Bit 4 on a datagram, a bit above 0x40, and STATUS with END_OF_GROUP.
        for code: UInt64 in [0x10, 0x40, 0x80, 0x22] {
            #expect(throws: WireError.self) { try DatagramType(code: code) }
        }
        // Subgroups: bit 4 clear, mode 0b11, and anything 128 or above.
        for code: UInt64 in [0x00, 0x16, 0x80, 0x90] {
            #expect(throws: WireError.self) { try SubgroupType(code: code, draft: .draft22) }
        }
    }

    @Test("a subgroup header in vi64")
    func subgroupVi64() throws {
        let header = SubgroupHeader(trackAlias: 200, group: 70, priority: 128)
        var writer = MoqtDraft.draft22.writer()
        header.write(to: &writer)
        // Type 0x10, alias 200 (two bytes in vi64: 0x80c8), group 70 (one byte,
        // where QUIC would need two), priority 0x80.
        #expect(writer.bytes == hexBytes("10 80c8 46 80"))
        var reader = MoqtDraft.draft22.reader(writer.bytes)
        #expect(try SubgroupHeader.read(from: &reader, draft: .draft22) == header)
    }

    /// Properties carry their own length, which has to be measured in the
    /// encoding being written or the reader lands in the wrong place.
    @Test("properties lengths are measured in the writer's encoding")
    func propertiesLength() throws {
        let properties = Parameters([try Parameter.integer(0x3C, 100)])
        let header = SubgroupHeader(trackAlias: 1, group: 2, propertiesPresent: true)
        var subgroup = SubgroupWriter(header: header)
        var writer = MoqtDraft.draft22.writer()
        try subgroup.write(SubgroupObject(object: 0, properties: properties, content: .payload(Data([7]))), to: &writer)
        // delta 0, properties length 2 (0x3C, 100 are one byte each in vi64),
        // payload length 1, payload.
        #expect(writer.bytes == hexBytes("00 02 3c 64 01 07"))

        var reader = MoqtDraft.draft22.reader(writer.bytes)
        var objects = SubgroupReader(header: header)
        let object = try objects.read(from: &reader)
        #expect(object.properties == properties)
    }

    @Test("End of Timed-Out Range exists only in draft-22")
    func timedOut() throws {
        #expect(throws: WireError.self) { try FetchFlags(code: 0x20C, draft: .draft19) }
        #expect(try FetchFlags(code: 0x20C, draft: .draft22).isEndOfRange)

        var writer19 = FetchWriter(header: FetchHeader(requestID: 1))
        var scratch = WireWriter()
        #expect(throws: FetchError.markerNotInDraft) {
            try writer19.write(.endOfTimedOutRange(Location(group: 1, object: 2)), to: &scratch)
        }

        let header = FetchHeader(requestID: 1)
        var writer = FetchWriter(header: header, draft: .draft22)
        var out = MoqtDraft.draft22.writer()
        try writer.write(.endOfTimedOutRange(Location(group: 5, object: 3)), to: &out)
        // 0x20C is 524, two bytes in vi64 (0x820c); group 5, object 3, length 0.
        #expect(out.bytes == hexBytes("820c 05 03 00"))

        var reader = FetchReader(header: header, draft: .draft22)
        var input = MoqtDraft.draft22.reader(out.bytes)
        #expect(try reader.read(from: &input) == .endOfTimedOutRange(Location(group: 5, object: 3)))
    }

    @Test("stream types per draft")
    func streamTypes() {
        var setup = MoqtDraft.draft22.writer()
        setup.varInt(0x2F00)
        #expect(setup.bytes == hexBytes("af00"))
        #expect(StreamType.peek(setup.bytes, draft: .draft22) == .control)
        #expect(StreamType.peek(hexBytes("05"), draft: .draft22) == .fetch)
        #expect(StreamType.peek(hexBytes("1d"), draft: .draft22) == .subgroup)

        var padding = MoqtDraft.draft22.writer()
        padding.varInt(StreamType.padding)
        #expect(StreamType.peek(padding.bytes, draft: .draft22) == .padding)

        // Draft-19 has no control or padding streams, so the same code is
        // unrecognised there.
        var quicSetup = WireWriter()
        quicSetup.varInt(0x2F00)
        #expect(StreamType.peek(quicSetup.bytes, draft: .draft19) == nil)
        #expect(StreamType.isUnknown(hexBytes("06"), draft: .draft22))
        #expect(!StreamType.isUnknown(hexBytes(""), draft: .draft22))
    }

    @Test("PUBLISH_DONE's uncounted sentinel follows the encoding")
    func publishDoneSentinel() throws {
        let done = PublishDone(status: PublishDoneStatus.trackEnded, reason: "")
        var writer = MoqtDraft.draft22.writer()
        done.write(to: &writer)
        #expect(writer.bytes == hexBytes("02 ffffffffffffffffff 00"))
        var reader = MoqtDraft.draft22.reader(writer.bytes)
        #expect(try PublishDone.read(from: &reader).streamCount == nil)

        // QUIC's 2^62 - 1 is eight 0xFF bytes: the length prefix and then ones.
        var quic = WireWriter()
        done.write(to: &quic)
        #expect(quic.bytes == hexBytes("02 ffffffffffffffff 00"))
    }
}
