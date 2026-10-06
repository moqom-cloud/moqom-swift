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
        /// A probe's payload, matching the Rust puncher's so a capture shows
        /// both the same.
        static let probe = Data("MQDP".utf8)
        /// How many rounds of probes the accepting side sends; see `punch`.
        static let probeBurst = 3

        public let configuration: DirectConfiguration
        let certificate: DirectCertificate
        /// The addresses this endpoint offers, best first.
        public let candidates: [DirectCandidate]
        /// The local port.
        public let port: UInt16

        private let listener: NetworkListener<QUIC>
        private let pin: Pin
        private let arrivals: AsyncStream<Inbound>
        private let arrivalsIn: AsyncStream<Inbound>.Continuation
        private let lock = NSLock()
        private var listening: Task<Void, Never>?
        private var busy = false

        /// This endpoint's certificate identity: base64url SHA-256 of its leaf
        /// certificate, which a peer's proof of possession must name.
        public var certificateIdentity: String { certificate.identity }

        /// Bind a port, find its candidate addresses, and make a certificate.
        ///
        /// Refuses before touching the network if the room does not allow
        /// direct paths. `exposure` is the caller's acknowledgement that the
        /// peer will learn the addresses this finds. A STUN server that does
        /// not answer is not an error: the endpoint is still useful on a local
        /// network.
        public static func bind(
            _ configuration: DirectConfiguration,
            eligibility: DirectEligibility,
            exposure _: DirectIPExposure
        ) async throws(DirectEndpointError) -> DirectEndpoint {
            do { try eligibility.check() } catch { throw .ineligible(error) }
            let certificate = try DirectCertificate.generate()
            let pin = Pin()
            let (arrivals, arrivalsIn) = AsyncStream.makeStream(of: Inbound.self, bufferingPolicy: .bufferingNewest(8))

            let listener: NetworkListener<QUIC>
            do {
                listener = try Self.listener(configuration, certificate: certificate, pin: pin)
            } catch {
                throw .bind("\(error)")
            }
            let patience = configuration.patience
            let listening = Task {
                _ = try? await listener.run { connection in
                    let inbound = Inbound(connection)
                    arrivalsIn.yield(inbound)
                    await inbound.held(unlessAdoptedWithin: patience)
                }
            }

            var port: UInt16 = 0
            for _ in 0 ..< 100 {
                if let bound = listener.port?.rawValue, bound != 0 {
                    port = bound
                    break
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
            guard port != 0 else {
                listening.cancel()
                throw .bind("the listener never reported a port")
            }

            var candidates: [DirectCandidate] = []
            if let host = configuration.advertisedHost {
                guard let candidate = DirectCandidate(host: host, port: port) else {
                    listening.cancel()
                    throw .bind("\(host) is not a numeric address")
                }
                candidates.append(candidate)
            } else {
                candidates.append(Self.routedAddress(port: port))
            }
            if let stun = configuration.stun,
               let reflexive = await Self.reflexive(from: port, server: stun),
               !candidates.contains(reflexive) {
                candidates.append(reflexive)
            }

            return DirectEndpoint(
                configuration: configuration,
                certificate: certificate,
                candidates: candidates,
                port: port,
                listener: listener,
                pin: pin,
                arrivals: arrivals,
                arrivalsIn: arrivalsIn,
                listening: listening
            )
        }

        private init(
            configuration: DirectConfiguration,
            certificate: DirectCertificate,
            candidates: [DirectCandidate],
            port: UInt16,
            listener: NetworkListener<QUIC>,
            pin: Pin,
            arrivals: AsyncStream<Inbound>,
            arrivalsIn: AsyncStream<Inbound>.Continuation,
            listening: Task<Void, Never>
        ) {
            self.configuration = configuration
            self.certificate = certificate
            self.candidates = candidates
            self.port = port
            self.listener = listener
            self.pin = pin
            self.arrivals = arrivals
            self.arrivalsIn = arrivalsIn
            self.listening = listening
        }

        deinit {
            listening?.cancel()
            arrivalsIn.finish()
        }

        /// Stop listening. A session already established is unaffected on the
        /// dialling side and ends on the accepting side, whose connection the
        /// listener owns.
        public func close() {
            lock.withLock {
                busy = true
                listening?.cancel()
                listening = nil
            }
            arrivalsIn.finish()
        }

        /// An offer telling `peer` how to reach this endpoint.
        public func offer(to peer: String) -> CandidateOffer {
            CandidateOffer(
                from: configuration.me,
                to: peer,
                certificate: certificate.fingerprint,
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
            guard offer.to == configuration.me else { throw .offer("addressed to another participant") }
            guard offer.certificate != certificate.fingerprint else { throw .offer("this is our own offer") }
            guard offer.certificate.count == 32 else { throw .offer("the certificate fingerprint is not SHA-256") }
            let claimed = lock.withLock {
                if busy { return false }
                busy = true
                return true
            }
            guard claimed else { throw .busy }

            let dialling = certificate.fingerprint.lexicographicallyPrecedes(offer.certificate)
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

        // MARK: - Dialling

        private func dial(
            _ offer: CandidateOffer,
            credentials: DeviceCredentials,
            verifier: any DirectPeerVerifying,
            attempt: Attempt
        ) async -> Result<DirectSession, DirectEndpointError> {
            // Released first: a live listener on the port takes the peer's
            // replies to the dial, and the handshake never completes.
            lock.withLock {
                listening?.cancel()
                listening = nil
            }
            try? await Task.sleep(for: .milliseconds(50))

            guard let raw = await firstReady(offer) else { return .failure(.unreachable) }
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
            do {
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

        /// Every candidate at once, from this endpoint's port; the first to
        /// complete a handshake wins and the rest are closed.
        private func firstReady(_ offer: CandidateOffer) async -> DirectDialCarrier? {
            await withTaskGroup(of: DirectDialCarrier?.self) { group in
                for candidate in offer.candidates {
                    guard let port = NWEndpoint.Port(rawValue: candidate.port) else { continue }
                    let remote = NWEndpoint.hostPort(host: NWEndpoint.Host(candidate.host), port: port)
                    group.addTask { [certificate, configuration, port = self.port] in
                        try? await DirectDialCarrier.dial(
                            remote,
                            from: port,
                            certificate: certificate,
                            pinning: offer.certificate,
                            idleTimeout: configuration.idleTimeout,
                            timeout: configuration.patience
                        )
                    }
                }
                var winner: DirectDialCarrier?
                for await carrier in group {
                    guard let carrier else { continue }
                    if winner == nil {
                        winner = carrier
                        group.cancelAll()
                    } else {
                        await carrier.close(code: 0, reason: "another path won")
                    }
                }
                return winner
            }
        }

        // MARK: - Accepting

        private func accept(
            _ offer: CandidateOffer,
            credentials: DeviceCredentials,
            verifier: any DirectPeerVerifying,
            attempt: Attempt
        ) async -> Result<DirectSession, DirectEndpointError> {
            // Only the offered certificate completes a handshake, and only
            // while this runs: outside it the validator refuses everyone.
            pin.set(offer.certificate)
            defer { pin.set(nil) }

            let puncher = configuration.punching ? punch(offer.candidates) : nil
            defer { puncher?.cancel() }

            for await inbound in arrivals {
                // A probe opens a flow to the peer's address, and a flow that
                // exists when the peer's packets arrive takes them from the
                // listener. The first packet from anyone means the probes
                // have done what they can.
                puncher?.cancel()
                guard inbound.adopt() else { continue }
                let raw: NetworkQUICCarrier
                do {
                    raw = try await NetworkQUICCarrier.accepted(
                        inbound.connection,
                        alpn: Self.alpn,
                        peerCertificate: offer.certificate.base64URLEncodedString,
                        within: configuration.patience
                    )
                } catch {
                    // Not the peer: a probe the listener took for a connection,
                    // or a handshake the pin refused. Keep waiting.
                    inbound.release()
                    continue
                }
                let usage = DirectUsage()
                let carrier = DirectCarrier(raw, awaitingAdmission: true, usage: usage) { inbound.release() }
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
            return .failure(.unreachable)
        }

        /// A short burst of probes to every candidate from this endpoint's
        /// port, so this side's NAT expects the dialler's packets.
        ///
        /// A burst rather than the Rust SDK's probing for as long as it takes,
        /// because a probe here cannot share the listener's socket: each one is
        /// a flow of its own, and a flow to the peer's address that exists
        /// when the peer's QUIC arrives takes those packets from the listener.
        /// Probing throughout would keep catching the handshake. A NAT mapping
        /// outlives the burst by far, and a packet a probe did catch is one
        /// QUIC sends again.
        private func punch(_ candidates: [DirectCandidate]) -> Task<Void, Never> {
            let port = port
            let interval = configuration.punchInterval
            return Task {
                guard let local = NWEndpoint.Port(rawValue: port) else { return }
                for _ in 0 ..< Self.probeBurst where !Task.isCancelled {
                    for candidate in candidates {
                        guard let remote = NWEndpoint.Port(rawValue: candidate.port) else { continue }
                        let probe = NetworkConnection(
                            to: .hostPort(host: NWEndpoint.Host(candidate.host), port: remote),
                            using: .parameters { UDP() }.localPort(local).localEndpointReuseAllowed(true)
                        )
                        try? await probe.send(Self.probe)
                    }
                    try? await Task.sleep(for: interval)
                }
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
                localCertificate: certificate.identity,
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

        // MARK: - Binding

        private static func listener(
            _ configuration: DirectConfiguration,
            certificate: DirectCertificate,
            pin: Pin
        ) throws -> NetworkListener<QUIC> {
            guard let identity = sec_identity_create(certificate.secIdentity) else {
                throw DirectEndpointError.identity("the identity could not be wrapped")
            }
            // No datagrams offered, matching the dialling side, which cannot
            // read them: a peer told there are none sends audio on streams
            // rather than into a channel nobody reads.
            let quic = QUIC(alpn: [alpn])
                .idleTimeout(configuration.idleTimeout.milliseconds)
                .initialMaxBidirectionalStreams(256)
                .initialMaxUnidirectionalStreams(1024)
                .tls.localIdentity(identity)
                .tls.peerAuthentication(.required)
                .tls.certificateValidator { _, trust in
                    guard let expected = pin.value else { return false }
                    return DirectCertificate.leaf(of: trust, matches: expected)
                }
            var parameters = NWParametersBuilder.parameters { quic }
                .localEndpointReuseAllowed(true)
                .serviceClass(NetworkQUICCarrier.serviceClass)
            if configuration.port != 0, let port = NWEndpoint.Port(rawValue: configuration.port) {
                parameters = parameters.localPort(port)
            }
            return try NetworkListener(using: parameters)
        }

        /// The address the system would route the internet through, with this
        /// endpoint's port; loopback if there is none.
        ///
        /// Found the way the Rust SDK finds it: connect a UDP socket to a
        /// TEST-NET-1 address, which is never routed so nothing is sent, and
        /// read which local address the kernel chose.
        static func routedAddress(port: UInt16) -> DirectCandidate {
            let loopback = DirectCandidate(address: [127, 0, 0, 1], port: port)!
            let fd = socket(AF_INET, SOCK_DGRAM, 0)
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

        /// This port's public address, asked of a STUN server: three attempts,
        /// each waiting a third of a second, as the Rust SDK does.
        static func reflexive(from port: UInt16, server: (host: String, port: UInt16)) async -> DirectCandidate? {
            guard let local = NWEndpoint.Port(rawValue: port),
                  let remote = NWEndpoint.Port(rawValue: server.port)
            else { return nil }
            var random = [UInt8](repeating: 0, count: 12)
            guard SecRandomCopyBytes(kSecRandomDefault, 12, &random) == errSecSuccess else { return nil }
            let transaction = random
            let request = DirectSTUN.request(transaction: transaction)

            // One flow for the whole exchange, dropped on return: while it
            // exists it takes every packet from the server's address.
            let connection = NetworkConnection(
                to: .hostPort(host: NWEndpoint.Host(server.host), port: remote),
                using: .parameters { UDP() }.localPort(local).localEndpointReuseAllowed(true)
            )
            for _ in 0 ..< 3 {
                guard (try? await connection.send(request)) != nil else { return nil }
                let answer = await withTaskGroup(of: DirectCandidate?.self) { group in
                    group.addTask {
                        while !Task.isCancelled {
                            guard let message = try? await connection.receive() else { return nil }
                            if let address = DirectSTUN.parse(message.content, transaction: transaction) {
                                return address
                            }
                        }
                        return nil
                    }
                    group.addTask {
                        try? await Task.sleep(for: .milliseconds(333))
                        return nil
                    }
                    let first = await group.next() ?? nil
                    group.cancelAll()
                    return first
                }
                if let answer { return answer }
            }
            return nil
        }
    }

    /// The certificate the listener's validator accepts, set only while an
    /// acceptance is under way.
    private final class Pin: @unchecked Sendable {
        private let lock = NSLock()
        private var expected: Data?

        var value: Data? { lock.withLock { expected } }

        func set(_ fingerprint: Data?) {
            lock.withLock { expected = fingerprint }
        }
    }

    /// One connection the listener accepted, held open by the listener's
    /// handler for as long as something uses it.
    private final class Inbound: @unchecked Sendable {
        let connection: NetworkConnection<QUIC>
        private let lock = NSLock()
        private var adopted = false
        private var released = false
        private var waiter: CheckedContinuation<Void, Never>?

        init(_ connection: NetworkConnection<QUIC>) {
            self.connection = connection
        }

        /// Claim it, once.
        func adopt() -> Bool {
            lock.withLock {
                if adopted || released { return false }
                adopted = true
                return true
            }
        }

        func release() {
            let waiter: CheckedContinuation<Void, Never>? = lock.withLock {
                released = true
                defer { self.waiter = nil }
                return self.waiter
            }
            waiter?.resume()
        }

        /// Suspend until released, or until `patience` passes with nobody
        /// having adopted it: a connection nobody is waiting for is a probe,
        /// or a peer whose establishment already gave up.
        func held(unlessAdoptedWithin patience: Duration) async {
            let expiry = Task { [weak self] in
                try? await Task.sleep(for: patience)
                guard let self, !Task.isCancelled else { return }
                let unclaimed = lock.withLock { !adopted }
                if unclaimed { release() }
            }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let already = lock.withLock {
                    if released { return true }
                    waiter = continuation
                    return false
                }
                if already { continuation.resume() }
            }
            expiry.cancel()
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
