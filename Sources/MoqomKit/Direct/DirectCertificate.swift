// The certificate a direct endpoint presents: made on the spot, held in memory,
// and trusted by exactly one peer because that peer was told its hash.
//
// The model is `moqom_client::direct`'s, so either SDK can be on either end:
//
// - A fresh P-256 key and a self-signed certificate per endpoint, named
//   `moqom-direct`. Nothing checks the name, the issuer or the dates; TLS needs
//   a certificate, and the only property anybody relies on is its SHA-256.
// - That SHA-256 travels in the sealed offer. Each side accepts the handshake
//   only if the peer's leaf certificate hashes to the value the peer's offer
//   named, and TLS itself checks the peer holds the certificate's key. Nobody
//   outside the room can read or forge an offer, so nobody outside the room can
//   complete a handshake as either peer.
// - base64url of the same hash is the certificate *identity* a proof of
//   possession is bound to: the dialler's proof names the acceptor's
//   certificate and the acceptor's proof names the dialler's, as a relay's
//   proof names the relay's.
//
// Built by hand rather than through a library because the platform has no API
// that makes a certificate, and the structure needed is small and fixed. It
// stays in memory: `SecIdentityCreate` pairs it with a key that never touches
// the Keychain, so nothing is left behind when the endpoint goes.

import CryptoKit
import Foundation
import Security

/// An ephemeral TLS identity for one direct endpoint.
struct DirectCertificate: @unchecked Sendable {
    /// The certificate's subject and SAN. Sent as the TLS server name and
    /// checked by nobody, matching the Rust side's `SERVER_NAME`.
    static let serverName = "moqom-direct"

    /// The certificate, DER.
    let der: Data

    /// SHA-256 of ``der``, which an offer carries.
    let fingerprint: Data

    /// base64url of ``fingerprint``, which a peer's proof must name.
    let identity: String

    /// The certificate and its key, as TLS wants them.
    ///
    /// `@unchecked Sendable` above is for this: a `SecIdentity` is an immutable
    /// CoreFoundation object and safe to share, but is not annotated as such.
    let secIdentity: SecIdentity

    /// A new key and a certificate for it.
    ///
    /// - Throws: ``DirectEndpointError/identity(_:)`` if the platform refuses
    ///   the key or the certificate, which is a platform fault rather than
    ///   anything a caller can fix.
    static func generate(now: Date = Date()) throws(DirectEndpointError) -> DirectCertificate {
        let key = P256.Signing.PrivateKey()
        let tbs = tbsCertificate(publicKey: key.publicKey, now: now)
        guard let signature = try? key.signature(for: tbs).derRepresentation else {
            throw .identity("signing the certificate failed")
        }
        let der = DER.sequence([
            tbs,
            DER.sequence([DER.oid(OID.ecdsaWithSHA256)]),
            DER.bitString(signature),
        ])

        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw .identity("the platform does not accept the certificate")
        }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 256,
        ]
        guard let secKey = SecKeyCreateWithData(
            key.x963Representation as CFData,
            attributes as CFDictionary,
            nil
        ) else {
            throw .identity("the platform does not accept the key")
        }
        guard let identity = SecIdentityCreate(nil, certificate, secKey) else {
            throw .identity("the certificate and key do not pair")
        }
        let fingerprint = Data(SHA256.hash(data: der))
        return DirectCertificate(
            der: der,
            fingerprint: fingerprint,
            identity: fingerprint.base64URLEncodedString,
            secIdentity: identity
        )
    }

    /// The identity a fingerprint names, as a proof spells it.
    static func identity(of fingerprint: Data) -> String {
        fingerprint.base64URLEncodedString
    }

    /// Whether `trust` presents the certificate `fingerprint` names, and only
    /// that: the leaf is hashed and every other certificate is ignored, since
    /// an intermediate would vouch for whatever it signed.
    static func leaf(of trust: sec_trust_t, matches fingerprint: Data) -> Bool {
        let reference = sec_trust_copy_ref(trust).takeRetainedValue()
        guard
            let chain = SecTrustCopyCertificateChain(reference) as? [SecCertificate],
            let leaf = chain.first
        else { return false }
        let presented = Data(SHA256.hash(data: SecCertificateCopyData(leaf) as Data))
        return constantTimeEqual(presented, fingerprint)
    }

    // MARK: - The certificate's contents

    private enum OID {
        static let ecdsaWithSHA256: [UInt64] = [1, 2, 840, 10045, 4, 3, 2]
        static let ecPublicKey: [UInt64] = [1, 2, 840, 10045, 2, 1]
        static let prime256v1: [UInt64] = [1, 2, 840, 10045, 3, 1, 7]
        static let commonName: [UInt64] = [2, 5, 4, 3]
        static let subjectAltName: [UInt64] = [2, 5, 29, 17]
    }

    /// An X.509 v3 `TBSCertificate`, as every verifier involved parses one.
    ///
    /// v3 with a subject alternative name because webpki, which the Rust peer
    /// verifies handshake signatures with, refuses anything older. Valid from an
    /// hour ago, for clocks that disagree, to a week ahead; neither side checks
    /// the dates, so these only need to parse.
    private static func tbsCertificate(publicKey: P256.Signing.PublicKey, now: Date) -> Data {
        var serial = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, serial.count, &serial)
        // Positive and minimal: a leading zero bit, and never a leading zero
        // byte, which DER forbids for an INTEGER.
        serial[0] = (serial[0] & 0x7F) | 0x40

        let name = DER.sequence([
            DER.set([DER.sequence([DER.oid(OID.commonName), DER.utf8(serverName)])]),
        ])
        let algorithm = DER.sequence([DER.oid(OID.ecdsaWithSHA256)])
        let validity = DER.sequence([
            DER.utcTime(now.addingTimeInterval(-3600)),
            DER.utcTime(now.addingTimeInterval(7 * 24 * 3600)),
        ])
        let subjectPublicKeyInfo = DER.sequence([
            DER.sequence([DER.oid(OID.ecPublicKey), DER.oid(OID.prime256v1)]),
            DER.bitString(publicKey.x963Representation),
        ])
        let alternativeNames = DER.sequence([
            DER.contextPrimitive(2, Data(serverName.utf8)),
        ])
        let extensions = DER.contextConstructed(3, DER.sequence([
            DER.sequence([DER.oid(OID.subjectAltName), DER.octetString(alternativeNames)]),
        ]))

        return DER.sequence([
            DER.contextConstructed(0, DER.integer(Data([2]))),
            DER.integer(Data(serial)),
            algorithm,
            name,
            validity,
            name,
            subjectPublicKeyInfo,
            extensions,
        ])
    }
}

/// Compare without leaking where two values first differ, as the relay does
/// for every value an admission decision rests on.
func constantTimeEqual(_ left: Data, _ right: Data) -> Bool {
    guard left.count == right.count else { return false }
    return zip(left, right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
}

/// The handful of DER encodings a certificate needs.
private enum DER {
    static func element(_ tag: UInt8, _ content: Data) -> Data {
        var out = Data([tag])
        let count = content.count
        if count < 0x80 {
            out.append(UInt8(count))
        } else {
            var length = [UInt8]()
            var remaining = count
            while remaining > 0 {
                length.insert(UInt8(remaining & 0xFF), at: 0)
                remaining >>= 8
            }
            out.append(0x80 | UInt8(length.count))
            out.append(contentsOf: length)
        }
        out.append(content)
        return out
    }

    static func sequence(_ items: [Data]) -> Data { element(0x30, items.reduce(Data(), +)) }
    static func set(_ items: [Data]) -> Data { element(0x31, items.reduce(Data(), +)) }
    static func integer(_ bytes: Data) -> Data { element(0x02, bytes) }
    static func octetString(_ bytes: Data) -> Data { element(0x04, bytes) }
    static func utf8(_ text: String) -> Data { element(0x0C, Data(text.utf8)) }
    static func bitString(_ bytes: Data) -> Data { element(0x03, Data([0]) + bytes) }
    static func contextPrimitive(_ number: UInt8, _ bytes: Data) -> Data { element(0x80 | number, bytes) }
    static func contextConstructed(_ number: UInt8, _ inner: Data) -> Data { element(0xA0 | number, inner) }

    static func oid(_ arcs: [UInt64]) -> Data {
        var body = Data([UInt8(arcs[0] * 40 + arcs[1])])
        for arc in arcs.dropFirst(2) {
            var chunk = [UInt8(arc & 0x7F)]
            var remaining = arc >> 7
            while remaining > 0 {
                chunk.insert(UInt8(remaining & 0x7F) | 0x80, at: 0)
                remaining >>= 7
            }
            body.append(contentsOf: chunk)
        }
        return element(0x06, body)
    }

    /// `YYMMDDHHMMSSZ`, which X.509 requires for any date before 2050.
    static func utcTime(_ date: Date) -> Data {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let text = String(
            format: "%02d%02d%02d%02d%02d%02dZ",
            (parts.year ?? 2000) % 100, parts.month ?? 1, parts.day ?? 1,
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0
        )
        return element(0x17, Data(text.utf8))
    }
}
