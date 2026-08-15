// Locale on the catalog, and how a mid-call change reaches the other side.

import Foundation
import Testing

@testable import MoqomCore
@testable import MoqomKit
@testable import MoqomLoopback

@Suite("Spoken locale")
struct SpokenLocaleTests {
    @Test("Foundation's identifier becomes a BCP 47 tag")
    func underscoresBecomeHyphens() {
        #expect(SpokenLocale.normalize("en_US") == "en-US")
        #expect(SpokenLocale.normalize("  zh-Hans-CN  ") == "zh-Hans-CN")
        #expect(SpokenLocale.normalize("es") == "es")
    }

    @Test("a string that is not a language tag is refused")
    func refuseJunk() {
        #expect(SpokenLocale.normalize("") == nil)
        #expect(SpokenLocale.normalize("   ") == nil)
        #expect(SpokenLocale.normalize("not a locale") == nil)
        #expect(SpokenLocale.normalize("en--US") == nil)
        #expect(SpokenLocale.normalize(String(repeating: "a", count: 40)) == nil)
    }

    @Test("the phone has a locale this build can publish")
    func thePhoneHasOne() {
        #expect(SpokenLocale.normalize(SpokenLocale.current()) != nil)
    }
}

@Suite("Locale on a live catalog")
struct LocalePublicationTests {
    @Test("a viewer reads the publisher's locale, including after it changes")
    func localeTravelsAndUpdates() async throws {
        let relay = LoopbackRelay()
        let host = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: credentials("alice"),
            tenant: "acme"
        )
        try await host.connect(to: RelayEndpoint(host: "loopback"))
        let hostRoom = try await host.join(room: "room-42")

        let viewer = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: credentials("bob"),
            tenant: "acme"
        )
        try await viewer.connect(to: RelayEndpoint(host: "loopback"))
        let viewerRoom = try await viewer.join(room: "room-42")

        await hostRoom.setLocale("en-US")
        _ = try await hostRoom.startBroadcast(
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

        let who = identity("alice")
        #expect(
            await eventually {
                await viewerRoom.catalog(of: who)?.locale == "en-US"
            }
        )
        #expect(await viewerRoom.roster[who]?.locale == "en-US")

        await hostRoom.setLocale("ja-JP")
        #expect(
            await eventually {
                await viewerRoom.catalog(of: who)?.locale == "ja-JP"
            }
        )
        #expect(await viewerRoom.roster[who]?.locale == "ja-JP")
        #expect(await hostRoom.locale == "ja-JP")
    }
}
