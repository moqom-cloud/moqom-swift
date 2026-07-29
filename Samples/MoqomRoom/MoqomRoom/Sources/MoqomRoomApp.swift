import MoqomKit
import SwiftUI

@main
struct MoqomRoomApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                switch model.phase {
                case .joining:
                    JoinScreen(model: model)
                case .connecting:
                    ProgressView("Connecting")
                        .navigationTitle("MOQOM")
                case let .inRoom(room):
                    RoomScreen(room: room) {
                        await model.leave()
                    }
                case let .failed(error):
                    FailureScreen(error: error) {
                        model.dismissError()
                    }
                }
            }
            .task { await model.joinOnLaunch() }
        }
    }
}

struct JoinScreen: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("You") {
                TextField("Username", text: $model.username)
                    .textContentType(.username)
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
            }

            Section {
                TextField("Room", text: $model.roomName)
            } header: {
                Text("Room")
            } footer: {
                // Worth saying out loud in a sample: the same username on a
                // phone and an iPad is two participants, not a conflict to
                // resolve. Nothing here deduplicates by username.
                Text("Joining from a second device adds a second tile.")
            }

            // Where the media actually goes. Left blank the sample runs on the in-process
            // loopback, which is the right default and measures nothing: two phones only
            // become a broadcast when both are pointed at the same relay.
            Section {
                // First, because it is the only field anyone should have to touch. The three
                // below are what it resolves to, left visible so the interface can still say
                // where the media is going.
                TextField("Pairing code", text: $model.pairingCode)
                    #if os(iOS)
                        .keyboardType(.numberPad)
                    #endif

                TextField("Relay host", text: $model.relayHost)
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    #endif
                    .autocorrectionDisabled()

                // Grouping turned off because a port is an identifier and "4,443" is not
                // one, however much the locale would like it to be.
                TextField("Port", value: $model.relay.port, format: .number.grouping(.never))
                    #if os(iOS)
                        .keyboardType(.numberPad)
                    #endif

                TextField("Certificate hash", text: $model.relayCertificateHash)
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .font(.caption.monospaced())
            } header: {
                Text("Relay")
            } footer: {
                // The pinning is worth explaining rather than just offering. A relay on a
                // desk signs its own certificate, so there is nothing for the platform to
                // check and the connection is refused before any media moves — which on
                // screen is indistinguishable from the relay being down.
                VStack(alignment: .leading, spacing: 4) {
                    if let problem = model.pairingProblem {
                        Text(problem).foregroundStyle(.orange)
                    }
                    Text(
                        "A pairing code finds a relay advertising itself on this network and "
                            + "fills in the rest, including the hash of the certificate it "
                            + "signed for itself. Without one, type the address by hand; "
                            + "blank runs on the loopback, with nothing on the network."
                    )
                }
            }

            Section {
                // Deliberately next to Join rather than inside the room: it changes what
                // gets published and which clock stamps it, and both are settled before the
                // first frame.
                Toggle("Measure this run", isOn: $model.measure)

                Button("Join") {
                    Task { await model.join() }
                }
                .disabled(!model.canJoin)
            } footer: {
                // Which relay this build talks to, because "loopback" and "a relay on the
                // desk" produce very different numbers and look identical on screen.
                Text(
                    "Relay: \(model.relay.summary)."
                        + (model.measure
                            ? " Publishes one 720p HEVC rung from the camera on an "
                                + "NTP-disciplined clock, and reports what the far side's "
                                + "frames cost to arrive."
                            : "")
                )
            }
        }
        .navigationTitle("MOQOM")
    }
}

struct FailureScreen: View {
    let error: MoqomError
    let onDismiss: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Could not join", systemImage: "exclamationmark.triangle")
        } description: {
            Text(error.displayString)
        } actions: {
            Button("Try again", action: onDismiss)
        }
    }
}

extension MoqomError {
    /// Rendered from the case, not from a message string.
    ///
    /// The terminal reasons want different treatments and the typed enum is
    /// what makes that a compile-time obligation — adding a case here breaks
    /// the build rather than silently falling into a generic "disconnected"
    /// message.
    var displayString: String {
        switch self {
        case let .invalidName(reason):
            "That name will not work: \(reason)."
        case .transport:
            "Could not reach the relay."
        case let .rejected(reason):
            "The relay refused: \(reason)."
        case .invalidState:
            "The app got ahead of itself."
        case let .terminated(event):
            event.defaultDisplayString
        case let .notPermitted(capability):
            "You do not have permission (\(capability))."
        case let .unsupportedCodec(codec):
            "This device cannot handle \(codec.rawValue)."
        case let .unsupportedAudioCodec(codec):
            "This device cannot handle \(codec.rawValue) audio."
        case .protocolViolation:
            // Deliberately not "try again". Reconnecting into the same
            // violation is how one bug on the other end becomes a loop here.
            "The relay is speaking a protocol this app does not understand."
        case .encryptionFailed:
            "Could not encrypt the stream, so nothing was sent."
        case let .platform(api, status):
            "\(api) failed with \(status)."
        }
    }
}
