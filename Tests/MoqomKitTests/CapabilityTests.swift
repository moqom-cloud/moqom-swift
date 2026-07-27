import Testing

@testable import MoqomCore
@testable import MoqomKit

@Suite("Moderation capabilities")
struct CapabilityTests {
    private let mod = Grants(publish: .none, moderation: .moderator)
    private let superMod = Grants(publish: .camera, moderation: .superModerator)
    private let viewer = Grants()
    private let owner = Grants(publish: .full, moderation: .owner, isOwner: true)

    @Test("a mod cannot act on a peer mod, because the sets are equal")
    func peersCannotModerateEachOther() {
        #expect(!mod.canModerate(mod))
        #expect(!superMod.canModerate(superMod))
    }

    @Test("a super mod can act on a mod, because the set is a strict superset")
    func strictSupersetCanModerate() {
        #expect(superMod.canModerate(mod))
        #expect(!mod.canModerate(superMod))
    }

    @Test("moderators with different specialities simply cannot act on each other")
    func incomparableSetsCannotAct() {
        // This is the case a level hierarchy gets wrong: forced onto a line,
        // one of these would spuriously outrank the other.
        let chatMod = Grants(moderation: .chatGroup)
        let stageMod = Grants(moderation: .stageGroup)

        #expect(!chatMod.canModerate(stageMod))
        #expect(!stageMod.canModerate(chatMod))
    }

    @Test("the owner is above everyone and below no one")
    func ownerIsAbsolute() {
        #expect(owner.canModerate(superMod))
        #expect(owner.canModerate(mod))
        #expect(!superMod.canModerate(owner))
        #expect(!owner.canModerate(owner))
    }

    @Test("nobody grants what they do not hold")
    func cannotGrantBeyondOwnSet() {
        #expect(mod.canGrant(.deleteMessage))
        #expect(!mod.canGrant(.promoteToCohost))
        #expect(superMod.canGrant(.promoteToCohost))
    }

    @Test("appointing moderators is owner-held, so one compromised super mod is not a takeover")
    func appointmentDoesNotDelegate() {
        let appointer = Grants(moderation: [.superModerator, .appointModerators])

        #expect(!appointer.canGrant(.appointModerators))
        #expect(owner.canGrant(.appointModerators))
    }

    @Test("an action is refused without its capability, before any target check")
    func actionRequiresItsCapability() {
        let action = ModerationAction.kick(identity("bob"))
        let result = authorize(action, by: mod, against: viewer)

        guard case let .failure(error) = result else {
            Issue.record("expected refusal")
            return
        }
        guard case let .notPermitted(capability) = error else {
            Issue.record("expected notPermitted")
            return
        }
        #expect(capability == .kick)
    }

    @Test("having the capability is not enough if the target outranks you")
    func targetRankStillApplies() {
        let kicker = Grants(moderation: [.kick])
        let entrenched = Grants(moderation: [.kick, .banFromRoom])

        #expect(authorizeSucceeds(.kick(identity("x")), by: kicker, against: Grants()))
        #expect(!authorizeSucceeds(.kick(identity("x")), by: kicker, against: entrenched))
    }

    @Test("roles are labels derived from grants, not a second source of truth")
    func rolesAreDerived() {
        #expect(ParticipantRole(owner) == .owner)
        #expect(ParticipantRole(superMod) == .cohost)
        #expect(ParticipantRole(mod) == .moderator)
        #expect(ParticipantRole(Grants(publish: .audioOnly)) == .guest)
        #expect(ParticipantRole(viewer) == .viewer)
    }

    @Test("publish and moderation are independent axes")
    func axesAreOrthogonal() {
        // The combination that a single role enum cannot express: someone who
        // moderates the chat and never appears on camera.
        let textMod = Grants(publish: .none, moderation: [.chatGroup, .kick])
        #expect(textMod.publish.isEmpty)
        #expect(textMod.moderation.contains(.kick))

        // And its mirror: a guest who publishes and controls nothing.
        let guest = Grants(publish: .camera, moderation: .none)
        #expect(guest.moderation.isEmpty)
    }

    private func authorizeSucceeds(
        _ action: ModerationAction,
        by actor: Grants,
        against target: Grants?
    ) -> Bool {
        if case .success = authorize(action, by: actor, against: target) { return true }
        return false
    }
}

func identity(_ name: String, device: String = "iphone-0001") -> ParticipantIdentity {
    // Force-unwrapped rather than thrown: these are literals under test control
    // and a throwing helper would put a `try` on every line of every fixture.
    ParticipantIdentity(
        username: try! Username(name),
        device: try! DeviceID(device)
    )
}
