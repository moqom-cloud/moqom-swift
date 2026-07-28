// Fetch, with the bytes written out.
//
// These tests carry more byte literals than the rest of the codec's, for a
// reason worth stating: fetch is not a port. `rs/moqom-proto` has no fetch
// framing yet, so there is no other implementation's output to check against and
// a round-trip through this file would only prove that it agrees with itself.
// The literals below come from the draft's own field diagrams and flag tables,
// which is the only authority available.
//
// Two of them encode a reading of a genuinely ambiguous passage, and are marked
// as such where they appear. If interop ever fails on a fetch, start there.

import Foundation
import MoqomCore
import Testing

@testable import MoqomWire

private func bytes(_ body: (inout WireWriter) -> Void) -> [UInt8] {
    var writer = WireWriter()
    body(&writer)
    return [UInt8](writer.bytes)
}

private func track(_ namespace: [String], _ name: String) throws -> FullTrackName {
    try FullTrackName(namespace: TrackNamespace(namespace), name: TrackName(name))
}

@Suite("Locations and fetch ranges")
struct LocationTests {
    @Test("locations order by group first, then object")
    func ordering() {
        let a = Location(group: 1, object: 9)
        let b = Location(group: 2, object: 0)
        #expect(a < b)
        #expect(Location(group: 2, object: 0) < Location(group: 2, object: 1))
        #expect(!(b < a))
    }

    @Test("an inclusive end encodes as the object plus one")
    func endIsExclusiveOnTheWire() {
        // The trap: §10.12.3 calls the range inclusive and the field is "the end
        // Location, plus 1". Reading only the first sentence loses the last
        // object of every fetch.
        let end = FetchEnd.through(Location(group: 4, object: 7))
        #expect(end.wire == Location(group: 4, object: 8))
        #expect(FetchEnd(wire: Location(group: 4, object: 8)) == end)
    }

    @Test("a zero object means the whole group")
    func wholeGroup() {
        let end = FetchEnd.endOfGroup(9)
        #expect(end.wire == Location(group: 9, object: 0))
        #expect(FetchEnd(wire: Location(group: 9, object: 0)) == .endOfGroup(9))
    }

    @Test("both end forms round-trip through the wire encoding")
    func endRoundTrips() {
        for end in [
            FetchEnd.through(Location(group: 0, object: 0)),
            .through(Location(group: 7, object: 1)),
            .endOfGroup(0),
            .endOfGroup(1_000_000),
        ] {
            #expect(FetchEnd(wire: end.wire) == end)
        }
    }
}

@Suite("FETCH")
struct FetchMessageTests {
    private func roundTrip<M: ControlMessage>(_ message: M) throws {
        var writer = WireWriter()
        try ControlFrame.write(message, to: &writer)
        var reader = WireReader(writer.bytes)
        let frame = try ControlFrame.read(from: &reader)
        #expect(frame.type == M.messageType)
        var body = WireReader(frame.body)
        #expect(try M.read(from: &body) == message)
        #expect(body.isEmpty)
    }

    @Test("a standalone fetch names a track and a range")
    func standalone() throws {
        try roundTrip(
            Fetch(
                requestID: 4,
                kind: .standalone(
                    track: try track(["moqom", "room"], "video"),
                    start: Location(group: 10, object: 0),
                    end: .through(Location(group: 12, object: 5))
                )
            )
        )
    }

    @Test("a joining fetch names no track at all")
    func joining() throws {
        // The publisher takes the namespace, the name, and the end of the range
        // from the subscription being joined, which is the entire reason the
        // variants have different bodies.
        try roundTrip(Fetch(requestID: 6, kind: .relativeJoining(request: 2, groups: 1)))
        try roundTrip(Fetch(requestID: 8, kind: .absoluteJoining(request: 2, group: 40)))
    }

    @Test("the fetch type codes are 1, 2 and 3")
    func typeCodes() throws {
        let standalone = Fetch(
            requestID: 0,
            kind: .standalone(
                track: try track(["a"], "b"),
                start: Location(group: 0, object: 0),
                end: .endOfGroup(0)
            )
        )
        #expect(standalone.kind.code == 0x1)
        #expect(Fetch(requestID: 0, kind: .relativeJoining(request: 0, groups: 0)).kind.code == 0x2)
        #expect(Fetch(requestID: 0, kind: .absoluteJoining(request: 0, group: 0)).kind.code == 0x3)
    }

    @Test("the body is request ID, fetch type, then the type's own fields")
    func fieldOrder() throws {
        let message = Fetch(requestID: 6, kind: .relativeJoining(request: 2, groups: 3))
        #expect(bytes { message.write(to: &$0) } == [
            0x06, // request ID
            0x02, // fetch type: relative joining
            0x02, // joining request ID
            0x03, // joining start
            0x00, // parameter count
        ])
    }

    @Test("parameters come last, after the type-specific fields")
    func parametersAreLast() throws {
        let priority = try Parameter.integer(0x20, 40)
        let message = Fetch(
            requestID: 0,
            kind: .absoluteJoining(request: 2, group: 7),
            parameters: Parameters([priority])
        )
        let encoded = bytes { message.write(to: &$0) }
        #expect(encoded.prefix(4) == [0x00, 0x03, 0x02, 0x07])
        #expect(encoded[4] == 0x01)
        try roundTrip(message)
    }

    @Test("an unregistered fetch type is refused")
    func unknownType() throws {
        var writer = WireWriter()
        writer.varInt(0)
        writer.varInt(0x4)
        writer.varInt(0)
        var reader = WireReader(writer.bytes)
        #expect(throws: WireError.self) { try Fetch.read(from: &reader) }
    }

    @Test("an end before its start is refused")
    func backwardsRange() throws {
        let name = try track(["a"], "b")
        var writer = WireWriter()
        writer.varInt(0)
        writer.varInt(0x1)
        name.write(to: &writer)
        Location(group: 9, object: 0).write(to: &writer)
        Location(group: 4, object: 1).write(to: &writer)
        writer.varInt(0)

        var reader = WireReader(writer.bytes)
        #expect(throws: WireError.self) { try Fetch.read(from: &reader) }
    }
}

@Suite("FETCH_OK")
struct FetchOkTests {
    @Test("end of track is a fixed byte, not a varint")
    func endOfTrackIsAByte() {
        let message = FetchOk(endOfTrack: true, end: .through(Location(group: 2, object: 3)))
        #expect(bytes { message.write(to: &$0) } == [
            0x01, // end of track
            0x02, // end group
            0x04, // end object: the last object plus one
            0x00, // parameter count
        ])
    }

    @Test("it round-trips with parameters and track properties")
    func roundTrip() throws {
        let message = FetchOk(
            endOfTrack: false,
            end: .endOfGroup(11),
            properties: Parameters([try Parameter.integer(0x4000, 7)])
        )
        var writer = WireWriter()
        try ControlFrame.write(message, to: &writer)
        var reader = WireReader(writer.bytes)
        let frame = try ControlFrame.read(from: &reader)
        var body = WireReader(frame.body)
        #expect(try FetchOk.read(from: &body) == message)
    }

    @Test("track properties run to the end of the body, so the frame bounds them")
    func propertiesRunToTheEnd() throws {
        // Track Properties carry no length of their own — §2.5 makes the
        // envelope's 16-bit length the only thing that ends them. Parsing a
        // FETCH_OK outside its frame would read into whatever followed.
        let message = FetchOk(
            end: .endOfGroup(1),
            properties: Parameters([try Parameter.integer(0x4000, 1)])
        )
        var writer = WireWriter()
        try ControlFrame.write(message, to: &writer)
        writer.raw(Data([0xFF, 0xFF]))

        var reader = WireReader(writer.bytes)
        let frame = try ControlFrame.read(from: &reader)
        var body = WireReader(frame.body)
        #expect(try FetchOk.read(from: &body) == message)
        #expect(reader.rest == Data([0xFF, 0xFF]))
    }
}

@Suite("Fetch stream framing")
struct FetchStreamTests {
    @Test("the stream type is 0x05 and carries only a request ID")
    func header() throws {
        let header = FetchHeader(requestID: 9)
        #expect(bytes { header.write(to: &$0) } == [0x05, 0x09])

        var reader = WireReader(Data([0x05, 0x09]))
        #expect(try FetchHeader.read(from: &reader) == header)
    }

    @Test("a subgroup stream is not mistaken for a fetch stream")
    func peek() {
        #expect(StreamType.peek(Data([0x05, 0x09])) == .fetch)
        // 0x11 has the subgroup marker bit set.
        #expect(StreamType.peek(Data([0x11, 0x00, 0x00])) == .subgroup)
        #expect(StreamType.peek(Data([0x02])) == nil)
        #expect(StreamType.peek(Data()) == nil)
    }

    @Test("the flag bit values match draft-19 Table 9")
    func flagValues() {
        #expect(FetchFlags.subgroupMask == 0x03)
        #expect(FetchFlags.objectDelta == 0x04)
        #expect(FetchFlags.groupDelta == 0x08)
        #expect(FetchFlags.priority == 0x10)
        #expect(FetchFlags.properties == 0x20)
        #expect(FetchFlags.datagram == 0x40)
        #expect(FetchFlags.endOfNonExistentRange == 0x8C)
        #expect(FetchFlags.endOfUnknownRange == 0x10C)
    }

    @Test("a flags value that is neither flags nor a marker is refused")
    func reservedFlags() {
        #expect(throws: WireError.self) { try FetchFlags(code: 0x80) }
        #expect(throws: WireError.self) { try FetchFlags(code: 0x100) }
        #expect(throws: Never.self) { try FetchFlags(code: 0x7F) }
    }

    @Test("the datagram bit means the subgroup bits are ignored, not rejected")
    func datagramBitIgnoresSubgroup() throws {
        let flags = try FetchFlags(code: FetchFlags.datagram | 0x03)
        #expect(flags.isDatagram)
        #expect(flags.subgroup == .zero)
    }

    @Test("the first record's group and object are absolute")
    func firstRecordIsAbsolute() throws {
        var writer = FetchWriter(header: FetchHeader(requestID: 1))
        var out = WireWriter()
        try writer.write(
            .object(
                FetchObject(
                    location: Location(group: 7, object: 3),
                    priority: 128,
                    payload: Data([0xAA])
                )
            ),
            to: &out
        )
        #expect([UInt8](out.bytes) == [
            0x1C, // flags: group delta, object delta, priority present, subgroup zero
            0x07, // group, absolute
            0x03, // object, absolute
            0x80, // priority
            0x01, // payload length
            0xAA,
        ])
    }

    @Test("a first record that refers to a prior object is refused")
    func firstRecordCannotInherit() throws {
        var reader = FetchReader(header: FetchHeader(requestID: 1))
        // Subgroup mode 0x01 is "the prior object's subgroup", and there is no
        // prior object.
        var wire = WireReader(Data([0x1D, 0x00, 0x00, 0x80, 0x00]))
        #expect(throws: WireError.self) { try reader.read(from: &wire) }

        var second = FetchReader(header: FetchHeader(requestID: 1))
        // No priority bit, so the priority would come from a prior object.
        var withoutPriority = WireReader(Data([0x0C, 0x00, 0x00, 0x00]))
        #expect(throws: WireError.self) { try second.read(from: &withoutPriority) }
    }

    @Test("a consecutive object in the same group costs one byte of framing")
    func consecutiveObject() throws {
        var writer = FetchWriter(header: FetchHeader(requestID: 1))
        var out = WireWriter()
        try writer.write(
            .object(FetchObject(location: Location(group: 0, object: 0), payload: Data([0x01]))),
            to: &out
        )
        let first = out.count

        try writer.write(
            .object(FetchObject(location: Location(group: 0, object: 1), payload: Data([0x02]))),
            to: &out
        )
        // Flags, payload length, payload. Group, object, and priority are all
        // inherited, which is the entire point of the delta encoding.
        #expect(out.count - first == 3)
        #expect([UInt8](out.bytes.suffix(3)) == [0x00, 0x01, 0x02])
    }

    @Test("crossing a group boundary sends an absolute object ID")
    func groupBoundarySendsAbsoluteObject() throws {
        // The trap in §11.4.4.1: with the group delta present and the object
        // delta absent, the Object ID is the prior object's plus one
        // "regardless of which group it belongs to". So a publisher that
        // advanced the group and elided the object ID would number the first
        // object of a new group after the last object of the old one.
        var writer = FetchWriter(header: FetchHeader(requestID: 1))
        var out = WireWriter()
        for location in [Location(group: 0, object: 0), Location(group: 0, object: 1)] {
            try writer.write(.object(FetchObject(location: location)), to: &out)
        }
        let before = out.count
        try writer.write(
            .object(FetchObject(location: Location(group: 1, object: 0))),
            to: &out
        )

        #expect([UInt8](out.bytes.suffix(out.count - before)) == [
            0x0C, // flags: group delta and object delta present, subgroup zero
            0x00, // group delta: zero means the next group
            0x00, // object: absolute in the new group
            0x00, // payload length
        ])

        var reader = FetchReader(header: FetchHeader(requestID: 1))
        var wire = WireReader(out.bytes)
        var seen: [Location] = []
        for _ in 0 ..< 3 {
            guard case let .object(object) = try reader.read(from: &wire) else { continue }
            seen.append(object.location)
        }
        #expect(seen == [
            Location(group: 0, object: 0),
            Location(group: 0, object: 1),
            Location(group: 1, object: 0),
        ])
    }

    @Test("a group delta of zero means the next group, not the same one")
    func groupDeltaHasAnImplicitPlusOne() throws {
        var writer = FetchWriter(header: FetchHeader(requestID: 1))
        var out = WireWriter()
        try writer.write(
            .object(FetchObject(location: Location(group: 5, object: 0))),
            to: &out
        )
        try writer.write(
            .object(FetchObject(location: Location(group: 9, object: 0))),
            to: &out
        )
        // 9 - 5 - 1 = 3.
        #expect([UInt8](out.bytes.suffix(4)) == [0x0C, 0x03, 0x00, 0x00])
    }

    @Test("a descending fetch subtracts the group delta")
    func descendingOrder() throws {
        var writer = FetchWriter(header: FetchHeader(requestID: 1), order: .descending)
        var out = WireWriter()
        for group in [UInt64(9), 8, 5] {
            try writer.write(
                .object(FetchObject(location: Location(group: group, object: 0))),
                to: &out
            )
        }

        var reader = FetchReader(header: FetchHeader(requestID: 1), order: .descending)
        var wire = WireReader(out.bytes)
        var groups: [UInt64] = []
        for _ in 0 ..< 3 {
            guard case let .object(object) = try reader.read(from: &wire) else { continue }
            groups.append(object.location.group)
        }
        #expect(groups == [9, 8, 5])
    }

    @Test("reading a descending stream as ascending produces different groups")
    func orderIsNotJustAPreference() throws {
        // Group order changes the sign of the delta, so a reader with the wrong
        // one does not reorder the groups — it invents different ones. Worth
        // pinning, because a fetch whose GROUP_ORDER parameter was dropped
        // decodes without error.
        var writer = FetchWriter(header: FetchHeader(requestID: 1), order: .descending)
        var out = WireWriter()
        for group in [UInt64(9), 8] {
            try writer.write(
                .object(FetchObject(location: Location(group: group, object: 0))),
                to: &out
            )
        }

        var reader = FetchReader(header: FetchHeader(requestID: 1), order: .ascending)
        var wire = WireReader(out.bytes)
        _ = try reader.read(from: &wire)
        guard case let .object(second) = try reader.read(from: &wire) else {
            Issue.record("expected an object")
            return
        }
        #expect(second.location.group == 10)
    }

    @Test("a subgroup that repeats or steps by one is not sent")
    func subgroupModes() throws {
        var writer = FetchWriter(header: FetchHeader(requestID: 1))
        var out = WireWriter()
        let subgroups: [UInt64] = [4, 4, 5, 9, 0]
        for (index, subgroup) in subgroups.enumerated() {
            try writer.write(
                .object(
                    FetchObject(
                        location: Location(group: 0, object: UInt64(index)),
                        subgroup: subgroup
                    )
                ),
                to: &out
            )
        }

        var reader = FetchReader(header: FetchHeader(requestID: 1))
        var wire = WireReader(out.bytes)
        var seen: [UInt64] = []
        for _ in subgroups {
            guard case let .object(object) = try reader.read(from: &wire) else { continue }
            seen.append(object.subgroup)
        }
        #expect(seen == subgroups)
    }

    @Test("priority carries over until it changes, including across groups")
    func priorityCarriesOver() throws {
        var writer = FetchWriter(header: FetchHeader(requestID: 1))
        var out = WireWriter()
        let priorities: [UInt8] = [10, 10, 200, 200]
        for (index, priority) in priorities.enumerated() {
            try writer.write(
                .object(
                    FetchObject(
                        location: Location(group: UInt64(index), object: 0),
                        priority: priority
                    )
                ),
                to: &out
            )
        }

        var reader = FetchReader(header: FetchHeader(requestID: 1))
        var wire = WireReader(out.bytes)
        var seen: [UInt8] = []
        for _ in priorities {
            guard case let .object(object) = try reader.read(from: &wire) else { continue }
            seen.append(object.priority)
        }
        #expect(seen == priorities)
    }

    @Test("properties are never inherited")
    func propertiesAreNotInherited() throws {
        var writer = FetchWriter(header: FetchHeader(requestID: 1))
        var out = WireWriter()
        try writer.write(
            .object(
                FetchObject(
                    location: Location(group: 0, object: 0),
                    properties: Parameters([try Parameter.integer(0x78, 1000)])
                )
            ),
            to: &out
        )
        try writer.write(
            .object(FetchObject(location: Location(group: 0, object: 1))),
            to: &out
        )

        var reader = FetchReader(header: FetchHeader(requestID: 1))
        var wire = WireReader(out.bytes)
        guard case let .object(first) = try reader.read(from: &wire),
              case let .object(second) = try reader.read(from: &wire)
        else {
            Issue.record("expected two objects")
            return
        }
        #expect(first.properties.integer(0x78) == 1000)
        #expect(second.properties.isEmpty)
    }

    @Test("there is no object status, so an empty payload is just empty")
    func noObjectStatus() throws {
        var writer = FetchWriter(header: FetchHeader(requestID: 1))
        var out = WireWriter()
        try writer.write(
            .object(FetchObject(location: Location(group: 0, object: 0))),
            to: &out
        )
        // Flags, group, object, priority, and a zero length — and nothing after
        // it. A subgroup stream would follow the zero with an explicit Normal
        // status; §11.2.1.1 removes the field entirely on a fetch.
        #expect([UInt8](out.bytes) == [0x1C, 0x00, 0x00, 0x80, 0x00])

        var reader = FetchReader(header: FetchHeader(requestID: 1))
        var wire = WireReader(out.bytes)
        guard case let .object(object) = try reader.read(from: &wire) else {
            Issue.record("expected an object")
            return
        }
        #expect(object.payload.isEmpty)
        #expect(wire.isEmpty)
    }

    @Test("the encoded length agrees with what is written")
    func lengthAgrees() throws {
        var writer = FetchWriter(header: FetchHeader(requestID: 1))
        var out = WireWriter()
        let records: [FetchRecord] = [
            .object(FetchObject(location: Location(group: 1, object: 0), payload: Data([1, 2, 3]))),
            .object(FetchObject(location: Location(group: 1, object: 1), subgroup: 2)),
            .endOfNonExistentRange(Location(group: 1, object: 9)),
            .object(FetchObject(location: Location(group: 4, object: 0), priority: 3)),
        ]
        for record in records {
            let predicted = try writer.encodedLength(of: record)
            let before = out.count
            try writer.write(record, to: &out)
            #expect(out.count - before == predicted)
        }
    }
}

@Suite("End of range markers")
struct EndOfRangeTests {
    @Test("a marker's location is absolute, not delta-encoded")
    func markersAreAbsolute() throws {
        // This is a reading of an ambiguous passage, not a quote from one.
        // §11.4.4.2 calls these "the Group ID and Object ID fields" while Figure
        // 27 names the same fields as deltas. Absolute is the reading that can
        // express "objects 5 through 9 of *this* group do not exist", which the
        // delta reading cannot: the marker's flags are a fixed constant with the
        // group delta bit set, and a delta of zero means the *next* group.
        var writer = FetchWriter(header: FetchHeader(requestID: 1))
        var out = WireWriter()
        try writer.write(
            .object(FetchObject(location: Location(group: 3, object: 4))),
            to: &out
        )
        let before = out.count
        try writer.write(.endOfNonExistentRange(Location(group: 3, object: 9)), to: &out)

        #expect([UInt8](out.bytes.suffix(out.count - before)) == [
            0x40, 0x8C, // end of non-existent range, as a two-byte varint
            0x03, // group, absolute — same group as the object before it
            0x09, // object, absolute
            0x00, // payload length
        ])
    }

    @Test("the marker values are varints, so neither fits in one byte")
    func markersAreVarints() throws {
        // 0x8C and 0x10C are *values* of a varint field, not bytes of one. Both
        // are above 63, so both need a two-byte varint, and an implementation
        // that wrote the constant as a byte would emit 0x8C — which parses as
        // the two-byte varint 0x0C00 and is neither marker.
        var writer = FetchWriter(header: FetchHeader(requestID: 1))
        var out = WireWriter()
        try writer.write(.endOfUnknownRange(Location(group: 0, object: 1)), to: &out)
        #expect([UInt8](out.bytes.prefix(2)) == [0x41, 0x0C])

        var reader = WireReader(Data([0x41, 0x0C]))
        #expect(try reader.varInt() == FetchFlags.endOfUnknownRange)
    }

    @Test("both markers round-trip and stay distinguishable")
    func bothMarkers() throws {
        var writer = FetchWriter(header: FetchHeader(requestID: 1))
        var out = WireWriter()
        let records: [FetchRecord] = [
            .object(FetchObject(location: Location(group: 0, object: 0))),
            .endOfNonExistentRange(Location(group: 0, object: 4)),
            .endOfUnknownRange(Location(group: 0, object: 8)),
        ]
        for record in records { try writer.write(record, to: &out) }

        var reader = FetchReader(header: FetchHeader(requestID: 1))
        var wire = WireReader(out.bytes)
        var seen: [FetchRecord] = []
        for _ in records { seen.append(try reader.read(from: &wire)) }
        #expect(seen == records)
    }

    @Test("the object after a marker keeps the prior object's subgroup and priority")
    func markerDoesNotResetSubgroupOrPriority() throws {
        // §11.4.4.2: after an End of Range the prior group and object come from
        // the marker, but the prior subgroup and priority come from the last
        // real object — the marker has neither.
        var writer = FetchWriter(header: FetchHeader(requestID: 1))
        var out = WireWriter()
        try writer.write(
            .object(
                FetchObject(location: Location(group: 0, object: 0), subgroup: 6, priority: 20)
            ),
            to: &out
        )
        try writer.write(.endOfUnknownRange(Location(group: 0, object: 5)), to: &out)
        try writer.write(
            .object(
                FetchObject(location: Location(group: 0, object: 6), subgroup: 6, priority: 20)
            ),
            to: &out
        )

        var reader = FetchReader(header: FetchHeader(requestID: 1))
        var wire = WireReader(out.bytes)
        _ = try reader.read(from: &wire)
        _ = try reader.read(from: &wire)
        guard case let .object(after) = try reader.read(from: &wire) else {
            Issue.record("expected an object after the marker")
            return
        }
        #expect(after.subgroup == 6)
        #expect(after.priority == 20)
        #expect(after.location == Location(group: 0, object: 6))
    }

    @Test("a marker may be the first record on a stream")
    func markerFirst() throws {
        // A fetch whose whole requested range is missing still gets a stream,
        // and this is how the publisher says so without sending an object.
        var writer = FetchWriter(header: FetchHeader(requestID: 1))
        var out = WireWriter()
        try writer.write(.endOfNonExistentRange(Location(group: 12, object: 40)), to: &out)

        var reader = FetchReader(header: FetchHeader(requestID: 1))
        var wire = WireReader(out.bytes)
        #expect(try reader.read(from: &wire) == .endOfNonExistentRange(
            Location(group: 12, object: 40)
        ))
    }

    @Test("a marker carrying a payload is refused")
    func markerWithPayload() throws {
        var reader = FetchReader(header: FetchHeader(requestID: 1))
        var wire = WireReader(Data([0x40, 0x8C, 0x00, 0x00, 0x01, 0xFF]))
        #expect(throws: WireError.self) { try reader.read(from: &wire) }
    }
}

@Suite("Fetch stream violations")
struct FetchViolationTests {
    @Test("objects must advance along the stream")
    func mustAdvance() throws {
        var writer = FetchWriter(header: FetchHeader(requestID: 1))
        var out = WireWriter()
        try writer.write(
            .object(FetchObject(location: Location(group: 5, object: 5))),
            to: &out
        )
        #expect(throws: FetchError.self) {
            try writer.write(
                .object(FetchObject(location: Location(group: 5, object: 4))),
                to: &out
            )
        }
        #expect(throws: FetchError.self) {
            try writer.write(
                .object(FetchObject(location: Location(group: 4, object: 0))),
                to: &out
            )
        }
    }

    @Test("a descending stream must go down, not up")
    func descendingMustDescend() throws {
        var writer = FetchWriter(header: FetchHeader(requestID: 1), order: .descending)
        var out = WireWriter()
        try writer.write(
            .object(FetchObject(location: Location(group: 5, object: 0))),
            to: &out
        )
        #expect(throws: FetchError.self) {
            try writer.write(
                .object(FetchObject(location: Location(group: 6, object: 0))),
                to: &out
            )
        }
    }

    @Test("a group delta that would pass 2^64-1 is refused rather than wrapped")
    func groupOverflow() throws {
        // Takes several records to get there: the first group is varint-bounded
        // at 2^62-1 and so is every delta, while the accumulated group is a full
        // 64-bit value. Four maximal steps overshoot, and the point is that the
        // reader says so rather than wrapping into a small group number.
        var out = WireWriter()
        out.varInt(0x1C)
        out.varInt(varIntMaximum)
        out.varInt(0)
        out.byte(128)
        out.varInt(0)
        for _ in 0 ..< 4 {
            out.varInt(0x0C)
            out.varInt(varIntMaximum)
            out.varInt(0)
            out.varInt(0)
        }

        var reader = FetchReader(header: FetchHeader(requestID: 1))
        var wire = WireReader(out.bytes)
        var groups: [UInt64] = []
        #expect(throws: WireError.self) {
            for _ in 0 ..< 5 {
                guard case let .object(object) = try reader.read(from: &wire) else { continue }
                groups.append(object.location.group)
            }
        }
        #expect(groups.allSatisfy { $0 >= varIntMaximum })
    }

    @Test("a descending group delta that would pass below zero is refused")
    func descendingUnderflow() throws {
        var reader = FetchReader(header: FetchHeader(requestID: 1), order: .descending)
        var out = WireWriter()
        out.varInt(0x1C)
        out.varInt(2)
        out.varInt(0)
        out.byte(128)
        out.varInt(0)
        out.varInt(0x0C)
        out.varInt(5)
        out.varInt(0)
        out.varInt(0)

        var wire = WireReader(out.bytes)
        _ = try reader.read(from: &wire)
        #expect(throws: WireError.self) { try reader.read(from: &wire) }
    }
}
