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
        let package: Data
        if held.oneTime.isEmpty {
            package = held.last
        } else {
            package = held.oneTime.removeFirst()
            packages[who] = held
        }
        // As the control plane does: a package in another suite than the
        // group's is consumed and refused.
        if let group, let suite = try? MLSKeyPackage.decode(package).cipherSuite,
           suite.identifier != group.cipherSuite {
            refusedClaims += 1
            throw MLSDeliveryError.refused(status: 409, reason: "key package is for another cipher suite")
        }
        return package
    }

    private(set) var refusedClaims = 0

    /// Found a group nobody in the test holds, in any suite at all.
    func foundElsewhere(_ id: Data, suite: UInt16, by who: String) {
        group = .init(id: id, epoch: 0, cipherSuite: suite)
        rows[who, default: Row()].member = true
    }

    func sync(_ who: String, after: UInt64) -> MLSDeliverySnapshot {
        rows[who, default: Row()].online = true
        if group != nil, !rows.values.contains(where: { $0.member && $0.online }) {
            group = nil
            messages.removeAll()
            for key in rows.keys { rows[key]?.member = false }
        }
        let visible = messages.filter { $0.seq > after && ($0.to == nil || $0.to!.contains(who)) }
        let (audience, audienceWaiting) = audienceCounts(for: who)
        return MLSDeliverySnapshot(
            group: group,
            messages: visible.map { .init(sequence: $0.seq, kind: $0.kind, data: $0.data) },
            members: rows.filter { $0.value.member && $0.value.online }.map(\.key).sorted(),
            pending: rows.filter { !$0.value.member && $0.value.online && packages[$0.key] != nil }
                .map(\.key).sorted(),
            cursor: sequence,
            audience: audience,
            audienceWaiting: audienceWaiting
        )
    }

    func create(_ id: Data, suite: MLSCipherSuite, by who: String) -> Bool {
        guard group == nil else { return false }
        group = .init(id: id, epoch: 0, cipherSuite: suite.identifier)
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
        group = .init(id: current.id, epoch: current.epoch + 1, cipherSuite: current.cipherSuite)
        for gone in commit.removed { rows[gone]?.member = false }
        for joiner in commit.joiners { rows[joiner, default: Row()].member = true }
        return .accepted(sequence: seq)
    }

    func rejoin(_ who: String) { rows[who]?.member = false }
    func leave(_ who: String) { rows[who] = nil }

    struct Viewer {
        var key: Data
        var online = true
        var envelope: MLSAudienceEnvelope?
    }

    private(set) var viewers: [String: Viewer] = [:]
    private var deaf: Set<String> = []

    /// A viewer that stops checking in but keeps whatever keys it holds: the
    /// one rotation is there to shut out.
    func deafen(_ who: String) {
        deaf.insert(who)
        viewers[who]?.online = false
    }

    private var current: MLSEpochRef? { group.map { MLSEpochRef(groupID: $0.id, epoch: $0.epoch) } }

    private var waiting: [String] {
        viewers.filter { $0.value.online && $0.value.envelope?.epoch != current }.map(\.key).sorted()
    }

    /// A viewer that stops checking in, as one that closed the app does.
    func depart(_ who: String) { viewers[who]?.online = false }

    func joinAudience(_ who: String, key: Data, have: MLSEpochRef?) -> MLSAudienceEnvelope? {
        guard !deaf.contains(who) else { return nil }
        if viewers[who]?.key != key { viewers[who] = Viewer(key: key) }
        viewers[who]?.online = true
        guard let envelope = viewers[who]?.envelope, envelope.epoch != have else { return nil }
        return envelope
    }

    func audienceWork(_ who: String) throws -> MLSAudienceWork {
        guard rows[who]?.member == true, let current else {
            throw MLSDeliveryError.refused(status: 403, reason: "not a member")
        }
        return MLSAudienceWork(
            epoch: current,
            seats: waiting.map { .init(device: $0, publicKey: viewers[$0]!.key) }
        )
    }

    func seal(_ envelopes: [String: Data], for epoch: MLSEpochRef, by who: String) -> Bool {
        guard rows[who]?.member == true, epoch == current else { return false }
        for (device, data) in envelopes where viewers[device] != nil {
            everything.append(data)
            viewers[device]?.envelope = MLSAudienceEnvelope(epoch: epoch, data: data)
        }
        return true
    }

    func audienceCounts(for who: String) -> (Int, Int) {
        guard rows[who]?.member == true else { return (0, 0) }
        return (viewers.values.filter(\.online).count, waiting.count)
    }

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

        func createGroup(_ id: Data, cipherSuite: MLSCipherSuite, token _: Data) async throws -> Bool {
            await service.create(id, suite: cipherSuite, by: identity)
        }

        func submitCommit(_ commit: MLSDeliveryCommit, token _: Data) async throws -> MLSCommitReceipt {
            await service.submit(commit, by: identity)
        }

        func rejoin(token _: Data) async throws { await service.rejoin(identity) }
        func leave(token _: Data) async throws { await service.leave(identity) }

        func joinAudience(publicKey: Data, have: MLSEpochRef?, wait _: Duration, token _: Data) async throws -> MLSAudienceEnvelope? {
            if let envelope = await service.joinAudience(identity, key: publicKey, have: have) { return envelope }
            // Held, as the service holds it, rather than spun on.
            try? await Task.sleep(for: .milliseconds(5))
            return nil
        }

        func leaveAudience(token _: Data) async throws { await service.depart(identity) }

        func audienceWork(token _: Data) async throws -> MLSAudienceWork {
            try await service.audienceWork(identity)
        }

        func sealAudience(_ envelopes: [String: Data], for epoch: MLSEpochRef, token _: Data) async throws -> Bool {
            await service.seal(envelopes, for: epoch, by: identity)
        }
    }
}

@Suite("Managed room keys")
struct ManagedRoomKeysTests {
    private func keys(
        _ name: String,
        _ device: String,
        _ service: FakeKeyDelivery,
        cipherSuite: MLSCipherSuite = .default
    ) async -> ManagedRoomKeys {
        ManagedRoomKeys(
            identity: identity(name, device: device),
            delivery: await service.client(identity(name, device: device)),
            token: { Data() },
            cipherSuite: cipherSuite,
            sleep: { try? await Task.sleep(for: min($0, .milliseconds(5))) }
        )
    }

    private func viewer(_ name: String, _ service: FakeKeyDelivery) async throws -> AudienceKeys {
        let who = identity(name, device: "tv")
        return try AudienceKeys(
            identity: who,
            delivery: await service.client(who),
            token: { Data() },
            sleep: { try? await Task.sleep(for: min($0, .milliseconds(5))) }
        )
    }

    private func holds(_ viewer: AudienceKeys, epochOf member: ManagedRoomKeys) async -> Bool {
        guard let epoch = await member.status?.epoch else { return false }
        return await viewer.status?.epoch == epoch
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

        // Founded in the hybrid suite, and everybody is in it.
        #expect(await service.group?.cipherSuite == MLSCipherSuite.mls192MLKEM768MLDSA65.identifier)
        for keys in [alice, bob, carol] {
            #expect(await keys.status?.cipherSuite == .mls192MLKEM768MLDSA65)
        }

        for keys in [alice, bob, carol] { await keys.stop() }
    }

    @Test("a device joining a group founded in suite 0x0001 republishes its key packages in that suite")
    func joinsClassicalGroup() async throws {
        let service = FakeKeyDelivery()
        let alice = await keys("alice", "iphone-a", service, cipherSuite: .mls128DHKEMX25519)
        let bob = await keys("bob", "iphone-b", service)
        await alice.start()
        #expect(await eventually { await alice.status != nil })
        await bob.start()
        #expect(await eventually { await sameEpoch([alice, bob], members: 2) })
        #expect(await bob.status?.cipherSuite == .mls128DHKEMX25519)
        #expect(await service.group?.cipherSuite == 0x0001)

        let sealed = try bob.encryption.sender.protect(Data("classical".utf8))
        #expect(try alice.encryption.receiver.unprotect(sealed) == Data("classical".utf8))

        for keys in [alice, bob] { await keys.stop() }
    }

    @Test("an agent decrypts as a member, and nobody sends to it until its watchdog is disclosed")
    func agentsAreDisclosedBeforeTheyHear() async throws {
        let service = FakeKeyDelivery()
        let alice = await keys("alice", "iphone-a", service)
        let bob = await keys("bob", "iphone-b", service)
        await alice.start()
        #expect(await eventually { await alice.status != nil })
        await bob.start()
        #expect(await eventually { await sameEpoch([alice, bob], members: 2) })

        let recorder = await keys("watchdog.rec-1", "worker-01", service)
        await recorder.start()
        #expect(await eventually { await sameEpoch([alice, bob, recorder], members: 3) })

        // In the group, visible to everyone as an agent, and not yet disclosed:
        // nobody sends.
        let status = try #require(await alice.status)
        #expect(status.agents == ["watchdog.rec-1/worker-01"])
        #expect(status.undisclosedAgents == ["watchdog.rec-1/worker-01"])
        #expect(throws: SFrameError.noKey) { _ = try alice.encryption.sender.protect(Data("hi".utf8)) }
        #expect(throws: SFrameError.noKey) { _ = try bob.encryption.sender.protect(Data("hi".utf8)) }

        // The control log names it. Media flows, and the agent can open it.
        await alice.disclose(watchdogs: ["rec-1"])
        await bob.disclose(watchdogs: ["rec-1"])
        #expect(await alice.status?.undisclosedAgents.isEmpty == true)
        let sealed = try alice.encryption.sender.protect(Data("recorded".utf8))
        #expect(try recorder.encryption.receiver.unprotect(sealed) == Data("recorded".utf8))
        #expect(try bob.encryption.receiver.unprotect(sealed) == Data("recorded".utf8))

        // Detached on the log while still in the group: held again.
        await alice.disclose(watchdogs: [])
        #expect(throws: SFrameError.noKey) { _ = try alice.encryption.sender.protect(Data("hi".utf8)) }

        // An ordinary username that merely looks like one is not an agent.
        #expect(ManagedRoomKeys.watchdog(of: "watchdogs/iphone") == nil)
        #expect(ManagedRoomKeys.watchdog(of: "watchdog./iphone") == nil)
        #expect(ManagedRoomKeys.watchdog(of: "watchdog.rec-1/worker-01") == "rec-1")

        for keys in [alice, bob, recorder] { await keys.stop() }
    }

    @Test("viewers outside the group are sealed each epoch's key and read every publisher")
    func viewersAreSealedTheEpoch() async throws {
        let service = FakeKeyDelivery()
        let alice = await keys("alice", "iphone-a", service)
        let bob = await keys("bob", "iphone-b", service)
        await alice.start()
        #expect(await eventually { await alice.status != nil })
        await bob.start()
        #expect(await eventually { await sameEpoch([alice, bob], members: 2) })

        let carol = try await viewer("carol", service)
        let dave = try await viewer("dave", service)
        await carol.start()
        await dave.start()
        #expect(await eventually { await holds(carol, epochOf: alice) })
        #expect(await eventually { await holds(dave, epochOf: alice) })

        // Not members: the group is still two, and the audience is counted apart.
        let status = try #require(await alice.status)
        #expect(status.members.count == 2)
        #expect(await eventually { await alice.status?.audience == 2 })

        // Each publisher's frames open from the one base key, by key ID.
        for sender in [alice, bob] {
            let sealed = try sender.encryption.sender.protect(Data("on air".utf8))
            #expect(try carol.encryption.receiver.unprotect(sealed) == Data("on air".utf8))
            #expect(try dave.encryption.receiver.unprotect(sealed) == Data("on air".utf8))
        }
        // A viewer has nothing to send under.
        #expect(throws: SFrameError.noKey) { _ = try carol.encryption.sender.protect(Data("hi".utf8)) }

        // A new member moves the epoch, and viewers follow it.
        let erin = await keys("erin", "iphone-e", service)
        await erin.start()
        #expect(await eventually { await sameEpoch([alice, bob, erin], members: 3) })
        #expect(await eventually { await holds(carol, epochOf: alice) })
        let sealed = try erin.encryption.sender.protect(Data("new epoch".utf8))
        #expect(try carol.encryption.receiver.unprotect(sealed) == Data("new epoch".utf8))

        for keys in [alice, bob, erin] { await keys.stop() }
        await carol.stop()
        await dave.stop()
    }

    @Test("a viewer that goes is not sealed the next rotation, and cannot read past it")
    func rotationShutsOutDepartedViewers() async throws {
        let service = FakeKeyDelivery()
        let alice = ManagedRoomKeys(
            identity: identity("alice", device: "iphone-a"),
            delivery: await service.client(identity("alice", device: "iphone-a")),
            token: { Data() },
            audienceRotation: .milliseconds(300),
            sleep: { try? await Task.sleep(for: min($0, .milliseconds(5))) }
        )
        await alice.start()
        #expect(await eventually { await alice.status != nil })
        let carol = try await viewer("carol", service)
        let dave = try await viewer("dave", service)
        await carol.start()
        await dave.start()
        #expect(await eventually { await holds(carol, epochOf: alice) })
        #expect(await eventually { await holds(dave, epochOf: alice) })
        let before = try #require(await alice.status).epoch
        let early = try alice.encryption.sender.protect(Data("before".utf8))
        #expect(try dave.encryption.receiver.unprotect(early) == Data("before".utf8))

        await service.deafen("dave/tv")
        // With nobody joining or leaving the group, the epoch moves on a timer
        // because there is an audience.
        #expect(await eventually(timeout: .seconds(10)) { (await alice.status?.epoch ?? 0) > before })
        #expect(await eventually { await holds(carol, epochOf: alice) })
        let late = try alice.encryption.sender.protect(Data("after".utf8))
        #expect(try carol.encryption.receiver.unprotect(late) == Data("after".utf8))
        #expect(throws: SFrameError.self) { _ = try dave.encryption.receiver.unprotect(late) }

        await alice.stop()
        await carol.stop()
        await dave.stop()
    }

    @Test("an audience envelope opens only for its viewer and its epoch")
    func audienceEnvelopes() throws {
        let viewer = try AudienceSeal.suite.generateKeyPair()
        let other = try AudienceSeal.suite.generateKeyPair()
        let base = Data(repeating: 0x42, count: 32)
        let epoch = MLSEpochRef(groupID: Data("group".utf8), epoch: 9)
        let sealed = try AudienceSeal.seal(base, to: viewer.publicKey, epoch: epoch)
        #expect(try AudienceSeal.open(.init(epoch: epoch, data: sealed), privateKey: viewer.privateKey) == base)
        #expect(throws: MLSError.self) {
            _ = try AudienceSeal.open(.init(epoch: epoch, data: sealed), privateKey: other.privateKey)
        }
        // Replayed as another epoch's key, it does not open.
        let later = MLSEpochRef(groupID: epoch.groupID, epoch: 10)
        #expect(throws: MLSError.self) {
            _ = try AudienceSeal.open(.init(epoch: later, data: sealed), privateKey: viewer.privateKey)
        }
        // A classical key is refused, not sealed to.
        let classical = try MLSCipherSuite.mls128DHKEMX25519.generateKeyPair()
        #expect(throws: MLSError.self) { _ = try AudienceSeal.seal(base, to: classical.publicKey, epoch: epoch) }
    }

    @Test("the publish grant in a token decides member or viewer, and silence means member")
    func publishGrant() {
        #expect(DeviceCredentials.mayPublish(token: testToken(subject: "a", e2ee: nil, publish: true)) == true)
        #expect(DeviceCredentials.mayPublish(token: testToken(subject: "a", e2ee: nil, publish: false)) == false)
        #expect(DeviceCredentials.mayPublish(token: testToken(subject: "a", e2ee: nil)) == nil)
        #expect(DeviceCredentials.mayPublish(token: Data("not a token".utf8)) == nil)
    }

    @Test("a group in a suite this build does not implement is not joined")
    func unknownSuiteNotJoined() async throws {
        let service = FakeKeyDelivery()
        await service.foundElsewhere(Data("future".utf8), suite: 0x7A7A, by: "zed/z")
        let bob = await keys("bob", "iphone-b", service)
        await bob.start()
        try await Task.sleep(for: .milliseconds(200))
        #expect(await bob.status == nil)
        await bob.stop()
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

    private func join(
        _ name: String, relay: LoopbackRelay, service: FakeKeyDelivery, publish: Bool? = nil
    ) async throws -> RoomSession {
        let who = identity(name)
        let session = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: DeviceCredentials(
                identity: who,
                token: testToken(subject: name, e2ee: .required, publish: publish),
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

    @Test("a viewer token is keyed as audience, outside the group, and reads the broadcast")
    func viewerRoom() async throws {
        let relay = LoopbackRelay()
        let service = FakeKeyDelivery()
        let host = try await join("alice", relay: relay, service: service, publish: true)
        let viewer = try await join("bob", relay: relay, service: service, publish: false)
        #expect(await eventually(timeout: .seconds(20)) {
            guard let group = await host.groupKeys, let held = await viewer.audienceKeys else { return false }
            return group.epoch == held.epoch && group.audience == 1
        })
        #expect(await host.groupKeys?.members == ["alice/iphone-0001"])
        #expect(await viewer.groupKeys == nil)

        let source = FrameRelay(format: CaptureFormat(size: rung.size, frameRate: 30), depth: 16)
        _ = try await host.startBroadcast(
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
        let feeding = Task {
            var index = 0
            while !Task.isCancelled {
                source.submit(VideoFrame(
                    timestamp: FrameTimestamp(nanoseconds: UInt64(index) * 33_000_000),
                    size: rung.size, surface: .synthetic(byteCount: 1024), forcesKeyFrame: index % 30 == 0
                ))
                index += 1
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
        defer { feeding.cancel() }
        var received = 0
        for await _ in frames {
            received += 1
            if received == 3 { break }
        }
        #expect(received == 3)
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
