// A direct, verified MOQT session between two devices, beside the relay.
//
// The Swift side of `moqom_client::direct::DirectEndpoint`, and wire-compatible
// with it: the same offer, the same roles, the same TLS, the same SETUP with a
// token and a proof, the same refusals, and the same final word from the
// dialler. Either SDK can be either end.
//
// The shape, for a reader arriving here first:
//
// - Each side binds one UDP port, makes a throwaway certificate, and offers
//   the port's addresses and the certificate's fingerprint to the one peer
//   it is for, sealed and sent through the relay (``DirectOffers``).
// - The side whose fingerprint sorts lower dials; the other accepts. Both
//   know which without asking, which is what lets them start at once.
// - TLS is mutual and pinned both ways to the offers. A certificate proves
//   only that the peer is whoever sent the offer; who that is comes from its
//   MOQOM token, checked here exactly as a relay checks it.
// - The dialler goes first in SETUP and the acceptor answers only once the
//   dialler checked out. The dialler then opens one empty unidirectional
//   stream, which tells the acceptor its own credentials were accepted.
//   Neither side keeps a session the other refused.
//
// Nothing here touches the relay session. A failure of any kind leaves the
// caller where it started, on the relay.

import CryptoKit
import Foundation
import MoqomWire

#if canImport(Network)
    import Network
#endif

/// How a direct endpoint behaves.
public struct DirectConfiguration: Sendable {
    /// This side's tenant, which the peer's token must share.
    public var tenant: String
    /// The room, which the peer's token must admit them to.
    public var room: String
    /// This participant, as `user/device`. Offers are addressed by it.
    public var me: String
    /// The UDP port to bind. Zero picks one.
    public var port: UInt16 = 0
    /// The host address to offer instead of the one the system would route the
    /// internet through. The socket still listens on every interface; this is
    /// for a test on one machine, and for a device that knows better.
    public var advertisedHost: String?
    /// A STUN server, `host` and `port`, to learn the public address from.
    ///
    /// Without one, only this device's own address is offered, which reaches a
    /// peer on the same network or one with a public address and nothing
    /// behind a NAT.
    public var stun: (host: String, port: UInt16)?
    /// Whether the accepting side sends probes to open its NAT.
    public var punching = true
    /// How often to probe each of the peer's candidates while establishing.
    public var punchInterval: Duration = .milliseconds(25)
    /// How long ``DirectEndpoint/establish(offer:credentials:verifier:)`` may
    /// take before giving up.
    public var patience: Duration = .seconds(5)
    /// How long a direct connection may be silent before QUIC declares it
    /// dead. Short, because the relay is always there to fall back to.
    public var idleTimeout: Duration = .seconds(3)

    public init(tenant: String, room: String, me: String) {
        self.tenant = tenant
        self.room = room
        self.me = me
    }
}

/// Why a direct session was not established. None of them touch the relay
/// session; every one means "stay on the relay".
public enum DirectEndpointError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The room does not allow direct paths.
    case ineligible(DirectIneligibility)
    /// The throwaway certificate could not be made.
    case identity(String)
    /// The port could not be bound.
    case bind(String)
    /// The offer cannot be acted on.
    case offer(String)
    /// No path opened within the configured patience.
    case unreachable
    /// The peer's credentials were refused here.
    case peerUnverified(DirectPeerRefusal)
    /// Ours were refused there.
    ///
    /// Without the peer's reason: it is sent, as a relay sends its own, and
    /// neither of the platform's QUIC interfaces reports it to the side that
    /// was refused.
    case peerRejected
    /// Another establishment is already under way on this endpoint, or it was
    /// closed.
    case busy

    public var description: String {
        switch self {
        case let .ineligible(why): "not eligible for a direct path: \(why)"
        case let .identity(why): "could not make a direct certificate: \(why)"
        case let .bind(why): "could not bind a direct endpoint: \(why)"
        case let .offer(why): "offer refused: \(why)"
        case .unreachable: "no direct path opened in time"
        case let .peerUnverified(refusal): "peer refused: \(refusal)"
        case .peerRejected: "the peer refused us"
        case .busy: "this endpoint is busy or closed"
        }
    }
}

/// A verified direct session.
public struct DirectSession: Sendable {
    /// The MOQT session to the peer, used exactly as a relay session is.
    public let session: MoqtSession
    /// Who the peer's token says they are.
    public let peer: VerifiedDirectPeer
    /// What the session has carried, for reporting; see ``DirectUsage``.
    public let usage: DirectUsage
}

#if canImport(Network)

    /// A socket ready to reach one peer directly.
    ///
    /// One per peer, as in the Rust SDK: the certificate and the replay set
    /// belong to one pairing, and an endpoint establishes once.
    public final class DirectEndpoint: @unchecked Sendable {
        /// The protocol on a direct path is the relay's: MOQT draft 19, over
        /// raw QUIC with no WebTransport.
        static let alpn = "moqt-19"
        /// The MOQT session close code for refused credentials, as the relay
        /// uses it.
        static let unauthorized: UInt64 = 0x03

        public let configuration: DirectConfiguration
        /// The addresses this endpoint offers, best first.
        public let candidates: [DirectCandidate]
        /// The local port.
        public let port: UInt16

        private let socket: any DirectSocket
        private let lock = NSLock()
        private var busy = false

        /// This endpoint's certificate identity: base64url SHA-256 of its leaf
        /// certificate, which a peer's proof of possession must name.
        public var certificateIdentity: String { socket.certificateIdentity }

        /// SHA-256 of this endpoint's leaf certificate, which its offers carry.
        public var certificateFingerprint: Data { socket.certificateFingerprint }

        /// Bind a port, find its candidate addresses, and make a certificate.
        ///
        /// Refuses before touching the network if the room does not allow
        /// direct paths. `exposure` is the caller's acknowledgement that the
        /// peer will learn the addresses this finds. A STUN server that does
        /// not answer is not an error: the endpoint is still useful on a local
        /// network.
        ///
        /// - Parameter backend: which socket to run on. Either can reach either.
        public static func bind(
            _ configuration: DirectConfiguration,
            eligibility: DirectEligibility,
            exposure _: DirectIPExposure,
            backend: DirectBackend = .networkFramework
        ) async throws(DirectEndpointError) -> DirectEndpoint {
            do { try eligibility.check() } catch { throw .ineligible(error) }
            let socket = try await backend.provider.bind(DirectSocketOptions(
                port: configuration.port,
                alpn: alpn,
                idleTimeout: configuration.idleTimeout,
                stun: configuration.stun,
                patience: configuration.patience
            ))
            guard socket.certificateFingerprint.count == 32 else {
                socket.close()
                throw .identity("the certificate fingerprint is not SHA-256")
            }
            let port = socket.port

            var candidates: [DirectCandidate] = []
            if let host = configuration.advertisedHost {
                guard let candidate = DirectCandidate(host: host, port: port) else {
                    socket.close()
                    throw .bind("\(host) is not a numeric address")
                }
                candidates.append(candidate)
            } else {
                candidates.append(Self.routedAddress(port: port))
            }
            if let reflexive = socket.reflexive, !candidates.contains(reflexive) {
                candidates.append(reflexive)
            }
            return DirectEndpoint(configuration: configuration, socket: socket, candidates: candidates)
        }

        private init(configuration: DirectConfiguration, socket: any DirectSocket, candidates: [DirectCandidate]) {
            self.configuration = configuration
            self.socket = socket
            self.candidates = candidates
            port = socket.port
        }

        deinit {
            socket.close()
        }

        /// Stop listening. A session already established is unaffected on the
        /// dialling side; on the accepting side that depends on the backend,
        /// and on Network.framework's it ends, because the listener owns its
        /// connection.
        public func close() {
            lock.withLock { busy = true }
            socket.close()
        }

        /// An offer telling `peer` how to reach this endpoint.
        public func offer(to peer: String) -> CandidateOffer {
            CandidateOffer(
                from: configuration.me,
                to: peer,
                certificate: socket.certificateFingerprint,
                candidates: candidates
            )
        }

        /// Open a direct, verified MOQT session with the peer that sent `offer`.
        ///
        /// Both peers call this after exchanging offers. `credentials` are this
        /// side's, exactly as presented to the relay; the proof is made afresh
        /// for the peer's certificate.
        ///
        /// - Throws: ``DirectEndpointError/unreachable`` if no path opened in
        ///   time, ``DirectEndpointError/peerUnverified(_:)`` if the peer's
        ///   credentials were refused here, ``DirectEndpointError/peerRejected``
        ///   if ours were refused there. The relay session is untouched in
        ///   every case.
        public func establish(
            offer: CandidateOffer,
            credentials: DeviceCredentials,
            verifier: any DirectPeerVerifying
        ) async throws(DirectEndpointError) -> DirectSession {
            let fingerprint = socket.certificateFingerprint
            guard offer.to == configuration.me else { throw .offer("addressed to another participant") }
            guard offer.certificate != fingerprint else { throw .offer("this is our own offer") }
            guard offer.certificate.count == 32 else { throw .offer("the certificate fingerprint is not SHA-256") }
            let claimed = lock.withLock {
                if busy { return false }
                busy = true
                return true
            }
            guard claimed else { throw .busy }

            let dialling = fingerprint.lexicographicallyPrecedes(offer.certificate)
            let attempt = Attempt()
            let patience = configuration.patience
            let (result, timedOut) = await withTaskGroup(
                of: Result<DirectSession, DirectEndpointError>?.self
            ) { group in
                group.addTask {
                    dialling
                        ? await self.dial(offer, credentials: credentials, verifier: verifier, attempt: attempt)
                        : await self.accept(offer, credentials: credentials, verifier: verifier, attempt: attempt)
                }
                group.addTask {
                    try? await Task.sleep(for: patience)
                    return nil
                }
                var result: Result<DirectSession, DirectEndpointError>?
                var timedOut = false
                for await outcome in group {
                    if let outcome {
                        result = outcome
                        group.cancelAll()
                    } else if result == nil {
                        // Abandoned by closing what it holds, because a read
                        // waiting on a peer that never answers does not
                        // observe cancellation on its own.
                        timedOut = true
                        await attempt.abandon()
                        group.cancelAll()
                    }
                }
                return (result, timedOut)
            }
            switch result {
            case let .success(established)? where timedOut:
                // Finished as patience ran out; the caller has been told no.
                await established.session.close(code: 0, reason: "gave up")
                throw .unreachable
            case let .success(established)?:
                return established
            case let .failure(error)? where !timedOut:
                throw error
            default:
                throw .unreachable
            }
        }

        /// Probe the peer's candidates for as long as `body` runs, where this
        /// side should and the socket can.
        private func punching<T>(
            _ offer: CandidateOffer,
            dialling: Bool,
            _ body: () async -> T
        ) async -> T {
            let probing = configuration.punching && (!dialling || socket.probesWhileDialling)
            if probing { socket.startPunching(offer.candidates, interval: configuration.punchInterval) }
            defer { if probing { socket.stopPunching() } }
            return await body()
        }

        // MARK: - Dialling

        private func dial(
            _ offer: CandidateOffer,
            credentials: DeviceCredentials,
            verifier: any DirectPeerVerifying,
            attempt: Attempt
        ) async -> Result<DirectSession, DirectEndpointError> {
            await punching(offer, dialling: true) {
                let raw: any QUICCarrier
                do {
                    raw = try await socket.dial(
                        offer.candidates,
                        pinning: offer.certificate,
                        timeout: configuration.patience
                    )
                } catch {
                    return .failure(.unreachable)
                }
                let usage = DirectUsage()
                let carrier = DirectCarrier(raw, awaitingAdmission: false, usage: usage)
                await attempt.hold(carrier)

                let session = MoqtSession(carrier: carrier, role: .client)
                do {
                    try await session.performSetup(credentials: credentials)
                } catch {
                    await carrier.close(code: 0, reason: "setup failed")
                    return .failure(Task.isCancelled ? .unreachable : .peerRejected)
                }

                let peer: VerifiedDirectPeer
                do throws(DirectPeerRefusal) {
                    peer = try check(await session.peerSetupOptions, offer: offer, verifier: verifier)
                } catch {
                    await carrier.close(code: Self.unauthorized, reason: error.description)
                    return .failure(.peerUnverified(error))
                }

                do {
                    let admission = try await carrier.openUnidirectionalStream()
                    await admission.finish()
                } catch {
                    await carrier.close(code: 0, reason: "lost")
                    return .failure(.unreachable)
                }
                await session.startReading()
                await attempt.release()
                return .success(DirectSession(session: session, peer: peer, usage: usage))
            }
        }

        // MARK: - Accepting

        private func accept(
            _ offer: CandidateOffer,
            credentials: DeviceCredentials,
            verifier: any DirectPeerVerifying,
            attempt: Attempt
        ) async -> Result<DirectSession, DirectEndpointError> {
            await punching(offer, dialling: false) {
                let raw: any QUICCarrier
                do {
                    raw = try await socket.accept(pinning: offer.certificate, timeout: configuration.patience)
                } catch {
                    return .failure(.unreachable)
                }
                let usage = DirectUsage()
                let carrier = DirectCarrier(raw, awaitingAdmission: true, usage: usage)
                await attempt.hold(carrier)

                let verdict = Verdict()
                let answer = MoqtSession.SetupAnswer(credentials: credentials) { options in
                    do throws(DirectPeerRefusal) {
                        verdict.peer = try self.check(options, offer: offer, verifier: verifier)
                        return nil
                    } catch {
                        verdict.refusal = error
                        return error.description
                    }
                }
                let session: MoqtSession
                do {
                    session = try await MoqtSession.accept(over: carrier, answering: answer)
                } catch {
                    if let refusal = verdict.refusal { return .failure(.peerUnverified(refusal)) }
                    await carrier.close(code: 0, reason: "setup failed")
                    return .failure(.unreachable)
                }
                guard let peer = verdict.peer else {
                    await session.close(code: 0, reason: "setup failed")
                    return .failure(.unreachable)
                }

                guard await carrier.admission() else {
                    await session.close(code: 0, reason: "not admitted")
                    return .failure(Task.isCancelled ? .unreachable : .peerRejected)
                }
                await attempt.release()
                return .success(DirectSession(session: session, peer: peer, usage: usage))
            }
        }

        // MARK: - Checking the peer

        private func check(
            _ options: Parameters,
            offer: CandidateOffer,
            verifier: any DirectPeerVerifying
        ) throws(DirectPeerRefusal) -> VerifiedDirectPeer {
            let peer = try verifier.verify(
                token: options.bytes(SetupOption.authorizationToken) ?? Data(),
                proof: options.bytes(SetupOption.authorizationProof),
                localCertificate: socket.certificateIdentity,
                now: Date()
            )
            try directAdmissible(
                peer,
                tenant: configuration.tenant,
                room: configuration.room,
                participant: offer.from
            )
            return peer
        }

        // MARK: - Addresses

        /// The address the system would route the internet through, with this
        /// endpoint's port; loopback if there is none.
        ///
        /// Found the way the Rust SDK finds it: connect a UDP socket to a
        /// TEST-NET-1 address, which is never routed so nothing is sent, and
        /// read which local address the kernel chose.
        static func routedAddress(port: UInt16) -> DirectCandidate {
            let loopback = DirectCandidate(address: [127, 0, 0, 1], port: port)!
            let fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else { return loopback }
            defer { Darwin.close(fd) }
            var remote = sockaddr_in()
            remote.sin_family = sa_family_t(AF_INET)
            remote.sin_port = in_port_t(9).bigEndian
            inet_pton(AF_INET, "192.0.2.1", &remote.sin_addr)
            let connected = withUnsafePointer(to: &remote) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connected == 0 else { return loopback }
            var local = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &local) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
            }
            guard named == 0, local.sin_addr.s_addr != 0 else { return loopback }
            let address = withUnsafeBytes(of: local.sin_addr) { Array($0) }
            return DirectCandidate(address: address, port: port) ?? loopback
        }
    }

    /// What an acceptance's SETUP check decided, read after it ran.
    private final class Verdict: @unchecked Sendable {
        private let lock = NSLock()
        private var _peer: VerifiedDirectPeer?
        private var _refusal: DirectPeerRefusal?

        var peer: VerifiedDirectPeer? {
            get { lock.withLock { _peer } }
            set { lock.withLock { _peer = newValue } }
        }

        var refusal: DirectPeerRefusal? {
            get { lock.withLock { _refusal } }
            set { lock.withLock { _refusal = newValue } }
        }
    }

    /// The carrier an establishment holds, so running out of patience can
    /// close it.
    private actor Attempt {
        private var carrier: (any QUICCarrier)?
        private var abandoned = false

        func hold(_ carrier: any QUICCarrier) async {
            if abandoned {
                await carrier.close(code: 0, reason: "gave up")
            } else {
                self.carrier = carrier
            }
        }

        /// The establishment succeeded; the carrier is the session's now.
        func release() {
            carrier = nil
        }

        func abandon() async {
            abandoned = true
            await carrier?.close(code: 0, reason: "gave up")
            carrier = nil
        }
    }
#endif
