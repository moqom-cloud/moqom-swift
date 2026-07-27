import Foundation
import Testing

@testable import MoqomCore
@testable import MoqomKit

@Suite("Watchdogs are not participants")
struct WatchdogTests {
    private let prefix = try! MoqomNamespaces.room(tenant: "acme", room: "room-42")

    private func namespace(_ user: String, _ device: String = "iphone-0001") -> TrackNamespace {
        try! MoqomNamespaces.participant(
            tenant: "acme",
            room: "room-42",
            identity: identity(user, device: device)
        )
    }

    @Test("the roster is built from announcements and has no other input")
    func rosterComesFromAnnouncements() {
        let roster = Roster(
            announcements: [namespace("alice"), namespace("bob")],
            under: prefix
        )
        #expect(roster.count == 2)
        #expect(roster.participants.map(\.username.value) == ["alice", "bob"])
    }

    @Test("a recorder cannot be constructed into the roster, because it announces nothing")
    func watchdogHasNoSlot() {
        // The structural claim. A watchdog's scope is the room prefix itself —
        // it subscribes to everything and publishes nothing — so even if
        // someone passed that scope where an announcement was expected, it does
        // not resolve to a participant slot.
        let recorder = Watchdog(
            id: "rec-1",
            kind: .recording,
            operatedBy: .tenant,
            descriptor: "Recording for your compliance team",
            scope: prefix,
            attachedAt: Date()
        )

        #expect(ParticipantSlot(announced: recorder.scope, under: prefix) == nil)

        var state = RoomState(tenant: "acme", room: "room-42", namespace: prefix)
        state.roster = Roster(announcements: [namespace("alice"), recorder.scope], under: prefix)
        try! state.watchdogs.attach(recorder)

        #expect(state.participantCount == 1)
        #expect(state.isRecording)
    }

    @Test("the count the UI shows is the count the meter bills")
    func rosterAndMeterAgree() {
        var state = RoomState(
            tenant: "acme",
            room: "room-42",
            namespace: prefix,
            roster: Roster(
                announcements: (0 ..< 12).map { namespace("user\($0)") },
                under: prefix
            )
        )
        let before = state.participantCount

        try! state.watchdogs.attach(
            Watchdog(
                id: "rec-1",
                kind: .recording,
                operatedBy: .tenant,
                descriptor: "Recording",
                scope: prefix,
                attachedAt: Date()
            )
        )

        // The failure this guards against: enable recording, watch the
        // concurrent-participant count tick to 13, get billed viewer minutes
        // for your own recorder, and be unable to reconcile the invoice.
        #expect(state.participantCount == before)
        #expect(state.participantCount == 12)
    }

    @Test("platform safety scanning is not billed; tenant recording is")
    func billabilityIsAnAttribute() {
        let safety = Watchdog(
            id: "safety-1",
            kind: .safety,
            operatedBy: .platform,
            descriptor: "Automated safety scanning",
            scope: prefix,
            attachedAt: Date(),
            isBillable: false,
            pinnedLayer: "video/360p"
        )
        let archiver = Watchdog(
            id: "arch-1",
            kind: .recording,
            operatedBy: .thirdParty("Acme Compliance Ltd"),
            descriptor: "Archiving to Acme Compliance",
            scope: prefix,
            attachedAt: Date(),
            pinnedLayer: "video/1080p"
        )

        #expect(!safety.isBillable)
        #expect(archiver.isBillable)
    }

    @Test("both pinning subscribers are represented, and neither is a viewer")
    func pinnedLayersSurviveAnEmptyRoom() {
        var set = WatchdogSet()
        try! set.attach(
            Watchdog(
                id: "rec", kind: .recording, operatedBy: .tenant, descriptor: "Recording",
                scope: prefix, attachedAt: Date(), pinnedLayer: "video/1080p"
            )
        )
        try! set.attach(
            Watchdog(
                id: "safety", kind: .safety, operatedBy: .platform, descriptor: "Safety",
                scope: prefix, attachedAt: Date(), isBillable: false, pinnedLayer: "video/360p"
            )
        )

        // A classifier running on 180p is both less accurate and an obvious
        // evasion vector once someone notices an empty room downgrades the
        // stream the detector sees.
        #expect(set.pinnedLayers() == ["video/1080p", "video/360p"])
    }

    @Test("attachment is capped, because each one pins a layer and costs an encode session")
    func attachmentIsCapped() {
        var set = WatchdogSet(limit: 2)
        for index in 0 ..< 2 {
            try! set.attach(
                Watchdog(
                    id: WatchdogID("w\(index)"), kind: .analytics, operatedBy: .tenant,
                    descriptor: "Analytics", scope: prefix, attachedAt: Date()
                )
            )
        }

        #expect(throws: MoqomError.self) {
            try set.attach(
                Watchdog(
                    id: "w2", kind: .analytics, operatedBy: .tenant, descriptor: "Analytics",
                    scope: prefix, attachedAt: Date()
                )
            )
        }
    }

    @Test("health is operational, not social")
    func healthIsNotPresence() {
        var set = WatchdogSet()
        try! set.attach(
            Watchdog(
                id: "rec", kind: .recording, operatedBy: .tenant, descriptor: "Recording",
                scope: prefix, attachedAt: Date()
            )
        )
        #expect(set.isRecording)

        // A customer whose recorder died wants that in room state, not inferred
        // from a missing file afterwards.
        set.setHealth(.failed, for: "rec")
        #expect(set["rec"]?.health == .failed)
        #expect(!set.isRecording)
    }

    @Test("every attachment is disclosed, whoever operates it")
    func everythingIsDisclosed() {
        var set = WatchdogSet()
        try! set.attach(
            Watchdog(
                id: "s", kind: .safety, operatedBy: .platform,
                descriptor: "Automated safety scanning", scope: prefix, attachedAt: Date(),
                isBillable: false
            )
        )
        #expect(set.disclosures.count == 1)
        #expect(set.disclosures[0].descriptor == "Automated safety scanning")
    }
}
