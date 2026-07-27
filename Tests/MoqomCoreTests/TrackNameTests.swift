import Testing

@testable import MoqomCore

@Suite("Track namespaces")
struct TrackNamespaceTests {
    @Test("field count is capped at the draft-19 limit")
    func fieldCountCap() throws {
        let atLimit = (0 ..< maximumNamespaceFields).map { "f\($0)" }
        #expect(throws: Never.self) { try TrackNamespace(atLimit) }
        #expect(throws: NameError.tooManyFields) { try TrackNamespace(atLimit + ["one-more"]) }
    }

    @Test("an empty field is rejected rather than silently dropped")
    func emptyField() {
        #expect(throws: NameError.emptyField) { try TrackNamespace(["acme", "", "room"]) }
    }

    @Test("total length is measured in UTF-8 bytes, not characters")
    func lengthIsBytes() throws {
        // Four-byte scalars: 1024 of them is exactly the limit, 1025 is over,
        // even though the character count is a quarter of it.
        let atLimit = String(repeating: "😀", count: maximumNameLength / 4)
        #expect(throws: Never.self) { try TrackNamespace([atLimit]) }
        #expect(throws: NameError.tooLong) { try TrackNamespace([atLimit + "😀"]) }
    }

    @Test("tuple prefixes cannot produce the false match string prefixes can")
    func prefixMatching() throws {
        let room = try TrackNamespace(["acme", "r", "room"])
        let roomies = try TrackNamespace(["acme", "r", "roomies"])
        let inRoom = try TrackNamespace(["acme", "r", "room", "alice", "iphone"])

        #expect(inRoom.starts(with: room))
        #expect(!roomies.starts(with: room))
        #expect(!room.starts(with: inRoom))
    }

    @Test("the empty namespace is a prefix of everything")
    func emptyIsUniversalPrefix() throws {
        let anything = try TrackNamespace(["acme", "r", "room"])
        #expect(anything.starts(with: .empty))
    }

    @Test("fields are canonicalised so composed and decomposed forms match")
    func unicodeCanonicalisation() throws {
        // The wire compares bytewise and imposes no encoding, so a username
        // typed with a combining accent would otherwise be a different
        // namespace from the same username typed precomposed.
        let composed = try TrackNamespace(["acme", "u", "andr\u{00E9}"])
        let decomposed = try TrackNamespace(["acme", "u", "andre\u{0301}"])
        #expect(composed == decomposed)
        #expect(composed.hashValue == decomposed.hashValue)
    }

    @Test("the suffix after a prefix is what roster derivation reads")
    func suffixAfterPrefix() throws {
        let prefix = try TrackNamespace(["acme", "r", "room"])
        let full = try TrackNamespace(["acme", "r", "room", "alice", "iphone-3f9a"])

        #expect(full.suffix(after: prefix) == ["alice", "iphone-3f9a"])
        #expect(full.suffix(after: try TrackNamespace(["other"])) == nil)
    }

    @Test("appending validates rather than growing past the limit")
    func appendingValidates() throws {
        var namespace = try TrackNamespace((0 ..< maximumNamespaceFields - 1).map { "f\($0)" })
        namespace = try namespace.appending("last")
        #expect(namespace.count == maximumNamespaceFields)
        #expect(throws: NameError.tooManyFields) { try namespace.appending("overflow") }
    }
}

@Suite("Full track names")
struct FullTrackNameTests {
    @Test("the length limit applies to the pair, not each half")
    func combinedLength() throws {
        let namespace = try TrackNamespace([String(repeating: "a", count: maximumNameLength - 4)])
        #expect(throws: Never.self) {
            try FullTrackName(namespace: namespace, name: TrackName("abcd"))
        }
        #expect(throws: NameError.tooLong) {
            try FullTrackName(namespace: namespace, name: TrackName("abcde"))
        }
    }

    @Test("an empty track name is rejected")
    func emptyName() {
        #expect(throws: NameError.emptyField) { try TrackName("") }
    }
}
