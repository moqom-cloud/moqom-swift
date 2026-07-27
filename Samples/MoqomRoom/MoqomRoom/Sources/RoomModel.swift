// The room, as the views need it.
//
// This exists because a view cannot read an actor synchronously and a view body
// must not await. So the actor's event stream is drained into main-actor
// properties once, here, and the views read plain values — which is also the
// only way `roster` can be indexed during layout without the roster changing
// halfway through a diff.
//
// Note what is *not* mirrored: `watchdogs` is a separate property from
// `participants`, and there is no combined list. That is not a UI preference,
// it is the SDK's type structure showing through — `Roster` cannot hold a
// `Watchdog`, so a view that wanted them in one array would have to build the
// union deliberately rather than forget to exclude one.

import Foundation
import MoqomCore
import MoqomKit
import Observation

@MainActor
@Observable
final class RoomModel {
    private(set) var participants: [Participant] = []
    private(set) var watchdogs: [Watchdog] = []
    private(set) var stage = StageState()
    private(set) var lifecycle: RoomLifecycle = .live
    private(set) var isBroadcasting = false
    private(set) var lastError: MoqomError?

    /// What this device may do, as granted by its token.
    ///
    /// Hard-coded to owner in the sample. In a real client it is decoded from
    /// the CAT and never inferred from a role name, because roles are a
    /// rendering of capabilities rather than the other way round.
    let grants = Grants(publish: .full, moderation: .owner, isOwner: true)

    let identity: ParticipantIdentity
    let layout = LayoutObserver()

    private let session: MoqomSession
    private let room: RoomSession
    private var pump: Task<Void, Never>?
    private var capture: FrameRelay?

    init(session: MoqomSession, room: RoomSession, identity: ParticipantIdentity) {
        self.session = session
        self.room = room
        self.identity = identity
        layout.bind(to: room)
        start()
    }

    var roomName: String { room.room.value }

    /// Everyone but this device, which is rendered as the local preview.
    var remoteParticipants: [Participant] {
        participants.filter { $0.slot.identity != identity }
    }

    private func start() {
        pump = Task { [weak self, room] in
            for await event in room.events {
                await self?.apply(event)
            }
        }
        Task { await refresh() }
    }

    private func apply(_ event: RoomEvent) async {
        switch event {
        case .watchdogChanged(let set):
            watchdogs = set.all
        case .stageChanged(let updated):
            stage = updated
        case .lifecycleChanged(let updated):
            lifecycle = updated
        case .participantJoined, .participantLeft, .presenceChanged,
             .muteChanged, .grantsChanged, .spotlightChanged:
            await refresh()
        case .terminated:
            await leave()
        }
    }

    private func refresh() async {
        participants = await room.roster.participants
    }

    // MARK: - Broadcasting

    func startBroadcast() async {
        guard !isBroadcasting else { return }

        // A `FrameRelay` rather than a camera or a scene, so the sample runs in
        // a simulator with nothing attached. `SceneEffects` is where a real
        // build swaps in `SceneCapture` and gets the RealityKit path.
        let relay = FrameRelay(
            format: CaptureFormat(size: PixelSize(width: 1280, height: 720), frameRate: 30)
        )
        capture = relay

        do {
            let broadcast = try await room.startBroadcast(from: relay)
            await broadcast.start()
            isBroadcasting = true
            await refresh()
        } catch {
            lastError = error
            capture = nil
        }
    }

    func stopBroadcast() async {
        guard isBroadcasting else { return }
        await room.stopBroadcast()
        capture = nil
        isBroadcasting = false
        await refresh()
    }

    // MARK: - Per-viewer mute

    /// Silence one cohost for this viewer only.
    ///
    /// Never leaves the device. The relay forwards rather than mixes, so this
    /// is an unsubscribe: instant, private, and a bandwidth saving rather than
    /// a request for permission.
    func toggleLocalMute(_ target: ParticipantIdentity) async {
        guard let participant = participants.first(where: { $0.slot.identity == target }) else {
            return
        }
        if participant.mute.localToMe.contains(.audio) {
            await room.localUnmute(target, .audio)
        } else {
            await room.localMute(target, .audio)
        }
        await refresh()
    }

    // MARK: - Moderation

    func moderate(_ action: ModerationAction) async {
        do {
            try await room.moderate(action, as: grants)
            await refresh()
        } catch {
            lastError = error
        }
    }

    func attachRecorder() async {
        do {
            try await room.manageWatchdog(
                .attach(
                    WatchdogRequest(
                        kind: .recording,
                        operatedBy: .tenant,
                        descriptor: "Session recording",
                        scope: room.namespace
                    )
                ),
                as: grants
            )
        } catch {
            lastError = error
        }
    }

    func dismissError() { lastError = nil }

    func leave() async {
        pump?.cancel()
        pump = nil
        await session.close()
    }
}
