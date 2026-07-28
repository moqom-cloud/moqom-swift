// Where something is in a track.
//
// In `MoqomCore` rather than in the codec for the same reason the name types
// are: a location is a thing an application says ("start me here", "I am missing
// through there"), not only a thing that gets encoded. The wire form lives in
// `MoqomWire` as an extension, so a caller that never touches the protocol never
// imports it.

import Foundation

/// A group and object pair, in the draft's ordering.
///
/// `Comparable` lexicographically, which is load-bearing rather than
/// decorative: the point of a location is that "later in the track" is a total
/// order, and every range check on a fetch is written against it.
public struct Location: Hashable, Sendable, Comparable {
    public var group: UInt64
    public var object: UInt64

    public init(group: UInt64, object: UInt64) {
        self.group = group
        self.object = object
    }

    /// The first object of a group.
    public static func group(_ group: UInt64) -> Location {
        Location(group: group, object: 0)
    }

    public static func < (lhs: Location, rhs: Location) -> Bool {
        (lhs.group, lhs.object) < (rhs.group, rhs.object)
    }
}

/// Where a range of history stops.
///
/// The draft encodes this as "the last object, plus one", with a zero object
/// meaning the whole group. Both cases are here as named constructors so the
/// off-by-one is applied once, by the encoder, rather than by every caller who
/// has to remember it exists. §10.12.3 calls the range inclusive and the field
/// description says plus one; reading only the first sentence loses the last
/// object of every fetch.
public enum FetchEnd: Hashable, Sendable {
    /// Through this object, inclusive.
    case through(Location)

    /// Through the end of this group, however many objects it turns out to
    /// hold. The only way to say "the rest of the group" without knowing how
    /// long it is.
    case endOfGroup(UInt64)
}

/// Whether a range of groups is walked forwards or backwards.
///
/// Not merely a delivery preference. On a fetch's data stream it changes the
/// *sign* of the group delta, so a reader using the wrong one decodes different
/// group numbers rather than the same groups in a different order.
public enum GroupOrder: UInt64, Sendable, Hashable {
    case ascending = 0x1
    case descending = 0x2
}
