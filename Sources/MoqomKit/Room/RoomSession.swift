// A room, live.
//
// Two things in here are worth reading before changing them.
//
// First, `localMute` never touches the transport. Because the relay forwards
// rather than mixes, one viewer silencing one cohost is an unsubscribe: the
// bytes never leave the relay, it takes effect immediately, and there is
// nothing to ask permission for. In an SFU the same action means receiving the
// audio and discarding it client-side. Sending a control message here would
// turn a bandwidth saving into a round-trip for no gain, so the absence of that
// call is a feature and there is a test asserting it.
//
// Second, watchdogs arrive through a different door from participants. The
// roster is built from namespace announcements and nothing else; watchdogs come
// from explicit room state. They are never the same code path, which is what
// makes it impossible to accidentally count a recorder as a viewer.

import Foundation
import MoqomCore

/// A joined room.
public actor RoomSession {
    public nonisolated let tenant: TenantID
    public nonisolated let room: RoomID

    /// The prefix every participant announces under.
    public nonisolated let namespace: TrackNamespace

    /// This device.
    public nonisolated let identity: ParticipantIdentity

    private let connection: any TransportSession
    private var state: RoomState
    private var planner = SubscriptionPlanner()
    private var subscriptions: [ParticipantIdentity: any SubscriptionHandle] = [:]
    private var broadcast: Broadcast?
    private var rosterTask: Task<Void, Never>?

    private let eventStream: AsyncStream<RoomEvent>
    private let eventContinuation: AsyncStream<RoomEvent>.Continuation

    init(
        tenant: TenantID,
        room: RoomID,
        namespace: TrackNamespace,
        identity: ParticipantIdentity,
        connection: any TransportSession
    ) {
        self.tenant = tenant
        self.room = room
        self.namespace = namespace
        self.identity = identity
        self.connection = connection
        state = RoomState(tenant: tenant, room: room, namespace: namespace)
        (eventStream, eventContinuation) = AsyncStream.makeStream(
            of: RoomEvent.self,
            bufferingPolicy: .unbounded
        )
    }

    /// Everything happening in the room.
    public nonisolated var events: AsyncStream<RoomEvent> { eventStream }

    /// A snapshot.
    public var currentState: RoomState { state }

    /// Who is here. Cannot contain a watchdog.
    public var roster: Roster { state.roster }

    /// What is observing. Render as room chrome, never as a tile.
    public var watchdogs: [Watchdog] { state.watchdogs.all }

    /// Start watching the room prefix.
    func begin() async {
        guard rosterTask == nil else { return }
        let stream: AsyncStream<AnnouncementEvent>
        do {
            stream = try await connection.announcements(matching: namespace)
        } catch {
            return
        }
        rosterTask = Task { [weak self] in
            for await event in stream {
                await self?.applyAnnouncement(event)
            }
        }
    }

    func end() async {
        rosterTask?.cancel()
        rosterTask = nil
        await broadcast?.stop()
        broadcast = nil
        for subscription in subscriptions.values {
            await subscription.cancel()
        }
        subscriptions.removeAll()
        eventContinuation.finish()
    }

    // MARK: - Publishing

    /// Go live.
    ///
    /// Called by the participant, never by the SDK in response to a scope
    /// change. A grant is permission; going live is an act, and conflating them
    /// is a privacy incident rather than a bug.
    @discardableResult
    public func startBroadcast(
        from source: any FrameSource,
        configuration: BroadcastConfiguration = BroadcastConfiguration(),
        backstage: Bool = false
    ) async throws(MoqomError) -> Broadcast {
        if let broadcast { return broadcast }

        let publishNamespace: TrackNamespace
        do {
            publishNamespace = backstage
                ? try MoqomNamespaces.backstageParticipant(
                    tenant: tenant, room: room, identity: identity
                )
                : try MoqomNamespaces.participant(
                    tenant: tenant, room: room, identity: identity
                )
        } catch {
            throw MoqomError.invalidName(error)
        }

        let announcement = try await connection.announce(publishNamespace)

        var writers: [LayerID: any TrackWriter] = [:]
        for (index, rung) in configuration.ladder.rungs.enumerated() {
            let track: FullTrackName
            do {
                track = try FullTrackName(
                    namespace: publishNamespace,
                    name: TrackName(rung.id.value)
                )
            } catch {
                throw MoqomError.invalidName(error)
            }
            let priority = UInt8(min(255, Int(configuration.basePriority) + index * 8))
            writers[rung.id] = try await connection.publish(track, priority: priority)
        }

        let live = Broadcast(
            namespace: publishNamespace,
            configuration: configuration,
            source: source,
            announcement: announcement,
            writers: writers
        )
        broadcast = live
        await live.start()
        return live
    }

    public func stopBroadcast() async {
        await broadcast?.stop()
        broadcast = nil
    }

    func startNewGroup() async {
        await broadcast?.startNewGroup()
    }

    // MARK: - Subscribing

    /// Tell the SDK how big each participant is being drawn.
    ///
    /// Call this from a layout pass. It is cheap when nothing changed — the
    /// planner returns an empty diff — so it does not need debouncing at the
    /// call site, and driving it from every layout is how a resize gets picked
    /// up promptly.
    @discardableResult
    public func updateLayout(
        _ boxes: [ParticipantIdentity: RenderBox],
        linkBitrate: Int = .max
    ) async -> [SubscriptionChange] {
        let changes = planner.plan(boxes: boxes, linkBitrate: linkBitrate)
        for change in changes {
            await apply(change)
        }
        return changes
    }

    /// Pre-warm before a transition that will need a higher layer.
    ///
    /// Call on touch-down or hover, not on the tap. Starting the higher layer
    /// when the *intent* appears means the frame is ready before the animation
    /// finishes rather than a second after it.
    public func prewarm(_ target: ParticipantIdentity, for box: RenderBox) {
        planner.prewarm(target, for: box)
    }

    /// Silence one participant for this viewer alone.
    ///
    /// Deliberately not `async throws` against the network: this is an
    /// unsubscribe and a local state change. Nobody else is affected and the
    /// server need not know.
    public func localMute(_ target: ParticipantIdentity, _ kinds: MediaKind) {
        guard var participant = state.roster[target] else { return }
        participant.mute.localToMe.formUnion(kinds)
        state.roster[target] = participant
        eventContinuation.yield(.muteChanged(target, participant.mute))
    }

    public func localUnmute(_ target: ParticipantIdentity, _ kinds: MediaKind) {
        guard var participant = state.roster[target] else { return }
        participant.mute.localToMe.subtract(kinds)
        state.roster[target] = participant
        eventContinuation.yield(.muteChanged(target, participant.mute))
    }

    // MARK: - Moderation

    /// Act on a participant.
    ///
    /// Authorisation is checked here as well as at the relay. The client check
    /// is not a security boundary — a modified client ignores it — but it turns
    /// a disabled button into a local decision rather than a round-trip, and it
    /// keeps the two implementations of the subset rule in one place.
    public func moderate(
        _ action: ModerationAction,
        as actor: Grants
    ) async throws(MoqomError) {
        let target = action.target.flatMap { state.roster[$0]?.grants }
        if case let .failure(error) = authorize(action, by: actor, against: target) {
            throw error
        }
        apply(action)
    }

    /// Attach, detach, start, or stop a watchdog.
    ///
    /// A separate call from ``moderate(_:as:)`` because the verbs are different
    /// and so is the authorisation: you do not kick a recorder, you stop it.
    public func manageWatchdog(
        _ action: WatchdogAction,
        as actor: Grants
    ) async throws(MoqomError) {
        guard actor.isOwner || actor.moderation.contains(.manageWatchdogs) else {
            throw MoqomError.notPermitted(.manageWatchdogs)
        }
        switch action {
        case let .attach(request):
            let watchdog = Watchdog(
                id: WatchdogID(UUID().uuidString),
                kind: request.kind,
                operatedBy: request.operatedBy,
                descriptor: request.descriptor,
                scope: request.scope,
                attachedAt: Date(),
                isBillable: request.operatedBy != .platform,
                pinnedLayer: request.pinnedLayer
            )
            try state.watchdogs.attach(watchdog)
        case let .detach(id):
            state.watchdogs.detach(id)
        case let .start(id):
            state.watchdogs.setHealth(.attached, for: id)
        case let .stop(id):
            state.watchdogs.setHealth(.failed, for: id)
        }
        eventContinuation.yield(.watchdogChanged(state.watchdogs))
    }

    // MARK: - Room state

    func publishPresence(_ presence: Presence, for who: ParticipantIdentity) {
        guard var participant = state.roster[who] else { return }
        participant.presence = presence
        state.roster[who] = participant
        eventContinuation.yield(.presenceChanged(who, presence))
    }

    func deliverTerminal(_ event: TerminalEvent) {
        state.lifecycle = .ended(event)
        eventContinuation.yield(.terminated(event))
    }

    /// Apply room state received on the control track.
    ///
    /// Watchdogs arrive here and nowhere else. There is no path from this
    /// method into the roster.
    public func applyRoomState(watchdogs: WatchdogSet) {
        state.watchdogs = watchdogs
        eventContinuation.yield(.watchdogChanged(watchdogs))
    }

    /// Apply grants received on the control track.
    public func applyGrants(_ grants: Grants, to who: ParticipantIdentity) {
        guard var participant = state.roster[who] else { return }
        participant.grants = grants
        state.roster[who] = participant
        planner.setLadder(
            participant.ladders[MediaKind.video.rawValue] ?? .defaultCamera(),
            for: who
        )
        eventContinuation.yield(.grantsChanged(who, grants))
    }

    private func applyAnnouncement(_ event: AnnouncementEvent) {
        let before = Set(state.roster.participants.map(\.id))
        state.roster.apply(event, under: namespace)
        let after = Set(state.roster.participants.map(\.id))

        for joined in after.subtracting(before) {
            if let participant = state.roster[joined] {
                planner.setLadder(.defaultCamera(), for: joined)
                eventContinuation.yield(.participantJoined(participant))
            }
        }
        for left in before.subtracting(after) {
            planner.remove(left)
            subscriptions.removeValue(forKey: left)
            eventContinuation.yield(.participantLeft(left))
        }
    }

    private func apply(_ action: ModerationAction) {
        switch action {
        case let .kick(who):
            state.roster.remove(who)
            eventContinuation.yield(.participantLeft(who))
        case let .forceMute(who, kinds, _):
            guard var participant = state.roster[who] else { return }
            participant.mute.forcedForEveryone.formUnion(kinds)
            state.roster[who] = participant
            eventContinuation.yield(.muteChanged(who, participant.mute))
        case let .unmute(who, kinds):
            guard var participant = state.roster[who] else { return }
            participant.mute.forcedForEveryone.subtract(kinds)
            state.roster[who] = participant
            eventContinuation.yield(.muteChanged(who, participant.mute))
        case let .demote(who, scope):
            guard var participant = state.roster[who] else { return }
            participant.grants.publish.subtract(scope)
            state.roster[who] = participant
            eventContinuation.yield(.grantsChanged(who, participant.grants))
        case let .spotlight(who):
            state.stage.spotlighted = who
            eventContinuation.yield(.spotlightChanged(who))
        case let .lockStage(locked):
            state.stage.isLocked = locked
            eventContinuation.yield(.stageChanged(state.stage))
        case let .closeRoom(event):
            state.lifecycle = .ended(event)
            eventContinuation.yield(.terminated(event))
        case .banFromRoom, .banFromTenant, .banDevice:
            // Bans are control-plane records enforced in relay state. The
            // client reflects the resulting kick when the roster changes rather
            // than predicting it, so a ban that the control plane rejects does
            // not leave the UI showing someone as gone.
            break
        }
    }

    private func apply(_ change: SubscriptionChange) async {
        switch change {
        case let .subscribe(who, layer, priority):
            guard let participant = state.roster[who] else { return }
            if let existing = subscriptions[who] {
                await existing.cancel()
            }
            guard
                let name = try? TrackName(layer.value),
                let track = try? FullTrackName(namespace: participant.slot.namespace, name: name)
            else { return }
            let request = SubscribeRequest(track: track, priority: priority)
            subscriptions[who] = try? await connection.subscribe(request)
        case let .unsubscribeVideo(who):
            if let existing = subscriptions.removeValue(forKey: who) {
                await existing.cancel()
            }
        case let .reprioritise(who, priority):
            await subscriptions[who]?.updatePriority(priority)
        }
    }
}
