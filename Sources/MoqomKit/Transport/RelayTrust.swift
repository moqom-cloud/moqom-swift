// Deciding whether the relay on the other end is the right one.
//
// The default is the system's: a publicly trusted certificate for the host that
// was dialled, validated by the platform, which is what a shipping app talking
// to a production relay wants and what it should be hard to accidentally turn
// off.
//
// The other two cases are real and both need an answer. A relay running on a
// laptop or in a test harness has a certificate nobody trusts, and a self-hosted
// deployment may have one signed by a private CA that the device has no reason
// to know about. Neither can use the system default, and the wrong response to
// that is to accept anything — which is what "skip verification for
// development" flags turn into once they exist, because nothing distinguishes a
// development build from a shipped one at runtime.
//
// So the escape hatch is a pin: the exact certificate, by hash, and nothing
// else. It is stricter than the system default rather than weaker, it cannot be
// widened by accident, and it is useless to an attacker who does not already
// have the certificate.

import Foundation
import MoqomCore

#if canImport(CryptoKit)
    import CryptoKit
#endif

/// How to decide whether to trust a relay's certificate.
public struct RelayTrust: Sendable {
    /// What a policy accepts.
    enum Policy: Sendable {
        /// Whatever the platform trusts, for the host that was dialled.
        case system
        /// Exactly these certificates, by SHA-256 of their DER encoding.
        case pinned([Data])
    }

    let policy: Policy

    /// Platform validation. The default, and what production should use.
    public static let system = RelayTrust(policy: .system)

    /// Trust exactly the certificates with these SHA-256 hashes.
    ///
    /// The hash is over the whole DER certificate, which is what WebTransport's
    /// `serverCertificateHashes` is defined against and what `moqom-relay`
    /// prints when it generates one. Hashing the public key instead produces a
    /// value of the right length that never matches, and the symptom is a
    /// handshake failure with nothing to say which side is wrong.
    ///
    /// Several hashes are allowed so a relay can be rotated: publish the new
    /// certificate's hash alongside the old one, roll the relay, then drop the
    /// old hash. With a single pin that sequence has a window where clients
    /// cannot connect.
    ///
    /// - Note: An empty list trusts nothing and every handshake fails. That is
    ///   deliberate — the alternative reading, "no pins, so trust anything", is
    ///   how pinning gets silently disabled.
    public static func pinned(certificateHashes: [Data]) -> RelayTrust {
        RelayTrust(policy: .pinned(certificateHashes))
    }

    /// Trust exactly the certificates with these base64-encoded SHA-256 hashes.
    ///
    /// The form `moqom-relay` prints, so a harness can pass its output straight
    /// through. Unparseable entries are dropped rather than throwing, and since
    /// an empty pin list trusts nothing, a typo fails the handshake instead of
    /// weakening it.
    public static func pinned(base64CertificateHashes: [String]) -> RelayTrust {
        pinned(certificateHashes: base64CertificateHashes.compactMap { Data(base64Encoded: $0) })
    }

    /// Whether `certificate`, a DER-encoded certificate, satisfies this policy.
    ///
    /// Returns `nil` for ``system``, meaning "no opinion, ask the platform".
    /// Distinguishing that from `false` matters: a policy that answered `false`
    /// would reject every connection it was not asked about.
    func accepts(certificate: Data) -> Bool? {
        guard case let .pinned(hashes) = policy else { return nil }
        return Self.hash(of: certificate).map { digest in
            // Constant-time-ish by construction: these are public values, so
            // there is no secret to leak by comparing them normally, but the
            // count check first avoids comparing a short hash against a long one
            // byte by byte.
            hashes.contains { $0.count == digest.count && $0 == digest }
        } ?? false
    }

    /// SHA-256 of `bytes`, or `nil` where no hash implementation is available.
    ///
    /// `nil` is treated as a rejection by ``accepts(certificate:)``, because a
    /// platform that cannot hash cannot pin, and silently falling back to system
    /// trust would turn a stricter policy into a looser one.
    static func hash(of bytes: Data) -> Data? {
        #if canImport(CryptoKit)
            Data(SHA256.hash(data: bytes))
        #else
            nil
        #endif
    }
}
