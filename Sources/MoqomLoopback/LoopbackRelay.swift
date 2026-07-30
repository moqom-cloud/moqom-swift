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
    case fetched(FullTrackName, from: Location, to: FetchEnd)
    case cancelledFetch(FullTrackName)
    case closed(code: UInt64)
}

/// The shared fabric loopback sessions connect to.
public actor LoopbackRelay {
    private struct Watcher {
        let prefix: TrackNamespace
        let continuation: AsyncStream<AnnouncementEvent>.Continuation
    }

    private var announcements: Set<TrackNamespace> = []

    /// How many further attempts to open a track for publishing to refuse.
    private var refusedPublishes = 0

    /// Which session announced what.
    ///
    /// Needed because a session ending withdraws everything it announced, which
    /// is the real relay's behaviour and the only way a client ever finds out
    /// that somebody's connection died. Without this the loopback would keep a
    /// dead participant announced forever, and every test of a vanished peer
    /// would pass while the room quietly showed a ghost.
    private var announced: [ObjectIdentifier: Set<TrackNamespace>] = [:]

    private var watchers: [UUID: Watcher] = [:]
    private var subscribers: [FullTrackName: [UUID: AsyncStream<TrackObject>.Continuation]] = [:]
    private var interactions: [RelayInteraction] = []

    /// Everything published, kept whole.
    ///
    /// The interaction log records that a write happened; this records what was
    /// written. Both are needed, because a publish path can produce the right
    /// number of objects in the right groups and still put nothing useful in
    /// them — which is exactly the bug the descriptor placeholder was.
    private var delivered: [FullTrackName: [TrackObject]] = [:]

    /// The current group of each track, for joiners that ask to start there.
    private var latestGroup: [FullTrackName: [TrackObject]] = [:]
    private var latestGroupNumber: [FullTrackName: UInt64] = [:]

    /// Sessions opened on this fabric, per identity, so a test can take one away.
    private var sessions: [ParticipantIdentity: [LoopbackSession]] = [:]

    /// Whether new connections are answered.
    ///
    /// The switch that makes a reconnect worth testing: a retry loop against a
    /// relay that never comes back only proves the loop runs, and the behaviour
    /// that matters is what happens when it does come back.
    public private(set) var isAcceptingConnections = true

    public init() {}

    /// Refuse the next `count` attempts to open a track for publishing.
    ///
    /// For reproducing a partial recovery: the session comes back, and opening one of the
    /// tracks on it does not.
    public func refusePublishes(_ count: Int) {
        refusedPublishes = count
    }

    /// Whether this attempt to open a track should be refused. Consumes one refusal.
    func shouldRefusePublish() -> Bool {
        guard refusedPublishes > 0 else { return false }
        refusedPublishes -= 1
        return true
    }

    public func setAcceptingConnections(_ accepting: Bool) {
        isAcceptingConnections = accepting
    }

    func attach(_ session: LoopbackSession, for who: ParticipantIdentity) {
        sessions[who, default: []].append(session)
    }

    /// Take a participant's connection away, as the network would.
    ///
    /// Every session that identity has opened, because a reconnect leaves the
    /// earlier ones behind and dropping an already-dead one does nothing.
    ///
    /// Withdrawing what the dead sessions announced is not tidying up, it is the
    /// behaviour being modelled. A real relay withdraws everything a session
    /// announced when that session ends, cleanly or otherwise, and that
    /// withdrawal is the *only* way other clients learn a participant is gone —
    /// nobody dying sends their own notice. Leaving the announcements in place
    /// would make every peer's roster permanently wrong and every test of it
    /// vacuous.
    ///
    /// The withdrawals say ``WithdrawalReason/vanished``, which is what makes
    /// this distinguishable from the participant closing their own announcement.
    /// Without that, dying and leaving are the same event here and no test could
    /// tell whether the roster held the right seat for the right reason.
    public func drop(
        _ who: ParticipantIdentity,
        failure: TransportFailure = .idleTimeout
    ) {
        for session in sessions.removeValue(forKey: who) ?? [] {
            session.drop(failure)
            for namespace in announced.removeValue(forKey: ObjectIdentifier(session)) ?? [] {
                withdraw(namespace, reason: .vanished)
            }
        }
    }

    /// Everything that has happened, in order.
    public var log: [RelayInteraction] { interactions }

    /// Whether anything matching `predicate` was ever asked for.
    public func recorded(_ predicate: @Sendable (RelayInteraction) -> Bool) -> Bool {
        interactions.contains(where: predicate)
    }

    public func clearLog() {
        interactions.removeAll()
        delivered.removeAll()
        latestGroup.removeAll()
        latestGroupNumber.removeAll()
    }

    /// Objects published on a track.
    public func objects(on track: FullTrackName) -> [TrackObject] {
        delivered[track] ?? []
    }

    /// Objects published on any track with this name, whoever published it.
    ///
    /// Convenient for a test that cares about one rung and not about which
    /// participant's namespace it hangs under.
    public func objects(onTrackNamed name: String) -> [TrackObject] {
        delivered
            .filter { $0.key.name.value == name }
            .sorted { $0.key.description < $1.key.description }
            .flatMap(\.value)
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

    func announce(_ namespace: TrackNamespace, by owner: ObjectIdentifier? = nil) {
        interactions.append(.announced(namespace))
        if let owner { announced[owner, default: []].insert(namespace) }
        guard announcements.insert(namespace).inserted else { return }
        for watcher in watchers.values where namespace.starts(with: watcher.prefix) {
            watcher.continuation.yield(.announced(namespace))
        }
    }

    func withdraw(
        _ namespace: TrackNamespace,
        by owner: ObjectIdentifier? = nil,
        reason: WithdrawalReason = .stopped
    ) {
        interactions.append(.withdrew(namespace))
        if let owner { announced[owner]?.remove(namespace) }
        guard announcements.remove(namespace) != nil else { return }
        for watcher in watchers.values where namespace.starts(with: watcher.prefix) {
            watcher.continuation.yield(.withdrawn(namespace, reason))
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
        start: SubscribeRequest.Start,
        continuation: AsyncStream<TrackObject>.Continuation
    ) -> UUID {
        interactions.append(.subscribed(track, priority: priority))
        let id = UUID()
        subscribers[track, default: [:]][id] = continuation

        // A real relay caches the current group so a joiner does not have to
        // wait for the publisher to open the next one. That behaviour is the
        // whole reason the catalog can be a track: a viewer subscribes and has
        // the description immediately, rather than when it next changes.
        if start == .latestGroup, let latest = latestGroup[track] {
            for object in latest { continuation.yield(object) }
        }
        return id
    }

    func unsubscribe(_ id: UUID, from track: FullTrackName) {
        interactions.append(.unsubscribed(track))
        subscribers[track]?.removeValue(forKey: id)?.finish()
        if subscribers[track]?.isEmpty == true { subscribers.removeValue(forKey: track) }
    }

    /// Where a subscription is now, for resolving a joining fetch.
    ///
    /// Nil for a track nothing has been published on, which is the case a
    /// joining fetch cannot be answered in: there is no position to count back
    /// from. The real relay answers INVALID_RANGE.
    func position(of track: FullTrackName) -> Location? {
        guard let last = delivered[track]?.last else { return nil }
        return Location(group: last.group, object: last.object)
    }

    /// Serve a fetch from what has been published, gaps included.
    ///
    /// The gaps are the interesting part, and the reason this is not a filter
    /// over `delivered`: a fetch's answer has to distinguish "there was never an
    /// object here" from "the range stops here", and a subscriber that cannot
    /// tell them apart waits for something that is never coming.
    func fetch(
        _ track: FullTrackName,
        from start: Location,
        through end: FetchEnd,
        order: GroupOrder
    ) -> [FetchedRecord] {
        interactions.append(.fetched(track, from: start, to: end))

        let limit = end.wire
        let matching = (delivered[track] ?? []).filter { object in
            let location = Location(group: object.group, object: object.object)
            guard location >= start else { return false }
            switch end {
            case let .endOfGroup(group): return object.group <= group
            case .through: return location < limit
            }
        }

        let ordered: [TrackObject]
        switch order {
        case .ascending:
            ordered = matching.sorted {
                Location(group: $0.group, object: $0.object)
                    < Location(group: $1.group, object: $1.object)
            }
        case .descending:
            // Groups descend, objects within a group still ascend.
            ordered = matching.sorted {
                $0.group == $1.group ? $0.object < $1.object : $0.group > $1.group
            }
        }

        // A hole in the object numbering within a group means the object does
        // not exist, and saying so is what lets a receiver stop waiting. The
        // rule is `FetchGaps` rather than local, so this and the real session's
        // responder cannot drift apart.
        let markers = FetchGaps.markers(
            before: ordered.map { Location(group: $0.group, object: $0.object) },
            order: order
        )
        var records: [FetchedRecord] = []
        for (index, object) in ordered.enumerated() {
            if let marker = markers[index] { records.append(.missing(through: marker)) }
            records.append(.object(object))
        }
        return records
    }

    func cancelFetch(on track: FullTrackName) {
        interactions.append(.cancelledFetch(track))
    }

    func reprioritise(_ track: FullTrackName, priority: UInt8) {
        interactions.append(.reprioritised(track, priority: priority))
    }

    func publish(_ track: FullTrackName) {
        interactions.append(.published(track))
    }

    func deliver(_ object: TrackObject, to track: FullTrackName) {
        interactions.append(.wrote(track, group: object.group, object: object.object))
        delivered[track, default: []].append(object)

        if latestGroupNumber[track] != object.group {
            latestGroupNumber[track] = object.group
            latestGroup[track] = []
        }
        latestGroup[track, default: []].append(object)
        guard let targets = subscribers[track] else { return }
        for continuation in targets.values {
            continuation.yield(object)
        }
    }

    func close(code: UInt64) {
        interactions.append(.closed(code: code))
    }
}
