// A room's direct paths on the Rust backend: the same room, the same offers and
// tickets, with each participant's endpoint bound through the FFI.
//
// Only built when the MoqomDirectFFI xcframework is (see Package.swift).

#if canImport(MoqomDirectFFI)
    import Foundation
    import MoqomCore
    import MoqomDirectRust
    import MoqomDirectTesting
    @testable import MoqomKit
    import MoqomLoopback
    import Testing

    @Suite("Rust direct backend in a room", .serialized)
    struct RustDirectRoomTests {
        @Test(
            "two people go direct and media flows",
            arguments: [(DirectBackend.rust, DirectBackend.rust), (.rust, .networkFramework)]
        )
        func twoGoDirect(alice aliceBackend: DirectBackend, bob bobBackend: DirectBackend) async throws {
            let relay = LoopbackRelay()
            let key = Data(repeating: 0x42, count: 32)
            let alice = try await DirectRooms.join("alice", relay: relay, sharedKey: key, backend: aliceBackend)
            let bob = try await DirectRooms.join("bob", relay: relay, sharedKey: key, backend: bobBackend)
            let desk = DirectTicketDesk(relay: relay)
            await desk.admit(alice.device)
            await desk.admit(bob.device)
            try await desk.open()

            let cameras = [DirectCamera(), DirectCamera()]
            try await cameras[0].broadcast(on: alice.room)
            try await cameras[1].broadcast(on: bob.room)
            let options = DirectRooms.options(offerSecret: Data(repeating: 0x17, count: 32))
            try await alice.room.setDirect(options)
            try await bob.room.setDirect(options)

            let a = alice.identity, b = bob.identity
            #expect(await eventually(timeout: .seconds(20)) {
                let bobSeen = await alice.room.roster[b] != nil
                let aliceSeen = await bob.room.roster[a] != nil
                return bobSeen && aliceSeen
            })
            let drains = [await drainFrames(of: b, on: alice.room), await drainFrames(of: a, on: bob.room)]

            #expect(await eventually(timeout: .seconds(30)) {
                let toBob = await bob.room.directPaths[a]
                let toAlice = await alice.room.directPaths[b]
                return toBob?.state == .direct && toAlice?.state == .direct
                    && (toBob?.objectsOverDirect ?? 0) > 10 && (toAlice?.objectsOverDirect ?? 0) > 10
            })
            #expect(await bob.room.decryptionStatistics?.objectsRejected == 0)

            for drain in drains { drain.cancel() }
            for camera in cameras { camera.stop() }
            await desk.close()
            await alice.session.close()
            await bob.session.close()
        }
    }
#endif
