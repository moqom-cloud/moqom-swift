import Foundation
import MoqomCore
import Testing

@testable import MoqomKit

/// What MoqomKit adds on top of MoqomMLS's groups: frames carried across an
/// epoch change. The group protocol itself is held to its claims, and to the
/// shared vectors, in moqom-security's MoqomMLSTests.
@Suite("MLS group")
struct MLSGroupTests {
    private let room = Data("acme/room-42".utf8)

    @Test(
        "a frame under the next epoch waits for its key instead of being dropped",
        arguments: MLSCipherSuite.supported
    )
    func heldAcrossEpochChange(suite: MLSCipherSuite) async throws {
        var alice = try MLSGroup.create(
            groupID: room, bundle: MLSKeyPackageBundle.generate(identity: "alice/a", cipherSuite: suite)
        )
        let bobBundle = try MLSKeyPackageBundle.generate(identity: "bob/b", cipherSuite: suite)
        let addBob = try alice.commit(adding: [bobBundle.keyPackage])
        alice = addBob.next
        let bob = try MLSGroup.join(try #require(addBob.welcome), bundle: bobBundle)

        let update = try alice.commit()
        let receiver = SFrameReceiver()
        for key in bob.sframeKeys(suite: .aes256GcmSha512) { receiver.add(key) }
        let unprotector = MediaUnprotector(receiver: receiver, keyHold: .seconds(2))

        // Alice has moved; Bob has not processed her commit yet.
        let sender = SFrameSender(key: update.next.sframeKey(for: alice.ownLeaf, suite: .aes256GcmSha512))
        let object = TrackObjectFixture.object(payload: Data("new epoch".utf8))
        let track = TrackObjectFixture.track
        let sealed = try sender.protect(object.payload, metadata: SFrameMetadata(object, on: track))
        let early = Task { await unprotector.unprotect(TrackObjectFixture.object(payload: sealed), on: track) }

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
    static let track = try! FullTrackName(
        namespace: TrackNamespace(["moqom", "room", "alice"]), name: TrackName("video")
    )

    static func object(payload: Data) -> TrackObject {
        TrackObject(group: 1, object: 0, priority: 128, payload: payload, isKeyFrame: true)
    }
}
