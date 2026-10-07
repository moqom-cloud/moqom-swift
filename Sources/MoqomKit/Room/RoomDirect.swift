// Direct (peer-to-peer) paths in a room: the pieces in `Direct/`, driven by who
// is in the room and what they agreed to.
//
// A room never needs a direct path and never waits for one. Media starts on the
// relay and stays there unless every rule in ``DirectEligibility`` holds. Then,
// for each other participant on stage:
//
// 1. Bind an endpoint on the session's backend and send its offer, sealed, on
//    this participant's `.direct` track, again every second until the peer
//    answers, because a peer reading from the latest group can miss one.
// 2. Read the peer's offers on theirs, and establish with the newest one not
//    tried yet: pinned TLS, then each side checks the other's token and proof
//    as a relay would (``DirectEndpoint``).
// 3. Once up: ask this side's relay for direct tickets, present them and hold
//    the peer to its own (``DirectTicketGuard``); publish every media track on
//    the direct session as well as the relay (``DirectFanout``); and attach a
//    direct subscription beside each relay subscription to the peer, where
//    ``DualSubscription`` merges the two and falls back by itself.
// 4. Anything that ends the path -- the guard, the session closing, the peer
//    offering afresh, the room no longer qualifying -- leaves the relay doing
//    what it was doing all along. Another attempt follows after a backoff, for
//    as long as the room still qualifies.
//
// Offers are sealed under a key from the room's MLS group, so a new epoch means
// a new key: the offer track is reopened under it and readers restarted, and a
// peer not yet on a direct path is offered again. A path already up is kept: it
// is pinned to its certificates and its credentials were checked when it
// opened, and none of that was protected by the old key.

import Foundation
import MoqomCore

/// How a room may use direct (peer-to-peer) paths.
///
/// Off unless an application passes one of these to
/// ``RoomSession/setDirect(_:)`` or ``MoqomSession/join(room:seatPolicy:direct:)``,
/// and even then only used where ``DirectEligibility`` allows: an end-to-end
/// encrypted room of at most ``DirectEligibility/maximumParticipants``, with no
/// watchdog, where this device is publishing on stage and every participant has
/// opted in. Opting in is published on this device's catalog
/// (``Catalog/direct``), which is how the others count it.
public struct DirectRoomOptions: Sendable {
    /// The acknowledgement that peers will learn this device's IP addresses.
    public var exposure: DirectIPExposure

    /// The deployment's token verification keys, the set its relays hold, which
    /// a peer's token must be signed by. See ``DirectVerificationKey/parseSet(_:)``.
    public var tokenKeys: [DirectVerificationKey]

    /// The `iss` every peer token must carry. Empty accepts any, which is for
    /// tests, as on the relay.
    public var issuer: String

    /// Key material for sealing offers, for a room whose keys the application
    /// supplies through ``RoomSession/useEncryption(_:)``. At least 16 bytes,
    /// the same on every participant, and never held by a viewer.
    ///
    /// `nil` takes it from the room's managed MLS group; see
    /// ``DeviceCredentials/keyDelivery``. A room with neither stays on the
    /// relay, reporting ``DirectFallback/awaitingKeys``.
    public var offerSecret: Data?

    /// A STUN server to learn the public address from. Without one only this
    /// device's own address is offered, which reaches a peer on the same
    /// network and nothing behind a NAT.
    public var stun: (host: String, port: UInt16)?

    /// The host address to offer instead of the routed one; for tests on one
    /// machine. See ``DirectConfiguration/advertisedHost``.
    public var advertisedHost: String?

    /// How long one attempt may take to open a path.
    public var patience: Duration

    /// When the merge trusts the direct path, and when it gives up on it.
    public var path: DirectPathSettings

    /// How patient this side is with the peer's tickets.
    public var tickets: DirectTicketSettings

    /// The wait before trying again after an attempt fails, doubling on each
    /// failure up to a minute.
    public var retry: Duration

    public init(
        exposure: DirectIPExposure,
        tokenKeys: [DirectVerificationKey],
        issuer: String = "",
        offerSecret: Data? = nil,
        stun: (host: String, port: UInt16)? = nil,
        patience: Duration = .seconds(5),
        path: DirectPathSettings = DirectPathSettings(),
        tickets: DirectTicketSettings = DirectTicketSettings(),
        retry: Duration = .seconds(2)
    ) {
        self.exposure = exposure
        self.tokenKeys = tokenKeys
        self.issuer = issuer
        self.offerSecret = offerSecret
        self.stun = stun
        self.patience = patience
        self.path = path
        self.tickets = tickets
        self.retry = retry
    }
}

/// How one remote participant's media is reaching this device.
public enum DirectPathState: Hashable, Sendable, CustomStringConvertible {
    /// Through the relay, and why not directly.
    case relay(DirectFallback)
    /// Offers are out and a direct path is being set up. Media is on the relay.
    case connecting
    /// A verified direct session is up and media is read over it as well as
    /// the relay. ``DirectPathStatus/objectsOverDirect`` says how much of it
    /// is winning.
    case direct

    public var description: String {
        switch self {
        case let .relay(why): "relay (\(why))"
        case .connecting: "connecting"
        case .direct: "direct"
        }
    }
}

/// Why a participant's media is on the relay rather than a direct path.
public enum DirectFallback: Hashable, Sendable, CustomStringConvertible {
    /// The room does not allow direct paths, for the first reason in
    /// ``DirectEligibility/check()``'s order.
    case ineligible(DirectIneligibility)
    /// The room qualifies, but there is no key to seal offers with yet: the
    /// room's MLS group has not formed on this device, or the application
    /// supplies its own keys and no ``DirectRoomOptions/offerSecret``.
    case awaitingKeys
    /// The last attempt did not open a path.
    case failed(DirectEndpointError)
    /// This device's relay would not issue direct tickets, so no path is kept.
    case ticketsUnavailable
    /// The peer's direct tickets lapsed or did not verify.
    case ticket(DirectTicketRefusal)
    /// The direct session ended: the network, or the peer starting over.
    case lost

    public var description: String {
        switch self {
        case let .ineligible(why): "\(why)"
        case .awaitingKeys: "waiting for the room's encryption keys"
        case let .failed(why): "\(why)"
        case .ticketsUnavailable: "the relay issues no direct tickets"
        case let .ticket(why): "\(why)"
        case .lost: "the direct path was lost"
        }
    }
}

/// One remote participant's path, as ``RoomSession/directPaths`` reports it.
public struct DirectPathStatus: Hashable, Sendable {
    public internal(set) var state: DirectPathState
    /// Media objects from this participant delivered over the direct path,
    /// because it brought them first.
    public internal(set) var objectsOverDirect: Int
    /// Media objects from this participant delivered over the relay.
    public internal(set) var objectsOverRelay: Int

    init(state: DirectPathState) {
        self.state = state
        objectsOverDirect = 0
        objectsOverRelay = 0
    }
}

// MARK: - Publishing on direct sessions

/// Every media track this room publishes, copied onto each direct session.
///
/// Fed below the encryption, so the direct path carries exactly the
/// ciphertext the relay does, under the same group and object numbers, which is
/// what lets the receiving side's merge deliver each object once.
///
/// A copy is queued rather than awaited: a direct path that stalls must never
/// hold up the relay, which is the fallback. A queue that fills drops its
/// oldest objects, and the receiver's merge covers them from the relay.
final class DirectFanout: @unchecked Sendable {
    private struct Registration {
        let id: UUID
        let priority: UInt8
    }

    /// One track on one direct session, written in order by its own task.
    private final class Lane: Sendable {
        private let continuation: AsyncStream<TrackObject>.Continuation

        init(_ writer: any TrackWriter) {
            let (objects, continuation) = AsyncStream.makeStream(
                of: TrackObject.self,
                bufferingPolicy: .bufferingNewest(256)
            )
            self.continuation = continuation
            Task {
                for await object in objects { try? await writer.write(object) }
                await writer.finish()
            }
        }

        func send(_ object: TrackObject) { continuation.yield(object) }
        func close() { continuation.finish() }
    }

    private let lock = NSLock()
    private var tracks: [FullTrackName: Registration] = [:]
    private var sessions: [String: MoqtSession] = [:]
    private var lanes: [String: [FullTrackName: Lane]] = [:]

    /// A media track the room has opened on the relay.
    func register(_ track: FullTrackName, priority: UInt8) async -> UUID {
        let id = UUID()
        let peers = lock.withLock {
            tracks[track] = Registration(id: id, priority: priority)
            return sessions
        }
        for (peer, session) in peers {
            await open(track, priority: priority, on: session, for: peer)
        }
        return id
    }

    /// The track's writer finished. Ignored when a later registration of the
    /// same track, from a reconnect, has replaced this one.
    func unregister(_ track: FullTrackName, id: UUID) {
        let closed: [Lane] = lock.withLock {
            guard tracks[track]?.id == id else { return [] }
            tracks.removeValue(forKey: track)
            return lanes.keys.compactMap { lanes[$0]?.removeValue(forKey: track) }
        }
        for lane in closed { lane.close() }
    }

    /// Start copying every registered track onto `session`, for `peer`.
    func attach(_ peer: String, _ session: MoqtSession) async {
        let published = lock.withLock {
            sessions[peer] = session
            lanes[peer] = [:]
            return tracks
        }
        for (track, registration) in published {
            await open(track, priority: registration.priority, on: session, for: peer)
        }
    }

    func detach(_ peer: String) {
        let closed = lock.withLock {
            sessions.removeValue(forKey: peer)
            return lanes.removeValue(forKey: peer) ?? [:]
        }
        for lane in closed.values { lane.close() }
    }

    func send(_ object: TrackObject, on track: FullTrackName) {
        let targets = lock.withLock { lanes.values.compactMap { $0[track] } }
        for lane in targets { lane.send(object) }
    }

    var peers: Set<String> { lock.withLock { Set(sessions.keys) } }

    private func open(_ track: FullTrackName, priority: UInt8, on session: MoqtSession, for peer: String) async {
        guard let writer = try? await session.publish(track, priority: priority) else { return }
        let lane = Lane(writer)
        let kept = lock.withLock { () -> Bool in
            guard sessions[peer] === session, tracks[track] != nil else { return false }
            lanes[peer, default: [:]][track]?.close()
            lanes[peer, default: [:]][track] = lane
            return true
        }
        if !kept { lane.close() }
    }
}

/// A media writer that also hands each object to the room's direct sessions.
final class DirectTeeWriter: TrackWriter {
    let track: FullTrackName
    private let relay: any TrackWriter
    private let fanout: DirectFanout
    private let registration: UUID

    init(relay: any TrackWriter, fanout: DirectFanout, registration: UUID) {
        track = relay.track
        self.relay = relay
        self.fanout = fanout
        self.registration = registration
    }

    func write(_ object: TrackObject) async throws(MoqomError) {
        fanout.send(object, on: track)
        try await relay.write(object)
    }

    func startGroup(_ group: UInt64) async throws(MoqomError) {
        // A direct session's track starts each group from the objects' own
        // numbers, so only the relay needs telling.
        try await relay.startGroup(group)
    }

    func finish() async {
        fanout.unregister(track, id: registration)
        await relay.finish()
    }
}

// MARK: - Receiving over both paths

/// How many of one participant's objects each path delivered.
final class DirectCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var direct = 0
    private var relay = 0

    func count(_ path: DirectPath) {
        lock.withLock {
            switch path {
            case .direct: direct += 1
            case .relay: relay += 1
            }
        }
    }

    var counts: (direct: Int, relay: Int) { lock.withLock { (direct, relay) } }
}

/// A relay subscription read through a ``DualSubscription``, so the room's
/// pumps take whichever path delivers each object first without knowing there
/// are two.
///
/// The relay handle stays the room's subscription of record: a joining fetch
/// is resolved against it, and it is what keeps this one alive.
final class DirectMergedSubscription: SubscriptionHandle {
    let track: FullTrackName
    let priority: UInt8
    let dual: DualSubscription
    let objects: AsyncStream<TrackObject>
    private let relay: any SubscriptionHandle

    init(relay: any SubscriptionHandle, priority: UInt8, settings: DirectPathSettings, counter: DirectCounter) {
        track = relay.track
        self.priority = priority
        self.relay = relay
        let dual = DualSubscription(relay: relay, settings: settings)
        self.dual = dual
        let deliveries = dual.deliveries
        objects = AsyncStream { continuation in
            let reader = Task {
                for await delivery in deliveries {
                    counter.count(delivery.path)
                    continuation.yield(delivery.object)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in reader.cancel() }
        }
    }

    func updatePriority(_ priority: UInt8) async {
        await relay.updatePriority(priority)
    }

    func cancel() async {
        await dual.cancel()
    }
}

#if canImport(Network)

    /// What a room borrows from its ``MoqomSession`` to open direct paths.
    struct RoomDirectHooks: Sendable {
        /// The credentials in force, presented to a direct peer as to the relay.
        let credentials: @Sendable () async -> DeviceCredentials?
        /// ``MoqomSession/bindDirectEndpoint(_:eligibility:exposure:)``, on the
        /// session's backend.
        let bind: @Sendable (
            DirectConfiguration, DirectEligibility, DirectIPExposure
        ) async throws(DirectEndpointError) -> DirectEndpoint
    }

    /// What the room is, as far as direct paths are concerned, gathered by the
    /// room each time something in it changes.
    struct DirectRoomView: Equatable, Sendable {
        /// The room requires end-to-end encryption and this device has it.
        var encrypted = false
        /// This device is publishing on stage.
        var publishing = false
        /// A watchdog is attached to the room.
        var watchdogs = false
        /// Everyone else on stage.
        var peers: Set<ParticipantIdentity> = []
        /// Those of them whose catalog says they opted in.
        var optedIn: Set<ParticipantIdentity> = []
        /// The room's MLS group, as `user/device`. Every device holding the
        /// offer key counts as a participant, viewers included, because each
        /// of them could open an offer.
        var members: Set<String>?
        /// The offer key's material, `nil` until there is one.
        var secret: Data?
    }

    /// Direct paths for one room: offers, establishment, tickets, and teardown.
    actor RoomDirectPaths {
        /// How often an offer is sent again while its peer has not answered.
        static let resend: Duration = .seconds(1)
        static let maximumBackoff: Duration = .seconds(60)

        let options: DirectRoomOptions
        nonisolated let me: String
        nonisolated let fanout: DirectFanout
        private let tenant: TenantID
        private let room: RoomID
        private let identity: ParticipantIdentity
        private let hooks: RoomDirectHooks
        private let logger: MoqomLogger
        private var relay: any TransportSession
        private weak var owner: RoomSession?

        private var view = DirectRoomView()
        private var offers: DirectOffers?
        private var offerKey: Data?
        private var generation = 0
        private var peers: [ParticipantIdentity: Peer] = [:]
        private var stopped = false

        private struct Link {
            let session: DirectSession
            let certificate: Data
            let enforcement: DirectTicketGuard
            let tickets: any SubscriptionHandle
            let watcher: Task<Void, Never>
        }

        private struct Peer {
            var state: DirectPathState?
            /// Bumped by every attempt and every teardown, so a result from an
            /// attempt that has since been abandoned is recognised as such.
            var attempt = 0
            var endpoint: DirectEndpoint?
            var sender: Task<Void, Never>?
            var establishing: Task<Void, Never>?
            var reader: Task<Void, Never>?
            var retry: Task<Void, Never>?
            /// The newest offer the peer has addressed to this device.
            var newest: CandidateOffer?
            /// Certificates already established against. Each endpoint makes a
            /// fresh one, so an offer is never worth a second try.
            var tried: Set<Data> = []
            var link: Link?
            var failures = 0
            /// An endpoint is being bound for the current attempt.
            var binding = false

            var isIdle: Bool { link == nil && endpoint == nil && retry == nil && !binding }
        }

        init(
            options: DirectRoomOptions,
            tenant: TenantID,
            room: RoomID,
            identity: ParticipantIdentity,
            relay: any TransportSession,
            hooks: RoomDirectHooks,
            fanout: DirectFanout,
            owner: RoomSession,
            logger: MoqomLogger
        ) {
            self.options = options
            self.tenant = tenant
            self.room = room
            self.identity = identity
            self.relay = relay
            self.hooks = hooks
            self.fanout = fanout
            self.owner = owner
            self.logger = logger
            me = DirectParticipant.name(of: identity)
        }

        // MARK: - What the room says

        func update(_ next: DirectRoomView) async {
            guard !stopped, next != view else { return }
            view = next
            await reconcile()
        }

        /// The room moved to a new relay session. Everything opened on the old
        /// one is gone, so every path ends and starts again from the new one.
        func rebind(to connection: any TransportSession) async {
            for who in peers.keys {
                await teardown(who)
                peers[who]?.reader?.cancel()
                peers[who]?.reader = nil
                await setState(who, .relay(.lost))
            }
            offers = nil
            offerKey = nil
            relay = connection
            view = DirectRoomView()
        }

        /// Direct mode is off, or the room is over.
        func stop() async {
            stopped = true
            for who in peers.keys {
                await teardown(who)
                peers[who]?.reader?.cancel()
            }
            peers.removeAll()
            await offers?.close()
            offers = nil
        }

        /// The live direct session to `who`, for tests.
        func session(with who: ParticipantIdentity) -> DirectSession? {
            peers[who]?.link?.session
        }

        private func reconcile() async {
            for gone in peers.keys where !view.peers.contains(gone) {
                await teardown(gone)
                peers[gone]?.reader?.cancel()
                peers.removeValue(forKey: gone)
            }

            if let refusal = refusal() {
                for who in peers.keys {
                    await teardown(who)
                    peers[who]?.reader?.cancel()
                    peers[who]?.reader = nil
                    peers[who]?.failures = 0
                }
                for who in view.peers {
                    if peers[who] == nil { peers[who] = Peer() }
                    await setState(who, .relay(refusal))
                }
                if offers != nil {
                    await offers?.close()
                    offers = nil
                    offerKey = nil
                }
                return
            }

            if let key = view.secret, key != offerKey { rekey(key) }
            for who in view.peers.sorted(by: { DirectParticipant.name(of: $0) < DirectParticipant.name(of: $1) }) {
                if peers[who] == nil { peers[who] = Peer() }
                if peers[who]?.reader == nil { peers[who]?.reader = reading(who) }
                if peers[who]?.isIdle == true { await begin(who) }
            }
        }

        /// Why the room may not use direct paths right now, or `nil` if it may.
        private func refusal() -> DirectFallback? {
            let others = Set(view.peers.map(DirectParticipant.name(of:)))
            let everyone = others.union(view.members ?? []).union([me])
            let opted = Set(view.optedIn.map(DirectParticipant.name(of:)))
            do throws(DirectIneligibility) {
                try eligibility(participants: everyone.count, optedIn: everyone.subtracting([me]).isSubset(of: opted))
                    .check()
            } catch {
                return .ineligible(error)
            }
            return view.secret == nil ? .awaitingKeys : nil
        }

        private func eligibility(participants: Int, optedIn: Bool) -> DirectEligibility {
            DirectEligibility(
                endToEndEncrypted: view.encrypted,
                participants: participants,
                everyoneOptedIn: optedIn,
                watchdogRequired: view.watchdogs,
                audience: !view.publishing
            )
        }

        // MARK: - Offers

        private func rekey(_ key: Data) {
            // Closed before the next is opened: both publish the same track, and
            // closing the old one afterwards would retire the new one with it.
            let old = offers
            offers = nil
            generation += 1
            offerKey = key
            guard let secret = try? DirectRoomSecret(secret: key, tenant: tenant, room: room) else { return }
            let next = DirectOffers(
                tenant: tenant,
                room: room,
                identity: identity,
                connection: relay,
                secret: secret,
                announces: false
            )
            Task { await old?.close() }
            offers = next
            for who in peers.keys {
                peers[who]?.reader?.cancel()
                peers[who]?.reader = reading(who)
            }
            logger.debug(.room, "direct offers keyed", [LogField("generation", .number(generation))])
        }

        private func reading(_ who: ParticipantIdentity) -> Task<Void, Never>? {
            guard let offers else { return nil }
            let generation = generation
            return Task { [weak self] in
                guard let stream = try? await offers.offers(from: who) else { return }
                for await offer in stream {
                    await self?.received(offer, from: who, generation: generation)
                }
            }
        }

        private func send(_ offer: CandidateOffer) async {
            try? await offers?.send(offer)
        }

        private func received(_ offer: CandidateOffer, from who: ParticipantIdentity, generation offered: Int) async {
            guard offered == generation, var peer = peers[who], !peer.tried.contains(offer.certificate) else { return }
            peer.newest = offer
            peers[who] = peer
            if let link = peer.link {
                guard offer.certificate != link.certificate else { return }
                // The peer has bound afresh, so its end of this path is gone or
                // going; meet it on the new one rather than wait to notice.
                await linkEnded(who, attempt: peer.attempt, .lost)
                await retryNow(who)
                return
            }
            if let endpoint = peer.endpoint {
                if peer.establishing == nil { establish(who, offer, on: endpoint, attempt: peer.attempt) }
            } else if peer.retry != nil {
                // Waiting out a backoff while the peer is trying now.
                await retryNow(who)
            }
        }

        // MARK: - Attempts

        private func configuration() -> DirectConfiguration {
            var configuration = DirectConfiguration(tenant: tenant.value, room: room.value, me: me)
            configuration.advertisedHost = options.advertisedHost
            configuration.stun = options.stun
            configuration.patience = options.patience
            return configuration
        }

        private func begin(_ who: ParticipantIdentity) async {
            guard !stopped, refusal() == nil, var peer = peers[who], peer.isIdle else { return }
            peer.attempt += 1
            peer.binding = true
            let attempt = peer.attempt
            peers[who] = peer
            await setState(who, .connecting)

            let everyone = Set(view.peers.map(DirectParticipant.name(of:))).union(view.members ?? []).union([me])
            let bind = hooks.bind
            let configuration = configuration()
            let eligibility = eligibility(participants: everyone.count, optedIn: true)
            let exposure = options.exposure
            // A task of its own, because binding waits on the listener and the
            // caller may be a task that is cancelled later: an offer reader on a
            // new epoch, a backoff timer, the room's refresh.
            Task { [weak self] in
                let result: Result<DirectEndpoint, DirectEndpointError>
                do throws(DirectEndpointError) {
                    result = .success(try await bind(configuration, eligibility, exposure))
                } catch {
                    result = .failure(error)
                }
                guard let self else {
                    if case let .success(endpoint) = result { endpoint.close() }
                    return
                }
                await self.bound(who, attempt: attempt, result)
            }
        }

        private func bound(
            _ who: ParticipantIdentity,
            attempt: Int,
            _ result: Result<DirectEndpoint, DirectEndpointError>
        ) async {
            let current = !stopped && peers[who]?.attempt == attempt
            if current { peers[who]?.binding = false }
            let endpoint: DirectEndpoint
            switch result {
            case let .failure(error):
                if current { await failed(who, attempt: attempt, .failed(error)) }
                return
            case let .success(bound):
                guard current else {
                    bound.close()
                    return
                }
                endpoint = bound
            }
            peers[who]?.endpoint = endpoint
            let offer = endpoint.offer(to: DirectParticipant.name(of: who))
            peers[who]?.sender = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.send(offer)
                    try? await Task.sleep(for: Self.resend)
                }
            }
            if let newest = peers[who]?.newest, peers[who]?.tried.contains(newest.certificate) == false {
                establish(who, newest, on: endpoint, attempt: attempt)
            }
        }

        private func establish(_ who: ParticipantIdentity, _ offer: CandidateOffer, on endpoint: DirectEndpoint, attempt: Int) {
            peers[who]?.tried.insert(offer.certificate)
            let credentials = hooks.credentials
            let verifier = DirectPeerCheck(keys: options.tokenKeys, issuer: options.issuer)
            peers[who]?.establishing = Task { [weak self] in
                let result: Result<DirectSession, DirectEndpointError>
                if let presented = await credentials() {
                    do throws(DirectEndpointError) {
                        result = .success(try await endpoint.establish(
                            offer: offer, credentials: presented, verifier: verifier
                        ))
                    } catch {
                        result = .failure(error)
                    }
                } else {
                    result = .failure(.busy)
                }
                await self?.established(who, attempt: attempt, certificate: offer.certificate, result)
            }
        }

        private func established(
            _ who: ParticipantIdentity,
            attempt: Int,
            certificate: Data,
            _ result: Result<DirectSession, DirectEndpointError>
        ) async {
            guard !stopped, peers[who]?.attempt == attempt else {
                if case let .success(session) = result { await session.session.close(code: 0, reason: "abandoned") }
                return
            }
            peers[who]?.establishing = nil
            switch result {
            case let .failure(error):
                logger.info(.room, "direct path not opened", [
                    LogField("participant", .participant(who)),
                    LogField("reason", .text(error.description)),
                ])
                await failed(who, attempt: attempt, .failed(error))
            case let .success(session):
                await link(who, session, certificate: certificate, attempt: attempt)
            }
        }

        private func link(_ who: ParticipantIdentity, _ direct: DirectSession, certificate: Data, attempt: Int) async {
            peers[who]?.sender?.cancel()
            peers[who]?.sender = nil
            let peerName = DirectParticipant.name(of: who)

            // Holding this subscription is what the relay meters, so it is
            // opened only once there is a path to meter and closed with it.
            let feed: (tickets: AsyncStream<DirectTicket>, subscription: any SubscriptionHandle)
            do {
                let slot = try MoqomNamespaces.participant(tenant: tenant, room: room, identity: identity)
                feed = try await DirectTicketFeed.request(from: relay, slot: slot, peer: peerName)
            } catch {
                await direct.session.close(code: 0, reason: "no direct tickets")
                await failed(who, attempt: attempt, .ticketsUnavailable)
                return
            }
            guard !stopped, peers[who]?.attempt == attempt else {
                await feed.subscription.cancel()
                await direct.session.close(code: 0, reason: "abandoned")
                return
            }

            let enforcement = DirectTicketGuard(
                direct: direct, me: me, tickets: feed.tickets, settings: options.tickets
            ) { [weak self] reason in
                await self?.linkEnded(who, attempt: attempt, .ticket(reason))
            }
            let interruptions = direct.session.interruptions
            let watcher = Task { [weak self] in
                for await _ in interruptions {}
                // The guard closes the session before it reports why, so the
                // close can arrive here first.
                let refusal = await enforcement.ended
                await self?.linkEnded(who, attempt: attempt, refusal.map(DirectFallback.ticket) ?? .lost)
            }
            peers[who]?.link = Link(
                session: direct,
                certificate: certificate,
                enforcement: enforcement,
                tickets: feed.subscription,
                watcher: watcher
            )
            peers[who]?.failures = 0
            await fanout.attach(peerName, direct.session)
            await owner?.directSessionChanged(who, direct.session)
            logger.info(.room, "direct path open", [LogField("participant", .participant(who))])
            await setState(who, .direct)
        }

        private func linkEnded(_ who: ParticipantIdentity, attempt: Int, _ reason: DirectFallback) async {
            guard peers[who]?.attempt == attempt, peers[who]?.link != nil else { return }
            logger.info(.room, "direct path ended", [
                LogField("participant", .participant(who)),
                LogField("reason", .text(reason.description)),
            ])
            await teardown(who)
            peers[who]?.failures += 1
            await setState(who, .relay(reason))
            scheduleRetry(who)
        }

        private func failed(_ who: ParticipantIdentity, attempt: Int, _ reason: DirectFallback) async {
            guard peers[who]?.attempt == attempt else { return }
            await teardown(who)
            peers[who]?.failures += 1
            await setState(who, .relay(reason))
            scheduleRetry(who)
        }

        private func scheduleRetry(_ who: ParticipantIdentity) {
            guard !stopped, let failures = peers[who]?.failures else { return }
            let delay = min(options.retry * (1 << min(max(failures - 1, 0), 16)), Self.maximumBackoff)
            peers[who]?.retry = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                // Not cancelled on the way, since the attempt runs in this task.
                await self?.retryNow(who, cancelling: false)
            }
        }

        private func retryNow(_ who: ParticipantIdentity, cancelling: Bool = true) async {
            guard peers[who]?.link == nil, peers[who]?.endpoint == nil else { return }
            if cancelling { peers[who]?.retry?.cancel() }
            peers[who]?.retry = nil
            await begin(who)
        }

        /// End whatever is open to `who`, leaving the relay as it is.
        private func teardown(_ who: ParticipantIdentity) async {
            guard var peer = peers[who] else { return }
            peer.attempt += 1
            peer.binding = false
            peer.sender?.cancel()
            peer.sender = nil
            peer.establishing?.cancel()
            peer.establishing = nil
            peer.retry?.cancel()
            peer.retry = nil
            let link = peer.link
            let endpoint = peer.endpoint
            peer.link = nil
            peer.endpoint = nil
            peers[who] = peer

            if let link {
                fanout.detach(DirectParticipant.name(of: who))
                await owner?.directSessionChanged(who, nil)
                await link.enforcement.stop()
                await link.tickets.cancel()
                link.watcher.cancel()
                await link.session.session.close(code: 0, reason: "direct path ended")
            }
            endpoint?.close()
        }

        private func setState(_ who: ParticipantIdentity, _ state: DirectPathState) async {
            guard peers[who] != nil, peers[who]?.state != state else { return }
            peers[who]?.state = state
            await owner?.directStateChanged(who, state)
        }
    }

#endif
