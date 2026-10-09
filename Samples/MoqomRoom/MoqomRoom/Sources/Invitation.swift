// A link that has arrived and has not yet been agreed to.
//
// The problem this solves: a certificate hash is forty-four characters where a single
// wrong character is a connection that fails silently, and a token server's address is one
// more thing to type on a phone keyboard. Pasting those into a phone requires a Mac and a
// way to get text from one to the other. Pointing the camera at a QR code requires a phone.
//
// A link carries nothing that authorises — no token, no credential. Whoever scans it still
// has to sign in, and the token they are then issued is bound to their own phone's key.
//
// What is deliberately *not* automatic is the acting on it. A link chooses which relay this
// device trusts and which server it signs in to, so it is answered with a question rather
// than applied — the app shows where it is being sent and waits. That is not paranoia about
// this sample; it is that a URL can arrive from a message, a web page, or another app, and
// "opened a link" is not consent to hand your Apple sign-in to a stranger's server.
//
// Nothing is joined either way. Agreeing fills the fields in; the Join button still has to
// be pressed, which keeps one path into a room instead of two.

import Foundation
import MoqomKit

/// An invitation, and what it says, for somebody deciding whether to take it.
struct Invitation {
    var relay: RelayInvitation

    init?(_ url: URL) {
        guard let relay = RelayInvitation(url) else { return nil }
        self.relay = relay
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

    /// Where this phone would sign in, if the link says.
    var identification: String {
        var said = if let server = relay.tokenServer?.host() {
            "Sign in with Apple at \(server), which issues this phone a token each time it joins."
        } else {
            "No token server, so this keeps whichever one this phone already uses."
        }
        if let room = relay.room { said += " Room \(room)." }
        return said
    }
}
