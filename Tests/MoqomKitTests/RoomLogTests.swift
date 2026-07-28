import Foundation
import Testing

@testable import MoqomCore
@testable import MoqomKit

private let alice = identity("alice")
private let bob = identity("bob")

private func snapshot(_ sequence: UInt64, _ state: RoomSnapshot = RoomSnapshot()) -> RoomUpdate {
    RoomUpdate(sequence: sequence, state)
}

private func change(_ sequence: UInt64, _ change: RoomChange) -> RoomUpdate {
    RoomUpdate(sequence: sequence, change)
}

private func grants(_ who: ParticipantIdentity, _ publish: PublishScope) -> RoomChange {
    .grants(who, Grants(publish: publish))
}

@Suite("Room log ordering")
struct RoomLogOrderingTests {
    @Test("a snapshot founds the log and everything after it applies in order")
    func snapshotThenChanges() {
        var log = RoomLog()

        #expect(log.accept(snapshot(1)).count == 1)
        #expect(log.isFounded)
        #expect(log.applied == 1)

        #expect(log.accept(change(2, grants(alice, .camera))).count == 1)
        #expect(log.accept(change(3, .spotlight(alice))).count == 1)
        #expect(log.applied == 3)
        #expect(!log.needsSnapshot)
    }

    @Test("a change before any snapshot is held, because there is no state to change")
    func changeBeforeSnapshotWaits() {
        // The case that produces this: subscribing mid-group against a relay
        // with no cache, so the deltas arrive and the snapshot that opened the
        // group is already gone. Applying grants onto a room this client knows
        // nothing about would leave it authoritative about one field and blank
        // about the rest.
        var log = RoomLog()

        #expect(log.accept(change(7, grants(alice, .camera))).isEmpty)
        #expect(!log.isFounded)
        #expect(log.needsSnapshot)
        #expect(log.holding == 1)
    }

    @Test("entries that arrive out of order are held and released in order")
    func reordersWithinTheBuffer() {
        var log = RoomLog()
        _ = log.accept(snapshot(1))

        #expect(log.accept(change(4, .spotlight(bob))).isEmpty)
        #expect(log.accept(change(3, grants(bob, .audioOnly))).isEmpty)
        #expect(log.applied == 1)
        #expect(log.missing == 2 ..< 3)

        let released = log.accept(change(2, grants(alice, .camera)))

        #expect(released.count == 3)
        #expect(log.applied == 4)
        #expect(log.missing == nil)

        // In log order, not arrival order, which is the entire point: grants
        // applied after the spotlight that outranks them would leave the two
        // fields describing different moments.
        guard case let .change(first) = released[0],
              case let .change(second) = released[1],
              case let .change(third) = released[2]
        else { return #expect(Bool(false), "expected three changes") }
        #expect(first == grants(alice, .camera))
        #expect(second == grants(bob, .audioOnly))
        #expect(third == .spotlight(bob))
    }

    @Test("an entry already applied is ignored rather than applied twice")
    func duplicatesAreIgnored() {
        var log = RoomLog()
        _ = log.accept(snapshot(1))
        _ = log.accept(change(2, grants(alice, .camera)))

        #expect(log.accept(change(2, grants(alice, .camera))).isEmpty)
        #expect(log.accept(change(1, grants(alice, .none))).isEmpty)
        #expect(log.duplicates == 2)
        #expect(log.applied == 2)
    }

    @Test("a version this build cannot read is refused, not partly applied")
    func futureVersionsAreRefused() {
        var log = RoomLog()
        let ahead = RoomUpdate(
            sequence: 1,
            body: .snapshot(RoomSnapshot()),
            version: RoomUpdate.currentVersion + 1
        )

        #expect(log.accept(ahead).isEmpty)
        #expect(log.rejected == 1)
        #expect(!log.isFounded)
    }
}

@Suite("Room log recovery")
struct RoomLogRecoveryTests {
    @Test("a snapshot closes a gap no fetch ever asked about")
    func snapshotHealsAGap() {
        // The property that makes the control track survivable without help: a
        // group boundary is a complete state, so a hole in the middle of a
        // conversation resolves itself at the next one.
        var log = RoomLog()
        _ = log.accept(snapshot(1))
        _ = log.accept(change(5, .spotlight(bob)))

        #expect(log.needsSnapshot)
        #expect(log.holding == 1)

        var state = RoomSnapshot()
        state[alice] = ParticipantControl(identity: alice, grants: Grants(publish: .camera))
        let applied = log.accept(snapshot(6, state))

        #expect(applied.count == 1)
        #expect(log.applied == 6)
        #expect(!log.needsSnapshot)
        #expect(log.holding == 0)
    }

    @Test("a snapshot older than what has been applied is not a regression")
    func staleSnapshotsAreIgnored() {
        // A fetch answers with the group it holds, which may predate the live
        // edge this client has already reached. Applying it would undo the
        // present.
        var log = RoomLog()
        _ = log.accept(snapshot(10))
        _ = log.accept(change(11, grants(alice, .camera)))

        #expect(log.accept(snapshot(4)).isEmpty)
        #expect(log.applied == 11)
        #expect(log.duplicates == 1)
    }

    @Test("re-reading a whole group after a reconnect changes nothing")
    func replayIsIdempotent() {
        // What actually happens on the wire: the client resubscribes at the
        // latest group and a fetch returns objects it has already seen. The
        // sequence numbers make the overlap free, and the absolute-value rule
        // makes it harmless even where they do not.
        var log = RoomLog()
        let group = [
            snapshot(1),
            change(2, grants(alice, .camera)),
            change(3, .mute(alice, forEveryone: .audio, forAudience: [])),
            change(4, .spotlight(alice)),
        ]
        for update in group { _ = log.accept(update) }

        var state = RoomSnapshot()
        for update in group {
            if case let .change(entry) = update.body { state.apply(entry) }
        }

        var again = log
        for update in group { #expect(again.accept(update).isEmpty) }

        #expect(again.applied == log.applied)
        #expect(again.duplicates == 4)

        var replayed = RoomSnapshot()
        for update in group + group {
            if case let .change(entry) = update.body { replayed.apply(entry) }
        }
        #expect(replayed == state)
    }

    @Test("a buffer that fills stops growing and asks for a snapshot instead")
    func aFullBufferGivesUpAndSaysSo() {
        var log = RoomLog(policy: RoomLog.Policy(buffer: 4))
        _ = log.accept(snapshot(1))

        for sequence in UInt64(3) ... 12 {
            _ = log.accept(change(sequence, .spotlight(alice)))
        }

        #expect(log.holding == 4)
        #expect(log.isTruncated)
        #expect(log.needsSnapshot)

        // Filling the hole releases what was held and does not pretend the
        // discarded entries came back.
        _ = log.accept(change(2, grants(alice, .camera)))
        #expect(log.applied == 6)
        #expect(log.isTruncated)

        _ = log.accept(snapshot(20))
        #expect(!log.isTruncated)
        #expect(!log.needsSnapshot)
    }
}

@Suite("Room state folding")
struct RoomSnapshotFoldTests {
    @Test("a mute carries both scopes so a replay cannot apply half of it")
    func muteCarriesBothScopes() {
        var state = RoomSnapshot()
        state.apply(.mute(alice, forEveryone: .audio, forAudience: .video))

        #expect(state[alice]?.mutedForEveryone == .audio)
        #expect(state[alice]?.mutedForAudience == .video)
    }

    @Test("a change about somebody who has not announced yet is kept for them")
    func attributesWaitForTheirParticipant() {
        // Grants can precede the announcement — a promotion is what causes
        // somebody to start publishing — and a viewer who publishes nothing
        // never announces at all.
        var state = RoomSnapshot()
        state.apply(grants(bob, .camera))

        #expect(state[bob]?.grants.publish == .camera)
        #expect(state.participants.count == 1)
    }

    @Test("eviction takes the spotlight and the queue place with it")
    func evictionClearsDerivedState() {
        var state = RoomSnapshot()
        state.apply(grants(alice, .camera))
        state.apply(.stage(StageSnapshot(spotlighted: alice, queue: [alice, bob])))
        state.apply(.evicted(alice))

        #expect(state[alice] == nil)
        #expect(state.stage.spotlighted == nil)
        #expect(state.stage.queue == [bob])
    }

    @Test("a stage entry carries the spotlight, so the two cannot disagree")
    func stageOwnsTheSpotlight() {
        var state = RoomSnapshot()
        state.apply(.spotlight(alice))
        state.apply(.stage(StageSnapshot(isLocked: true)))

        #expect(state.stage.spotlighted == nil)
        #expect(state.stage.isLocked)
    }

    @Test("applying a stage snapshot leaves invitations in flight alone")
    func invitationsSurviveAStageSnapshot() {
        // Invitations are handshakes on somebody's clock, not room state. A
        // snapshot that restored them would deliver a promotion the invitee
        // stopped looking at thirty seconds ago.
        var stage = StageState()
        stage.pending = [
            StageInvitation(
                direction: .invitation,
                subject: bob,
                issuedBy: alice,
                offered: .camera,
                issuedAt: .seconds(1)
            ),
        ]

        let applied = StageSnapshot(isLocked: true, queue: [bob]).applied(to: stage)

        #expect(applied.pending.count == 1)
        #expect(applied.isLocked)
        #expect(applied.queue == [bob])
    }
}

@Suite("Room log wire form")
struct RoomLogWireTests {
    @Test("every change round-trips")
    func changesRoundTrip() throws {
        let watchdog = Watchdog(
            id: "w-1",
            kind: .custom("acme-archiver"),
            operatedBy: .thirdParty("Acme Compliance Ltd"),
            descriptor: "Recording for your compliance team",
            scope: try MoqomNamespaces.room(tenant: "acme", room: "room-42"),
            attachedAt: Date(timeIntervalSince1970: 1_700_000_000),
            health: .degraded,
            isBillable: true,
            pinnedLayer: "video/1080p"
        )

        let changes: [RoomChange] = [
            .grants(alice, Grants(publish: .full, moderation: .superModerator, isOwner: true)),
            .presence(alice, .reconnecting),
            .mute(alice, forEveryone: .audio, forAudience: .video),
            .spotlight(alice),
            .spotlight(nil),
            .stage(StageSnapshot(slotLimit: 4, isLocked: true, spotlighted: bob, queue: [alice])),
            .lifecycle(.ended(.moderated(.adultContent))),
            .lifecycle(.actingHost(bob)),
            .lifecycle(.scheduled(startsAt: Date(timeIntervalSince1970: 1_700_000_000))),
            .watchdogs([watchdog]),
            .evicted(bob),
        ]

        for entry in changes {
            let update = RoomUpdate(sequence: 9, entry)
            let decoded = try RoomUpdate.decode(try update.encoded())
            #expect(decoded == update, "\(entry)")
        }
    }

    @Test("a snapshot round-trips")
    func snapshotRoundTrips() throws {
        var state = RoomSnapshot()
        state[alice] = ParticipantControl(
            identity: alice,
            grants: Grants(publish: .camera, moderation: .moderator),
            presence: .away,
            mutedForEveryone: .audio
        )
        state.stage = StageSnapshot(isLocked: true, spotlighted: alice)
        state.lifecycle = .ended(.hostEnded)

        let update = RoomUpdate(sequence: 1, state)
        #expect(try RoomUpdate.decode(try update.encoded()) == update)
    }

    @Test("the same state always produces the same bytes")
    func encodingIsDeterministic() throws {
        let update = RoomUpdate(sequence: 3, grants(alice, .camera))
        #expect(try update.encoded() == (try update.encoded()))
    }

    @Test("the control track sits under the room, where no participant can be read from it")
    func controlTrackIsNotAParticipant() throws {
        let room = try MoqomNamespaces.room(tenant: "acme", room: "room-42")

        // The roster is namespaces under the room prefix with exactly two
        // trailing fields. The room's own prefix has none, so a client building
        // a roster from announcements cannot turn the control track into a
        // person.
        #expect(ParticipantSlot(announced: room, under: room) == nil)
        #expect(RoomUpdate.trackName.hasPrefix("."))
    }

    @Test("a namespace is validated when it is decoded, not trusted")
    func namespacesValidateOnDecode() throws {
        let empty = Data(#"[""]"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(TrackNamespace.self, from: empty)
        }

        let namespace = try MoqomNamespaces.room(tenant: "acme", room: "room-42")
        let encoded = try JSONEncoder().encode(namespace)
        #expect(try JSONDecoder().decode(TrackNamespace.self, from: encoded) == namespace)
    }
}

@Suite("Room log forward compatibility")
struct RoomLogCompatibilityTests {
    /// A change of a kind this build has never heard of, as an older build would
    /// see one published by a newer authority.
    private func fromTheFuture(_ sequence: UInt64, kind: String = "somethingNew") throws -> RoomUpdate {
        let json = """
        {"sequence":\(sequence),"version":1,"change":{"change":"\(kind)","whatever":{"x":1}}}
        """
        return try RoomUpdate.decode(Data(json.utf8))
    }

    @Test("an unknown change kind advances the log instead of holing it")
    func unknownKindDoesNotStall() throws {
        // The failure this prevents: a decode that throws never reaches the log,
        // so the sequence stops, every later entry is held behind the gap, and
        // the reader sits in repair fetching a group it still cannot read.
        var log = RoomLog()
        _ = log.accept(snapshot(1))

        let applied = log.accept(try fromTheFuture(2))
        #expect(applied.count == 1)
        #expect(log.applied == 2)
        #expect(!log.needsSnapshot)
        #expect(log.holding == 0)

        // And the reader is still current on what it does understand.
        #expect(log.accept(change(3, grants(alice, .camera))).count == 1)
        #expect(log.applied == 3)
    }

    @Test("skipping is counted apart from refusing, because they mean opposite things")
    func skippingIsCountedSeparately() throws {
        var log = RoomLog()
        _ = log.accept(snapshot(1))
        _ = log.accept(try fromTheFuture(2))

        #expect(log.unrecognised == 1)
        // Not a refusal: the entry was read past, and the log is whole.
        #expect(log.rejected == 0)
        #expect(!log.hasGapAfterUnknown)
    }

    @Test("a version this build cannot read is still refused outright")
    func newerVersionsAreStillRefused() throws {
        // The other half of the rule. An unknown *kind* is additive and safe to
        // skip; an unknown *version* means the entries themselves may not mean
        // what this build thinks, and guessing on an authorisation path is the
        // thing the version field exists to prevent.
        var log = RoomLog()
        _ = log.accept(snapshot(1))

        let ahead = RoomUpdate(
            sequence: 2,
            body: .change(.spotlight(alice)),
            version: RoomUpdate.currentVersion + 1
        )
        #expect(log.accept(ahead).isEmpty)
        #expect(log.rejected == 1)
        #expect(log.unrecognised == 0)
        #expect(log.applied == 1)
    }

    @Test("an unknown kind held behind a gap is counted once, when it applies")
    func heldUnknownIsCountedOnce() throws {
        var log = RoomLog()
        _ = log.accept(snapshot(1))

        #expect(log.accept(try fromTheFuture(3)).isEmpty)
        #expect(log.unrecognised == 0, "not counted while it is merely held")

        let released = log.accept(change(2, grants(alice, .camera)))
        #expect(released.count == 2)
        #expect(log.unrecognised == 1)
        #expect(log.applied == 3)
    }

    @Test("folding an unknown kind into a snapshot changes nothing")
    func unknownFoldsToNothing() throws {
        var state = RoomSnapshot(participants: [ParticipantControl(identity: alice)])
        let before = state
        state.apply(.unrecognised("somethingNew"))
        #expect(state == before)
    }
}

private extension RoomLog {
    /// Whether an unknown kind left the log wanting a snapshot, which it must not.
    var hasGapAfterUnknown: Bool { isFounded && needsSnapshot }
}

@Suite("Audiences")
struct AudienceTests {
    private func user(_ name: String) throws -> Username { try Username(name) }

    @Test("a cohort with no cohost is the organic audience, not a missing one")
    func unattributedIsACohort() throws {
        let audiences = Audiences(cohorts: [
            .init(via: try user("bea"), viewers: 1200),
            .init(via: nil, viewers: 300),
        ])

        #expect(audiences[try user("bea")] == 1200)
        #expect(audiences.unattributed == 300)
        #expect(audiences.total == 1500)
        // Only the cohorts somebody brought, so a host UI cannot accidentally
        // draw "nobody" as a cohost tile.
        #expect(audiences.attributed.count == 1)
    }

    @Test("a cohost nobody brought viewers for reads as zero, not as absent")
    func absentCohostIsZero() throws {
        #expect(Audiences()[try user("bea")] == 0)
        #expect(Audiences().total == 0)
        #expect(Audiences().isExact)
    }

    @Test("cohorts are ordered largest first, so every client draws the same order")
    func attributedIsOrdered() throws {
        let audiences = Audiences(cohorts: [
            .init(via: try user("ana"), viewers: 10),
            .init(via: nil, viewers: 9000),
            .init(via: try user("cy"), viewers: 500),
            .init(via: try user("bea"), viewers: 500),
        ])

        #expect(audiences.attributed.map(\.viewers) == [500, 500, 10])
        // Ties broken by name rather than left to dictionary order, or two
        // clients would disagree about which of two equal cohorts comes first.
        #expect(audiences.attributed.compactMap(\.via?.value) == ["bea", "cy", "ana"])
    }

    @Test("a coarsened count says so, so a UI cannot print it as exact")
    func resolutionIsCarried() throws {
        let coarse = Audiences.Audience(via: try user("bea"), viewers: 1_204_000, resolution: 1000)
        #expect(!coarse.isExact)
        #expect(!Audiences(cohorts: [coarse]).isExact)

        // A resolution below one is meaningless rather than an error to throw:
        // there is no such thing as finer than exact.
        #expect(Audiences.Audience(via: nil, viewers: 3, resolution: 0).resolution == 1)
    }

    @Test("audiences survive the wire, in a snapshot and as a change")
    func roundTrips() throws {
        let audiences = Audiences(cohorts: [
            .init(via: try user("bea"), viewers: 1_204_000, resolution: 1000),
            .init(via: nil, viewers: 317),
        ])

        let asChange = try RoomUpdate(sequence: 4, .audiences(audiences)).encoded()
        #expect(try RoomUpdate.decode(asChange).body == .change(.audiences(audiences)))

        let asSnapshot = try RoomUpdate(sequence: 5, RoomSnapshot(audiences: audiences)).encoded()
        guard case let .snapshot(state) = try RoomUpdate.decode(asSnapshot).body else {
            Issue.record("not a snapshot")
            return
        }
        #expect(state.audiences == audiences)
    }

    @Test("audiences replace wholesale, because a per-cohost delta would drift")
    func foldsAsAWholeValue() throws {
        var state = RoomSnapshot(audiences: Audiences(cohorts: [
            .init(via: try user("ana"), viewers: 10),
            .init(via: try user("bea"), viewers: 20),
        ]))

        state.apply(.audiences(Audiences(cohorts: [.init(via: try user("ana"), viewers: 11)])))

        // Bea is gone rather than left at twenty. The authority's account is
        // complete, so an omission is a statement.
        #expect(state.audiences[try user("bea")] == 0)
        #expect(state.audiences[try user("ana")] == 11)
    }

    @Test("an authority that does not attribute reads as nobody knowing")
    func emptyIsHonest() throws {
        let state = try RoomUpdate.decode(
            try RoomUpdate(sequence: 1, RoomSnapshot()).encoded()
        )
        guard case let .snapshot(snapshot) = state.body else {
            Issue.record("not a snapshot")
            return
        }
        #expect(snapshot.audiences.cohorts.isEmpty)
        #expect(snapshot.audiences.total == 0)
    }
}
