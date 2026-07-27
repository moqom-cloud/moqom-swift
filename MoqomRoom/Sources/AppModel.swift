// The one piece of state the whole app hangs off.
//
// `@Observable` and a plain class rather than an actor: this is view state, it
// is read during layout, and making it an actor would put a suspension point in
// every view body. The concurrency lives one layer down in `MoqomSession` and
// `RoomSession`, which are actors; this type is their main-actor mirror.

import Foundation
import MoqomCore
import MoqomKit
import MoqomLoopback
import Observation

@MainActor
@Observable
final class AppModel {
    enum Phase {
        case joining
        case connecting
        case inRoom(RoomModel)
        case failed(MoqomError)
    }

    private(set) var phase: Phase = .joining

    var username: String = ""
    var roomName: String = "demo"

    /// Pointed at the loopback relay, because there is no relay to point at
    /// yet. When `moqom-transport` lands this becomes a QUIC transport and
    /// nothing else in the sample changes, which is the whole point of the seam.
    private let transport: any Transport = LoopbackTransport()

    var canJoin: Bool {
        if case .joining = phase { return !username.trimmed.isEmpty }
        return false
    }

    func join() async {
        guard canJoin else { return }
        phase = .connecting

        do {
            let identity = try ParticipantIdentity(
                username: Username(username.trimmed),
                // A real client derives this from the Secure Enclave key the
                // token's `cnf` claim is bound to, at install.
                device: DeviceID(thumbprint: "sample-device-key")
            )
            let session = MoqomSession(
                transport: transport,
                credentials: DeviceCredentials(
                    identity: identity,
                    token: Data(),
                    proofSigner: { challenge in challenge }
                ),
                tenant: "demo"
            )
            try await session.connect(to: RelayEndpoint(host: "relay.moqom.invalid"))
            let room = try await session.join(room: RoomID(roomName))
            phase = .inRoom(RoomModel(session: session, room: room, identity: identity))
        } catch let error as MoqomError {
            phase = .failed(error)
        } catch let error as NameError {
            phase = .failed(.invalidName(error))
        } catch {
            phase = .failed(.transport(.unreachable))
        }
    }

    func leave() async {
        if case let .inRoom(model) = phase {
            await model.leave()
        }
        phase = .joining
    }

    func dismissError() {
        phase = .joining
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
