import Foundation
import MoqomDirectTesting
import Testing

@testable import MoqomCore
@testable import MoqomKit
@testable import MoqomLoopback

/// Every ``RoomEvent/directPathChanged(_:_:)`` a room reports.
private actor PathLog {
    private(set) var changes: [(ParticipantIdentity, DirectPathState)] = []

    func record(_ who: ParticipantIdentity, _ state: DirectPathState) {
        changes.append((who, state))
    }

    func states(of who: ParticipantIdentity) -> [DirectPathState] {
        changes.filter { $0.0 == who }.map(\.1)
    }

    static func watching(_ room: RoomSession) -> PathLog {
        let log = PathLog()
        let events = room.events
        Task {
            for await event in events {
                if case let .directPathChanged(who, state) = event { await log.record(who, state) }
            }
        }
        return log
    }
}

@Suite("Direct paths in a room", .serialized)
struct DirectRoomTests {
    private struct Call {
        let relay: LoopbackRelay
        let service: FakeKeyDelivery
        let alice: DirectRoomPerson
        let bob: DirectRoomPerson
        let desk: DirectTicketDesk
        let cameras: [DirectCamera]
        let drains: [Task<Void, Never>]

        func hangUp() async {
            for drain in drains { drain.cancel() }
            for camera in cameras { camera.stop() }
            await desk.close()
            await alice.session.close()
            await bob.session.close()
        }
    }

    /// Alice and Bob on stage in an encrypted room, each watching the other,
    /// with tickets being issued and direct paths turned on where asked.
    private func call(
        aliceDirect: Bool = true,
        bobDirect: Bool = true,
        managedKeys: Bool = true,
        tickets: DirectTicketSettings? = nil,
        lifetime: TimeInterval = 90
    ) async throws -> Call {
        let relay = LoopbackRelay()
        let service = FakeKeyDelivery()
        let key = Data(repeating: 0x42, count: 32)
        let secret = Data(repeating: 0x17, count: 32)
        let delivery: (@Sendable (ParticipantIdentity) async -> any MLSDeliveryService)? =
            managedKeys ? { @Sendable in await service.client($0) } : nil
        let alice = try await DirectRooms.join(
            "alice", relay: relay, sharedKey: managedKeys ? nil : key, keyDelivery: delivery
        )
        let bob = try await DirectRooms.join(
            "bob", relay: relay, sharedKey: managedKeys ? nil : key, keyDelivery: delivery
        )

        let desk = DirectTicketDesk(relay: relay, lifetime: lifetime)
        await desk.admit(alice.device)
        await desk.admit(bob.device)
        try await desk.open()

        let cameras = [DirectCamera(), DirectCamera()]
        try await cameras[0].broadcast(on: alice.room)
        try await cameras[1].broadcast(on: bob.room)

        let base = DirectRooms.options(offerSecret: managedKeys ? nil : secret)
        var options = base
        if let tickets { options.tickets = tickets }
        if aliceDirect { try await alice.room.setDirect(options) }
        if bobDirect { try await bob.room.setDirect(options) }

        let a = alice.identity, b = bob.identity
        #expect(await eventually(timeout: .seconds(20)) {
            let bobSeen = await alice.room.roster[b] != nil
            let aliceSeen = await bob.room.roster[a] != nil
            return bobSeen && aliceSeen
        })
        let drains = [
            await drainFrames(of: b, on: alice.room),
            await drainFrames(of: a, on: bob.room),
        ]
        return Call(relay: relay, service: service, alice: alice, bob: bob, desk: desk, cameras: cameras, drains: drains)
    }

    private func state(_ room: RoomSession, of who: ParticipantIdentity) async -> DirectPathState? {
        await room.directPaths[who]?.state
    }

    private func bothDirect(_ call: Call) async -> Bool {
        let alice = await state(call.alice.room, of: call.bob.identity)
        let bob = await state(call.bob.room, of: call.alice.identity)
        return alice == .direct && bob == .direct
    }

    @Test("two people go direct, and media flows over the direct path")
    func twoGoDirect() async throws {
        let call = try await call()
        let log = PathLog.watching(call.bob.room)
        let a = call.alice.identity, b = call.bob.identity

        #expect(await eventually(timeout: .seconds(30)) {
            await bothDirect(call)
        })
        #expect(await eventually(timeout: .seconds(10)) {
            let toBob = await call.bob.room.directPaths[a]?.objectsOverDirect ?? 0
            let toAlice = await call.alice.room.directPaths[b]?.objectsOverDirect ?? 0
            return toBob > 10 && toAlice > 10
        })

        // Offers went out under the group's key, so the room keyed itself first.
        #expect(await call.alice.room.groupKeys?.members.count == 2)
        // The direct session is the verified peer, and tickets are held for it.
        let session = try #require(await call.alice.room.directSession(with: b))
        #expect(session.peer.participant == call.bob.device.name)
        let ticketTrack = try #require(DirectTicketDesk.track(holder: call.alice.device, peer: call.bob.device))
        #expect(await call.relay.subscriberCount(for: ticketTrack) == 1)
        // What went direct is what went to the relay: ciphertext.
        #expect(await call.bob.room.decryptionStatistics?.objectsRejected == 0)

        #expect(await eventually { await log.states(of: a).contains(.direct) })
        await call.hangUp()
    }

    @Test("a viewer never goes direct, and the two on stage still do")
    func viewerStaysOnRelay() async throws {
        let call = try await call(managedKeys: false)
        let key = Data(repeating: 0x42, count: 32)
        let viewer = try await DirectRooms.join("carol", relay: call.relay, publish: 0, sharedKey: key)
        try await viewer.room.setDirect(DirectRooms.options(offerSecret: Data(repeating: 0x17, count: 32)))
        let a = call.alice.identity, b = call.bob.identity

        #expect(await eventually(timeout: .seconds(20)) { await viewer.room.roster[a] != nil })
        let drain = await drainFrames(of: a, on: viewer.room)
        #expect(await eventually(timeout: .seconds(30)) {
            await bothDirect(call)
        })
        #expect(await eventually { await state(viewer.room, of: a) == .relay(.ineligible(.audience)) })
        #expect(await eventually { (await viewer.room.directPaths[a]?.objectsOverRelay ?? 0) > 5 })

        // Never offered anything, and nobody on stage counts it as a peer.
        let slot = try MoqomNamespaces.participant(tenant: "acme", room: "room-42", identity: viewer.identity)
        let offers = try FullTrackName(namespace: slot, name: TrackName(".direct"))
        #expect(await call.relay.objects(on: offers).isEmpty)
        #expect(await call.alice.room.directPaths[viewer.identity] == nil)
        #expect(await viewer.room.directSession(with: a) == nil)
        #expect(await viewer.room.directPaths[a]?.objectsOverDirect == 0)

        drain.cancel()
        await viewer.session.close()
        await call.hangUp()
    }

    @Test("one participant not opting in keeps the room on the relay")
    func notOptedInKeepsRelay() async throws {
        let call = try await call(bobDirect: false)
        let b = call.bob.identity

        #expect(await eventually(timeout: .seconds(20)) {
            await state(call.alice.room, of: b) == .relay(.ineligible(.notEveryoneOptedIn))
        })
        try await Task.sleep(for: .seconds(1))
        #expect(await state(call.alice.room, of: b) == .relay(.ineligible(.notEveryoneOptedIn)))
        #expect(await call.alice.room.directSession(with: b) == nil)
        #expect(await call.bob.room.directPaths.isEmpty)
        // No offers: Alice's endpoint was never bound, so her address went nowhere.
        #expect(await call.relay.objects(onTrackNamed: ".direct").isEmpty)
        #expect((await call.alice.room.directPaths[b]?.objectsOverRelay ?? 0) > 0)

        // Bob changing his mind is all it takes.
        try await call.bob.room.setDirect(DirectRooms.options())
        #expect(await eventually(timeout: .seconds(30)) { await state(call.alice.room, of: b) == .direct })
        await call.hangUp()
    }

    @Test("a direct path that dies falls back to the relay at once, and comes back")
    func fallsBackWhenKilled() async throws {
        let call = try await call()
        let a = call.alice.identity, b = call.bob.identity
        #expect(await eventually(timeout: .seconds(30)) {
            let toBob = await call.bob.room.directPaths[a]
            return toBob?.state == .direct && (toBob?.objectsOverDirect ?? 0) > 10
        })

        let relayBefore = await call.bob.room.directPaths[a]?.objectsOverRelay ?? 0
        let session = try #require(await call.alice.room.directSession(with: b))
        let killed = ContinuousClock.now
        await session.session.close(code: 0x03, reason: "killed by the test")

        // Documented: back on the relay immediately on a failure. Measured as
        // the relay delivering Bob's next object, with slack for a busy machine.
        #expect(await eventually(timeout: .seconds(5)) {
            (await call.bob.room.directPaths[a]?.objectsOverRelay ?? 0) > relayBefore
        })
        let elapsed = ContinuousClock.now - killed
        #expect(elapsed < .seconds(1), "fell back after \(elapsed)")
        #expect(await eventually { await state(call.bob.room, of: a) != .direct })

        // And a fresh attempt follows.
        #expect(await eventually(timeout: .seconds(30)) {
            await bothDirect(call)
        })
        await call.hangUp()
    }

    @Test("a peer whose tickets lapse loses its direct path")
    func lapsedTicketsEndThePath() async throws {
        let call = try await call(
            tickets: DirectTicketSettings(grace: .seconds(10), represent: .milliseconds(500), skew: .seconds(1)),
            lifetime: 3
        )
        let a = call.alice.identity, b = call.bob.identity
        #expect(await eventually(timeout: .seconds(30)) {
            await bothDirect(call)
        })

        // Long enough for tickets to have been presented and checked: the feed
        // only subscribes once the path is up. Then the relay stops issuing, as
        // for a participant no longer eligible.
        try await Task.sleep(for: .seconds(2))
        #expect(await bothDirect(call))
        await call.desk.close()
        #expect(await eventually(timeout: .seconds(15)) {
            let alice = await state(call.alice.room, of: b), bob = await state(call.bob.room, of: a)
            return alice == .relay(.ticket(.expired)) || bob == .relay(.ticket(.expired))
        })
        #expect(await eventually { await call.alice.room.directSession(with: b) == nil })
        await call.hangUp()
    }

    @Test("leaving tears the direct path down, tickets included")
    func leavingTearsDown() async throws {
        let call = try await call()
        let a = call.alice.identity, b = call.bob.identity
        #expect(await eventually(timeout: .seconds(30)) {
            await bothDirect(call)
        })
        let bobsTickets = try #require(DirectTicketDesk.track(holder: call.bob.device, peer: call.alice.device))
        let alicesTickets = try #require(DirectTicketDesk.track(holder: call.alice.device, peer: call.bob.device))
        #expect(await call.relay.subscriberCount(for: bobsTickets) == 1)
        await call.bob.session.leave(room: "room-42")

        #expect(await call.relay.subscriberCount(for: bobsTickets) == 0)
        #expect(await call.bob.room.directPaths.isEmpty)
        #expect(await eventually(timeout: .seconds(10)) {
            let path = await call.alice.room.directPaths[b]
            let session = await call.alice.room.directSession(with: b)
            let holders = await call.relay.subscriberCount(for: alicesTickets)
            return path == nil && session == nil && holders == 0
        })
        await call.hangUp()
    }

    @Test("a viewer sealed the room's keys takes the room back to the relay")
    func viewerInTheAudienceCounts() async throws {
        let call = try await call()
        let a = call.alice.identity, b = call.bob.identity
        #expect(await eventually(timeout: .seconds(30)) {
            await bothDirect(call)
        })

        // A viewer is not in the group and cannot open the offers, but a room
        // with an audience is not a small call: it counts as a participant who
        // has not opted in.
        let service = call.service
        let viewer = try await DirectRooms.join(
            "carol", relay: call.relay, publish: 0, keyDelivery: { @Sendable in await service.client($0) }
        )
        #expect(await eventually(timeout: .seconds(30)) {
            let path = await state(call.alice.room, of: b)
            let session = await call.alice.room.directSession(with: b)
            return path == .relay(.ineligible(.notEveryoneOptedIn)) && session == nil
        })
        await viewer.session.close()
        await call.hangUp()
    }
}
