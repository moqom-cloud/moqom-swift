import Testing

@testable import MoqomCore

@Suite("Identity")
struct IdentityTests {
    @Test("a username is a string end to end, with no numeric mapping anywhere")
    func usernameStaysAString() throws {
        let alice = try Username("alice")
        let identity = ParticipantIdentity(username: alice, device: try DeviceID("iphone-3f9a"))
        let namespace = try MoqomNamespaces.participant(
            tenant: "acme",
            room: "room-42",
            identity: identity
        )

        #expect(namespace.fields == ["acme", "r", "room-42", "alice", "iphone-3f9a"])
    }

    @Test("the device is its own field, so a delimiter in a username is harmless")
    func delimiterInUsernameIsHarmless() throws {
        // The bug this design removes: with `username + "-" + device` glued
        // into one field, this username would parse as a different user on a
        // different device.
        let awkward = try Username("alice-iphone-3f9a")
        let identity = ParticipantIdentity(username: awkward, device: try DeviceID("ipad-0001"))
        let prefix = try MoqomNamespaces.room(tenant: "acme", room: "room-42")
        let namespace = try MoqomNamespaces.participant(
            tenant: "acme",
            room: "room-42",
            identity: identity
        )

        let recovered = MoqomNamespaces.identity(announcedAt: namespace, under: prefix)
        #expect(recovered == identity)
        #expect(recovered?.username.value == "alice-iphone-3f9a")
    }

    @Test("one user on two devices is two identities and not a duplicate")
    func multiDevice() throws {
        let alice = try Username("alice")
        let phone = ParticipantIdentity(username: alice, device: try DeviceID("iphone-3f9a"))
        let pad = ParticipantIdentity(username: alice, device: try DeviceID("ipad-77b2"))

        #expect(phone != pad)
        #expect(phone.username == pad.username)
    }

    @Test("device IDs derive from the thumbprint and truncate deterministically")
    func deviceFromThumbprint() throws {
        let thumbprint = "NzbLsXh8uDCcd-6MNwXF4W_7noWXFZAfHkxZsRGC9Xs"
        let device = try DeviceID(thumbprint: thumbprint)
        #expect(device.value == "NzbLsXh8uDCcd-6M")
        #expect(device.value.count == 16)
    }

    @Test("backstage sits outside the room prefix a viewer subscribes to")
    func backstageIsNotUnderTheRoomPrefix() throws {
        let identity = ParticipantIdentity(
            username: try Username("guest"),
            device: try DeviceID("iphone-0001")
        )
        let roomPrefix = try MoqomNamespaces.room(tenant: "acme", room: "room-42")
        let backstage = try MoqomNamespaces.backstageParticipant(
            tenant: "acme",
            room: "room-42",
            identity: identity
        )

        #expect(!backstage.starts(with: roomPrefix))
        #expect(backstage.starts(with: try MoqomNamespaces.backstage(tenant: "acme", room: "room-42")))
    }

    @Test("a namespace deeper than a participant slot does not resolve to one")
    func deeperNamespaceIsNotAParticipant() throws {
        let prefix = try MoqomNamespaces.room(tenant: "acme", room: "room-42")
        let deeper = try TrackNamespace(["acme", "r", "room-42", "alice", "iphone", "extra"])
        let shallower = try TrackNamespace(["acme", "r", "room-42", "alice"])

        #expect(MoqomNamespaces.identity(announcedAt: deeper, under: prefix) == nil)
        #expect(MoqomNamespaces.identity(announcedAt: shallower, under: prefix) == nil)
    }

    @Test("an announcement under a different room does not resolve")
    func wrongRoom() throws {
        let prefix = try MoqomNamespaces.room(tenant: "acme", room: "room-42")
        let other = try TrackNamespace(["acme", "r", "room-43", "alice", "iphone"])
        #expect(MoqomNamespaces.identity(announcedAt: other, under: prefix) == nil)
    }
}
