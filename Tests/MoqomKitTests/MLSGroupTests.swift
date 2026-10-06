import CryptoKit
import Foundation
import Testing

@testable import MoqomKit

/// The group protocol on top of the RFC primitives: what MOQOM claims about
/// membership changes, held to it directly rather than through a room.
@Suite("MLS group")
struct MLSGroupTests {
    private let room = Data("acme/room-42".utf8)

    private func bundle(_ who: String) throws -> MLSKeyPackageBundle {
        try MLSKeyPackageBundle.generate(identity: who)
    }

    /// A, then B by Welcome, then C by Welcome; every member at the same epoch.
    private func threeMembers() throws -> (MLSGroup, MLSGroup, MLSGroup) {
        var alice = try MLSGroup.create(groupID: room, bundle: bundle("alice/a"))
        let bob = try bundle("bob/b")
        let addBob = try alice.commit(adding: [bob.keyPackage])
        alice = addBob.next
        var bobGroup = try MLSGroup.join(try #require(addBob.welcome), bundle: bob)

        let carol = try bundle("carol/c")
        let addCarol = try alice.commit(adding: [carol.keyPackage])
        alice = addCarol.next
        guard case let .advanced(next) = try bobGroup.process(addCarol.message) else {
            Issue.record("bob was not advanced")
            throw MLSError.removed
        }
        bobGroup = next
        let carolGroup = try MLSGroup.join(try #require(addCarol.welcome), bundle: carol)
        return (alice, bobGroup, carolGroup)
    }

    @Test("Add by Welcome: every member derives the same epoch and the same SFrame keys")
    func addAgrees() throws {
        let (alice, bob, carol) = try threeMembers()
        #expect(alice.epoch == 2 && bob.epoch == 2 && carol.epoch == 2)
        #expect(alice.epochAuthenticator == bob.epochAuthenticator)
        #expect(alice.epochAuthenticator == carol.epochAuthenticator)
        #expect(Set(alice.roster.map(\.member.identityString)) == ["alice/a", "bob/b", "carol/c"])

        let sender = SFrameSender(key: alice.sframeKey(for: alice.ownLeaf, suite: .aes256GcmSha512))
        let sealed = try sender.protect(Data("frame".utf8), metadata: Data([1]))
        for member in [bob, carol] {
            let receiver = SFrameReceiver()
            for key in member.sframeKeys(suite: .aes256GcmSha512) { receiver.add(key) }
            #expect(try receiver.unprotect(sealed, metadata: Data([1])) == Data("frame".utf8))
        }
    }

    @Test("Remove: the removed member cannot follow, and the new epoch's keys are not theirs")
    func removeIsForwardSecret() throws {
        let (alice, bob, carol) = try threeMembers()
        let bobLeaf = try #require(alice.leaf(of: "bob/b"))
        let removal = try alice.commit(removing: [bobLeaf])
        #expect(removal.welcome == nil)

        guard case .removed = try bob.process(removal.message) else {
            Issue.record("bob followed his own removal")
            return
        }
        guard case let .advanced(carolNext) = try carol.process(removal.message) else {
            Issue.record("carol was not advanced")
            return
        }
        #expect(carolNext.epochAuthenticator == removal.next.epochAuthenticator)
        #expect(carolNext.memberCount == 2)

        // Everything Bob could still hold is the epoch before. None of it opens
        // a frame from the epoch after.
        let sender = SFrameSender(key: removal.next.sframeKey(for: removal.next.ownLeaf, suite: .aes256GcmSha512))
        let sealed = try sender.protect(Data("after".utf8))
        let bobReceiver = SFrameReceiver()
        for key in bob.sframeKeys(suite: .aes256GcmSha512) { bobReceiver.add(key) }
        #expect(throws: SFrameError.self) { _ = try bobReceiver.unprotect(sealed) }
        #expect(bob.epochAuthenticator != removal.next.epochAuthenticator)
    }

    @Test("a joiner's keys are not any earlier epoch's")
    func joinerCannotReadHistory() throws {
        var alice = try MLSGroup.create(groupID: room, bundle: bundle("alice/a"))
        let before = alice.sframeKey(for: 0, suite: .aes256GcmSha512)
        let sealed = try SFrameSender(key: before).protect(Data("history".utf8))
        let bob = try bundle("bob/b")
        let add = try alice.commit(adding: [bob.keyPackage])
        alice = add.next
        let joined = try MLSGroup.join(try #require(add.welcome), bundle: bob)
        let receiver = SFrameReceiver()
        for key in joined.sframeKeys(suite: .aes256GcmSha512) { receiver.add(key) }
        #expect(throws: SFrameError.self) { _ = try receiver.unprotect(sealed) }
    }

    @Test("an empty commit is an Update: new epoch, new keys, same members")
    func updateRotates() throws {
        let (alice, bob, _) = try threeMembers()
        let update = try bob.commit()
        guard case let .advanced(aliceNext) = try alice.process(update.message) else {
            Issue.record("alice was not advanced")
            return
        }
        #expect(aliceNext.epoch == alice.epoch + 1)
        #expect(aliceNext.memberCount == alice.memberCount)
        #expect(aliceNext.epochAuthenticator == update.next.epochAuthenticator)
        #expect(aliceNext.sframeKey(for: 0, suite: .aes128GcmSha256).keyID
            != alice.sframeKey(for: 0, suite: .aes128GcmSha256).keyID)
    }

    @Test("a commit for an epoch already left is refused as stale")
    func staleCommitRefused() throws {
        let (alice, bob, carol) = try threeMembers()
        let first = try alice.commit()
        let second = try bob.commit()
        guard case let .advanced(carolNext) = try carol.process(first.message) else {
            Issue.record("carol was not advanced")
            return
        }
        #expect(throws: MLSError.wrongEpoch(expected: carolNext.epoch, got: second.message.epoch)) {
            _ = try carolNext.process(second.message)
        }
    }

    @Test("a commit with a forged signature or confirmation tag is refused")
    func tamperedCommitRefused() throws {
        let (alice, bob, _) = try threeMembers()
        let commit = try alice.commit()
        var bytes = commit.message.encoded
        bytes[bytes.index(before: bytes.endIndex)] ^= 1
        let forgedTag = try MLSCommitMessage.decode(bytes)
        #expect(throws: MLSError.confirmationMismatch) { _ = try bob.process(forgedTag) }

        let forgedSignature = MLSCommitMessage(
            groupID: commit.message.groupID, epoch: commit.message.epoch, sender: commit.message.sender,
            commit: commit.message.commit, signature: Data(repeating: 0, count: 64),
            confirmationTag: commit.message.confirmationTag
        )
        #expect(throws: MLSError.badSignature) { _ = try bob.process(forgedSignature) }
    }

    @Test("a key package with a broken signature cannot be added")
    func badKeyPackageRefused() throws {
        let alice = try MLSGroup.create(groupID: room, bundle: bundle("alice/a"))
        let bob = try bundle("bob/b").keyPackage
        let forged = MLSKeyPackage(
            identity: Data("mallory/m".utf8), signatureKey: bob.signatureKey, initKey: bob.initKey,
            encryptionKey: bob.encryptionKey, signature: bob.signature
        )
        #expect(!forged.isValid)
        #expect(throws: MLSError.badSignature) { _ = try alice.commit(adding: [forged]) }
        #expect(try MLSKeyPackage.decode(bob.encoded) == bob)
    }

    @Test("a Welcome opens only for the key package it was made for")
    func welcomeAddressed() throws {
        let alice = try MLSGroup.create(groupID: room, bundle: bundle("alice/a"))
        let bob = try bundle("bob/b")
        let other = try bundle("bob/b")
        let add = try alice.commit(adding: [bob.keyPackage])
        let welcome = try MLSWelcome.decode(try #require(add.welcome).encoded)
        #expect(welcome.isAddressed(to: bob.keyPackage))
        #expect(!welcome.isAddressed(to: other.keyPackage))
        #expect(throws: MLSError.notAddressed) { _ = try MLSGroup.join(welcome, bundle: other) }
    }

    @Test("a returning device is removed and re-added in one commit")
    func replaceStaleLeaf() throws {
        let (alice, _, carol) = try threeMembers()
        let stale = try #require(alice.leaf(of: "bob/b"))
        let bobAgain = try bundle("bob/b")
        let commit = try alice.commit(adding: [bobAgain.keyPackage], removing: [stale])
        let rejoined = try MLSGroup.join(try #require(commit.welcome), bundle: bobAgain)
        guard case let .advanced(carolNext) = try carol.process(commit.message) else {
            Issue.record("carol was not advanced")
            return
        }
        #expect(rejoined.epochAuthenticator == carolNext.epochAuthenticator)
        #expect(carolNext.memberCount == 3)
    }

    // MARK: - RFC 9605 §5.2

    @Test("KIDs follow RFC 9605 Figure 9 (E = 4, context 0)")
    func keyIDLayout() {
        #expect(MLSSFrameKeys.keyID(leaf: 3, epoch: 14) == 0x3E)
        #expect(MLSSFrameKeys.keyID(leaf: 7, epoch: 14) == 0x7E)
        #expect(MLSSFrameKeys.keyID(leaf: 20, epoch: 14) == 0x14E)
        #expect(MLSSFrameKeys.keyID(leaf: 3, epoch: 15) == 0x3F)
        #expect(MLSSFrameKeys.keyID(leaf: 5, epoch: 15) == 0x5F)
        #expect(MLSSFrameKeys.keyID(leaf: 33, epoch: 17) == 0x211)
        #expect(MLSSFrameKeys.keyID(leaf: 51, epoch: 17) == 0x331)
        #expect(MLSSFrameKeys.epochTag(ofKeyID: 0x331) == 1)
    }

    @Test("the SFrame base key is the exporter's, with the sender told apart only by KID")
    func baseKeyIsExporter() throws {
        let (alice, _, _) = try threeMembers()
        let base = alice.secrets.export(label: "SFrame 1.0 Base Key", length: 32)
        let sealed = try SFrameSender(key: alice.sframeKey(for: 1, suite: .aes256GcmSha512))
            .protect(Data("x".utf8))
        let receiver = SFrameReceiver()
        receiver.add(SFrameKey(keyID: MLSSFrameKeys.keyID(leaf: 1, epoch: alice.epoch), baseKey: base))
        #expect(try receiver.unprotect(sealed) == Data("x".utf8))
    }

    // MARK: - Epoch change mid-stream

    @Test("a frame under the next epoch waits for its key instead of being dropped")
    func heldAcrossEpochChange() async throws {
        let (alice, bob, _) = try threeMembers()
        let update = try alice.commit()
        let receiver = SFrameReceiver()
        for key in bob.sframeKeys(suite: .aes256GcmSha512) { receiver.add(key) }
        let unprotector = MediaUnprotector(receiver: receiver, keyHold: .seconds(2))

        // Alice has moved; Bob has not processed her commit yet.
        let sender = SFrameSender(key: update.next.sframeKey(for: alice.ownLeaf, suite: .aes256GcmSha512))
        let object = TrackObjectFixture.object(payload: Data("new epoch".utf8))
        let sealed = try sender.protect(object.payload, metadata: SFrameMetadata.encode(for: object))
        let early = Task { await unprotector.unprotect(TrackObjectFixture.object(payload: sealed)) }

        try await Task.sleep(for: .milliseconds(50))
        guard case let .advanced(bobNext) = try bob.process(update.message) else {
            Issue.record("bob was not advanced")
            return
        }
        for key in bobNext.sframeKeys(suite: .aes256GcmSha512) { receiver.add(key) }
        await unprotector.keysChanged()

        #expect(await early.value?.payload == Data("new epoch".utf8))
        #expect(await unprotector.objectsAwaitingKey == 0)
    }
}

enum TrackObjectFixture {
    static func object(payload: Data) -> TrackObject {
        TrackObject(group: 1, object: 0, priority: 128, payload: payload, isKeyFrame: true)
    }
}
