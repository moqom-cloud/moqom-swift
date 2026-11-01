// Direct tickets: what keeps a direct path honest about the relay session
// beside it.
//
// Direct time is billed, and direct media never touches a relay, so a relay
// cannot count it. What it counts is tickets: while a participant is on a
// direct path it holds a subscription to its own `.direct/{peer}` track on its
// relay, and the relay answers with a signed ticket about once a minute and
// meters the time (`moqom_relay::ticket`). Each side presents its tickets to
// the other over the direct session, and each ends the direct path when the
// other's ticket is missing, does not verify or runs out, falling back to the
// relay. An app that drops its relay session therefore loses its direct path
// as well; only two modified apps that both skip the check could keep one.
//
// A ticket is checked as a token is, an ML-DSA-65 compact JWS by `kid`, against a
// separate set of keys: the ticket keys, which each side takes from the ticket
// objects its own relay sends. A key the peer handed over would prove nothing.

import CryptoKit
import Foundation
import MoqomCore

/// A ticket, as the relay issued it to this participant.
public struct DirectTicket: Hashable, Sendable {
    /// The compact JWS, presented to the peer as is.
    public let compact: Data
    /// When it stops being accepted, before clock skew.
    public let expires: Date
    /// The relay's ticket keys, which the peer's tickets are checked against.
    public let keys: [DirectVerificationKey]

    public init(compact: Data, expires: Date, keys: [DirectVerificationKey]) {
        self.compact = compact
        self.expires = expires
        self.keys = keys
    }

    /// Read one object of the relay's ticket track.
    public init(object payload: Data) throws(DirectTicketRefusal) {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              object["version"] as? Int == 1,
              let ticket = object["ticket"] as? String,
              let expires = object["expires"] as? Int64,
              let keyList = object["keys"] as? [Any],
              let keyDocument = try? JSONSerialization.data(withJSONObject: keyList),
              let keys = try? DirectVerificationKey.parseSet(keyDocument),
              !keys.isEmpty
        else { throw .malformed }
        self.init(
            compact: Data(ticket.utf8),
            expires: Date(timeIntervalSince1970: TimeInterval(expires)),
            keys: keys
        )
    }
}

/// Why a peer's ticket was refused. Every case ends the direct path.
public enum DirectTicketRefusal: Error, Hashable, Sendable, CustomStringConvertible {
    /// No ticket arrived in time.
    case missing
    /// Not a compact JWS, or not the relay's ticket object.
    case malformed
    /// Signed with another algorithm, or a token rather than a ticket.
    case unsupported
    /// Signed by a key outside this side's ticket keys.
    case unknownKey
    /// The signature does not verify.
    case badSignature
    /// Past its expiry, allowing for skew.
    case expired
    /// Issued in the future, allowing for skew.
    case notYetValid
    /// For another tenant, room or participant than the one verified at setup.
    case wrongHolder
    /// For a direct path to somebody else.
    case wrongPeer

    public var description: String {
        switch self {
        case .missing: "the peer presented no direct ticket"
        case .malformed: "the ticket is malformed"
        case .unsupported: "not a direct ticket"
        case .unknownKey: "the ticket's key is not a ticket key"
        case .badSignature: "the ticket's signature does not verify"
        case .expired: "the ticket has expired"
        case .notYetValid: "the ticket is not valid yet"
        case .wrongHolder: "the ticket names somebody other than the peer"
        case .wrongPeer: "the ticket is for a direct path to somebody else"
        }
    }
}

/// The relay's ticket check, `moqom_relay::ticket::verify`, in Swift.
public enum DirectTicketCheck {
    /// The JWS `typ` every ticket carries and a token never does.
    public static let type = "moqom-direct-ticket"
    /// Clock skew allowed between the issuing relay and this device.
    public static let clockSkew: TimeInterval = 30
    static let maximumBytes = 8192

    /// Check `ticket`, presented by `holder` on a direct path to `me`
    /// (`user/device`), and return when it expires.
    public static func verify(
        _ ticket: Data,
        keys: [DirectVerificationKey],
        holder: VerifiedDirectPeer,
        me: String,
        now: Date = Date(),
        skew: TimeInterval = clockSkew
    ) throws(DirectTicketRefusal) -> Date {
        struct Header: Decodable { let alg: String; let typ: String; let kid: String }
        struct Claims: Decodable {
            let ten: String
            let room: String
            let sub: String
            let dev: String
            let peer: String
            let iat: Int64
            let exp: Int64
        }

        guard ticket.count <= maximumBytes else { throw .malformed }
        let segments = ticket.split(separator: UInt8(ascii: "."), omittingEmptySubsequences: false)
        guard segments.count == 3,
              let headerBytes = Data(base64URLEncoded: Data(segments[0])),
              let signature = Data(base64URLEncoded: Data(segments[2])),
              let header = try? JSONDecoder().decode(Header.self, from: headerBytes)
        else { throw .malformed }
        guard header.typ == type else { throw .unsupported }
        guard let key = keys.first(where: { $0.id == header.kid }) else { throw .unknownKey }
        guard header.alg == key.algorithm.jose else { throw .unsupported }
        let signed = ticket.prefix(segments[0].count + 1 + segments[1].count)
        guard key.verifies(signature, for: Data(signed)) else { throw .badSignature }

        guard let claimsBytes = Data(base64URLEncoded: Data(segments[1])),
              let claims = try? JSONDecoder().decode(Claims.self, from: claimsBytes)
        else { throw .malformed }
        let expires = Date(timeIntervalSince1970: TimeInterval(claims.exp))
        if now.addingTimeInterval(-skew) > expires { throw .expired }
        if now.addingTimeInterval(skew) < Date(timeIntervalSince1970: TimeInterval(claims.iat)) {
            throw .notYetValid
        }
        guard claims.ten == holder.tenant, claims.room == holder.room,
              "\(claims.sub)/\(claims.dev)" == holder.participant
        else { throw .wrongHolder }
        guard claims.peer == me else { throw .wrongPeer }
        return expires
    }
}

/// The relay's tickets for one direct path, as a stream.
public enum DirectTicketFeed {
    /// The ticket track for a direct path to `peer` (`user/device`), under a
    /// participant's own stage slot, as the relay checks.
    public static func track(slot: TrackNamespace, peer: String) throws(NameError) -> FullTrackName {
        try FullTrackName(namespace: slot, name: TrackName(".direct/\(peer)"))
    }

    /// Ask the relay for tickets, and read each one it sends.
    ///
    /// Holding the subscription is what the relay meters, so cancel it the
    /// moment the direct path ends.
    public static func request(
        from relay: any TransportSession,
        slot: TrackNamespace,
        peer: String
    ) async throws(MoqomError) -> (tickets: AsyncStream<DirectTicket>, subscription: any SubscriptionHandle) {
        let track: FullTrackName
        do { track = try Self.track(slot: slot, peer: peer) } catch { throw .invalidName(error) }
        let subscription = try await relay.subscribe(SubscribeRequest(track: track))
        return (tickets(from: subscription.objects), subscription)
    }

    /// Ticket objects, read into tickets. One that does not parse is skipped:
    /// the next renewal replaces it, and the peer's patience covers the gap.
    public static func tickets(from objects: AsyncStream<TrackObject>) -> AsyncStream<DirectTicket> {
        AsyncStream { continuation in
            let reader = Task {
                for await object in objects {
                    if let ticket = try? DirectTicket(object: object.payload) {
                        continuation.yield(ticket)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in reader.cancel() }
        }
    }
}

/// How patient a ``DirectTicketGuard`` is.
public struct DirectTicketSettings: Hashable, Sendable {
    /// How long the peer has to present its first ticket.
    public var grace: Duration
    /// How often the current ticket is presented again, so a peer that
    /// subscribed late is not left waiting for the next renewal.
    public var represent: Duration
    /// Clock skew allowed on the peer's tickets.
    public var skew: Duration

    public init(grace: Duration = .seconds(10), represent: Duration = .seconds(5), skew: Duration = .seconds(30)) {
        self.grace = grace
        self.represent = represent
        self.skew = skew
    }
}

/// Presents this side's tickets to a direct peer and holds the peer to its
/// own, ending the direct session the moment the peer's lapse.
///
/// Ending the session is the whole of the enforcement: a ``DualSubscription``
/// reading the peer's media over it falls back to the relay and resumes the
/// relay's forwarding, as on any other loss.
///
/// A guard keeps itself alive until the path ends or ``stop()`` is called, so
/// dropping the reference does not quietly stop the enforcement.
public actor DirectTicketGuard {
    private let direct: DirectSession
    private let me: String
    private let settings: DirectTicketSettings
    private let onEnd: @Sendable (DirectTicketRefusal) async -> Void

    private var current: DirectTicket?
    private var presented = 0
    private var pending: Data?
    private var peerExpires: Date?
    private var tasks: [Task<Void, Never>] = []
    private var writer: (any TrackWriter)?
    private var peerSubscription: (any SubscriptionHandle)?
    private var deadline: ContinuousClock.Instant
    private var stopped = false

    /// Why the direct path was ended, once it has been.
    public private(set) var ended: DirectTicketRefusal?

    /// - Parameters:
    ///   - direct: the direct session to guard.
    ///   - me: this participant, as `user/device`.
    ///   - tickets: this participant's tickets from its own relay.
    public init(
        direct: DirectSession,
        me: String,
        tickets: AsyncStream<DirectTicket>,
        settings: DirectTicketSettings = DirectTicketSettings(),
        onEnd: @escaping @Sendable (DirectTicketRefusal) async -> Void = { _ in }
    ) {
        self.direct = direct
        self.me = me
        self.settings = settings
        self.onEnd = onEnd
        deadline = .now + settings.grace
        let feed = tickets
        Task { await self.start(feed) }
    }

    /// When the peer's current ticket runs out, if it has presented one.
    public var peerTicketExpires: Date? { peerExpires }

    private func start(_ feed: AsyncStream<DirectTicket>) async {
        guard ended == nil, !stopped else { return }
        // Tickets are only issued in a room, so a peer admitted without one
        // could never present a valid one.
        guard let room = direct.peer.room else {
            await end(.wrongHolder)
            return
        }
        let peer = direct.peer.participant
        guard let own = Self.track(tenant: direct.peer.tenant, room: room, holder: me, peer: peer),
              let theirs = Self.track(tenant: direct.peer.tenant, room: room, holder: peer, peer: me)
        else {
            await end(.malformed)
            return
        }
        writer = try? await direct.session.publish(own, priority: 0)
        guard ended == nil, !stopped else { return }

        tasks.append(Task {
            for await ticket in feed {
                await self.renewed(ticket, on: own)
            }
        })
        tasks.append(Task { await self.presentEvery(on: own) })
        tasks.append(Task { await self.watch(theirs) })
        tasks.append(Task { await self.enforce() })
    }

    /// Where `holder` presents its tickets on the direct session: the same
    /// slot-and-name shape as on the relay, so a capture of either reads alike.
    static func track(tenant: String, room: String, holder: String, peer: String) -> FullTrackName? {
        let parts = holder.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return try? FullTrackName(
            namespace: TrackNamespace([tenant, "r", room, parts[0], parts[1]]),
            name: TrackName(".direct/\(peer)")
        )
    }

    private func renewed(_ ticket: DirectTicket, on track: FullTrackName) async {
        current = ticket
        if let pending {
            self.pending = nil
            check(pending)
        }
        await present(on: track)
    }

    private func presentEvery(on track: FullTrackName) async {
        while ended == nil, !Task.isCancelled {
            // Until the first presentation lands, look often: the peer's grace
            // period is running from the moment it subscribes.
            try? await Task.sleep(for: presented == 0 ? .milliseconds(50) : settings.represent)
            if ended != nil { return }
            await present(on: track)
        }
    }

    /// Write the current ticket as a new group, once somebody is listening.
    private func present(on track: FullTrackName) async {
        guard let current, let writer,
              await direct.session.publishedTrack(track)?.hasSubscribers == true
        else { return }
        let group = UInt64(presented)
        presented += 1
        if group > 0 { try? await writer.startGroup(group) }
        try? await writer.write(TrackObject(group: group, object: 0, priority: 0, payload: current.compact))
    }

    /// Subscribe to the peer's ticket track, retrying while the peer has not
    /// published it yet, and check every ticket on it.
    private func watch(_ track: FullTrackName) async {
        while ended == nil, !Task.isCancelled, peerSubscription == nil {
            if let subscription = try? await direct.session.subscribe(SubscribeRequest(track: track)) {
                peerSubscription = subscription
                for await object in subscription.objects {
                    check(object.payload)
                    if ended != nil { return }
                }
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func check(_ ticket: Data) {
        guard ended == nil else { return }
        guard let keys = current?.keys else {
            // Nothing to check against until this side's own relay has said
            // what the ticket keys are; the newest one waits for that.
            pending = ticket
            return
        }
        do throws(DirectTicketRefusal) {
            let expires = try DirectTicketCheck.verify(
                ticket,
                keys: keys,
                holder: direct.peer,
                me: me,
                skew: settings.skew.timeInterval
            )
            if expires > (peerExpires ?? .distantPast) {
                peerExpires = expires
                deadline = .now + .seconds(expires.timeIntervalSinceNow) + settings.skew
            }
        } catch {
            Task { await self.end(error) }
        }
    }

    private func enforce() async {
        while ended == nil, !Task.isCancelled {
            let now = ContinuousClock.now
            if now >= deadline {
                await end(peerExpires == nil ? .missing : .expired)
                return
            }
            try? await Task.sleep(until: min(deadline, now + .milliseconds(250)), clock: .continuous)
        }
    }

    /// Stop presenting and watching, without ending the direct session: the
    /// direct path ended for another reason.
    public func stop() async {
        stopped = true
        for task in tasks { task.cancel() }
        tasks.removeAll()
        await peerSubscription?.cancel()
    }

    private func end(_ reason: DirectTicketRefusal) async {
        guard ended == nil else { return }
        ended = reason
        await stop()
        await direct.session.close(code: 0x03, reason: reason.description)
        await onEnd(reason)
    }
}

fileprivate extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
