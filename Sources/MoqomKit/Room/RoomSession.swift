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

/// Presents a token, and optionally a new way to renew it, on the connection a
/// room shares with every other room on its session.
typealias CredentialUpdate = @Sendable (
    IssuedToken,
    (@Sendable () async throws -> IssuedToken)?
) async throws(MoqomError) -> Void

/// A joined room.
public actor RoomSession {
    public nonisolated let tenant: TenantID
    public nonisolated let room: RoomID

    /// The personal channel this session is watching, when it is one.
    ///
    /// Set for ``MoqomSession/goLive()`` and ``MoqomSession/watch(_:)``.
    /// Publishing then uses the caller's own `(tenant, "u", …)` slot rather
    /// than a room participant slot, and the roster is built from that
    /// prefix plus any catalog references the host publishes.
    public nonisolated let channel: Username?

    /// The prefix every participant announces under.
    public nonisolated let namespace: TrackNamespace

    /// This device.
    public nonisolated let identity: ParticipantIdentity

    /// Where this room's diagnostics go.
    ///
    /// Silent unless the application asked for a sink, because a library has no
    /// business writing to somebody else's log by default.
    public nonisolated let logger: MoqomLogger

    private var connection: any TransportSession
    private var state: RoomState
    private var planner = SubscriptionPlanner()
    private var subscriptions: [ParticipantIdentity: any SubscriptionHandle] = [:]
    private var broadcast: Broadcast?
    private var audio: AudioPublication?
    private var audioAnnouncement: (any AnnouncementHandle)?
    private var encryption: RoomEncryption?
    private var unprotector: MediaUnprotector?

    /// The MLS group keying this room, when the SDK rather than the application
    /// holds the keys. See ``DeviceCredentials/keyDelivery``.
    private var managedKeys: ManagedRoomKeys?
    private let keyDelivery: (any MLSDeliveryService)?
    private let currentToken: (@Sendable () async -> Data)?

    /// Hands a token to the ``MoqomSession`` this room hangs off, which owns the
    /// credential because the connection is shared by every room on it.
    private let presentCredential: CredentialUpdate?

    /// Whether this room insists on end-to-end encryption:
    /// ``EncryptionPolicy/required``. Not settable, on purpose: see
    /// ``EncryptionPolicy``.
    public private(set) var encryptionPolicy: EncryptionPolicy

    /// Participants already told about through ``RoomEvent/encryptionRequired(_:)``.
    ///
    /// So a publisher sending thirty frames a second produces one event rather
    /// than thirty, and a fresh one after this device's key arrives and goes away.
    private var refusedUnencrypted: Set<ParticipantIdentity> = []
    private var catalogPublisher: CatalogPublisher?
    private var catalogRefresh: Task<Void, Never>?
    private var catalogRestatement: Task<Void, Never>?

    /// Watches the broadcast's shape, for as long as it is publishing.
    private var catalogReshapes: Task<Void, Never>?

    /// Watches whether the broadcast is producing anything at all.
    private var catalogStalls: Task<Void, Never>?

    /// Retries of a broadcast's writers after a reconnect, and the announcement they share.
    private var publicationRepair: Task<Void, Never>?
    private var reopenedAnnouncement: (any AnnouncementHandle)?
    private var catalogs: [ParticipantIdentity: CatalogReader] = [:]
    private var catalogTasks: [ParticipantIdentity: Task<Void, Never>] = [:]
    private var pumps: [ParticipantIdentity: Task<Void, Never>] = [:]
    private var media: [ParticipantIdentity: MediaSink] = [:]
    private var depacketisers: [ParticipantIdentity: VideoDepacketiser] = [:]

    /// Consumers decoding a participant's media for their own purposes.
    ///
    /// Keyed by participant and held as arrays because two taps on one person
    /// is a real case — a safety classifier on keyframes and a transcriber on
    /// everything are different cadences and should not have to agree.
    /// What this device has muted on itself. See ``setSelfMuted(_:)``.
    ///
    /// The source of truth, rather than the roster entry, because that entry is
    /// this device's own announcement arriving back and can be absent or be
    /// rebuilt — on a reconnect, on a rejoin — while the user's choice about
    /// their own microphone has not changed and must not be quietly discarded.
    private var ownMute: MediaKind = []

    /// The language this device is publishing, as a BCP 47 tag.
    ///
    /// Source of truth for the same reason ``ownMute`` is: the roster entry is
    /// this device's own announcement arriving back, and a locale set before
    /// that lands — or changed while the catalog is down — must not be
    /// discarded. Starts as the phone's current locale; ``setLocale(_:)``
    /// replaces it, including mid-broadcast.
    private var ownLocale: String? = SpokenLocale.current()

    /// What this device's own hardware has stopped producing, unasked.
    ///
    /// Kept beside ``ownMute`` and never merged into it. They are published in
    /// the same document and they mean opposite things about the person: one is
    /// a choice they made and the other is a choice made for them.
    private var ownInterruption: MediaKind = []

    /// What the relay is holding down on this device, as it last said.
    ///
    /// Separate from ``ownMute`` because the two are lifted by different
    /// people, and separate from the roster entry for the same reason it is:
    /// this arrives on a track of its own and must survive the roster being
    /// rebuilt by a reconnect.
    private var enforced = ParticipantPolicy()

    /// Kinds the relay has stopped enforcing that this device has not turned
    /// back on. See ``resumeAfterForceMute(_:)``.
    private var freed: MediaKind = []

    /// Reads the `.policy` track the relay pushes at this session.
    private var policyTask: Task<Void, Never>?

    private var videoTaps: [ParticipantIdentity: [ReceiveVideoPipe]] = [:]
    private var audioTaps: [ParticipantIdentity: [ReceiveAudioPipe]] = [:]

    /// Which rung each participant is currently subscribed at.
    ///
    /// Needed because the decoder configuration is per rung: reading the
    /// catalog is not enough without knowing which of its tracks is the one
    /// arriving.
    private var subscribedLayers: [ParticipantIdentity: LayerID] = [:]

    private var audioSubscriptions: [ParticipantIdentity: any SubscriptionHandle] = [:]
    private var audioPumps: [ParticipantIdentity: Task<Void, Never>] = [:]
    private var audioSinks: [ParticipantIdentity: AudioSink] = [:]
    private var receivers: [ParticipantIdentity: AudioReceiver] = [:]
    private var estimator = BandwidthEstimator()
    private var rosterTask: Task<Void, Never>?
    private var prefixTasks: [Task<Void, Never>] = []
    private var followed: Set<TrackNamespace> = []
    private var ownReferences: [TrackNamespace] = []
    private var ownInvitations: [StageInvitationRecord] = []

    private var speakers = ActiveSpeakers()
    private var gallery = Gallery()

    /// Occupancy of the Picture in Picture window, or `nil` when nothing has
    /// asked for one.
    ///
    /// Optional rather than always-on so a room that never enters PiP does not
    /// rank a second gallery on every speech transition. It is here rather than
    /// in the AVKit layer because the two inputs it needs — who is in the room
    /// and who is talking — are both here, and a PiP window that disagreed with
    /// the grid about who matters would be visible the moment somebody
    /// backgrounded the app mid-conversation.
    private var pictureInPicture: PictureInPictureStage?
    private var pictureInPictureContinuation: AsyncStream<[Gallery.Slot]>.Continuation?

    /// Runs only while somebody is speaking.
    ///
    /// Speech has to be able to *end* without a packet arriving, because a
    /// publisher using DTX stops sending when it stops talking — so the last
    /// person to speak in a room that has gone quiet would stay lit forever. It
    /// exits when nobody is speaking rather than ticking for the life of the
    /// room, because an idle room should cost nothing.
    private var speechTask: Task<Void, Never>?

    private let eventStream: AsyncStream<RoomEvent>
    private let eventContinuation: AsyncStream<RoomEvent>.Continuation

    /// How long a vanished participant keeps their seat.
    private let seatPolicy: SeatPolicy

    /// When each participant's media last arrived.
    ///
    /// The one liveness signal that costs nothing to collect, because every
    /// object already passes through here on its way to a decoder. Recorded per
    /// participant rather than per track: a publisher whose video has frozen
    /// while their audio continues is a stalled camera, not a stalled peer, and
    /// the tile is what a viewer is looking at either way.
    private var lastObject: [ParticipantIdentity: MonotonicTime] = [:]

    /// Seats being held open, and the timer that will give up on each.
    ///
    /// Membership here is what distinguishes "gone" from "gone for now", and it
    /// is why a withdrawal is not a departure: everyone in this dictionary is
    /// still in the roster, still holds a tile, and is one re-announcement away
    /// from carrying on as though nothing happened.
    private var held: [ParticipantIdentity: Task<Void, Never>] = [:]

    /// What this room may do with direct paths, while it may. See ``setDirect(_:)``.
    private var direct: DirectRoomOptions?

    /// Copies every media track this device publishes onto its direct sessions.
    /// Empty, and costing a lock per object, while there are none.
    private let directFanout = DirectFanout()

    /// Participants whose catalog says they opted in to direct paths.
    private var directOptedIn: Set<ParticipantIdentity> = []
    private var directStates: [ParticipantIdentity: DirectPathState] = [:]
    private var directCounters: [ParticipantIdentity: DirectCounter] = [:]
    private var directSessions: [ParticipantIdentity: MoqtSession] = [:]
    private var directAttaches: [ParticipantIdentity: [Task<Void, Never>]] = [:]

    /// Subscriptions read through a merge, beside the relay handles in
    /// ``subscriptions`` and ``audioSubscriptions`` that they wrap.
    private var videoDuals: [ParticipantIdentity: DirectMergedSubscription] = [:]
    private var audioDuals: [ParticipantIdentity: DirectMergedSubscription] = [:]
    private var videoPriorities: [ParticipantIdentity: UInt8] = [:]

    #if canImport(Network)
        private var directHooks: RoomDirectHooks?
        private var directPathsController: RoomDirectPaths?
        private var directTicker: Task<Void, Never>?
    #endif

    init(
        tenant: TenantID,
        room: RoomID,
        namespace: TrackNamespace,
        identity: ParticipantIdentity,
        connection: any TransportSession,
        logger: MoqomLogger = .silent,
        seatPolicy: SeatPolicy = .default,
        channel: Username? = nil,
        encryptionPolicy: EncryptionPolicy = .required,
        authorityKeys: [DirectVerificationKey] = [],
        keyDelivery: (any MLSDeliveryService)? = nil,
        currentToken: (@Sendable () async -> Data)? = nil,
        updateCredential: CredentialUpdate? = nil
    ) {
        self.encryptionPolicy = encryptionPolicy
        self.authorityKeys = authorityKeys
        self.keyDelivery = keyDelivery
        self.currentToken = currentToken
        presentCredential = updateCredential
        self.seatPolicy = seatPolicy
        self.tenant = tenant
        self.room = room
        self.channel = channel
        self.namespace = namespace
        self.identity = identity
        self.connection = connection
        self.logger = logger
        state = RoomState(tenant: tenant, room: room, namespace: namespace)

        // This device's own camera is a self view drawn from the capture session,
        // not a subscription to its own upload.
        gallery.excluded = [identity]
        (eventStream, eventContinuation) = AsyncStream.makeStream(
            of: RoomEvent.self,
            bufferingPolicy: .unbounded
        )
    }

    /// Everything happening in the room.
    ///
    /// > Important: One consumer. Two `for await` loops over this split the
    /// > events between them rather than each seeing all of them, which is an
    /// > `AsyncStream` property and not a choice made here — but it is the kind
    /// > of thing that looks like a dropped-event bug from a long way away, so
    /// > an application wanting several readers should fan out from one loop of
    /// > its own.
    public nonisolated var events: AsyncStream<RoomEvent> { eventStream }

    /// Change what this participant may do in the room, on the connection
    /// already open.
    ///
    /// Present the token the backend minted for the new role. A promoted viewer
    /// then goes live on this same session with
    /// ``startBroadcast(from:configuration:backstage:)`` or
    /// ``startAudio(from:configuration:backstage:)`` — a grant is permission,
    /// and starting a camera stays the participant's choice. A demoted guest's
    /// publications are ended by the relay and reported as
    /// ``RoomEvent/publishingRevoked(_:)``. Either way the room keeps playing
    /// and nobody sees this participant leave and come back.
    ///
    /// The same call as ``MoqomSession/updateCredential(_:renewingWith:)``, made
    /// from where the promotion is usually noticed.
    public func updateCredential(
        _ issued: IssuedToken,
        renewingWith renew: (@Sendable () async throws -> IssuedToken)? = nil
    ) async throws(MoqomError) {
        guard let presentCredential else {
            throw MoqomError.invalidState(
                expected: "a room joined through a MoqomSession",
                actual: "a room with no session to hold its credential"
            )
        }
        try await presentCredential(issued, renew)
    }

    /// Turn on end-to-end encryption for everything this session publishes and
    /// receives.
    ///
    /// Set before going live. Changing it mid-broadcast would mean some objects
    /// in a group are encrypted and some are not, which no receiver can be
    /// expected to sort out.
    ///
    /// Required in every room. Without it ``startBroadcast(from:configuration:backstage:)``
    /// and ``startAudio(from:configuration:backstage:)`` throw
    /// ``MoqomError/encryptionRequired`` and incoming media is dropped.
    ///
    /// Not needed when the credentials carry a
    /// ``DeviceCredentials/keyDelivery``: a required room then keys itself.
    /// Calling this anyway replaces the managed keys with the ones given, which
    /// is the override for an application that distributes its own.
    public func useEncryption(_ encryption: RoomEncryption) {
        if let managedKeys {
            self.managedKeys = nil
            Task { await managedKeys.stop() }
        }
        self.encryption = encryption
        unprotector = MediaUnprotector(receiver: encryption.receiver)
        refusedUnencrypted.removeAll()
    }

    /// Whether this session has an encryption key configured, or is having one
    /// agreed for it.
    public var isEncrypted: Bool { encryption != nil }

    /// The room's MLS group, when its keys are managed and it has formed.
    ///
    /// `nil` when the application supplied a key, the room is not encrypted,
    /// or this device has not been added yet — media it publishes in that
    /// window is dropped rather than sent, because nobody could open it.
    public var groupKeys: GroupKeyStatus? {
        get async { await managedKeys?.status }
    }

    // MARK: - Direct paths

    /// Let this room carry media directly between participants where it may,
    /// with the relay as the fallback; `nil` turns it off again.
    ///
    /// Off by default, and the acknowledgement in ``DirectRoomOptions/exposure``
    /// is the reason: a direct path tells each peer this device's IP addresses.
    /// Turning it on publishes the opt-in on this device's catalog and changes
    /// nothing else until the room qualifies under ``DirectEligibility``:
    /// end-to-end encrypted, at most four participants counting everyone
    /// holding the room's keys, no watchdog, this device publishing on stage,
    /// and every other participant opted in too. A viewer is never offered a
    /// path and never offers one.
    ///
    /// Every participant's media keeps arriving over the relay throughout.
    /// Where a direct path opens, each of their tracks is read over both and
    /// merged (``DualSubscription``), so a path that fails costs nothing but
    /// the time to notice. ``directPaths`` and
    /// ``RoomEvent/directPathChanged(_:_:)`` say where each participant stands.
    ///
    /// Throws for a personal channel, which is a broadcast to an audience of
    /// any size, for a room not joined through a ``MoqomSession``, which has
    /// no backend to bind a direct endpoint on, and for an
    /// ``DirectRoomOptions/offerSecret`` shorter than 16 bytes.
    public func setDirect(_ options: DirectRoomOptions?) async throws(MoqomError) {
        if options != nil {
            guard channel == nil else {
                throw MoqomError.invalidState(
                    expected: "a room", actual: "a personal channel, which has no direct mode"
                )
            }
            if let secret = options?.offerSecret, secret.count < 16 {
                throw MoqomError.invalidState(
                    expected: "an offer secret of at least 16 bytes", actual: "\(secret.count) bytes"
                )
            }
        }
        #if canImport(Network)
            guard options == nil || directHooks != nil else {
                throw MoqomError.invalidState(
                    expected: "a room joined through a MoqomSession",
                    actual: "a room with no session to bind a direct endpoint on"
                )
            }
            let wasOn = direct != nil
            directTicker?.cancel()
            directTicker = nil
            if let controller = directPathsController {
                directPathsController = nil
                await controller.stop()
            }
            direct = options
            directStates.removeAll()
            if let options, let directHooks {
                directPathsController = RoomDirectPaths(
                    options: options,
                    tenant: tenant,
                    room: room,
                    identity: identity,
                    relay: connection,
                    hooks: directHooks,
                    fanout: directFanout,
                    owner: self,
                    logger: logger
                )
                // Most of what decides eligibility -- the MLS group's members and
                // epoch above all -- changes without telling the room, so it is
                // looked at four times a second as well as on the changes that do.
                directTicker = Task { [weak self] in
                    while !Task.isCancelled {
                        await self?.refreshDirect()
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                }
            }
            if wasOn != (options != nil) {
                await refreshCatalog()
                await resubscribeForDirect()
            }
        #else
            guard options == nil else {
                throw MoqomError.invalidState(
                    expected: "a platform with Network.framework", actual: "no direct endpoint"
                )
            }
        #endif
    }

    /// Whether direct paths are turned on for this room. See ``setDirect(_:)``.
    public var isDirectEnabled: Bool { direct != nil }

    /// How each other participant's media is reaching this device, while direct
    /// paths are turned on. Empty while they are off.
    ///
    /// Changes are reported as ``RoomEvent/directPathChanged(_:_:)``; the
    /// object counts are not, and are read here.
    public var directPaths: [ParticipantIdentity: DirectPathStatus] {
        directStates.reduce(into: [:]) { paths, entry in
            var status = DirectPathStatus(state: entry.value)
            if let counts = directCounters[entry.key]?.counts {
                status.objectsOverDirect = counts.direct
                status.objectsOverRelay = counts.relay
            }
            paths[entry.key] = status
        }
    }

    #if canImport(Network)
        /// Given by the ``MoqomSession`` that joined this room.
        func provideDirectHooks(_ hooks: RoomDirectHooks) {
            directHooks = hooks
        }

        /// The direct session open to `who`, if any. For tests.
        func directSession(with who: ParticipantIdentity) async -> DirectSession? {
            await directPathsController?.session(with: who)
        }

        private func refreshDirect() async {
            guard let directPathsController else { return }
            await directPathsController.update(directView())
        }

        private func directView() async -> DirectRoomView {
            var view = DirectRoomView()
            view.encrypted = encryption != nil && !encryptionPolicy.allowsPlaintext
            // Direct offers travel on the stage slot, so a publication backstage
            // leaves this device in the audience as far as direct paths go.
            let stage = try? slotNamespace(backstage: false)
            view.publishing = stage != nil && (broadcast?.namespace == stage || audio?.track.namespace == stage)
            view.watchdogs = !state.watchdogs.all.isEmpty
            view.peers = Set(
                state.roster.participants.filter { $0.id != identity && !$0.slot.isBackstage }.map(\.id)
            )
            view.optedIn = directOptedIn.intersection(view.peers)
            if let managedKeys, let status = await managedKeys.status {
                view.members = Set(status.members)
                // Every device in the group derives the same value for the same
                // epoch, and nobody outside it can.
                view.secret = direct?.offerSecret ?? status.directOfferSecret
            } else {
                view.secret = direct?.offerSecret
            }
            return view
        }

        func directStateChanged(_ who: ParticipantIdentity, _ path: DirectPathState) {
            guard direct != nil, state.roster[who] != nil, directStates[who] != path else { return }
            directStates[who] = path
            eventContinuation.yield(.directPathChanged(who, path))
        }

        func directSessionChanged(_ who: ParticipantIdentity, _ session: MoqtSession?) async {
            directSessions[who] = session
            for task in directAttaches.removeValue(forKey: who) ?? [] { task.cancel() }
            let merged = [videoDuals[who], audioDuals[who]].compactMap { $0 }
            if session != nil {
                for subscription in merged { attachDirect(to: subscription, from: who) }
            } else {
                // Straight back to the relay rather than waiting for the merge to
                // notice the direct subscription has ended.
                for subscription in merged { await subscription.dual.networkChanged() }
            }
        }
    #else
        private func refreshDirect() async {}
    #endif

    /// `relay`, read through a merge when direct paths are on.
    private func merging(
        _ relay: any SubscriptionHandle,
        priority: UInt8,
        from who: ParticipantIdentity
    ) -> DirectMergedSubscription? {
        guard let direct else { return nil }
        let counter = directCounters[who] ?? DirectCounter()
        directCounters[who] = counter
        let merged = DirectMergedSubscription(
            relay: relay, priority: priority, settings: direct.path, counter: counter
        )
        attachDirect(to: merged, from: who)
        return merged
    }

    /// Subscribe to the same track on the direct session to `who`, if there is
    /// one, and hand it to the merge.
    ///
    /// Retried for a while, because the peer opens its tracks on a new direct
    /// session as this side does, and a subscription that arrives first is told
    /// the track does not exist.
    private func attachDirect(to merged: DirectMergedSubscription, from who: ParticipantIdentity) {
        guard let session = directSessions[who] else { return }
        let request = SubscribeRequest(track: merged.track, priority: merged.priority)
        let task = Task {
            for _ in 0 ..< 50 {
                if Task.isCancelled { return }
                if let subscription = try? await session.subscribe(request) {
                    if Task.isCancelled {
                        await subscription.cancel()
                    } else {
                        await merged.dual.attachDirect(subscription)
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        directAttaches[who, default: []].append(task)
    }

    /// Open every subscription again, through a merge or without one, after
    /// direct paths were turned on or off.
    private func resubscribeForDirect() async {
        for (who, layer) in subscribedLayers {
            guard let priority = videoPriorities[who] else { continue }
            await apply(.subscribe(who, layer, priority: priority))
        }
        for who in Array(audioSubscriptions.keys) {
            await cancelAudio(who)
            if let catalog = await catalogs[who]?.current { await followAudio(of: who, in: catalog) }
        }
    }

    private func cancelVideo(_ who: ParticipantIdentity) async {
        let relay = subscriptions.removeValue(forKey: who)
        if let merged = videoDuals.removeValue(forKey: who) {
            await merged.cancel()
        } else {
            await relay?.cancel()
        }
    }

    private func cancelAudio(_ who: ParticipantIdentity) async {
        audioPumps.removeValue(forKey: who)?.cancel()
        let relay = audioSubscriptions.removeValue(forKey: who)
        if let merged = audioDuals.removeValue(forKey: who) {
            await merged.cancel()
        } else {
            await relay?.cancel()
        }
    }

    /// Hand the room's keys to MLS, if the room requires encryption, nobody
    /// supplied a key, and there is a delivery service to agree them through.
    ///
    /// Rooms only. A personal channel is a broadcast to an audience of any
    /// size, which is the case group key agreement is the wrong tool for.
    private func startManagedKeysIfNeeded() async {
        guard encryption == nil, managedKeys == nil, !encryptionPolicy.allowsPlaintext, channel == nil,
              let keyDelivery, let currentToken
        else { return }
        let keys = ManagedRoomKeys(
            identity: identity, delivery: keyDelivery, token: currentToken, logger: logger
        )
        managedKeys = keys
        encryption = keys.encryption
        unprotector = keys.unprotector
        refusedUnencrypted.removeAll()
        await keys.start()
        logger.info(.room, "end-to-end encryption keys are managed by MLS")
    }

    /// Take the policy renewed credentials state, which outside this package's
    /// tests is always ``EncryptionPolicy/required``. Moving to required stops
    /// a publication going out in the clear, and this device is told why
    /// through ``RoomEvent/encryptionRequired(_:)``.
    func applyEncryptionPolicy(_ policy: EncryptionPolicy) async {
        guard policy != encryptionPolicy else { return }
        encryptionPolicy = policy
        logger.info(.room, "encryption policy changed", [LogField("e2ee", .text(policy.rawValue))])
        if !policy.allowsPlaintext { await startManagedKeysIfNeeded() }
        guard !policy.allowsPlaintext, encryption == nil else { return }
        let publishing = broadcast != nil || audio != nil
        await stopBroadcast()
        await stopAudio()
        if publishing { eventContinuation.yield(.encryptionRequired(identity)) }
    }

    /// Refuse to publish in the clear unless the room allows it.
    private func requireEncryptionIfPolicyDemands() throws(MoqomError) {
        guard encryption == nil, !encryptionPolicy.allowsPlaintext else { return }
        logger.error(.publish, "refused to publish without end-to-end encryption", [
            LogField("e2ee", .text(encryptionPolicy.rawValue)),
        ])
        throw MoqomError.encryptionRequired
    }

    /// An incoming object as the application may see it, or `nil` to drop it.
    ///
    /// The one place incoming media is opened, so live video, audio, catch-up and
    /// replay cannot disagree about what a room's policy permits. With a key,
    /// everything must decrypt — plaintext fails authentication like any other
    /// forgery. Without one, everything is dropped, and said so once per
    /// participant.
    private func open(_ object: TrackObject, from who: ParticipantIdentity) async -> TrackObject? {
        if let unprotector { return await unprotector.unprotect(object) }
        guard encryptionPolicy.allowsPlaintext else {
            if refusedUnencrypted.insert(who).inserted {
                logger.warning(.media, "dropping media: the room requires end-to-end encryption", [
                    LogField("participant", .participant(who)),
                ])
                eventContinuation.yield(.encryptionRequired(who))
            }
            return nil
        }
        return object
    }

    /// Media for a participant: metered, decrypted, and ready to decode.
    ///
    /// The SDK consumes the subscription itself rather than handing the raw
    /// stream over, because it has to see every object to measure the link and
    /// to decrypt. A design where the application owned the stream would mean
    /// bandwidth estimation only worked if the application remembered to feed
    /// it, which is the kind of optional correctness that is never there when
    /// it matters.
    public func media(from who: ParticipantIdentity) -> AsyncStream<TrackObject>? {
        media[who]?.objects
    }

    /// The same media, reassembled into frames a decoder will accept.
    ///
    /// This is what a renderer wants. The SDK owns the reassembly for the same
    /// reason it owns the metering: dropping objects that precede the first
    /// keyframe, noticing gaps, and attaching the parameter sets the catalog
    /// carried are all things every viewer must do identically, and an
    /// application that got any of them subtly wrong would see it as a codec
    /// bug rather than as its own.
    ///
    /// Independent of ``media(from:)``: both are fed from the same pump, so
    /// consuming one does not starve the other.
    /// Each call returns its own stream, so a caller that walks away takes only its own with
    /// it — see ``MediaSink/frames``. Two live callers each see every frame.
    public func frames(from who: ParticipantIdentity) -> AsyncStream<DepacketisedFrame>? {
        media[who]?.frames.stream()
    }

    /// A participant's audio, paced by the jitter buffer.
    ///
    /// Subscribed automatically when their catalog says they have an audio
    /// track, and unsubscribed when this viewer mutes them — which is where the
    /// bandwidth saving in per-viewer mute actually comes from.
    ///
    /// The stream yields one item per packet slot, including the slots where
    /// nothing arrived: a decoder needs to be told to conceal, and a caller
    /// that only saw the packets that made it would have no way to know.
    public func audio(from who: ParticipantIdentity) -> AsyncStream<JitterBufferOutput>? {
        audioSinks[who]?.stream
    }

    // MARK: - Raw media

    /// Decoded pictures from a participant, for processing the SDK does not do.
    ///
    /// This is the seam for anything that needs to look at what a remote person
    /// is actually showing: a safety classifier, a gesture recogniser, a
    /// re-render, a texture in a scene. Everything else on the receive path
    /// hands out compressed media — ``media(from:)`` and ``frames(from:)`` are
    /// both bitstream — because rendering goes through a display layer that
    /// decodes privately and returns nothing.
    ///
    /// So this one costs something the others do not. It starts a decompression
    /// session that would not otherwise exist, and on a phone those are a
    /// bounded hardware resource. Two consequences follow:
    ///
    /// - Call ``MediaTap/stop()`` when the processing stops. The session is
    ///   released then, or when the participant unsubscribes, or when the room
    ///   ends — but not merely because nobody is reading.
    /// - Ask for ``TapPolicy/classification`` rather than the default unless the
    ///   work genuinely needs every frame. Keyframes decode standalone, so that
    ///   policy is closer to a still image decode every couple of seconds than
    ///   to running a decoder.
    ///
    /// Frames arrive after decryption, which is the point: an end-to-end
    /// encrypted room is one a relay cannot classify and a participant can,
    /// because the participant is who the media was encrypted for. Doing the
    /// inference here is what makes those two facts compatible.
    ///
    /// Attaching before the participant's catalog arrives is fine. The decoder
    /// is built when the codec is known, and rebuilt if a rung change moves it.
    ///
    /// > Important: Nothing stops a tap from sending what it sees somewhere
    /// > else, and nothing here can tell that apart from on-device work. If
    /// > media leaves the device, that is a disclosure the integrator owes the
    /// > room; see ``Watchdog``.
    public func tapVideo(
        from who: ParticipantIdentity,
        policy: TapPolicy = .everyFrame
    ) -> MediaTap<TappedVideo> {
        let pipe = ReceiveVideoPipe(policy: policy)
        videoTaps[who, default: []].append(pipe)
        logger.debug(
            .media,
            "video tap attached",
            [LogField("participant", .participant(who))]
        )
        return pipe.tap
    }

    /// Decoded samples from a participant, for transcription and the like.
    ///
    /// Linear PCM at the format their catalog names, one element per jitter
    /// buffer slot, in order. Every slot is delivered, including the ones where
    /// nothing arrived — see ``TappedAudio/origin``, which is the difference
    /// between a transcriber that knows the line dropped and one that stitches
    /// a sentence across the hole.
    ///
    /// Cheaper than the video tap by a wide margin: audio decoding is software
    /// either way and a speech track is a few kilobytes a second.
    ///
    /// Bounded by subscription, though, and that is worth knowing before
    /// relying on it. A participant this viewer has muted is not merely silent,
    /// they are unsubscribed — which is where per-viewer mute gets its bandwidth
    /// saving — so their tap goes quiet too. A transcript of everyone in the
    /// room is a job for a participant who is listening to everyone.
    public func tapAudio(
        from who: ParticipantIdentity,
        policy: TapPolicy = .transcription
    ) -> MediaTap<TappedAudio> {
        let pipe = ReceiveAudioPipe(policy: policy)
        audioTaps[who, default: []].append(pipe)
        logger.debug(
            .media,
            "audio tap attached",
            [LogField("participant", .participant(who))]
        )
        return pipe.tap
    }

    /// Frames this device is about to encode.
    ///
    /// `nil` when nothing is being broadcast, because there is nothing to watch
    /// and returning an empty stream would be indistinguishable from a camera
    /// that has stopped. See ``Broadcast/tapFrames(policy:)``.
    public func tapCapturedVideo(policy: TapPolicy = .everyFrame) async -> MediaTap<VideoFrame>? {
        await broadcast?.tapFrames(policy: policy)
    }

    /// Samples this device is about to encode, after echo cancellation.
    ///
    /// `nil` when this device is not publishing audio. See
    /// ``AudioPublication/tapSamples(policy:)`` for why these samples are not
    /// the same thing as opening a second microphone.
    public func tapCapturedAudio(policy: TapPolicy = .transcription) async -> MediaTap<AudioFrame>? {
        await audio?.tapSamples(policy: policy)
    }

    /// What the jitter buffer is doing for one participant.
    public func audioStatistics(for who: ParticipantIdentity) -> JitterBufferStatistics? {
        receivers[who]?.buffer.stats
    }

    /// What reassembly has seen for a participant.
    public func videoStatistics(for who: ParticipantIdentity) -> VideoReceiveStatistics? {
        guard let depacketiser = depacketisers[who] else { return nil }
        return VideoReceiveStatistics(
            framesProduced: depacketiser.framesProduced,
            objectsLost: depacketiser.objectsLost,
            objectsAwaitingKeyFrame: depacketiser.objectsAwaitingKeyFrame
        )
    }

    /// How decryption is going. `nil` when the room is not encrypted.
    public var decryptionStatistics: DecryptionStatistics? {
        get async {
            guard let unprotector else { return nil }
            return DecryptionStatistics(
                objectsDecrypted: await unprotector.objectsDecrypted,
                objectsRejected: await unprotector.objectsRejected,
                objectsAwaitingKey: await unprotector.objectsAwaitingKey
            )
        }
    }

    /// A snapshot.
    public var currentState: RoomState { state }

    /// Who is here. Cannot contain a watchdog.
    public var roster: Roster { state.roster }

    /// What is observing. Render as room chrome, never as a tile.
    public var watchdogs: [Watchdog] { state.watchdogs.all }

    /// Start watching the room prefix.
    func begin() async {
        watchControl()
        watchPolicy()
        await startManagedKeysIfNeeded()
        guard prefixTasks.isEmpty else { return }
        watchPrefix(namespace)
        if let channel, let personal = try? MoqomNamespaces.personalPrefix(
            tenant: tenant, username: channel
        ) {
            watchPrefix(personal)
        }
    }

    /// Watch announcements under `prefix` and fold them into the roster.
    private func watchPrefix(_ prefix: TrackNamespace) {
        let task = Task { [weak self] in
            guard let self else { return }
            let stream: AsyncStream<AnnouncementEvent>
            do {
                stream = try await self.connection.announcements(matching: prefix)
            } catch {
                return
            }
            for await event in stream {
                await self.applyAnnouncement(event, under: prefix)
            }
        }
        prefixTasks.append(task)
        if rosterTask == nil { rosterTask = task }
    }

    /// Move the room onto a new transport session after a reconnect.
    ///
    /// A room is not the connection it happens to be running over. The roster,
    /// the layout, the encryption keys, the camera, and the encoders all survive
    /// a dropped socket; subscriptions, announcement streams, and every writer do
    /// not, because each of those was a stream on a connection that no longer
    /// exists. This replaces precisely the second set.
    ///
    /// The roster is torn down and rebuilt from the new session's announcements
    /// rather than kept. Keeping it looks better — no churn — and is wrong: a
    /// prefix subscription reports who is publishing *now*, and nobody sends a
    /// withdrawal for a participant who left while we were not connected. A
    /// retained roster would keep that participant forever. The rebuild happens
    /// while the session is still `reconnecting`, so an application showing a
    /// reconnect treatment never renders the intermediate empty state.
    func rebind(to session: any TransportSession) async {
        connection = session

        // Restored once participants re-announce. Captured before the roster is
        // torn down, because tearing it down is what discards the layout.
        layoutToRestore = planner.layout

        // Everything on the receive side belonged to the dead session. Routed
        // through the departure path rather than reimplemented so that the
        // per-participant teardown has one definition: an application watching
        // events sees each participant leave, and every pump, sink, and catalog
        // reader is released by the code that already knows how.
        //
        // Departure and not ``vanish``, which is what a withdrawal would reach.
        // Holding seats is right when one participant's session ends and this
        // one can still see the room; it is wrong here, where the reasoning in
        // the comment above applies -- this client cannot tell who is still
        // there, so a held seat is a guess rather than a wait, and the guess is
        // wrong for anybody who left during the outage.
        for participant in state.roster.participants {
            await depart(participant.id, reason: .connectionLost)
        }
        rosterTask?.cancel()
        rosterTask = nil
        for task in prefixTasks { task.cancel() }
        prefixTasks.removeAll()
        followed.removeAll()
        speechTask?.cancel()
        speechTask = nil

        // The log position goes with the roster, and for the same reason. It
        // means "everything up to here is already applied to the state I am
        // holding", and the line above threw that state away — so keeping the
        // number would have this client dismiss the snapshot it needs as
        // something it had already read, and come back to a room where nobody
        // has any grants. Re-reading the log from the start of the current group
        // is cheap and correct: that group opens with a complete state, and every
        // entry after it assigns a value rather than adjusting one.
        controlTask?.cancel()
        controlTask = nil
        controlSubscription = nil
        controlRepair?.cancel()
        controlRepair = nil
        repairedAt = nil
        log = RoomLog(policy: log.policy)

        // The offers belonged to the dead session; what they said does not go
        // with them. `enforced` is the relay's decision about this participant
        // and the control plane is holding it, so the next relay re-states it
        // from the snapshot it loads — and keeping it in the meantime is what
        // stops a reconnect from being a way to unmute yourself.
        policyTask?.cancel()
        policyTask = nil
        waiting.removeAll()

        for task in replayTasks.values { task.cancel() }
        replayTasks.removeAll()
        replayDepacketisers.removeAll()

        // Anything the withdrawals did not reach, because it was never keyed by
        // a participant.
        subscriptions.removeAll()
        audioSubscriptions.removeAll()
        for pump in audioPumps.values { pump.cancel() }
        audioPumps.removeAll()
        let merged = Array(videoDuals.values) + Array(audioDuals.values)
        videoDuals.removeAll()
        audioDuals.removeAll()
        if !merged.isEmpty {
            Task { for subscription in merged { await subscription.cancel() } }
        }

        // Offers and tickets were opened on the dead relay session, and a
        // direct path is not kept without them, so every one starts over.
        #if canImport(Network)
            await directPathsController?.rebind(to: session)
        #endif

        await rebindPublications(to: session)
        await begin()
    }

    // MARK: - The shared space

    /// The room's shared space, if this session joined it.
    private var space: SpaceSession?

    /// What it would take to build that space again on a new connection.
    ///
    /// Kept because a space is not restorable from its own state: the
    /// simulation is the application's, and a reconnect that handed back an
    /// empty one would look to the player like the game had been reset by the
    /// network.
    private var spacePlan: (
        simulation: any SpaceSimulation,
        configuration: SpaceSession.Configuration,
        clock: SpaceTimeReading
    )?

    /// Join the room's shared space: replicated state that is not media.
    ///
    /// Separate from going live, and deliberately. A space costs a subscription
    /// and nothing else until something happens in it, so a viewer can watch
    /// one without a camera — and an application that wants a board without a
    /// call should not have to start one.
    ///
    /// Calling twice returns the space already joined rather than a second one,
    /// because two simulations on one track is precisely the split brain the
    /// epoch fence exists to survive rather than to encourage.
    @discardableResult
    public func joinSpace(
        _ simulation: any SpaceSimulation,
        configuration: SpaceSession.Configuration = SpaceSession.Configuration(),
        clock: @escaping SpaceTimeReading = { .fallback() }
    ) async throws(MoqomError) -> SpaceSession {
        if let space { return space }
        let joined = try SpaceSession(
            tenant: tenant,
            room: room,
            identity: identity,
            connection: connection,
            simulation: simulation,
            configuration: configuration,
            clock: clock,
            logger: logger
        )
        space = joined
        spacePlan = (simulation, configuration, clock)
        await joined.start()
        return joined
    }

    /// The shared space this session joined, if any.
    public var sharedSpace: SpaceSession? { space }

    public func leaveSpace() async {
        await space?.stop()
        space = nil
        spacePlan = nil
    }

    /// Re-announce and re-open every writer this room was publishing through.
    private func rebindPublications(to session: any TransportSession) async {
        // The space is rebuilt rather than repointed, because everything it
        // holds — the subscription it reads, the writer it publishes through,
        // the announcement that makes it reachable — belonged to the session
        // that died. Its state is not carried over either: whoever is leading
        // now will send a snapshot, and asserting a remembered world over the
        // top of that is how a reconnecting client resurrects things the rest
        // of the room has already finished with.
        if let plan = spacePlan {
            await space?.stop()
            space = try? SpaceSession(
                tenant: tenant,
                room: room,
                identity: identity,
                connection: session,
                simulation: plan.simulation,
                configuration: plan.configuration,
                clock: plan.clock,
                logger: logger
            )
            await space?.start()
        }

        if let broadcast {
            let publishNamespace = broadcast.namespace
            await restore(broadcast, on: session)

            // Dropped rather than finished: its writer is on the dead session, so
            // there is nothing to flush and nowhere to flush it. A fresh one
            // republishes the current catalog, which a viewer needs before it can
            // build a decoder for the media about to arrive.
            catalogPublisher = nil
            do {
                try await publishCatalog(under: publishNamespace)
            } catch {
                // Loudly, because a broadcast whose catalog never came back is a black tile on
                // every viewer for the rest of the call, with media flowing behind it that
                // nobody can build a decoder for.
                logger.error(.publish, "catalog lost across a reconnect", [
                    LogField("error", .text(String(describing: error))),
                ])
            }
        }

        if let authority {
            // Reopened rather than kept, since its writer was a stream on the
            // dead session — but carrying the sequence and group it had reached.
            // Restarting either would make every reader dismiss what follows as
            // something it had already applied.
            self.authority = try? await RoomLogPublisher.opening(
                room: room,
                tenant: tenant,
                on: session,
                signer: authority.signer,
                state: await authority.state,
                cadence: await authority.cadence,
                sequence: await authority.sequence,
                group: await authority.group
            )
        }

        if let audio {
            let publishNamespace = audio.track.namespace
            if let announcement = try? await session.announce(publishNamespace) {
                watchForRefusal(of: announcement)
                audioAnnouncement = announcement
            }
            if let writer = try? await protectedWriter(
                for: audio.track,
                priority: audio.configuration.priority
            ) {
                await audio.rebind(writer: writer)
            }
            if broadcast == nil {
                catalogPublisher = nil
                try? await publishCatalog(under: publishNamespace)
            }
        }
    }

    /// Put a broadcast back on a live session, and keep trying until it is whole.
    ///
    /// The reason this is not a single attempt: reopening a track can fail for the same
    /// transient reasons the reconnect itself happened, and a rung skipped on the way through
    /// is a rung with no writer for the rest of the call. Every frame the encoder produces for
    /// it is then discarded inside ``Broadcast``, which is invisible from the outside — the
    /// camera runs, the counters climb, and nothing arrives at the far end. On a publication
    /// pinned to one rung, as a measurement run is, a single skipped reopen is the whole
    /// broadcast, silently.
    ///
    /// So the attempt repeats with a widening delay, and says so when it cannot succeed. The
    /// first attempt is awaited because the common case succeeds immediately and the caller is
    /// mid-resume; the retries are not, because the rest of the room — roster, control track,
    /// subscriptions — should not wait on one track's stream.
    private func restore(_ broadcast: Broadcast, on session: any TransportSession) async {
        publicationRepair?.cancel()
        publicationRepair = nil

        if await reopen(broadcast, on: session) { return }

        publicationRepair = Task { [weak self] in
            // Widening, and bounded. If a track cannot be opened after half a minute of trying
            // then the session is not what is broken, and a task retrying forever would hide
            // that as effectively as the original silence did.
            for delay in [Duration.milliseconds(250), .milliseconds(500), .seconds(1),
                          .seconds(2), .seconds(4), .seconds(8), .seconds(15)] {
                do { try await Task.sleep(for: delay) } catch { return }
                guard let self, !Task.isCancelled else { return }
                if await reopen(broadcast, on: session) { return }
            }
            await self?.reportPublicationLost()
        }
    }

    /// Reopen the announcement and one writer per rung.
    ///
    /// - Returns: Whether every rung the ladder describes now has a writer.
    private func reopen(_ broadcast: Broadcast, on session: any TransportSession) async -> Bool {
        let namespace = broadcast.namespace
        let configuration = broadcast.configuration

        // Held across attempts rather than retaken on each one, because announcing twice puts
        // the same participant in the roster twice.
        if reopenedAnnouncement == nil {
            do {
                let announcement = try await session.announce(namespace)
                watchForRefusal(of: announcement)
                reopenedAnnouncement = announcement
            } catch {
                logger.warning(.publish, "could not re-announce after reconnect", [
                    LogField("error", .text(String(describing: error))),
                ])
                return false
            }
        }
        guard let announcement = reopenedAnnouncement else { return false }

        var writers: [LayerID: any TrackWriter] = [:]
        var missing: [LayerID] = []
        for (index, rung) in configuration.ladder.rungs.enumerated() {
            guard
                let name = try? TrackName(rung.id.value),
                let track = try? FullTrackName(namespace: namespace, name: name)
            else {
                // A name that will not parse will not parse on the next attempt either, so
                // this one is reported rather than retried.
                logger.error(.publish, "a rung has an unusable track name", [
                    LogField("layer", .text(rung.id.value)),
                ])
                continue
            }
            let priority = UInt8(min(255, Int(configuration.basePriority) + index * 8))
            do {
                writers[rung.id] = try await protectedWriter(for: track, priority: priority)
            } catch {
                missing.append(rung.id)
                logger.warning(.publish, "could not reopen a rung after reconnect", [
                    LogField("layer", .text(rung.id.value)),
                    LogField("error", .text(String(describing: error))),
                ])
            }
        }

        // What came back goes in now, rather than waiting for the rung that did not. A viewer
        // on a recovered rung should not be held dark by an unrelated one.
        if !writers.isEmpty {
            await broadcast.rebind(writers: writers, announcement: announcement)
        }

        if missing.isEmpty {
            reopenedAnnouncement = nil
            return true
        }
        return false
    }

    /// Say that a publication could not be put back.
    ///
    /// The end of the road for a broadcast this session cannot repair. Reported rather than
    /// thrown, because there is nobody to throw to — the reconnect succeeded and the room is
    /// otherwise healthy — and reported at all because the alternative is what happened
    /// before: a camera running for half an hour into a track that no longer existed.
    private func reportPublicationLost() {
        logger.error(.publish, "broadcast could not be restored after reconnect", [
            LogField("room", .text(room.value)),
        ])
        eventContinuation.yield(.broadcastInterrupted)
    }

    /// Wait for a relay to refuse an announcement, and say so if it does.
    ///
    /// Started beside the publisher rather than in front of it, because an
    /// accepted announcement is answered with silence: there is nothing to wait
    /// for on the way in, and blocking would trade a working `startBroadcast`
    /// for a timeout.
    ///
    /// The consequence of a refusal is the one ``RoomEvent/broadcastInterrupted``
    /// already describes. The camera runs, the encoder works, the frames go into
    /// a namespace the relay never registered, and nothing else about the room's
    /// state looks wrong — so it is reported the same way rather than given a
    /// case of its own. The cause is almost always a token minted for a
    /// different tenant or room than the one being published under, which is why
    /// the namespace is named in the log.
    private func watchForRefusal(of announcement: any AnnouncementHandle) {
        Task { [weak self] in
            guard let refusal = await announcement.refusal else { return }
            await self?.reportAnnouncementRefused(announcement.namespace, refusal)
        }
    }

    private func reportAnnouncementRefused(_ namespace: TrackNamespace, _ error: MoqomError) async {
        if case .rejected(.revoked) = error {
            await stopPublishing(under: namespace)
            return
        }
        logger.error(.publish, "the relay refused this namespace", [
            LogField("namespace", .text(namespace.description)),
            LogField("error", .text(String(describing: error))),
        ])
        eventContinuation.yield(.broadcastInterrupted)
    }

    /// Stop what this device publishes under a namespace its grants no longer
    /// cover, and say so.
    ///
    /// The relay has already withdrawn the announcement and stopped asking for
    /// the media, so nobody is receiving any of it; what is left is a camera and
    /// a microphone running for nothing, with their indicators lit. Stopping
    /// them is not the SDK deciding something on the participant's behalf, as
    /// starting them would be: it is the hardware catching up with a decision
    /// the room has made. The session, the roster and playback are untouched.
    private func stopPublishing(under namespace: TrackNamespace) async {
        var stopped: MediaKind = []
        if let broadcast, broadcast.namespace == namespace {
            await stopBroadcast()
            stopped.insert(.video)
        }
        if let audio, audio.track.namespace == namespace {
            await stopAudio()
            stopped.insert(.audio)
        }
        if broadcast == nil, audio == nil {
            await catalogPublisher?.finish()
            catalogPublisher = nil
        }
        logger.info(.publish, "publishing stopped: this session's grants changed", [
            LogField("namespace", .text(namespace.description)),
            LogField("stopped", .number(stopped.rawValue)),
        ])
        eventContinuation.yield(.publishingRevoked(stopped))
    }

    /// The layout to put back as participants return after a reconnect.
    ///
    /// Held because the alternative is worse than it sounds: the roster is
    /// rebuilt from announcements, which drops the planner's boxes with it, and
    /// an application that does not happen to run a layout pass after
    /// reconnecting would come back to a room with audio and no video. Cleared by
    /// the next ``updateLayout(_:linkBitrate:)``, so an application that *does*
    /// lay out again wins.
    private var layoutToRestore: [ParticipantIdentity: RenderBox] = [:]
    private var layoutRestore: Task<Void, Never>?

    private func scheduleLayoutRestore() {
        layoutRestore?.cancel()
        layoutRestore = Task { [weak self] in
            await self?.restoreLayout()
        }
    }

    private func restoreLayout() async {
        let returning = layoutToRestore.filter { state.roster[$0.key] != nil }
        guard !returning.isEmpty else { return }

        // Merged over what is already being drawn rather than stated on its own,
        // because ``SubscriptionPlanner/plan(boxes:order:linkBitrate:)`` takes the
        // whole layout: restoring one returning participant by itself would assert
        // a layout in which nobody else has a box, and unsubscribe every tile that
        // was working. After a reconnect the live layout is empty — everything was
        // torn down together — so the merge changes nothing on that path.
        var boxes = planner.layout
        boxes.merge(returning) { _, restored in restored }

        // Applied, so they are no longer pending. Anyone still absent keeps their
        // entry and is restored by the arrival that brings them back.
        for identity in returning.keys { layoutToRestore.removeValue(forKey: identity) }

        await applyLayout(boxes, linkBitrate: nil)
    }

    func end() async {
        // Nobody is waiting for anybody once the room is over, and a held seat
        // is a live task with a `weak self` that would otherwise sit out its
        // grace period before discovering there is nothing left to report to.
        for timer in held.values { timer.cancel() }
        held.removeAll()

        // The direct sessions, and the ticket subscriptions the relay meters
        // them by, end with the room.
        #if canImport(Network)
            directTicker?.cancel()
            directTicker = nil
            if let controller = directPathsController {
                directPathsController = nil
                await controller.stop()
            }
        #endif
        for tasks in directAttaches.values { for task in tasks { task.cancel() } }
        directAttaches.removeAll()

        rosterTask?.cancel()
        rosterTask = nil
        for task in prefixTasks { task.cancel() }
        prefixTasks.removeAll()
        speechTask?.cancel()
        speechTask = nil
        controlTask?.cancel()
        controlTask = nil
        controlSubscription = nil
        controlRepair?.cancel()
        controlRepair = nil
        await authority?.finish()
        authority = nil
        await space?.stop()
        space = nil
        spacePlan = nil
        waiting.removeAll()
        layoutRestore?.cancel()
        layoutRestore = nil
        layoutToRestore.removeAll()
        await broadcast?.stop()
        broadcast = nil
        await audio?.stop()
        audio = nil
        await managedKeys?.stop()
        managedKeys = nil
        await audioAnnouncement?.withdraw()
        audioAnnouncement = nil
        catalogRefresh?.cancel()
        catalogRefresh = nil
        catalogReshapes?.cancel()
        catalogReshapes = nil
        catalogStalls?.cancel()
        catalogStalls = nil
        await catalogPublisher?.finish()
        catalogPublisher = nil
        catalogs.removeAll()
        for task in catalogTasks.values { task.cancel() }
        catalogTasks.removeAll()
        for pump in pumps.values { pump.cancel() }
        pumps.removeAll()
        for task in catchUps.values { task.cancel() }
        catchUps.removeAll()
        for task in replayTasks.values { task.cancel() }
        replayTasks.removeAll()
        replayDepacketisers.removeAll()
        for sink in media.values { sink.finish() }
        media.removeAll()
        depacketisers.removeAll()
        for pipes in videoTaps.values {
            for pipe in pipes { await pipe.close() }
        }
        videoTaps.removeAll()
        for pipes in audioTaps.values {
            for pipe in pipes { pipe.tap.stop() }
        }
        audioTaps.removeAll()
        subscribedLayers.removeAll()
        for pump in audioPumps.values { pump.cancel() }
        audioPumps.removeAll()
        for who in Array(audioSubscriptions.keys) { await cancelAudio(who) }
        for sink in audioSinks.values { sink.continuation.finish() }
        audioSinks.removeAll()
        receivers.removeAll()
        for who in Array(subscriptions.keys) { await cancelVideo(who) }
        directSessions.removeAll()
        directStates.removeAll()
        eventContinuation.finish()
    }

    // MARK: - Publishing

    /// The namespace this device publishes under.
    ///
    /// A personal channel uses the caller's own `(tenant, "u", …)` slot, even
    /// when the session is watching someone else — that is how a guest uploads
    /// once and the host's catalog points at them. A room uses the participant
    /// slot under the room prefix, or backstage when they have not gone live.
    private func slotNamespace(backstage: Bool) throws(NameError) -> TrackNamespace {
        if backstage {
            return try MoqomNamespaces.backstageParticipant(
                tenant: tenant, room: room, identity: identity
            )
        }
        if channel != nil {
            return try MoqomNamespaces.personal(tenant: tenant, identity: identity)
        }
        return try MoqomNamespaces.participant(
            tenant: tenant, room: room, identity: identity
        )
    }

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

        // Before the announcement, so a refusal leaves no roster entry behind
        // for a participant who is not going to send anything.
        try requireEncryptionIfPolicyDemands()

        let publishNamespace: TrackNamespace
        do {
            publishNamespace = try slotNamespace(backstage: backstage)
        } catch {
            throw MoqomError.invalidName(error)
        }

        let announcement = try await connection.announce(publishNamespace)
        watchForRefusal(of: announcement)

        var writers: [LayerID: any TrackWriter] = [:]
        var encoders: [LayerID: any FrameEncoder] = [:]
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
            writers[rung.id] = try await protectedWriter(for: track, priority: priority)
            do {
                encoders[rung.id] = try await configuration.encoderFactory(
                    EncoderConfiguration(
                        layer: rung,
                        codec: configuration.codec,
                        prefersPowerEfficiency: configuration.prefersPowerEfficiency
                    )
                )
            } catch let error as MoqomError {
                throw error
            } catch {
                // A factory an integrator supplied can throw anything.
                throw MoqomError.unsupportedCodec(configuration.codec)
            }
        }

        let live = Broadcast(
            namespace: publishNamespace,
            configuration: configuration,
            source: source,
            announcement: announcement,
            writers: writers,
            encoders: encoders
        )
        broadcast = live

        // A camera started while its owner is force-muted comes up closed.
        // Somebody muted before they went live and then pressing the camera
        // button is the ordinary case, not an exotic one, and a publication
        // that ignored the standing restriction would light the indicator for
        // media the relay is not carrying.
        if enforced.mutedForEveryone.union(freed).contains(.video) {
            await live.setCaptureRestricted(true)
        }

        // Published before the first frame. A viewer that receives media for a
        // track the catalog does not mention cannot build a decoder for it, and
        // the failure looks like a codec problem rather than an ordering one.
        try await publishCatalog(under: publishNamespace)

        await live.start()

        // A publication whose source changes shape republishes the catalog, so a
        // newcomer's first sight of the stream is the size it is now. Everyone
        // already watching learns it from the keyframe that changed it and does
        // not need this; the catalog is the joiner's path, not the switch's.
        catalogReshapes?.cancel()
        let reshapes = live.reshapes
        catalogReshapes = Task { [weak self] in
            for await _ in reshapes {
                await self?.refreshCatalog()
            }
        }

        // The other thing a publication can do that the room has to be told
        // about: stop producing anything, because the phone's own system took
        // the camera away. See ``Catalog/interrupted``.
        catalogStalls?.cancel()
        let stalls = live.captureStalls
        catalogStalls = Task { [weak self] in
            for await stalled in stalls {
                await self?.reportCapture(stalled: stalled)
            }
        }

        // Republished once the encoders have produced parameter sets, which
        // cannot happen until something has been encoded.
        catalogRefresh?.cancel()
        catalogRefresh = Task { [weak self] in
            // Bounded rather than open-ended. If a rung has produced nothing
            // after five seconds it is not going to, and a viewer is better
            // served by a catalog missing one configuration than by a publisher
            // that never stops polling its own encoders.
            for _ in 0 ..< 20 {
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { return }
                guard let self, await self.refreshCatalog() else { continue }
                return
            }
        }

        return live
    }

    /// The catalog this session is publishing.
    public var publishedCatalog: Catalog? {
        get async { await catalogPublisher?.published }
    }

    /// Bring the catalog up to date with what the encoders now know.
    ///
    /// - Returns: Whether the catalog is now complete, meaning every video rung
    ///   has a decoder configuration.
    @discardableResult
    private func refreshCatalog() async -> Bool {
        guard let publisher = catalogPublisher else { return true }

        // An audio-only publisher has no broadcast and still needs a catalog,
        // because the catalog is how a viewer finds out they have an audio track
        // at all. Describing an empty ladder is the honest answer: they are
        // publishing, and none of it is video.
        let configurations = await broadcast?.decoderConfigurations ?? [:]
        let configuration = broadcast?.configuration
            ?? BroadcastConfiguration(ladder: LayerLadder(rungs: []))

        // The shape the broadcast is publishing rather than the one it was built
        // with. They part company the moment the source changes aspect, and a
        // catalog that still advertised the old dimensions would have every
        // newcomer lay out a tile for a picture that is no longer that size.
        let ladder = await broadcast?.currentLadder ?? configuration.ladder
        let catalog = Catalog.describing(
            configuration,
            ladder: ladder,
            decoderConfigurations: configurations,
            audio: audio?.configuration,
            keyID: encryption?.sender.key?.keyID,
            muted: ownMute,
            interrupted: ownInterruption,
            locale: ownLocale,
            references: ownReferences,
            invitations: ownInvitations.filter(\.isOpen),
            direct: direct != nil
        )
        _ = try? await publisher.publish(catalog)
        return configurations.count >= ladder.rungs.count
    }

    /// Say the catalog again, a few times, over the couple of seconds after somebody arrives.
    ///
    /// Once is not enough, and the reason is a race that cannot be won from this side. A
    /// newcomer's announcement and their subscription to this device's catalog are separate
    /// messages travelling separately; the announcement is what wakes this code, and by
    /// construction it can arrive before the relay has finished setting up the upstream pull
    /// that the subscription requires. A catalog written in that window is written to nobody
    /// and the tile stays black for the rest of the call.
    ///
    /// Repeating it turns a race into a delay: whichever attempt is the first to land after
    /// the pull exists is the one that gets through, and the others cost a few hundred bytes
    /// each. Spread rather than evenly spaced, because the common case is that the first
    /// attempt already works and the later ones are insurance against a slow relay.
    ///
    /// The honest fix is retention — a publisher that can answer a subscription for its latest
    /// group from a held copy, which is what `start: .latestGroup` promises the subscriber and
    /// what nothing currently keeps. This is the version that works against a relay that
    /// forwards without caching.
    private func restateCatalog() {
        catalogRestatement?.cancel()
        catalogRestatement = Task { [weak self] in
            for delay in [Duration.zero, .milliseconds(250), .milliseconds(1000), .seconds(3)] {
                if delay > .zero {
                    do { try await Task.sleep(for: delay) } catch { return }
                }
                guard let self, !Task.isCancelled else { return }

                // Refreshed first in case something has genuinely changed since the last
                // version — a rung that has produced its parameter sets, a mute — and then
                // restated, because a refresh that finds nothing new sends nothing at all and
                // sending is the entire point here.
                await refreshCatalog()
                _ = try? await catalogPublisher?.restate()
            }
        }
    }

    private func publishCatalog(under namespace: TrackNamespace) async throws(MoqomError) {
        guard catalogPublisher == nil else {
            await refreshCatalog()
            return
        }
        let name: FullTrackName
        do {
            name = try FullTrackName(namespace: namespace, name: TrackName(Catalog.trackName))
        } catch {
            throw MoqomError.invalidName(error)
        }

        // Sealed like the media it describes. What the relay needs — names,
        // kinds, geometry, locale — rides beside it as the catalog's disclosure,
        // authenticated by the same tag.
        try requireEncryptionIfPolicyDemands()
        let relay = try await connection.publish(name, priority: CatalogPublisher.priority)
        let writer: any TrackWriter = if let encryption {
            ProtectedTrackWriter(wrapping: relay, sender: encryption.sender)
        } else {
            relay
        }
        let publisher = CatalogPublisher(writer: writer)
        catalogPublisher = publisher
        await refreshCatalog()
    }

    public func stopBroadcast() async {
        catalogRefresh?.cancel()
        catalogRefresh = nil
        catalogReshapes?.cancel()
        catalogReshapes = nil
        catalogStalls?.cancel()
        catalogStalls = nil
        catalogRestatement?.cancel()
        catalogRestatement = nil
        await broadcast?.stop()
        broadcast = nil

        // Cleared with the publication that observed it. Someone who stops
        // broadcasting while their camera happens to be taken is not
        // interrupted, they have stopped, and leaving the flag set would caption
        // their absence with the last thing that went wrong before it.
        ownInterruption = []
        if var participant = state.roster[identity] {
            participant.mute.interrupted = []
            state.roster[identity] = participant
        }

        await catalogPublisher?.finish()
        catalogPublisher = nil
    }

    /// Start publishing audio.
    ///
    /// Separate from ``startBroadcast(from:configuration:backstage:)`` because
    /// the two are separate permissions and separate acts. Someone who joins to
    /// talk should not have to start a camera, and a stream that keeps talking
    /// after the video stops is normal rather than exceptional.
    @discardableResult
    public func startAudio(
        from source: any AudioSource,
        configuration: AudioPublicationConfiguration = AudioPublicationConfiguration(),
        backstage: Bool = false
    ) async throws(MoqomError) -> AudioPublication {
        if let audio { return audio }

        try requireEncryptionIfPolicyDemands()

        let publishNamespace: TrackNamespace
        let name: FullTrackName
        do {
            publishNamespace = try slotNamespace(backstage: backstage)
            name = try FullTrackName(namespace: publishNamespace, name: TrackName("audio"))
        } catch {
            throw MoqomError.invalidName(error)
        }

        // Announced even when video already did: the announcement is per
        // namespace and withdrawing it is refcounted by the transport, so an
        // audio-only participant appears in the roster the same way.
        let announcement = try await connection.announce(publishNamespace)
        watchForRefusal(of: announcement)
        audioAnnouncement = announcement

        let writer = try await protectedWriter(for: name, priority: configuration.priority)

        let encoder: any AudioEncoder
        do {
            encoder = try await configuration.encoderFactory(configuration.encoder)
        } catch let error as MoqomError {
            throw error
        } catch {
            throw MoqomError.unsupportedAudioCodec(configuration.encoder.codec)
        }

        let publication = AudioPublication(
            track: name,
            configuration: configuration,
            source: source,
            encoder: encoder,
            writer: writer
        )
        audio = publication
        if enforced.mutedForEveryone.union(freed).contains(.audio) {
            await publication.setCaptureRestricted(true)
        }
        await publication.start()

        // The catalog, not just a refresh of one. An audio-only participant has
        // never started a broadcast, so nothing has created a publisher yet and
        // a refresh would have nowhere to go.
        try await publishCatalog(under: publishNamespace)
        return publication
    }

    public func stopAudio() async {
        await audio?.stop()
        audio = nil
        await audioAnnouncement?.withdraw()
        audioAnnouncement = nil
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
    /// - Parameter linkBitrate: What the link can carry. Defaults to the SDK's
    ///   own measurement, which is what an application should use — passing a
    ///   number here overrides a live estimate with a guess, and is for tests
    ///   and for integrators who genuinely know something we do not.
    /// Take whatever each publisher offers instead of choosing a rung.
    ///
    /// See ``LayerSelectionPolicy/followsPublisher``. For a call where every end runs the
    /// same layout and the sender already knows the size of the box its picture will land
    /// in — which is most two-party calls, and none of the nine-up grids this SDK's
    /// selection was written for.
    ///
    /// Layout reports are still worth making with this on: they set subscriber priority, so
    /// the relay still sheds the smallest tile first.
    public func setFollowsPublisher(_ follows: Bool) async {
        guard planner.followsPublisher != follows else { return }
        planner.followsPublisher = follows
        await applyLayout(planner.layout, linkBitrate: nil)
    }

    @discardableResult
    public func updateLayout(
        _ boxes: [ParticipantIdentity: RenderBox],
        linkBitrate: Int? = nil
    ) async -> [SubscriptionChange] {
        // The application has stated a layout, which supersedes anything a
        // reconnect was still trying to put back.
        layoutToRestore.removeAll()
        return await applyLayout(boxes, linkBitrate: linkBitrate)
    }

    @discardableResult
    private func applyLayout(
        _ boxes: [ParticipantIdentity: RenderBox],
        linkBitrate: Int?
    ) async -> [SubscriptionChange] {
        let budget = linkBitrate ?? estimator.estimate

        // Never this device. A tile showing yourself is a self view drawn from
        // the capture session, and an application that reports a box for it —
        // which is the natural thing to do, since it is a tile like any other —
        // would otherwise pay to download its own upload, complete with the round
        // trip and the compression artefacts. The audio path has always guarded
        // this; the video path did not, and the symptom is a bandwidth bill
        // rather than anything visible on screen.
        let remote = boxes.filter { $0.key != identity }
        let changes = planner.plan(boxes: remote, order: gallery.order, linkBitrate: budget)
        for change in changes {
            // At `debug` rather than `info`: a room where the layout is animating
            // produces one of these per participant per frame of the animation,
            // and drowning a field report is as bad as having no log at all.
            logger.debug(.subscribe, "subscription change", change.fields + [
                LogField("budget_bps", .number(budget)),
            ])
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

    // MARK: - Gallery

    /// Who to draw, in what order, bounded by how many tiles the layout has.
    ///
    /// Kept here rather than left to the application because the two things it
    /// needs are both here: who is speaking, which only the audio path knows, and
    /// the subscription ranking, which has to agree with the layout or the relay
    /// sheds the wrong tile.
    public var galleryLayout: [Gallery.Slot] { gallery.slots }

    /// Everyone in the room without a tile, strongest claim first. They keep
    /// their audio.
    public var galleryOverflow: [ParticipantIdentity] { gallery.overflow }

    public var galleryPolicy: Gallery.Policy { gallery.policy }

    /// Set the tile count and the shape of the layout.
    ///
    /// Lower it under thermal pressure. Sixteen tiles is reachable because
    /// sixteen tiles are small enough for the bottom rung of the ladder, not
    /// because a phone can decode sixteen streams of anything larger.
    public func setGalleryPolicy(_ policy: Gallery.Policy) async {
        gallery.policy = policy
        await refreshGallery()
    }

    /// Guarantee a participant a tile, for this viewer only.
    public func pin(_ target: ParticipantIdentity) async {
        gallery.pin(target)
        await refreshGallery()
    }

    public func unpin(_ target: ParticipantIdentity) async {
        gallery.unpin(target)
        await refreshGallery()
    }

    /// Whether this participant is talking right now.
    ///
    /// Worked out on this device from the voice-activity flag their packets
    /// carry, which is why it still works when the media is end-to-end encrypted
    /// and the relay cannot see any of it.
    public func isSpeaking(_ target: ParticipantIdentity) -> Bool {
        speakers.isSpeaking(target)
    }

    // MARK: - Picture in Picture

    /// Who the Picture in Picture window draws.
    ///
    /// Setting this starts maintaining the window's occupancy; it does not
    /// start the window, which is ``MoqomPictureInPicture``'s job and needs a
    /// view hierarchy this actor does not have.
    public func setPictureInPictureCast(_ cast: PictureInPictureCast) async {
        if pictureInPicture == nil {
            pictureInPicture = PictureInPictureStage(cast: cast, viewer: identity)
        } else {
            pictureInPicture?.cast = cast
        }
        await refreshPictureInPicture()
    }

    /// Stop maintaining the window's occupancy.
    public func clearPictureInPictureCast() {
        pictureInPicture = nil
        pictureInPictureContinuation?.finish()
        pictureInPictureContinuation = nil
    }

    /// The window's occupancy, as it changes.
    ///
    /// A stream of its own rather than a case on ``events`` for the controller
    /// to watch, because an `AsyncStream` has one consumer: a controller
    /// reading ``events`` would take events the application never sees, and the
    /// symptom — a roster that updates only half the time — points nowhere near
    /// Picture in Picture. Applications that want to draw their own thing still
    /// get ``RoomEvent/pictureInPictureChanged(_:)`` on ``events``.
    ///
    /// Calling this a second time replaces the first stream. There is one
    /// window.
    public func pictureInPictureUpdates() -> AsyncStream<[Gallery.Slot]> {
        pictureInPictureContinuation?.finish()
        let (stream, continuation) = AsyncStream.makeStream(
            of: [Gallery.Slot].self,
            bufferingPolicy: .bufferingNewest(1)
        )
        pictureInPictureContinuation = continuation
        continuation.yield(pictureInPicture?.slots ?? [])
        return stream
    }

    public var pictureInPictureCast: PictureInPictureCast? { pictureInPicture?.cast }

    /// Who the window is drawing, in order.
    public var pictureInPictureSlots: [Gallery.Slot] { pictureInPicture?.slots ?? [] }

    private func refreshPictureInPicture(at now: MonotonicTime? = nil) async {
        guard pictureInPicture != nil else { return }
        let instant = now ?? .nanoseconds(DispatchTime.now().uptimeNanoseconds)
        guard pictureInPicture?.update(state, speakers: speakers, at: instant) == true else {
            return
        }
        let slots = pictureInPicture?.slots ?? []
        pictureInPictureContinuation?.yield(slots)
        eventContinuation.yield(.pictureInPictureChanged(slots))
    }

    /// Recompute the gallery, and re-rank subscriptions if it moved.
    private func refreshGallery(at now: MonotonicTime? = nil) async {
        let instant = now ?? .nanoseconds(DispatchTime.now().uptimeNanoseconds)

        // Unconditionally, and before the early return below. The window's
        // occupancy can move when the grid's does not — a speaker-following
        // cast changes on speech that leaves a nine-up grid untouched — so
        // making it a consequence of the grid changing would leave the window
        // showing whoever was talking a minute ago.
        await refreshPictureInPicture(at: instant)

        guard gallery.update(state.roster, speakers: speakers, at: instant) else { return }

        eventContinuation.yield(.galleryChanged(gallery.slots))

        // Against the layout the application last stated, because the tiles are
        // still the size they were: what changed is which participant is in which
        // one, and therefore which subscription the relay should shed last.
        await applyLayout(planner.layout, linkBitrate: nil)
    }

    private func scheduleSpeechExpiry() {
        guard speechTask == nil, !speakers.speaking.isEmpty else { return }
        speechTask = Task { [weak self] in
            while true {
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, !Task.isCancelled else { return }
                guard await self.expireSpeech() else { return }
            }
        }
    }

    /// - Returns: Whether anybody is still speaking, and so whether to tick again.
    private func expireSpeech() async -> Bool {
        let now = MonotonicTime.nanoseconds(DispatchTime.now().uptimeNanoseconds)
        if !speakers.refresh(at: now).isEmpty {
            await refreshGallery(at: now)
        }
        guard !speakers.speaking.isEmpty else {
            speechTask = nil
            return false
        }
        return true
    }

    /// Silence one participant for this viewer alone.
    ///
    /// Deliberately not `async throws` against the network: this is an
    /// unsubscribe and a local state change. Nobody else is affected and the
    /// server need not know.
    public func localMute(_ target: ParticipantIdentity, _ kinds: MediaKind) async {
        guard var participant = state.roster[target] else { return }
        participant.mute.localToMe.formUnion(kinds)
        state.roster[target] = participant

        // The unsubscribe that makes this a bandwidth saving rather than a
        // client-side discard. It is the one thing here that touches the
        // transport, and it asks nobody's permission.
        if kinds.contains(.audio) {
            await stopAudioSubscription(for: target)
        }
        eventContinuation.yield(.muteChanged(target, participant.mute))
    }

    public func localUnmute(_ target: ParticipantIdentity, _ kinds: MediaKind) async {
        guard var participant = state.roster[target] else { return }
        participant.mute.localToMe.subtract(kinds)
        state.roster[target] = participant

        if kinds.contains(.audio), let catalog = await catalogs[target]?.current {
            await followAudio(of: target, in: catalog)
        }
        eventContinuation.yield(.muteChanged(target, participant.mute))
    }

    // MARK: - Stage handshake

    /// Invite someone onto this channel.
    ///
    /// Lands on the catalog, not the control log. The invitee must be watching
    /// this catalog to see it. Accepting grants publish rights and starts
    /// nothing — they still have to go live.
    @discardableResult
    public func invite(
        _ username: Username,
        offered: PublishScope = .camera,
        expiresAfter: Duration = .seconds(30)
    ) async throws(MoqomError) -> StageInvitationRecord {
        let subject = ParticipantIdentity(
            username: username,
            device: identity.device
        )
        let record = StageInvitationRecord(
            direction: .invitation,
            subject: subject,
            issuedBy: identity,
            offered: offered,
            expiresAt: Date().addingTimeInterval(Double(expiresAfter.components.seconds))
        )
        ownInvitations.removeAll { $0.subject.username == username && $0.isOpen }
        ownInvitations.append(record)
        try await publishStageCatalog()
        if let prefix = try? MoqomNamespaces.personalPrefix(tenant: tenant, username: username) {
            watchPrefix(prefix)
        }
        adoptInvitations(ownInvitations, from: identity)
        logger.info(.room, "invited", [LogField("username", .text(username.value))])
        return record
    }

    /// Ask to come up on the channel this session is watching.
    ///
    /// Written on *this* device's catalog, so the host sees it only after they
    /// follow this namespace — which they do the moment they invite, and which
    /// a two-way watch does from the start.
    @discardableResult
    public func requestStage(
        offered: PublishScope = .camera,
        expiresAfter: Duration = .seconds(30)
    ) async throws(MoqomError) -> StageInvitationRecord {
        let record = StageInvitationRecord(
            direction: .request,
            subject: identity,
            issuedBy: identity,
            offered: offered,
            expiresAt: Date().addingTimeInterval(Double(expiresAfter.components.seconds))
        )
        ownInvitations.removeAll { $0.direction == .request && $0.isOpen }
        ownInvitations.append(record)
        try await publishStageCatalog()
        adoptInvitations(ownInvitations, from: identity)
        return record
    }

    /// Accept a pending invitation. Does not start a camera.
    public func accept(_ id: UUID) async throws(MoqomError) {
        try await resolve(id, to: .accepted)
    }

    public func decline(_ id: UUID) async throws(MoqomError) {
        try await resolve(id, to: .declined)
    }

    public func cancel(_ id: UUID) async throws(MoqomError) {
        try await resolve(id, to: .cancelled)
    }

    private func resolve(_ id: UUID, to outcome: StageOutcome) async throws(MoqomError) {
        if let index = ownInvitations.firstIndex(where: { $0.id == id && $0.isOpen }) {
            ownInvitations[index].outcome = outcome
        }
        if let index = state.stage.pending.firstIndex(where: { $0.id == id }) {
            var invitation = state.stage.pending[index]
            switch outcome {
            case .accepted: invitation.accept()
            case .declined: invitation.decline()
            case .cancelled: invitation.cancel()
            case .timedOut, .pending: break
            }
            state.stage.pending[index] = invitation
            eventContinuation.yield(.stageChanged(state.stage))
        }
        try await publishStageCatalog()
    }

    /// If we invited this person, their going live is the accept.
    private func linkIfInvited(_ who: ParticipantIdentity) async {
        guard let index = ownInvitations.firstIndex(where: {
            $0.subject.username == who.username && $0.isOpen
        }) else { return }
        ownInvitations[index].outcome = .accepted
        await link(who)
    }

    /// Point this catalog at `who`'s personal channel so viewers follow them.
    private func link(_ who: ParticipantIdentity) async {
        guard let namespace = try? MoqomNamespaces.personal(tenant: tenant, identity: who) else {
            return
        }
        guard !ownReferences.contains(namespace) else { return }
        ownReferences.append(namespace)
        await follow(namespace, hop: 0)
        _ = await refreshCatalog()
    }

    /// Publish a catalog so invitations exist even before anyone is on camera.
    private func publishStageCatalog() async throws(MoqomError) {
        if catalogPublisher != nil {
            _ = await refreshCatalog()
            return
        }
        let publishNamespace: TrackNamespace
        do {
            publishNamespace = try slotNamespace(backstage: false)
        } catch {
            throw MoqomError.invalidName(error)
        }
        if let announcement = try? await connection.announce(publishNamespace) {
            watchForRefusal(of: announcement)
        }
        try await publishCatalog(under: publishNamespace)
        _ = await refreshCatalog()
    }

    // MARK: - Muting yourself

    /// What this device has muted on itself.
    public var selfMuted: MediaKind { ownMute }

    /// The language this device is publishing, as a BCP 47 tag.
    public var locale: String? { ownLocale }

    /// Tell the room which language this device is speaking.
    ///
    /// ```swift
    /// await room.setLocale(SpokenLocale.current())   // follow the phone
    /// await room.setLocale("es-MX")                  // override
    /// await room.setLocale(nil)                      // stop claiming one
    /// ```
    ///
    /// The phone's own locale is the default, taken at join. Call this when
    /// that changes — `NSLocale.currentLocaleDidChangeNotification` — or when
    /// the application has an override of its own. Either may happen in the
    /// middle of a broadcast; the catalog is republished and everyone already
    /// subscribed reads the new tag, including the relay.
    ///
    /// `raw` is normalised to BCP 47 (`en_US` becomes `en-US`). A string that
    /// is not a language tag is ignored rather than published, so a typo in an
    /// override cannot take the catalog down.
    public func setLocale(_ raw: String?) async {
        let next = SpokenLocale.normalize(raw)
        guard ownLocale != next else { return }
        ownLocale = next

        if var participant = state.roster[identity] {
            participant.locale = next
            state.roster[identity] = participant
        }

        _ = await refreshCatalog()

        logger.info(.media, "locale changed", [
            LogField("locale", .text(next ?? "")),
        ])
        eventContinuation.yield(.localeChanged(identity, next))
    }

    /// Stop sending your own microphone or camera.
    ///
    /// ```swift
    /// await room.setSelfMuted(.audio)          // microphone off
    /// await room.setSelfMuted([])              // both back on
    /// await room.setSelfMuted([.audio, .video]) // and off again
    /// ```
    ///
    /// Three things happen, and all three are needed for the feature to be what
    /// a user believes it is.
    ///
    /// The bytes stop, at the encoder. Nothing muted is compressed and nothing
    /// is written, so this is a saving on the uplink rather than a filter
    /// applied at the far end — and, more to the point, it is a claim a packet
    /// capture can check.
    ///
    /// The publication stays up. The announcement stands, the tracks stay
    /// offered, and every subscriber keeps their subscription, so unmuting
    /// resumes on the next captured frame instead of renegotiating. That is why
    /// this is not ``stopBroadcast()`` with a nicer name: stopping takes the
    /// participant off the stage, and coming back from it is a rejoin.
    ///
    /// The room is told, on the catalog. Without that a viewer sees objects
    /// stop and cannot tell a muted microphone from a dead uplink, which are
    /// the same silence and want opposite interfaces — one draws a mute badge,
    /// the other draws a reconnecting spinner.
    ///
    /// Absolute rather than additive, deliberately. A toggle expressed as
    /// "add .audio" and "remove .audio" drifts out of step with the button that
    /// drives it as soon as anything else can mute — and something else always
    /// can, because a moderator can. Passing the whole set means the SDK's idea
    /// of what is muted and the interface's cannot disagree.
    ///
    /// > Note: This is what *this participant chose*. A moderator's mute is
    /// > ``MuteState/forcedForEveryone`` and is enforced at the relay; nothing
    /// > here can lift it, and unmuting yourself while force-muted changes this
    /// > flag and no behaviour.
    public func setSelfMuted(_ kinds: MediaKind) async {
        guard ownMute != kinds else { return }
        ownMute = kinds

        // Held here rather than only on the roster entry, because the roster
        // entry for this device is built from our own announcement coming back
        // round and may not exist yet. Muting before that lands is entirely
        // ordinary — it is what a "join muted" control does — and reading the
        // roster for it would make that case do nothing at all, silently.
        if var participant = state.roster[identity] {
            participant.mute.selfMuted = kinds
            state.roster[identity] = participant
        }

        await broadcast?.setMuted(kinds.contains(.video))
        await audio?.setMuted(kinds.contains(.audio))

        // After the media, so that a catalog claiming silence is never
        // published while packets are still in flight behind it.
        _ = await refreshCatalog()

        logger.info(.media, "self mute changed", [
            LogField("audio", .flag(kinds.contains(.audio))),
            LogField("video", .flag(kinds.contains(.video))),
        ])
        if let participant = state.roster[identity] {
            eventContinuation.yield(.muteChanged(identity, participant.mute))
        }
    }

    /// Say that this device's capture has stopped, or started again.
    ///
    /// The counterpart to ``setSelfMuted(_:)`` for the silences nobody chose,
    /// and it goes out by the same route: the catalog, which everyone already
    /// reads and which a late joiner reads on arrival. Driven by the
    /// publication noticing its own source has gone quiet — see
    /// ``Broadcast/captureStalls`` — rather than by the application, because an
    /// application that has to remember to report this is an application that
    /// will report it for the case it thought of and no other.
    ///
    /// The media is not touched. Nothing is muted, no group is restarted and no
    /// subscription changes: the frames stopped on their own, and they will
    /// resume on their own. All that happens here is that the room is told.
    private func reportCapture(stalled: Bool) async {
        let interrupted: MediaKind = stalled ? .video : []
        guard ownInterruption != interrupted else { return }
        ownInterruption = interrupted

        if var participant = state.roster[identity] {
            participant.mute.interrupted = interrupted
            state.roster[identity] = participant
        }

        _ = await refreshCatalog()

        logger.info(.media, stalled ? "capture interrupted" : "capture resumed", [])
        if let participant = state.roster[identity] {
            eventContinuation.yield(.muteChanged(identity, participant.mute))
        }
    }

    /// Mute these kinds in addition to whatever is already muted.
    public func muteSelf(_ kinds: MediaKind) async {
        await setSelfMuted(selfMuted.union(kinds))
    }

    /// Unmute these kinds, leaving anything else muted alone.
    public func unmuteSelf(_ kinds: MediaKind) async {
        await setSelfMuted(selfMuted.subtracting(kinds))
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
        await apply(action)

        // Published after the local effect and read back from state, so what the
        // room is told is the value this client actually holds rather than a
        // second derivation of it that could disagree.
        if let change = published(action) { await announce(change) }
    }

    /// What a moderation action becomes on the control log, once applied.
    ///
    /// `nil` for the bans, which are control-plane records rather than room
    /// state: what the room sees is the eviction that follows, and predicting it
    /// here would show somebody as gone on a ban the control plane went on to
    /// refuse.
    private func published(_ action: ModerationAction) -> RoomChange? {
        switch action {
        case let .kick(who):
            .evicted(who)
        case let .forceMute(who, _, _), let .unmute(who, _):
            state.roster[who].map {
                .mute(
                    who,
                    forEveryone: $0.mute.forcedForEveryone,
                    forAudience: $0.mute.forcedForAudience
                )
            }
        case let .demote(who, _):
            state.roster[who].map { .grants(who, $0.grants) }
        case .spotlight:
            .spotlight(state.stage.spotlighted)
        case .lockStage:
            .stage(StageSnapshot(state.stage))
        case let .closeRoom(event):
            .lifecycle(.ended(event))
        case .banFromRoom, .banFromTenant, .banDevice:
            nil
        }
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
        await announce(.watchdogs(state.watchdogs.all))
    }

    // MARK: - Measurement

    /// When this room was joined, for uptime.
    private let joinedAt = MonotonicTime.nanoseconds(DispatchTime.now().uptimeNanoseconds)

    /// The last quality reported for this device and for each participant.
    ///
    /// Held so that a change can be an event. Without it the only way an
    /// application learns a cohost's connection has degraded is by polling, and
    /// the indicator it draws would update at whatever rate it happened to
    /// choose rather than when the thing changed.
    private var reportedQuality: [ParticipantIdentity: ConnectionQuality] = [:]

    /// Everything measurable about the room, right now.
    ///
    /// One snapshot rather than a dozen accessors, taken at one instant. The
    /// instant matters: comparing an encoder's output rate against a link
    /// estimate is only meaningful if both were read together, and that
    /// comparison is most of what diagnosis consists of.
    public var statistics: RoomStatistics {
        get async { await sample() }
    }

    /// The same snapshot, repeatedly.
    ///
    /// For a diagnostics overlay, a periodic upload, or a support-ticket capture.
    /// Emitting quality changes as ``RoomEvent/qualityChanged(_:_:)`` is a side
    /// effect of sampling, so an application that consumes this stream also gets
    /// the events, and one that wants only the events can consume this and
    /// discard it.
    ///
    /// The stream ends when the room does. `interval` is clamped to something a
    /// device can sustain: this walks the roster and hops to three actors per
    /// sample, so a caller asking for a millisecond would be asking for the
    /// measurement to become the load.
    public func statistics(every interval: Duration) -> AsyncStream<RoomStatistics> {
        let period = max(interval, .milliseconds(100))
        return AsyncStream { continuation in
            let task = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { break }
                    let snapshot = await self.sample()
                    continuation.yield(snapshot)
                    if snapshot.lifecycle.isEnded { break }
                    try? await Task.sleep(for: period)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Gather one snapshot, and emit any quality change it reveals.
    private func sample() async -> RoomStatistics {
        let link = linkStatistics
        let publishing = PublishingStatistics(
            video: await broadcast?.stats,
            audio: await audio?.stats
        )

        let sampledAt = now()
        var participants: [ParticipantIdentity: ParticipantStatistics] = [:]
        for participant in state.roster.participants where participant.id != identity {
            let who = participant.id
            let video = videoStatistics(for: who)
            let audio = receivers[who]?.buffer.stats
            var stats = ParticipantStatistics(
                identity: who,
                presence: participant.presence,
                isSpeaking: speakers.isSpeaking(who),
                layer: subscribedLayers[who],
                video: video,
                audio: audio,
                silentFor: lastObject[who].map { sampledAt - $0 }
            )
            stats.quality = quality(for: stats, link: link)
            participants[who] = stats
        }

        // The local figure folds in encode drops, because a broadcaster whose
        // uplink is failing sees nothing wrong in any participant tile — every
        // one of those describes an inbound stream.
        let local = localQuality(link: link, publishing: publishing)

        let snapshot = RoomStatistics(
            capturedAt: now(),
            room: room,
            identity: identity,
            uptime: now() - joinedAt,
            lifecycle: state.lifecycle,
            participantCount: state.participantCount,
            link: link,
            publishing: publishing,
            participants: participants,
            decryption: await decryptionStatistics,
            control: ControlStatistics(
                sequence: log.applied,
                isFounded: log.isFounded,
                accepted: log.accepted,
                duplicates: log.duplicates,
                rejected: log.rejected,
                unrecognised: log.unrecognised,
                needsSnapshot: log.needsSnapshot,
                isTruncated: log.isTruncated,
                isAuthority: authority != nil
            ),
            quality: local
        )

        report(local, for: identity)
        for (who, stats) in participants {
            report(stats.quality, for: who)
        }
        return snapshot
    }

    /// How one participant's inbound stream is arriving.
    ///
    /// Their own audio loss is preferred over the room-wide link figure when
    /// there is any, because the link figure is an aggregate across every
    /// subscription: one cohost on a failing connection would otherwise drag
    /// every tile's indicator down with them, which points the viewer at their
    /// own network instead of at the person actually in trouble.
    private func quality(
        for stats: ParticipantStatistics,
        link: LinkStatistics
    ) -> ConnectionQuality {
        // Somebody who is not connected has no measurable stream, and reporting
        // `bad` for them would conflate "gone" with "struggling".
        guard stats.presence == .connected else { return .unknown }
        if let audio = stats.audio, audio.packetsReceived > 0 {
            return .from(link: link, loss: stats.audioLossRatio)
        }
        if let video = stats.video, video.framesProduced > 0 {
            let expected = video.framesProduced + video.objectsLost
            let loss = expected > 0 ? Double(video.objectsLost) / Double(expected) : 0
            return .from(link: link, loss: loss)
        }
        return .unknown
    }

    /// How this device's own connection looks.
    private func localQuality(
        link: LinkStatistics,
        publishing: PublishingStatistics
    ) -> ConnectionQuality {
        let downlink = ConnectionQuality.from(link: link)
        guard publishing.isPublishing else { return downlink }

        // Encode drops measured against the same thresholds as network loss: a
        // frame the device threw away and a frame the network lost look
        // identical to whoever was meant to see it.
        let uplink = ConnectionQuality.from(link: link, loss: publishing.encodeDropRatio)
        guard downlink != .unknown else { return uplink }
        guard uplink != .unknown else { return downlink }
        return min(downlink, uplink)
    }

    /// Emit a quality change, once, when it actually changes.
    private func report(_ quality: ConnectionQuality, for who: ParticipantIdentity) {
        guard reportedQuality[who] != quality else { return }
        reportedQuality[who] = quality
        logger.debug(
            .statistics,
            "connection quality changed",
            [
                LogField("participant", .participant(who)),
                LogField("quality", .text(quality.label)),
            ]
        )
        eventContinuation.yield(.qualityChanged(who, quality))
    }

    /// The monotonic clock, in one place.
    private nonisolated func now() -> MonotonicTime {
        .nanoseconds(DispatchTime.now().uptimeNanoseconds)
    }

    // MARK: - The control log

    /// What the room's authority has told this client, in order.
    private var log = RoomLog()

    /// What control entries must be signed by. See ``DeviceCredentials/authorityKeys``.
    private let authorityKeys: [DirectVerificationKey]

    /// Whether an unverifiable control entry has been reported, so a relay
    /// sending a stream of them produces one warning rather than a log flood.
    private var reportedUnsigned = false

    /// Control entries dropped because they did not verify.
    public private(set) var controlEntriesRefused = 0

    private var controlTask: Task<Void, Never>?
    private var controlSubscription: (any SubscriptionHandle)?
    private var controlRepair: Task<Void, Never>?

    /// The log position the last repair was attempted from.
    ///
    /// Without this a client behind a relay that cannot answer fetches issues one
    /// per arriving object forever, since the gap it is trying to close stays
    /// open. Retrying only once the log has moved bounds it to one attempt per
    /// gap.
    private var repairedAt: UInt64?

    /// Authority held over this room's log, when this session is the authority.
    private var authority: RoomLogPublisher?

    /// Control state for people whose announcement has not arrived, or who will
    /// never send one.
    ///
    /// A promotion is what *causes* somebody to start publishing, so grants
    /// routinely precede the announcement they apply to; and a moderator who
    /// publishes nothing never announces at all. Dropping what arrives early
    /// would mean a cohost whose permissions land a frame before they do appears
    /// as a viewer until the next snapshot.
    private var waiting: [ParticipantIdentity: ParticipantControl] = [:]

    /// Where this client is in the room's log. `0` when it has read none of it.
    ///
    /// Reset by a reconnect, along with the roster and everything else derived
    /// from a connection that no longer exists. The authority's numbering is not
    /// reset, so this climbing past where it was is the sign that a returning
    /// client has caught up rather than merely resubscribed.
    public var logPosition: UInt64 { log.applied }

    /// The authority this session holds over the room's log, if it has taken it.
    ///
    /// Worth reading rather than holding what ``assumeAuthority(signer:cadence:)``
    /// returned: a reconnect replaces the publisher, because its writer was a
    /// stream on a connection that is gone.
    public var roomAuthority: RoomLogPublisher? { authority }

    /// Whether the log has a hole in it that this client cannot close alone.
    public var isAwaitingSnapshot: Bool { log.needsSnapshot }

    /// Subscribe to the room's control track and follow it.
    ///
    /// At `.latestGroup`, which is what makes this work: every group on that
    /// track opens with a complete state, so subscribing delivers the room as it
    /// is now rather than the next thing to change about it. A client that
    /// waited for the next change would render an empty room until somebody was
    /// promoted.
    private func watchControl() {
        guard controlTask == nil else { return }
        guard
            let name = try? TrackName(RoomUpdate.trackName),
            let track = try? FullTrackName(namespace: namespace, name: name)
        else { return }

        controlTask = Task { [weak self] in
            guard let self else { return }
            guard
                let subscription = try? await self.connection.subscribe(
                    SubscribeRequest(
                        track: track,
                        priority: RoomLogPublisher.priority,
                        start: .latestGroup
                    )
                )
            else { return }
            await self.holdControl(subscription)
            for await object in subscription.objects {
                await self.receiveControl(object)
            }
        }
    }

    private func holdControl(_ subscription: any SubscriptionHandle) {
        controlSubscription = subscription
    }

    // MARK: - What the relay will not carry

    /// Follow the `.policy` track the relay pushes at this session.
    ///
    /// Nothing is subscribed to. A subscription is a request, and a participant
    /// being force-muted is by definition somebody who has not asked — the
    /// relay offers the track with a server-initiated PUBLISH, which is the one
    /// direction that reaches a client with nothing on its mind.
    ///
    /// Every offer is read rather than only the first. A second mute is a
    /// second PUBLISH, and a session that stopped after one would enforce the
    /// first restriction it was given for as long as it lasted.
    private func watchPolicy() {
        guard policyTask == nil else { return }
        let offers = connection.offers

        policyTask = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                for await offer in offers {
                    guard offer.track.name.value == ParticipantPolicy.trackName else { continue }
                    group.addTask { [weak self] in
                        for await object in offer.objects {
                            await self?.receivePolicy(object)
                        }
                    }
                }
            }
        }
    }

    private func receivePolicy(_ object: TrackObject) async {
        guard let policy = try? ParticipantPolicy.decode(object.payload) else {
            logger.warning(
                .control,
                "undecodable policy object",
                [LogField("payload", .redacted(bytes: object.payload.count))]
            )
            return
        }
        // A version this build does not understand is not an empty policy. The
        // relay is enforcing something either way, and reading a newer document
        // as "nothing is muted" would put the camera back on while the room
        // still cannot see it.
        guard policy.version == 1 else {
            logger.warning(.control, "unreadable policy version", [
                LogField("version", .number(policy.version)),
            ])
            return
        }
        await apply(policy)
    }

    /// Make this device's hardware agree with what the relay is enforcing.
    private func apply(_ policy: ParticipantPolicy) async {
        let was = enforced
        enforced = policy

        // Only the everyone-scope closes a device. An audience mute is still
        // being watched by the hosts, so stopping the camera for it would take
        // the participant off the screens of the people who muted them from
        // everyone else's.
        let held = policy.mutedForEveryone
        let lifted = was.mutedForEveryone.subtracting(held)

        // Held on to rather than acted on. A mute the relay has stopped
        // enforcing is permission to unmute, and turning a camera back on
        // because somebody else stopped objecting is exactly the surprise this
        // whole path exists to avoid — the device that was closed is opened by
        // the person sitting in front of it. See ``resumeAfterForceMute(_:)``.
        freed.formUnion(lifted)
        freed.subtract(held)

        if was.mutedForEveryone != held {
            // Everything the relay is holding down, and everything it has let
            // go of that this device has not been asked to reopen. A lift
            // therefore changes nothing about the hardware, which is the point.
            await restrictCapture(held.union(freed))
            logger.info(.media, "force mute changed", [
                LogField("audio", .flag(held.contains(.audio))),
                LogField("video", .flag(held.contains(.video))),
                LogField("resumable", .flag(!freed.isEmpty)),
            ])
        }

        if var participant = state.roster[identity] {
            participant.mute.forcedForEveryone = held
            participant.mute.forcedForAudience = policy.mutedForAudience
            state.roster[identity] = participant
            eventContinuation.yield(.muteChanged(identity, participant.mute))
        }
        eventContinuation.yield(.captureRestricted(held: held, resumable: freed))
    }

    /// Close or open this device's capture to match `closed`.
    private func restrictCapture(_ closed: MediaKind) async {
        await broadcast?.setCaptureRestricted(closed.contains(.video))
        await audio?.setCaptureRestricted(closed.contains(.audio))

        // Told to the room after the hardware, so a catalog claiming silence is
        // never published while packets are still in flight behind it.
        _ = await refreshCatalog()
    }

    /// What a moderator is holding down on this device right now.
    public var forceMuted: MediaKind { enforced.mutedForEveryone }

    /// What this device may turn back on, having been force-muted and released.
    ///
    /// Empty in the ordinary case. Non-empty means the relay would now carry
    /// this participant's media and their hardware is still off, which is a
    /// state an interface has to surface — otherwise a released participant
    /// sits in silence waiting for a camera nobody is going to start.
    public var resumableAfterForceMute: MediaKind { freed }

    /// Turn the camera or microphone back on after a force-mute was lifted.
    ///
    /// The only way capture comes back, and deliberately the only way. A lift
    /// arrives from the relay and a resume comes from the person: a server that
    /// could reopen a device would be a server that can open a device, which is
    /// a different feature and one nobody should ship by accident.
    ///
    /// Kinds still being enforced are ignored rather than refused. The relay is
    /// not carrying them, so opening the hardware would light an indicator for
    /// media that goes nowhere.
    @discardableResult
    public func resumeAfterForceMute(_ kinds: MediaKind = .all) async -> MediaKind {
        let resuming = freed.intersection(kinds).subtracting(enforced.mutedForEveryone)
        guard !resuming.isEmpty else { return [] }
        freed.subtract(resuming)

        if resuming.contains(.video) { await broadcast?.setCaptureRestricted(false) }
        if resuming.contains(.audio) { await audio?.setCaptureRestricted(false) }
        _ = await refreshCatalog()

        logger.info(.media, "capture resumed after a force mute", [
            LogField("audio", .flag(resuming.contains(.audio))),
            LogField("video", .flag(resuming.contains(.video))),
        ])
        eventContinuation.yield(
            .captureRestricted(held: enforced.mutedForEveryone, resumable: freed)
        )
        return resuming
    }

    private func receiveControl(_ object: TrackObject) async {
        guard RoomLogSignature.verifies(
            object.properties.authoritySignature,
            entry: object.payload,
            tenant: tenant,
            room: room,
            keys: authorityKeys
        ) else {
            controlEntriesRefused += 1
            if !reportedUnsigned {
                reportedUnsigned = true
                logger.warning(
                    .control,
                    authorityKeys.isEmpty
                        ? "ignoring the control log: no authority keys to verify it with"
                        : "dropping a control entry the room authority did not sign",
                    [LogField("payload", .redacted(bytes: object.payload.count))]
                )
            }
            return
        }
        guard let update = try? RoomUpdate.decode(object.payload) else {
            logger.warning(
                .control,
                "undecodable control entry",
                [LogField("payload", .redacted(bytes: object.payload.count))]
            )
            return
        }
        for body in log.accept(update) {
            await apply(body)
        }
        if log.needsSnapshot {
            // A reader that has never seen a snapshot also wants one, and that is
            // not a fault — it is the first moment of every room. Only a hole in
            // a log that had been whole is worth a warning, and that one is worth
            // it: until it heals, this client's idea of who may do what is stale,
            // which presents as a permissions bug rather than a network one.
            let fields = [
                LogField("applied", .number(Int(log.applied))),
                LogField("received", .number(Int(update.sequence))),
                LogField("holding", .number(log.holding)),
            ]
            if log.isFounded {
                logger.warning(.control, "control gap", fields)
            } else {
                logger.debug(.control, "awaiting first snapshot", fields)
            }
            repairControl()
        }
    }

    /// Fetch the group the control track is in the middle of.
    ///
    /// The whole repair, and it needs no mechanism of its own: that group opens
    /// with a snapshot, so one fetch returns a complete state plus everything
    /// published since. The objects it also re-delivers are ones this client has
    /// already applied, and the sequence numbers make re-reading them free.
    private func repairControl() {
        guard controlRepair == nil, repairedAt != log.applied else { return }
        guard let subscription = controlSubscription else { return }
        repairedAt = log.applied
        controlRepair = Task { [weak self] in
            guard let self else { return }
            defer { Task { await self.finishRepair() } }
            guard
                let fetch = try? await self.connection.fetch(
                    FetchRequest.catchUp(on: subscription, groups: 1)
                )
            else { return }
            for await record in fetch.records {
                guard case let .object(object) = record else { continue }
                await self.receiveControl(object)
            }
        }
    }

    private func finishRepair() {
        controlRepair = nil
    }

    /// Take authority over this room's log and start publishing it.
    ///
    /// For the party that owns the room's state — a relay, a control plane, or a
    /// self-hosted deployment's own service. A participant's token does not
    /// authorise publishing under the room's own prefix, so a client calling this
    /// against a real relay is refused; it is public because the log's shape is a
    /// protocol contract, and because a test has to be able to be the authority.
    @discardableResult
    public func assumeAuthority(
        signer: RoomLogSigner,
        cadence: RoomLogPublisher.Cadence = .default
    ) async throws(MoqomError) -> RoomLogPublisher {
        if let authority { return authority }
        let publisher = try await RoomLogPublisher.opening(
            room: room,
            tenant: tenant,
            on: connection,
            signer: signer,
            state: controlState,
            cadence: cadence
        )

        // Taking authority is an assertion about the room as it stands, so it
        // makes one immediately. Without it the track stays empty until somebody
        // is moderated, and a client that joins before then cannot tell an
        // authority with nothing to say from a room that has no authority.
        try await publisher.snapshot()
        authority = publisher
        return publisher
    }

    /// What this session would publish as a snapshot, drawn from live state.
    private var controlState: RoomSnapshot {
        RoomSnapshot(
            participants: state.roster.participants.map {
                ParticipantControl(
                    identity: $0.id,
                    grants: $0.grants,
                    presence: $0.presence,
                    mutedForEveryone: $0.mute.forcedForEveryone,
                    mutedForAudience: $0.mute.forcedForAudience
                )
            },
            stage: StageSnapshot(state.stage),
            lifecycle: state.lifecycle,
            watchdogs: state.watchdogs.all
        )
    }

    /// Publish a change, if this session is the authority. Otherwise nothing:
    /// a client that is not the authority has nowhere to put it, and pretending
    /// otherwise would make every moderation call fail on a viewer's device.
    private func announce(_ change: RoomChange) async {
        guard let authority else { return }
        _ = try? await authority.append(change)
    }

    private func apply(_ body: RoomUpdate.Body) async {
        switch body {
        case let .snapshot(snapshot):
            await adopt(snapshot)
        case let .change(change):
            await adopt(change)
        }
    }

    /// Replace everything the control track owns with a complete state.
    ///
    /// Participants the snapshot does not mention are reset rather than left as
    /// they were. A snapshot is the authority's complete account, so an omission
    /// is a statement — and the failure mode of the alternative is a grant that
    /// outlives its revocation because the entry carrying the revocation was the
    /// one that got lost.
    private func adopt(_ snapshot: RoomSnapshot) async {
        waiting = [:]
        for control in snapshot.participants where state.roster[control.identity] == nil {
            waiting[control.identity] = control
        }
        for participant in state.roster.participants {
            adopt(snapshot[participant.id] ?? ParticipantControl(identity: participant.id))
        }

        state.stage = snapshot.stage.applied(to: state.stage)
        mirrorSpotlight()
        state.watchdogs = WatchdogSet(snapshot.watchdogs, limit: state.watchdogs.limit)
        adopt(audiences: snapshot.audiences)

        eventContinuation.yield(.stageChanged(state.stage))
        eventContinuation.yield(.watchdogChanged(state.watchdogs))
        await adopt(lifecycle: snapshot.lifecycle)
        await refreshGallery()
    }

    /// Take new audience counts, and say so only if they actually moved.
    ///
    /// The authority republishes the whole set on every snapshot, so a room that
    /// nobody is joining or leaving would otherwise emit an event per group
    /// boundary forever, and every application watching would redraw for it.
    private func adopt(audiences: Audiences) {
        guard audiences != state.audiences else { return }
        state.audiences = audiences
        eventContinuation.yield(.audiencesChanged(audiences))
    }

    private func adopt(_ change: RoomChange) async {
        // Attributes for somebody the roster has never heard of. Kept rather than
        // dropped, and applied the moment they announce. Room-level changes fall
        // through, because a spotlight on a stranger is still a spotlight.
        if let subject = change.subject, change.isAttribute, state.roster[subject] == nil {
            var carrier = RoomSnapshot(
                participants: [waiting[subject] ?? ParticipantControl(identity: subject)]
            )
            carrier.apply(change)
            waiting[subject] = carrier[subject]
            return
        }

        switch change {
        case let .grants(who, grants):
            applyGrants(grants, to: who)
        case let .presence(who, presence):
            await publishPresence(presence, for: who)
        case let .mute(who, forEveryone, forAudience):
            guard var participant = state.roster[who] else { return }
            participant.mute.forcedForEveryone = forEveryone
            participant.mute.forcedForAudience = forAudience
            state.roster[who] = participant
            eventContinuation.yield(.muteChanged(who, participant.mute))
        case let .spotlight(who):
            state.stage.spotlighted = who
            mirrorSpotlight()
            eventContinuation.yield(.spotlightChanged(who))
            await refreshGallery()
        case let .stage(stage):
            state.stage = stage.applied(to: state.stage)
            mirrorSpotlight()
            eventContinuation.yield(.stageChanged(state.stage))
            await refreshGallery()
        case let .lifecycle(lifecycle):
            await adopt(lifecycle: lifecycle)
        case let .watchdogs(watchdogs):
            state.watchdogs = WatchdogSet(watchdogs, limit: state.watchdogs.limit)
            eventContinuation.yield(.watchdogChanged(state.watchdogs))
        case let .evicted(who):
            waiting.removeValue(forKey: who)
            if who == identity {
                // Being told, rather than watching the stream stop for no
                // reason. The transport may well be about to close; this arrives
                // first, which is the whole argument for carrying it as media.
                deliverTerminal(
                    .moderated(
                        .operatorAction,
                        display: "You were removed from this room."
                    )
                )
                return
            }
            await depart(who, reason: .evicted)
        case let .audiences(audiences):
            adopt(audiences: audiences)
        case let .unrecognised(kind):
            // Read past, counted, and logged once at debug. A newer authority is
            // entitled to publish something this build has no opinion about, and
            // the log's sequence has already advanced past it — so there is
            // nothing to repair and nothing a person should be warned about.
            logger.debug(
                .control,
                "control entry of an unknown kind",
                [LogField("kind", .text(kind))]
            )
        }
    }

    private func adopt(lifecycle: RoomLifecycle) async {
        guard !state.lifecycle.isEnded else { return }
        if case let .ended(event) = lifecycle {
            deliverTerminal(event)
            return
        }
        state.lifecycle = lifecycle
        eventContinuation.yield(.lifecycleChanged(lifecycle))
    }

    /// Apply attributes onto a roster member and report the change.
    private func adopt(_ control: ParticipantControl) {
        guard assign(control) else { return }
        eventContinuation.yield(.grantsChanged(control.identity, control.grants))
    }

    /// Apply attributes onto a roster member without reporting anything.
    ///
    /// - Returns: Whether anything changed.
    @discardableResult
    private func assign(_ control: ParticipantControl) -> Bool {
        guard var participant = state.roster[control.identity] else { return false }
        let changed = participant.grants != control.grants
            || participant.presence != control.presence
            || participant.mute.forcedForEveryone != control.mutedForEveryone
            || participant.mute.forcedForAudience != control.mutedForAudience
        guard changed else { return false }

        participant.grants = control.grants
        participant.presence = control.presence
        participant.mute.forcedForEveryone = control.mutedForEveryone
        participant.mute.forcedForAudience = control.mutedForAudience
        state.roster[control.identity] = participant
        planner.setLadder(
            participant.ladders[MediaKind.video.rawValue] ?? .defaultCamera(),
            for: control.identity,
            provisional: participant.ladders[MediaKind.video.rawValue] == nil
        )
        return true
    }

    /// Keep ``Participant/isSpotlighted`` in step with the stage.
    ///
    /// Two fields hold one fact, so everything that changes the stage comes
    /// through here — otherwise a spotlight moves the badge beside a name
    /// without moving the tile, or the reverse.
    private func mirrorSpotlight() {
        for participant in state.roster.participants {
            let wanted = participant.id == state.stage.spotlighted
            guard participant.isSpotlighted != wanted else { continue }
            state.roster[participant.id]?.isSpotlighted = wanted
        }
    }

    // MARK: - Room state

    func publishPresence(_ presence: Presence, for who: ParticipantIdentity) async {
        guard var participant = state.roster[who] else { return }
        guard participant.presence != presence else { return }
        participant.presence = presence
        state.roster[who] = participant
        eventContinuation.yield(.presenceChanged(who, presence))

        // A cohost who drops keeps their tile and becomes the first candidate to
        // lose it, which is the room persisting through a lift rather than
        // reflowing around a gap.
        await refreshGallery()
        await announce(.presence(who, presence))

        // Said outright, so there is nothing to wait for. This also covers the
        // order the other way round from ``vanish``: somebody whose seat is
        // already being held, who then turns out to have left deliberately,
        // should go now rather than serve out a window meant for an accident.
        if presence == .left, who != identity {
            await depart(who, reason: .left)
        }
    }

    func deliverTerminal(_ event: TerminalEvent) {
        state.lifecycle = .ended(event)
        logger.info(
            .room,
            "room ended",
            [
                LogField("room", .text(room.value)),
                LogField("reason", .text(event.reason.identifier)),
                LogField("uptime", .elapsed(now() - joinedAt)),
            ]
        )
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
            for: who,
            provisional: participant.ladders[MediaKind.video.rawValue] == nil
        )
        eventContinuation.yield(.grantsChanged(who, grants))
    }

    /// A namespace appeared or went away under the room prefix.
    ///
    /// The asymmetry here is the whole point. An announcement is proof somebody
    /// is there and is acted on at once; a withdrawal is only proof their
    /// session ended, which is a different and much weaker claim, so it starts
    /// a clock instead. See ``SeatPolicy``.
    private func applyAnnouncement(
        _ event: AnnouncementEvent,
        under prefix: TrackNamespace? = nil
    ) async {
        let prefix = prefix ?? namespace
        let slot = ParticipantSlot(announced: event.namespace, under: prefix)
            ?? ParticipantSlot(personal: event.namespace)
        guard let slot else {
            // A namespace this client does not model. The relay is entitled to
            // announce those and it is not an error to ignore them.
            return
        }

        switch event {
        case .announced:
            if held[slot.identity] != nil {
                await restore(slot.identity)
            } else {
                await admit(slot)
            }
        case let .withdrawn(_, reason):
            await vanish(slot.identity, reason: reason)
        }
    }

    /// Somebody who was never here before.
    private func admit(_ slot: ParticipantSlot) async {
        let before = Set(state.roster.participants.map(\.id))
        if state.roster[slot.identity] == nil {
            state.roster.insert(Participant(slot: slot))
        }
        let after = Set(state.roster.participants.map(\.id))

        for joined in after.subtracting(before) {
            if var participant = state.roster[joined] {
                // Our own entry arrives the same way everyone else's does, by
                // our announcement coming back round, and it arrives with an
                // empty mute. Restating what the user already chose keeps a
                // mute set before the roster caught up — or before a
                // reconnect — from appearing to have been undone.
                if joined == identity {
                    if participant.mute.selfMuted != ownMute {
                        participant.mute.selfMuted = ownMute
                    }
                    if participant.locale != ownLocale {
                        participant.locale = ownLocale
                    }
                    state.roster[joined] = participant
                }

                // A default until their catalog arrives, not a decision. It
                // exists so that layout can proceed in the milliseconds before
                // the catalog lands, and it is replaced rather than merged.
                planner.setLadder(.defaultCamera(), for: joined, provisional: true)

                // What the authority already said about them, which routinely
                // arrives first: a promotion is what causes somebody to start
                // publishing, so their grants can precede their announcement.
                // Before the joined event, so an application reading the roster
                // from it sees a cohost rather than a viewer that is about to
                // change.
                if let control = waiting.removeValue(forKey: joined) { assign(control) }
                if state.stage.spotlighted == joined {
                    state.roster[joined]?.isSpotlighted = true
                }

                eventContinuation.yield(.participantJoined(state.roster[joined] ?? participant))
                watchCatalog(of: participant)

                // Someone the outage took away has come back. Coalesced rather
                // than applied per arrival, because a reconnect brings the whole
                // room back at once and each plan would otherwise re-derive
                // priorities against a roster that is still filling.
                if layoutToRestore[joined] != nil { scheduleLayoutRestore() }

                // Say again what we are offering, because somebody arrived who has not heard
                // it. Their subscription asks for the latest group, which is the right
                // request, but a group only exists where something retained it: the catalog
                // is written once at go-live, and a relay that pulls upstream on demand was
                // not subscribed at the time. Nothing is holding a copy, so a subscription
                // opened afterwards begins at a live edge that stays silent until this
                // publisher happens to change something — a mute, a camera flip — which in a
                // call that has settled is never.
                //
                // It is why this failed by who arrived second rather than by anything about
                // the network: whoever subscribed before the other's catalog was written saw
                // video, and whoever subscribed after saw a black tile beside a roster entry
                // proving the participant was there. Two phones, one direction working, no
                // loss and no errors on either.
                //
                // Cheap enough to do unconditionally — a few hundred bytes against a joining
                // participant's first video keyframe.
                if joined != identity { restateCatalog() }
                await linkIfInvited(slot.identity)
            }
        }
        if before != after { await refreshGallery() }
    }

    /// Their session ended. Hold the seat and start the clock.
    private func vanish(_ who: ParticipantIdentity, reason: WithdrawalReason?) async {
        guard let participant = state.roster[who], held[who] == nil else { return }

        // They said they were going, one way or the other: on the control track
        // before leaving, or by closing the announcement, which the relay
        // reports as ``WithdrawalReason/stopped``. Either is a statement of
        // intent, and waiting for somebody who announced their departure is
        // waiting for nobody. A relay too old to say gets the patient reading.
        if participant.presence == .left || !reason.mayReturn {
            await depart(who, reason: .left)
            return
        }

        let grace = seatPolicy.grace(for: participant.role)
        guard grace > .zero else {
            await depart(who, reason: .timedOut)
            return
        }

        // The media plumbing goes now, even though the seat stays. Their tracks
        // are gone with the namespace, so every pump is about to fail on a
        // subscription to something nobody is publishing; keeping them would
        // buy nothing and burn a task each. What is kept is the roster entry
        // and the tile, which is what anyone watching actually notices.
        teardownMedia(for: who)

        state.roster[who]?.presence = .reconnecting
        eventContinuation.yield(.presenceChanged(who, .reconnecting))
        logger.info(
            .room,
            "participant vanished, holding their seat",
            [
                LogField("participant", .participant(who)),
                LogField("role", .text(participant.role.rawValue)),
                LogField("grace", .elapsed(grace)),
            ]
        )

        held[who] = Task { [weak self] in
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled else { return }
            await self?.depart(who, reason: .timedOut)
        }

        await refreshGallery()
    }

    /// They came back inside the window.
    private func restore(_ who: ParticipantIdentity) async {
        held.removeValue(forKey: who)?.cancel()
        guard state.roster[who] != nil else { return }

        state.roster[who]?.presence = .connected
        eventContinuation.yield(.presenceChanged(who, .connected))
        logger.info(
            .room,
            "participant returned",
            [LogField("participant", .participant(who))]
        )

        // Rebuilding what `vanish` tore down. Not a join: they never left the
        // roster, so nothing above has to re-add them, and emitting
        // `participantJoined` would tell an application to build a tile it
        // already has.
        planner.setLadder(
            state.roster[who]?.ladders[MediaKind.video.rawValue] ?? .defaultCamera(),
            for: who,
            provisional: state.roster[who]?.ladders[MediaKind.video.rawValue] == nil
        )
        if let participant = state.roster[who] { watchCatalog(of: participant) }
        if layoutToRestore[who] != nil { scheduleLayoutRestore() }

        await refreshGallery()
    }

    /// Out of the roster, for good.
    private func depart(_ who: ParticipantIdentity, reason: DepartureReason) async {
        held.removeValue(forKey: who)?.cancel()
        guard state.roster[who] != nil else { return }

        teardownMedia(for: who)
        state.roster.remove(who)

        // Otherwise a rejoin inherits the speech history of the session that
        // left, and jumps the queue for a tile on the strength of a sentence
        // finished before the reconnect.
        speakers.remove(who)
        waiting.removeValue(forKey: who)

        logger.info(
            .room,
            "participant left",
            [
                LogField("participant", .participant(who)),
                LogField("reason", .text(reason.rawValue)),
            ]
        )
        eventContinuation.yield(.participantLeft(who, reason))
        await refreshDirect()
        await refreshGallery()
    }

    /// Drop everything subscribed, pumped, or decoded on somebody's behalf.
    ///
    /// Shared by the seat-holding path and the departure path because the two
    /// want exactly the same teardown and differ only in whether the roster
    /// entry survives it.
    private func teardownMedia(for who: ParticipantIdentity) {
        // Otherwise somebody who vanishes and returns is reported as having been
        // silent for the whole outage, when what actually happened is that this
        // client was not subscribed to them for any of it.
        lastObject.removeValue(forKey: who)

        // Where they were being drawn, kept so that a return can put the
        // subscription back without waiting for a layout pass that may never
        // come. An application reports a box when one *changes*, and a tile torn
        // down and rebuilt at the same size changes nothing — so a participant
        // who leaves and comes back sits behind a roster entry, a catalog, and no
        // video, indefinitely, because every party to the decision believes it
        // has already been made. Read before `remove`, which is what discards it.
        if let box = planner.layout[who] { layoutToRestore[who] = box }

        planner.remove(who)
        subscriptions.removeValue(forKey: who)
        catalogTasks.removeValue(forKey: who)?.cancel()
        catalogs.removeValue(forKey: who)
        pumps.removeValue(forKey: who)?.cancel()
        catchUps.removeValue(forKey: who)?.cancel()
        media.removeValue(forKey: who)?.finish()
        depacketisers.removeValue(forKey: who)
        subscribedLayers.removeValue(forKey: who)
        audioPumps.removeValue(forKey: who)?.cancel()
        audioSubscriptions.removeValue(forKey: who)
        audioSinks.removeValue(forKey: who)?.continuation.finish()
        receivers.removeValue(forKey: who)

        // A merge also holds a direct subscription, which nothing else ends.
        directOptedIn.remove(who)
        directStates.removeValue(forKey: who)
        directCounters.removeValue(forKey: who)
        directSessions.removeValue(forKey: who)
        videoPriorities.removeValue(forKey: who)
        for task in directAttaches.removeValue(forKey: who) ?? [] { task.cancel() }
        let merged = [videoDuals.removeValue(forKey: who), audioDuals.removeValue(forKey: who)].compactMap { $0 }
        if !merged.isEmpty {
            Task { for subscription in merged { await subscription.cancel() } }
        }
    }

    /// Subscribe to a participant's catalog track and follow it.
    private func watchCatalog(of participant: Participant) {
        // Never this device. Announcing is what puts a participant in the roster,
        // and this device announces itself, so without this a publisher
        // subscribes to the catalog it is publishing — paying a subscription and
        // a round trip to be told what it just said. The same self-subscription
        // the video path guards against in `applyLayout`, on a track small enough
        // that nobody would notice it in a bandwidth graph.
        guard participant.id != identity else { return }
        guard catalogTasks[participant.id] == nil else { return }
        guard
            let name = try? TrackName(Catalog.trackName),
            let track = try? FullTrackName(namespace: participant.slot.namespace, name: name)
        else { return }

        let who = participant.id
        let request = SubscribeRequest(
            track: track,
            priority: CatalogPublisher.priority,
            // The current catalog, not the next one. Waiting for
            // the next version means waiting until the publisher
            // happens to change something, which may be never.
            start: .latestGroup
        )

        catalogTasks[who] = Task { [weak self] in
            await Self.follow(request, from: who, for: self)
        }
    }

    /// Stay subscribed to one participant's catalog until told to stop.
    ///
    /// A single attempt is not enough, and its failures were all silent. Subscribing can be
    /// refused outright — a race with the announcement, a session mid-reconnect — and it can
    /// also succeed and deliver nothing, which is what happens when the publisher wrote its
    /// only catalog group before this subscription reached the relay and nothing since has
    /// made it write another. Both end the same way: a participant who is in the roster, has a
    /// tile, has a layout box, and is never subscribed to, because the ladder that would say
    /// what to subscribe to never arrived. The tile stays black on a link carrying the other
    /// direction perfectly.
    ///
    /// So: retry a refused subscription, and treat a subscription that has said nothing for a
    /// few seconds as refused too. The publishing side restates its catalog when someone joins,
    /// which covers the common race from its end; this covers the same race from the end that
    /// can actually tell it went wrong, and covers the case where the restatement itself was
    /// lost. Once a catalog has arrived the wait no longer applies — a settled room may go
    /// minutes without a new one, and that is not a fault.
    private static func follow(
        _ request: SubscribeRequest,
        from who: ParticipantIdentity,
        for session: RoomSession?
    ) async {
        var attempt = 0
        while !Task.isCancelled {
            guard let session else { return }
            var subscription: (any SubscriptionHandle)?
            do throws(MoqomError) {
                subscription = try await session.connection.subscribe(request)
            } catch {
                session.logger.warning(.subscribe, "catalog subscription refused", [
                    LogField("participant", .participant(who)),
                    LogField("attempt", .text("\(attempt + 1)")),
                    LogField("error", .text(String(describing: error))),
                ])
            }

            if let subscription {
                var arrived = false
                let watchdog = Task {
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                    await subscription.cancel()
                }
                for await object in subscription.objects {
                    if !arrived {
                        arrived = true
                        watchdog.cancel()
                        attempt = 0
                    }
                    await session.applyCatalog(object, from: who)
                }
                watchdog.cancel()
                await subscription.cancel()
                if arrived {
                    // Ended after delivering, which is the publisher going away rather than a
                    // race. Their departure cancels this task; until it does, a slow retry
                    // costs nothing and covers a track that comes back.
                    session.logger.warning(.subscribe, "catalog stream ended", [
                        LogField("participant", .participant(who)),
                    ])
                }
            }

            attempt += 1
            guard attempt < 8 else {
                session.logger.error(.subscribe, "catalog never arrived", [
                    LogField("participant", .participant(who)),
                ])
                return
            }
            try? await Task.sleep(for: .milliseconds(250 * (1 << min(attempt, 4))))
        }
    }

    private func applyCatalog(_ object: TrackObject, from who: ParticipantIdentity) async {
        guard let object = await open(object, from: who) else { return }
        let reader = catalogs[who] ?? CatalogReader()
        catalogs[who] = reader
        guard let catalog = await reader.apply(object) else { return }

        // The ladder now comes from the publisher rather than from an
        // assumption. This is the difference between subscribing to the rungs
        // that exist and subscribing to the rungs we hoped for.
        let ladder = catalog.videoLadder
        if !ladder.isEmpty {
            planner.setLadder(ladder, for: who)

            // And then act on it, which is the half that was missing. Replacing the ladder
            // changes what every box means without changing any box, so nothing else here
            // will ever reconsider: the layout has already been reported, and the next pass
            // comes when something moves on screen, which in a two-person room is never.
            //
            // Until then the selection in force is the one made against the default ladder,
            // whose top rung is 1080p. A publisher offering less than that — anyone pinned
            // to a single rung, anyone whose camera caps lower — is subscribed at a rung
            // they do not publish, and the relay has nothing to send. The result is a tile
            // that stays black on a healthy connection, with the catalog on screen beside it
            // naming a resolution that is never requested.
            await applyLayout(planner.layout, linkBitrate: nil)
        }
        configureDepacketiser(for: who, from: catalog)

        // Before `followAudio`, which reads the effective mute to decide
        // whether to stay subscribed. Applied in the other order, a participant
        // muting themselves would be acted on one catalog late.
        adoptSelfMute(catalog.muted, of: who)
        adoptInterruption(catalog.interrupted, of: who)
        adoptLocale(catalog.locale, of: who)
        if catalog.direct {
            directOptedIn.insert(who)
        } else {
            directOptedIn.remove(who)
        }

        await followAudio(of: who, in: catalog)
        await followReferences(in: catalog, hop: 0)
        adoptInvitations(catalog.invitations, from: who)
        eventContinuation.yield(.catalogChanged(who, catalog))
    }

    /// Subscribe to every namespace this catalog points at, once, with a hop
    /// limit so A→B→C→A cannot chase its own tail on the client.
    ///
    /// Relay-side loop detection on the mesh is a separate problem; this is
    /// what stops one device from opening the same subscription forever.
    private func followReferences(in catalog: Catalog, hop: Int) async {
        guard hop < 3 else { return }
        for namespace in catalog.references {
            await follow(namespace, hop: hop + 1)
        }
    }

    private func follow(_ namespace: TrackNamespace, hop: Int) async {
        guard !followed.contains(namespace) else { return }
        followed.insert(namespace)
        if let slot = ParticipantSlot(personal: namespace)
            ?? ParticipantSlot(announced: namespace, under: self.namespace)
        {
            if state.roster[slot.identity] == nil {
                await admit(slot)
            }
        }
        if namespace.fields.count >= 3, namespace.fields[1] == "u",
           let username = try? Username(namespace.fields[2]),
           let prefix = try? MoqomNamespaces.personalPrefix(tenant: tenant, username: username)
        {
            watchPrefix(prefix)
        }
        // A catalog we already admitted will be pulled by watchCatalog; if the
        // slot was new, admit did that. If we already knew them, pull again
        // so a newly referenced publisher is not waiting on a restatement.
        if let slot = ParticipantSlot(personal: namespace),
           let participant = state.roster[slot.identity]
        {
            watchCatalog(of: participant)
        }
        _ = hop
    }

    /// Take pending invitations off a catalog this session is reading.
    private func adoptInvitations(_ records: [StageInvitationRecord], from who: ParticipantIdentity) {
        let open = records.filter(\.isOpen)
        guard !open.isEmpty || !state.stage.pending.isEmpty else { return }
        // Host-authored invitations replace the pending set for that host.
        // Requests from a guest land as themselves.
        let others = state.stage.pending.filter { $0.issuedBy != who }
        var next = others
        for record in open {
            next.append(
                StageInvitation(
                    id: record.id,
                    direction: record.direction,
                    subject: record.subject,
                    issuedBy: record.issuedBy,
                    offered: record.offered,
                    issuedAt: .zero,
                    expiresAfter: .seconds(max(1, record.expiresAt.timeIntervalSinceNow))
                )
            )
        }
        state.stage.pending = next
        eventContinuation.yield(.stageChanged(state.stage))
    }

    /// Take what a participant says their own hardware has stopped giving them.
    ///
    /// Trusted on the same terms as their mute, and with less at stake: a
    /// participant who lies about this makes their own tile say their camera
    /// was interrupted while they carry on publishing, which is a way of
    /// slandering nobody but themselves.
    private func adoptInterruption(_ interrupted: MediaKind, of who: ParticipantIdentity) {
        guard var participant = state.roster[who], participant.mute.interrupted != interrupted
        else { return }

        participant.mute.interrupted = interrupted
        state.roster[who] = participant
        eventContinuation.yield(.muteChanged(who, participant.mute))
    }

    /// Take a participant's own mute from the catalog they published.
    ///
    /// Trusted because it is theirs to state. The mute that does not rely on
    /// the publisher cooperating arrives on the control track from the
    /// authority and lands in ``MuteState/forcedForEveryone``; this one is the
    /// participant reporting a choice, in the same way they are trusted to
    /// report which rungs they are offering.
    private func adoptSelfMute(_ muted: MediaKind, of who: ParticipantIdentity) {
        guard var participant = state.roster[who], participant.mute.selfMuted != muted else {
            return
        }
        participant.mute.selfMuted = muted
        state.roster[who] = participant
        eventContinuation.yield(.muteChanged(who, participant.mute))
    }

    /// Take a participant's language from the catalog they published.
    ///
    /// Trusted on the same terms as their mute: it is theirs to state, and a
    /// lie about it slanders nobody but themselves. Normalised again here so a
    /// modified client that put something that is not a language tag on the
    /// wire does not land it on the roster.
    private func adoptLocale(_ locale: String?, of who: ParticipantIdentity) {
        let next = SpokenLocale.normalize(locale)
        guard var participant = state.roster[who], participant.locale != next else { return }
        participant.locale = next
        state.roster[who] = participant
        eventContinuation.yield(.localeChanged(who, next))
    }

    // MARK: - Audio

    /// Subscribe to a participant's audio, or stop, according to their catalog
    /// and this viewer's mute.
    private func followAudio(of who: ParticipantIdentity, in catalog: Catalog) async {
        guard who != identity else { return }

        guard
            let track = catalog.audioTrack,
            state.roster[who]?.mute.effective.contains(.audio) != true
        else {
            await stopAudioSubscription(for: who)
            return
        }

        var receiver = receivers[who] ?? AudioReceiver()
        receiver.setFormat(AudioFormat(track))
        receivers[who] = receiver

        guard audioSubscriptions[who] == nil else { return }
        let priority = AudioPublicationConfiguration().priority
        guard
            let participant = state.roster[who],
            let name = try? TrackName(track.name),
            let full = try? FullTrackName(namespace: participant.slot.namespace, name: name),
            let subscription = try? await connection.subscribe(
                SubscribeRequest(track: full, priority: priority)
            )
        else { return }

        audioSubscriptions[who] = subscription
        let merged = merging(subscription, priority: priority, from: who)
        audioDuals[who] = merged
        let sink = audioSinks[who] ?? AudioSink()
        audioSinks[who] = sink

        let objects = (merged ?? subscription).objects
        audioPumps[who] = Task { [weak self] in
            for await object in objects {
                guard let self else { return }
                await self.receiveAudio(object, from: who, into: sink)
            }
        }
    }

    private func receiveAudio(
        _ object: TrackObject,
        from who: ParticipantIdentity,
        into sink: AudioSink
    ) async {
        estimator.record(object, at: .nanoseconds(DispatchTime.now().uptimeNanoseconds))
        lastObject[who] = now()

        guard let plain = await open(object, from: who) else { return }

        let arrival = MonotonicTime.nanoseconds(DispatchTime.now().uptimeNanoseconds)

        // After decryption, and on this device. Every other stack measures speech
        // on the server, where it is unavailable the moment the media is
        // encrypted; here it is a flag the publisher already computed, on a track
        // this viewer is already subscribed to.
        let voiced = !(plain.properties.isSilence ?? false)
        if !speakers.heard(voiced: voiced, from: who, at: arrival).isEmpty {
            await refreshGallery(at: arrival)
            scheduleSpeechExpiry()
        }

        var receiver = receivers[who] ?? AudioReceiver()
        receiver.accept(plain, at: arrival)

        // Drained on arrival rather than on a timer. A real player pulls from
        // its own audio callback at exactly the device's rate, which is the
        // clock that matters; pulling here keeps the buffer from growing without
        // bound when nobody is playing, and hands a caller that is playing the
        // slots in order.
        var tapped: [JitterBufferOutput] = []
        while true {
            let output = receiver.next()
            if output == .buffering { break }
            sink.continuation.yield(output)
            if audioTaps[who]?.isEmpty == false { tapped.append(output) }
        }
        receivers[who] = receiver

        for output in tapped {
            await feedAudioTaps(output, from: who)
        }
    }

    /// Hand one decoded slot to whoever is listening for their own reasons.
    private func feedAudioTaps(_ output: JitterBufferOutput, from who: ParticipantIdentity) async {
        guard var pipes = audioTaps[who], !pipes.isEmpty else { return }

        pipes.removeAll { !$0.tap.isActive }
        guard !pipes.isEmpty else {
            audioTaps.removeValue(forKey: who)
            return
        }
        audioTaps[who] = pipes

        guard let track = await catalogs[who]?.current?.audioTrack else { return }
        let format = AudioFormat(track)
        let codec = track.audioCodec ?? .opus

        for pipe in pipes {
            guard
                let failure = await pipe.offer(output, format: format, codec: codec)
            else { continue }
            logger.error(
                .media,
                "audio tap cannot decode",
                [
                    LogField("participant", .participant(who)),
                    LogField("codec", .text(codec.rawValue)),
                    LogField("reason", .text(String(describing: failure))),
                ]
            )
        }
    }

    private func stopAudioSubscription(for who: ParticipantIdentity) async {
        await cancelAudio(who)
        receivers[who]?.reset()
        for pipe in audioTaps.removeValue(forKey: who) ?? [] {
            pipe.tap.stop()
        }
    }

    /// Hand the subscribed rung's parameter sets to reassembly.
    ///
    /// Called from both directions — a new subscription and a new catalog —
    /// because either can arrive first. A publisher's first catalog has no
    /// decoder configuration in it at all, since the encoders have produced
    /// nothing yet, so the version that carries one is usually the second.
    private func configureDepacketiser(for who: ParticipantIdentity, from catalog: Catalog?) {
        guard
            let catalog,
            let layer = subscribedLayers[who],
            let track = catalog.track(named: layer.value),
            let hex = track.decoderConfiguration,
            var depacketiser = depacketisers[who]
        else { return }
        depacketiser.setDecoderConfiguration(hexadecimal: hex)
        depacketisers[who] = depacketiser
    }

    /// The codec a participant's subscribed rung is encoded with, from their
    /// catalog. `nil` until the catalog arrives.
    public func codec(of who: ParticipantIdentity) async -> VideoCodec? {
        guard
            let layer = subscribedLayers[who],
            let catalog = await catalogs[who]?.current
        else { return nil }
        return catalog.track(named: layer.value)?.videoCodec
    }

    /// A participant's catalog, once it has arrived.
    ///
    /// For this device it is the catalog being published, which is known without
    /// a subscription — asking the relay to send back a description this session
    /// wrote would be a round trip to learn something it already knows.
    public func catalog(of who: ParticipantIdentity) async -> Catalog? {
        if who == identity { return await catalogPublisher?.current }
        return await catalogs[who]?.current
    }

    // MARK: - Measuring the link

    /// Read every object of a subscription: measure it, decrypt it, hand it on.
    private func startPump(_ subscription: any SubscriptionHandle, for who: ParticipantIdentity) {
        let sink = media[who] ?? MediaSink()
        media[who] = sink

        let objects = subscription.objects
        pumps[who] = Task { [weak self] in
            for await object in objects {
                guard let self else { return }
                await self.receive(object, from: who, into: sink)
            }
        }
    }

    /// Ask for the group the publisher is in the middle of.
    ///
    /// A subscription starts at the next group, so joining a broadcast means
    /// waiting for the next keyframe — up to a whole group interval of nothing.
    /// This closes that gap by fetching the group already in progress, which is
    /// the difference between a tile that fills immediately and one that is
    /// black for two seconds.
    ///
    /// Best-effort on purpose. A publisher or relay that keeps no history
    /// refuses the fetch, and the subscription still delivers from the next
    /// group: catch-up makes joining faster and is not what makes it work.
    private func catchUp(
        on subscription: any SubscriptionHandle,
        for who: ParticipantIdentity
    ) async {
        guard catchUpGroups > 0 else { return }
        guard let fetch = try? await connection.fetch(
            FetchRequest.catchUp(on: subscription, groups: catchUpGroups)
        ) else { return }

        let sink = media[who] ?? MediaSink()
        media[who] = sink

        catchUps[who]?.cancel()
        catchUps[who] = Task { [weak self] in
            for await record in fetch.records {
                guard let self else { return }
                await self.receive(record, from: who, into: sink)
            }
        }
    }

    /// How many groups of history to ask for when subscribing. `0` disables it.
    public private(set) var catchUpGroups: UInt64 = 1

    /// Change how much history a new subscription asks for.
    ///
    /// One group is the default because one group is what buys a keyframe.
    /// More is a seek rather than a join, and it competes with the live edge for
    /// the same downlink — so raising this trades a faster first frame for a
    /// worse first second.
    public func setCatchUpGroups(_ groups: UInt64) {
        catchUpGroups = groups
    }

    // MARK: - Replaying history

    /// Ask for the last `groups` groups of a participant's video, delivered
    /// separately from their live stream.
    ///
    /// This is the seek. ``frames(from:)`` is the live edge and only ever moves
    /// forward — catch-up feeds into it precisely because the objects it fetches
    /// are the ones immediately behind that edge — so replaying into it would
    /// interleave the past with the present and hand a renderer frames that jump
    /// backwards. What comes back here is its own stream, with its own
    /// reassembly, and consuming it does not disturb what is on screen.
    ///
    /// Requires a live subscription to the participant, because a joining fetch
    /// is resolved against one: the publisher counts back from where that
    /// subscription is rather than from a group number this client would have to
    /// guess. `nil` when there is no subscription, or when the range was refused.
    ///
    /// How far back this can reach is not ours to promise. A publisher retains a
    /// couple of groups by default and a relay retains what its cache holds, so
    /// asking for a hundred groups is not an error and will not get you a
    /// hundred groups.
    public func replay(
        of who: ParticipantIdentity,
        lastGroups groups: UInt64
    ) async -> AsyncStream<DepacketisedFrame>? {
        guard groups > 0, let subscription = subscriptions[who] else { return nil }
        return await replay(
            of: who,
            range: .joining(subscription: subscription, groups: groups)
        )
    }

    /// The same, from a group already seen rather than a distance back.
    ///
    /// For resuming: a client that knows which group it stopped at asks from
    /// there, and gets everything up to the live edge without having to work out
    /// how far away that is.
    public func replay(
        of who: ParticipantIdentity,
        fromGroup group: UInt64
    ) async -> AsyncStream<DepacketisedFrame>? {
        guard let subscription = subscriptions[who] else { return nil }
        return await replay(
            of: who,
            range: .joiningFrom(subscription: subscription, group: group)
        )
    }

    /// Reassembly state for replays in flight, keyed per replay.
    ///
    /// Per replay rather than per participant because two replays of the same
    /// participant are two independent walks through history, and sharing a
    /// depacketiser between them would have each one's gaps and keyframes
    /// interpreted against the other's position.
    private var replayDepacketisers: [UUID: VideoDepacketiser] = [:]
    private var replayTasks: [UUID: Task<Void, Never>] = [:]

    private func replay(
        of who: ParticipantIdentity,
        range: FetchRequest.Range
    ) async -> AsyncStream<DepacketisedFrame>? {
        guard let fetch = try? await connection.fetch(FetchRequest(range: range)) else {
            return nil
        }

        // Unbounded, unlike the live sinks. Dropping the oldest is right for a
        // live stream, where the newest picture is the one wanted; a replay is
        // read in order and dropping from the front would silently remove the
        // keyframe everything after it depends on.
        let (frames, continuation) = AsyncStream.makeStream(
            of: DepacketisedFrame.self,
            bufferingPolicy: .unbounded
        )

        var depacketiser = VideoDepacketiser()
        if
            let layer = subscribedLayers[who],
            let catalog = await catalogs[who]?.current,
            let hex = catalog.track(named: layer.value)?.decoderConfiguration
        {
            depacketiser.setDecoderConfiguration(hexadecimal: hex)
        }

        let id = UUID()
        replayDepacketisers[id] = depacketiser
        replayTasks[id] = Task { [weak self] in
            for await record in fetch.records {
                await self?.receiveReplay(record, from: who, id: id, into: continuation)
            }
            await self?.endReplay(id: id, continuation: continuation)
        }
        return frames
    }

    private func receiveReplay(
        _ record: FetchedRecord,
        from who: ParticipantIdentity,
        id: UUID,
        into continuation: AsyncStream<DepacketisedFrame>.Continuation
    ) async {
        guard var depacketiser = replayDepacketisers[id] else { return }
        defer { replayDepacketisers[id] = depacketiser }

        switch record {
        case let .object(object):
            // Metered like live media. History competes for the same downlink,
            // and an estimator that only saw the live edge would read a replay
            // as spare capacity.
            estimator.record(object, at: .nanoseconds(DispatchTime.now().uptimeNanoseconds))

            guard let plain = await open(object, from: who) else { return }
            if let frame = depacketiser.accept(plain) { continuation.yield(frame) }
        case let .missing(through), let .unknown(through):
            depacketiser.skip(through: through.object)
        }
    }

    private func endReplay(
        id: UUID,
        continuation: AsyncStream<DepacketisedFrame>.Continuation
    ) {
        replayDepacketisers.removeValue(forKey: id)
        replayTasks.removeValue(forKey: id)
        // Finished rather than left open: a fetch ending is the normal outcome,
        // and a caller iterating this needs the loop to terminate.
        continuation.finish()
    }

    private func receive(
        _ record: FetchedRecord,
        from who: ParticipantIdentity,
        into sink: MediaSink
    ) async {
        switch record {
        case let .object(object):
            // Through the same path as live media, deliberately: fetched objects
            // are decrypted with the same keys, counted in the same statistics,
            // and reassembled by the same depacketiser. A second path would be a
            // second place for the pre-keyframe rule to be wrong.
            await receive(object, from: who, into: sink)
        case let .missing(through), let .unknown(through):
            // A gap in history is final, so the depacketiser is told rather than
            // left waiting for objects that were never published.
            var depacketiser = depacketisers[who] ?? VideoDepacketiser()
            depacketiser.skip(through: through.object)
            depacketisers[who] = depacketiser
        }
    }

    private var catchUps: [ParticipantIdentity: Task<Void, Never>] = [:]

    private func receive(
        _ object: TrackObject,
        from who: ParticipantIdentity,
        into sink: MediaSink
    ) async {
        // Measured before decryption, because what the link carried is the
        // ciphertext, and because an object that fails to authenticate still
        // consumed bandwidth.
        estimator.record(object, at: .nanoseconds(DispatchTime.now().uptimeNanoseconds))

        // Before the decryption guard below, for the same reason: an object
        // that arrived and failed to open is still proof the publisher is
        // sending. Recording it after would report a peer with the wrong keys
        // as a peer who had gone quiet, which is a misleading way to describe a
        // key mismatch.
        lastObject[who] = now()

        guard let plain = await open(object, from: who) else { return }

        sink.objectsContinuation.yield(plain)

        var depacketiser = depacketisers[who] ?? VideoDepacketiser()
        let frame = depacketiser.accept(plain)
        depacketisers[who] = depacketiser
        guard let frame else { return }

        sink.frames.yield(frame)
        await feedVideoTaps(frame, from: who)
    }

    /// Hand a reassembled frame to whoever is decoding it for their own reasons.
    ///
    /// After the renderer's copy has been yielded, deliberately. A tap is
    /// somebody else's work and must never be in front of the picture.
    private func feedVideoTaps(_ frame: DepacketisedFrame, from who: ParticipantIdentity) async {
        guard var pipes = videoTaps[who], !pipes.isEmpty else { return }

        for pipe in pipes where !pipe.tap.isActive { await pipe.close() }
        pipes.removeAll { !$0.tap.isActive }
        guard !pipes.isEmpty else {
            videoTaps.removeValue(forKey: who)
            return
        }
        videoTaps[who] = pipes

        // Held until the catalog names it. Guessing would build a format
        // description that fails somewhere inside VideoToolbox rather than
        // declining the frame, and the difference matters when the answer
        // arrives a few hundred milliseconds later anyway.
        guard let codec = await codec(of: who) else { return }

        for pipe in pipes {
            guard let failure = await pipe.offer(frame, codec: codec) else { continue }
            logger.error(
                .media,
                "video tap cannot decode",
                [
                    LogField("participant", .participant(who)),
                    LogField("codec", .text(codec.rawValue)),
                    LogField("reason", .text(String(describing: failure))),
                ]
            )
        }
    }

    /// What the downlink looks like it can carry, in bits per second.
    ///
    /// Measured from arriving media rather than supplied by the application.
    public var estimatedLinkBitrate: Int { estimator.estimate }

    /// The full picture, for a debug overlay or a support ticket.
    public var linkStatistics: LinkStatistics {
        LinkStatistics(
            estimate: estimator.estimate,
            received: estimator.receivedBitrate,
            state: estimator.state,
            delayTrend: estimator.delayTrend,
            objectsReceived: estimator.objectsReceived,
            objectsLost: estimator.objectsLost
        )
    }

    /// Forget the path. Call on a network change.
    public func resetLinkEstimate() {
        estimator.reset()
    }

    private func apply(_ action: ModerationAction) async {
        switch action {
        case let .kick(who):
            await depart(who, reason: .evicted)
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

            // Mirrored onto the roster, because two fields holding one fact is
            // how a spotlight ends up moving the badge next to a name without
            // moving the tile. Everything that asks "is this participant
            // spotlighted" asks ``Participant/isSpotlighted``.
            for participant in state.roster.participants {
                let wanted = participant.id == who
                guard participant.isSpotlighted != wanted else { continue }
                state.roster[participant.id]?.isSpotlighted = wanted
            }

            eventContinuation.yield(.spotlightChanged(who))
            await refreshGallery()
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

    /// A writer that encrypts, when the room is encrypted.
    ///
    /// Wrapping the writer rather than encrypting inside the publish path is
    /// what makes it impossible to bypass: there is no route from a frame to
    /// the wire that goes around the wrapper, because upstream the wrapper is
    /// the only writer there is.
    private func protectedWriter(
        for track: FullTrackName,
        priority: UInt8
    ) async throws(MoqomError) -> any TrackWriter {
        // Checked again here, after the entry points have, because this is the
        // one door every media writer passes through — a reopen after a
        // reconnect included — and a policy that could tighten in between has to
        // be honoured by the writer that is opened second.
        try requireEncryptionIfPolicyDemands()
        let relay = try await connection.publish(track, priority: priority)
        // Under the encryption, so a direct peer gets the same ciphertext.
        let writer = DirectTeeWriter(
            relay: relay,
            fanout: directFanout,
            registration: await directFanout.register(track, priority: priority)
        )
        guard let encryption else { return writer }
        return ProtectedTrackWriter(wrapping: writer, sender: encryption.sender)
    }

    private func apply(_ change: SubscriptionChange) async {
        switch change {
        case let .subscribe(who, layer, priority):
            guard let participant = state.roster[who] else { return }
            await cancelVideo(who)
            pumps.removeValue(forKey: who)?.cancel()
            catchUps.removeValue(forKey: who)?.cancel()
            guard
                let name = try? TrackName(layer.value),
                let track = try? FullTrackName(namespace: participant.slot.namespace, name: name)
            else { return }
            let request = SubscribeRequest(track: track, priority: priority)
            let subscription: any SubscriptionHandle
            do {
                subscription = try await connection.subscribe(request)
            } catch {
                // Said out loud rather than swallowed. A refused subscription leaves a tile
                // black on a connection that is working perfectly, and the most common cause
                // is asking for a rung the publisher does not offer — which is a disagreement
                // between two ladders, not a network fault, and impossible to distinguish
                // from one without this line.
                logger.warning(.subscribe, "subscription refused", [
                    LogField("participant", .participant(who)),
                    LogField("layer", .text(layer.value)),
                    LogField("error", .text(String(describing: error))),
                ])
                return
            }
            subscriptions[who] = subscription
            videoPriorities[who] = priority
            let merged = merging(subscription, priority: priority, from: who)
            videoDuals[who] = merged

            // A rung change is a different bitstream with its own parameter
            // sets and its own object numbering, so reassembly starts over
            // rather than carrying state across the switch.
            subscribedLayers[who] = layer
            depacketisers[who] = VideoDepacketiser()
            configureDepacketiser(for: who, from: await catalogs[who]?.current)

            startPump(merged ?? subscription, for: who)
            await catchUp(on: subscription, for: who)
        case let .unsubscribeVideo(who):
            pumps.removeValue(forKey: who)?.cancel()
            catchUps.removeValue(forKey: who)?.cancel()
            subscribedLayers.removeValue(forKey: who)
            depacketisers.removeValue(forKey: who)

            // The tap ends with the media. A tap left open on a track nobody is
            // subscribed to holds a decoder that will never be fed, and a
            // consumer blocked on it would wait for a frame that is not coming.
            for pipe in videoTaps.removeValue(forKey: who) ?? [] {
                await pipe.close()
            }

            await cancelVideo(who)
            videoPriorities.removeValue(forKey: who)
        case let .reprioritise(who, priority):
            videoPriorities[who] = priority
            await subscriptions[who]?.updatePriority(priority)
        }
    }
}

/// One participant's media, after metering and decryption.
///
/// Two views of the same objects rather than one, because the two consumers are
/// different: a renderer wants frames, and a recorder or a bridge wants the
/// objects exactly as they arrived. Deriving one from the other in the
/// application would mean depacketising twice or recording something that had
/// already been reassembled.
struct MediaSink: Sendable {
    let objects: AsyncStream<TrackObject>
    let objectsContinuation: AsyncStream<TrackObject>.Continuation

    /// A stream per caller, rather than one stream handed out repeatedly.
    ///
    /// The distinction is invisible until a view is rebuilt, and then it is the whole
    /// difference between a picture and a black tile. An `AsyncStream` has one consumer, and
    /// abandoning it does not merely stop that consumer: the iterator's deinit terminates the
    /// stream itself. So a tile torn down and replaced — which SwiftUI does for any change of
    /// layout — killed the stream on its way out, and the replacement asked for frames, was
    /// handed the same dead stream, and waited on it forever. Everything upstream carried on
    /// perfectly: the subscription stayed open, reassembly kept counting frames, and the only
    /// symptom was a tile that stopped.
    let frames: FrameFanout

    init() {
        // Newest, because a subscriber that has fallen behind on live media
        // wants the current picture rather than the backlog.
        (objects, objectsContinuation) = AsyncStream.makeStream(
            of: TrackObject.self,
            bufferingPolicy: .bufferingNewest(64)
        )
        frames = FrameFanout()
    }

    func finish() {
        objectsContinuation.finish()
        frames.finish()
    }
}

/// Delivers one participant's reassembled frames to everyone who asked for them.
///
/// A class with a lock rather than actor state, because it is yielded to from the receive
/// path — which is somewhere with better things to do than await an actor — and subscribed to
/// from the main actor when a view appears.
final class FrameFanout: @unchecked Sendable {
    private let lock = NSLock()
    private var subscribers: [UUID: AsyncStream<DepacketisedFrame>.Continuation] = [:]
    private var isFinished = false

    /// A new stream, live from now, which unsubscribes itself when it ends.
    func stream() -> AsyncStream<DepacketisedFrame> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: DepacketisedFrame.self,
            bufferingPolicy: .bufferingNewest(64)
        )
        continuation.onTermination = { [weak self] _ in
            self?.lock.withLock { _ = self?.subscribers.removeValue(forKey: id) }
        }
        let finished: Bool = lock.withLock {
            guard !isFinished else { return true }
            subscribers[id] = continuation
            return false
        }
        if finished { continuation.finish() }
        return stream
    }

    func yield(_ frame: DepacketisedFrame) {
        let all = lock.withLock { Array(subscribers.values) }
        for subscriber in all { subscriber.yield(frame) }
    }

    func finish() {
        let all: [AsyncStream<DepacketisedFrame>.Continuation] = lock.withLock {
            isFinished = true
            let existing = Array(subscribers.values)
            subscribers.removeAll()
            return existing
        }
        for subscriber in all { subscriber.finish() }
    }
}

/// One participant's audio, paced.
struct AudioSink: Sendable {
    let stream: AsyncStream<JitterBufferOutput>
    let continuation: AsyncStream<JitterBufferOutput>.Continuation

    init() {
        // Unbounded, unlike the video sinks. Dropping the oldest slot would put
        // the remaining ones out of order with what has already been heard,
        // which is the one thing a jitter buffer exists to prevent — and audio
        // at 24kbps cannot build a backlog worth bounding.
        (stream, continuation) = AsyncStream.makeStream(
            of: JitterBufferOutput.self,
            bufferingPolicy: .unbounded
        )
    }
}

/// What the link is doing, for a debug overlay or a support ticket.
public struct LinkStatistics: Hashable, Sendable {
    /// What the controller believes the path can carry, in bits per second.
    public let estimate: Int

    /// What is actually arriving.
    public let received: Int

    public let state: BandwidthState

    /// Milliseconds of delay the path is adding per second of media. Positive
    /// means a queue is building.
    public let delayTrend: Double

    public let objectsReceived: Int

    /// Inferred from gaps in object IDs within a group.
    public let objectsLost: Int

    public init(
        estimate: Int,
        received: Int,
        state: BandwidthState,
        delayTrend: Double,
        objectsReceived: Int,
        objectsLost: Int
    ) {
        self.estimate = estimate
        self.received = received
        self.state = state
        self.delayTrend = delayTrend
        self.objectsReceived = objectsReceived
        self.objectsLost = objectsLost
    }

    /// Before anything has arrived.
    public static let unknown = LinkStatistics(
        estimate: 0,
        received: 0,
        state: .increasing,
        delayTrend: 0,
        objectsReceived: 0,
        objectsLost: 0
    )
}
