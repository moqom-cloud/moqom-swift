// A link that has arrived and has not yet been agreed to.
//
// The problem this solves is the one that made the credential field necessary in
// the first place, taken one step further: a token is four hundred characters
// that expire in fifteen minutes, and a certificate hash is forty-four where a
// single wrong character is a connection that fails silently. Pasting those into
// a phone requires a Mac, a port-forward into the cluster, and a way to get text
// from one to the other. Pointing the camera at a QR code requires a phone.
//
// What is deliberately *not* automatic is the acting on it. A link chooses which
// relay this device trusts and which credential it offers, so it is answered
// with a question rather than applied — the app shows where it is being sent and
// waits. That is not paranoia about this sample; it is that a URL can arrive from
// a message, a web page, or another app, and "opened a link" is not consent to
// dial a stranger's relay with your name on it.
//
// Nothing is joined either way. Agreeing fills the fields in; the Join button
// still has to be pressed, which keeps one path into a room instead of two.

import Foundation
import MoqomKit

/// An invitation, and what it says, for somebody deciding whether to take it.
struct Invitation {
    var relay: RelayInvitation

    /// What the credential in it claims, unverified. See ``Credential``.
    var credential: Credential?

    init?(_ url: URL) {
        guard let relay = RelayInvitation(url) else { return nil }
        self.relay = relay
        credential = relay.token.isEmpty ? nil : Credential(relay.token)
    }

    /// Where this would send the phone, in a sentence somebody can refuse.
    ///
    /// Leads with the address rather than the room, because the address is the
    /// part being trusted and the room is the part that sounds familiar. A link
    /// that says "room demo" first and names an unknown host second is a link
    /// people accept without reading the second half.
    var destination: String {
        let where_ = "\(relay.endpoint.host):\(relay.endpoint.port)"
        let trust = relay.certificateHashes.isEmpty
            ? "using ordinary certificate validation"
            : "trusting a certificate it names"
        return "\(where_), \(trust)"
    }

    /// What the credential in the link would make this phone, if it carries one.
    var identification: String {
        // The service first, because it is the stronger fact: a phone that can
        // fetch its own tokens does not care what token this link came with, and
        // saying "expires in twelve minutes" about a link that never expires is
        // the wrong thing to put in front of somebody deciding.
        if let service = relay.tokenService, !service.credential.isEmpty {
            return "Enrols this phone with \(service.endpoint.host), which will issue it a"
                + " credential each time it joins."
        }
        guard let credential else {
            return relay.token.isEmpty
                ? "No credential, so this would join as nobody."
                : "The credential in it does not read as a token."
        }
        return credential.summary
    }

    /// Whether this link enrols the device rather than handing it one credential.
    var enrols: Bool { relay.tokenService?.credential.isEmpty == false }

    /// Whether it enrols with a token service it does not pin.
    ///
    /// Refused outright rather than offered. Enrolling sends the long-lived
    /// credential on every join, and under ordinary certificate validation
    /// anybody who can get a certificate for that name -- a hijacked registry
    /// is enough -- is handed it.
    var enrolsUnpinned: Bool { enrols && relay.tokenService?.certificateHashes.isEmpty == true }

    /// Whether taking this is pointless because the credential has already died.
    ///
    /// Worth saying before rather than after. A QR code photographed twenty
    /// minutes ago looks exactly like one printed a moment ago, and the failure
    /// it produces — admitted to the relay, permitted nothing — is the one this
    /// whole path exists to stop people debugging.
    ///
    /// A link that enrols is never stale, which is the point of it: the token in
    /// it, if there even is one, is about to be replaced by a fresh one.
    var isStale: Bool { !enrols && (credential?.hasExpired ?? false) }
}
