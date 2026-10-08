// The key this sample encrypts its media with.
//
// Every MOQOM room requires end-to-end encryption unless its backend has turned
// that off, and a session with no key refuses to publish into one. So the sample
// sets a key on every room it joins, the way an application has to.
//
// Where the key comes from is the part a real application does differently, and
// this is not a model for it. Here it is derived from a passphrase both phones
// already know and the room's name, so two phones running this sample find each
// other's media with nothing to set up. The default passphrase is in this file
// and therefore public: it keeps a demo's media away from the relay, not away
// from anybody who has read the source. An application distributes keys from
// its own server to the members it admits, or uses MLS.

import CryptoKit
import Foundation
import MoqomCore
import MoqomKit

enum RoomKey {
    /// Used when `--room-key` is not given. Not a secret; see above.
    static let samplePassphrase = "moqom-sample-not-a-secret"

    /// The encryption for one room, from a passphrase.
    ///
    /// The room's name is the salt, so the same passphrase gives different keys
    /// in different rooms and a key learned in one opens nothing in another.
    /// Every participant derives the same base key; each sends under its own
    /// random key ID. A real deployment rotates; this sample does not.
    static func encryption(room: RoomID, passphrase: String = samplePassphrase) -> RoomEncryption {
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(passphrase.utf8)),
            salt: Data(room.value.utf8),
            info: Data("moqom-sample room key".utf8),
            outputByteCount: 32
        )
        let base = derived.withUnsafeBytes { Data($0) }
        // 32 bytes is the default suite's key length, so this cannot throw.
        return try! .sharedKey(base)
    }
}
