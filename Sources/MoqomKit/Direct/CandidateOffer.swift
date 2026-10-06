// Candidate offers: where to reach a peer, and which certificate it will show.
//
// An offer travels through the relay on a room track, and the relay must not be
// able to read it: the addresses in it are exactly what direct mode is careful
// about, and the certificate fingerprint is what stops anybody else answering
// for the peer. So it is sealed with AES-256-GCM under a key derived from the
// room's end-to-end secret. Whoever cannot decrypt the room's media cannot read
// an offer, and cannot forge one either.
//
// The bytes are the same as `moqom_client::direct::CandidateOffer`'s, so an
// offer from either SDK opens in the other:
//
//     version(1) | len(1) from | len(1) to | certificate sha-256(32)
//                | count(1) | count * (family(1) address(4|16) port(2))
//
// sealed as `"MQD1" | nonce(12) | ciphertext | tag(16)`, with `"MQD1"` and the
// room's identifier authenticated alongside so an offer sealed for one room does
// not open in another that happens to share a secret.

import CryptoKit
import Foundation
import MoqomCore

/// The room's end-to-end secret, as far as candidate offers are concerned.
///
/// Supplied by whatever manages the room's encryption: for an MLS room, an
/// exporter secret from the participants' group. It must be a secret viewers do
/// not hold, since an offer carries the participants' network addresses.
public struct DirectRoomSecret: Sendable {
    fileprivate static let magic = Data("MQD1".utf8)
    private static let salt = Data("moqom direct candidate offer v1".utf8)

    fileprivate let key: SymmetricKey
    fileprivate let room: Data

    /// Derive the offer key for `room` from `secret`.
    ///
    /// `room` must be the same string on every participant, in every SDK.
    /// ``init(secret:tenant:room:)`` spells it the conventional way.
    public init(secret: Data, room: String) throws(DirectOfferError) {
        guard secret.count >= 16 else { throw .shortSecret }
        self.room = Data(room.utf8)
        key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            salt: Self.salt,
            info: self.room,
            outputByteCount: 32
        )
    }

    /// The offer key for a room, named as `tenant/room`.
    public init(secret: Data, tenant: TenantID, room: RoomID) throws(DirectOfferError) {
        try self.init(secret: secret, room: "\(tenant.value)/\(room.value)")
    }

    fileprivate var aad: Data { Self.magic + room }
}

/// One address a peer can be reached at.
public struct DirectCandidate: Hashable, Sendable, CustomStringConvertible {
    /// The address as raw bytes: four for IPv4, sixteen for IPv6.
    public let address: [UInt8]
    public let port: UInt16

    public init?(address: [UInt8], port: UInt16) {
        guard address.count == 4 || address.count == 16 else { return nil }
        self.address = address
        self.port = port
    }

    /// Parse a numeric address, `"192.0.2.1"` or `"2001:db8::1"`.
    public init?(host: String, port: UInt16) {
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            self.address = withUnsafeBytes(of: &v4) { Array($0) }
            self.port = port
            return
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 {
            self.address = withUnsafeBytes(of: &v6) { Array($0) }
            self.port = port
            return
        }
        return nil
    }

    public var isIPv6: Bool { address.count == 16 }

    /// The address in its usual text form.
    public var host: String {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let family = isIPv6 ? AF_INET6 : AF_INET
        let written = address.withUnsafeBytes { raw in
            inet_ntop(family, raw.baseAddress, &buffer, socklen_t(buffer.count))
        }
        guard written != nil else { return "" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    public var description: String { isIPv6 ? "[\(host)]:\(port)" : "\(host):\(port)" }
}

/// Where one participant can be reached, addressed to one other.
public struct CandidateOffer: Hashable, Sendable {
    /// More than any real host has, and few enough that an offer stays one
    /// packet.
    public static let maximumCandidates = 16

    private static let version: UInt8 = 1

    /// The sender, as ``DirectParticipant/name(of:)`` spells it.
    public var from: String

    /// The one participant this offer is for.
    public var to: String

    /// SHA-256 of the certificate the sender's endpoint will present.
    public var certificate: Data

    /// Addresses to try, best first.
    public var candidates: [DirectCandidate]

    public init(from: String, to: String, certificate: Data, candidates: [DirectCandidate]) {
        self.from = from
        self.to = to
        self.certificate = certificate
        self.candidates = candidates
    }

    /// Seal this offer for the room.
    public func sealed(with secret: DirectRoomSecret) throws(DirectOfferError) -> Data {
        try sealed(with: secret, nonce: AES.GCM.Nonce())
    }

    func sealed(with secret: DirectRoomSecret, nonce: AES.GCM.Nonce) throws(DirectOfferError) -> Data {
        let plain = try encoded()
        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.seal(plain, using: secret.key, nonce: nonce, authenticating: secret.aad)
        } catch {
            throw .sealingFailed
        }
        return DirectRoomSecret.magic + Data(nonce) + box.ciphertext + box.tag
    }

    /// Open an offer sealed for the room, refusing one not addressed to `me`.
    public init(opening sealed: Data, with secret: DirectRoomSecret, for me: String) throws(DirectOfferError) {
        let bytes = [UInt8](sealed)
        let magic = [UInt8](DirectRoomSecret.magic)
        guard bytes.starts(with: magic) else { throw .notAnOffer }
        let rest = bytes.dropFirst(magic.count)
        guard rest.count >= 12 + 16 else { throw .truncated }
        let nonceBytes = rest.prefix(12)
        let ciphertext = rest.dropFirst(12).dropLast(16)
        let tag = rest.suffix(16)

        let plain: Data
        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: Data(nonceBytes)),
                ciphertext: Data(ciphertext),
                tag: Data(tag)
            )
            plain = try AES.GCM.open(box, using: secret.key, authenticating: secret.aad)
        } catch {
            throw .doesNotOpen
        }

        self = try Self.decoded([UInt8](plain))
        guard to == me else { throw .addressedToSomebodyElse }
    }

    private func encoded() throws(DirectOfferError) -> Data {
        guard candidates.count <= Self.maximumCandidates else { throw .tooManyCandidates }
        guard certificate.count == 32 else { throw .malformed("a certificate digest is 32 bytes") }
        var out: [UInt8] = [Self.version]
        for name in [from, to] {
            let bytes = Array(name.utf8)
            guard bytes.count <= 255 else { throw .malformed("a name is longer than 255 bytes") }
            out.append(UInt8(bytes.count))
            out += bytes
        }
        out += certificate
        out.append(UInt8(candidates.count))
        for candidate in candidates {
            out.append(candidate.isIPv6 ? 6 : 4)
            out += candidate.address
            out.append(UInt8(candidate.port >> 8))
            out.append(UInt8(candidate.port & 0xFF))
        }
        return Data(out)
    }

    private static func decoded(_ bytes: [UInt8]) throws(DirectOfferError) -> Self {
        var cursor = bytes[...]
        func take(_ count: Int) throws(DirectOfferError) -> ArraySlice<UInt8> {
            guard cursor.count >= count else { throw .truncated }
            let head = cursor.prefix(count)
            cursor = cursor.dropFirst(count)
            return head
        }
        func name() throws(DirectOfferError) -> String {
            let length = Int(try take(1).first!)
            guard let text = String(validating: try take(length), as: UTF8.self) else {
                throw .malformed("a name is not UTF-8")
            }
            return text
        }

        guard try take(1).first == version else { throw .malformed("unknown offer version") }
        let from = try name()
        let to = try name()
        let certificate = Data(try take(32))
        let count = Int(try take(1).first!)
        guard count <= maximumCandidates else { throw .tooManyCandidates }
        var candidates: [DirectCandidate] = []
        for _ in 0 ..< count {
            let length: Int
            switch try take(1).first! {
            case 4: length = 4
            case 6: length = 16
            default: throw .malformed("unknown address family")
            }
            let address = Array(try take(length))
            let port = try take(2)
            let value = UInt16(port[port.startIndex]) << 8 | UInt16(port[port.startIndex + 1])
            candidates.append(DirectCandidate(address: address, port: value)!)
        }
        guard cursor.isEmpty else { throw .malformed("trailing bytes") }
        return Self(from: from, to: to, certificate: certificate, candidates: candidates)
    }
}

/// Why an offer could not be made or opened.
public enum DirectOfferError: Error, Hashable, Sendable {
    case shortSecret
    case notAnOffer
    case truncated
    case doesNotOpen
    case addressedToSomebodyElse
    case tooManyCandidates
    case sealingFailed
    case malformed(String)
}

/// How participants are named on a direct path.
public enum DirectParticipant {
    /// `user/device`: the name an offer is addressed by and the one a peer's
    /// token must match.
    public static func name(of identity: ParticipantIdentity) -> String {
        "\(identity.username.value)/\(identity.device.value)"
    }
}
