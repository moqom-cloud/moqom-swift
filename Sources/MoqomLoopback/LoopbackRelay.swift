// An in-memory relay.
//
// This is not a mock in the usual sense — nothing here returns canned answers.
// It implements the forwarding semantics the real relay has: announcements
// under a prefix reach everyone watching that prefix, objects written to a
// track reach everyone subscribed to it, and a withdrawal removes the
// announcement from late joiners as well as notifying current ones. That is
// enough to drive the roster, the layer planner, and the publication lifecycle
// through their real code paths.
//
// It also keeps a log of everything it was asked to do, which is what lets a
// test assert a *negative*: per-viewer mute is supposed to be an unsubscribe
// and nothing else, and the only way to check that no control message was sent
// is to have somewhere that would have recorded one.

import Foundation
import MoqomCore
import MoqomKit

/// Something a session asked the relay to do.
public enum RelayInteraction: Hashable, Sendable {
    case connected(ParticipantIdentity)
    case announced(TrackNamespace)
    case withdrew(TrackNamespace)
    case watched(prefix: TrackNamespace)
    case subscribed(FullTrackName, priority: UInt8)
    case unsubscribed(FullTrackName)
    case reprioritised(FullTrackName, priority: UInt8)
    case published(FullTrackName)
    case wrote(FullTrackName, group: UInt64, object: UInt64)
    case closed(code: UInt64)
}

/// The shared fabric loopback sessions connect to.
public actor LoopbackRelay {
    private struct Watcher {
        let prefix: TrackNamespace
        let continuation: AsyncStream<AnnouncementEvent>.Continuation
    }

    private var announcements: Set<TrackNamespace> = []
    private var watchers: [UUID: Watcher] = [:]
    private var subscribers: [FullTrackName: [UUID: AsyncStream<TrackObject>.Continuation]] = [:]
    private var interactions: [RelayInteraction] = []

    public init() {}

    /// Everything that has happened, in order.
    public var log: [RelayInteraction] { interactions }

    /// Whether anything matching `predicate` was ever asked for.
    public func recorded(_ predicate: @Sendable (RelayInteraction) -> Bool) -> Bool {
        interactions.contains(where: predicate)
    }

    public func clearLog() {
        interactions.removeAll()
    }

    /// Namespaces currently announced under a prefix.
    public func announcements(under prefix: TrackNamespace) -> [TrackNamespace] {
        announcements.filter { $0.starts(with: prefix) }.sorted { $0.description < $1.description }
    }

    /// How many subscribers a track has. The signal the real relay feeds back
    /// to a publisher so it can stop encoding a layer nobody is watching.
    public func subscriberCount(for track: FullTrackName) -> Int {
        subscribers[track]?.count ?? 0
    }

    func record(_ interaction: RelayInteraction) {
        interactions.append(interaction)
    }

    func announce(_ namespace: TrackNamespace) {
        interactions.append(.announced(namespace))
        guard announcements.insert(namespace).inserted else { return }
        for watcher in watchers.values where namespace.starts(with: watcher.prefix) {
            watcher.continuation.yield(.announced(namespace))
        }
    }

    func withdraw(_ namespace: TrackNamespace) {
        interactions.append(.withdrew(namespace))
        guard announcements.remove(namespace) != nil else { return }
        for watcher in watchers.values where namespace.starts(with: watcher.prefix) {
            watcher.continuation.yield(.withdrawn(namespace))
        }
    }

    func watch(
        prefix: TrackNamespace,
        continuation: AsyncStream<AnnouncementEvent>.Continuation
    ) -> UUID {
        interactions.append(.watched(prefix: prefix))
        let id = UUID()
        watchers[id] = Watcher(prefix: prefix, continuation: continuation)
        // A late joiner must see what is already there, or the roster would
        // only ever contain participants who arrived after it did.
        for namespace in announcements.sorted(by: { $0.description < $1.description })
            where namespace.starts(with: prefix)
        {
            continuation.yield(.announced(namespace))
        }
        return id
    }

    func unwatch(_ id: UUID) {
        watchers.removeValue(forKey: id)?.continuation.finish()
    }

    func subscribe(
        to track: FullTrackName,
        priority: UInt8,
        continuation: AsyncStream<TrackObject>.Continuation
    ) -> UUID {
        interactions.append(.subscribed(track, priority: priority))
        let id = UUID()
        subscribers[track, default: [:]][id] = continuation
        return id
    }

    func unsubscribe(_ id: UUID, from track: FullTrackName) {
        interactions.append(.unsubscribed(track))
        subscribers[track]?.removeValue(forKey: id)?.finish()
        if subscribers[track]?.isEmpty == true { subscribers.removeValue(forKey: track) }
    }

    func reprioritise(_ track: FullTrackName, priority: UInt8) {
        interactions.append(.reprioritised(track, priority: priority))
    }

    func publish(_ track: FullTrackName) {
        interactions.append(.published(track))
    }

    func deliver(_ object: TrackObject, to track: FullTrackName) {
        interactions.append(.wrote(track, group: object.group, object: object.object))
        guard let targets = subscribers[track] else { return }
        for continuation in targets.values {
            continuation.yield(object)
        }
    }

    func close(code: UInt64) {
        interactions.append(.closed(code: code))
    }
}
