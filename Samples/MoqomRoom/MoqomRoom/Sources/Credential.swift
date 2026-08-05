// The credential this device dials with, and what it says about itself.
//
// Kept out of the defaults database. Everything else on the join screen is an address, and
// this one authorises; a sample is a thing people copy, and a token in `UserDefaults` is a
// token in a plist that an unencrypted backup carries off intact. The Keychain costs thirty
// lines here and is the habit worth demonstrating.
//
// The claims are read for display and never for a decision. A client cannot verify its own
// token — it holds no key, and a client that held one could mint rather than verify — so
// nothing below is trusted for anything. What it buys is a screen that can say "this expired
// forty minutes ago", which is the difference between a saved credential being a convenience
// and being the puzzle this file's earlier absence was avoiding: an app that worked in the
// morning and stopped by lunchtime with nothing on screen having changed.

import Foundation
import Security

/// What a token asserts, as far as the interface needs to say it.
///
/// Unverified, and the naming is deliberate about that: this is what the token *says*.
struct Credential {
    var subject: String
    var tenant: String
    var room: String
    var expires: Date

    /// Read the claims out of a JWT without checking the signature. See the file comment.
    init?(_ token: Data) {
        let parts = token.split(separator: UInt8(ascii: "."))
        guard parts.count == 3, let payload = Self.unpad(parts[1]) else { return nil }

        // Named for the wire rather than for Swift, because these names are the format. The
        // room lives under `moqt` with the rest of what a relay enforces.
        struct Claims: Decodable {
            struct Scope: Decodable { var room: String? }
            var sub: String?
            var aud: String?
            var exp: Double?
            var moqt: Scope?
        }

        guard
            let claims = try? JSONDecoder().decode(Claims.self, from: payload),
            let expires = claims.exp
        else { return nil }

        subject = claims.sub ?? ""
        tenant = claims.aud ?? ""
        room = claims.moqt?.room ?? ""
        self.expires = Date(timeIntervalSince1970: expires)
    }

    /// base64url, which is base64 with two characters exchanged and the padding left off.
    private static func unpad(_ text: Data) -> Data? {
        var encoded = String(decoding: text, as: UTF8.self)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        return Data(base64Encoded: encoded)
    }

    var hasExpired: Bool { expires <= .now }

    /// One line for the join screen, and the only reason the claims are read at all.
    var summary: String {
        let when = expires.formatted(.relative(presentation: .numeric))
        let who = subject.isEmpty ? "somebody" : subject
        let where_ = room.isEmpty ? "no room" : "room \(room)"
        return "\(who) in \(tenant), \(where_) — \(hasExpired ? "expired" : "expires") \(when)"
    }

    /// Why this credential will not do for the room being joined, if it will not.
    ///
    /// The failure it names cost an evening: a token minted for one room, a room field saying
    /// another, and a relay that refuses the pair — which on the phone is a Join that fails
    /// and a Go live that does nothing, with the reason sitting unread in the token itself.
    func complaint(joining room: String, as username: String) -> String? {
        if hasExpired { return "This token expired \(expires.formatted(.relative(presentation: .numeric)))." }
        if !self.room.isEmpty, self.room != room {
            return "This token is for room \(self.room), not \(room)."
        }
        if !subject.isEmpty, subject != username {
            return "This token names \(subject), not \(username)."
        }
        return nil
    }
}

/// Where the token is kept between launches.
///
/// Filed under the host it was minted for, which does two things. A credential is never
/// offered to a relay it does not belong to — and that is not tidiness: a relay holding
/// verification keys refuses a token it cannot verify outright, rather than admitting the
/// session anonymously, so presenting the wrong one is worse than presenting none. And
/// switching relays stops destroying the token for the one being left, so a laptop on the
/// desk and a deployment in Los Angeles can both be a tap away.
enum TokenStore {
    private static let service = "cloud.moqom.room"

    private static func identity(for host: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host,
        ]
    }

    static func load(for host: String) -> Data? {
        var query = identity(for: host)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else {
            return nil
        }
        return item as? Data
    }

    /// Replace what is stored for a host, or clear it when given nothing.
    ///
    /// Deleted and re-added rather than updated, because the Keychain refuses an update to an
    /// item that is not there and refuses an add of one that is, and branching on which case
    /// this is means asking a question whose answer can change between the asking and the
    /// writing.
    static func save(_ token: Data, for host: String) {
        SecItemDelete(identity(for: host) as CFDictionary)
        guard !token.isEmpty else { return }

        var item = identity(for: host)
        item[kSecValueData as String] = token
        // After first unlock rather than when unlocked, so a run started from a Mac against a
        // phone whose screen has since gone dark can still read it.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }

    /// The long-lived credential this device asks for tokens with.
    ///
    /// Beside the tokens and under a name of its own, because the two are secrets
    /// of different lifetimes and losing them has different consequences. A token
    /// expires in fifteen minutes; this one is how the phone gets the next
    /// fifteen minutes, months from now. Both belong in the Keychain and neither
    /// belongs in a defaults database — this one more emphatically, since a
    /// leaked token is a problem that solves itself by lunchtime.
    static func loadJoinCredential(for host: String) -> String? {
        load(for: "join:" + host).map { String(decoding: $0, as: UTF8.self) }
    }

    static func saveJoinCredential(_ credential: String, for host: String) {
        save(Data(credential.utf8), for: "join:" + host)
    }
}
