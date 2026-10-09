// The feed's window: which rooms are joined as the focus moves.

#if canImport(AVFoundation) && canImport(VideoToolbox)
    import Foundation
    import Testing

    @testable import MoqomCore
    @testable import MoqomKit
    @testable import MoqomLoopback

    @Suite("Room feed")
    @MainActor
    struct RoomFeedTests {
        private let rooms: [RoomID] = ["a", "b", "c", "d", "e"]

        private func connected() async throws -> MoqomSession {
            let session = MoqomSession(
                transport: LoopbackTransport(relay: LoopbackRelay()),
                credentials: credentials("viewer"),
                tenant: "acme"
            )
            try await session.connect(to: RelayEndpoint(host: "loopback"))
            return session
        }

        /// Joins and leaves run in tasks; wait for the session to settle on `expected`.
        private func settle(_ session: MoqomSession, on expected: Set<RoomID>) async -> Set<RoomID> {
            for _ in 0 ..< 200 {
                let open = await session.openRooms
                if open == expected { return open }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return await session.openRooms
        }

        @Test("joins the focused room and its neighbours, relay-only, with instant mirrors")
        func joinsTheWindow() async throws {
            let session = try await connected()
            let feed = RoomFeed(session: session, rooms: rooms)
            feed.focus(on: 0)

            #expect(await settle(session, on: ["a", "b"]) == ["a", "b"])
            #expect(feed.entry(for: "a")?.renderer.mirrorsInstantly == true)
            #expect(feed.entry(for: "c") == nil)
        }

        @Test("keeps a room one step outside the window, and leaves it after that")
        func lingersOneStep() async throws {
            let session = try await connected()
            let feed = RoomFeed(session: session, rooms: rooms)
            feed.focus(on: 0)
            _ = await settle(session, on: ["a", "b"])

            feed.focus(on: 2)
            #expect(await settle(session, on: ["a", "b", "c", "d"]) == ["a", "b", "c", "d"])

            feed.focus(on: 4)
            #expect(await settle(session, on: ["c", "d", "e"]) == ["c", "d", "e"])
            #expect(feed.entry(for: "a") == nil)
        }

        @Test("an opened room stays joined when the window moves on, until it is released")
        func openedRoomsStay() async throws {
            let session = try await connected()
            let feed = RoomFeed(session: session, rooms: rooms)
            feed.focus(on: 0)
            _ = await settle(session, on: ["a", "b"])
            _ = try await feed.open("a")

            feed.focus(on: 4)
            #expect(await settle(session, on: ["a", "d", "e"]) == ["a", "d", "e"])

            feed.release("a")
            #expect(await settle(session, on: ["d", "e"]) == ["d", "e"])
        }

        @Test("close leaves everything")
        func closeLeavesAll() async throws {
            let session = try await connected()
            let feed = RoomFeed(session: session, rooms: rooms)
            feed.focus(on: 1)
            _ = await settle(session, on: ["a", "b", "c"])
            _ = try await feed.open("b")

            feed.close()
            #expect(await settle(session, on: []) == [])
        }
    }
#endif
