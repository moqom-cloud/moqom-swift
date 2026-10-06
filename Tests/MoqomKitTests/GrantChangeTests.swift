// A participant's grants changing on the session they already have.
//
// A viewer promoted to guest, or a guest returned to the audience, stays on the
// connection they were watching on: the backend mints a token for the new role
// and the app presents it. What is covered here is the client's half — that the
// token reaches the open connection rather than a new one, that the renewal that
// follows mints the new role rather than the old, and that a publication the
// relay withdraws is stopped rather than left encoding into nothing.
//
// The relay's half, including what a renewal may and may not change, is the
// relay's `grants.rs`.

import Foundation
import Testing

@testable import MoqomCore
@testable import MoqomKit
@testable import MoqomLoopback

/// What happened to the connections a session dialled, from outside it.
private actor Wire {
    private(set) var dials = 0
    private(set) var presented: [Data] = []
    private var revocations: [CheckedContinuation<Void, Never>] = []
    private var revoked = false

    func dialled() { dials += 1 }
    func present(_ token: Data) { presented.append(token) }

    /// End every announcement the way a relay does when grants change.
    func revoke() {
        revoked = true
        for waiting in revocations { waiting.resume() }
        revocations.removeAll()
    }

    func untilRevoked() async {
        if revoked { return }
        await withCheckedContinuation { revocations.append($0) }
    }
}

/// A token for the new role, with the claims the SDK reads.
private func issued(_ name: String, lasting seconds: TimeInterval = 900) -> IssuedToken {
    IssuedToken(
        token: testToken(subject: name, e2ee: .optional),
        expiresAt: Date().addingTimeInterval(seconds),
        username: name,
        room: "room-42"
    )
}

/// Collects a room's events, so a test can wait for one without being the
/// stream's only reader forever.
private actor Events {
    private(set) var seen: [RoomEvent] = []
    func append(_ event: RoomEvent) { seen.append(event) }

    var revoked: [MediaKind] {
        seen.compactMap { event in
            if case let .publishingRevoked(kinds) = event { return kinds }
            return nil
        }
    }

    var interrupted: Bool {
        seen.contains { event in
            if case .broadcastInterrupted = event { return true }
            return false
        }
    }
}

@Suite("Grants changing on a live session")
struct GrantChangeTests {
    private let endpoint = RelayEndpoint(host: "loopback", alpn: ["moqt-19"])

    @Test("a token for a new role is presented on the open connection")
    func promotionDoesNotReconnect() async throws {
        let wire = Wire()
        let session = MoqomSession(
            transport: WireTransport(relay: LoopbackRelay(), wire: wire),
            credentials: credentials("bob"),
            tenant: "acme",
            clock: { .zero },
            sleeper: { _ in }
        )
        try await session.connect(to: endpoint)
        let room = try await session.join(room: "room-42")

        let guest = issued("bob")
        try await room.updateCredential(guest)

        #expect(await wire.presented == [guest.token])
        #expect(await wire.dials == 1, "a promotion must not reconnect")
        #expect(await session.state == .established)

        // Promoted means able to go live in the room already joined, not in a
        // new one.
        let publication = try await room.startAudio(
            from: AudioRelay(depth: 4),
            configuration: AudioPublicationConfiguration(
                encoderFactory: { SyntheticAudioEncoder(configuration: $0) }
            )
        )
        await publication.stop()
        #expect(await wire.dials == 1)

        await session.close()
    }

    /// The footgun this parameter exists to close: a renewal closure still
    /// minting the old role would hand it back at the next renewal, and a relay
    /// would apply it — quietly undoing the promotion a few minutes later.
    @Test("the renewal after a promotion mints the new role")
    func renewalFollowsThePromotion() async throws {
        let wire = Wire()
        let session = MoqomSession(
            transport: WireTransport(relay: LoopbackRelay(), wire: wire),
            credentials: DeviceCredentials(
                identity: identity("bob"),
                token: testToken(subject: "bob", e2ee: .optional),
                deviceKey: nil,
                expiresAt: Date().addingTimeInterval(3600),
                renew: { issued("viewer") }
            ),
            tenant: "acme",
            clock: { .zero },
            sleeper: { _ in }
        )
        try await session.connect(to: endpoint)

        // Inside the renewal margin, so the next renewal is due at once.
        let guest = issued("bob", lasting: 30)
        let renewed = issued("guest")
        try await session.updateCredential(guest, renewingWith: { renewed })

        #expect(await eventually { await wire.presented.count >= 2 })
        let presented = await wire.presented
        #expect(presented.first == guest.token)
        #expect(presented.dropFirst().allSatisfy { $0 == renewed.token })

        await session.close()
    }

    /// The demotion half. The relay has already withdrawn the announcement and
    /// stopped asking for media; what is left for the client is to stop the
    /// hardware and say so. And nothing else: the session, the room and its
    /// roster stay as they were.
    @Test("a publication the relay revokes is stopped, and the room carries on")
    func demotionStopsPublishing() async throws {
        let wire = Wire()
        let session = MoqomSession(
            transport: WireTransport(relay: LoopbackRelay(), wire: wire),
            credentials: credentials("bob"),
            tenant: "acme",
            clock: { .zero },
            sleeper: { _ in }
        )
        try await session.connect(to: endpoint)
        let room = try await session.join(room: "room-42")
        let events = Events()
        let reader = Task {
            for await event in room.events { await events.append(event) }
        }
        defer { reader.cancel() }

        let source = AudioRelay(depth: 4)
        let publication = try await room.startAudio(
            from: source,
            configuration: AudioPublicationConfiguration(
                encoderFactory: { SyntheticAudioEncoder(configuration: $0) }
            )
        )

        await wire.revoke()

        #expect(await eventually { await events.revoked == [.audio] })
        // Not reported as the failure that asks the app to restart publishing.
        #expect(await !events.interrupted)
        // Stopped, so a second start is a new publication rather than the same
        // one handed back.
        let again = try await room.startAudio(
            from: AudioRelay(depth: 4),
            configuration: AudioPublicationConfiguration(
                encoderFactory: { SyntheticAudioEncoder(configuration: $0) }
            )
        )
        #expect(again !== publication)
        #expect(await wire.dials == 1, "a demotion must not reconnect")
        #expect(await session.state == .established)

        await session.close()
    }
}

/// A loopback transport whose announcements a test can revoke, and whose
/// sessions record the credentials handed to them.
///
/// Wraps rather than replaces, so everything else about the session under test
/// is the real loopback behaviour. The loopback has no grants to change, so the
/// revocation is the one thing this has to supply.
private struct WireTransport: Transport {
    let relay: LoopbackRelay
    let wire: Wire

    func connect(
        to endpoint: RelayEndpoint,
        credentials: DeviceCredentials
    ) async throws(MoqomError) -> any TransportSession {
        await wire.dialled()
        let inner = try await LoopbackTransport(relay: relay)
            .connect(to: endpoint, credentials: credentials)
        return WireSession(inner: inner, wire: wire)
    }
}

private final class RevocableAnnouncement: AnnouncementHandle {
    private let inner: any AnnouncementHandle
    private let wire: Wire

    init(inner: any AnnouncementHandle, wire: Wire) {
        self.inner = inner
        self.wire = wire
    }

    var namespace: TrackNamespace { inner.namespace }

    var refusal: MoqomError? {
        get async {
            await wire.untilRevoked()
            return .rejected(.revoked(inner.namespace))
        }
    }

    func withdraw() async { await inner.withdraw() }
}

private final class WireSession: TransportSession {
    private let inner: any TransportSession
    private let wire: Wire

    init(inner: any TransportSession, wire: Wire) {
        self.inner = inner
        self.wire = wire
    }

    func renewCredential(_ token: Data) async throws(MoqomError) {
        await wire.present(token)
    }

    var negotiated: NegotiatedParameters {
        get async { await inner.negotiated }
    }

    var interruptions: AsyncStream<TransportFailure> { inner.interruptions }
    var offers: AsyncStream<TrackOffer> { inner.offers }

    func announce(
        _ namespace: TrackNamespace
    ) async throws(MoqomError) -> any AnnouncementHandle {
        RevocableAnnouncement(inner: try await inner.announce(namespace), wire: wire)
    }

    func announcements(
        matching prefix: TrackNamespace
    ) async throws(MoqomError) -> AsyncStream<AnnouncementEvent> {
        try await inner.announcements(matching: prefix)
    }

    func subscribe(
        _ request: SubscribeRequest
    ) async throws(MoqomError) -> any SubscriptionHandle {
        try await inner.subscribe(request)
    }

    func fetch(_ request: FetchRequest) async throws(MoqomError) -> any FetchHandle {
        try await inner.fetch(request)
    }

    func publish(
        _ track: FullTrackName,
        priority: UInt8
    ) async throws(MoqomError) -> any TrackWriter {
        try await inner.publish(track, priority: priority)
    }

    func close(code: UInt64, reason: String) async {
        await inner.close(code: code, reason: reason)
    }
}
