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

    /// Everyone but this device, in whatever space the stage leaves.
    ///
    /// One view rather than three copies, because it is also the thing that reports each
    /// tile's geometry to the layer selector. Three inlined galleries would be three places
    /// for that reporting to be dropped, and a dropped report does not look like a bug: it
    /// looks like a viewer subscribing to a rung that is too large for the tile it is drawn in.
    private var gallery: some View {
        MoqomGalleryView(
            slots: room.slots,
            reportingTo: room.layout,
            aspect: room.seatAspect,
            spacing: 8,
            columns: room.arrangement.columns
        ) { slot in
            switch room.mode {
            case .gallery:
                GalleryTile(slot: slot, room: room)
            case .audioRoom:
                SeatTile(slot: slot, room: room)
            }
        }
    }

    /// How tall the corner stack of tiles should be, in tiles.
    ///
    /// Capped, because the overlay is a glance at who else is here and not the gallery: a
    /// fourth tile would reach the controls, and the point of this stage is the picture behind.
    private var overlaidRows: Double {
        Double(min(room.arrangement.columns == nil ? room.slots.count : 1, 3))
    }

    /// Who is audible but has no tile.
    @ViewBuilder private var overflowNote: some View {
        if !room.overflow.isEmpty {
            // Not hidden and not an error. They are still audible; there is simply no tile,
            // because sixteen decoders is a hardware limit and this is what degrading into it
            // looks like.
            Label("\(room.overflow.count) more listening in", systemImage: "person.2.wave.2")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

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
                switch room.screen {
                case .others:
                    gallery
                        .padding(.horizontal, 8)
                    overflowNote

                    if room.isBroadcasting || room.isPublishingAudio {
                        HStack {
                            Spacer()
                            SelfView(room: room, height: 132)
                        }
                        .padding(.horizontal)
                    }

                case .me:
                    // The camera under everything, which is a different question from the
                    // one the gallery answers and the reason this is not just a bigger self
                    // view. What is being judged here is the picture this device is sending,
                    // at the size a viewer's screen would give it, with everyone else reduced
                    // to the corner — so the tiles overlay rather than take space from it.
                    ZStack(alignment: .topTrailing) {
                        SelfView(room: room, height: nil)
                        gallery
                            .frame(width: 120, height: 120 / room.seatAspect * overlaidRows)
                            .padding(12)
                    }
                    .padding(.horizontal, 8)
                    overflowNote

                case .sideBySide:
                    // Both at once and both at half width, which is the comparison: the same
                    // scene captured here and the same scene after encoding, a relay and a
                    // decode, at the same size on the same panel. It is also the arrangement
                    // that halves every tile's box, so the rung each tile fetches changes with
                    // it — visible on the badge without touching the grid picker.
                    //
                    // Halved explicitly, because neither side has a width of its own to
                    // negotiate with. The self view is an aspect ratio around a layer and the
                    // gallery is a `GeometryReader`; both answer "as much as you have" to any
                    // proposal, so an `HStack` resolves them in the order it happens to try
                    // and one of them ends up with nothing. What that looks like is a side by
                    // side with one side missing.
                    GeometryReader { proxy in
                        let half = max((proxy.size.width - 8) / 2, 1)
                        HStack(spacing: 8) {
                            SelfView(room: room, height: nil)
                                .frame(width: half)
                            gallery
                                .frame(width: half)
                        }
                        .frame(width: proxy.size.width, height: proxy.size.height)
                    }
                    .padding(.horizontal, 8)
                    overflowNote
                }
            }
        }
        .frame(maxHeight: .infinity)
        // On the video area rather than on the screen, because the system
        // measures this view to decide whether to open the window when the app
        // is backgrounded, and animates the window out of its frame.
        .moqomPictureInPictureSource(room)
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

                    // Separate from the count above, and the pair is the experiment. How
                    // many tiles there are and how they are arranged both change how big
                    // each one is, which is the only input render-aware selection has —
                    // so this is where a rung is chosen, and the badge on each tile is
                    // where the choice can be read.
                    // What the screen is mostly given to, which the grid below then
                    // divides. Side by side is the one worth having on a test device: the
                    // same face captured here and returned by the relay, at the same size.
                    Picker("Stage", selection: $room.screen) {
                        ForEach(RoomModel.Screen.allCases) { choice in
                            Text(choice.rawValue).tag(choice)
                        }
                    }

                    Picker("Grid", selection: $room.arrangement) {
                        ForEach(RoomModel.Arrangement.allCases) { choice in
                            Text(choice.rawValue).tag(choice)
                        }
                    }

                    // The host's mirror, and the only one there is. It is applied at the
                    // capture connection, so it is in the pixels everybody receives rather
                    // than a flip each viewer performs — which is what makes it a decision
                    // at all instead of a per-client preference nobody agrees on.
                    Toggle("Mirror my video", isOn: $room.publishesMirrored)

                    // Who stays on screen once the app is not. A rule rather
                    // than a list, so it keeps following the room as people
                    // join, leave and take the stage.
                    Picker("In small window", selection: $room.cast) {
                        ForEach(CastChoice.allCases) { choice in
                            Text(choice.rawValue).tag(choice)
                        }
                    }

                    Divider()
                    // Always enabled, unlike the controls above it. The card worth clearing
                    // is usually one this launch did not start — a Live Activity outlives
                    // the process that asked for it — so the app cannot tell whether there
                    // is anything to clear, and disabling it on what this launch knows about
                    // would grey out exactly the case somebody is reaching for.
                    #if os(iOS)
                        Button("End Lock Screen card", systemImage: "rectangle.badge.xmark") {
                            Task { await room.clearBroadcastCard() }
                        }
                    #endif

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
                .aspectRatio(room.seatAspect, contentMode: .fit)
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
            .aspectRatio(room.seatAspect, contentMode: .fit)
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
                VStack(alignment: .leading, spacing: 4) {
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

                    // What this tile is costing and why. The offer above is the whole
                    // ladder's best; this is the rung being fetched for a box of this
                    // size, which is the number that moves when the grid changes.
                    if let fetching = room.fetching(participant.slot.identity) {
                        Text(
                            "\(fetching.rung) for "
                                + "\(fetching.box.width)×\(fetching.box.height)"
                        )
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.thinMaterial, in: Capsule())
                    }
                }
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

/// One height and one shape for everything in the control row.
///
/// Not cosmetic. The row mixes a prominent button, several bordered ones and two menus, and
/// each of those sizes itself from its own label — an icon-only menu is shorter than a
/// button with two words in it, so the row came out as a line of different-sized pills with
/// their centres wandering. Fixing the height is also what stops the row changing height
/// when a label does: "Camera off" becoming "Camera on" is one line of text either way, but
/// "Go live" becoming "Stop" is not.
private struct ControlCapsule: ViewModifier {
    /// Whether to drop the words. Everything but the primary action does, because seven
    /// labelled controls do not fit across a phone and the row wraps or clips rather than
    /// telling anyone it did not fit.
    let iconOnly: Bool

    func body(content: Content) -> some View {
        Group {
            if iconOnly {
                content.labelStyle(.iconOnly)
            } else {
                content.labelStyle(.titleAndIcon)
            }
        }
        .frame(height: 44)
        .buttonBorderShape(.capsule)
    }
}

private extension View {
    func controlCapsule(iconOnly: Bool = true) -> some View {
        modifier(ControlCapsule(iconOnly: iconOnly))
    }
}

struct BroadcastControls: View {
    @Bindable var room: RoomModel

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
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
                .controlCapsule(iconOnly: false)

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
                        room.isPublishingAudio ? "End audio" : "Audio",
                        systemImage: room.isPublishingAudio ? "waveform.slash" : "waveform"
                    )
                }
                .buttonStyle(.bordered)
                .controlCapsule()

                // Distinct from the button beside it, and the difference is the
                // point. That one ends the publication: the track closes, the
                // catalog loses it, and every subscriber unsubscribes. This one
                // stops the bytes and leaves all of that standing, so coming
                // back is the next packet rather than a renegotiation.
                Button {
                    Task { await room.setMicrophoneMuted(!room.isMicrophoneMuted) }
                } label: {
                    Label(
                        room.isMicrophoneMuted ? "Unmute" : "Mute",
                        systemImage: room.isMicrophoneMuted ? "mic.slash.fill" : "mic.fill"
                    )
                }
                .buttonStyle(.bordered)
                .tint(room.isMicrophoneMuted ? .red : nil)
                .disabled(!room.isPublishingAudio)
                .controlCapsule()

                Button {
                    Task { await room.setCameraMuted(!room.isCameraMuted) }
                } label: {
                    Label(
                        room.isCameraMuted ? "Camera on" : "Camera off",
                        systemImage: room.isCameraMuted ? "video.slash.fill" : "video.fill"
                    )
                }
                .buttonStyle(.bordered)
                .tint(room.isCameraMuted ? .red : nil)
                .disabled(!room.isBroadcasting)
                .controlCapsule()

                // Live, unlike the input pickers below. Switching cameras does
                // not replace the `FrameSource` the publication is bound to, so
                // there is nothing to tear down and nobody watching sees the
                // participant leave the stage.
                Button {
                    Task { await room.flipCamera() }
                } label: {
                    Label("Flip", systemImage: "arrow.triangle.2.circlepath.camera")
                }
                .buttonStyle(.bordered)
                .disabled(!room.isBroadcasting || room.videoInput != .camera)
                .controlCapsule()

                // Fixed while publishing. Swapping the source under a live
                // publication would mean tearing down the capture the encoder is
                // reading from, and the sample is not the place to demonstrate
                // that being survivable.
                Menu {
                    // Live, unlike the video picker below. Audio is a publication that can be
                    // stopped and restarted in the time between two packets, and disabling
                    // this while publishing meant the one moment a person wants to leave the
                    // tone behind — hearing it — is the moment the control will not move.
                    Picker("Audio", selection: $room.audioInput) {
                        ForEach(RoomModel.AudioInput.allCases) { input in
                            Text(input.rawValue).tag(input)
                        }
                    }

                    Picker("Video", selection: $room.videoInput) {
                        ForEach(RoomModel.VideoInput.allCases) { input in
                            Text(input.rawValue).tag(input)
                        }
                    }
                    .disabled(room.isBroadcasting)

                    // Here so cancellation can be measured rather than believed.
                    // Toggling it while the far end plays gives the level
                    // difference the canceller is worth, which is the only
                    // honest way to know it is doing anything.
                    Toggle("Bypass voice processing", isOn: $room.isBypassingVoiceProcessing)
                        .disabled(!room.isPublishingAudio || room.audioInput != .microphone)
                } label: {
                    Label("Input", systemImage: "slider.horizontal.3")
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .controlCapsule()

                // In the row rather than in the toolbar menu, because these two are what a
                // test session actually touches. Between them they set every tile's size,
                // and a tile's size is the whole input to which rung is fetched — so this is
                // the control that changes what is being measured, and it was three taps away
                // behind a picker for something else.
                Menu {
                    Picker("Stage", selection: $room.screen) {
                        ForEach(RoomModel.Screen.allCases) { choice in
                            Text(choice.rawValue).tag(choice)
                        }
                    }

                    Picker("Grid", selection: $room.arrangement) {
                        ForEach(RoomModel.Arrangement.allCases) { choice in
                            Text(choice.rawValue).tag(choice)
                        }
                    }

                    Toggle("Mirror my video", isOn: $room.publishesMirrored)
                } label: {
                    Label("Layout", systemImage: "rectangle.3.group")
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .controlCapsule()

                SceneEffectsMenu()
                    .menuStyle(.button)
                    .buttonStyle(.bordered)
                    .disabled(!room.isBroadcasting)
                    .controlCapsule()
            }

            if room.isPublishingAudio, room.audioInput == .microphone {
                CaptureReadout(meter: room.meter, isCancellingEcho: room.isCancellingEcho)
            }

            LinkReadout(link: room.link, quality: room.quality)

            // Neither of these is behind the trusted clock, unlike the latency: the cadence and
            // the hold are both measured on this device's own monotonic clock and stay valid
            // when no clock has been agreed with anybody.
            if !room.participants.filter({ $0.slot.identity != room.identity }).isEmpty {
                // Above the parts it is made of, because it is the one somebody came to read.
                GlassReadout(
                    meter: room.latency,
                    wait: room.playoutSlack ?? room.playoutDepth.seconds,
                    measured: room.trustedStamp != nil
                )

                if room.trustedStamp != nil {
                    LatencyReadout(meter: room.latency)
                }

                CadenceReadout(meter: room.cadence)
            }

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

/// The whole of it: shutter to screen, on the phone, while it is happening.
///
/// Two things nobody can see separately, added up. Sensor to arrival is what the encoder and
/// the network cost, and is measured across two devices against a shared clock. The wait is
/// what the far end then holds the frame for so the motion is even, and is measured here — as
/// the headroom the frames actually have, which is not the delay that was asked for. See
/// ``VideoRenderer/playoutSlack``.
///
/// Worth the space it takes because it is the number a person actually experiences and the
/// only one they can check against the room: hold a hand up, watch it arrive on the other
/// phone. Everything below this line explains the total; this is the total.
struct GlassReadout: View {
    let meter: LatencyMeter

    /// Seconds a frame waits at the far end before it is shown.
    let wait: Double

    /// Whether the two devices have agreed a clock, without which there is no total.
    ///
    /// The wait is still shown when they have not, because it is measured here and is true
    /// either way. Half an answer beats the alternatives: a blank row says nothing, and a
    /// total assembled from two unsynchronised clocks says something false.
    let measured: Bool

    @State private var reading: LatencyMeter.Reading?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "camera.metering.matrix")
            if !measured {
                Text(String(format: "%.0f ms", held))
                    .font(.caption.bold().monospacedDigit())
                    .foregroundStyle(.primary)
                Text("hold · glass-to-glass needs Measure on both devices")
                    .foregroundStyle(.tertiary)
            } else if let reading, reading.worst > 0 {
                Text(String(format: "%.0f ms", reading.median + held))
                    .font(.caption.bold().monospacedDigit())
                    .foregroundStyle(.primary)
                Text(String(format: "glass · p95 %.0f", reading.p95 + held))

                // Broken out because the two halves answer to different things: the link is
                // the network and the encoder, and the wait is a policy this app chose. A
                // total that is mostly wait is a total somebody can do something about.
                Text(String(format: "· link %.0f + hold %.0f", reading.median, held))
                    .foregroundStyle(.tertiary)
            } else {
                Text("waiting for the other device")
            }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .task {
            while !Task.isCancelled {
                reading = meter.reading()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var held: Double { wait * 1000 }
}

/// The network half of ``GlassReadout``, with the error bar on the measurement.
///
/// Half of it is measured on each device, so it only means anything because both stamp frames
/// on a clock disciplined against the same service — and the error bar on that clock belongs
/// on screen next to the result rather than tucked into a log line. A median of 60ms taken on
/// a clock that could be 40ms out is not a latency measurement.
///
/// Polled rather than observed, because the meter is written from the frame pump on every
/// frame and publishing that into SwiftUI would invalidate this view thirty times a second to
/// move a digit.
struct LatencyReadout: View {
    let meter: LatencyMeter

    @State private var reading: LatencyMeter.Reading?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "timer")
            if let reading, reading.worst > 0 {
                Text(String(format: "%.0f ms", reading.median))
                Text(String(format: "· p95 %.0f", reading.p95))
                Text(String(format: "· ±%.0f clock", reading.uncertainty))
                    .foregroundStyle(reading.uncertainty > reading.median ? .orange : .secondary)
                if reading.impossible > 0 {
                    // Not a slow link: a pair of clocks that have not agreed yet. Said
                    // plainly, because the latencies alongside it are understated by
                    // however far apart they are.
                    Text("· clocks disagree")
                        .foregroundStyle(.orange)
                }
            } else {
                Text("waiting for the other device")
            }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .task {
            // A second is faster than anyone reads and slow enough to cost nothing.
            while !Task.isCancelled {
                reading = meter.reading()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

/// Frame rate, evenness, and stalls, on the phone that is watching.
///
/// Beside the latency rather than instead of it, because a viewer complaining about choppy
/// video is not describing latency and no latency figure will confirm or refute them. The
/// spread is what to read: an even stream has a p95 gap close to its median, and one that
/// stutters has a p95 several times it while both may average the same frame rate.
struct CadenceReadout: View {
    let meter: CadenceMeter

    @State private var reading: CadenceMeter.Reading?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.path.ecg")
            if let reading {
                Text(String(format: "%.0f fps", reading.rate))
                Text(String(format: "· %.0f/%.0f ms gap", reading.median, reading.p95))
                    .foregroundStyle(reading.unevenness > 2 ? .orange : .secondary)
                if reading.freezes > 0 {
                    Text(String(format: "· %d stalls %.0f%%", reading.freezes, reading.frozen * 100))
                        .foregroundStyle(.orange)

                    // How often, and whether a keyframe closed them. On screen rather than only
                    // in a log, because this is the readout somebody photographs when they say
                    // it looks choppy, and "every 2.0s, all on keyframes" is a different bug
                    // report from the same stall count scattered across ordinary frames.
                    Text(String(
                        format: "· every %.1fs key %d/%d",
                        reading.period,
                        reading.onKeyFrame,
                        reading.freezes
                    ))
                    .foregroundStyle(.orange)
                }
            } else {
                Text("no frames yet")
            }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .task {
            while !Task.isCancelled {
                reading = meter.reading()
                try? await Task.sleep(for: .seconds(1))
            }
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
