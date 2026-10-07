// Talking to an implementation that is not this one.
//
// Everything else in this suite runs two `MoqtSession`s against each other over
// `MemoryCarrier`. That proves the codec is self-consistent and proves nothing
// about whether it is *right*: a mistake in the framing is made by both ends and
// observed by neither. The only test that can catch that is one where the peer
// was written separately, and the peer here is `moqom-relay` — a Rust process,
// built on a Rust codec, that has never seen this file.
//
// It is also the only test in the repository that opens a socket, which makes it
// the only coverage `NetworkQUICCarrier` has ever had.
//
// # Why this is skipped by default
//
// It needs a relay binary, which lives in `moqom-engine` rather than here, so
// the path comes from `MOQOM_RELAY_BIN`:
//
// ```
// (cd ../moqom-engine && cargo build --bin moqom-relay)
// MOQOM_RELAY_BIN=$PWD/../moqom-engine/target/debug/moqom-relay swift test
// ```
//
// Skipping rather than failing when it is absent is the right trade for a client
// SDK whose CI has no Rust toolchain — but it does mean a green run here is not
// evidence of interop unless that variable was set.
//
// macOS only: it launches the relay with `Process`, which iOS doesn't have.

#if os(macOS)
import Foundation
import Synchronization
import Testing

@testable import MoqomCore
@testable import MoqomKit
import MoqomWire

@Suite("Interop with the Rust relay", .enabled(if: RelayProcess.isAvailable))
struct RelayInteropTests {
    private func namespace(_ publisher: String) throws -> TrackNamespace {
        try MoqomNamespaces.participant(
            tenant: "acme",
            room: "room-42",
            identity: identity(publisher)
        )
    }

    /// SETUP against a peer that implements the draft independently.
    ///
    /// The assertion that matters is the implementation string: it is a value
    /// only the Rust relay could have produced, so reading it back proves an
    /// exchange happened rather than that a local default was returned.
    @Test("SETUP completes against the Rust relay", arguments: interopDrafts)
    func setup(alpn: String) async throws {
        let relay = try RelayProcess.start()
        let session = try await relay.connect(alpn: alpn, credentials: credentials("alice"))

        let negotiated = await session.negotiated
        #expect(negotiated.alpn == alpn)

        let peer = await session.peerSetupOptions
        let implementation = peer.string(SetupOption.implementation)
        #expect(
            implementation?.hasPrefix("moqom-relay/") == true,
            "expected the relay's implementation string, got \(implementation ?? "none")"
        )

        await session.close(code: 0, reason: "done")
    }

    /// An announcement made on one session reaches a prefix watcher on another,
    /// through the relay, with the namespace intact.
    ///
    /// The relay sends a *suffix* relative to the watched prefix and the client
    /// rejoins them. That arithmetic is implemented twice, in two languages, and
    /// a disagreement produces a namespace that decodes cleanly and names the
    /// wrong participant — exactly the failure a loopback test cannot see.
    @Test("an announcement crosses the relay to a watcher", arguments: interopDrafts)
    func announcementCrossesTheRelay(alpn: String) async throws {
        let relay = try RelayProcess.start()
        let publisher = try await relay.connect(alpn: alpn, credentials: credentials("alice"))
        let watcher = try await relay.connect(alpn: alpn, credentials: credentials("bob"))

        let room = try MoqomNamespaces.room(tenant: "acme", room: "room-42")
        let events = try await watcher.announcements(matching: room)
        let seen = Collector<AnnouncementEvent>()
        let reader = Task { for await event in events { await seen.append(event) } }

        let mine = try namespace("alice")
        let announcement = try await publisher.announce(mine)
        #expect(
            await eventually(timeout: .seconds(10)) {
                await seen.items.contains(.announced(mine))
            },
            "the relay did not report the announcement"
        )

        // Withdrawal is a stream close rather than a message, so this also
        // checks that the relay notices one and translates it.
        //
        // And the reason, which is the part only this test can check. The
        // trailing varint carrying it is written by the Rust relay and read
        // here, so the two codecs have to agree on a field draft-19 does not
        // describe; a loopback test asserts Swift against Swift and would pass
        // whatever the relay actually sent.
        await announcement.withdraw()
        let withdrawn = await eventually(timeout: .seconds(10)) {
            await seen.items.contains(.withdrawn(mine, .stopped))
        }
        let saw = await seen.items
        #expect(withdrawn, "the relay did not report the withdrawal: \(saw)")

        reader.cancel()
        await publisher.close(code: 0, reason: "done")
        await watcher.close(code: 0, reason: "done")
    }

    /// The same message, the other reason, across the same two codecs.
    ///
    /// Everything a viewer does with a withdrawal turns on this distinction, and
    /// it is the pair that gives it meaning: the test above establishes that the
    /// relay can say `stopped`, and this one that it does not simply always say
    /// so. Nothing else about the two endings differs on the wire.
    @Test("a publisher whose session dies is reported as vanished, not stopped", arguments: interopDrafts)
    func vanishingCrossesTheRelay(alpn: String) async throws {
        let relay = try RelayProcess.start()
        let publisher = try await relay.connect(alpn: alpn, credentials: credentials("alice"))
        let watcher = try await relay.connect(alpn: alpn, credentials: credentials("bob"))

        let room = try MoqomNamespaces.room(tenant: "acme", room: "room-42")
        let events = try await watcher.announcements(matching: room)
        let seen = Collector<AnnouncementEvent>()
        let reader = Task { for await event in events { await seen.append(event) } }

        let mine = try namespace("alice")
        let announcement = try await publisher.announce(mine)
        #expect(
            await eventually(timeout: .seconds(10)) {
                await seen.items.contains(.announced(mine))
            },
            "the relay did not report the announcement"
        )

        // The connection goes while the announcement is still standing. Not
        // withdrawing it first is the whole scenario: the relay has to infer the
        // withdrawal from the transport, which is what a dead battery looks like.
        await publisher.close(code: 0, reason: "vanished")
        let withdrawn = await eventually(timeout: .seconds(10)) {
            await seen.items.contains(.withdrawn(mine, .vanished))
        }
        let saw = await seen.items
        #expect(withdrawn, "the relay did not report the withdrawal as a vanish: \(saw)")

        _ = announcement
        reader.cancel()
        await watcher.close(code: 0, reason: "done")
    }

    /// Objects published on one session arrive on another, byte for byte, under
    /// the alias the subscriber negotiated rather than the one the publisher used.
    ///
    /// Alias rewriting is the one edit a relay makes to a subgroup header. If the
    /// two implementations disagree about where that field sits, the subscriber
    /// either drops the stream or attributes it to the wrong track, and neither
    /// shows up without a real relay in the middle.
    @Test("objects survive a round trip through the relay", arguments: interopDrafts)
    func objectsSurviveTheRelay(alpn: String) async throws {
        let relay = try RelayProcess.start()
        let publisher = try await relay.connect(alpn: alpn, credentials: credentials("alice"))
        let subscriber = try await relay.connect(alpn: alpn, credentials: credentials("bob"))

        // The subscriber hears of the announcement from the relay before asking
        // for the track. They are two connections, so nothing orders the
        // relay's handling of one against the other, and a relay accepting a
        // namespace sends nothing back to wait on: under load the SUBSCRIBE
        // can be read first and refused as DOES_NOT_EXIST.
        let room = try MoqomNamespaces.room(tenant: "acme", room: "room-42")
        let events = try await subscriber.announcements(matching: room)
        let seen = Collector<AnnouncementEvent>()
        let watcher = Task { for await event in events { await seen.append(event) } }

        let mine = try namespace("alice")
        let announcement = try await publisher.announce(mine)
        let video = try FullTrackName(namespace: mine, name: try TrackName("video/720p"))
        let writer = try await publisher.publish(video, priority: 128)
        #expect(
            await eventually(timeout: .seconds(10)) {
                await seen.items.contains(.announced(mine))
            },
            "the relay did not report the announcement"
        )
        watcher.cancel()

        let subscription = try await subscriber.subscribe(
            SubscribeRequest(track: video, priority: 128)
        )
        let received = Collector<TrackObject>()
        let reader = Task {
            for await object in subscription.objects { await received.append(object) }
        }

        // The relay has to have subscribed upstream before a write has anywhere
        // to go. That is a property of the protocol rather than of this harness:
        // a publisher with no subscriber drops objects on the floor.
        #expect(
            await eventually(timeout: .seconds(10)) {
                await publisher.hasSubscriber(for: video)
            },
            "the relay never subscribed upstream, log:\n\(relay.logContents)"
        )

        // The keyframe carries what a real one carries: a capture time, and the
        // decoder configuration for the group it opens. The configuration is the
        // interesting one here because it is the first *bytes-valued* object
        // property this SDK sends — an odd type, length-prefixed rather than a
        // bare varint — and whether a relay written separately reads that the same
        // way is exactly the kind of thing only interop can answer. Get it wrong
        // and a viewer's geometry comes from whatever the catalog last said.
        let sets = [Data([0x40, 0x01, 0x0C]), Data([0x42, 0x02, 0xD0, 0x05, 0x00])]
        let configuration = DecoderConfiguration.encode(sets)
        let payloads = ["keyframe", "delta", "delta-2"]
        for (index, payload) in payloads.enumerated() {
            try await writer.write(
                TrackObject(
                    group: 0,
                    object: UInt64(index),
                    priority: 128,
                    payload: Data(payload.utf8),
                    isKeyFrame: index == 0,
                    properties: ObjectProperties(
                        captureTime: FrameTimestamp(nanoseconds: UInt64(index) * 33_000_000),
                        configuration: index == 0 ? configuration : nil
                    )
                )
            )
        }

        let arrived = await eventually(timeout: .seconds(10)) {
            await received.items.count == payloads.count
        }
        let objects = await received.items.sorted { $0.object < $1.object }
        #expect(
            arrived,
            """
            only \(objects.count) of \(payloads.count) objects crossed the relay, log:
            \(relay.logContents)
            """
        )
        #expect(objects.map { String(decoding: $0.payload, as: UTF8.self) } == payloads)
        #expect(objects.map(\.object) == [0, 1, 2], "object IDs must survive the relay")

        // Both properties, byte for byte. A relay that dropped the configuration
        // would leave a viewer unable to tell that a publisher had changed the
        // shape of its picture, and a relay that mangled it would have them decode
        // the new shape against the old description.
        #expect(objects.first?.properties.configuration == configuration)
        #expect(DecoderConfiguration.decode(objects[0].properties.configuration ?? Data()) == sets)
        #expect(objects[1].properties.captureTime?.nanoseconds == 33_000_000)
        #expect(objects.dropFirst().allSatisfy { $0.properties.configuration == nil })

        reader.cancel()
        await subscription.cancel()
        await announcement.withdraw()
        await publisher.close(code: 0, reason: "done")
        await subscriber.close(code: 0, reason: "done")
    }
}

/// Every draft the relay serves, each offered on its own so the relay can't
/// quietly pick the other.
let interopDrafts = ["moqt-22", "moqt-19"]

/// A `moqom-relay` process on a loopback port, and the pin needed to reach it.
///
/// The relay prints two lines on stdout before its first accept — the
/// certificate hash and the bound address — which is what makes this work without
/// a fixed port or a checked-in certificate. Reading them is also how the harness
/// knows the relay is listening, rather than polling the port and racing it.
final class RelayProcess {
    /// Where the relay binary is, if the environment says so.
    static var relayBinary: String? {
        ProcessInfo.processInfo.environment["MOQOM_RELAY_BIN"].flatMap { path in
            FileManager.default.isExecutableFile(atPath: path) ? path : nil
        }
    }

    static var isAvailable: Bool { relayBinary != nil }

    private let process: Process
    private let host = "localhost"
    private let port: UInt16
    private let trust: RelayTrust

    /// Where this relay is writing its log.
    let log: URL

    /// What the relay has logged so far.
    ///
    /// Worth quoting in a failure: the relay's account of what it thought was
    /// happening is the only one available, and a failure here is otherwise just
    /// "nothing arrived".
    var logContents: String {
        (try? String(contentsOf: log, encoding: .utf8)) ?? "(no log)"
    }

    /// Start a relay and wait until it is listening.
    static func start() throws -> RelayProcess {
        guard let binary = relayBinary else { throw InteropUnavailable() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        var environment = ProcessInfo.processInfo.environment
        // Port zero because tests run in parallel and each starts its own relay,
        // and the wildcard address because `localhost` resolves to `::1` before
        // `127.0.0.1` on macOS — a relay bound only to the IPv4 loopback never
        // sees a packet, and the symptom is a handshake that hangs rather than
        // one that is refused.
        environment["MOQOM_RELAY_ADDR"] = "[::]:0"
        environment["MOQOM_RELAY_NAMES"] = "localhost"
        process.environment = environment

        let output = Pipe()
        process.standardOutput = output
        // To a file rather than a pipe: the relay's log is the only account of
        // what it thought was happening, and it is what a failure here is
        // diagnosed from — but a pipe nobody drains fills up and blocks the
        // process it is meant to be observing.
        let log = Self.logFile()
        process.standardError = try FileHandle(forWritingTo: log)
        try process.run()

        let announced = try Self.readAnnouncement(from: output)
        return RelayProcess(
            process: process,
            port: announced.port,
            trust: .pinned(base64CertificateHashes: [announced.certificateHash]),
            log: log
        )
    }

    /// Somewhere for one relay's log to go.
    private static func logFile() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("moqom-relay-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return url
    }

    private init(process: Process, port: UInt16, trust: RelayTrust, log: URL) {
        self.process = process
        self.port = port
        self.trust = trust
        self.log = log
    }

    /// Stop the relay and wait for it to go.
    ///
    /// Explicit rather than in `deinit`: a subprocess outliving the test that
    /// started it keeps the test runner's own exit waiting, and the symptom is a
    /// suite that reports every test as passed and then never returns.
    func stop() {
        guard process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
    }

    deinit {
        stop()
        // The log outlives every assertion that quotes it, but not the run: a
        // few files per `swift test` accumulate in the temporary directory
        // otherwise, and the one worth reading is never the one still there.
        try? FileManager.default.removeItem(at: log)
    }

    /// Open a MOQT session to this relay over the system QUIC stack.
    func connect(alpn: String, credentials: DeviceCredentials) async throws -> MoqtSession {
        let carrier = try await NetworkQUICCarrier.connect(
            host: host,
            port: port,
            alpn: [alpn],
            trust: trust
        )
        return try await MoqtSession.connect(over: carrier, credentials: credentials)
    }

    /// Read the relay's two startup lines, or give up.
    ///
    /// The reading happens on a dispatch queue rather than here, because the
    /// obvious version — `read` in a loop with a deadline checked between
    /// iterations — cannot honour its own deadline: the check is only reached
    /// once a read returns, so a relay that starts and says nothing hangs the
    /// suite instead of failing it. The semaphore is the timeout, and it holds
    /// whatever the relay managed to say, so the failure can quote it.
    private static func readAnnouncement(
        from pipe: Pipe
    ) throws -> (certificateHash: String, port: UInt16) {
        let announcement = Announcement()
        let complete = DispatchSemaphore(value: 0)
        let handle = pipe.fileHandleForReading

        handle.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                // EOF: the relay exited. Signal rather than wait out the
                // timeout, so the message says what happened.
                handle.readabilityHandler = nil
                complete.signal()
                return
            }
            if announcement.absorb(chunk) {
                handle.readabilityHandler = nil
                complete.signal()
            }
        }

        defer { handle.readabilityHandler = nil }
        guard complete.wait(timeout: .now() + 30) == .success else {
            throw InteropStartupFailed(
                reason: "no announcement within 30s, saw: \(announcement.transcript)"
            )
        }
        guard let announced = announcement.announced else {
            throw InteropStartupFailed(
                reason: "the relay stopped early, saw: \(announcement.transcript)"
            )
        }
        return announced
    }
}

/// The relay's startup lines, accumulated a chunk at a time.
///
/// A chunk is not a line: a read can split one, and half of `listening:
/// [::]:51679` parses as a port that is a prefix of the real one. So the bytes
/// are buffered and only whole lines are interpreted.
///
/// Locked because it is written on the pipe's reader queue and read here after
/// the wait, including on the path where the wait timed out and the reader is
/// still going.
private final class Announcement: Sendable {
    private struct State {
        var buffer = Data()
        var certificateHash: String?
        var port: UInt16?
        var transcript = ""

        var announced: (certificateHash: String, port: UInt16)? {
            guard let certificateHash, let port else { return nil }
            return (certificateHash, port)
        }
    }

    private let state = Mutex(State())

    /// What has been read, for a failure message.
    var transcript: String { state.withLock(\.transcript) }

    /// Both lines, once both have arrived.
    var announced: (certificateHash: String, port: UInt16)? {
        state.withLock(\.announced)
    }

    /// Take `chunk`, and say whether the announcement is now complete.
    func absorb(_ chunk: Data) -> Bool {
        state.withLock { state in
            state.buffer.append(chunk)
            state.transcript += String(decoding: chunk, as: UTF8.self)

            while let newline = state.buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = String(
                    decoding: state.buffer[state.buffer.startIndex ..< newline],
                    as: UTF8.self
                )
                state.buffer.removeSubrange(state.buffer.startIndex ... newline)

                if let value = line.suffix(after: "certificate-hash: ") {
                    state.certificateHash = value
                } else if let value = line.suffix(after: "listening: ") {
                    // The address is `[::]:51679` or `127.0.0.1:51679`; the port
                    // is what follows the last colon either way.
                    state.port = value.split(separator: ":").last.flatMap { UInt16($0) }
                }
            }
            return state.announced != nil
        }
    }
}

private struct InteropUnavailable: Error, CustomStringConvertible {
    var description: String { "MOQOM_RELAY_BIN is not set to an executable relay" }
}

private struct InteropStartupFailed: Error, CustomStringConvertible {
    let reason: String
    var description: String { "the relay did not start: \(reason)" }
}

private extension String {
    /// The remainder after `prefix`, or `nil` if it is not there.
    func suffix(after prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
#endif
