// The one piece of state the whole app hangs off.
//
// `@Observable` and a plain class rather than an actor: this is view state, it
// is read during layout, and making it an actor would put a suspension point in
// every view body. The concurrency lives one layer down in `MoqomSession` and
// `RoomSession`, which are actors; this type is their main-actor mirror.

import Foundation
import MoqomCore
import MoqomKit
import MoqomLoopback
import Observation

#if os(iOS)
    import AVFAudio
#endif

@MainActor
@Observable
final class AppModel {
    enum Phase {
        case joining
        case connecting
        case inRoom(RoomModel)
        case failed(MoqomError)
    }

    private(set) var phase: Phase = .joining

    var username: String = ""
    var roomName: String = "demo"

    /// Where the relay is, and therefore whether this is a real broadcast.
    ///
    /// Configured rather than compiled in: given a host the sample dials it over QUIC, and
    /// given none it runs on the in-memory loopback exactly as it always has. That the
    /// switch is one line here is the point of the seam.
    ///
    /// Editable, because the interface is where a two-device run actually gets set up. A
    /// launch argument needs a Mac tethered to the phone, and the moment the screen locks or
    /// the app is reopened by hand the argument is gone and the build is silently back on the
    /// loopback — which looks exactly like a relay that works.
    var relay = RelayConfiguration.current()

    let launch = LaunchOptions.current()

    /// A four digit code standing in for the relay's address and certificate hash.
    ///
    /// Resolved over Bonjour at join, then discarded in favour of what it resolved to, so the
    /// settings below always show what is actually being dialled. A code that stayed as the
    /// configuration would leave the interface unable to say where the media went.
    var pairingCode: String

    /// Why the last pairing attempt found nothing, if it found nothing.
    ///
    /// Kept beside the field rather than raised as a failure screen. Nothing has been dialled
    /// yet, the settings typed by hand are still there to fall back on, and "no relay is
    /// advertising 4242" is a different sentence from "the relay refused".
    private(set) var pairingProblem: String?

    /// Publish one pinned rung on a disciplined clock, and measure what arrives.
    ///
    /// A mode rather than a build: the same app is the thing being measured, and a separate
    /// benchmark target would measure a different program. Off by default, because the clock
    /// discipline talks to an NTP server and the pinned rung is the wrong shape for a call.
    var measure: Bool

    init() {
        measure = launch.benchmark
        pairingCode = launch.pairingCode ?? ""
    }

    /// Guarded because SwiftUI may run a `task` more than once for the same view, and
    /// joining twice reports the second attempt as a failure on a session that is fine.
    private var joinedOnLaunch = false

    /// Prints the link's state while a measured run is going.
    private var reporter: Task<Void, Never>?

    /// Keeps the shared clock disciplined for as long as one is.
    private var timekeeping: Task<Void, Never>?

    var canJoin: Bool {
        if case .joining = phase { return !username.trimmed.isEmpty }
        return false
    }

    /// The relay's host as a text field sees it, where blank means the loopback.
    ///
    /// A field rather than a switch and a field, because "no relay" and "a relay whose
    /// address I have cleared" are the same intention and should not be two controls.
    var relayHost: String {
        get { relay.host ?? "" }
        set { relay.host = newValue.trimmed.isEmpty ? nil : newValue.trimmed }
    }

    /// The one certificate hash a development relay needs pinned.
    ///
    /// One rather than the list the configuration carries: a deployment behind a real
    /// certificate pins nothing, and a relay on the desk has exactly one. Somewhere between
    /// those is a case for a list, and it is not a case anyone types in by thumb.
    var relayCertificateHash: String {
        get { relay.certificateHashes.first ?? "" }
        set {
            relay.certificateHashes = newValue.trimmed.isEmpty ? [] : [newValue.trimmed]
        }
    }

    /// Join on the settings a script supplied, if it supplied any.
    ///
    /// Prints rather than only logging, so `devicectl process launch --console` makes the
    /// outcome legible from the Mac. Whether a phone can reach a relay at all is the first
    /// question of a two-device run and the console is where it gets answered.
    func joinOnLaunch() async {
        guard launch.autojoin, !joinedOnLaunch else { return }
        joinedOnLaunch = true

        username = launch.username ?? "device"
        roomName = launch.room ?? roomName
        print("JOINING relay=\(relay.summary) room=\(roomName) as=\(username)")

        await join()

        switch phase {
        case let .inRoom(room):
            print("JOINED relay=\(relay.summary) room=\(roomName)")
            guard launch.benchmark else { return }
            await room.startBroadcast()
            guard room.isBroadcasting else {
                print(
                    "GO LIVE FAILED "
                        + (room.lastError.map(String.init(describing:)) ?? "no reason given")
                )
                return
            }
            if let audio = launch.audio {
                room.audioInput = audio == "mic" ? .microphone : .tone
                await room.startAudio()
                if !room.isPublishingAudio {
                    print(
                        "AUDIO FAILED "
                            + (room.lastError.map(String.init(describing:)) ?? "no reason given")
                    )
                }
            }

            print(
                "LIVE rung=video/720p codec=hevc source=camera"
                    + " fps=\(Int(launch.frameRate ?? 30))"
                    + " playout=\(launch.playoutMilliseconds.map { "\($0)ms fixed" } ?? "adaptive")"
                    + " layers=\(launch.flatLayers ? "flat" : "temporal")"
                    + " audio=\(room.isPublishingAudio ? (launch.audio ?? "on") : "off")"
            )
        case let .failed(error): print("JOIN FAILED \(error)")
        default: print("JOIN ended in an unexpected state")
        }
    }

    /// Set the room up to be measured, without starting anything.
    ///
    /// Separate from going live because the button is the honest way to do this by hand: both
    /// phones are already in the room and pointed at each other before either starts sending,
    /// so the first frames measured are not the ones from before the far side was listening.
    ///
    /// One rung and one codec, because the point of a two-device run is a number, and a
    /// ladder gives a viewer three tracks to choose between while it is being taken.
    /// Keep exchanging with the authority for as long as the run lasts.
    ///
    /// The opening burst leaves an interval of a few tens of milliseconds, set by the shortest
    /// round trip among four attempts over Wi-Fi, and from then on it only widens as the anchor
    /// ages. That interval is the floor on what any cross-device latency figure can claim, so a
    /// run that measures a forty millisecond path against a thirty millisecond interval is
    /// reporting mostly its own ignorance. Every later exchange is another chance at a shorter
    /// round trip, and the clock keeps whichever anchor is worth the most.
    private func discipline(_ clock: TrustedClock) {
        timekeeping?.cancel()
        timekeeping = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { return }
                await clock.synchronise()
            }
        }
    }

    private func prepareMeasurement(in room: RoomModel) async {
        // Before anything is published, because frames stamped on an undisciplined clock
        // are frames the far side cannot measure. A failure here is not fatal — the run
        // still streams — but it is said out loud, since the alternative is a latency
        // figure quietly built on the device's own idea of the time.
        if let clock = try? Self.trustedClock() {
            // Synchronised repeatedly rather than once. The offset is the reply's stamp plus
            // half the round trip, so the error is bounded by that same half trip — the path
            // home may have taken all of it or none. Nothing can measure that asymmetry, but
            // a shorter exchange bounds it more tightly, and the clock keeps whichever anchor
            // is worth the most. So attempts can only narrow the interval, and the interval
            // is the floor on what any latency measured against it can claim.
            //
            // A dozen rather than four because four over Wi-Fi settled around ±30ms, which is
            // the same order as the 45ms path being measured. Wi-Fi round trips are not
            // distributed tightly around their median: most of the spread is scheduling and
            // retries, so the shortest of twelve is meaningfully shorter than the shortest of
            // four, and a dozen UDP exchanges cost nothing worth counting.
            var synchronised = false
            for _ in 0 ..< 12 {
                synchronised = await clock.synchronise() || synchronised
            }
            let now = await clock.now()
            print(
                synchronised
                    ? "CLOCK synchronised uncertainty=\(now.uncertainty)"
                    : "CLOCK NOT synchronised — latency across devices will be meaningless"
            )
            if synchronised {
                room.trustedStamp = clock.stamp
                discipline(clock)
            }
        } else {
            print("CLOCK unavailable — latency across devices will be meaningless")
        }

        room.videoInput = .camera
        let fps = launch.frameRate ?? 30

        // Bitrate with the frame rate, not fixed. Twice the frames at the same budget is half
        // the bits each, and a sixty frame run that looks worse than a thirty frame one has
        // measured the budget rather than the frame rate. Not doubled either — consecutive
        // frames sixteen milliseconds apart differ less than ones thirty-three apart, so the
        // extra cost of the same picture is well under two-fold.
        //
        // The base is what HEVC needs for a talking head at this size rather than what a
        // ladder built for H.264 asks for: 720p60 lands on two megabits, and the earlier
        // three was buying nothing visible while making two phones on one domestic uplink
        // compete for it. `--kbps` overrides the arithmetic entirely, which is how the
        // question "is the link full?" gets asked without also changing the frame rate.
        let bitrate = launch.kilobitsPerSecond.map { $0 * 1000 }
            ?? Int(1_250_000 * (1 + (fps / 30 - 1) * 0.6))

        room.pinnedRung = VideoLayer(
            id: "video/720p",
            size: PixelSize(width: 1280, height: 720),
            frameRate: fps,
            // One temporal layer for the same reason as one spatial rung: hierarchical
            // P-frames are nearly free to produce, but they let a receiver drop the top
            // sub-layer under pressure, and a run that silently becomes 15fps halfway
            // through still reports itself as 30.
            bitrate: bitrate,
            temporalLayers: 1
        )

        report(on: room)
    }

    /// Print what the link is doing, on a cadence a console can be read at.
    ///
    /// The publisher's own counters and the receiver's latencies together, because either
    /// alone invites the wrong conclusion: frames that never arrive look like low latency,
    /// and latency measured without the drop count looks like a link that is coping.
    #if os(iOS)
        private static func describe(_ route: AVAudioSessionRouteDescription) -> String {
            let outputs = route.outputs.map(\.portType.rawValue)
            return outputs.isEmpty ? "none" : outputs.joined(separator: ",")
        }
    #endif

    private static func describe(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    private func report(on room: RoomModel) {
        reporter?.cancel()
        reporter = Task { [weak room] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let room else { return }
                let stats = room.statistics
                print(
                    "LINK \(room.latency.report())"
                        + " received=\(stats?.link.received ?? 0)bps"
                        + " lost=\(stats?.link.objectsLost ?? 0)"
                        + " quality=\(room.quality)"
                )

                // The number the whole exercise is for, stated rather than left to be assembled
                // from two lines by whoever reads the log. Sensor to arrival is what the network
                // and the encoder cost; the buffer is what smoothness cost; the sum is what a
                // person waiting for a reply actually experiences.
                if let link = room.latency.reading(), link.frames > 0 {
                    // The wait charged is the headroom the frames actually have, not the delay
                    // that was asked for: a frame sits in the schedule until it is due, and how
                    // long that is depends on where the schedule was anchored as much as on the
                    // setting. Falling back to the setting only before there is a measurement.
                    let wait = (room.playoutSlack ?? room.playoutDepth.seconds) * 1000
                    print(
                        String(
                            format: "GLASS p50=%.0fms p95=%.0fms (link %.0f/%.0f + wait %.0f)",
                            link.median + wait,
                            link.p95 + wait,
                            link.median,
                            link.p95,
                            wait
                        )
                    )
                }

                // Alongside the latency rather than folded into it. A stream can be fast and
                // uneven or slow and smooth, and the two complaints have different causes.
                print("PLAY \(room.cadence.report())")

                // The publisher's timeline, beside the arrivals it should be independent of.
                // An even arrival cadence and an uneven timeline is motion that is wrong while
                // nothing is late or missing, and it is the only line here that can say so.
                if let timeline = room.timeline.report() { print("TIME \(timeline)") }

                // The last few inches, which nothing else covers. Frames counted as arrived by
                // PLAY and as lost by nobody can still fail to reach the screen, and a picture
                // that misses steps while every other line reads clean is what that looks like.
                let drawn = room.drawing
                print(
                    String(
                        format: "DRAW shown=%d late=%d undescribed=%d failures=%d"
                            + " backwards=%d reanchors=%d regrids=%d delivered=%.1f%%"
                            + " buffer=%.0fms",
                        drawn.enqueued,
                        drawn.skippedNotReady,
                        drawn.skippedUndescribed,
                        drawn.failures,
                        drawn.outOfOrder,
                        drawn.reanchors,
                        drawn.regrids,
                        drawn.delivered * 100,
                        room.playoutDepth.seconds * 1000
                    )
                )
                // The display pipeline's own account, which is the only one that can say a frame
                // was accepted and then not shown.
                if let shown = room.presentation {
                    print(
                        String(
                            format: "SHOW total=%d dropped=%d corrupted=%d delay=%.1f ms",
                            shown.total,
                            shown.dropped,
                            shown.corrupted,
                            shown.delay * 1000
                        )
                    )
                }

                print("GRAB \(room.captureCadence.report())")

                // Audio's own two ends, which share none of the machinery above. It is paced by
                // a device pulling at a fixed rate rather than by a display, so its buffer sizes
                // itself in packets and its failures are audible before they are visible in any
                // video figure: late packets are a buffer too shallow for the jitter, gaps are
                // slots concealed because nothing arrived at all, and the two are fixed by
                // opposite things.
                if let audio = stats?.publishing.audio {
                    print(
                        "TALK captured=\(audio.framesCaptured)"
                            + " published=\(audio.packetsPublished)"
                            + " dropped=\(audio.packetsDropped)"
                            + " silent=\(audio.silentPackets)"
                            // Both spacings, because the receiver sizes its buffer from how
                            // evenly packets arrive and cannot tell an uneven sender from an
                            // uneven network. Twenty milliseconds flat at both ends means the
                            // jitter the far side reports is genuinely the link's.
                            + String(
                                format: " grab p50=%.1f p95=%.1f max=%.1f",
                                audio.captureSpacing.median,
                                audio.captureSpacing.p95,
                                audio.captureSpacing.worst
                            )
                            + String(
                                format: " · send p50=%.1f p95=%.1f max=%.1f ms",
                                audio.publishSpacing.median,
                                audio.publishSpacing.p95,
                                audio.publishSpacing.worst
                            )
                    )
                }
                // The output path itself, which no counter above can see. A packet decoded and
                // handed to a player node in an engine that never opened is counted as played.
                #if os(iOS)
                    let session = AVAudioSession.sharedInstance()
                    print(
                        "OUT engine=\(AudioGraph.shared.isRunning ? "running" : "stopped")"
                            + " route=\(Self.describe(session.currentRoute))"
                            // What the hardware granted, which is the thing that decides how
                            // evenly packets leave here. A request is not a setting.
                            + String(format: " io=%.1fms", session.ioBufferDuration * 1000)
                            + " volume=\(String(format: "%.2f", session.outputVolume))"
                            + " mic=\(AVAudioApplication.shared.recordPermission == .granted ? "granted" : "not granted")"
                            + (room.lastError.map { " error=\($0)" } ?? "")
                    )
                #endif

                for (who, participant) in stats?.participants ?? [:] {
                    guard let heard = participant.audio else { continue }
                    print(
                        String(
                            format: "HEAR %@ received=%d played=%d late=%d duplicate=%d gaps=%d"
                                + " target=%.0fms jitter=%.1fms",
                            String(describing: who.username),
                            heard.packetsReceived,
                            heard.packetsPlayed,
                            heard.packetsLate,
                            heard.packetsDuplicate,
                            heard.gaps,
                            heard.targetDelay.seconds * 1000,
                            heard.jitter.seconds * 1000
                        )
                    )

                    // The last inch, which every line above is blind to: packets can arrive,
                    // decode, and be scheduled while containing nothing but zeros.
                    if let played = await room.playback(of: who) {
                        print(
                            String(
                                format: "  SPKR %@ buffers=%d silent=%d peak=%.3f"
                                    + " decoded=%d failed=%d gaps=%d silences=%d",
                                String(describing: who.username),
                                played.buffers,
                                played.silent,
                                played.peak,
                                played.decoding.packets,
                                played.decoding.failures,
                                played.decoding.gaps,
                                played.decoding.silences
                            )
                        )
                    }
                }

                // The device's own limits, which every other line here would blame on the
                // network. Capture at sixty, one hardware encode, one hardware decode and a
                // radio held busy is enough to warm a phone up, and iOS answers a warm phone
                // by slowing the camera down — so a capture cadence that decays while the
                // link stays clean is a thermal reading rather than a transport bug. Low
                // power mode does the same thing for a different reason and is worth the two
                // words it costs to rule out.
                print(
                    "HOST thermal=\(Self.describe(ProcessInfo.processInfo.thermalState))"
                        + " lowpower=\(ProcessInfo.processInfo.isLowPowerModeEnabled)"
                        // Whether the gyroscope currently has stabilisation switched on, which is
                        // the one power draw here that comes and goes on its own.
                        + (room.cameraIsMoving.map { " camera=\($0 ? "moving" : "steady")" } ?? "")
                )

                // What the publisher did with the frames it captured, which is where an
                // uneven arrival pattern is explained when the network turns out to be
                // healthy: a source delivering unevenly, or an encoder shedding frames it
                // could not keep up with, produces exactly the same picture at the far end as
                // a link that is losing them.
                if let video = stats?.publishing.video {
                    print(
                        "SEND submitted=\(video.framesSubmitted)"
                            + " encoded=\(video.framesEncoded)"
                            + " dropped=\(video.framesDropped)"
                            + " muted=\(video.framesMuted)"
                            + " unroutable=\(video.framesUnroutable)"
                            + " objects=\(video.objectsPublished)"
                    )

                    // The two stages between the camera and the wire, separately. Together they
                    // answer the question a frame rate cannot: whether a stutter was made here,
                    // before anything touched the network. An encoder whose p95 matches its
                    // median and a write path whose p95 is thirty times its own are the same
                    // total delay and completely different bugs.
                    print(
                        String(
                            format: "COST encode p50=%.1f p95=%.1f max=%.1f ms"
                                + " · write p50=%.1f p95=%.1f max=%.1f ms",
                            video.encodeLatency.median,
                            video.encodeLatency.p95,
                            video.encodeLatency.worst,
                            video.writeLatency.median,
                            video.writeLatency.p95,
                            video.writeLatency.worst
                        )
                    )
                }

                // Per publisher as well as per link, because the two failures they
                // distinguish look identical from the link alone. A viewer subscribed to a
                // rung nobody publishes has a healthy connection carrying nothing, and a
                // viewer that never subscribed at all has the same. The rung, the box that
                // chose it, and whether anything has ever arrived are the three facts that
                // tell those apart.
                for who in room.participants.map(\.slot.identity)
                    where who != room.identity
                {
                    let mine = stats?.participants[who]
                    let box = room.layout.lastReported[who]
                    print(
                        "  VIEW \(who.username.value)"
                            + " rung=\(mine?.layer?.value ?? "none")"
                            + " box=\(box.map { "\($0.pixelSize.width)x\($0.pixelSize.height)" } ?? "unreported")"
                            + " frames=\(mine?.video?.framesProduced ?? 0)"
                            // Separated from a network failure on purpose: objects arriving
                            // and being thrown away for want of a keyframe is also a black
                            // tile, and the remedy is the publisher's, not the link's.
                            + " nokey=\(mine?.video?.objectsAwaitingKeyFrame ?? 0)"
                            + " offers=\(room.catalogs[who]?.videoLadder.rungs.map(\.id.value).joined(separator: ",") ?? "no catalog")"
                            + " silent=\(mine?.silentFor.map { "\($0)" } ?? "never arrived")"
                    )
                }
            }
        }
    }

    /// A clock disciplined against the same service the other device uses.
    private static func trustedClock() throws -> TrustedClock {
        TrustedClock(
            authority: NTPAuthority(exchange: try UDPExchange.cloudflare())
        )
    }

    func join() async {
        guard canJoin else { return }
        phase = .connecting
        pairingProblem = nil

        // Before the transport is built, since what it resolves to decides both where to dial
        // and which certificate to pin. A code that resolves to nothing stops here rather
        // than quietly dialling whatever was in the fields, which is how a run ends up
        // measuring the loopback and reporting it as a network.
        if !pairingCode.trimmed.isEmpty {
            guard let paired = await RelayPairing.find(code: pairingCode) else {
                pairingProblem =
                    "Nothing is advertising \(pairingCode.trimmed) on this network."
                phase = .joining
                return
            }
            relay = paired
            pairingCode = ""
        }

        relay.save()

        do {
            let identity = try ParticipantIdentity(
                username: Username(username.trimmed),
                // A real client derives this from the Secure Enclave key the
                // token's `cnf` claim is bound to, at install.
                device: DeviceID(thumbprint: "sample-device-key")
            )
            let session = MoqomSession(
                transport: relay.transport(),
                credentials: DeviceCredentials(
                    identity: identity,
                    token: Data(),
                    proofSigner: { challenge in challenge }
                ),
                tenant: "demo",
                // The sample opts in, because the sample is what an integrator
                // reads to find out that this exists. `.hashed` even here: a
                // demo's log is the one most likely to end up in a screenshot.
                logger: MoqomLogger(
                    sink: SystemLogSink(subsystem: "cloud.moqom.sample", privacy: .hashed),
                    minimum: .debug
                )
            )
            try await session.connect(to: relay.endpoint)
            let room = try await session.join(room: RoomID(roomName))
            let model = RoomModel(
                session: session,
                room: room,
                identity: identity,
                statisticsInterval: launch.statisticsMilliseconds
                    .map { .milliseconds($0) } ?? .milliseconds(250)
            )
            model.flatLayers = launch.flatLayers

            // A figure given on the command line is a figure to be obeyed, so it turns the
            // adaptation off: the point of passing one is to see what that exact delay does.
            if let playout = launch.playoutMilliseconds {
                model.playoutBounds = nil
                model.playoutDelay = playout > 0 ? .milliseconds(playout) : nil
            }
            if let tolerance = launch.playoutTolerance {
                model.playoutTolerance = tolerance
            }
            if let floor = launch.playoutFloorMilliseconds, var bounds = model.playoutBounds {
                bounds.floor = .milliseconds(floor)
                model.playoutBounds = bounds
            }
            if measure { await prepareMeasurement(in: model) }
            phase = .inRoom(model)
        } catch let error as MoqomError {
            phase = .failed(error)
        } catch let error as NameError {
            phase = .failed(.invalidName(error))
        } catch {
            phase = .failed(.transport(.unreachable))
        }
    }

    func leave() async {
        reporter?.cancel()
        timekeeping?.cancel()
        timekeeping = nil
        if case let .inRoom(model) = phase {
            await model.leave()
        }
        phase = .joining
    }

    func dismissError() {
        phase = .joining
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
