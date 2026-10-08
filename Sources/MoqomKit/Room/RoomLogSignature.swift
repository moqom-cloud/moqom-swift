// Signing the room control log.
//
// The log says who may publish, who is muted, whether the room has ended — the
// state a client acts on as authorisation. The relay that carries it is not
// trusted with it, so every entry is signed with ML-DSA-65 by the room's
// authority, which is the control plane, and a client applies nothing that does
// not verify against the authority's published keys. A relay that forwards the
// log can drop entries, which the sequence numbers already surface as a hole;
// it cannot write one, alter one, or move one from another room into this one.
//
// The payload is unchanged JSON. The signature rides beside it as an object
// property, so a reader that only files the log — a recorder — keeps reading it
// as before. What is signed is the entry under a fixed context naming the
// tenant and room, which keeps a log signature from ever being mistaken for a
// token's (a JWS signs `header.payload`, which never begins with the context)
// and an entry signed for one room from verifying in another.

import CryptoKit
import Foundation
import MoqomCore

/// The authority's key for signing a room's control log.
///
/// Held by the control plane, or by a self-hosted deployment's own service. A
/// participant's device never holds one: a client that could sign the log
/// could grant itself the stage.
public struct RoomLogSigner: Sendable {
    /// The `kid` readers look the key up by.
    public let id: String
    private let key: MLDSA65.PrivateKey

    /// From the 32-byte FIPS 204 seed the control plane keeps.
    ///
    /// - Parameter id: Defaults to the control plane's own derivation, the
    ///   first eight bytes of the public key's SHA-256 in base64url, so a seed
    ///   names the same key wherever it is loaded.
    public init(seed: Data, id: String? = nil) throws {
        key = try MLDSA65.PrivateKey(seedRepresentation: seed, publicKey: nil)
        self.id = id ?? Self.keyID(key.publicKey.rawRepresentation)
    }

    /// What a reader verifies this signer's entries with.
    public var verificationKey: DirectVerificationKey {
        DirectVerificationKey(id: id, key: key.publicKey.rawRepresentation, algorithm: .mlDSA65)
    }

    /// The signature property for `entry`, an encoded ``RoomUpdate``, in the
    /// room it is published to.
    func sign(_ entry: Data, tenant: TenantID, room: RoomID) throws -> Data {
        let signature = try key.signature(
            for: RoomLogSignature.message(entry, tenant: tenant, room: room)
        )
        return RoomLogSignature.property(keyID: id, signature: signature)
    }

    private static func keyID(_ publicKey: Data) -> String {
        Data(SHA256.hash(data: publicKey).prefix(8)).base64URLEncodedString
    }
}

enum RoomLogSignature {
    /// Prefixes every signed message. Versioned, so a change to what is signed
    /// is a different context rather than a reinterpretation of the old one.
    static let context = Data("moqom room log v1".utf8)

    /// `context ‖ 0 ‖ tenant ‖ 0 ‖ room ‖ 0 ‖ entry`. Neither identifier can
    /// contain a NUL, so the boundaries cannot be shifted.
    static func message(_ entry: Data, tenant: TenantID, room: RoomID) -> Data {
        var message = context
        message.append(0)
        message.append(Data(tenant.value.utf8))
        message.append(0)
        message.append(Data(room.value.utf8))
        message.append(0)
        message.append(entry)
        return message
    }

    /// `kid length (one byte) ‖ kid ‖ signature`.
    static func property(keyID: String, signature: Data) -> Data {
        let id = Data(keyID.utf8)
        precondition(id.count <= 255, "a key ID is at most 255 bytes")
        var property = Data([UInt8(id.count)])
        property.append(id)
        property.append(signature)
        return property
    }

    /// Whether `property` is a valid authority signature over `entry`.
    ///
    /// ML-DSA-65 only. The log was never signed with anything else, so an
    /// Ed25519 key kept for verifying old tokens verifies no entry.
    static func verifies(
        _ property: Data?,
        entry: Data,
        tenant: TenantID,
        room: RoomID,
        keys: [DirectVerificationKey]
    ) -> Bool {
        guard let property, let length = property.first else { return false }
        let bytes = Data(property)
        let idEnd = 1 + Int(length)
        guard bytes.count > idEnd,
              let id = String(data: bytes[1 ..< idEnd], encoding: .utf8),
              let key = keys.first(where: { $0.id == id && $0.algorithm == .mlDSA65 })
        else { return false }
        return key.verifies(
            Data(bytes[idEnd...]),
            for: message(entry, tenant: tenant, room: room)
        )
    }
}
