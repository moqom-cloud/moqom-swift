// Draft-16 control messages against hand-worked bytes.
//
// The CLIENT_SETUP vector is moq-rs's own (`setup/client.rs`,
// `encode_decode_params_only`), which is what Cloudflare's relay runs; the
// rest are worked from draft-16 §9's figures.

import Foundation
import MoqomCore
import Testing

@testable import MoqomWire

private let draft = MoqtDraft.draft16

private func framed(_ message: some DraftControlMessage) -> Data {
    var writer = draft.writer()
    try! ControlFrame.write(message, to: &writer)
    return writer.bytes
}

private func decode<M: DraftControlMessage>(_ type: M.Type, _ hex: String) throws -> M {
    var reader = draft.reader(hexBytes(hex))
    let frame = try ControlFrame.readRaw(from: &reader)
    #expect(reader.isEmpty)
    #expect(frame.code == M.typeCode)
    return try M.decode(frame.body, draft)
}

private let bbb = try! TrackNamespace(["bbb"])

@Suite("Draft-16 control messages")
struct Draft16Tests {
    @Test("CLIENT_SETUP matches moq-rs")
    func clientSetupMoqRs() throws {
        let setup = Draft16.ClientSetup(parameters: Parameters([
            try .string(Draft16.SetupParameter.path, "testpath"),
            try .integer(Draft16.SetupParameter.maxRequestID, 100),
        ]))
        let bytes = "20 000e 02 01 08 7465737470617468 01 4064"
        #expect(framed(setup) == hexBytes(bytes))
        #expect(try decode(Draft16.ClientSetup.self, bytes) == setup)
    }

    /// PATH, MAX_REQUEST_ID, AUTHORITY in type order, so the deltas are 1, 1,
    /// 3; nothing of MOQOM's own.
    @Test("CLIENT_SETUP for a raw-QUIC relay")
    func clientSetupRelay() {
        let setup = Draft16.ClientSetup(authority: "relay.example", path: "/abc?jwt=x", maxRequestID: 100)
        #expect(framed(setup) == hexBytes(
            """
            20 001f
            03
            01 0a 2f6162633f6a77743d78
            01 4064
            03 0d 72656c61792e6578616d706c65
            """
        ))
        #expect(setup.parameters.items.map(\.type) == [0x01, 0x02, 0x05])
    }

    @Test("SERVER_SETUP's MAX_REQUEST_ID defaults to none")
    func serverSetup() throws {
        #expect(try decode(Draft16.ServerSetup.self, "21 0004 01 02 4064").maxRequestID == 100)
        #expect(try decode(Draft16.ServerSetup.self, "21 0001 00").maxRequestID == 0)
    }

    /// FORWARD (0x10), SUBSCRIBER_PRIORITY (0x20) and SUBSCRIPTION_FILTER
    /// (0x21, odd, so length-prefixed bytes) go out as deltas 16, 16, 1.
    @Test("SUBSCRIBE")
    func subscribe() throws {
        let subscribe = Draft16.Subscribe(
            requestID: 0,
            track: try FullTrackName(namespace: bbb, name: TrackName("1.m4s")),
            parameters: Parameters([
                try .integer(Draft16.Parameter.forward, 1),
                try .integer(Draft16.Parameter.subscriberPriority, 128),
                Draft16.SubscriptionFilter.largestObject.parameter,
            ])
        )
        let bytes = "03 0015 00 01 03 626262 05 312e6d3473 03 10 01 10 4080 01 01 02"
        #expect(framed(subscribe) == hexBytes(bytes))
        #expect(try decode(Draft16.Subscribe.self, bytes) == subscribe)
    }

    @Test("SUBSCRIBE_OK with LARGEST_OBJECT and no extensions")
    func subscribeOk() throws {
        let ok = try decode(Draft16.SubscribeOk.self, "04 0007 00 05 01 09 02 07 03")
        #expect(ok.requestID == 0)
        #expect(ok.trackAlias == 5)
        #expect(try ok.parameters.draft16LargestObject == Location(group: 7, object: 3))
        #expect(ok.extensions.isEmpty)
    }

    @Test("REQUEST_ERROR carries the request ID and no redirect")
    func requestError() throws {
        let error = try decode(Draft16.RequestError.self, "05 0007 02 10 00 03 626164")
        #expect(error == Draft16.RequestError(requestID: 2, code: RequestErrorCode.doesNotExist, reason: "bad"))
    }

    @Test("PUBLISH_DONE's swapped codes map to draft-19's")
    func publishDone() throws {
        let done = try decode(Draft16.PublishDone.self, "0b 0004 00 06 02 00")
        #expect(done.status == Draft16.DoneStatus.tooFarBehind)
        #expect(Draft16.DoneStatus.draft19(done.status) == PublishDoneStatus.tooFarBehind)
        #expect(Draft16.DoneStatus.draft19(Draft16.DoneStatus.expired) == PublishDoneStatus.expired)
        #expect(Draft16.DoneStatus.draft19(Draft16.DoneStatus.trackEnded) == PublishDoneStatus.trackEnded)
    }

    @Test("request-ID-only messages")
    func requestIDOnly() throws {
        #expect(framed(Draft16.Unsubscribe(requestID: 0)) == hexBytes("0a 0001 00"))
        #expect(framed(Draft16.MaxRequestID(100)) == hexBytes("15 0002 4064"))
        #expect(try decode(Draft16.RequestsBlocked.self, "1a 0001 3f").maximum == 63)
        #expect(framed(Draft16.PublishNamespaceDone(requestID: 4)) == hexBytes("09 0001 04"))
    }

    @Test("SUBSCRIBE_NAMESPACE carries its options")
    func subscribeNamespace() throws {
        let message = Draft16.SubscribeNamespace(requestID: 2, prefix: bbb, options: .namespace)
        #expect(framed(message) == hexBytes("11 0008 02 01 03 626262 01 00"))
        #expect(throws: WireError.self) { try decode(Draft16.SubscribeNamespace.self, "11 0008 02 01 03 626262 03 00") }
    }

    @Test("PUBLISH from the relay, and PUBLISH_OK back")
    func publish() throws {
        // Request 1, bbb / 0.mp4, alias 9, LARGEST_OBJECT {0, 0}, extension
        // 0x0E (DEFAULT_PUBLISHER_PRIORITY) = 128.
        let publish = try decode(
            Draft16.Publish.self,
            "1d 0015 01 01 03 626262 05 302e6d7034 09 01 09 02 00 00 0e 4080"
        )
        #expect(publish.track.name.value == "0.mp4")
        #expect(publish.trackAlias == 9)
        #expect(try publish.parameters.draft16LargestObject == Location(group: 0, object: 0))
        #expect(publish.extensions.integer(0x0E) == 128)

        let ok = Draft16.PublishOk(requestID: 1, parameters: Parameters([
            try .integer(Draft16.Parameter.forward, 1),
        ]))
        #expect(framed(ok) == hexBytes("1e 0004 01 01 10 01"))
    }

    @Test("PUBLISH_NAMESPACE and its cancel")
    func publishNamespace() throws {
        #expect(framed(Draft16.PublishNamespace(requestID: 0, namespace: bbb)) == hexBytes("06 0007 00 01 03 626262 00"))
        let cancel = try decode(Draft16.PublishNamespaceCancel.self, "0c 0004 00 01 01 78")
        #expect(cancel == Draft16.PublishNamespaceCancel(requestID: 0, code: 1, reason: "x"))
    }

    @Test("TRACK_STATUS is SUBSCRIBE's layout")
    func trackStatus() throws {
        let status = Draft16.TrackStatus(requestID: 6, track: try FullTrackName(namespace: bbb, name: TrackName("0.mp4")))
        #expect(framed(status) == hexBytes("0d 000d 06 01 03 626262 05 302e6d7034 00"))
        let ok = try decode(Draft16.RequestOk.self, "07 0006 06 01 09 02 0c 00")
        #expect(ok.requestID == 6)
        #expect(try ok.parameters.draft16LargestObject == Location(group: 12, object: 0))
    }

    @Test("SUBSCRIPTION_FILTER round-trips every type")
    func filters() throws {
        let filters: [Draft16.SubscriptionFilter] = [
            .nextGroupStart,
            .largestObject,
            .absoluteStart(Location(group: 3, object: 1)),
            .absoluteRange(start: Location(group: 3, object: 1), endGroup: 5),
        ]
        for filter in filters {
            let bytes = try #require(filter.parameter.bytesValue)
            #expect(try Draft16.SubscriptionFilter(bytes: bytes) == filter)
        }
        #expect(Draft16.SubscriptionFilter.absoluteRange(start: Location(group: 3, object: 1), endGroup: 5)
            .parameter.bytesValue == hexBytes("04 03 01 05"))
        #expect(throws: WireError.self) { try Draft16.SubscriptionFilter(bytes: hexBytes("04 05 00 03")) }
        #expect(throws: WireError.self) { try Draft16.SubscriptionFilter(bytes: hexBytes("05")) }
    }

    @Test("NAMESPACE and NAMESPACE_DONE are draft-19's bodies")
    func namespaces() throws {
        var reader = draft.reader(hexBytes("0e 0007 01 05 616c696365"))
        let frame = try ControlFrame.readRaw(from: &reader)
        #expect(frame.code == Draft16.MessageCode.namespaceDone.rawValue)
        #expect(try NamespaceDone.decode(frame.body, draft) == NamespaceDone(suffix: try TrackNamespace(["alice"])))
    }

    @Test("unknown message types are refused")
    func unknown() {
        #expect(throws: WireError.self) { try Draft16.MessageCode(code: 0x2F00) }
        #expect(throws: WireError.self) { try Draft16.MessageCode(code: 0x22) }
    }
}
