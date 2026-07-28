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

            Section {
                Button("Join") {
                    Task { await model.join() }
                }
                .disabled(!model.canJoin)
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
