import Foundation
import Testing

@testable import MoqomCore
@testable import MoqomKit
@testable import MoqomLoopback

/// A delivery service in memory, with the control plane's semantics: one
/// group per room, commits ordered by epoch, key packages used once with a
/// last resort, Welcomes only to whom they are for. It sees exactly what the
/// real one sees, and the tests below check it never needed more.
actor FakeKeyDelivery {
    struct Row {
        var member = false
        var online = true
    }

    private(set) var group: MLSDeliverySnapshot.Group?
    private var sequence: UInt64 = 0
    private var messages: [(seq: UInt64, kind: MLSDeliverySnapshot.Message.Kind, data: Data, to: Set<String>?)] = []
    private var rows: [String: Row] = [:]
    private var packages: [String: (oneTime: [Data], last: Data)] = [:]
    private(set) var everything: [Data] = []

    func client(_ identity: ParticipantIdentity) -> Client {
        Client(service: self, identity: ManagedRoomKeys.name(of: identity))
    }

    func publish(_ who: String, _ oneTime: [Data], _ last: Data) {
        packages[who] = (oneTime, last)
        everything += oneTime + [last]
        rows[who, default: Row()].online = true
    }

    func claim(_ who: String, by caller: String) throws -> Data {
        guard rows[caller]?.member == true, var held = packages[who] else {
            throw MLSDeliveryError.refused(status: 404, reason: "no key package")
        }
        if held.oneTime.isEmpty { return held.last }
        let first = held.oneTime.removeFirst()
        packages[who] = held
        return first
    }

    func sync(_ who: String, after: UInt64) -> MLSDeliverySnapshot {
        rows[who, default: Row()].online = true
        if group != nil, !rows.values.contains(where: { $0.member && $0.online }) {
            group = nil
            messages.removeAll()
            for key in rows.keys { rows[key]?.member = false }
        }
        let visible = messages.filter { $0.seq > after && ($0.to == nil || $0.to!.contains(who)) }
        return MLSDeliverySnapshot(
            group: group,
            messages: visible.map { .init(sequence: $0.seq, kind: $0.kind, data: $0.data) },
            members: rows.filter { $0.value.member && $0.value.online }.map(\.key).sorted(),
            pending: rows.filter { !$0.value.member && $0.value.online && packages[$0.key] != nil }
                .map(\.key).sorted(),
            cursor: sequence
        )
    }

    func create(_ id: Data, by who: String) -> Bool {
        guard group == nil else { return false }
        group = .init(id: id, epoch: 0)
        rows[who, default: Row()].member = true
        return true
    }

    func submit(_ commit: MLSDeliveryCommit, by who: String) -> MLSCommitReceipt {
        guard let current = group, current.epoch == commit.epoch, rows[who]?.member == true else {
            return .stale
        }
        everything.append(commit.commit)
        sequence += 1
        let seq = sequence
        messages.append((seq, .commit, commit.commit, nil))
        if let welcome = commit.welcome {
            everything.append(welcome)
            sequence += 1
            messages.append((sequence, .welcome, welcome, Set(commit.joiners)))
        }
        group = .init(id: current.id, epoch: current.epoch + 1)
        for gone in commit.removed { rows[gone]?.member = false }
        for joiner in commit.joiners { rows[joiner, default: Row()].member = true }
        return .accepted(sequence: seq)
    }

    func rejoin(_ who: String) { rows[who]?.member = false }
    func leave(_ who: String) { rows[who] = nil }

    struct Client: MLSDeliveryService {
        let service: FakeKeyDelivery
        let identity: String

        func publishKeyPackages(_ packages: [Data], lastResort: Data, token _: Data) async throws {
            await service.publish(identity, packages, lastResort)
        }

        func claimKeyPackage(for who: String, token _: Data) async throws -> Data {
            try await service.claim(who, by: identity)
        }

        func sync(after cursor: UInt64, wait _: Duration, token _: Data) async throws -> MLSDeliverySnapshot {
            await service.sync(identity, after: cursor)
        }

        func createGroup(_ id: Data, token _: Data) async throws -> Bool {
            await service.create(id, by: identity)
        }

        func submitCommit(_ commit: MLSDeliveryCommit, token _: Data) async throws -> MLSCommitReceipt {
            await service.submit(commit, by: identity)
        }

        func rejoin(token _: Data) async throws { await service.rejoin(identity) }
        func leave(token _: Data) async throws { await service.leave(identity) }
    }
}

@Suite("Managed room keys")
struct ManagedRoomKeysTests {
    private func keys(_ name: String, _ device: String, _ service: FakeKeyDelivery) async -> ManagedRoomKeys {
        ManagedRoomKeys(
            identity: identity(name, device: device),
            delivery: await service.client(identity(name, device: device)),
            token: { Data() },
            sleep: { try? await Task.sleep(for: min($0, .milliseconds(5))) }
        )
    }

    private func sameEpoch(_ all: [ManagedRoomKeys], members: Int) async -> Bool {
        var seen: Set<Data> = []
        for keys in all {
            guard let status = await keys.status, status.members.count == members else { return false }
            seen.insert(status.epochAuthenticator)
        }
        return seen.count == 1
    }

    @Test("the first device founds the group, later ones are added, and all agree")
    func joinsConverge() async throws {
        let service = FakeKeyDelivery()
        let alice = await keys("alice", "iphone-a", service)
        let bob = await keys("bob", "iphone-b", service)
        let carol = await keys("carol", "iphone-c", service)
        await alice.start()
        #expect(await eventually { await alice.status != nil })
        await bob.start()
        await carol.start()
        #expect(await eventually { await sameEpoch([alice, bob, carol], members: 3) })

        // Media sealed by one member opens for the others, with no key ever
        // having been handed to the application or the service.
        let sealed = try alice.encryption.sender.protect(Data("hello".utf8))
        #expect(try bob.encryption.receiver.unprotect(sealed) == Data("hello".utf8))
        #expect(try carol.encryption.receiver.unprotect(sealed) == Data("hello".utf8))

        let base = try #require(await alice.status).epochAuthenticator
        for blob in await service.everything { #expect(blob.range(of: base) == nil) }

        for keys in [alice, bob, carol] { await keys.stop() }
    }

    @Test("a member that leaves is removed in a new epoch it cannot read")
    func leaveRekeys() async throws {
        let service = FakeKeyDelivery()
        let alice = await keys("alice", "iphone-a", service)
        let bob = await keys("bob", "iphone-b", service)
        let carol = await keys("carol", "iphone-c", service)
        await alice.start()
        #expect(await eventually { await alice.status != nil })
        await bob.start()
        await carol.start()
        #expect(await eventually { await sameEpoch([alice, bob, carol], members: 3) })
        let before = try #require(await alice.status).epoch

        // What Bob could still decrypt with, captured before he goes.
        let bobReceiverKeys = bob.encryption.receiver.keyIDs
        await bob.stop()
        #expect(bob.encryption.receiver.keyIDs.isEmpty)

        #expect(await eventually { await sameEpoch([alice, carol], members: 2) })
        let after = try #require(await alice.status)
        #expect(after.epoch > before)
        #expect(!after.members.contains("bob/iphone-b"))

        let sealed = try alice.encryption.sender.protect(Data("after".utf8))
        let header = try SFrameHeader.read(from: sealed).0
        #expect(!bobReceiverKeys.contains(header.keyID))
        #expect(try carol.encryption.receiver.unprotect(sealed) == Data("after".utf8))

        for keys in [alice, carol] { await keys.stop() }
    }

    @Test("a device that comes back is re-added in place of its stale leaf")
    func rejoinReplacesStaleLeaf() async throws {
        let service = FakeKeyDelivery()
        let alice = await keys("alice", "iphone-a", service)
        let first = await keys("bob", "iphone-b", service)
        await alice.start()
        #expect(await eventually { await alice.status != nil })
        await first.start()
        #expect(await eventually { await sameEpoch([alice, first], members: 2) })

        // The app is killed: no leave, and every private key with it.
        await first.stop(leaving: false)
        let bob = await keys("bob", "iphone-b", service)
        await bob.start()
        #expect(await eventually { await sameEpoch([alice, bob], members: 2) })
        let sealed = try bob.encryption.sender.protect(Data("back".utf8))
        #expect(try alice.encryption.receiver.unprotect(sealed) == Data("back".utf8))

        for keys in [alice, bob] { await keys.stop() }
    }
}

@Suite("Managed keys in a room")
struct ManagedKeysRoomTests {
    private let rung = VideoLayer(
        id: "video/360p", size: PixelSize(width: 640, height: 360), frameRate: 30, bitrate: 600_000
    )

    private func join(_ name: String, relay: LoopbackRelay, service: FakeKeyDelivery) async throws -> RoomSession {
        let who = identity(name)
        let session = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: DeviceCredentials(
                identity: who,
                token: testToken(subject: name, e2ee: .required),
                deviceKey: nil,
                keyDelivery: await service.client(who)
            ),
            tenant: "acme"
        )
        try await session.connect(to: RelayEndpoint(host: "loopback"))
        return try await session.join(room: "room-42")
    }

    @Test("a required room with a delivery service keys itself, and the relay carries only ciphertext")
    func roomKeysItself() async throws {
        let relay = LoopbackRelay()
        let service = FakeKeyDelivery()
        let host = try await join("alice", relay: relay, service: service)
        let viewer = try await join("bob", relay: relay, service: service)
        #expect(await host.isEncrypted)
        #expect(await eventually(timeout: .seconds(20)) {
            let a = await host.groupKeys, b = await viewer.groupKeys
            return a != nil && a?.members.count == 2 && a?.epochAuthenticator == b?.epochAuthenticator
        })

        let source = FrameRelay(format: CaptureFormat(size: rung.size, frameRate: 30), depth: 16)
        let live = try await host.startBroadcast(
            from: source,
            configuration: BroadcastConfiguration(
                ladder: LayerLadder(rungs: [rung]),
                encoderFactory: { SyntheticEncoder(configuration: $0) }
            )
        )
        let who = identity("alice")
        #expect(await eventually { await viewer.roster[who] != nil })
        await viewer.updateLayout([who: RenderBox(width: 640, height: 360, scale: 1)], linkBitrate: 5_000_000)
        let frames = try #require(await viewer.frames(from: who))

        for index in 0 ..< 8 {
            source.submit(VideoFrame(
                timestamp: FrameTimestamp(nanoseconds: UInt64(index) * 33_000_000),
                size: rung.size, surface: .synthetic(byteCount: 1024), forcesKeyFrame: index == 0
            ))
        }
        var received = 0
        for await _ in frames {
            received += 1
            if received == 3 { break }
        }
        #expect(received == 3)
        #expect(await live.stats.objectsPublished >= 3)
        let sealed = try #require(await relay.objects(onTrackNamed: "video/360p").first)
        #expect(Set(sealed.payload.dropFirst(8)).count > 32)
        #expect(await viewer.decryptionStatistics?.objectsRejected == 0)
    }

    @Test("an application key overrides managed keys")
    func sharedKeyOverrides() async throws {
        let relay = LoopbackRelay()
        let service = FakeKeyDelivery()
        let room = try await join("alice", relay: relay, service: service)
        await room.useEncryption(.sharedKey(Data(repeating: 0x5A, count: 32), keyID: 1))
        #expect(await room.groupKeys == nil)
        #expect(await room.isEncrypted)
    }
}
