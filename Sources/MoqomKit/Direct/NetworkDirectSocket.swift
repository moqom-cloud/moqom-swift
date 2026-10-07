// A direct socket on Network.framework: a QUIC listener with port reuse, plain
// UDP flows on the same port for STUN and probes, and the connection-group API
// for dialling (see DirectDialCarrier.swift for why that one).
//
// The listener and the flows share a port but not a socket, and that is where
// this backend's two quirks come from. A flow to an address takes every packet
// from that address while it exists, so the accepting side probes in a short
// burst and stops at the first inbound packet, and the dialling side releases
// the listener before it dials. A backend with one real socket does neither.

#if canImport(Network)
    import Foundation
    import Network

    /// ``DirectBackend/networkFramework``.
    struct NetworkDirectSocketProvider: DirectSocketProvider {
        func bind(_ options: DirectSocketOptions) async throws(DirectEndpointError) -> any DirectSocket {
            try await NetworkDirectSocket.bind(options)
        }
    }

    final class NetworkDirectSocket: DirectSocket, @unchecked Sendable {
        /// A probe's payload, matching the Rust puncher's so a capture shows
        /// both the same.
        static let probe = Data("MQDP".utf8)
        /// How many rounds of probes the accepting side sends; see
        /// ``startPunching(_:interval:)``.
        static let probeBurst = 3

        let port: UInt16
        let certificate: DirectCertificate
        let reflexive: DirectCandidate?
        let probesWhileDialling = false

        private let options: DirectSocketOptions
        private let listener: NetworkListener<QUIC>
        private let pin: Pin
        private let arrivals: AsyncStream<Inbound>
        private let arrivalsIn: AsyncStream<Inbound>.Continuation
        private let lock = NSLock()
        private var listening: Task<Void, Never>?
        private var puncher: Task<Void, Never>?

        var certificateDER: Data { certificate.der }
        var certificateFingerprint: Data { certificate.fingerprint }
        var certificateIdentity: String { certificate.identity }

        static func bind(_ options: DirectSocketOptions) async throws(DirectEndpointError) -> NetworkDirectSocket {
            let certificate = try DirectCertificate.generate()
            let pin = Pin()
            let (arrivals, arrivalsIn) = AsyncStream.makeStream(of: Inbound.self, bufferingPolicy: .bufferingNewest(8))

            let listener: NetworkListener<QUIC>
            do {
                listener = try Self.listener(options, certificate: certificate, pin: pin)
            } catch let error as DirectEndpointError {
                throw error
            } catch {
                throw .bind("\(error)")
            }
            let patience = options.patience
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

            var reflexive: DirectCandidate?
            if let stun = options.stun {
                reflexive = await Self.reflexive(from: port, server: stun)
            }

            return NetworkDirectSocket(
                options: options,
                certificate: certificate,
                port: port,
                reflexive: reflexive,
                listener: listener,
                pin: pin,
                arrivals: arrivals,
                arrivalsIn: arrivalsIn,
                listening: listening
            )
        }

        private init(
            options: DirectSocketOptions,
            certificate: DirectCertificate,
            port: UInt16,
            reflexive: DirectCandidate?,
            listener: NetworkListener<QUIC>,
            pin: Pin,
            arrivals: AsyncStream<Inbound>,
            arrivalsIn: AsyncStream<Inbound>.Continuation,
            listening: Task<Void, Never>
        ) {
            self.options = options
            self.certificate = certificate
            self.port = port
            self.reflexive = reflexive
            self.listener = listener
            self.pin = pin
            self.arrivals = arrivals
            self.arrivalsIn = arrivalsIn
            self.listening = listening
        }

        deinit {
            listening?.cancel()
            puncher?.cancel()
            arrivalsIn.finish()
        }

        /// Stop listening. A carrier already dialled is unaffected; one
        /// accepted ends, because the listener owns its connection.
        func close() {
            lock.withLock {
                listening?.cancel()
                listening = nil
                puncher?.cancel()
                puncher = nil
            }
            arrivalsIn.finish()
        }

        // MARK: - Punching

        /// A short burst of probes to every candidate from this port, so this
        /// side's NAT expects the dialler's packets.
        ///
        /// A burst rather than the Rust SDK's probing for as long as it takes,
        /// because a probe here cannot share the listener's socket: each one is
        /// a flow of its own, and a flow to the peer's address that exists
        /// when the peer's QUIC arrives takes those packets from the listener.
        /// Probing throughout would keep catching the handshake. A NAT mapping
        /// outlives the burst by far, and a packet a probe did catch is one
        /// QUIC sends again. The burst also ends at the first inbound
        /// connection; see ``accept(pinning:timeout:)``.
        func startPunching(_ candidates: [DirectCandidate], interval: Duration) {
            let port = port
            let burst = Task {
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
            let previous = lock.withLock {
                defer { puncher = burst }
                return puncher
            }
            previous?.cancel()
        }

        func stopPunching() {
            let current = lock.withLock {
                defer { puncher = nil }
                return puncher
            }
            current?.cancel()
        }

        // MARK: - Dialling

        func dial(
            _ candidates: [DirectCandidate],
            pinning fingerprint: Data,
            timeout: Duration
        ) async throws(MoqomError) -> any QUICCarrier {
            // Released first: a live listener on the port takes the peer's
            // replies to the dial, and the handshake never completes.
            lock.withLock {
                listening?.cancel()
                listening = nil
            }
            try? await Task.sleep(for: .milliseconds(50))
            guard let carrier = await firstReady(candidates, pinning: fingerprint, timeout: timeout) else {
                throw MoqomError.transport(.unreachable)
            }
            return carrier
        }

        /// Every candidate at once, from this port; the first to complete a
        /// handshake wins and the rest are closed.
        private func firstReady(
            _ candidates: [DirectCandidate],
            pinning fingerprint: Data,
            timeout: Duration
        ) async -> DirectDialCarrier? {
            await withTaskGroup(of: DirectDialCarrier?.self) { group in
                for candidate in candidates {
                    guard let port = NWEndpoint.Port(rawValue: candidate.port) else { continue }
                    let remote = NWEndpoint.hostPort(host: NWEndpoint.Host(candidate.host), port: port)
                    group.addTask { [certificate, options, port = self.port] in
                        try? await DirectDialCarrier.dial(
                            remote,
                            from: port,
                            alpn: options.alpn,
                            certificate: certificate,
                            pinning: fingerprint,
                            idleTimeout: options.idleTimeout,
                            timeout: timeout
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

        func accept(pinning fingerprint: Data, timeout: Duration) async throws(MoqomError) -> any QUICCarrier {
            // Only the pinned certificate completes a handshake, and only
            // while this runs: outside it the validator refuses everyone.
            pin.set(fingerprint)
            defer { pin.set(nil) }

            for await inbound in arrivals {
                // A probe opens a flow to the peer's address, and a flow that
                // exists when the peer's packets arrive takes them from the
                // listener. The first packet from anyone means the probes
                // have done what they can.
                stopPunching()
                guard inbound.adopt() else { continue }
                let raw: NetworkQUICCarrier
                do {
                    raw = try await NetworkQUICCarrier.accepted(
                        inbound.connection,
                        alpn: options.alpn,
                        peerCertificate: fingerprint.base64URLEncodedString,
                        within: timeout
                    )
                } catch {
                    // Not the peer: a probe the listener took for a connection,
                    // or a handshake the pin refused. Keep waiting.
                    inbound.release()
                    continue
                }
                return HeldCarrier(raw) { inbound.release() }
            }
            throw MoqomError.transport(.unreachable)
        }

        // MARK: - Binding

        private static func listener(
            _ options: DirectSocketOptions,
            certificate: DirectCertificate,
            pin: Pin
        ) throws -> NetworkListener<QUIC> {
            guard let identity = sec_identity_create(certificate.secIdentity) else {
                throw DirectEndpointError.identity("the identity could not be wrapped")
            }
            // No datagrams offered, matching the dialling side, which cannot
            // read them: a peer told there are none sends audio on streams
            // rather than into a channel nobody reads.
            let quic = QUIC(alpn: [options.alpn])
                .idleTimeout(options.idleTimeout.milliseconds)
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
            if options.port != 0, let port = NWEndpoint.Port(rawValue: options.port) {
                parameters = parameters.localPort(port)
            }
            return try NetworkListener(using: parameters)
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

    /// An accepted carrier that lets the listener's handler return once it is
    /// closed or lost.
    private final class HeldCarrier: QUICCarrier, @unchecked Sendable {
        private let base: any QUICCarrier
        private let onEnd: @Sendable () -> Void
        private let ended = OnceFlag()
        private let lossStream: AsyncStream<TransportFailure>
        private let pump: Task<Void, Never>

        init(_ base: any QUICCarrier, onEnd: @escaping @Sendable () -> Void) {
            self.base = base
            self.onEnd = onEnd
            let (loss, lossIn) = AsyncStream.makeStream(of: TransportFailure.self, bufferingPolicy: .bufferingNewest(1))
            lossStream = loss
            pump = Task { [ended] in
                for await failure in base.loss {
                    lossIn.yield(failure)
                }
                lossIn.finish()
                if ended.claim() { onEnd() }
            }
        }

        deinit {
            pump.cancel()
        }

        var alpn: String { base.alpn }
        var maximumDatagramSize: Int { base.maximumDatagramSize }
        var peerCertificateDigest: String? { base.peerCertificateDigest }
        var incomingBidirectionalStreams: AsyncStream<any QUICStream> { base.incomingBidirectionalStreams }
        var incomingUnidirectionalStreams: AsyncStream<any QUICReceiveStream> { base.incomingUnidirectionalStreams }
        var datagrams: AsyncStream<Data> { base.datagrams }
        var loss: AsyncStream<TransportFailure> { lossStream }

        func openBidirectionalStream() async throws(MoqomError) -> any QUICStream {
            try await base.openBidirectionalStream()
        }

        func openUnidirectionalStream() async throws(MoqomError) -> any QUICSendStream {
            try await base.openUnidirectionalStream()
        }

        func send(datagram: Data) async throws(MoqomError) {
            try await base.send(datagram: datagram)
        }

        func close(code: UInt64, reason: String) async {
            await base.close(code: code, reason: reason)
            if ended.claim() { onEnd() }
        }
    }
#endif
