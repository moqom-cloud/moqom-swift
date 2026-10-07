// The one place `MoqtSession` learns which draft it is speaking.
//
// Draft-19 (MOQOM's profile) and draft-22 share a session shape — every
// request on its own bidirectional stream, data on unidirectional streams and
// datagrams — and differ in bytes: varint encoding, Message Parameters, which
// messages exist, and where SETUP goes. So the session states what it means
// (``OutgoingMessage``) and acts on what arrived (``PeerMessage``), and this
// file is the translation in each direction. Everything draft-specific above
// the data plane is in here, which is what keeps adding a draft from being an
// edit to every method of a two-thousand-line actor.
//
// Draft-16 is not a dialect of this session. Its requests share one control
// stream and are matched by Request ID, which is a different state machine
// rather than different bytes; that is ``Draft16Session``.

import Foundation
import MoqomCore
import MoqomWire

/// A control message, as the session acts on it.
enum PeerMessage: Sendable {
    case setup(Parameters)
    case goaway(newSessionURI: String, timeoutMilliseconds: UInt64)
    /// `fill` is draft-22's FILL_PARAMETERS location filter, when the
    /// subscription asked to be caught up as well.
    case subscribe(requestID: UInt64, track: FullTrackName, fill: LocationFilter?)
    case subscribeOk(alias: UInt64)
    case requestOk
    case requestError(RequestError)
    case publish(track: FullTrackName, alias: UInt64)
    case publishNamespace
    case subscribeNamespace(prefix: TrackNamespace)
    case namespace(suffix: TrackNamespace)
    case namespaceDone(suffix: TrackNamespace, reason: WithdrawalReason?)
    /// `kind` is `nil` for a draft-22 range this end cannot serve: one
    /// relative to the live edge, which only makes sense as a fill.
    case fetch(requestID: UInt64, kind: Fetch.Kind?, order: GroupOrder)
    case fetchOk(FetchEnd)
    case publishDone
    case requestUpdate(requestID: UInt64, fill: LocationFilter?)
    /// Well-formed and of no use to this session.
    case unhandled
}

/// A control message, as the session means it.
enum OutgoingMessage: Sendable {
    case setup(token: Data?, proof: Data?)
    case goaway
    case subscribe(requestID: UInt64, track: FullTrackName, priority: UInt8, deliveryTimeout: UInt64?)
    case subscribeOk(alias: UInt64, largest: Location?)
    case requestOk
    case requestError(code: UInt64, reason: String)
    case publishNamespace(requestID: UInt64, namespace: TrackNamespace)
    case subscribeNamespace(requestID: UInt64, prefix: TrackNamespace)
    case namespace(suffix: TrackNamespace)
    case namespaceDone(suffix: TrackNamespace, reason: WithdrawalReason)
    case update(requestID: UInt64, RequestChange)
    case fetch(requestID: UInt64, kind: Fetch.Kind, priority: UInt8, order: GroupOrder)
    case fetchOk(FetchEnd)
}

/// What a REQUEST_UPDATE changes.
enum RequestChange: Sendable {
    case priority(UInt8)
    case forward(Bool)
    case token(Data, proof: Data?)
    /// Draft-22 only: open a fill fetch stream for this subscription.
    case fill(LocationFilter)
}

struct SessionDialect: Sendable {
    let draft: MoqtDraft

    /// Draft-22: both SETUPs declared ``SetupOption/moqomParameters``, so
    /// MOQOM's private Message Parameters and NAMESPACE_DONE's reason may
    /// travel. Set by the session once the peer's SETUP is read; until then,
    /// and with any peer that did not declare it, neither end may use them.
    var moqomParameters = false

    init(_ draft: MoqtDraft) {
        precondition(draft != .draft16, "draft-16 is Draft16Session, not a dialect")
        self.draft = draft
    }

    init(alpn: String) {
        self.init(MoqtDraft(alpn: alpn).flatMap { $0 == .draft16 ? nil : $0 } ?? .draft19)
    }

    var isStrict: Bool { draft >= .draft22 }

    func reader(_ data: Data) -> WireReader { draft.reader(data) }
    func writer(capacity: Int = 0) -> WireWriter { draft.writer(capacity: capacity) }

    func framer() -> StreamFramer { StreamFramer(draft: draft) }

    // MARK: - Encoding

    func bytes(_ message: OutgoingMessage) throws(MoqomError) -> Data {
        var writer = writer(capacity: 64)
        do {
            switch draft {
            case .draft22: try encode22(message, to: &writer)
            default: try encode19(message, to: &writer)
            }
        } catch {
            throw MoqomError.protocolViolation("control message too long to frame")
        }
        return writer.bytes
    }

    private func encode19(_ message: OutgoingMessage, to writer: inout WireWriter) throws(BodyTooLong) {
        switch message {
        case let .setup(token, proof):
            try ControlFrame.write(Setup(options: setupOptions(token: token, proof: proof)), to: &writer)
        case .goaway:
            try ControlFrame.write(Goaway(timeoutMilliseconds: 0), to: &writer)
        case let .subscribe(requestID, track, priority, timeout):
            var parameters = Parameters()
            if let value = try? Parameter.integer(SubscribeParameter.subscriberPriority, UInt64(priority)) {
                parameters.insert(value)
            }
            if let timeout, let value = try? Parameter.integer(SubscribeParameter.deliveryTimeout, timeout) {
                parameters.insert(value)
            }
            try ControlFrame.write(Subscribe(requestID: requestID, track: track, parameters: parameters), to: &writer)
        case let .subscribeOk(alias, _):
            try ControlFrame.write(SubscribeOk(trackAlias: alias), to: &writer)
        case .requestOk:
            try ControlFrame.write(RequestOk(), to: &writer)
        case let .requestError(code, reason):
            try ControlFrame.write(RequestError(code: code, reason: reason), to: &writer)
        case let .publishNamespace(requestID, namespace):
            try ControlFrame.write(PublishNamespace(requestID: requestID, namespace: namespace), to: &writer)
        case let .subscribeNamespace(requestID, prefix):
            try ControlFrame.write(SubscribeNamespace(requestID: requestID, prefix: prefix), to: &writer)
        case let .namespace(suffix):
            try ControlFrame.write(NamespaceAnnounced(suffix: suffix), to: &writer)
        case let .namespaceDone(suffix, reason):
            try ControlFrame.write(NamespaceDone(suffix: suffix, reason: reason), to: &writer)
        case let .update(requestID, change):
            var parameters = Parameters()
            switch change {
            case let .priority(priority):
                if let value = try? Parameter.integer(SubscribeParameter.subscriberPriority, UInt64(priority)) {
                    parameters.insert(value)
                }
            case let .forward(forward):
                if let value = try? Parameter.integer(SubscribeParameter.forward, forward ? 1 : 0) {
                    parameters.insert(value)
                }
            case let .token(token, proof):
                if let value = try? Parameter.bytes(RequestParameter.authorizationToken, token) {
                    parameters.insert(value)
                }
                if let proof, let value = try? Parameter.bytes(RequestParameter.authorizationProof, proof) {
                    parameters.insert(value)
                }
            case .fill:
                preconditionFailure("draft-19 has no fill")
            }
            try ControlFrame.write(RequestUpdate(requestID: requestID, parameters: parameters), to: &writer)
        case let .fetch(requestID, kind, priority, order):
            var parameters = Parameters()
            if let value = try? Parameter.integer(SubscribeParameter.subscriberPriority, UInt64(priority)) {
                parameters.insert(value)
            }
            if let value = try? Parameter.integer(SubscribeParameter.groupOrder, order.rawValue) {
                parameters.insert(value)
            }
            try ControlFrame.write(Fetch(requestID: requestID, kind: kind, parameters: parameters), to: &writer)
        case let .fetchOk(end):
            try ControlFrame.write(FetchOk(end: end), to: &writer)
        }
    }

    private func encode22(_ message: OutgoingMessage, to writer: inout WireWriter) throws(BodyTooLong) {
        switch message {
        case let .setup(token, proof):
            // The token is a Token structure here, USE_VALUE with the
            // out-of-band type. The proof stays a private option: draft-22
            // ignores setup options it does not know (§9.3.1), so a relay that
            // does not check proofs never sees a reason to refuse.
            let structured = token.map { AuthorizationToken.useValue(type: 0, value: $0).encoded(in: .vi64) }
            var options = setupOptions(token: structured, proof: proof)
            if let value = try? Parameter.integer(SetupOption.moqomParameters, 1) { options.insert(value) }
            try ControlFrame.write(
                Setup(options: options),
                as: Draft22.MessageCode.setup.rawValue,
                to: &writer
            )
        case .goaway:
            try ControlFrame.write(Goaway(timeoutMilliseconds: 0), as: Draft22.MessageCode.goaway.rawValue, to: &writer)
        case let .subscribe(requestID, track, priority, timeout):
            var parameters: [MessageParameter] = [.subscriberPriority(priority)]
            if let timeout { parameters.append(.objectDeliveryTimeout(timeout)) }
            try ControlFrame.write(
                Draft22.Subscribe(requestID: requestID, track: track, parameters: MessageParameters(parameters)),
                to: &writer
            )
        case let .subscribeOk(alias, largest):
            try ControlFrame.write(
                Draft22.SubscribeOk(trackAlias: alias, parameters: MessageParameters(largest.map { [.largestObject($0)] } ?? [])),
                to: &writer
            )
        case .requestOk:
            try ControlFrame.write(Draft22.RequestOk(), to: &writer)
        case let .requestError(code, reason):
            try ControlFrame.write(
                RequestError(code: code, reason: reason),
                as: Draft22.MessageCode.requestError.rawValue,
                to: &writer
            )
        case let .publishNamespace(requestID, namespace):
            try ControlFrame.write(Draft22.PublishNamespace(requestID: requestID, namespace: namespace), to: &writer)
        case let .subscribeNamespace(requestID, prefix):
            try ControlFrame.write(Draft22.SubscribeNamespace(requestID: requestID, prefix: prefix), to: &writer)
        case let .namespace(suffix):
            try ControlFrame.write(NamespaceAnnounced(suffix: suffix), as: Draft22.MessageCode.namespace.rawValue, to: &writer)
        case let .namespaceDone(suffix, reason):
            // MOQOM's trailing reason only to a peer that agreed to it:
            // draft-22 §9 makes a body longer than its fields a
            // PROTOCOL_VIOLATION, so the extension draft-19 receivers skip
            // would close any other draft-22 session.
            try ControlFrame.write(
                NamespaceDone(suffix: suffix, reason: moqomParameters ? reason : nil),
                as: Draft22.MessageCode.namespaceDone.rawValue,
                to: &writer
            )
        case let .update(requestID, change):
            let parameters: [MessageParameter] = switch change {
            case let .priority(priority): [.subscriberPriority(priority)]
            case let .forward(forward): [.forward(forward)]
            // The proof beside the token only where MOQOM_PARAMETERS was
            // agreed: draft-22 closes the session over a Message Parameter the
            // peer does not define, so elsewhere the token goes alone.
            case let .token(token, proof?) where moqomParameters:
                [.authorizationToken(.useValue(type: 0, value: token)), .authorizationProof(proof)]
            case let .token(token, _): [.authorizationToken(.useValue(type: 0, value: token))]
            case let .fill(filter): [.fillParameters([.locationFilter(filter)])]
            }
            try ControlFrame.write(
                Draft22.RequestUpdate(requestID: requestID, parameters: MessageParameters(parameters)),
                to: &writer
            )
        case let .fetch(requestID, kind, priority, order):
            guard case let .standalone(track, start, end) = kind else {
                preconditionFailure("draft-22 joins with a fill, not a fetch")
            }
            let filter: LocationFilter = switch end {
            case let .through(last): .absoluteRange(start: start, end: last)
            case let .endOfGroup(group): .absoluteThroughGroup(start: start, endGroup: group)
            }
            try ControlFrame.write(
                Draft22.Fetch(requestID: requestID, track: track, parameters: [
                    .subscriberPriority(priority), .locationFilter(filter), .groupOrder(order),
                ]),
                to: &writer
            )
        case let .fetchOk(end):
            let last: Location = switch end {
            case let .through(location): location
            // Inclusive on the wire, so "the whole group" has no exact
            // spelling without knowing its last object. The group's start is
            // the conservative end: FETCH_OK describes, it does not bound.
            case let .endOfGroup(group): Location.group(group)
            }
            try ControlFrame.write(Draft22.FetchOk(end: last), to: &writer)
        }
    }

    private func setupOptions(token: Data?, proof: Data?) -> Parameters {
        var options = Parameters()
        // Sent only when there is one. An empty token is not a weaker claim, it
        // is a malformed one.
        if let token, !token.isEmpty, let value = try? Parameter.bytes(SetupOption.authorizationToken, token) {
            options.insert(value)
            if let proof, let value = try? Parameter.bytes(SetupOption.authorizationProof, proof) {
                options.insert(value)
            }
        }
        if let value = try? Parameter.string(SetupOption.implementation, "moqom-swift/\(moqomKitVersion)") {
            options.insert(value)
        }
        return options
    }

    /// The raw token from a peer's SETUP options, whichever shape it arrived
    /// in.
    func setupToken(_ options: Parameters) -> Data? {
        guard let value = options.bytes(SetupOption.authorizationToken) else { return nil }
        guard draft >= .draft22 else { return value }
        guard case let .useValue(_, token) = try? AuthorizationToken.decode(value, in: .vi64) else { return nil }
        return token
    }

    // MARK: - Decoding

    /// - Throws: ``WireError`` for a frame that is malformed or not allowed
    ///   here. Draft-22 closes the session over that (§9); draft-19 callers
    ///   drop the frame, as they always have.
    func decode(_ frame: RawFrame) throws(WireError) -> PeerMessage {
        switch draft {
        case .draft22: try decode22(frame)
        default: try decode19(frame)
        }
    }

    private func decode19(_ frame: RawFrame) throws(WireError) -> PeerMessage {
        guard let type = MessageType(rawValue: frame.code) else {
            throw WireError.invalid("unknown control message type 0x\(String(frame.code, radix: 16))")
        }
        var reader = WireReader(frame.body)
        switch type {
        case .setup:
            return .setup(try Setup.read(from: &reader).options)
        case .goaway:
            let goaway = try Goaway.read(from: &reader)
            return .goaway(newSessionURI: goaway.newSessionURI, timeoutMilliseconds: goaway.timeoutMilliseconds)
        case .subscribe:
            let request = try Subscribe.read(from: &reader)
            return .subscribe(requestID: request.requestID, track: request.track, fill: nil)
        case .subscribeOk:
            return .subscribeOk(alias: try SubscribeOk.read(from: &reader).trackAlias)
        case .requestOk:
            return .requestOk
        case .requestError:
            return .requestError(try RequestError.read(from: &reader))
        case .publish:
            let offer = try Publish.read(from: &reader)
            return .publish(track: offer.track, alias: offer.trackAlias)
        case .publishNamespace:
            return .publishNamespace
        case .subscribeNamespace:
            return .subscribeNamespace(prefix: try SubscribeNamespace.read(from: &reader).prefix)
        case .namespace:
            return .namespace(suffix: try NamespaceAnnounced.read(from: &reader).suffix)
        case .namespaceDone:
            let done = try NamespaceDone.read(from: &reader)
            return .namespaceDone(suffix: done.suffix, reason: done.reason)
        case .fetch:
            let request = try Fetch.read(from: &reader)
            let order = request.parameters.integer(SubscribeParameter.groupOrder)
                .flatMap(GroupOrder.init(rawValue:)) ?? .ascending
            return .fetch(requestID: request.requestID, kind: request.kind, order: order)
        case .fetchOk:
            return .fetchOk(try FetchOk.read(from: &reader).end)
        case .publishDone:
            return .publishDone
        case .requestUpdate:
            return .requestUpdate(requestID: try RequestUpdate.read(from: &reader).requestID, fill: nil)
        default:
            return .unhandled
        }
    }

    private func decode22(_ frame: RawFrame) throws(WireError) -> PeerMessage {
        let draft = self.draft
        switch try Draft22.MessageCode(code: frame.code) {
        case .setup:
            return .setup(try Setup.decode(frame.body, draft).options)
        case .goaway:
            let goaway = try Goaway.decode(frame.body, draft)
            return .goaway(newSessionURI: goaway.newSessionURI, timeoutMilliseconds: goaway.timeoutMilliseconds)
        case .subscribe:
            let request = try Draft22.Subscribe.decode(frame.body, draft)
            try admit(request.parameters)
            return .subscribe(requestID: request.requestID, track: request.track, fill: request.parameters.fill.map {
                $0.locationFilter ?? .none
            })
        case .subscribeOk:
            let ok = try Draft22.SubscribeOk.decode(frame.body, draft)
            try admit(ok.parameters)
            return .subscribeOk(alias: ok.trackAlias)
        case .requestOk:
            try admit(try Draft22.RequestOk.decode(frame.body, draft).parameters)
            return .requestOk
        case .requestError:
            return .requestError(try RequestError.decode(frame.body, draft))
        case .publish:
            let offer = try Draft22.Publish.decode(frame.body, draft)
            try admit(offer.parameters)
            return .publish(track: offer.track, alias: offer.trackAlias)
        case .publishNamespace:
            try admit(try Draft22.PublishNamespace.decode(frame.body, draft).parameters)
            return .publishNamespace
        case .subscribeNamespace:
            let request = try Draft22.SubscribeNamespace.decode(frame.body, draft)
            try admit(request.parameters)
            return .subscribeNamespace(prefix: request.prefix)
        case .namespace:
            return .namespace(suffix: try NamespaceAnnounced.decode(frame.body, draft).suffix)
        case .namespaceDone:
            // MOQOM's reason, if a MOQOM peer sent one anyway, is read rather
            // than refused: the bytes are unambiguous and the reason is worth
            // having.
            let done = try NamespaceDone.decode(frame.body, draft)
            return .namespaceDone(suffix: done.suffix, reason: done.reason)
        case .fetch:
            let request = try Draft22.Fetch.decode(frame.body, draft)
            try admit(request.parameters)
            let kind: Fetch.Kind? = switch request.locationFilter {
            case let .absoluteStart(start)?:
                .standalone(track: request.track, start: start, end: .endOfGroup(.max))
            case let .absoluteThroughGroup(start, endGroup)?:
                .standalone(track: request.track, start: start, end: .endOfGroup(endGroup))
            case let .absoluteRange(start, end)?:
                .standalone(track: request.track, start: start, end: .through(end))
            default:
                nil
            }
            return .fetch(requestID: request.requestID, kind: kind, order: request.groupOrder ?? .ascending)
        case .fetchOk:
            let ok = try Draft22.FetchOk.decode(frame.body, draft)
            try admit(ok.parameters)
            return .fetchOk(.through(ok.end))
        case .publishDone:
            _ = try PublishDone.decode(frame.body, draft)
            return .publishDone
        case .requestUpdate:
            let update = try Draft22.RequestUpdate.decode(frame.body, draft)
            try admit(update.parameters)
            return .requestUpdate(requestID: update.requestID, fill: update.parameters.fill.map {
                $0.locationFilter ?? .none
            })
        case .publishStateNotify:
            try admit(try Draft22.PublishStateNotify.decode(frame.body, draft).parameters)
            return .unhandled
        case .trackStatus:
            try admit(try Draft22.TrackStatus.decode(frame.body, draft).parameters)
            return .unhandled
        case .subscribeTracks:
            try admit(try Draft22.SubscribeTracks.decode(frame.body, draft).parameters)
            return .unhandled
        case .publishSkipped:
            _ = try Draft22.PublishSkipped.decode(frame.body, draft)
            return .unhandled
        }
    }

    /// Refuse MOQOM's private Message Parameters from a peer that has not
    /// agreed to them, in the words §9.20 uses for any parameter a receiver
    /// does not define. The codec reads them regardless; see
    /// ``MessageParameter/Kind/isPrivate`` for why the check lives here.
    private func admit(_ parameters: MessageParameters) throws(WireError) {
        guard !moqomParameters, let found = parameters.firstPrivate else { return }
        throw WireError.invalid(
            "unknown message parameter 0x\(String(found.type, radix: 16)) (MOQOM_PARAMETERS not negotiated)"
        )
    }
}

/// A control message's type and body, before it is interpreted.
struct RawFrame: Sendable {
    let code: UInt64
    let body: Data
}
