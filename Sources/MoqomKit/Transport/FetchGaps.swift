// Saying "this was never published".
//
// A fetch answer is not just the objects that exist. A hole in the numbering has
// to be reported, because the alternative is a receiver waiting for an object
// that is never coming — and unlike live media, where the next keyframe
// eventually rescues you, a fetch has a finite range and nothing after it.
//
// This lives here, rather than inside either responder, because there are two of
// them: `MoqtSession` answering from a publisher's retained history, and
// `LoopbackRelay` answering from everything it holds. They work with different
// types and produce different records, but the rule about where a marker goes is
// the same rule, and a rule implemented twice is a rule that will differ.

import Foundation
import MoqomCore

/// Where a fetch answer needs a non-existent-range marker.
public enum FetchGaps {
    /// The marker location to emit immediately *before* each object, keyed by
    /// that object's index in `locations`.
    ///
    /// `locations` must already be in the order the records will be written.
    ///
    /// Only gaps *within* a group are reported, and only in ascending order.
    /// Both restrictions are about what a marker can actually express: it covers
    /// everything from after the previous record through the location it names,
    /// which is a contiguous span. Between two groups that span would also have
    /// to assert something about the end of the earlier group, and the responder
    /// does not know where that group ended — a group is finished by the
    /// publisher, not by the numbering. Descending is excluded for the same
    /// reason in the other direction: groups descend while objects inside them
    /// ascend, so consecutive records are not adjacent in location order and one
    /// marker cannot describe the span between them.
    public static func markers(
        before locations: [Location],
        order: GroupOrder
    ) -> [Int: Location] {
        guard order == .ascending else { return [:] }

        var markers: [Int: Location] = [:]
        var previous: Location?
        for (index, location) in locations.enumerated() {
            defer { previous = location }
            guard
                let previous,
                previous.group == location.group,
                location.object > previous.object + 1
            else { continue }
            // Through the object before this one: the span being described ends
            // where the gap ends, not where the next real object begins.
            markers[index] = Location(group: location.group, object: location.object - 1)
        }
        return markers
    }
}
