// Writing a room's control log.
//
// Held by the room's authority, which is the relay and the control plane behind
// it rather than any participant's device. Two reasons, and the second is the
// one that decides it. A client can be demoted by the very entry it would have
// to publish, so a client-authored log is a client that can decline to say it
// lost its own permissions. And presence is unpublishable by its subject: a
// phone in a tunnel cannot announce that it is in a tunnel, so only the party
// watching the session drop can write that down.
//
// The class is public anyway, because the shape of the log is a protocol
// contract rather than an implementation detail — a self-hosted deployment
// writing this track from its own control plane needs the same grouping and
// numbering rules, and a test needs to be able to be the authority.
//
// The snapshot cadence is the only tunable, and it is a straight trade. Every
// group starts with a complete state, so frequent groups mean fast recovery and
// more bytes; rare groups mean a returning client waits longer for a resync it
// could have had immediately. The default splits at eight changes or thirty
// seconds, which for a busy room is a snapshot every few seconds and for an idle
// one is a snapshot nobody needed anyway.

import Foundation
import MoqomCore

/// Publishes a room's control log on its `.control` track.
public actor RoomLogPublisher {
    /// When to start a new group with a fresh snapshot.
    public struct Cadence: Hashable, Sendable {
        /// Snapshot after this many changes.
        public var changes: Int

        /// Snapshot after this long, whatever the change count.
        ///
        /// Bounds recovery latency in a quiet room. Without it a room that
        /// settles after one busy minute leaves its next joiner reading a
        /// snapshot from whenever the last flurry ended, and a lost object from
        /// that flurry stays lost for as long as the room stays calm.
        public var interval: Duration

        public init(changes: Int = 8, interval: Duration = .seconds(30)) {
            self.changes = changes
            self.interval = interval
        }

        public static let `default` = Cadence()
    }

    /// Priority for the control track.
    ///
    /// Above all media and beside the catalog. It is tens of bytes, and shedding
    /// it under congestion means a client that keeps rendering video while
    /// holding stale authorisation state — a force-muted cohost still audible
    /// because the mute lost a race with a frame.
    public static let priority: UInt8 = 8

    public private(set) var cadence: Cadence

    /// The state as published, which is what the next snapshot will contain.
    public private(set) var state: RoomSnapshot

    /// The last sequence written. `0` before anything.
    public private(set) var sequence: UInt64 = 0

    /// The last group opened.
    public private(set) var group: UInt64 = 0

    private let writer: any TrackWriter
    let signer: RoomLogSigner
    private let tenant: TenantID
    private let room: RoomID
    private var object: UInt64 = 0
    private var changesSinceSnapshot = 0
    private var lastSnapshot: MonotonicTime?

    /// - Parameters:
    ///   - signer: The authority's key. Every entry is signed with it, and a
    ///     reader applies nothing that is not.
    ///   - tenant: With `room`, what every signature is bound to.
    ///   - sequence: Where to carry on from. An authority that reconnects must
    ///     pass what it had reached, because restarting at zero means every
    ///     reader treats the new entries as ones it has already applied and the
    ///     room silently stops updating. Same for `group`, which MOQT requires
    ///     to be increasing within a track.
    public init(
        writer: any TrackWriter,
        signer: RoomLogSigner,
        tenant: TenantID,
        room: RoomID,
        state: RoomSnapshot = RoomSnapshot(),
        cadence: Cadence = .default,
        sequence: UInt64 = 0,
        group: UInt64 = 0
    ) {
        self.writer = writer
        self.signer = signer
        self.tenant = tenant
        self.room = room
        self.state = state
        self.cadence = cadence
        self.sequence = sequence
        self.group = group
    }

    public func setCadence(_ cadence: Cadence) {
        self.cadence = cadence
    }

    /// Publish a change, and a snapshot first if one is due.
    ///
    /// - Returns: The sequence the change was written at.
    @discardableResult
    public func append(
        _ change: RoomChange,
        at now: MonotonicTime = .nanoseconds(DispatchTime.now().uptimeNanoseconds)
    ) async throws(MoqomError) -> UInt64 {
        state.apply(change)

        if isSnapshotDue(at: now) {
            // Written *after* folding the change in, so the snapshot that opens
            // the group already contains it and the change is not published
            // twice. A subscriber joining on this group sees the effect once, in
            // the state, which is the same thing it would have computed.
            try await writeSnapshot(at: now)
            return sequence
        }

        sequence += 1
        try await write(RoomUpdate(sequence: sequence, change))
        changesSinceSnapshot += 1
        return sequence
    }

    /// Publish a complete state now, opening a new group.
    ///
    /// Called on a cadence, and worth calling directly when the authority knows
    /// somebody is about to need it — a relay that has just seen a session
    /// return, for instance, which turns that client's resync from a fetch into
    /// something already on its way.
    @discardableResult
    public func snapshot(
        at now: MonotonicTime = .nanoseconds(DispatchTime.now().uptimeNanoseconds)
    ) async throws(MoqomError) -> UInt64 {
        try await writeSnapshot(at: now)
        return sequence
    }

    /// Replace the published state wholesale and snapshot it.
    ///
    /// The path a control plane uses when it has reloaded a room from its
    /// database and would rather assert the result than compute the difference.
    @discardableResult
    public func publish(
        _ state: RoomSnapshot,
        at now: MonotonicTime = .nanoseconds(DispatchTime.now().uptimeNanoseconds)
    ) async throws(MoqomError) -> UInt64 {
        self.state = state
        try await writeSnapshot(at: now)
        return sequence
    }

    public func finish() async {
        await writer.finish()
    }

    private func isSnapshotDue(at now: MonotonicTime) -> Bool {
        guard let lastSnapshot else { return true }
        if changesSinceSnapshot >= cadence.changes { return true }
        return now - lastSnapshot >= cadence.interval
    }

    private func writeSnapshot(at now: MonotonicTime) async throws(MoqomError) {
        sequence += 1
        let update = RoomUpdate(sequence: sequence, state)

        // A new group, because a group is where a subscriber can join, and the
        // whole design rests on a joiner landing on a complete state rather
        // than on the middle of a conversation about one.
        group += 1
        object = 0
        do {
            try await writer.startGroup(group)
        } catch {
            // Rolled back so the next attempt writes this sequence rather than
            // leaving a number that no object will ever carry — which a reader
            // cannot distinguish from an entry it lost.
            sequence -= 1
            group -= 1
            throw error
        }
        try await write(update, isKeyFrame: true)
        changesSinceSnapshot = 0
        lastSnapshot = now
    }

    private func write(
        _ update: RoomUpdate,
        isKeyFrame: Bool = false
    ) async throws(MoqomError) {
        let payload: Data
        let signature: Data
        do {
            payload = try update.encoded()
            signature = try signer.sign(payload, tenant: tenant, room: room)
        } catch {
            sequence -= 1
            throw MoqomError.invalidState(
                expected: "encodable, signable room update",
                actual: "\(error)"
            )
        }
        do {
            try await writer.write(
                TrackObject(
                    group: group,
                    object: object,
                    priority: Self.priority,
                    payload: payload,
                    isKeyFrame: isKeyFrame,
                    properties: ObjectProperties(authoritySignature: signature)
                )
            )
        } catch {
            sequence -= 1
            throw error
        }
        object += 1
    }
}

public extension RoomLogPublisher {
    /// A publisher for a room's control track on `session`.
    ///
    /// The track sits under the room's own prefix rather than under a
    /// participant's, so publishing it requires authority over the room. A
    /// participant's token does not carry that, and the relay refuses — which is
    /// the enforcement, not this comment.
    static func opening(
        room: RoomID,
        tenant: TenantID,
        on session: any TransportSession,
        signer: RoomLogSigner,
        state: RoomSnapshot = RoomSnapshot(),
        cadence: Cadence = .default,
        sequence: UInt64 = 0,
        group: UInt64 = 0
    ) async throws(MoqomError) -> RoomLogPublisher {
        let track: FullTrackName
        do {
            track = try FullTrackName(
                namespace: MoqomNamespaces.room(tenant: tenant, room: room),
                name: TrackName(RoomUpdate.trackName)
            )
        } catch {
            throw MoqomError.invalidName(error)
        }
        let writer = try await session.publish(track, priority: priority)
        return RoomLogPublisher(
            writer: writer,
            signer: signer,
            tenant: tenant,
            room: room,
            state: state,
            cadence: cadence,
            sequence: sequence,
            group: group
        )
    }
}
