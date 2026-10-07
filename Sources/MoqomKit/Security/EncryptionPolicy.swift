// Whether a room insists on end-to-end encryption. It does, always.
//
// There is no switch: not in the application, not in the token, not in the
// room's policy on the control plane. A session publishes nothing until it
// holds a key — managed through MLS when the credentials carry a
// ``DeviceCredentials/keyDelivery``, or given to
// ``RoomSession/useEncryption(_:)`` — and drops every incoming object that does
// not open under one. A recorder or classifier that needs the media is a
// disclosed member of the room's group and decrypts on the tenant's side.
//
// Earlier versions read an `e2ee` claim from the token and let a value of
// `optional` permit plaintext. The claim is no longer read: a token cannot
// relax encryption whatever it says, and the control plane no longer mints
// one that tries.

import Foundation

/// Whether media in a room must be end-to-end encrypted: ``required``.
public struct EncryptionPolicy: Sendable, Hashable {
    /// Every object this session publishes is sealed with SFrame, and every
    /// object it receives must open under a key it holds.
    public static let required = EncryptionPolicy(allowsPlaintext: false)

    /// Media in the clear, for this package's loopback tests, which inspect the
    /// bytes on the relay. Internal: nothing an application calls and nothing
    /// a token says reaches it.
    static let plaintextForTesting = EncryptionPolicy(allowsPlaintext: true)

    let allowsPlaintext: Bool

    /// The name of the token claim this was once carried in, and the value
    /// the control plane still states there.
    public static let claim = "e2ee"

    public var rawValue: String { allowsPlaintext ? "plaintext-for-testing" : "required" }
}

extension DeviceCredentials {
    /// ``EncryptionPolicy/required``, whatever the token says.
    public var encryptionPolicy: EncryptionPolicy {
        plaintextForTesting ? .plaintextForTesting : .required
    }
}
