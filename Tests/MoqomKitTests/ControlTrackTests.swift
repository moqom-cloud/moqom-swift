import Foundation
import Testing

@testable import MoqomCore
@testable import MoqomKit
@testable import MoqomLoopback

/// The room control track, end to end over the loopback relay.
///
/// The authority is a bare transport session rather than a `MoqomSession`,
/// because that is what it is in production: the log is published by the relay
/// and the control plane behind it, not by a participant's phone. A client
/// appears in these tests only as a reader — apart from one that checks a
/// moderator's action reaching the log, which is the self-hosted case.
/// A control entry as the room's authority writes it: signed for room-42.
func signedEntry(
    _ update: RoomUpdate,
    group: UInt64,
    object: UInt64,
    isKeyFrame: Bool = false,
    signer: RoomLogSigner = testAuthority,
    room: RoomID = "room-42"
) throws -> TrackObject {
    let payload = try update.encoded()
    return TrackObject(
        group: group,
        object: object,
        payload: payload,
        isKeyFrame: isKeyFrame,
        properties: ObjectProperties(
            authoritySignature: try signer.sign(payload, tenant: "acme", room: room)
        )
    )
}

@Suite("The room control track")
struct ControlTrackTests {
    private let endpoint = RelayEndpoint(host: "loopback", alpn: ["moqt-19"])
    private let alice = identity("alice")
    private let bob = identity("bob")

    private func viewer(
        _ name: String,
        relay: LoopbackRelay
    ) async throws -> MoqomSession {
        let session = MoqomSession(
            transport: LoopbackTransport(relay: relay),
            credentials: credentials(name),
            tenant: "acme",
            clock: { .zero },
            sleeper: { _ in try? await Task.sleep(for: .milliseconds(1)) }
        )
        try await session.connect(to: endpoint)
        return session
    }

    /// The room's authority: a session that publishes the control track.
    private func authority(
        relay: LoopbackRelay,
        state: RoomSnapshot = RoomSnapshot(),
        cadence: RoomLogPublisher.Cadence = .default
    ) async throws -> (any TransportSession, RoomLogPublisher) {
        let session = try await LoopbackTransport(relay: relay).connect(
            to: endpoint,
            credentials: credentials("control-plane", device: "relay-0001")
        )
        let publisher = try await RoomLogPublisher.opening(
            room: "room-42",
            tenant: "acme",
            on: session,
            signer: testAuthority,
            state: state,
            cadence: cadence
        )

        // An authority that has said nothing looks exactly like a room with no
        // authority, so taking it starts by asserting the state.
        try await publisher.snapshot()
        return (session, publisher)
    }

    /// Put somebody in the roster without giving them media, by announcing the
    /// namespace that *is* the roster entry.
    private func announce(
        _ who: ParticipantIdentity,
        relay: LoopbackRelay
    ) async throws -> (any TransportSession, any AnnouncementHandle) {
        let session = try await LoopbackTransport(relay: relay).connect(
            to: endpoint,
            credentials: DeviceCredentials(
                identity: who,
                token: Data("token".utf8),
                deviceKey: nil
            )
        )
        let handle = try await session.announce(
            MoqomNamespaces.participant(tenant: "acme", room: "room-42", identity: who)
        )
        return (session, handle)
    }

    @Test("what the authority says about a participant reaches every client")
    func grantsReachTheRoom() async throws {
        let relay = LoopbackRelay()
        let (_, log) = try await authority(relay: relay)
        let (_, _) = try await announce(alice, relay: relay)

        let watcher = try await viewer("bob", relay: relay)
        let room = try await watcher.join(room: "room-42")
        #expect(await eventually { await room.roster[alice] != nil })

        try await log.append(.grants(alice, Grants(publish: .camera, moderation: .moderator)))

        #expect(
            await eventually {
                await room.roster[alice]?.grants.publish == .camera
            }
        )
        #expect(await room.roster[alice]?.role == .cohost)

        await watcher.close()
    }

    @Test("a client joining later reads the state, not the next thing to change")
    func aLateJoinerReadsTheState() async throws {
        // The property that makes a control *track* work where a control message
        // would not: every group opens with a complete state, so subscribing is
        // enough. A client that had to wait for the next change would show a room
        // full of viewers until somebody happened to be promoted.
        let relay = LoopbackRelay()
        let (_, log) = try await authority(relay: relay)
        let (_, _) = try await announce(alice, relay: relay)

        try await log.append(.grants(alice, Grants(publish: .full, isOwner: true)))
        try await log.append(.spotlight(alice))

        let watcher = try await viewer("bob", relay: relay)
        let room = try await watcher.join(room: "room-42")

        #expect(await eventually { await room.roster[alice]?.grants.isOwner == true })
        #expect(await room.currentState.stage.spotlighted == alice)
        #expect(await room.roster[alice]?.isSpotlighted == true)
        #expect(await room.logPosition > 0)

        await watcher.close()
    }

    @Test("a change that arrives before its participant is applied when they announce")
    func attributesWaitForTheAnnouncement() async throws {
        // Ordinary rather than exotic: a promotion is what *causes* somebody to
        // start publishing, so their grants precede the announcement that puts
        // them in the roster. Dropping the entry would leave a cohost looking
        // like a viewer until the next snapshot.
        let relay = LoopbackRelay()
        let (_, log) = try await authority(relay: relay)

        let watcher = try await viewer("bob", relay: relay)
        let room = try await watcher.join(room: "room-42")

        try await log.append(.grants(alice, Grants(publish: .camera)))
        #expect(await eventually { await room.logPosition > 0 })
        #expect(await room.roster[alice] == nil)

        let (_, _) = try await announce(alice, relay: relay)

        #expect(await eventually { await room.roster[alice]?.grants.publish == .camera })

        await watcher.close()
    }

    @Test("a client that was offline is told what it missed when it returns")
    func aReturningClientCatchesUp() async throws {
        // The whole point of the sequence numbers, and the answer to "what
        // happens to a moderation decision taken while somebody is in a tunnel".
        // Nothing here retries: the client resubscribes at the latest group,
        // which opens with a snapshot, and the entries it had already applied are
        // recognised and ignored.
        let relay = LoopbackRelay()
        let (_, log) = try await authority(relay: relay)
        let (_, _) = try await announce(alice, relay: relay)

        let watcher = try await viewer("bob", relay: relay)
        let room = try await watcher.join(room: "room-42")
        try await log.append(.grants(alice, Grants(publish: .camera)))
        #expect(await eventually { await room.roster[alice]?.grants.publish == .camera })
        let before = await room.logPosition

        // Offline, and kept offline while the room changes underneath.
        await relay.setAcceptingConnections(false)
        await relay.drop(bob)
        #expect(await eventually { await watcher.state != .established })

        try await log.append(.mute(alice, forEveryone: .audio, forAudience: []))
        try await log.append(.spotlight(alice))

        await relay.setAcceptingConnections(true)

        #expect(await eventually { await watcher.state == .established })
        #expect(
            await eventually {
                await room.roster[alice]?.mute.forcedForEveryone == .audio
            }
        )
        #expect(await room.currentState.stage.spotlighted == alice)

        // Not just the entries written during the outage: the grant from before
        // it is back too, restored by the snapshot that opens the group rather
        // than remembered across a connection that no longer exists.
        #expect(await room.roster[alice]?.grants.publish == .camera)
        #expect(await room.logPosition > before)

        await watcher.close()
    }

    @Test("a hole in the log is reported, and closed by the next snapshot")
    func aGapIsClosedByASnapshot() async throws {
        // Written through a raw writer so that a sequence can be skipped, which
        // is what a lost object looks like from the receiving end. The recovery
        // needs no mechanism of its own: the next group starts with a complete
        // state.
        let relay = LoopbackRelay()
        let session = try await LoopbackTransport(relay: relay).connect(
            to: endpoint,
            credentials: credentials("control-plane", device: "relay-0001")
        )
        let track = try FullTrackName(
            namespace: MoqomNamespaces.room(tenant: "acme", room: "room-42"),
            name: TrackName(RoomUpdate.trackName)
        )
        let writer = try await session.publish(track, priority: RoomLogPublisher.priority)
        let (_, _) = try await announce(alice, relay: relay)

        var state = RoomSnapshot()
        state[alice] = ParticipantControl(identity: alice)
        try await writer.startGroup(1)
        try await writer.write(
            signedEntry(RoomUpdate(sequence: 1, state), group: 1, object: 0, isKeyFrame: true)
        )
        try await writer.write(
            // Sequence 3, so 2 is missing.
            signedEntry(RoomUpdate(sequence: 3, .spotlight(alice)), group: 1, object: 1)
        )

        let watcher = try await viewer("bob", relay: relay)
        let room = try await watcher.join(room: "room-42")

        #expect(await eventually { await room.logPosition == 1 })
        #expect(await room.isAwaitingSnapshot)
        #expect(await room.currentState.stage.spotlighted == nil)

        // A new group, which is a new complete state.
        state.stage.spotlighted = alice
        try await writer.startGroup(2)
        try await writer.write(
            signedEntry(RoomUpdate(sequence: 4, state), group: 2, object: 0, isKeyFrame: true)
        )

        #expect(await eventually { await room.currentState.stage.spotlighted == alice })
        #expect(await !room.isAwaitingSnapshot)
        #expect(await room.logPosition == 4)

        await watcher.close()
    }

    @Test("only entries the room's authority signed for this room are applied")
    func onlySignedEntriesApply() async throws {
        // Written by a party with the relay's position: it can put anything on
        // the track, and has every key but the authority's.
        let relay = LoopbackRelay()
        let session = try await LoopbackTransport(relay: relay).connect(
            to: endpoint,
            credentials: credentials("control-plane", device: "relay-0001")
        )
        let track = try FullTrackName(
            namespace: MoqomNamespaces.room(tenant: "acme", room: "room-42"),
            name: TrackName(RoomUpdate.trackName)
        )
        let writer = try await session.publish(track, priority: RoomLogPublisher.priority)
        let (_, _) = try await announce(alice, relay: relay)
        let watcher = try await viewer("bob", relay: relay)
        let room = try await watcher.join(room: "room-42")

        var state = RoomSnapshot()
        state[alice] = ParticipantControl(identity: alice)
        state.stage.spotlighted = alice
        let impostor = try RoomLogSigner(seed: Data(repeating: 0x01, count: 32))
        let genuine = try signedEntry(RoomUpdate(sequence: 1, state), group: 1, object: 0)

        try await writer.startGroup(1)
        // Unsigned.
        try await writer.write(
            TrackObject(group: 1, object: 0, payload: genuine.payload, isKeyFrame: true)
        )
        // Signed, by a key the room does not trust.
        try await writer.write(
            signedEntry(RoomUpdate(sequence: 1, state), group: 1, object: 1, signer: impostor)
        )
        // Signed by the authority, for another room.
        try await writer.write(
            signedEntry(RoomUpdate(sequence: 1, state), group: 1, object: 2, room: "room-7")
        )
        // The authority's signature, over different words.
        var altered = state
        altered.stage.spotlighted = bob
        try await writer.write(
            TrackObject(
                group: 1, object: 3, payload: try RoomUpdate(sequence: 1, altered).encoded(),
                properties: genuine.properties
            )
        )

        #expect(await eventually { await room.controlEntriesRefused == 4 })
        #expect(await room.logPosition == 0)
        #expect(await room.currentState.stage.spotlighted == nil)

        try await writer.write(
            TrackObject(
                group: 1, object: 4, payload: genuine.payload, properties: genuine.properties
            )
        )
        #expect(await eventually { await room.currentState.stage.spotlighted == alice })
        #expect(await room.logPosition == 1)

        await watcher.close()
    }

    @Test("a seed always names the same key")
    func aSeedNamesTheSameKey() throws {
        let again = try RoomLogSigner(seed: Data(repeating: 0xA7, count: 32))
        #expect(again.id == testAuthority.id)
        #expect(again.verificationKey == testAuthority.verificationKey)
        #expect(testAuthority.verificationKey.key.count == 1952)
    }

    @Test("being removed tells the client why instead of stopping the stream")
    func evictionIsExplained() async throws {
        let relay = LoopbackRelay()
        let (_, log) = try await authority(relay: relay)
        let watcher = try await viewer("bob", relay: relay)
        let room = try await watcher.join(room: "room-42")
        #expect(await eventually { await room.logPosition > 0 })

        try await log.append(.evicted(bob))

        #expect(await eventually { await room.currentState.lifecycle.isEnded })
        guard case let .ended(terminal) = await room.currentState.lifecycle else {
            return #expect(Bool(false), "expected the room to have ended")
        }

        #expect(terminal.reason == .moderated(code: .operatorAction))
        #expect(!terminal.isRetryable)

        await watcher.close()
    }

    @Test("the room ending reaches a viewer as media, before anything closes")
    func theEndArrivesOnTheTrack() async throws {
        let relay = LoopbackRelay()
        let (_, log) = try await authority(relay: relay)
        let watcher = try await viewer("bob", relay: relay)
        let room = try await watcher.join(room: "room-42")
        #expect(await eventually { await room.logPosition > 0 })

        try await log.append(.lifecycle(.ended(.hostEnded)))

        #expect(await eventually { await room.currentState.lifecycle.isEnded })
        guard case let .ended(terminal) = await room.currentState.lifecycle else {
            return #expect(Bool(false), "expected the room to have ended")
        }
        #expect(terminal.reason == .hostEnded)

        await watcher.close()
    }

    @Test("a recorder that attaches while nobody is looking is still disclosed")
    func watchdogsAreDisclosed() async throws {
        let relay = LoopbackRelay()
        let (_, log) = try await authority(relay: relay)
        let watchdog = Watchdog(
            id: "rec-1",
            kind: .recording,
            operatedBy: .thirdParty("Acme Compliance Ltd"),
            descriptor: "Recording for your compliance team",
            scope: try MoqomNamespaces.room(tenant: "acme", room: "room-42"),
            attachedAt: Date()
        )
        try await log.append(.watchdogs([watchdog]))

        let watcher = try await viewer("bob", relay: relay)
        let room = try await watcher.join(room: "room-42")

        #expect(await eventually { await room.currentState.isRecording })
        #expect(await room.watchdogs.first?.descriptor == "Recording for your compliance team")

        // Room chrome, never a tile, and never a participant.
        #expect(await room.roster.count == 0)

        await watcher.close()
    }

    @Test("a moderator's action reaches the log when the client holds authority")
    func moderationIsPublished() async throws {
        // The self-hosted shape: whoever runs the room writes its log. Against a
        // managed relay a participant's token does not authorise this track, and
        // the publish is refused before any of it matters.
        let relay = LoopbackRelay()
        let host = try await viewer("alice", relay: relay)
        let hostRoom = try await host.join(room: "room-42")
        let log = try await hostRoom.assumeAuthority(signer: testAuthority)
        let (_, _) = try await announce(bob, relay: relay)
        #expect(await eventually { await hostRoom.roster[bob] != nil })

        try await hostRoom.moderate(
            .forceMute(bob, .audio, until: nil),
            as: Grants(moderation: .superModerator)
        )

        #expect(
            await eventually {
                await log.state[bob]?.mutedForEveryone == .audio
            }
        )

        try await hostRoom.moderate(.spotlight(bob), as: Grants(moderation: .superModerator))
        #expect(await eventually { await log.state.stage.spotlighted == bob })

        // Bans are control-plane records. Publishing one here would show somebody
        // as gone on a decision the control plane may still refuse.
        let position = await log.sequence
        try await hostRoom.moderate(
            .banFromTenant(bob.username, until: nil),
            as: Grants(moderation: .owner, isOwner: true)
        )
        #expect(await log.sequence == position)

        await host.close()
    }

    @Test("an authority that reconnects carries on numbering where it left off")
    func authorityNumberingSurvivesAReconnect() async throws {
        // Restarting the sequence would make every reader dismiss what follows as
        // something it had already applied, and the room would silently stop
        // updating — with the log still being written, which is the worst version
        // of this failure.
        let relay = LoopbackRelay()
        let host = try await viewer("alice", relay: relay)
        let hostRoom = try await host.join(room: "room-42")
        let first = try await hostRoom.assumeAuthority(signer: testAuthority)
        try await first.append(.spotlight(identity("alice")))
        let reached = await first.sequence
        let group = await first.group
        #expect(reached == 2)

        await relay.drop(identity("alice"))
        #expect(await eventually { await host.state == .established })
        #expect(await eventually { await hostRoom.roomAuthority !== first })

        let second = try #require(await hostRoom.roomAuthority)
        try await second.append(.stage(StageSnapshot(isLocked: true)))

        #expect(await second.sequence == reached + 1)

        // A new group as well as a new number, because MOQT requires groups to
        // increase within a track and the track did not change when the
        // connection did.
        #expect(await second.group > group)

        await host.close()
    }
}
