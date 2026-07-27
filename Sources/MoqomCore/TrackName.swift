// Track namespaces and full track names, per draft-19 §2.4.1.
//
// This mirrors `rs/moqom-proto/src/model/name.rs` and must keep mirroring it:
// the two implementations validate the same inputs and are expected to agree on
// which ones are legal. The Rust side stores raw bytes because a relay never
// needs to interpret them. A client does, constantly — every namespace it
// builds comes from a username, a room ID, or a device thumbprint — so this
// side stores `String` and canonicalises on the way in.
//
// That canonicalisation is the one place the two can silently diverge. The
// specification imposes no character encoding and compares bytewise, so "é"
// composed and "é" decomposed are two different namespaces. A username typed on
// iOS arrives decomposed often enough that this is a real bug rather than a
// theoretical one, and the client is the only layer that can fix it.

import Foundation

/// Maximum number of fields in a namespace (draft-19 §2.4.1).
public let maximumNamespaceFields = 32

/// Maximum total UTF-8 byte length of a namespace, and of a full track name.
///
/// Counts field *values* only — the wire's varint length prefixes are excluded.
public let maximumNameLength = 4096

/// A namespace or track name that violates draft-19 §2.4.1.
///
/// Construction is fallible so that an illegal name is unrepresentable rather
/// than something the transport has to reject later, by which point the caller
/// has lost the context that would let it produce a useful message.
public enum NameError: Error, Hashable, Sendable {
    /// More than ``maximumNamespaceFields`` namespace fields.
    case tooManyFields

    /// A namespace field of zero length, which the specification forbids.
    case emptyField

    /// Total length exceeds ``maximumNameLength`` bytes.
    case tooLong
}

extension NameError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .tooManyFields: "namespace has more than \(maximumNamespaceFields) fields"
        case .emptyField: "namespace field is empty"
        case .tooLong: "name exceeds \(maximumNameLength) bytes"
        }
    }
}

/// An ordered tuple of strings identifying a namespace.
///
/// Namespaces are tuples rather than delimited strings, and MOQOM leans on that
/// harder than most: the room model puts the tenant, the room, the participant,
/// and the device each in their own field, so authorisation can be scoped to a
/// prefix without parsing anything. See ``MoqomNamespaces``.
public struct TrackNamespace: Hashable, Sendable {
    private let storage: [String]

    /// The empty namespace, which is valid and matches everything as a prefix.
    public static let empty = TrackNamespace()

    private init() {
        storage = []
    }

    /// Construct from fields, canonicalising each and validating count,
    /// emptiness, and total length.
    ///
    /// - Throws: ``NameError`` if any draft-19 §2.4.1 constraint is violated.
    public init(_ fields: [String]) throws(NameError) {
        guard fields.count <= maximumNamespaceFields else { throw NameError.tooManyFields }

        var canonical: [String] = []
        canonical.reserveCapacity(fields.count)
        var total = 0
        for field in fields {
            let normalised = field.precomposedStringWithCanonicalMapping
            guard !normalised.isEmpty else { throw NameError.emptyField }
            total += normalised.utf8.count
            guard total <= maximumNameLength else { throw NameError.tooLong }
            canonical.append(normalised)
        }
        storage = canonical
    }

    /// The fields, in order, canonicalised.
    public var fields: [String] { storage }

    /// Number of fields.
    public var count: Int { storage.count }

    /// Whether the namespace has no fields.
    public var isEmpty: Bool { storage.isEmpty }

    /// Total UTF-8 length of all field values, excluding length prefixes.
    public var byteCount: Int { storage.reduce(0) { $0 + $1.utf8.count } }

    /// A namespace with `field` appended.
    ///
    /// - Throws: ``NameError`` if the result would violate a constraint.
    public func appending(_ field: String) throws(NameError) -> TrackNamespace {
        try TrackNamespace(storage + [field])
    }

    /// Whether `prefix` is a leading subsequence of this namespace.
    ///
    /// This is the operation `SUBSCRIBE_NAMESPACE` is built on, and the reason
    /// namespaces are tuples rather than strings. Comparing tuple fields cannot
    /// produce the false match that string prefixes can: `("acme", "room")` is
    /// not a prefix of `("acme", "roomies")`, though `"acme/room"` *is* a
    /// string prefix of `"acme/roomies"`.
    public func starts(with prefix: TrackNamespace) -> Bool {
        prefix.storage.count <= storage.count
            && zip(prefix.storage, storage).allSatisfy(==)
    }

    /// The fields after `prefix`, or `nil` when `prefix` does not match.
    ///
    /// Roster construction is exactly this operation: an announcement arrives
    /// under the room prefix and the remaining fields are the participant.
    public func suffix(after prefix: TrackNamespace) -> [String]? {
        guard starts(with: prefix) else { return nil }
        return Array(storage.dropFirst(prefix.count))
    }
}

extension TrackNamespace: CustomStringConvertible {
    /// Renders as a tuple rather than a path, so a log line cannot be mistaken
    /// for something you could parse back by splitting on a separator.
    public var description: String { "(\(storage.joined(separator: ", ")))" }
}

// No `ExpressibleByStringLiteral` or `ExpressibleByArrayLiteral` on the
// validating types in this file, and the reason is a Swift overload-resolution
// trap rather than taste. Given both a throwing `init(_:)` and a trapping
// literal initialiser, `try TrackName("video/360p")` binds to the *trapping*
// one, because the compiler prefers the non-throwing overload when the argument
// is a literal. It even warns that the `try` is redundant — which reads as a
// harmless lint rather than as "this call now crashes on bad input instead of
// throwing". A convenience that quietly converts a recoverable error into a
// process abort at exactly the call sites most likely to be written in a hurry
// is not worth having.

/// A track name within a namespace.
public struct TrackName: Hashable, Sendable {
    /// The canonicalised name.
    public let value: String

    /// - Throws: ``NameError`` if empty or longer than ``maximumNameLength``.
    public init(_ value: String) throws(NameError) {
        let normalised = value.precomposedStringWithCanonicalMapping
        guard !normalised.isEmpty else { throw NameError.emptyField }
        guard normalised.utf8.count <= maximumNameLength else { throw NameError.tooLong }
        self.value = normalised
    }
}

extension TrackName: CustomStringConvertible {
    public var description: String { value }
}

/// A namespace paired with a track name, uniquely identifying a track.
public struct FullTrackName: Hashable, Sendable {
    /// The namespace the track lives under.
    public let namespace: TrackNamespace

    /// The track's name within that namespace.
    public let name: TrackName

    /// - Throws: ``NameError/tooLong`` if the combined length exceeds
    ///   ``maximumNameLength``. The limit is on the pair, not on each half, so
    ///   two individually valid halves can still fail here.
    public init(namespace: TrackNamespace, name: TrackName) throws(NameError) {
        guard namespace.byteCount + name.value.utf8.count <= maximumNameLength else {
            throw NameError.tooLong
        }
        self.namespace = namespace
        self.name = name
    }
}

extension FullTrackName: CustomStringConvertible {
    public var description: String { "\(namespace)/\(name)" }
}
