// The room, in two layouts.
//
// The gallery is `MoqomGalleryView`, which is doing two things that are easy to
// get wrong by hand. It chooses a column count that maximises the visible area
// of each tile — which is a subscription decision as much as a layout one, since
// the SDK serves each tile the rung its box asks for — and it reports every
// tile's geometry, so layer selection cannot be left out on one branch. A
// hand-rolled `LazyVGrid` with the reporting modifier moved up to the container
// looks identical and subscribes everybody to fullscreen.
//
// Which participants are in it comes from the SDK too, and not from the roster.
// With twenty cohosts and sixteen boxes somebody has to be left out, and the
// gallery picks by who is talking rather than by username, holds each tile long
// enough not to flicker, and leaves the audio of everyone it drops alone.
//
// The audio room is the same machinery with square seats and no video. What makes
// it a different product is not the layout: it is that a listener holds no
// microphone, which is a session category and lives in `RoomModel`.
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

    var body: some View {
        VStack(spacing: 12) {
            if !room.watchdogs.isEmpty {
                WatchdogBanner(watchdogs: room.watchdogs)
                    .padding(.horizontal)
            }

            if room.participants.isEmpty {
                ContentUnavailableView(
                    "Nobody on stage",
                    systemImage: "person.2.slash",
                    description: Text("Start broadcasting to appear here.")
                )
            } else if room.slots.isEmpty {
                // Only this device. The gallery contains everyone *else*, so a
                // solo broadcaster has no tiles — which is a full-size self view
                // rather than an empty grid with a thumbnail under it.
                SelfView(room: room, height: nil)
                    .padding(.horizontal, 8)
            } else {
                MoqomGalleryView(
                    slots: room.slots,
                    reportingTo: room.layout,
                    aspect: room.mode.seatAspect,
                    spacing: 8
                ) { slot in
                    switch room.mode {
                    case .gallery:
                        GalleryTile(slot: slot, room: room)
                    case .audioRoom:
                        SeatTile(slot: slot, room: room)
                    }
                }
                .padding(.horizontal, 8)

                if !room.overflow.isEmpty {
                    // Not hidden and not an error. They are still audible; there
                    // is simply no tile, because sixteen decoders is a hardware
                    // limit and this is what degrading into it looks like.
                    Label(
                        "\(room.overflow.count) more listening in",
                        systemImage: "person.2.wave.2"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            if !room.slots.isEmpty, room.isBroadcasting || room.isPublishingAudio {
                HStack {
                    Spacer()
                    SelfView(room: room, height: 84)
                }
                .padding(.horizontal)
            }
        }
        .frame(maxHeight: .infinity)
        .navigationTitle(room.roomName)
        .safeAreaInset(edge: .bottom) {
            BroadcastControls(room: room)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("Room", systemImage: "ellipsis.circle") {
                    Picker("Layout", selection: $room.mode) {
                        ForEach(RoomModel.Mode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }

                    // The number a real client lowers when the device gets hot.
                    // Sixteen is reachable because sixteen tiles are small; it is
                    // not sixteen streams of anything larger.
                    Picker("Tiles", selection: $room.boxes) {
                        ForEach([4, 9, 16], id: \.self) { count in
                            Text("\(count)").tag(count)
                        }
                    }

                    Divider()
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
        } message: {
            if let error = room.lastError {
                Text(error.displayString)
            }
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

/// One video tile in the gallery.
///
/// Takes a ``Gallery/Slot`` rather than a `Participant` because the slot carries
/// the two things a tile needs that the roster does not have: whether they are
/// talking, and why they have a tile at all.
struct GalleryTile: View {
    let slot: Gallery.Slot
    let room: RoomModel

    var body: some View {
        Group {
            if let participant = room.participant(slot.identity) {
                ParticipantTile(
                    participant: participant,
                    isSelf: false,
                    quality: room.quality(of: slot.identity),
                    room: room
                ) {
                    await room.toggleLocalMute(slot.identity)
                }
            } else {
                RoundedRectangle(cornerRadius: 12).fill(.quaternary)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.green, lineWidth: slot.isSpeaking ? 3 : 0)
        }
        .overlay(alignment: .topLeading) {
            if slot.isFeatured {
                Image(systemName: slot.claim == .spotlighted ? "star.fill" : "pin.fill")
                    .font(.caption)
                    .padding(6)
            }
        }
        .animation(.easeOut(duration: 0.15), value: slot.isSpeaking)
        .onTapGesture {
            Task { await room.togglePin(slot.identity) }
        }
    }
}

/// One seat in an audio room.
///
/// No video, no decoder, and no subscription beyond the audio that was arriving
/// anyway — which is why an audio room seats far more people than a gallery can.
struct SeatTile: View {
    let slot: Gallery.Slot
    let room: RoomModel

    private var initial: String {
        String(slot.identity.username.value.prefix(1)).uppercased()
    }

    private var isMuted: Bool {
        room.participant(slot.identity)?.mute.effective.contains(.audio) == true
    }

    var body: some View {
        VStack(spacing: 6) {
            Circle()
                .fill(.tertiary)
                .overlay {
                    Text(initial)
                        .font(.title2.weight(.semibold))
                }
                .overlay {
                    // The ring is the whole interface of an audio room: with no
                    // faces it is the only thing that says who is talking.
                    Circle().strokeBorder(.green, lineWidth: slot.isSpeaking ? 3 : 0)
                }
                .overlay(alignment: .bottomTrailing) {
                    if isMuted {
                        Image(systemName: "mic.slash.fill")
                            .font(.caption2)
                            .padding(4)
                            .background(.thinMaterial, in: Circle())
                    }
                }
                .animation(.easeOut(duration: 0.15), value: slot.isSpeaking)

            Text(slot.identity.username.value)
                .font(.caption)
                .lineLimit(1)
        }
        .padding(4)
        .contentShape(Rectangle())
        .onTapGesture {
            Task { await room.toggleLocalMute(slot.identity) }
        }
    }
}

/// This device, which the gallery deliberately does not contain.
///
/// Drawn from the capture preview rather than from the relay: previewing the
/// published stream would show the publisher their own latency and their own
/// compression artefacts, and would pay to download an upload they just made.
struct SelfView: View {
    let room: RoomModel

    /// `nil` to fill whatever it is given.
    let height: Double?

    var body: some View {
        if let me = room.participant(room.identity) {
            RemoteVideoView(participant: me, isSelf: true, room: room)
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(height: height.map { CGFloat($0) })
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(.quaternary, lineWidth: 1)
                }
                .overlay(alignment: .bottomLeading) {
                    Text("You")
                        .font(.caption2.weight(.semibold))
                        .padding(4)
                        .background(.thinMaterial, in: Capsule())
                        .padding(4)
                }
        }
    }
}

struct ParticipantTile: View {
    let participant: Participant
    let isSelf: Bool

    /// The best rung this publisher offers, from their catalog.
    ///
    /// `nil` until the catalog arrives. Shown as nothing rather than as a
    /// guess, because a badge that says 720p for a publisher sending 540p is
    /// worse than no badge.
    let quality: String?

    let room: RoomModel

    let onToggleMute: () async -> Void

    var body: some View {
        RemoteVideoView(participant: participant, isSelf: isSelf, room: room)
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
                    if let quality {
                        Text(quality)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
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
        VStack(spacing: 8) {
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
                        systemImage: room.isBroadcasting
                            ? "stop.circle.fill"
                            : "dot.radiowaves.left.and.right"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(room.isBroadcasting ? .red : .accentColor)

                Button {
                    Task {
                        if room.isPublishingAudio {
                            await room.stopAudio()
                        } else {
                            await room.startAudio()
                        }
                    }
                } label: {
                    Label(
                        room.isPublishingAudio ? "Mute" : "Audio",
                        systemImage: room.isPublishingAudio ? "mic.fill" : "mic"
                    )
                }
                .buttonStyle(.bordered)

                // Fixed while publishing. Swapping the source under a live
                // publication would mean tearing down the capture the encoder is
                // reading from, and the sample is not the place to demonstrate
                // that being survivable.
                Menu {
                    Picker("Input", selection: $room.audioInput) {
                        ForEach(RoomModel.AudioInput.allCases) { input in
                            Text(input.rawValue).tag(input)
                        }
                    }

                    // Here so cancellation can be measured rather than believed.
                    // Toggling it while the far end plays gives the level
                    // difference the canceller is worth, which is the only
                    // honest way to know it is doing anything.
                    Toggle("Bypass voice processing", isOn: $room.isBypassingVoiceProcessing)
                        .disabled(!room.isPublishingAudio || room.audioInput != .microphone)
                } label: {
                    Label("Input", systemImage: "waveform")
                }
                .buttonStyle(.bordered)
                .disabled(room.isPublishingAudio)

                SceneEffectsMenu()
                    .disabled(!room.isBroadcasting)
            }

            if room.isPublishingAudio, room.audioInput == .microphone {
                CaptureReadout(meter: room.meter, isCancellingEcho: room.isCancellingEcho)
            }

            LinkReadout(link: room.link, quality: room.quality)

            if let statistics = room.statistics, !statistics.struggling.isEmpty {
                StrugglingReadout(struggling: statistics.struggling)
            }
        }
        .padding(.horizontal)
        .padding(.top)
        .padding(.bottom, 28)
        .background(.bar)
    }
}

/// What the microphone is hearing, and whether echo is being cancelled.
///
/// In the sample because it is the only way to check cancellation without lab
/// equipment. The procedure is in `Samples/MoqomRoom/README.md`: two devices,
/// one on speakerphone with the camera on, and this readout answers whether the
/// far end is leaking into the near end. A number on screen is worth more here
/// than a log line, because the thing being measured only happens while somebody
/// is holding the phone.
struct CaptureReadout: View {
    let meter: AudioMeter
    let isCancellingEcho: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isCancellingEcho ? "ear.badge.checkmark" : "ear.trianglebadge.exclamationmark")
                .foregroundStyle(isCancellingEcho ? .green : .orange)
                .accessibilityLabel(
                    isCancellingEcho ? "Echo cancellation on" : "Echo cancellation unavailable"
                )

            // Level and floor together, because neither means anything alone. A
            // level of -30 dBFS is speech in a quiet room and silence in a loud
            // one, and the gap between the two is the whole decision.
            Text(reading(meter.level))
                .monospacedDigit()
            Text("floor \(reading(meter.noiseFloor))")
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Spacer()

            Label("Speaking", systemImage: "waveform.badge.mic")
                .labelStyle(.iconOnly)
                .foregroundStyle(meter.isSpeaking ? .green : .secondary)
                .accessibilityLabel(meter.isSpeaking ? "Speaking" : "Not speaking")
        }
        .font(.caption)
    }

    private func reading(_ decibels: Double) -> String {
        decibels <= VoiceActivity.silent ? "--" : String(format: "%.0f dB", decibels)
    }
}

/// What the SDK measures the link to be doing.
///
/// Worth putting in the sample because it is the answer to the question every
/// integrator eventually asks — "why did it pick that quality" — and because
/// nothing in the app computes it. It comes from watching the media arrive.
struct LinkReadout: View {
    let link: LinkStatistics
    let quality: ConnectionQuality

    var body: some View {
        HStack(spacing: 8) {
            QualityBadge(quality: quality)
            Image(systemName: icon)
            Text("\(link.estimate / 1000) kbps")
            if link.objectsLost > 0 {
                Text("· \(link.objectsLost) lost")
            }
            if abs(link.delayTrend) > 0.5 {
                Text(String(format: "· %+.1f ms/s", link.delayTrend))
            }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    private var icon: String {
        switch link.state {
        case .increasing: "arrow.up.right.circle"
        case .holding: "equal.circle"
        case .decreasing: "arrow.down.right.circle"
        }
    }
}

/// Five bars of signal, from the SDK's own measurement.
///
/// Bars rather than a percentage on purpose: the SDK reports five buckets, and
/// rendering a number would suggest a precision the underlying signals do not
/// have.
struct QualityBadge: View {
    let quality: ConnectionQuality

    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(1..<5) { bar in
                Capsule()
                    .fill(bar <= quality.rawValue ? tint : Color.secondary.opacity(0.25))
                    .frame(width: 2.5, height: 3 + Double(bar) * 2)
            }
        }
        .frame(height: 11, alignment: .bottom)
        .accessibilityLabel("Connection \(quality.label)")
    }

    private var tint: Color {
        switch quality {
        case .unknown: .secondary
        case .bad: .red
        case .poor: .orange
        case .good, .excellent: .green
        }
    }
}

/// Who in the room is having a bad time.
///
/// The part an aggregate figure cannot tell you. A host whose own connection is
/// perfect still needs to know that one of their guests is dropping out, and
/// naming them is the difference between a host who waits and a host who moves
/// on.
struct StrugglingReadout: View {
    let struggling: [ParticipantStatistics]

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(names)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private var names: String {
        let listed = struggling.prefix(2).map(\.identity.username.value)
        let rest = struggling.count - listed.count
        let joined = listed.joined(separator: ", ")
        return rest > 0
            ? "\(joined) +\(rest) on a weak connection"
            : "\(joined) on a weak connection"
    }
}
