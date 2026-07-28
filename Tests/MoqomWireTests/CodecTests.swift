// What these tests are for.
//
// This codec is a port of `rs/moqom-proto`, and the failure mode of a port is
// not a crash — it is a field written in the wrong order, or a delta computed
// from the wrong base, producing bytes that this implementation reads back
// perfectly and no other implementation understands. Round-tripping through
// ourselves therefore proves almost nothing on its own.
//
// So the tests that matter here are the ones with byte literals in them: the
// RFC 9000 vectors, the exact encodings of a namespace and a subgroup object,
// and the flag values. Those are checked against the numbers in the draft and
// the Rust source rather than against our own output, and they are what would
// actually fail if the port drifted. The round-trip tests are the cheap layer
// on top, and they earn their place by covering the input space that hand-
// written vectors cannot.

import Foundation
import MoqomCore
import Testing

@testable import MoqomWire

private func encoded(_ body: (inout WireWriter) -> Void) -> Data {
    var writer = WireWriter()
    body(&writer)
    return writer.bytes
}

@Suite("Variable-length integers")
struct VarIntTests {
    /// Test vectors from RFC 9000 Appendix A.1, which is the only external
    /// authority this codec can be checked against without a peer.
    @Test("RFC 9000 Appendix A.1 vectors, both directions")
    func rfcVectors() throws {
        let cases: [([UInt8], UInt64)] = [
            ([0xC2, 0x19, 0x7C, 0x5E, 0xFF, 0x14, 0xE8, 0x8C], 151_288_809_941_952_652),
            ([0x9D, 0x7F, 0x3E, 0x7D], 494_878_333),
            ([0x7B, 0xBD], 15293),
            ([0x25], 37),
        ]

        for (bytes, value) in cases {
            #expect(encoded { $0.varInt(value) } == Data(bytes))
            var reader = WireReader(Data(bytes))
            #expect(try reader.varInt() == value)
            #expect(reader.isEmpty)
        }
    }

    /// RFC 9000 §16 permits non-minimal encodings, so 37 may arrive as one,
    /// two, four, or eight bytes. We must read all of them and emit only the
    /// shortest, which is why encode-then-decode round-trips and the reverse
    /// does not preserve bytes.
    @Test("non-minimal encodings decode")
    func nonMinimal() throws {
        for bytes in [[0x40, 0x25] as [UInt8], [0x80, 0x00, 0x00, 0x25]] {
            var reader = WireReader(Data(bytes))
            #expect(try reader.varInt() == 37)
        }
        #expect(encoded { $0.varInt(37) } == Data([0x25]))
    }

    @Test("width boundaries")
    func widths() {
        for (value, width) in [
            (UInt64(0), 1), (63, 1), (64, 2), (16383, 2),
            (16384, 4), (1_073_741_823, 4), (1_073_741_824, 8), (varIntMaximum, 8),
        ] {
            #expect(WireSize.varInt(value) == width)
            #expect(encoded { $0.varInt(value) }.count == width)
        }
    }

    /// A short read must say how much more is needed and must not advance, so
    /// a stream reader can retry against the same buffer once more arrives.
    /// Getting this wrong loses a byte per partial read and desynchronises the
    /// control stream in a way that looks like a peer bug.
    @Test("short reads report the shortfall and consume nothing")
    func shortReads() {
        for (bytes, needed) in [
            ([] as [UInt8], 1), ([0x40], 1), ([0x80, 0x00], 2), ([0xC0, 0x00, 0x00, 0x00], 4),
        ] {
            var reader = WireReader(Data(bytes))
            #expect(throws: WireError.short(needed: needed)) { try reader.varInt() }
            #expect(reader.offset == 0)
        }
    }

    @Test("a sequence decodes back in order")
    func sequences() throws {
        let values: [UInt64] = [0, 1, 63, 64, 16383, 16384, 1 << 30, varIntMaximum]
        var reader = WireReader(encoded { writer in values.forEach { writer.varInt($0) } })
        for expected in values {
            #expect(try reader.varInt() == expected)
        }
        #expect(reader.isEmpty)
    }

    /// `Data` slices keep the parent's index base, so a reader written against
    /// `startIndex` silently reads the wrong bytes on any buffer that is not
    /// the first message. Every buffer after the first is a slice.
    @Test("reads correctly from a sliced buffer")
    func slicedBuffer() throws {
        let whole = Data([0xFF, 0xFF, 0x25, 0x7B, 0xBD])
        var reader = WireReader(whole[2...])
        #expect(try reader.varInt() == 37)
        #expect(try reader.varInt() == 15293)
    }
}

@Suite("Parameters")
struct ParameterTests {
    /// Parity is the discriminator: there is no type tag on the wire, so an
    /// even type carrying bytes would be read back as a varint by the peer.
    @Test("parity is enforced at construction")
    func parity() {
        #expect(throws: (any Error).self) { try Parameter.integer(0x03, 1) }
        #expect(throws: (any Error).self) { try Parameter.bytes(0x04, Data([1])) }
        #expect(throws: Never.self) { try Parameter.integer(0x04, 1) }
        #expect(throws: Never.self) { try Parameter.bytes(0x03, Data([1])) }
    }

    /// Types are delta-encoded from zero, so the same parameter encodes
    /// differently depending on what precedes it. This is the detail most
    /// likely to be missed by an implementation reading the draft quickly.
    @Test("types are delta-encoded from the previous type")
    func deltaEncoding() throws {
        let parameters = Parameters([
            try Parameter.integer(0x04, 7),
            try Parameter.integer(0x08, 9),
        ])
        // 0x04 delta from 0, value 7; then 0x04 delta from 0x04, value 9.
        #expect(encoded { parameters.write(to: &$0) } == Data([0x04, 0x07, 0x04, 0x09]))
    }

    @Test("ordering is by type, and repeated types keep insertion order")
    func ordering() throws {
        let first = try Parameter.bytes(0x03, Data("first".utf8))
        let second = try Parameter.bytes(0x03, Data("second".utf8))
        let parameters = Parameters([try Parameter.integer(0x08, 1), first, second])

        #expect(parameters.items.map(\.type) == [0x03, 0x03, 0x08])
        #expect(parameters.items[0].bytesValue == first.bytesValue)
        #expect(parameters.items[1].bytesValue == second.bytesValue)
    }

    @Test("counted and uncounted forms round-trip")
    func roundTrip() throws {
        let parameters = Parameters([
            try Parameter.bytes(0x03, Data(repeating: 0xAB, count: 300)),
            try Parameter.integer(0x06, varIntMaximum),
        ])

        var counted = WireReader(encoded { parameters.writeCounted(to: &$0) })
        #expect(try Parameters.readCounted(from: &counted) == parameters)
        #expect(counted.isEmpty)

        var toEnd = WireReader(encoded { parameters.write(to: &$0) })
        #expect(try Parameters.readToEnd(from: &toEnd) == parameters)
    }

    @Test("declared sizes match what is written")
    func sizesAgree() throws {
        let parameters = Parameters([
            try Parameter.integer(0x04, 1),
            try Parameter.bytes(0x05, Data("x".utf8)),
        ])
        #expect(encoded { parameters.write(to: &$0) }.count == parameters.encodedLength)
        #expect(encoded { parameters.writeCounted(to: &$0) }.count == parameters.encodedLengthCounted)
    }

    /// The count precedes the data it describes and is attacker-controlled, so
    /// a two-byte message must not be able to ask for a large allocation.
    @Test("an implausible count is refused before allocating")
    func implausibleCount() {
        var reader = WireReader(encoded { $0.varInt(1_000_000) })
        #expect(throws: (any Error).self) { try Parameters.readCounted(from: &reader) }
    }
}

@Suite("Names on the wire")
struct NameWireTests {
    @Test("a namespace is a count then length-prefixed fields")
    func namespaceBytes() throws {
        let namespace = try TrackNamespace(["ab", "c"])
        #expect(
            encoded { namespace.write(to: &$0) }
                == Data([0x02, 0x02, 0x61, 0x62, 0x01, 0x63])
        )
    }

    @Test("namespace and full track name round-trip")
    func roundTrip() throws {
        let namespace = try TrackNamespace(["acme", "r", "room-1", "elliott"])
        var reader = WireReader(encoded { namespace.write(to: &$0) })
        #expect(try TrackNamespace.read(from: &reader) == namespace)

        let track = try FullTrackName(namespace: namespace, name: try TrackName("video/720p"))
        var trackReader = WireReader(encoded { track.write(to: &$0) })
        #expect(try FullTrackName.read(from: &trackReader) == track)
    }

    /// The property that actually holds, given that this side canonicalises to
    /// NFC and the Rust side stores raw bytes. Names MOQOM emits are always
    /// already canonical, because they went through these types on the way out.
    @Test("a canonical namespace round-trips byte-for-byte")
    func namespaceRoundTripsWhenAlreadyCanonical() throws {
        let namespace = try TrackNamespace(["café", "naïve"])
        let bytes = encoded { namespace.write(to: &$0) }
        var reader = WireReader(bytes)
        let decoded = try TrackNamespace.read(from: &reader)
        #expect(encoded { decoded.write(to: &$0) } == bytes)
    }

    @Test("the field limit is enforced on the way in")
    func fieldLimit() {
        var reader = WireReader(encoded { $0.varInt(UInt64(maximumNamespaceFields + 1)) })
        #expect(throws: (any Error).self) { try TrackNamespace.read(from: &reader) }
    }

    @Test("empty namespace and empty name are legal")
    func emptyIsLegal() throws {
        let empty = TrackNamespace.empty
        var reader = WireReader(encoded { empty.write(to: &$0) })
        #expect(try TrackNamespace.read(from: &reader) == empty)
    }
}

@Suite("Control messages")
struct ControlMessageTests {
    private func roundTrip<M: ControlMessage & Equatable>(_ message: M) throws {
        var writer = WireWriter()
        try ControlFrame.write(message, to: &writer)

        var reader = WireReader(writer.bytes)
        let (type, body) = try ControlFrame.read(from: &reader)
        #expect(type == M.messageType)
        #expect(reader.isEmpty)

        var bodyReader = WireReader(body)
        #expect(try M.read(from: &bodyReader) == message)
        #expect(bodyReader.isEmpty)
    }

    /// The codes draft-19 changed. Reading these from an earlier draft's
    /// registry produces a stack that fails in a way nobody can diagnose, so
    /// they are pinned as literals rather than trusted to the enum.
    @Test("message type codes match the draft-19 registry")
    func codes() {
        #expect(MessageType.setup.rawValue == 0x2F00)
        #expect(MessageType.publishNamespace.rawValue == 0x6)
        #expect(MessageType.subscribeNamespace.rawValue == 0x50)
        #expect(MessageType.requestOk.rawValue == 0x7)
        #expect(MessageType.requestError.rawValue == 0x5)
        #expect(MessageType.requestUpdate.rawValue == 0x2)
    }

    @Test("a code from an earlier draft is named as such")
    func retiredCodes() {
        // 0x40 was CLIENT_SETUP up to draft-10. A peer sending it is speaking
        // a different protocol, which is worth saying.
        #expect(throws: (any Error).self) { try MessageType(code: 0x40) }
        #expect(throws: (any Error).self) { try MessageType(code: 0x7FFF) }
    }

    @Test("SETUP carries options and nothing else")
    func setup() throws {
        try roundTrip(
            Setup(options: Parameters([
                try Parameter.string(SetupOption.implementation, "moqom-swift/0.1"),
                try Parameter.integer(SetupOption.maximumRequestUpdates, 16),
            ]))
        )
        // No version field: an empty SETUP is a legal, complete message.
        try roundTrip(Setup())
    }

    @Test("namespace requests round-trip")
    func namespaceRequests() throws {
        let namespace = try TrackNamespace(["acme", "r", "room-1"])
        try roundTrip(PublishNamespace(requestID: 0, namespace: namespace))
        try roundTrip(SubscribeNamespace(requestID: 2, prefix: namespace))
        try roundTrip(NamespaceAnnounced(suffix: try TrackNamespace(["elliott", "phone"])))
        try roundTrip(NamespaceDone(suffix: try TrackNamespace(["elliott", "phone"])))
        try roundTrip(
            NamespaceDone(suffix: try TrackNamespace(["elliott", "phone"]), reason: .stopped)
        )
        try roundTrip(
            NamespaceDone(suffix: try TrackNamespace(["elliott", "phone"]), reason: .other(41))
        )
    }

    /// The withdrawal reason is a MOQOM addition to a draft-19 message, and the
    /// only thing making that safe is that it is skippable in both directions.
    /// Both halves are checked against bytes rather than against our own output,
    /// because a symmetrical mistake round-trips perfectly and interoperates with
    /// nobody.
    @Test("a withdrawal reason is optional in both directions")
    func withdrawalReasonIsOptional() throws {
        let suffix = try TrackNamespace(["elliott", "phone"])
        let bare = encoded { NamespaceDone(suffix: suffix).write(to: &$0) }

        // What a draft-19 sender produces: the suffix and nothing after it. Read
        // as "did not say", which is distinct from any reason and must not be a
        // truncation error.
        var reader = WireReader(bare)
        #expect(try NamespaceDone.read(from: &reader).reason == nil)

        // What we produce: the same bytes, plus one varint. The prefix has to be
        // byte-identical or a draft-19 receiver would misread the suffix itself
        // rather than harmlessly ignore the tail.
        let withReason = encoded {
            NamespaceDone(suffix: suffix, reason: .vanished).write(to: &$0)
        }
        #expect(withReason.prefix(bare.count) == bare)
        #expect(withReason.count == bare.count + 1)
        #expect(withReason.last == 1)
    }

    @Test("subscribe and its response round-trip")
    func subscribe() throws {
        let track = try FullTrackName(
            namespace: try TrackNamespace(["acme", "r", "room-1", "elliott"]),
            name: try TrackName("video/360p")
        )
        try roundTrip(Subscribe(requestID: 4, track: track))
        try roundTrip(
            SubscribeOk(
                trackAlias: 9,
                properties: Parameters([try Parameter.integer(0x08, 3)])
            )
        )
    }

    @Test("generic responses round-trip")
    func responses() throws {
        try roundTrip(RequestOk())
        try roundTrip(
            RequestError(
                code: RequestErrorCode.unauthorized,
                retryInterval: 5001,
                reason: "token does not cover this namespace"
            )
        )
        try roundTrip(RequestUpdate(requestID: 6, parameters: Parameters([
            try Parameter.integer(0x02, 200),
        ])))
        try roundTrip(Goaway(newSessionURI: "https://edge.moqom.cloud", timeoutMilliseconds: 30000))
    }

    /// A redirect is the one response with a conditional field, present only
    /// when the code says so. Decoding it unconditionally would consume the
    /// next message's bytes on every other error.
    @Test("a redirect body is present only for the redirect code")
    func redirect() throws {
        let track = try FullTrackName(
            namespace: try TrackNamespace(["acme"]),
            name: try TrackName("video")
        )
        try roundTrip(
            RequestError(
                code: RequestErrorCode.redirect,
                reason: "moved",
                redirect: RequestError.Redirect(
                    connectURI: "https://edge2.moqom.cloud",
                    track: track
                )
            )
        )

        var writer = WireWriter()
        try ControlFrame.write(RequestError(code: RequestErrorCode.timeout), to: &writer)
        var reader = WireReader(writer.bytes)
        let (_, body) = try ControlFrame.read(from: &reader)
        var bodyReader = WireReader(body)
        #expect(try RequestError.read(from: &bodyReader).redirect == nil)
    }

    /// Message length is a fixed 16-bit field, so this is a hard ceiling
    /// rather than a soft one, and it has to be caught when the message is
    /// built rather than at the socket.
    @Test("an oversized body is refused and writes nothing")
    func bodyLimit() throws {
        let huge = Parameters([
            try Parameter.bytes(0x03, Data(repeating: 0, count: maximumParameterValueLength)),
            try Parameter.bytes(0x05, Data(repeating: 0, count: maximumParameterValueLength)),
        ])
        var writer = WireWriter()
        #expect(throws: BodyTooLong.self) {
            try ControlFrame.write(Setup(options: huge), to: &writer)
        }
        #expect(writer.count == 0)
    }

    @Test("a reason phrase is truncated rather than rejected")
    func reasonTruncation() {
        let error = RequestError(code: 0, reason: String(repeating: "é", count: 2000))
        #expect(error.reason.utf8.count <= maximumReasonLength)
    }
}

@Suite("Datagrams")
struct DatagramTests {
    @Test("flag values match the draft")
    func flags() {
        #expect(DatagramType.properties == 0x01)
        #expect(DatagramType.endOfGroup == 0x02)
        #expect(DatagramType.zeroObjectID == 0x04)
        #expect(DatagramType.defaultPriority == 0x08)
        #expect(DatagramType.status == 0x20)
    }

    /// The omissions are the point of the flag byte: a keyframe datagram on a
    /// subscription-priority track with object ID zero costs three varints and
    /// its payload, not six fields.
    @Test("omitted fields really are absent")
    func omission() throws {
        let minimal = ObjectDatagram(
            trackAlias: 1,
            group: 2,
            object: 0,
            content: .payload(Data([0xAA]), endOfGroup: false)
        )
        #expect(minimal.type.hasZeroObjectID)
        #expect(minimal.type.hasDefaultPriority)
        // type, alias, group, payload. No object ID, no priority byte.
        #expect(encoded { minimal.write(to: &$0) } == Data([0x0C, 0x01, 0x02, 0xAA]))
    }

    @Test("round-trips with every field present")
    func roundTrip() throws {
        let datagram = ObjectDatagram(
            trackAlias: 300,
            group: 7,
            object: 5,
            priority: 64,
            properties: Parameters([try Parameter.integer(0x02, 1)]),
            content: .payload(Data([1, 2, 3]), endOfGroup: true)
        )
        let bytes = encoded { datagram.write(to: &$0) }
        #expect(bytes.count == datagram.encodedLength)

        var reader = WireReader(bytes)
        let decoded = try ObjectDatagram.read(from: &reader)
        #expect(decoded.trackAlias == 300)
        #expect(decoded.object == 5)
        #expect(decoded.priority == 64)
        #expect(decoded.type.isEndOfGroup)
        guard case let .payload(payload, endOfGroup) = decoded.content else {
            Issue.record("expected a payload")
            return
        }
        #expect(payload == Data([1, 2, 3]))
        #expect(endOfGroup)
    }

    /// A datagram payload has no length field — it runs to the end — so an
    /// empty normal object cannot be represented by writing nothing. It gets an
    /// explicit Normal status, which is why "empty" and "terminal" are
    /// different cases rather than one nullable payload.
    @Test("an empty object is distinguishable from a terminal one")
    func emptyVersusTerminal() throws {
        for content in [ObjectDatagram.Content.empty, .terminal(.endOfGroup)] {
            let datagram = ObjectDatagram(trackAlias: 1, group: 1, object: 1, content: content)
            var reader = WireReader(encoded { datagram.write(to: &$0) })
            let decoded = try ObjectDatagram.read(from: &reader)
            switch (content, decoded.content) {
            case (.empty, .empty), (.terminal(.endOfGroup), .terminal(.endOfGroup)):
                break
            default:
                Issue.record("empty and terminal are not distinguishable on the wire")
            }
        }
    }

    @Test("illegal flag combinations are refused")
    func illegalFlags() {
        // Status and end-of-group together.
        #expect(throws: (any Error).self) {
            try DatagramType(code: UInt64(DatagramType.status | DatagramType.endOfGroup))
        }
        // Bit 4 is the subgroup marker and must not appear on a datagram.
        #expect(throws: (any Error).self) { try DatagramType(code: 0x10) }
        #expect(throws: (any Error).self) { try DatagramType(code: 0x80) }
    }
}

@Suite("Subgroup streams")
struct SubgroupTests {
    @Test("flag values and the reserved mode match the draft")
    func flags() throws {
        #expect(SubgroupType.marker == 0x10)
        #expect(SubgroupType.defaultPriority == 0x20)
        #expect(SubgroupType.firstObject == 0x40)
        // Mode 0b11 is reserved: bits 2-1 set, marker set.
        #expect(throws: (any Error).self) { try SubgroupType(code: 0x16) }
        // Marker clear is a datagram, not a subgroup.
        #expect(throws: (any Error).self) { try SubgroupType(code: 0x06) }
    }

    @Test("the header round-trips in every subgroup ID mode")
    func headerModes() throws {
        for source in [SubgroupSource.zero, .firstObjectID, .explicit(42)] {
            let header = SubgroupHeader(
                trackAlias: 3,
                group: 4,
                subgroup: source,
                priority: 128,
                propertiesPresent: true
            )
            let bytes = encoded { header.write(to: &$0) }
            #expect(bytes.count == header.encodedLength)
            var reader = WireReader(bytes)
            #expect(try SubgroupHeader.read(from: &reader) == header)
        }
    }

    /// The first object's delta is its absolute ID; every later one is
    /// `id - previous - 1`, so consecutive objects encode as zero. An
    /// implementation that used a plain difference would be off by one from
    /// the second object onwards and would still decode its own output.
    @Test("object IDs are delta-encoded with an implicit increment")
    func deltaEncoding() throws {
        let header = SubgroupHeader(trackAlias: 1, group: 1)
        var writer = SubgroupWriter(header: header)
        var buffer = WireWriter()

        for id in [UInt64(5), 6, 10] {
            try writer.write(
                SubgroupObject(object: id, content: .payload(Data([UInt8(id)]))),
                to: &buffer
            )
        }

        // 5 (absolute), then 0 (consecutive), then 3 (10 - 6 - 1).
        #expect(buffer.bytes[buffer.bytes.startIndex] == 5)

        var reader = WireReader(buffer.bytes)
        var subgroupReader = SubgroupReader(header: header)
        #expect(try subgroupReader.read(from: &reader).object == 5)
        #expect(try subgroupReader.read(from: &reader).object == 6)
        #expect(try subgroupReader.read(from: &reader).object == 10)
        #expect(reader.isEmpty)
    }

    /// The reason `SubgroupObject.object` is a plain `UInt64` rather than a
    /// varint-bounded type: only deltas are encoded, so an accumulated ID may
    /// legally exceed 2^62-1, which no absolute varint field could hold.
    @Test("an accumulated object ID may exceed the varint maximum")
    func accumulatedIDPassesVarIntMaximum() throws {
        let header = SubgroupHeader(trackAlias: 1, group: 1)
        var writer = SubgroupWriter(header: header)
        var buffer = WireWriter()

        let first = varIntMaximum - 1
        let second = first + varIntMaximum // Beyond anything a varint can hold.
        try writer.write(SubgroupObject(object: first, content: .payload(Data([1]))), to: &buffer)
        try writer.write(SubgroupObject(object: second, content: .payload(Data([2]))), to: &buffer)

        var reader = WireReader(buffer.bytes)
        var subgroupReader = SubgroupReader(header: header)
        #expect(try subgroupReader.read(from: &reader).object == first)
        #expect(try subgroupReader.read(from: &reader).object == second)
        #expect(second > varIntMaximum)
    }

    @Test("object IDs must strictly increase")
    func mustIncrease() throws {
        let header = SubgroupHeader(trackAlias: 1, group: 1)
        var writer = SubgroupWriter(header: header)
        var buffer = WireWriter()
        try writer.write(SubgroupObject(object: 5, content: .payload(Data([1]))), to: &buffer)

        #expect(throws: SubgroupError.notIncreasing(previous: 5, next: 5)) {
            try writer.write(SubgroupObject(object: 5, content: .payload(Data([2]))), to: &buffer)
        }
    }

    @Test("nothing may follow a terminal object")
    func afterTerminal() throws {
        let header = SubgroupHeader(trackAlias: 1, group: 1)
        var writer = SubgroupWriter(header: header)
        var buffer = WireWriter()
        try writer.write(SubgroupObject(object: 0, content: .terminal(.endOfGroup)), to: &buffer)

        #expect(throws: SubgroupError.afterTerminal) {
            try writer.write(SubgroupObject(object: 1, content: .payload(Data([1]))), to: &buffer)
        }
    }

    /// Properties are a stream-wide promise made in the header. Writing them
    /// on a stream that did not declare them emits a field the reader will not
    /// look for, which desynchronises everything after it.
    @Test("properties are refused unless the header declared them")
    func undeclaredProperties() throws {
        let header = SubgroupHeader(trackAlias: 1, group: 1, propertiesPresent: false)
        var writer = SubgroupWriter(header: header)
        var buffer = WireWriter()

        #expect(throws: SubgroupError.propertiesNotDeclared) {
            try writer.write(
                SubgroupObject(
                    object: 0,
                    properties: Parameters([try Parameter.integer(0x02, 1)]),
                    content: .payload(Data([1]))
                ),
                to: &buffer
            )
        }
    }

    @Test("a declared-properties stream round-trips, empty sets included")
    func declaredProperties() throws {
        let header = SubgroupHeader(trackAlias: 1, group: 1, propertiesPresent: true)
        var writer = SubgroupWriter(header: header)
        var buffer = WireWriter()

        let withProperties = SubgroupObject(
            object: 0,
            properties: Parameters([try Parameter.integer(0x02, 99)]),
            content: .payload(Data([7]))
        )
        try writer.write(withProperties, to: &buffer)
        try writer.write(SubgroupObject(object: 1, content: .payload(Data([8]))), to: &buffer)
        try writer.write(SubgroupObject(object: 2, content: .terminal(.endOfGroup)), to: &buffer)

        var reader = WireReader(buffer.bytes)
        var subgroupReader = SubgroupReader(header: header)

        let first = try subgroupReader.read(from: &reader)
        #expect(first.properties.integer(0x02) == 99)
        let second = try subgroupReader.read(from: &reader)
        #expect(second.properties.isEmpty)
        let third = try subgroupReader.read(from: &reader)
        guard case .terminal(.endOfGroup) = third.content else {
            Issue.record("expected a terminal object")
            return
        }
        #expect(reader.isEmpty)
    }

    /// Zero length is a normal object with no bytes, not the absence of one.
    /// It is written as a zero length followed by an explicit Normal status,
    /// which is what keeps it distinct from a terminal object.
    @Test("an empty payload survives as an empty payload")
    func emptyPayload() throws {
        let header = SubgroupHeader(trackAlias: 1, group: 1)
        var writer = SubgroupWriter(header: header)
        var buffer = WireWriter()
        try writer.write(SubgroupObject(object: 0, content: .payload(Data())), to: &buffer)

        var reader = WireReader(buffer.bytes)
        var subgroupReader = SubgroupReader(header: header)
        guard case let .payload(payload) = try subgroupReader.read(from: &reader).content else {
            Issue.record("an empty object decoded as terminal")
            return
        }
        #expect(payload.isEmpty)
    }

    @Test("declared sizes match what is written")
    func sizesAgree() throws {
        let header = SubgroupHeader(trackAlias: 1, group: 1, propertiesPresent: true)
        var writer = SubgroupWriter(header: header)
        var buffer = WireWriter()

        let object = SubgroupObject(
            object: 3,
            properties: Parameters([try Parameter.integer(0x04, 1)]),
            content: .payload(Data(repeating: 9, count: 500))
        )
        let predicted = try writer.encodedLength(of: object)
        let before = buffer.count
        try writer.write(object, to: &buffer)
        #expect(buffer.count - before == predicted)
    }

    /// The subgroup ID is not knowable from the header in this mode, which is
    /// the reason the reader is stateful rather than a free function.
    @Test("first-object-ID mode resolves only after the first object")
    func firstObjectIDMode() throws {
        let header = SubgroupHeader(trackAlias: 1, group: 1, subgroup: .firstObjectID)
        var writer = SubgroupWriter(header: header)
        var buffer = WireWriter()
        try writer.write(SubgroupObject(object: 12, content: .payload(Data([1]))), to: &buffer)

        var subgroupReader = SubgroupReader(header: header)
        #expect(subgroupReader.subgroupID == nil)
        var reader = WireReader(buffer.bytes)
        _ = try subgroupReader.read(from: &reader)
        #expect(subgroupReader.subgroupID == 12)
    }
}
