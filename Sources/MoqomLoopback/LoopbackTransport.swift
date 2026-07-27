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

    /// Fail the next connection attempt, to exercise the reconnect path.
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
        await relay.record(.connected(credentials.identity))
        return LoopbackSession(
            relay: relay,
            negotiated: NegotiatedParameters(
                alpn: endpoint.alpn.first ?? "moqt-19",
                supportsDatagrams: true,
                maximumDatagramSize: 1200
            )
        )
    }
}

/// One session on the loopback fabric.
public final class LoopbackSession: TransportSession {
    private let relay: LoopbackRelay
    private let parameters: NegotiatedParameters

    init(relay: LoopbackRelay, negotiated: NegotiatedParameters) {
        self.relay = relay
        parameters = negotiated
    }

    public var negotiated: NegotiatedParameters {
        get async { parameters }
    }

    public func announce(
        _ namespace: TrackNamespace
    ) async throws(MoqomError) -> any AnnouncementHandle {
        await relay.announce(namespace)
        return LoopbackAnnouncement(namespace: namespace, relay: relay)
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
        let (stream, continuation) = AsyncStream.makeStream(
            of: TrackObject.self,
            bufferingPolicy: .bufferingNewest(64)
        )
        let id = await relay.subscribe(
            to: request.track,
            priority: request.priority,
            continuation: continuation
        )
        return LoopbackSubscription(
            id: id,
            track: request.track,
            objects: stream,
            relay: relay
        )
    }

    public func publish(
        _ track: FullTrackName,
        priority: UInt8
    ) async throws(MoqomError) -> any TrackWriter {
        await relay.publish(track)
        return LoopbackWriter(track: track, priority: priority, relay: relay)
    }

    public func close(code: UInt64, reason _: String) async {
        await relay.close(code: code)
    }
}

private final class LoopbackAnnouncement: AnnouncementHandle {
    let namespace: TrackNamespace
    private let relay: LoopbackRelay

    init(namespace: TrackNamespace, relay: LoopbackRelay) {
        self.namespace = namespace
        self.relay = relay
    }

    func withdraw() async {
        await relay.withdraw(namespace)
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
