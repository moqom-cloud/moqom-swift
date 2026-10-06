// Whether a room insists on end-to-end encryption.
//
// The default is that it does, and the asymmetry is the whole design. A room is
// encrypted unless somebody with authority over it said otherwise, in a place
// that is written down: the control plane records the change in the room's audit
// log and states the result in every token it mints afterwards, as the `e2ee`
// claim. The SDK reads that claim and nothing else. There is no client-side
// switch, because a switch an application can flip is a switch a careless one
// will, and the person on the other end of the call never finds out.
//
// Read from the token without verifying its signature, which is safe for the
// direction it is used in. A client that rewrote its own token to say `optional`
// would present a token the relay refuses outright, so the only thing forgery
// can buy is a session that never starts; and a claim that cannot be read is
// treated as `required`, so every way of getting this wrong fails closed.

import Foundation

/// Whether media in a room must be end-to-end encrypted.
public enum EncryptionPolicy: String, Sendable, Hashable {
    /// Every object this session publishes is sealed with SFrame, and every
    /// object it receives must open under a key it holds.
    ///
    /// The default, and what a token with no `e2ee` claim means. A session in a
    /// room like this refuses to publish until ``RoomSession/useEncryption(_:)``
    /// has been called, and drops incoming media it cannot decrypt.
    case required

    /// The room's backend has turned end-to-end encryption off.
    ///
    /// Only ever learned from a token. Encryption still applies when a session
    /// configures it; this only permits media to travel in the clear when it
    /// does not.
    case optional

    /// The name of the token claim this is carried in.
    public static let claim = "e2ee"

    /// The policy a token asserts, or ``required`` when it asserts none.
    ///
    /// Anything other than an exact `"optional"` is required: an absent claim,
    /// a token that is not a compact JWS, a claim with a value this build does
    /// not recognise. A newer control plane that invents a stricter mode should
    /// not have an older SDK read it as permission.
    public init(token: Data) {
        self = Self.claimed(in: token) == Self.optional.rawValue ? .optional : .required
    }

    private static func claimed(in token: Data) -> String? {
        let parts = token.split(separator: UInt8(ascii: "."), omittingEmptySubsequences: false)
        guard parts.count == 3, let payload = base64URLDecoded(parts[1]) else { return nil }
        guard
            let object = try? JSONSerialization.jsonObject(with: payload),
            let claims = object as? [String: Any]
        else { return nil }
        return claims[claim] as? String
    }

    private static func base64URLDecoded(_ segment: Data.SubSequence) -> Data? {
        guard var text = String(data: Data(segment), encoding: .ascii) else { return nil }
        text = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        return Data(base64Encoded: text)
    }
}

extension DeviceCredentials {
    /// What the token in these credentials says about encryption.
    ///
    /// ``EncryptionPolicy/required`` unless the control plane minted the token
    /// for a room whose policy an administrator set to optional.
    public var encryptionPolicy: EncryptionPolicy { EncryptionPolicy(token: token) }
}
