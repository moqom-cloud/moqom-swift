import Foundation
import Testing

@testable import MoqomCore
@testable import MoqomKit

@Suite("Mute is four features")
struct MuteTests {
    @Test("the four kinds are independent and combine")
    func fourIndependentKinds() {
        var mute = MuteState()
        mute.selfMuted = .audio
        mute.forcedForEveryone = .video
        mute.localToMe = .screenShare

        #expect(mute.effective.contains(.audio))
        #expect(mute.effective.contains(.video))
        #expect(mute.effective.contains(.screenShare))
    }

    @Test("audience-only muting does not silence the participant for hosts")
    func audienceOnlyIsNotEffectiveForHosts() {
        // The talkback case: cohosts still hear each other, the audience does
        // not. It needs no new machinery because the relay already authorises
        // subscriptions by token scope.
        var mute = MuteState()
        mute.forcedForAudience = .audio

        #expect(!mute.effective.contains(.audio))
        #expect(mute.reason(for: .audio) == .audienceOnly)
    }

    @Test("a force-muted participant is told they were muted, not left guessing")
    func moderatorReasonOutranksSelf() {
        var mute = MuteState()
        mute.selfMuted = .audio
        mute.forcedForEveryone = .audio

        #expect(mute.reason(for: .audio) == .moderator)
    }

    @Test("nothing muted reports no reason")
    func noReasonWhenAudible() {
        #expect(MuteState().reason(for: .audio) == nil)
    }
}

@Suite("Stage management")
struct StageTests {
    @Test("accepting a promotion grants publish rights and starts nothing")
    func promotionIsAnOfferNotAnAct() async {
        // Getting this wrong is a privacy incident rather than a bug: a scope
        // change must never turn a camera on.
        var invitation = StageInvitation(
            direction: .invitation,
            subject: identity("guest"),
            issuedBy: identity("host"),
            offered: .camera,
            issuedAt: .zero
        )
        invitation.accept()

        #expect(invitation.outcome == .accepted)

        // The source a promoted guest holds until they choose to go live.
        let idle = IdleFrameSource(
            format: CaptureFormat(size: PixelSize(width: 1280, height: 720), frameRate: 30)
        )
        // Awaited here rather than in a `Task`. The task version asserted
        // before the child had run, so it held for a source that emitted
        // continuously; an idle source finishes its stream immediately, which
        // makes the inline loop terminate and the count meaningful.
        var produced = 0
        for await _ in idle.frames() { produced += 1 }
        #expect(produced == 0)
    }

    @Test("an invitation nobody answers times out rather than lingering")
    func invitationsExpire() {
        var invitation = StageInvitation(
            direction: .invitation,
            subject: identity("guest"),
            issuedBy: identity("host"),
            offered: .audioOnly,
            issuedAt: .seconds(10),
            expiresAfter: .seconds(30)
        )

        let early = invitation.expire(at: .seconds(39))
        #expect(!early)
        #expect(invitation.outcome == .pending)

        let late = invitation.expire(at: .seconds(40))
        #expect(late)
        #expect(invitation.outcome == .timedOut)
    }

    @Test("an answered invitation cannot be reopened by a late timeout")
    func outcomesAreTerminal() {
        var invitation = StageInvitation(
            direction: .request,
            subject: identity("viewer"),
            issuedBy: identity("viewer"),
            offered: .audioOnly,
            issuedAt: .zero
        )
        invitation.accept()
        invitation.decline()
        let expired = invitation.expire(at: .seconds(600))
        #expect(invitation.outcome == .accepted)
        #expect(!expired)
    }

    @Test("expiring the stage returns what lapsed, which is the recommender's training data")
    func expiryReportsOutcomes() {
        var stage = StageState()
        stage.pending = [
            StageInvitation(
                direction: .invitation, subject: identity("a"), issuedBy: identity("host"),
                offered: .camera, issuedAt: .zero, expiresAfter: .seconds(30)
            ),
            StageInvitation(
                direction: .invitation, subject: identity("b"), issuedBy: identity("host"),
                offered: .camera, issuedAt: .seconds(20), expiresAfter: .seconds(30)
            ),
        ]

        let lapsed = stage.expirePending(at: .seconds(31))
        #expect(lapsed.count == 1)
        #expect(lapsed[0].subject == identity("a"))
        #expect(stage.pending.count == 1)
    }
}

@Suite("Room state")
struct RoomStateTests {
    private let prefix = try! MoqomNamespaces.room(tenant: "acme", room: "room-42")

    @Test("multi-device is two roster entries and one distinct user")
    func multiDeviceCounts() {
        let roster = Roster(
            announcements: [
                try! MoqomNamespaces.participant(
                    tenant: "acme", room: "room-42",
                    identity: identity("alice", device: "iphone-0001")
                ),
                try! MoqomNamespaces.participant(
                    tenant: "acme", room: "room-42",
                    identity: identity("alice", device: "ipad-0002")
                ),
            ],
            under: prefix
        )

        #expect(roster.count == 2)
        #expect(roster.distinctUsers == 1)
        #expect(roster.devices(of: try! Username("alice")).count == 2)
    }

    @Test("withdrawing an announcement removes the participant")
    func withdrawalRemoves() {
        var roster = Roster()
        let namespace = try! MoqomNamespaces.participant(
            tenant: "acme", room: "room-42", identity: identity("bob")
        )

        roster.apply(.announced(namespace), under: prefix)
        #expect(roster.count == 1)

        // Either reason, because this view does not weigh them: holding a seat
        // open is ``SeatPolicy``'s job, decided before the roster is touched.
        roster.apply(.withdrawn(namespace, .vanished), under: prefix)
        #expect(roster.count == 0)
    }

    @Test("an announcement outside the room is ignored rather than treated as an error")
    func foreignAnnouncementsAreIgnored() {
        // A relay may announce namespaces this client does not model. Treating
        // that as an error would make every future protocol addition breaking.
        var roster = Roster()
        roster.apply(
            .announced(try! TrackNamespace(["acme", "r", "other-room", "eve", "iphone"])),
            under: prefix
        )
        #expect(roster.count == 0)
    }

    @Test("backstage participants are separated from the stage")
    func backstageIsSeparate() {
        var state = RoomState(tenant: "acme", room: "room-42", namespace: prefix)
        var onStage = Participant(
            slot: ParticipantSlot(
                announced: try! MoqomNamespaces.participant(
                    tenant: "acme", room: "room-42", identity: identity("host")
                ),
                under: prefix
            )!
        )
        onStage.grants = Grants(publish: .camera)
        state.roster.insert(onStage)

        let backstagePrefix = try! MoqomNamespaces.backstage(tenant: "acme", room: "room-42")
        var waiting = Participant(
            slot: ParticipantSlot(
                announced: try! MoqomNamespaces.backstageParticipant(
                    tenant: "acme", room: "room-42", identity: identity("guest")
                ),
                under: backstagePrefix,
                isBackstage: true
            )!
        )
        waiting.grants = Grants(publish: .camera)
        state.roster.insert(waiting)

        #expect(state.broadcasters.map(\.username.value) == ["host"])
        #expect(state.backstage.map(\.username.value) == ["guest"])
    }
}
