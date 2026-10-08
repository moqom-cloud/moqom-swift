// The socket underneath a direct endpoint, and the choice of who provides it.
//
// ``DirectEndpoint`` is MOQT: offers, roles, SETUP with a token and a proof,
// the peer check, and the dialler's final word. Below it is one UDP port that
// does STUN, sends NAT probes, and carries pinned, mutually authenticated
// QUIC. That port is a ``DirectSocket``, and there are two:
//
// - Network.framework's (``DirectBackend/networkFramework``, the default). It
//   cannot share a port between a QUIC listener and plain UDP flows without
//   the flows taking the listener's packets, so it probes only in a short
//   burst on the accepting side and releases its listener before it dials.
// - Rust's, from `moqom-direct-ffi` through the `MoqomDirectRust` module. One
//   socket does everything, so it probes on both sides for the whole
//   establishment, as the Rust SDK does.
//
// Both speak the same QUIC and TLS on the wire, so either can be at either end.

import CryptoKit
import Foundation

/// How a direct socket is bound.
public struct DirectSocketOptions: Sendable {
    /// The UDP port to bind on every interface. Zero picks one.
    public var port: UInt16
    /// The single ALPN offered and accepted.
    public var alpn: String
    /// How long a connection may be silent before QUIC declares it dead.
    public var idleTimeout: Duration
    /// A STUN server to ask for the socket's public address, from the socket
    /// itself, during bind. One that does not answer is not an error.
    public var stun: (host: String, port: UInt16)?
    /// How long to wait for the STUN server.
    public var stunTimeout: Duration
    /// How long an establishment may take; a backend may hold an inbound
    /// connection nobody has claimed for this long.
    public var patience: Duration

    public init(
        port: UInt16 = 0,
        alpn: String,
        idleTimeout: Duration,
        stun: (host: String, port: UInt16)? = nil,
        stunTimeout: Duration = .seconds(1),
        patience: Duration = .seconds(5)
    ) {
        self.port = port
        self.alpn = alpn
        self.idleTimeout = idleTimeout
        self.stun = stun
        self.stunTimeout = stunTimeout
        self.patience = patience
    }
}

/// Makes the socket a ``DirectEndpoint`` runs on.
public protocol DirectSocketProvider: Sendable {
    /// Bind a port, make a throwaway certificate for it, and ask the STUN
    /// server, if any, for its public address.
    ///
    /// - Throws: ``DirectEndpointError/bind(_:)`` or
    ///   ``DirectEndpointError/identity(_:)``.
    func bind(_ options: DirectSocketOptions) async throws(DirectEndpointError) -> any DirectSocket
}

/// One UDP port with one certificate, for reaching one peer.
///
/// QUIC on it is mutual TLS with the peer pinned to the SHA-256 of its leaf
/// certificate, and no other check: the pin is what the sealed offer vouches
/// for.
public protocol DirectSocket: AnyObject, Sendable {
    /// The bound port, never zero.
    var port: UInt16 { get }

    /// This socket's DER leaf certificate.
    var certificateDER: Data { get }

    /// SHA-256 of ``certificateDER``, which an offer carries. Thirty-two bytes.
    var certificateFingerprint: Data { get }

    /// base64url of ``certificateFingerprint``, which a peer's proof of
    /// possession must name.
    var certificateIdentity: String { get }

    /// The public address the STUN server reported during bind, if any.
    var reflexive: DirectCandidate? { get }

    /// Whether this socket can probe the peer while it dials as well as while
    /// it accepts. One that cannot is only asked to probe when accepting.
    var probesWhileDialling: Bool { get }

    /// Probe every candidate from this port every `interval`, to open this
    /// side's NAT for the peer, until ``stopPunching()``. Starting again
    /// replaces the targets. A backend may stop on its own sooner.
    func startPunching(_ candidates: [DirectCandidate], interval: Duration)
    func stopPunching()

    /// Dial every candidate from this port; the first handshake with a peer
    /// presenting the certificate `fingerprint` names wins.
    ///
    /// - Throws: ``MoqomError/transport(_:)`` if none completed in `timeout`.
    func dial(
        _ candidates: [DirectCandidate],
        pinning fingerprint: Data,
        timeout: Duration
    ) async throws(MoqomError) -> any QUICCarrier

    /// Wait for the peer presenting the certificate `fingerprint` names to
    /// connect. Handshakes from anyone else fail and are ignored.
    ///
    /// Ends with an error when the calling task is cancelled.
    func accept(pinning fingerprint: Data, timeout: Duration) async throws(MoqomError) -> any QUICCarrier

    /// Stop probing and accepting. What a carrier already returned does after
    /// this is the backend's to say.
    func close()
}

public extension DirectSocket {
    var certificateFingerprint: Data { Data(SHA256.hash(data: certificateDER)) }
    var certificateIdentity: String { DirectCertificate.identity(of: certificateFingerprint) }
}

/// Which socket direct paths run on.
///
/// Chosen once, when the session is made (see
/// ``MoqomSession/init(transport:credentials:tenant:reconnectPolicy:logger:directBackend:clock:sleeper:)``),
/// or per endpoint in ``DirectEndpoint/bind(_:eligibility:exposure:backend:)``.
public enum DirectBackend: Sendable {
    /// Network.framework. Always available; probes only in a short burst.
    case networkFramework
    /// Anything else, for instance `.rust` from the `MoqomDirectRust` module.
    case custom(any DirectSocketProvider)

    #if canImport(Network)
        /// The provider this backend names.
        public var provider: any DirectSocketProvider {
            switch self {
            case .networkFramework: NetworkDirectSocketProvider()
            case let .custom(provider): provider
            }
        }
    #endif
}
