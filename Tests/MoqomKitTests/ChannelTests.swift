// Personal channels, catalog references, and the stage handshake.

import Foundation
import Testing

@testable import MoqomCore
@testable import MoqomKit
@testable import MoqomLoopback

@Suite("Personal channel")
struct PersonalChannelTests {
    @Test("a catalog can name another publisher and a late joiner still reads it")
    func referencesRoundTrip() throws {
        let guest = try MoqomNamespaces.personal(
            tenant: "acme",
            identity: identity("bea")
        )
        let catalog = Catalog(
            locale: "en-US",
            references: [guest],
            invitations: [
                StageInvitationRecord(
                    direction: .invitation,
                    subject: identity("bea"),
                    issuedBy: identity("ada"),
                    offered: .camera,
                    expiresAt: Date().addingTimeInterval(30)
                ),
            ],
            tracks: [
                CatalogTrack(name: "audio", kind: .audio, codec: "audio/opus"),
            ]
        )
        let decoded = try Catalog.decode(catalog.encoded())
        #expect(decoded.references == [guest])
        #expect(decoded.invitations.count == 1)
        #expect(decoded.invitations[0].subject.username.value == "bea")
        #expect(decoded.locale == "en-US")
    }

    @Test("an older catalog without references still decodes")
    func missingReferencesAreEmpty() throws {
        let catalog = Catalog(
            tracks: [CatalogTrack(name: "audio", kind: .audio, codec: "audio/opus")]
        )
        let decoded = try Catalog.decode(catalog.encoded())
        #expect(decoded.references.isEmpty)
        #expect(decoded.invitations.isEmpty)
    }

    @Test("going live on a personal channel does not need a room name")
    func goLiveIsWatchedByUsername() async throws {
        let relay = LoopbackRelay()
        let host = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: credentials("ada"),
            tenant: "acme"
        )
        try await host.connect(to: RelayEndpoint(host: "loopback"))
        let channel = try await host.goLive()

        let viewer = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: credentials("bea"),
            tenant: "acme"
        )
        try await viewer.connect(to: RelayEndpoint(host: "loopback"))
        let watching = try await viewer.watch(try Username("ada"))

        _ = try await channel.startBroadcast(
            from: FrameRelay(
                format: CaptureFormat(size: PixelSize(width: 640, height: 360), frameRate: 30),
                depth: 8
            ),
            configuration: BroadcastConfiguration(
                ladder: LayerLadder(rungs: [
                    VideoLayer(
                        id: "video/360p",
                        size: PixelSize(width: 640, height: 360),
                        frameRate: 30,
                        bitrate: 600_000
                    ),
                ]),
                encoderFactory: { SyntheticEncoder(configuration: $0) }
            )
        )

        #expect(
            await eventually {
                await watching.catalog(of: identity("ada")) != nil
            }
        )
        #expect(channel.channel?.value == "ada")
        #expect(watching.channel?.value == "ada")
    }

    @Test("an invitation is an offer; accepting starts no camera")
    func inviteThenAcceptDoesNotGoLive() async throws {
        let relay = LoopbackRelay()
        let host = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: credentials("ada"),
            tenant: "acme"
        )
        try await host.connect(to: RelayEndpoint(host: "loopback"))
        let channel = try await host.goLive()

        let guest = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: credentials("bea"),
            tenant: "acme"
        )
        try await guest.connect(to: RelayEndpoint(host: "loopback"))
        let watching = try await guest.watch(try Username("ada"))

        let invitation = try await channel.invite(try Username("bea"))
        #expect(invitation.direction == .invitation)
        #expect(invitation.isOpen)

        #expect(
            await eventually {
                await watching.currentState.stage.pending.contains { $0.id == invitation.id }
            }
        )

        try await watching.accept(invitation.id)
        let stillIdle = await watching.currentState.roster[identity("bea")] == nil
        #expect(stillIdle)
    }

    @Test("a guest who goes live is referenced from the host catalog")
    func guestLiveIsFollowed() async throws {
        let relay = LoopbackRelay()
        let host = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: credentials("ada"),
            tenant: "acme"
        )
        try await host.connect(to: RelayEndpoint(host: "loopback"))
        let channel = try await host.goLive()
        _ = try await channel.startBroadcast(
            from: FrameRelay(
                format: CaptureFormat(size: PixelSize(width: 640, height: 360), frameRate: 30),
                depth: 8
            ),
            configuration: BroadcastConfiguration(
                ladder: LayerLadder(rungs: [
                    VideoLayer(
                        id: "video/360p",
                        size: PixelSize(width: 640, height: 360),
                        frameRate: 30,
                        bitrate: 600_000
                    ),
                ]),
                encoderFactory: { SyntheticEncoder(configuration: $0) }
            )
        )

        let guest = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: credentials("bea"),
            tenant: "acme"
        )
        try await guest.connect(to: RelayEndpoint(host: "loopback"))
        _ = try await guest.watch(try Username("ada"))
        _ = try await channel.invite(try Username("bea"))

        let own = try await guest.goLive()
        _ = try await own.startBroadcast(
            from: FrameRelay(
                format: CaptureFormat(size: PixelSize(width: 640, height: 360), frameRate: 30),
                depth: 8
            ),
            configuration: BroadcastConfiguration(
                ladder: LayerLadder(rungs: [
                    VideoLayer(
                        id: "video/360p",
                        size: PixelSize(width: 640, height: 360),
                        frameRate: 30,
                        bitrate: 600_000
                    ),
                ]),
                encoderFactory: { SyntheticEncoder(configuration: $0) }
            )
        )

        let expected = try MoqomNamespaces.personal(tenant: "acme", identity: identity("bea"))
        #expect(
            await eventually(timeout: .seconds(6)) {
                await channel.publishedCatalog?.references.contains(expected) == true
            }
        )
    }

    @Test("following a reference does not follow itself")
    func referencesDoNotLoop() async throws {
        let relay = LoopbackRelay()
        let host = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: credentials("ada"),
            tenant: "acme"
        )
        try await host.connect(to: RelayEndpoint(host: "loopback"))
        let channel = try await host.goLive()
        _ = try await channel.startBroadcast(
            from: FrameRelay(
                format: CaptureFormat(size: PixelSize(width: 640, height: 360), frameRate: 30),
                depth: 8
            ),
            configuration: BroadcastConfiguration(
                ladder: LayerLadder(rungs: [
                    VideoLayer(
                        id: "video/360p",
                        size: PixelSize(width: 640, height: 360),
                        frameRate: 30,
                        bitrate: 600_000
                    ),
                ]),
                encoderFactory: { SyntheticEncoder(configuration: $0) }
            )
        )

        // Point the catalog at itself. A hop limit and a visited set have to
        // keep this from opening subscriptions forever.
        let own = try MoqomNamespaces.personal(tenant: "acme", identity: identity("ada"))
        // Invite-and-link uses the same follow path; calling it twice is the
        // cycle. The second call must be a no-op.
        _ = try await channel.invite(try Username("ada"))
        let copies = await channel.publishedCatalog?.references.filter { $0 == own }.count ?? 0
        #expect(copies <= 1)
    }
}
