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
            // A scanned QR code arrives here. Read and held; see `AppModel.offer`.
            .onOpenURL { model.offer($0) }
        }
    }
}

struct JoinScreen: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            if let invitation = model.offered {
                InvitationSection(invitation: invitation, model: model)
            }

            Section {
                TextField("Username", text: $model.username)
                    .textContentType(.username)
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
            } header: {
                Text("You")
            } footer: {
                DeviceKeyFooter(model: model)
            }

            Section {
                TextField("Pairing code", text: $model.pairingCode)
                    #if os(iOS)
                        .keyboardType(.numberPad)
                    #endif

                TextField("Room or @username", text: $model.roomName)
            } header: {
                Text("Call")
            } footer: {
                Text(
                    "Share the pairing code. Both phones join that call and go live. "
                        + "@ada watches ada. A room name is used only when the code is empty."
                )
            }

            Section {
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
                Text(
                    "The GCP relay this build is compiled against. A pairing code is "
                        + "the call on that relay, not a lookup on this network."
                )
            }

            // Before the token, because it is what produces one. A phone with a
            // service configured never touches the field below: it asks for a
            // credential seconds before it dials, every time, which is the only way
            // a fifteen-minute token is a workable thing to hold.
            Section {
                TextField("Token service host", text: $model.joinHost)
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    #endif
                    .autocorrectionDisabled()

                TextField("Port", text: $model.joinPort)
                    #if os(iOS)
                        .keyboardType(.numberPad)
                    #endif

                TextField("Certificate hash", text: $model.joinCertificateHash)
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .font(.caption.monospaced())

                // Secure, and not because anybody is shoulder-surfing a sample. It
                // is the one durable secret on this screen, and a field that prints
                // it back in full is a field that ends up in a screenshot in an
                // issue.
                SecureField("Device credential", text: $model.joinCredential)
                    .font(.caption.monospaced())
            } header: {
                Text("Token service")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let problem = model.tokenProblem {
                        Text(problem).foregroundStyle(.orange)
                    }
                    Text(model.relay.tokenService?.summary ?? "none")
                    Text(
                        "With this filled in, the phone fetches its own token just before "
                            + "it connects and replaces it mid-call, so neither this nor the "
                            + "call expires. The credential is not a token: it grants joining "
                            + "rooms in one tenant, never moderation or ownership, and it is "
                            + "kept in the Keychain."
                    )
                }
            }

            // Now the fallback rather than the mechanism. Kept because a relay on a
            // desk with no control plane in front of it is still a thing people run,
            // and because a service that is down should not make the deployment
            // unreachable to somebody who can mint by hand.
            Section {
                TextField("Token", text: $model.relayToken, axis: .vertical)
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .lineLimit(1 ... 3)
                    .font(.caption.monospaced())
            } header: {
                Text("Pasted token")
            } footer: {
                // What the token says about itself, read out of it and never checked — the
                // phone holds no key and could not verify this if it wanted to. It is here
                // because a stale token and a good one are the same four hundred characters
                // on screen and behave nothing alike.
                VStack(alignment: .leading, spacing: 4) {
                    if let complaint = model.credentialComplaint {
                        Text(complaint).foregroundStyle(.orange)
                    }
                    if let credential = model.credential {
                        Text(credential.summary)
                    } else if model.relayToken.isEmpty {
                        Text(
                            model.relay.tokenService?.isUsable == true
                                ? "Empty, and it does not need filling in: one will be "
                                    + "fetched when you join."
                                : "Without one, a deployed relay admits this device and lets "
                                    + "it publish nothing. Mint one with deploy/tools/join.sh "
                                    + "and paste it here; it is kept for this relay and this "
                                    + "phone."
                        )
                    } else {
                        Text("That does not read as a token.").foregroundStyle(.orange)
                    }
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
                Text(
                    "Relay: \(model.relay.summary)."
                        + (model.measure
                            ? " Stamps both phones on a shared clock and reports how long "
                                + "the far side's frames take to arrive."
                            : "")
                )
            }
        }
        .navigationTitle("MOQOM")
    }
}

/// Which key this phone is, and where it is kept.
///
/// On screen rather than in a log because it is the value that has to match in
/// three places — the namespace this device announces under, the `cnf.jkt` of
/// the token it presents, and the key it signs its proof of possession with —
/// and a mismatch is refused by the relay with the reason inside a credential
/// nobody reads. It is also the third argument `deploy/tools/join.sh` wants, and
/// reading it off the phone is easier than deriving it anywhere else.
struct DeviceKeyFooter: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let problem = model.deviceProblem {
                // Not fatal, and the sentence says so. A relay that does not
                // require proofs still admits this phone; one that does will
                // not, and that is the whole of the consequence.
                Text("No device key: \(problem). Tokens cannot be bound to this phone.")
                    .foregroundStyle(.orange)
            }
            if let key = model.deviceKey {
                Text(model.deviceName).font(.caption.monospaced())
                Text(
                    key.storage == .secureEnclave
                        ? "Key in the Secure Enclave, so a copied token is useless without "
                            + "this phone."
                        // Said plainly rather than hidden: the fallback passes every check
                        // the enclave does and makes none of the same promise.
                        : "Key in the Keychain — the Secure Enclave was unavailable, so this "
                            + "key could be read off the device."
                )
            }
        }
    }
}

/// What a scanned link is offering, and the two answers to it.
///
/// A section at the top of the form rather than an alert, because an alert
/// interrupts and then disappears: somebody who dismisses one has no way back to
/// the link, and the fields it would have filled are exactly the ones they
/// cannot type. This waits.
struct InvitationSection: View {
    let invitation: Invitation
    let model: AppModel

    var body: some View {
        Section {
            Button("Use this relay") { model.acceptOffer() }
            Button("Ignore", role: .cancel) { model.declineOffer() }
        } header: {
            Text("Scanned link")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                // The address first and in bold, because it is the part being
                // trusted. A link naming a familiar room and an unfamiliar host
                // is one people accept having read only the familiar half.
                Text("Would connect to \(invitation.destination).").bold()
                Text(invitation.identification)
                if invitation.isStale {
                    Text("Its credential has already expired — ask for a fresh link.")
                        .foregroundStyle(.orange)
                }
            }
        }
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
