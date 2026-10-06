// Exchanging candidate offers over the room, through the relay that cannot
// read them.
//
// No signalling server and nothing new at the relay: each participant publishes
// its sealed offers on a track of its own, under its own stage namespace, which
// is a name the relay already lets it publish and lets the room read. A peer
// subscribes to that track the way it subscribes to a camera, opens what is
// addressed to it, and ignores the rest. Viewers in the room can fetch the
// bytes and cannot open them.

import Foundation
import MoqomCore

/// One participant's side of the offer exchange.
public actor DirectOffers {
    /// The track offers travel on, beside the participant's media.
    public static let trackName = ".direct"

    /// Behind control and media: an offer is worth a few hundred milliseconds of
    /// patience, and a stalled frame is not.
    public static let priority: UInt8 = 32

    public nonisolated let identity: ParticipantIdentity
    private let tenant: TenantID
    private let room: RoomID
    private let connection: any TransportSession
    private let secret: DirectRoomSecret

    private var writer: (any TrackWriter)?
    private var announcement: (any AnnouncementHandle)?
    private var group: UInt64 = 0

    public init(
        tenant: TenantID,
        room: RoomID,
        identity: ParticipantIdentity,
        connection: any TransportSession,
        secret: DirectRoomSecret
    ) {
        self.tenant = tenant
        self.room = room
        self.identity = identity
        self.connection = connection
        self.secret = secret
    }

    /// The name offers to this device are addressed by.
    public nonisolated var me: String { DirectParticipant.name(of: identity) }

    /// Publish `offer`, sealed, for its addressee to read.
    ///
    /// A group per offer, so a subscriber starting at the latest group reads the
    /// newest one and never an offer for a network this device has left.
    public func send(_ offer: CandidateOffer) async throws(MoqomError) {
        let sealed: Data
        do {
            sealed = try offer.sealed(with: secret)
        } catch {
            throw MoqomError.invalidState(expected: "a sealable offer", actual: "\(error)")
        }
        let writer = try await openWriter()
        group += 1
        try await writer.startGroup(group)
        try await writer.write(TrackObject(
            group: group,
            object: 0,
            priority: Self.priority,
            payload: sealed,
            isKeyFrame: true
        ))
    }

    /// Offers `peer` has addressed to this device, opened, newest last.
    ///
    /// Anything that does not open — another participant's offer, a forgery, a
    /// different room's secret — is skipped without comment: on a shared track
    /// most objects are somebody else's.
    public func offers(from peer: ParticipantIdentity) async throws(MoqomError) -> AsyncStream<CandidateOffer> {
        let track: FullTrackName
        do {
            track = try FullTrackName(
                namespace: MoqomNamespaces.participant(tenant: tenant, room: room, identity: peer),
                name: TrackName(Self.trackName)
            )
        } catch {
            throw MoqomError.invalidName(error)
        }
        let subscription = try await connection.subscribe(
            SubscribeRequest(track: track, priority: Self.priority, start: .latestGroup)
        )
        let secret = secret
        let me = me
        let sender = DirectParticipant.name(of: peer)
        return AsyncStream { continuation in
            let reader = Task {
                for await object in subscription.objects {
                    guard
                        let offer = try? CandidateOffer(opening: object.payload, with: secret, for: me),
                        offer.from == sender
                    else { continue }
                    continuation.yield(offer)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                reader.cancel()
                Task { await subscription.cancel() }
            }
        }
    }

    /// Stop publishing offers.
    public func close() async {
        await writer?.finish()
        writer = nil
        await announcement?.withdraw()
        announcement = nil
    }

    private func openWriter() async throws(MoqomError) -> any TrackWriter {
        if let writer { return writer }
        let namespace: TrackNamespace
        let track: FullTrackName
        do {
            namespace = try MoqomNamespaces.participant(tenant: tenant, room: room, identity: identity)
            track = try FullTrackName(namespace: namespace, name: TrackName(Self.trackName))
        } catch {
            throw MoqomError.invalidName(error)
        }
        // Announcements are per namespace and refcounted, so this is harmless
        // beside a broadcast that already announced the same one.
        announcement = try await connection.announce(namespace)
        let opened = try await connection.publish(track, priority: Self.priority)
        writer = opened
        return opened
    }
}
