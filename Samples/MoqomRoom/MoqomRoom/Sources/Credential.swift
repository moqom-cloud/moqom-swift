// The secrets this device keeps between launches.
//
// Kept out of the defaults database. Everything else on the join screen is an address, and
// these authorise; a sample is a thing people copy, and a secret in `UserDefaults` is a
// secret in a plist that an unencrypted backup carries off intact. The Keychain costs thirty
// lines here and is the habit worth demonstrating.
//
// Nothing here reads a token. Tokens are sealed by the control plane and opaque to the
// device holding them, so what the interface says about one — who it names, which room, when
// it dies — comes from what the token server said when it issued it (`IssuedToken`), and a
// token pasted in by hand is just bytes.

import Foundation
import Security

/// Where secrets are kept between launches.
///
/// Filed under the host they belong to, which does two things. A credential is never
/// offered to a server it does not belong to — and that is not tidiness: a relay holding
/// verification keys refuses a token it cannot verify outright, rather than admitting the
/// session anonymously, so presenting the wrong one is worse than presenting none. And
/// switching servers stops destroying the secret for the one being left, so a laptop on the
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

    /// The enrollment the token server issued at sign-in, which this device asks for tokens
    /// with.
    ///
    /// Beside any token and under a name of its own, because the two are secrets of
    /// different lifetimes. A token expires in fifteen minutes; this is how the phone gets the
    /// next fifteen minutes, until the server revokes it or it runs out and the person signs
    /// in again. It is bound to this phone's key, so a copy of it is worth nothing elsewhere,
    /// and it is still a secret.
    static func loadEnrollment(for host: String) -> String? {
        load(for: "enrollment:" + host).map { String(decoding: $0, as: UTF8.self) }
    }

    static func saveEnrollment(_ enrollment: String, for host: String) {
        save(Data(enrollment.utf8), for: "enrollment:" + host)
    }

    /// What older builds kept under `join:` — a long-lived device credential for the
    /// control plane's `/join`, which no longer exists. Deleted rather than read.
    static func forgetJoinCredential(for host: String) {
        save(Data(), for: "join:" + host)
    }
}
