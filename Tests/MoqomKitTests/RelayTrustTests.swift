// The pin, without a socket.
//
// `NetworkQUICCarrier` is where a pin is applied and it cannot be tested here —
// it needs a handshake. The decision it delegates can be, and it is the part
// worth testing: a pinning policy that accidentally accepts everything looks
// identical to one that works, right up until it matters.

import Foundation
import Testing

@testable import MoqomKit

@Suite("Relay certificate trust")
struct RelayTrustTests {
    /// Stands in for a DER certificate. The bytes are irrelevant; only their
    /// hash is ever compared.
    private let certificate = Data("a certificate".utf8)
    private let impostor = Data("a different certificate".utf8)

    private func hash(_ data: Data) throws -> Data {
        try #require(RelayTrust.hash(of: data), "SHA-256 must be available")
    }

    /// System trust has no opinion of its own — it defers to the platform. That
    /// has to be distinguishable from a rejection, because a policy that
    /// answered "no" here would refuse every connection it was not asked about.
    @Test("system trust defers rather than deciding")
    func systemDefers() {
        #expect(RelayTrust.system.accepts(certificate: certificate) == nil)
    }

    @Test("a pinned certificate is accepted")
    func pinnedIsAccepted() throws {
        let trust = RelayTrust.pinned(certificateHashes: [try hash(certificate)])
        #expect(trust.accepts(certificate: certificate) == true)
    }

    @Test("anything but the pinned certificate is rejected")
    func othersAreRejected() throws {
        let trust = RelayTrust.pinned(certificateHashes: [try hash(certificate)])
        #expect(trust.accepts(certificate: impostor) == false)
    }

    /// Rotating a relay's certificate needs an overlap where both are trusted;
    /// with one pin at a time there is a window in which no client can connect.
    @Test("several pins allow a rotation")
    func rotation() throws {
        let trust = RelayTrust.pinned(
            certificateHashes: [try hash(certificate), try hash(impostor)]
        )
        #expect(trust.accepts(certificate: certificate) == true)
        #expect(trust.accepts(certificate: impostor) == true)
    }

    /// The reading to guard against is "no pins configured, so trust anything",
    /// which is how pinning gets silently disabled by a configuration mistake.
    @Test("an empty pin list trusts nothing")
    func emptyTrustsNothing() {
        let trust = RelayTrust.pinned(certificateHashes: [])
        #expect(trust.accepts(certificate: certificate) == false)
    }

    /// The base64 form is what `moqom-relay` prints, so a harness can pass its
    /// output through without decoding it.
    @Test("base64 hashes are accepted in the form the relay prints")
    func base64Form() throws {
        let encoded = try hash(certificate).base64EncodedString()
        let trust = RelayTrust.pinned(base64CertificateHashes: [encoded])
        #expect(trust.accepts(certificate: certificate) == true)
    }

    /// A mistyped hash must not widen the policy. It is dropped, and since an
    /// empty list trusts nothing, the result is a failed handshake rather than an
    /// unpinned one.
    @Test("an unparseable hash narrows rather than widens")
    func malformedBase64() {
        let trust = RelayTrust.pinned(base64CertificateHashes: ["not base64 at all!!"])
        #expect(trust.accepts(certificate: certificate) == false)
    }

    /// A pin has to be over the whole DER certificate: that is what WebTransport
    /// defines and what the relay prints. Hashing anything else produces a value
    /// of the right length that never matches.
    @Test("a hash of the wrong length cannot match")
    func wrongLength() {
        let trust = RelayTrust.pinned(certificateHashes: [Data([0x01, 0x02, 0x03])])
        #expect(trust.accepts(certificate: certificate) == false)
    }
}
