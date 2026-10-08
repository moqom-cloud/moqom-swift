import Foundation
import Testing

@testable import MoqomCore
@testable import MoqomKit
@testable import MoqomLoopback

@Suite("Room agent")
struct RoomAgentTests {
    @Test("an agent's username is the watchdog it serves")
    func usernameNamesTheWatchdog() throws {
        #expect(try RoomAgent.username(for: "rec-1").value == "watchdog.rec-1")
        #expect(ManagedRoomKeys.watchdog(of: "watchdog.rec-1/worker-01") == "rec-1")
    }

    @Test("an agent follows everyone at the top rung, with no layout from the application")
    func followsEveryoneAtTheTop() async throws {
        let relay = LoopbackRelay()
        let host = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: credentials("alice"),
            tenant: "acme"
        )
        try await host.connect(to: RelayEndpoint(host: "loopback"))
        let hostRoom = try await host.join(room: "room-42")
        let source = FrameRelay(
            format: CaptureFormat(size: PixelSize(width: 1280, height: 720), frameRate: 30)
        )
        _ = try await hostRoom.startBroadcast(from: source)

        let worker = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: credentials(try RoomAgent.username(for: "rec-1").value, device: "worker-01"),
            tenant: "acme"
        )
        try await worker.connect(to: RelayEndpoint(host: "loopback"))
        let agentRoom = try await worker.join(room: "room-42")
        let agent = RoomAgent(room: agentRoom, interval: .milliseconds(10))
        await agent.start()

        #expect(await eventually { await agentRoom.roster.count == 1 })
        let top = try #require(
            await eventually { await agentRoom.catalog(of: identity("alice")) != nil }
                ? await agentRoom.catalog(of: identity("alice"))?.videoLadder.rungs.last?.id
                : nil
        )
        #expect(await eventually {
            await relay.recorded { interaction in
                if case let .subscribed(track, _) = interaction { return track.name.value == top.value }
                return false
            }
        })

        await agent.stop()
        await worker.close()
        await host.close()
    }
}
