// The room.
//
// Two things here are doing real work rather than decorating.
//
// `.moqomRenderBox(for:reportingTo:)` on each tile is what makes layer
// selection render-aware: the tile reports its own size in points, the SDK
// converts with the display scale, and a nine-tile grid ends up subscribed to
// thumbnails instead of nine 1080p streams. Moving that modifier to the
// enclosing `LazyVGrid` would report the grid's size nine times and quietly
// subscribe everyone to fullscreen.
//
// The watchdog banner is separate from the grid because the types are separate.
// There is no array holding both, so a recorder cannot end up as a tile by
// accident — which is the failure mode this structure exists to prevent.

import MoqomCore
import MoqomKit
import SwiftUI

struct RoomScreen: View {
    @Bindable var room: RoomModel
    let onLeave: () async -> Void

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if !room.watchdogs.isEmpty {
                    WatchdogBanner(watchdogs: room.watchdogs)
                }

                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(room.participants, id: \.slot.identity) { participant in
                        ParticipantTile(
                            participant: participant,
                            isSelf: participant.slot.identity == room.identity
                        ) {
                            await room.toggleLocalMute(participant.slot.identity)
                        }
                        .moqomRenderBox(
                            for: participant.slot.identity,
                            reportingTo: room.layout
                        )
                    }
                }

                if room.participants.isEmpty {
                    ContentUnavailableView(
                        "Nobody on stage",
                        systemImage: "person.2.slash",
                        description: Text("Start broadcasting to appear here.")
                    )
                    .frame(minHeight: 200)
                }
            }
            .padding()
        }
        .navigationTitle(room.roomName)
        .safeAreaInset(edge: .bottom) {
            BroadcastControls(room: room)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("Room", systemImage: "ellipsis.circle") {
                    Button("Record session", systemImage: "record.circle") {
                        Task { await room.attachRecorder() }
                    }
                    Button("Lock stage", systemImage: "lock") {
                        Task { await room.moderate(.lockStage(true)) }
                    }
                    Divider()
                    Button("Leave", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                        Task { await onLeave() }
                    }
                }
            }
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { room.lastError != nil },
                set: { if !$0 { room.dismissError() } }
            )
        ) {
            Button("OK") { room.dismissError() }
        }
    }
}

/// Disclosure, not a participant.
///
/// Rendered as room chrome because a recorder is not in the room in the sense
/// the roster means — it publishes nothing and can be neither muted nor kicked.
struct WatchdogBanner: View {
    let watchdogs: [Watchdog]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(watchdogs, id: \.id) { watchdog in
                Label {
                    VStack(alignment: .leading) {
                        Text(watchdog.descriptor).font(.subheadline.weight(.medium))
                        Text(operatorDescription(watchdog.operatedBy))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: icon(for: watchdog.kind))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    private func icon(for kind: WatchdogKind) -> String {
        switch kind {
        case .recording: "record.circle"
        case .safety: "shield"
        case .analytics: "chart.bar"
        case .compliance: "checkmark.seal"
        case .custom: "eye"
        }
    }

    private func operatorDescription(_ operatedBy: WatchdogOperator) -> String {
        switch operatedBy {
        case .platform: "Operated by MOQOM"
        case .tenant: "Operated by this room's host"
        case let .thirdParty(name): "Operated by \(name)"
        }
    }
}

struct ParticipantTile: View {
    let participant: Participant
    let isSelf: Bool
    let onToggleMute: () async -> Void

    var body: some View {
        RemoteVideoView(participant: participant)
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            // The video area is black and so is the page, so without an edge a
            // tile that has not received a frame is indistinguishable from no
            // tile at all. Letterboxing has to stay black — a grey pillarbox
            // around a 4:3 publisher would look like a rendering fault — which
            // makes the border the only thing that can carry the boundary.
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.quaternary, lineWidth: 1)
            }
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 4) {
                    Text(participant.slot.identity.username.value)
                        .font(.caption.weight(.semibold))
                    if participant.mute.effective.contains(.audio) {
                        Image(systemName: "mic.slash.fill")
                    }
                }
                .padding(6)
                .background(.thinMaterial, in: Capsule())
                .padding(8)
            }
            .overlay(alignment: .topTrailing) {
                if !isSelf {
                    Button {
                        Task { await onToggleMute() }
                    } label: {
                        Image(
                            systemName: participant.mute.localToMe.contains(.audio)
                                ? "speaker.slash.fill"
                                : "speaker.wave.2.fill"
                        )
                    }
                    .buttonStyle(.borderless)
                    .padding(8)
                    // Silencing someone for yourself is not moderation and does
                    // not ask anyone: the control is always enabled.
                    .help("Mute for me only")
                }
            }
    }
}

struct BroadcastControls: View {
    @Bindable var room: RoomModel

    var body: some View {
        HStack(spacing: 12) {
            Button {
                Task {
                    if room.isBroadcasting {
                        await room.stopBroadcast()
                    } else {
                        await room.startBroadcast()
                    }
                }
            } label: {
                Label(
                    room.isBroadcasting ? "Stop" : "Go live",
                    systemImage: room.isBroadcasting ? "stop.circle.fill" : "dot.radiowaves.left.and.right"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(room.isBroadcasting ? .red : .accentColor)

            SceneEffectsMenu()
                .disabled(!room.isBroadcasting)
        }
        .padding()
        .background(.bar)
    }
}
