// The broadcast, as it appears when the app is not on screen.
//
// The whole extension is presentation. Every value it draws arrives in
// `context.state`, which is `BroadcastActivityState` — the SDK's type, rendered
// directly rather than mapped into one of the sample's own. That is the point
// worth copying: the card and the app agree on what a broadcast looks like
// because they are reading the same struct, and a state that cannot be drawn is
// a compile error rather than a stale card.
//
// One thing here is load-bearing rather than cosmetic. The elapsed time is
// `Text(timerInterval:)`, given the start date the card already holds, so the
// clock runs without the app sending anything. Formatting a duration in the app
// and pushing it would cost one update per second and exhaust ActivityKit's
// budget within the first minute — after which the card freezes for the rest of
// the broadcast. See `BroadcastActivityThrottle` for the other half of that.

import ActivityKit
import MoqomKit
import SwiftUI
import WidgetKit

struct BroadcastActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MoqomBroadcastAttributes.self) { context in
            LockScreenCard(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(.black.opacity(0.6))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(context.attributes.title)
                            .font(.caption)
                            .lineLimit(1)
                    } icon: {
                        PhaseDot(phase: context.state.phase)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Elapsed(from: context.state.startedAt, phase: context.state.phase)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 12) {
                        Label("\(context.state.participants)", systemImage: "person.2.fill")
                        if let speaker = context.state.speaker {
                            Label(speaker, systemImage: "waveform")
                                .lineLimit(1)
                        }
                        Spacer()
                        Signal(quality: context.state.quality)
                    }
                    .font(.caption)
                }
            } compactLeading: {
                PhaseDot(phase: context.state.phase)
            } compactTrailing: {
                Elapsed(from: context.state.startedAt, phase: context.state.phase)
                    .font(.caption2.monospacedDigit())
                    .frame(maxWidth: 44)
            } minimal: {
                PhaseDot(phase: context.state.phase)
            }
        }
    }
}

// MARK: - Lock Screen

private struct LockScreenCard: View {
    let attributes: MoqomBroadcastAttributes
    let state: BroadcastActivityState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                PhaseDot(phase: state.phase)
                Text(attributes.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Elapsed(from: state.startedAt, phase: state.phase)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 14) {
                Label("\(state.participants)", systemImage: "person.2.fill")

                if let speaker = state.speaker {
                    Label(speaker, systemImage: "waveform")
                        .lineLimit(1)
                } else {
                    Label("Quiet", systemImage: "speaker.slash")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Deliberately prominent. A recording indicator that is easy to
                // miss is, in several jurisdictions, the difference between
                // having disclosed and not.
                if state.isRecording {
                    Label("REC", systemImage: "record.circle")
                        .foregroundStyle(.red)
                }

                Signal(quality: state.quality)
            }
            .font(.caption)

            // Absent for a viewer, because a viewer has no microphone in the
            // room and a greyed-out control would imply otherwise.
            if state.isMuted != nil || state.isCameraOff != nil {
                HStack(spacing: 10) {
                    if let muted = state.isMuted {
                        DeviceChip(
                            on: !muted,
                            onLabel: "Mic on",
                            offLabel: "Muted",
                            onIcon: "mic.fill",
                            offIcon: "mic.slash.fill"
                        )
                    }
                    if let off = state.isCameraOff {
                        DeviceChip(
                            on: !off,
                            onLabel: "Camera on",
                            offLabel: "Camera off",
                            onIcon: "video.fill",
                            offIcon: "video.slash.fill"
                        )
                    }
                }
                .font(.caption2)
            }
        }
        .padding(16)
    }
}

// MARK: - Parts

private struct PhaseDot: View {
    let phase: BroadcastActivityState.Phase

    var body: some View {
        Circle()
            .fill(colour)
            .frame(width: 9, height: 9)
            .accessibilityLabel(label)
    }

    private var colour: Color {
        switch phase {
        case .live: .red
        case .reconnecting: .orange
        case .ended: .secondary
        }
    }

    private var label: String {
        switch phase {
        case .live: "Live"
        case .reconnecting: "Reconnecting"
        case .ended: "Ended"
        }
    }
}

/// The running clock, or a reason there isn't one.
private struct Elapsed: View {
    let from: Date
    let phase: BroadcastActivityState.Phase

    var body: some View {
        switch phase {
        case .live:
            // Counted by SwiftUI from a date the card already holds. No update
            // is sent for any of these ticks, which is what keeps a broadcast
            // of any length inside the budget.
            Text(timerInterval: from...Date.distantFuture, countsDown: false)
        case .reconnecting:
            Text("Reconnecting")
        case .ended:
            Text("Ended")
        }
    }
}

private struct Signal: View {
    let quality: ConnectionQuality

    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(1..<5) { bar in
                Capsule()
                    .fill(bar <= bars ? colour : Color.secondary.opacity(0.3))
                    .frame(width: 2.5, height: 3.5 + Double(bar) * 2)
            }
        }
        .accessibilityLabel("Connection \(quality)")
    }

    private var bars: Int {
        switch quality {
        case .excellent: 4
        case .good: 3
        case .poor: 2
        case .bad: 1
        case .unknown: 0
        }
    }

    private var colour: Color {
        switch quality {
        case .excellent, .good: .green
        case .poor: .yellow
        case .bad: .red
        case .unknown: .secondary
        }
    }
}

private struct DeviceChip: View {
    let on: Bool
    let onLabel: String
    let offLabel: String
    let onIcon: String
    let offIcon: String

    var body: some View {
        Label(on ? onLabel : offLabel, systemImage: on ? onIcon : offIcon)
            .foregroundStyle(on ? .secondary : Color.orange)
    }
}
