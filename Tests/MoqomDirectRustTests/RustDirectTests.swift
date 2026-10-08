// The Rust direct backend: its socket and carrier on their own, and whole
// establishments with each backend at either end and in either role. Both
// backends speak moqt-19 over pinned mutual TLS, so every pairing must work.
//
// Only built when the MoqomDirectFFI xcframework is (see Package.swift).

#if canImport(MoqomDirectFFI)
    import CryptoKit
    import Foundation
    import MoqomCore
    import MoqomDirectRust
    import MoqomDirectTesting
    @testable import MoqomKit
    import MoqomLoopback
    import Testing

    // MARK: - Helpers

    actor Collector<Element: Sendable> {
        private(set) var items: [Element] = []
        func append(_ item: Element) { items.append(item) }
    }

    func eventually(timeout: Duration = .seconds(10), _ condition: @Sendable () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return await condition()
    }

    extension MoqtSession {
        func hasSubscriber(for track: FullTrackName) async -> Bool {
            guard let published = publishedTrack(track) else { return false }
            return await published.hasSubscribers
        }
    }

    /// Which backend is at either end, and which of them dials.
    enum Pairing: String, CaseIterable, CustomTestStringConvertible, Sendable {
        case rustDialsRust
        case networkDialsRust
        case rustDialsNetwork

        var dialler: DirectBackend {
            self == .networkDialsRust ? .networkFramework : .rust
        }

        var acceptor: DirectBackend {
            self == .rustDialsNetwork ? .networkFramework : .rust
        }

        /// Datagrams are offered only by the Rust socket, so only a Rust pair
        /// has them.
        var datagrams: Bool { self == .rustDialsRust }

        var testDescription: String {
            switch self {
            case .rustDialsRust: "rust → rust"
            case .networkDialsRust: "network → rust"
            case .rustDialsNetwork: "rust → network"
            }
        }
    }

    func bind(_ backend: DirectBackend, patience: Duration = .seconds(4)) async throws -> any DirectSocket {
        try await backend.provider.bind(DirectSocketOptions(
            alpn: DirectEndpoint.alpn,
            idleTimeout: .seconds(3),
            patience: patience
        ))
    }

    func loopback(_ socket: any DirectSocket) -> DirectCandidate {
        DirectCandidate(host: "127.0.0.1", port: socket.port)!
    }

    /// Two raw carriers, one dialled and one accepted.
    func connect(_ pairing: Pairing) async throws -> (
        dialled: any QUICCarrier, accepted: any QUICCarrier, sockets: [any DirectSocket]
    ) {
        let acceptor = try await bind(pairing.acceptor)
        let dialler = try await bind(pairing.dialler)
        async let accepted = acceptor.accept(pinning: dialler.certificateFingerprint, timeout: .seconds(4))
        let dialled = try await dialler.dial(
            [loopback(acceptor)],
            pinning: acceptor.certificateFingerprint,
            timeout: .seconds(4)
        )
        return (dialled, try await accepted, [acceptor, dialler])
    }

    /// `body`'s result, or `nil` if it takes longer than `limit`. Not
    /// structured, because a read the library never completes cannot be
    /// cancelled and a task group would wait for it.
    func within<T: Sendable>(_ limit: Duration, _ body: @escaping @Sendable () async -> T) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let once = OnceFlag()
            Task {
                let value = await body()
                if once.claim() { continuation.resume(returning: value) }
            }
            Task {
                try? await Task.sleep(for: limit)
                if once.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    /// Whether a unidirectional stream `opener` writes to and then resets
    /// ends at `answerer` within a few seconds: `nil` if it did not.
    func resetEnds(from opener: any QUICCarrier, to answerer: any QUICCarrier) async -> Bool? {
        guard let stream = try? await opener.openUnidirectionalStream() else { return false }
        var incoming = answerer.incomingUnidirectionalStreams.makeAsyncIterator()
        guard (try? await stream.write(Data("partial".utf8))) != nil, let other = await incoming.next() else {
            return false
        }
        await stream.reset(code: 0x11)
        // Whatever arrived before the reset may or may not be read first;
        // the stream must end either way rather than hang.
        return await within(.seconds(3)) {
            while (try? await other.read()) != nil {}
            return true
        }
    }

    func readAll(_ stream: any QUICReceiveStream) async throws -> Data {
        var all = Data()
        while let chunk = try await stream.read() {
            all.append(chunk)
        }
        return all
    }

    // MARK: - The library

    @Suite("The Rust direct backend")
    struct RustDirectBackendTests {
        @Test("the linked library speaks this module's ABI")
        func abi() {
            #expect(RustDirectBackend.isCompatible)
            #expect(RustDirectBackend.libraryABIVersion == RustDirectBackend.expectedABIVersion)
        }

        @Test("a socket has a port, a DER certificate, and the fingerprint and identity of it")
        func socket() async throws {
            let socket = try await bind(.rust)
            defer { socket.close() }
            #expect(socket.port != 0)
            #expect(SecCertificateCreateWithData(nil, socket.certificateDER as CFData) != nil)
            #expect(socket.certificateFingerprint == Data(SHA256.hash(data: socket.certificateDER)))
            #expect(socket.certificateFingerprint.count == 32)
            #expect(socket.certificateIdentity == socket.certificateFingerprint.base64URLEncodedString)
            #expect(socket.reflexive == nil)
            #expect(socket.probesWhileDialling)
        }

        @Test("two sockets have different certificates")
        func freshCertificates() async throws {
            let one = try await bind(.rust)
            let two = try await bind(.rust)
            #expect(one.certificateFingerprint != two.certificateFingerprint)
        }

        @Test("a session chooses the backend its direct endpoints bind on")
        func sessionOption() async throws {
            let device = DirectDevice(user: "alice")
            let session = MoqomSession(
                transport: LoopbackTransport(relay: LoopbackRelay()),
                credentials: try device.credentials(),
                tenant: TenantID("acme"),
                directBackend: .rust
            )
            guard case .custom = session.directBackend else {
                Issue.record("expected the Rust backend")
                return
            }
            var configuration = DirectConfiguration(tenant: "acme", room: "room-42", me: device.name)
            configuration.advertisedHost = "127.0.0.1"
            let endpoint = try await session.bindDirectEndpoint(
                configuration,
                eligibility: DirectPair.eligible,
                exposure: .peersWillLearnMyIPAddresses()
            )
            defer { endpoint.close() }
            #expect(endpoint.port != 0)
            #expect(endpoint.certificateIdentity == endpoint.certificateFingerprint.base64URLEncodedString)
        }

        @Test("a dial to a certificate other than the one presented never completes")
        func wrongPin() async throws {
            let acceptor = try await bind(.rust, patience: .seconds(1))
            let dialler = try await bind(.rust, patience: .seconds(1))
            async let accepted: Void = {
                _ = try? await acceptor.accept(pinning: dialler.certificateFingerprint, timeout: .seconds(1))
            }()
            let forged = Data(SHA256.hash(data: Data("someone else".utf8)))
            await #expect(throws: MoqomError.self) {
                try await dialler.dial([loopback(acceptor)], pinning: forged, timeout: .seconds(1))
            }
            await accepted
        }

        @Test("closing a socket ends an accept waiting on it")
        func closeCancelsAccept() async throws {
            let socket = try await bind(.rust)
            let pin = Data(repeating: 1, count: 32)
            let waiting = Task { () async -> Bool in
                (try? await socket.accept(pinning: pin, timeout: .seconds(30))) == nil
            }
            try await Task.sleep(for: .milliseconds(100))
            socket.close()
            #expect(await waiting.value)
        }

        @Test("cancelling the task ends a dial waiting on it")
        func cancellationEndsDial() async throws {
            let socket = try await bind(.rust)
            let nobody = DirectCandidate(host: "127.0.0.1", port: 9)!
            let started = ContinuousClock.now
            let dial = Task { () async -> Bool in
                (try? await socket.dial([nobody], pinning: Data(repeating: 1, count: 32), timeout: .seconds(30))) == nil
            }
            try await Task.sleep(for: .milliseconds(100))
            dial.cancel()
            #expect(await dial.value)
            #expect(ContinuousClock.now - started < .seconds(5))
        }
    }

    // MARK: - Carriers

    @Suite("Rust direct carriers", .serialized)
    struct RustCarrierTests {
        @Test("a bidirectional stream both ways, finished", arguments: Pairing.allCases)
        func bidirectional(_ pairing: Pairing) async throws {
            let (dialled, accepted, sockets) = try await connect(pairing)
            defer { sockets.forEach { $0.close() } }
            #expect(dialled.alpn == "moqt-19")
            #expect(accepted.alpn == "moqt-19")
            #expect(dialled.peerCertificateDigest == sockets[0].certificateIdentity)
            #expect(accepted.peerCertificateDigest == sockets[1].certificateIdentity)

            for (opener, answerer) in [(dialled, accepted), (accepted, dialled)] {
                let stream = try await opener.openBidirectionalStream()
                try await stream.write(Data("ping".utf8))
                await stream.finish()
                var incoming = answerer.incomingBidirectionalStreams.makeAsyncIterator()
                let other = try #require(await incoming.next())
                #expect(try await readAll(other) == Data("ping".utf8))
                try await other.write(Data("pong".utf8))
                await other.finish()
                #expect(try await readAll(stream) == Data("pong".utf8))
            }
            await dialled.close(code: 0, reason: "done")
            await accepted.close(code: 0, reason: "done")
        }

        @Test("a unidirectional stream both ways, large and finished", arguments: Pairing.allCases)
        func unidirectional(_ pairing: Pairing) async throws {
            let (dialled, accepted, sockets) = try await connect(pairing)
            defer { sockets.forEach { $0.close() } }
            let payload = Data((0 ..< 300_000).map { UInt8(truncatingIfNeeded: $0 * 7) })

            for (opener, answerer) in [(dialled, accepted), (accepted, dialled)] {
                let stream = try await opener.openUnidirectionalStream()
                var incoming = answerer.incomingUnidirectionalStreams.makeAsyncIterator()
                try await stream.write(payload)
                await stream.finish()
                let other = try #require(await incoming.next())
                #expect(try await readAll(other) == payload)
            }
            await dialled.close(code: 0, reason: "done")
            await accepted.close(code: 0, reason: "done")
        }

        @Test("a reset from a Rust sender reads as the end of the stream", arguments: Pairing.allCases)
        func reset(_ pairing: Pairing) async throws {
            let (dialled, accepted, sockets) = try await connect(pairing)
            defer { sockets.forEach { $0.close() } }
            for (opener, answerer) in [(dialled, accepted), (accepted, dialled)] where opener is RustQUICCarrier {
                #expect(await resetEnds(from: opener, to: answerer) == true)
            }
            await dialled.close(code: 0, reason: "done")
            await accepted.close(code: 0, reason: "done")
        }

        @Test("a reset from a Network.framework sender reaches a Rust reader",
              arguments: [Pairing.networkDialsRust, .rustDialsNetwork])
        func networkReset(_ pairing: Pairing) async throws {
            let (dialled, accepted, sockets) = try await connect(pairing)
            defer { sockets.forEach { $0.close() } }
            let (opener, answerer) = pairing == .networkDialsRust ? (dialled, accepted) : (accepted, dialled)
            let ended = await resetEnds(from: opener, to: answerer)
            if pairing == .networkDialsRust {
                #expect(ended == true)
            } else {
                // The accepting side's NetworkQUICCarrier resets by setting the
                // stream's error code, and nothing reaches the peer while the
                // stream is held. A gap in that backend, not in this one.
                withKnownIssue("a NetworkQUICCarrier reset is not seen by the peer while the stream lives") {
                    #expect(ended == true)
                }
            }
            await dialled.close(code: 0, reason: "done")
            await accepted.close(code: 0, reason: "done")
        }

        @Test("datagrams both ways between two Rust sockets")
        func datagrams() async throws {
            let (dialled, accepted, sockets) = try await connect(.rustDialsRust)
            defer { sockets.forEach { $0.close() } }
            #expect(dialled.maximumDatagramSize > 0)
            #expect(accepted.maximumDatagramSize > 0)
            for (sender, receiver) in [(dialled, accepted), (accepted, dialled)] {
                let received = Collector<Data>()
                let reader = Task {
                    for await datagram in receiver.datagrams { await received.append(datagram) }
                }
                // Unreliable, so sent until one lands.
                let landed = await eventually(timeout: .seconds(4)) {
                    try? await sender.send(datagram: Data("audio".utf8))
                    try? await Task.sleep(for: .milliseconds(20))
                    return await !received.items.isEmpty
                }
                #expect(landed)
                #expect(await received.items.first == Data("audio".utf8))
                reader.cancel()
            }
            await dialled.close(code: 0, reason: "done")
            await accepted.close(code: 0, reason: "done")
        }

        @Test("a Network.framework peer gets no datagrams from a Rust one", arguments: [Pairing.networkDialsRust, .rustDialsNetwork])
        func noDatagramsWithNetwork(_ pairing: Pairing) async throws {
            let (dialled, accepted, sockets) = try await connect(pairing)
            defer { sockets.forEach { $0.close() } }
            let rust = pairing == .networkDialsRust ? accepted : dialled
            #expect(rust.maximumDatagramSize == 0)
            await dialled.close(code: 0, reason: "done")
            await accepted.close(code: 0, reason: "done")
        }

        @Test("a deliberate close is not a loss here, and is one there", arguments: Pairing.allCases)
        func closeAndLoss(_ pairing: Pairing) async throws {
            let (dialled, accepted, sockets) = try await connect(pairing)
            defer { sockets.forEach { $0.close() } }
            // Each Rust end closing in turn: the closer's loss finishes
            // without a word, and the peer's reports it.
            let (closer, peer) = pairing == .networkDialsRust ? (accepted, dialled) : (dialled, accepted)
            await closer.close(code: 0x42, reason: "bye")
            var closerLoss = closer.loss.makeAsyncIterator()
            #expect(await closerLoss.next() == nil)
            let lost = Task { () async -> TransportFailure? in
                var iterator = peer.loss.makeAsyncIterator()
                return await iterator.next()
            }
            let report = await withTaskGroup(of: TransportFailure??.self) { group in
                group.addTask { await lost.value }
                group.addTask {
                    try? await Task.sleep(for: .seconds(6))
                    return .some(nil)
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                lost.cancel()
                return first ?? nil
            }
            #expect(report != nil, "the peer never noticed")
            if peer is RustQUICCarrier {
                #expect(report == .closedByPeer(code: 0x42, reason: "bye"))
            }
        }
    }

    // MARK: - Establishing

    @Suite("Direct sessions across backends", .serialized)
    struct RustEstablishTests {
        let alice = DirectDevice(user: "alice")
        let bob = DirectDevice(user: "bob")

        /// Alice dials and Bob accepts, on the pairing's backends.
        func establish(
            _ pairing: Pairing,
            bobToken: Data? = nil,
            offerToAlice: (CandidateOffer) -> CandidateOffer = { $0 },
            patience: Duration = .seconds(4),
            aliceDials: Bool? = true
        ) async throws -> (alice: DirectPair.Outcome, bob: DirectPair.Outcome) {
            try await DirectPair.establish(
                alice: alice,
                bob: bob,
                aliceBackend: pairing.dialler,
                bobBackend: pairing.acceptor,
                bobToken: bobToken,
                offerToAlice: offerToAlice,
                patience: patience,
                aliceDials: aliceDials
            )
        }

        func track(_ publisher: DirectDevice) throws -> FullTrackName {
            try FullTrackName(
                namespace: MoqomNamespaces.participant(
                    tenant: "acme",
                    room: "room-42",
                    identity: ParticipantIdentity(
                        username: try Username(publisher.user),
                        device: try DeviceID(thumbprint: publisher.key.thumbprint)
                    )
                ),
                name: try TrackName("camera")
            )
        }

        func exchange(from publisher: MoqtSession, to subscriber: MoqtSession, track: FullTrackName) async throws
            -> [String] {
            let writer = try await publisher.publish(track, priority: 64)
            let subscription = try await subscriber.subscribe(SubscribeRequest(track: track))
            let received = Collector<TrackObject>()
            let reader = Task { for await object in subscription.objects { await received.append(object) } }
            #expect(await eventually { await publisher.hasSubscriber(for: track) })
            for index in 0 ..< 3 {
                try await writer.write(TrackObject(group: 0, object: UInt64(index), payload: Data("frame-\(index)".utf8)))
            }
            _ = await eventually { await received.items.count == 3 }
            reader.cancel()
            await subscription.cancel()
            return await received.items.sorted { $0.object < $1.object }.map { String(decoding: $0.payload, as: UTF8.self) }
        }

        @Test("two endpoints connect, verify each other, and carry media both ways", arguments: Pairing.allCases)
        func connectsAndCarriesMedia(_ pairing: Pairing) async throws {
            let (fromAlice, fromBob) = try await establish(pairing)
            let atAlice = try fromAlice.get()
            let atBob = try fromBob.get()

            #expect(atAlice.peer.participant == bob.name)
            #expect(atBob.peer.participant == alice.name)

            let frames = ["frame-0", "frame-1", "frame-2"]
            #expect(try await exchange(from: atAlice.session, to: atBob.session, track: track(alice)) == frames)
            #expect(try await exchange(from: atBob.session, to: atAlice.session, track: track(bob)) == frames)
            #expect(atAlice.usage.bytesSent > 0)
            #expect(atBob.usage.bytesReceived > 0)

            await atAlice.session.close(code: 0, reason: "done")
            await atBob.session.close(code: 0, reason: "done")
        }

        @Test("a viewer's token is refused, and the viewer keeps no session", arguments: Pairing.allCases)
        func refusesViewer(_ pairing: Pairing) async throws {
            let viewer = DirectTokens.mint(user: "bob", key: bob.key, publish: 0)
            let (fromAlice, fromBob) = try await establish(pairing, bobToken: viewer)
            #expect(fromAlice.failure == .peerUnverified(.viewer))
            #expect(fromBob.failure == .peerRejected, "\(String(describing: fromBob.failure))")
        }

        @Test("a token naming somebody other than the offer's sender is refused", arguments: Pairing.allCases)
        func refusesImpostor(_ pairing: Pairing) async throws {
            let carol = DirectTokens.mint(user: "carol", key: bob.key)
            let (fromAlice, fromBob) = try await establish(pairing, bobToken: carol)
            #expect(fromAlice.failure == .peerUnverified(.wrongParticipant))
            #expect(fromBob.failure == .peerRejected)
        }

        @Test("a certificate other than the offered one never completes a handshake", arguments: Pairing.allCases)
        func refusesWrongCertificate(_ pairing: Pairing) async throws {
            let (fromAlice, fromBob) = try await establish(
                pairing,
                offerToAlice: { offer in
                    var forged = offer
                    forged.certificate = Data(SHA256.hash(data: Data("someone else".utf8)))
                    return forged
                },
                patience: .seconds(2),
                // Alice decides her role against the forged fingerprint, so
                // neither role can be arranged.
                aliceDials: nil
            )
            #expect(fromAlice.failure == .unreachable)
            #expect(fromBob.failure == .unreachable || fromBob.failure == .peerRejected)
        }
    }
#endif
