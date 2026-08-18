// Keeping a session's credential fresh while it runs.
//
// The relay closes a session when the token that admitted it runs out, which it
// did not always do: `exp` was checked at SETUP and then discarded, so a token
// with a fifteen-minute life bounded the act of joining and nothing after it.
// Now that it is enforced, a call longer than a token's lifetime needs the token
// replaced without reconnecting — so these two behaviours are one feature, and
// this file covers the client's half of it.
//
// What is not covered here is the wire format, which is `MoqtSessionTests`, or
// the enforcement, which is the relay's `authorisation.rs`. This is about
// whether anybody remembers to renew.

import Foundation
import Testing

@testable import MoqomCore
@testable import MoqomKit
@testable import MoqomLoopback

/// What a renewing session did, from outside it.
private actor Ledger {
    private(set) var minted = 0
    private(set) var presented: [Data] = []

    /// Tokens the mint hands out, each named for how many have been asked for.
    func mint(lasting seconds: TimeInterval) -> IssuedToken {
        minted += 1
        return IssuedToken(
            token: Data("token-\(minted)".utf8),
            expiresAt: Date().addingTimeInterval(seconds),
            username: "bob",
            room: "room-42"
        )
    }

    func present(_ token: Data) { presented.append(token) }
}

@Suite("Renewing a credential")
struct CredentialRenewalTests {
    private let endpoint = RelayEndpoint(host: "loopback", alpn: ["moqt-19"])

    /// Credentials that expire inside the renewal margin, so the session renews
    /// at once rather than after the minutes a realistic token would take.
    private func expiring(soon: TimeInterval, from ledger: Ledger) -> DeviceCredentials {
        DeviceCredentials(
            identity: identity("bob"),
            token: Data("token-0".utf8),
            deviceKey: nil,
            expiresAt: Date().addingTimeInterval(soon),
            renew: { await ledger.mint(lasting: 900) }
        )
    }

    @Test("a session replaces its credential before the relay stops accepting it")
    func renewsBeforeExpiry() async throws {
        let ledger = Ledger()
        let session = MoqomSession(
            transport: RecordingTransport(relay: LoopbackRelay(), ledger: ledger),
            credentials: expiring(soon: 30, from: ledger),
            tenant: "acme",
            clock: { .zero },
            sleeper: { _ in }
        )
        try await session.connect(to: endpoint)

        // Handed to the connection, not merely fetched. Fetching alone would
        // leave the relay holding the old deadline and closing the session on it,
        // which is the failure that looks like a network fault to everybody
        // experiencing it.
        #expect(await eventually { await ledger.presented == [Data("token-1".utf8)] })

        await session.close()
    }

    /// The loop has to stop asking once it has bought time, and this is the test
    /// that would catch it not doing so. A credential inside the margin computes
    /// no wait at all — correct for the first attempt, and a request per round
    /// trip if it were also correct for every attempt after it.
    @Test("a session that has renewed stops asking")
    func doesNotSpin() async throws {
        let ledger = Ledger()
        let session = MoqomSession(
            transport: RecordingTransport(relay: LoopbackRelay(), ledger: ledger),
            credentials: expiring(soon: 30, from: ledger),
            tenant: "acme",
            clock: { .zero },
            sleeper: { _ in }
        )
        try await session.connect(to: endpoint)

        #expect(await eventually { await ledger.minted == 1 })
        try? await Task.sleep(for: .milliseconds(200))
        #expect(await ledger.minted == 1, "the renewal loop is minting on a spin")

        await session.close()
    }

    /// A caller that passes no renewal closure gets the behaviour it had before
    /// any of this existed. Worth asserting because the alternative — renewing
    /// from somewhere the caller did not nominate — is the kind of helpfulness
    /// that surprises somebody in production.
    @Test("a session with nothing to renew with renews nothing")
    func noRenewalWithoutAClosure() async throws {
        let ledger = Ledger()
        let session = MoqomSession(
            transport: RecordingTransport(relay: LoopbackRelay(), ledger: ledger),
            credentials: credentials("bob"),
            tenant: "acme",
            clock: { .zero },
            sleeper: { _ in }
        )
        try await session.connect(to: endpoint)

        try? await Task.sleep(for: .milliseconds(100))
        #expect(await ledger.minted == 0)
        #expect(await ledger.presented.isEmpty)

        await session.close()
    }
}

/// A loopback transport whose sessions record the credentials handed to them.
///
/// The loopback itself has no tokens and no expiry, so its sessions accept a
/// renewal and discard it — which is right for it and useless for asserting that
/// one happened. This wraps rather than replaces so that everything else about
/// the session under test is the real loopback behaviour.
private struct RecordingTransport: Transport {
    let relay: LoopbackRelay
    let ledger: Ledger

    func connect(
        to endpoint: RelayEndpoint,
        credentials: DeviceCredentials
    ) async throws(MoqomError) -> any TransportSession {
        let inner = try await LoopbackTransport(relay: relay)
            .connect(to: endpoint, credentials: credentials)
        return RecordingSession(inner: inner, ledger: ledger)
    }
}

private final class RecordingSession: TransportSession {
    private let inner: any TransportSession
    private let ledger: Ledger

    init(inner: any TransportSession, ledger: Ledger) {
        self.inner = inner
        self.ledger = ledger
    }

    func renewCredential(_ token: Data) async throws(MoqomError) {
        await ledger.present(token)
    }

    var negotiated: NegotiatedParameters {
        get async { await inner.negotiated }
    }

    var interruptions: AsyncStream<TransportFailure> { inner.interruptions }
    var offers: AsyncStream<TrackOffer> { inner.offers }

    func announce(
        _ namespace: TrackNamespace
    ) async throws(MoqomError) -> any AnnouncementHandle {
        try await inner.announce(namespace)
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
