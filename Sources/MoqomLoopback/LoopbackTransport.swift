// A `Transport` with no network under it.
//
// Ships as a product rather than living in the test target, for two reasons.
// The sample app needs to run before there is a relay to point it at, and an
// integrator evaluating the SDK should be able to write their room UI against
// something that behaves correctly before they have credentials. A loopback
// that only the SDK's own tests can reach is worth much less than one anybody
// can build against.

import Foundation
import MoqomCore
import MoqomKit

/// Connects sessions to a shared in-memory ``LoopbackRelay``.
public struct LoopbackTransport: Transport {
    public let relay: LoopbackRelay

    /// Fail every connection attempt, to exercise the reconnect path.
    ///
    /// For a relay that goes away and comes back — which is the case reconnection
    /// actually has to handle — use ``LoopbackRelay/setAcceptingConnections(_:)``
    /// instead. This is the permanent version.
    public let failure: TransportFailure?

    public init(relay: LoopbackRelay = LoopbackRelay(), failure: TransportFailure? = nil) {
        self.relay = relay
        self.failure = failure
    }

    public func connect(
        to endpoint: RelayEndpoint,
        credentials: DeviceCredentials
    ) async throws(MoqomError) -> any TransportSession {
        if let failure { throw MoqomError.transport(failure) }
        guard await relay.isAcceptingConnections else {
            throw MoqomError.transport(.unreachable)
        }
        await relay.record(.connected(credentials.identity))
        let session = LoopbackSession(
            relay: relay,
            negotiated: NegotiatedParameters(
                alpn: endpoint.alpn.first ?? "moqt-19",
                supportsDatagrams: true,
                maximumDatagramSize: 1200
            )
        )
        await relay.attach(session, for: credentials.identity)
        return session
    }
}

/// One session on the loopback fabric.
public final class LoopbackSession: TransportSession {
    private let relay: LoopbackRelay
    private let parameters: NegotiatedParameters

    private let interruptionStream: AsyncStream<TransportFailure>
    private let interruptionContinuation: AsyncStream<TransportFailure>.Continuation
    private let interrupted = OnceFlag()

    private let offerStream: AsyncStream<TrackOffer>
    private let offerContinuation: AsyncStream<TrackOffer>.Continuation
    private let offered = Offers()

    init(relay: LoopbackRelay, negotiated: NegotiatedParameters) {
        self.relay = relay
        parameters = negotiated
        (interruptionStream, interruptionContinuation) = AsyncStream.makeStream(
            of: TransportFailure.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        (offerStream, offerContinuation) = AsyncStream.makeStream(of: TrackOffer.self)
    }

    public var negotiated: NegotiatedParameters {
        get async { parameters }
    }

    public var interruptions: AsyncStream<TransportFailure> { interruptionStream }

    public var offers: AsyncStream<TrackOffer> { offerStream }

    /// Push a track at this session, the way a relay's PUBLISH does.
    ///
    /// Returns where to write the track's objects. Offering a track that has
    /// already been offered reuses the stream the consumer is reading rather
    /// than starting a second one, which is what the real session does with a
    /// second PUBLISH for the same name — a participant muted twice must not
    /// have to notice that they were.
    @discardableResult
    public func offer(_ track: FullTrackName) -> AsyncStream<TrackObject>.Continuation {
        if let existing = offered.continuation(for: track) { return existing }
        let (stream, continuation) = AsyncStream.makeStream(
            of: TrackObject.self,
            bufferingPolicy: .unbounded
        )
        offered.set(continuation, for: track)
        offerContinuation.yield(TrackOffer(track: track, objects: stream))
        return continuation
    }

    /// Drop this session as if the network had gone away.
    ///
    /// The loopback's equivalent of ``MemoryCarrier/drop(_:)``, and the reason
    /// the room layer's reconnection is testable without a socket: everything
    /// above the transport sees exactly what a real drop produces.
    public func drop(_ failure: TransportFailure = .idleTimeout) {
        guard interrupted.claim() else { return }
        interruptionContinuation.yield(failure)
        interruptionContinuation.finish()
    }

    public func announce(
        _ namespace: TrackNamespace
    ) async throws(MoqomError) -> any AnnouncementHandle {
        // Announced *by this session*, so that dropping the session withdraws
        // it. Ownership rather than a bare namespace, because two sessions for
        // the same person -- an old one and its replacement mid-reconnect --
        // must not withdraw each other's.
        let owner = ObjectIdentifier(self)
        await relay.announce(namespace, by: owner)
        return LoopbackAnnouncement(namespace: namespace, relay: relay, owner: owner)
    }

    public func announcements(
        matching prefix: TrackNamespace
    ) async throws(MoqomError) -> AsyncStream<AnnouncementEvent> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: AnnouncementEvent.self,
            bufferingPolicy: .unbounded
        )
        let id = await relay.watch(prefix: prefix, continuation: continuation)
        let relay = relay
        continuation.onTermination = { _ in
            Task { await relay.unwatch(id) }
        }
        return stream
    }

    public func subscribe(
        _ request: SubscribeRequest
    ) async throws(MoqomError) -> any SubscriptionHandle {
        if await relay.shouldRefuseSubscribe(to: request.track) {
            throw MoqomError.rejected(.trackNotFound(request.track))
        }
        let (stream, continuation) = AsyncStream.makeStream(
            of: TrackObject.self,
            bufferingPolicy: .bufferingNewest(64)
        )
        let id = await relay.subscribe(
            to: request.track,
            priority: request.priority,
            start: request.start,
            continuation: continuation
        )
        return LoopbackSubscription(
            id: id,
            track: request.track,
            objects: stream,
            relay: relay
        )
    }

    public func fetch(_ request: FetchRequest) async throws(MoqomError) -> any FetchHandle {
        let track: FullTrackName
        let start: Location
        let end: FetchEnd

        switch request.range {
        case let .standalone(named, from, to):
            track = named
            start = from
            end = to
        case let .joining(subscription, groups):
            // Resolved against where the track actually is, which is the whole
            // reason to prefer a joining fetch: the live edge cannot move
            // between working out what to ask for and asking.
            track = subscription.track
            guard let position = await relay.position(of: track) else {
                throw MoqomError.rejected(.unavailable)
            }
            start = Location.group(position.group >= groups ? position.group - groups : 0)
            end = .through(position)
        case let .joiningFrom(subscription, group):
            track = subscription.track
            guard let position = await relay.position(of: track) else {
                throw MoqomError.rejected(.unavailable)
            }
            guard group <= position.group else {
                throw MoqomError.rejected(.unavailable)
            }
            start = Location.group(group)
            end = .through(position)
        }

        let records = await relay.fetch(track, from: start, through: end, order: request.order)
        return LoopbackFetch(track: track, served: end, records: records, relay: relay)
    }

    public func publish(
        _ track: FullTrackName,
        priority: UInt8
    ) async throws(MoqomError) -> any TrackWriter {
        // A relay that refuses to open a track is the failure worth being able to reproduce.
        // Reopening a writer after a reconnect can fail for the same transient reason the
        // reconnect happened, and what a publisher does about it decides whether the broadcast
        // comes back or dies quietly with its camera still running.
        if await relay.shouldRefusePublish() { throw MoqomError.rejected(.unavailable) }
        await relay.publish(track)
        return LoopbackWriter(track: track, priority: priority, relay: relay)
    }

    public func close(code: UInt64, reason _: String) async {
        // Finished without yielding, so a deliberate close is never mistaken for
        // a drop and never provokes a reconnect.
        if interrupted.claim() { interruptionContinuation.finish() }
        offered.finishAll()
        offerContinuation.finish()
        await relay.close(code: code)
    }
}

/// The tracks a session has been offered, by name.
private final class Offers: @unchecked Sendable {
    private let lock = NSLock()
    private var streams: [FullTrackName: AsyncStream<TrackObject>.Continuation] = [:]

    func continuation(for track: FullTrackName) -> AsyncStream<TrackObject>.Continuation? {
        lock.lock()
        defer { lock.unlock() }
        return streams[track]
    }

    func set(_ continuation: AsyncStream<TrackObject>.Continuation, for track: FullTrackName) {
        lock.lock()
        defer { lock.unlock() }
        streams[track] = continuation
    }

    func finishAll() {
        lock.lock()
        let all = streams.values
        streams.removeAll()
        lock.unlock()
        for continuation in all { continuation.finish() }
    }
}

/// A one-shot latch.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

private final class LoopbackAnnouncement: AnnouncementHandle {
    let namespace: TrackNamespace
    private let relay: LoopbackRelay
    private let owner: ObjectIdentifier

    init(namespace: TrackNamespace, relay: LoopbackRelay, owner: ObjectIdentifier) {
        self.namespace = namespace
        self.relay = relay
        self.owner = owner
    }

    func withdraw() async {
        await relay.withdraw(namespace, by: owner)
    }
}

private final class LoopbackSubscription: SubscriptionHandle {
    let track: FullTrackName
    let objects: AsyncStream<TrackObject>

    private let id: UUID
    private let relay: LoopbackRelay

    init(
        id: UUID,
        track: FullTrackName,
        objects: AsyncStream<TrackObject>,
        relay: LoopbackRelay
    ) {
        self.id = id
        self.track = track
        self.objects = objects
        self.relay = relay
    }

    func updatePriority(_ priority: UInt8) async {
        await relay.reprioritise(track, priority: priority)
    }

    func cancel() async {
        await relay.unsubscribe(id, from: track)
    }
}

/// A fetch that has already been answered.
///
/// Everything is resolved before the handle exists, because there is no network
/// to be waiting on. The records still arrive through an `AsyncStream` rather
/// than as an array, so that a caller written against this and a caller written
/// against `MoqtSession` are the same caller — including the part where the
/// stream ending is how a fetch says it is done.
private final class LoopbackFetch: FetchHandle {
    let records: AsyncStream<FetchedRecord>

    private let track: FullTrackName
    private let end: FetchEnd
    private let relay: LoopbackRelay

    init(
        track: FullTrackName,
        served: FetchEnd,
        records: [FetchedRecord],
        relay: LoopbackRelay
    ) {
        self.track = track
        end = served
        self.relay = relay

        let (stream, continuation) = AsyncStream.makeStream(
            of: FetchedRecord.self,
            bufferingPolicy: .unbounded
        )
        for record in records { continuation.yield(record) }
        continuation.finish()
        self.records = stream
    }

    var served: FetchEnd? {
        get async { end }
    }

    func cancel() async {
        await relay.cancelFetch(on: track)
    }
}

private final class LoopbackWriter: TrackWriter {
    let track: FullTrackName

    private let priority: UInt8
    private let relay: LoopbackRelay

    init(track: FullTrackName, priority: UInt8, relay: LoopbackRelay) {
        self.track = track
        self.priority = priority
        self.relay = relay
    }

    func write(_ object: TrackObject) async throws(MoqomError) {
        await relay.deliver(object, to: track)
    }

    func startGroup(_: UInt64) async throws(MoqomError) {
        // Group boundaries are carried on the objects themselves, so there is
        // nothing for an in-memory fabric to do here. The real transport closes
        // the current subgroup stream and opens a new one.
    }

    func finish() async {}
}
