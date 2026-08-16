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
    import QuartzCore
    import UIKit
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

    /// Both remembered, like the relay's address and for the same reason.
    ///
    /// They are also half of what a token is minted against, so a phone that forgets them is
    /// a phone that dials a real relay holding a credential for somebody else in another
    /// room. Set in ``init``, saved on joining.
    var username: String
    var roomName: String

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

    #if os(iOS)
        /// What the panel is refreshing at while the call runs. See ``PanelRate``.
        let panelRate = PanelRate.shared
    #endif

    /// The shared call on the GCP relay.
    ///
    /// Two phones that type the same code join the same room there and go live. It is
    /// not a lookup: nothing is browsed on the LAN. Kept after join so the next tap
    /// is the same call, not a drop back onto whatever room name was left in the field.
    var pairingCode: String

    /// Publish one pinned rung on a disciplined clock, and measure what arrives.
    ///
    /// A mode rather than a build: the same app is the thing being measured, and a separate
    /// benchmark target would measure a different program.
    ///
    /// On by default, which it was not, because the figure it produces is the one everybody
    /// asks for first and half of it cannot be had without the other device. A run with this
    /// off shows the receiving phone's own playout hold and says underneath that the total
    /// needs both — which reads, reasonably enough, as a glass-to-glass figure of forty
    /// milliseconds. The cost is a handful of NTP exchanges on joining.
    ///
    /// The pinned rung is *not* part of it, and used to be. Pinning is what a benchmark wants
    /// — one rung so both ends agree on what is being measured — and it is wrong for a call,
    /// where the ladder and the layer selector are half the product. Bundling them meant the
    /// only configuration that reported latency was also the only one that never exercised
    /// selection.
    var measure: Bool

    init(defaults: UserDefaults = .standard) {
        Journal.shared.begin()
        measure = true
        pairingCode = launch.pairingCode ?? defaults.string(forKey: "pairingCode") ?? ""
        username = defaults.string(forKey: "username") ?? ""
        roomName = defaults.string(forKey: "roomName") ?? "demo"
        if !RelayConfiguration.relayHostOverridden {
            relay.useDevelopmentEndpoint()
        }

        // From launch, because the first tile sizes its schedule against this and a link that has
        // not ticked yet leaves it guessing from the screen's stated maximum.
        #if os(iOS)
            PanelRate.shared.start()
        #endif
    }

    /// Everything the join screen asked for, kept for the next launch.
    private func remember(to defaults: UserDefaults = .standard) {
        defaults.set(username, forKey: "username")
        defaults.set(roomName, forKey: "roomName")
        defaults.set(pairingCode, forKey: "pairingCode")
        relay.save(to: defaults)
    }

    /// Guarded because SwiftUI may run a `task` more than once for the same view, and
    /// joining twice reports the second attempt as a failure on a session that is fine.
    private var joinedOnLaunch = false

    /// Prints the link's state while a measured run is going.
    private var reporter: Task<Void, Never>?

    /// The display pipeline's counters as of the last report, for reporting the change.
    private var lastPresentation: VideoRenderer.Presentation?

    /// Keeps the shared clock disciplined for as long as one is.
    private var timekeeping: Task<Void, Never>?

    /// Stands in for a finger, in a run that has none.
    private var popping: Task<Void, Never>?

    /// Turns the published picture on its side and back, in the same sort of run.
    private var reshaping: Task<Void, Never>?

    /// Change the shape of what is published every so often.
    ///
    /// The publisher's half of a two-log test. What it prints is the intent and the moment,
    /// and the answer is in the other phone's log: a `RECV` line whose dimensions change at
    /// the same second, without the gap counter moving and without a stall being reported.
    /// Both halves are needed, because a publisher can report a reshape it completed
    /// perfectly and still have handed its viewers a black flash.
    private func reshapeRepeatedly(in room: RoomModel, every seconds: Double) {
        reshaping?.cancel()
        reshaping = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                if Task.isCancelled { return }
                guard await room.isBroadcasting else { continue }

                let next: RoomModel.Shape = await room.publishShape == .upright
                    ? .sideways
                    : .upright
                await room.setPublishShape(next)
                Journal.shared.say("SHAPE publishing \(next.rawValue.lowercased())")
            }
        }
    }

    /// Pop a bubble every so often, so a scripted run exercises intents.
    ///
    /// The scores in the two logs are what this is for: a pop is decided by one
    /// device and has to arrive at the other as a number that matches. Nothing
    /// a single phone prints can tell those apart from a pop that was applied
    /// locally and never left.
    private func popRepeatedly(in room: RoomModel, every seconds: Double) {
        popping?.cancel()
        popping = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                if Task.isCancelled { return }
                // Silent when there is nothing up, which is the first few
                // seconds of a field and not worth a line each time.
                if await room.popSomething() { Journal.shared.say("SPACE popped") }
            }
        }
    }

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

    /// The token as a text field sees it: something to paste, and blank for none.
    ///
    /// A field at all because there was no way to put a credential on a phone without a Mac
    /// attached to it, which made the deployed relays reachable only from a script.
    var relayToken: String {
        get { String(decoding: relay.token, as: UTF8.self) }
        set { relay.token = Data(newValue.trimmed.utf8) }
    }

    /// The token service's address, as a text field sees it.
    ///
    /// Clearing it turns the whole mechanism off and puts the pasted token back in
    /// charge, which is the right behaviour for a field: "no service" and "a
    /// service whose address I have deleted" are one intention.
    var joinHost: String {
        get { relay.tokenService?.host ?? "" }
        set {
            var service = relay.tokenService ?? JoinService.development
            service.host = newValue.trimmed
            relay.tokenService = service
        }
    }

    var joinPort: String {
        get { (relay.tokenService?.port).map(String.init) ?? "8444" }
        set {
            var service = relay.tokenService ?? JoinService.development
            service.port = UInt16(newValue.trimmed) ?? service.port
            relay.tokenService = service
        }
    }

    var joinCertificateHash: String {
        get { relay.tokenService?.certificateHashes.first ?? "" }
        set {
            var service = relay.tokenService ?? JoinService.development
            service.certificateHashes = newValue.trimmed.isEmpty ? [] : [newValue.trimmed]
            relay.tokenService = service
        }
    }

    /// The device's enrolment credential.
    ///
    /// The one field on this screen that is a durable secret. Everything else is an
    /// address, and the pasted token above dies by lunchtime; this is what buys the
    /// next one months from now, which is why it lives in the Keychain and why the
    /// interface should not print it back in full.
    var joinCredential: String {
        get { relay.tokenService?.credential ?? "" }
        set {
            var service = relay.tokenService ?? JoinService.development
            service.credential = newValue.trimmed
            relay.tokenService = service
        }
    }

    /// A link this app was opened with, waiting for somebody to agree to it.
    ///
    /// Held rather than applied. See ``Invitation``: a URL can arrive from
    /// anywhere, and this one names the relay to trust and the credential to
    /// present.
    var offered: Invitation?

    /// Read a `moqom://join?...` the app was opened with.
    ///
    /// Kept even while a room is up, and shown when the join screen next
    /// appears. Applying it mid-call would swap the relay under a live session,
    /// and discarding it would mean a link scanned a moment too early is a link
    /// that silently did nothing.
    func offer(_ url: URL) {
        guard let invitation = Invitation(url) else {
            Journal.shared.say("INVITE unreadable \(url.absoluteString.prefix(60))")
            return
        }
        Journal.shared.say("INVITE \(invitation.destination)")
        offered = invitation
    }

    /// Take the link that arrived: address, trust, credential, and who it says
    /// this phone is.
    ///
    /// The name and the room come out of the token rather than from the link's
    /// own fields, so the two cannot contradict each other. That contradiction
    /// is not hypothetical — a token minted for one room against a screen
    /// showing another is a relay refusing every track, which on the phone is a
    /// Join that works and a Go live that does nothing.
    func acceptOffer() {
        guard let invitation = offered else { return }
        offered = nil

        relay = RelayConfiguration(
            host: invitation.relay.endpoint.host,
            port: invitation.relay.endpoint.port,
            certificateHashes: invitation.relay.certificateHashes,
            token: invitation.relay.token,
            // Kept only when the link names one. A link with no service in it
            // leaves whatever this phone was already enrolled with, because
            // scanning a code for a relay on a desk should not un-enrol a phone
            // from the deployment it can otherwise reach.
            tokenService: invitation.relay.tokenService.map {
                JoinService(
                    host: $0.endpoint.host,
                    port: $0.endpoint.port,
                    certificateHashes: $0.certificateHashes,
                    credential: $0.credential
                )
            } ?? relay.tokenService
        )
        // A pairing code left in the field would be the room on the next Join
        // and throw away the room this invitation named.
        pairingCode = ""

        if let credential = invitation.credential {
            if !credential.subject.isEmpty { username = credential.subject }
            if !credential.room.isEmpty { roomName = credential.room }
        }
        remember()
    }

    func declineOffer() { offered = nil }

    /// What the token in hand says about itself, and whether it suits this join.
    var credential: Credential? { relay.credential }

    var credentialComplaint: String? {
        credential?.complaint(joining: destinationRoomName(pairing: pairing), as: username.trimmed)
    }

    /// Where Join puts this device, given the fields as they stand.
    ///
    /// Pairing is the shared call on the GCP relay. `@ada` is a watch. A `--room`
    /// from a script still wins, because benches share a code as the room and a
    /// room name to stay off this path. Empty everything is a solo channel.
    private enum Destination {
        case channel
        case watch(String)
        case room(String)
    }

    private var pairing: String? {
        let code = pairingCode.trimmed
        return code.isEmpty ? nil : code
    }

    private func destination(pairing: String?) -> Destination {
        let room = roomName.trimmed
        if room.hasPrefix("@") { return .watch(String(room.dropFirst())) }
        if let launched = launch.room?.trimmed, !launched.isEmpty { return .room(launched) }
        if let pairing { return .room(pairing) }
        if !room.isEmpty { return .room(room) }
        return .channel
    }

    private func destinationRoomName(pairing: String?) -> String {
        switch destination(pairing: pairing) {
        case .channel: return ""
        case let .watch(name): return "@\(name)"
        case let .room(name): return name
        }
    }

    /// Join on the settings a script supplied, if it supplied any.
    ///
    /// Whether a phone can reach a relay at all is the first question of a two-device run.
    /// The journal is where it gets answered — stdout only in Debug, because a live console
    /// pipe over Wi-Fi is traffic on the radio the call is using.
    func joinOnLaunch() async {
        // Filled in whether or not this launch joins by itself, because the name and the room
        // are half of what a token is minted against. A launch that supplies a token and no
        // autojoin used to leave the fields at their defaults, so the person tapping Join
        // reached room `demo` as nobody, holding a credential naming somebody in another room
        // — which the relay is right to refuse and which looks, on the phone, like a button
        // that does nothing.
        username = launch.username ?? username
        roomName = launch.room ?? roomName

        guard launch.autojoin, !joinedOnLaunch else { return }
        joinedOnLaunch = true

        if username.isEmpty { username = "device" }
        Journal.shared.say(
            "JOINING relay=\(relay.summary) room=\(destinationRoomName(pairing: pairing)) as=\(username)"
        )

        await join()

        switch phase {
        case let .inRoom(room):
            Journal.shared.say(
                "JOINED relay=\(relay.summary) room=\(destinationRoomName(pairing: pairing))"
            )
            guard launch.goesLive else { return }

            // Before the broadcast, because going live now brings a voice with it. Named
            // rather than matched against one value with everything else falling through to
            // the tone: `--audio 1` was accepted that way and published beeps for a run that
            // was listening for voices, and nothing said so.
            if let audio = launch.audio {
                switch audio {
                case "mic": room.audioInput = .microphone
                case "tone": room.audioInput = .tone
                default:
                    Journal.shared.say("AUDIO UNKNOWN \(audio) — expected mic or tone; using the microphone")
                    room.audioInput = .microphone
                }
            } else {
                // Silent on purpose. A benchmark that publishes a voice nobody asked for is
                // measuring a different link from the one the run was set up to measure.
                await room.stopAudio()
            }

            await room.startBroadcast()
            guard room.isBroadcasting else {
                Journal.shared.say(
                    "GO LIVE FAILED "
                        + (room.lastError.map(String.init(describing:)) ?? "no reason given")
                )
                return
            }
            if launch.audio != nil, !room.isPublishingAudio {
                Journal.shared.say(
                    "AUDIO FAILED "
                        + (room.lastError.map(String.init(describing:)) ?? "no reason given")
                )
            }

            let live = room.pinnedRung ?? room.rungForLayout()
            Journal.shared.say(
                // The rung as it is now rather than as it was pinned, because the size follows
                // the layout and the pin is only the benchmark's. See ``RoomModel/followLayout``.
                "LIVE rung=\(live.id.value)"
                    + " \(live.size.width)x\(live.size.height)@\(Int(live.frameRate))"
                    + " \(live.bitrate / 1000)kbps layers=\(live.temporalLayers)"
                    + " codec=hevc source=\(room.videoInput.rawValue)"
                    + " fps=\(Int(launch.frameRate ?? 60))"
                    + " playout=\(launch.playoutMilliseconds.map { "\($0)ms fixed" } ?? "adaptive")"
                    + " layers=\(launch.flatLayers ? "flat" : "temporal")"
                    + " encode=\(launch.eagerEncoding ? "eager" : "efficient")"
                    + " audio=\(room.isPublishingAudio ? (launch.audio ?? "on") : "off")"
                    + " queue=\(launch.bestEffort ? "best-effort" : "interactive-video")"
            )

            if let every = launch.reshapeEverySeconds {
                reshapeRepeatedly(in: room, every: every)
            }

            // After the broadcast, because the field is drawn in the scene's
            // view and there is no scene until something is being published
            // from one.
            if launch.bubbles {
                await room.startSharing()
                if let every = launch.popEverySeconds {
                    popRepeatedly(in: room, every: every)
                }
            }
        case let .failed(error): Journal.shared.say("JOIN FAILED \(error)")
        default: Journal.shared.say("JOIN ended in an unexpected state")
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
            Journal.shared.say(
                synchronised
                    ? "CLOCK synchronised uncertainty=\(now.uncertainty)"
                    : "CLOCK NOT synchronised — latency across devices will be meaningless"
            )
            if synchronised {
                room.trustedStamp = clock.stamp
                discipline(clock)
            }
        } else {
            Journal.shared.say("CLOCK unavailable — latency across devices will be meaningless")
        }

        // Only when asked. Absent `--video` the room keeps its own default — the AR
        // field on a phone — so a hand launch and a scripted one without the flag
        // are the same call.
        if let video = launch.video {
            switch video {
            case "pattern": room.videoInput = .pattern
            case "scene", "ar": room.videoInput = .scene
            default: room.videoInput = .camera
            }
        }

        // Sixty, which is what every measurement of this application has been taken at and what
        // the capture, encode and presentation paths are tuned around. Thirty was the default for
        // as long as the frame rate was only ever set from the command line, and the effect of
        // leaving it there was that the app a person opens by hand behaved unlike the one being
        // measured — the same build, half the frames, and no indication which one you were
        // looking at.
        let fps = launch.frameRate ?? 60

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

        // The rate reaches the publisher either way: a call chooses its own rung from the
        // layout and this is the one part of it a run is allowed to dictate.
        room.publishFrameRate = fps

        // Beyond that, only a benchmark pins anything. A call sizes its rung from the layout
        // — see ``RoomModel/rungForLayout()`` — and a measured run wants a figure that does
        // not move when somebody changes the screen.
        guard launch.benchmark else {
            report(on: room)
            return
        }

        room.pinnedRung = VideoLayer(
            id: "video/720p",
            // Upright, which is how the phone is held and therefore the only shape whose
            // pixels are all picture. The same rung landscape spends a third of its budget
            // on the ceiling and the desk either side of whoever is talking.
            size: RoomModel.defaultCaptureSize,
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

    /// What is left in the battery, and whether it is being filled while we watch.
    ///
    /// Here because the thermal state is four buckets and a slow one: a phone doing half again
    /// the work of another reports `nominal` alongside it for the first quarter of an hour, so a
    /// comparison between two settings either runs long enough to bake both or says nothing.
    /// Charge falls continuously and in minutes, which makes it the measurement a power question
    /// actually wants, with the thermal state as the thing it eventually causes.
    ///
    /// The plug state is reported with it because it decides whether any of it means anything.
    /// A phone on a cable is being warmed by the charger and its level is pinned, so a soak run
    /// against one measures the charger — and over a local network tunnel, which is how these are
    /// driven, there is nothing else that would say so.
    private static func charge() -> String {
        #if os(iOS)
            UIDevice.current.isBatteryMonitoringEnabled = true
            let level = UIDevice.current.batteryLevel
            let state = switch UIDevice.current.batteryState {
            case .charging: "charging"
            case .full: "full"
            case .unplugged: "unplugged"
            default: "unknown"
            }

            // Negative is what this reports when monitoring has only just been switched on, and
            // it is worth saying so rather than printing it: a run whose first samples read -100%
            // has a battery column that cannot be differenced.
            guard level >= 0 else { return " charge=pending power=\(state)" }
            return String(format: " charge=%.0f%% power=%@", level * 100, state)
        #else
            return ""
        #endif
    }

    private func report(on room: RoomModel) {
        reporter?.cancel()
        reporter = Task { [weak room] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let room else { return }
                let stats = room.statistics
                Journal.shared.say(
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
                    // The wait charged is what the frames actually wait, not the delay that was
                    // asked for: a frame sits in the schedule until it is due, and how long that
                    // is depends on where the schedule was anchored as much as on the setting.
                    // Falling back to the setting only before there is a measurement.
                    let wait = (room.playoutHold ?? room.playoutDepth.seconds) * 1000
                    Journal.shared.say(
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

                // Lip sync, stated as one signed number rather than left to be inferred from
                // the four it is made of. Both media are quoted against the same clock and
                // measured to the point where a person receives them: a picture reaches the
                // eye when the network has delivered it and the playout schedule has held it,
                // and a voice reaches the ear when the network has delivered it, the jitter
                // buffer has let it go, the queue in front of the speaker has drained to it
                // and the device's output path has finished with it.
                //
                // Positive means the picture is behind the voice. Negative means the face
                // moves first, which is the one people notice, and which is what a phone on
                // this stack did by a fifth of a second while every counter looked healthy.
                if let picture = room.latency.reading(), picture.frames > 0,
                   let voice = room.voiceLatency.reading(), voice.frames > 0 {
                    let eye = picture.median + (room.playoutHold ?? room.playoutDepth.seconds) * 1000
                    let ear = voice.median + room.earDelay.seconds * 1000
                    Journal.shared.say(
                        String(
                            format: "SYNC %+.0fms (eye %.0f = link %.0f + wait %.0f,"
                                + " ear %.0f = link %.0f + hold %.0f)",
                            eye - ear,
                            eye,
                            picture.median,
                            eye - picture.median,
                            ear,
                            voice.median,
                            room.earDelay.seconds * 1000
                        )
                    )
                }

                // Alongside the latency rather than folded into it. A stream can be fast and
                // uneven or slow and smooth, and the two complaints have different causes.
                Journal.shared.say("PLAY \(room.cadence.report())")

                // The publisher's timeline, beside the arrivals it should be independent of.
                // An even arrival cadence and an uneven timeline is motion that is wrong while
                // nothing is late or missing, and it is the only line here that can say so.
                if let timeline = room.timeline.report() { Journal.shared.say("TIME \(timeline)") }

                // The last few inches, which nothing else covers. Frames counted as arrived by
                // PLAY and as lost by nobody can still fail to reach the screen, and a picture
                // that misses steps while every other line reads clean is what that looks like.
                let drawn = room.drawing
                Journal.shared.say(
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
                        // Where those frames were drawn, which is the one question the counters
                        // cannot answer: a layer that is detached or laid out at nothing accepts
                        // frames, presents them, and shows a person nothing at all.
                        + String(
                            format: " on-screen=%@ tile=%.0fx%.0f tiles=%d",
                            room.tileIsOnScreen ? "yes" : "no",
                            room.tileSize.width,
                            room.tileSize.height,
                            room.tileCount
                        )
                        // The shape being decoded, beside the tile it is drawn in. Together
                        // they answer whether a layout change landed: the two dimensions
                        // change within a frame of each other, `reshapes` goes up by one, and
                        // the gap and stall counters above do not move. A picture that
                        // changed shape while the tile did not is a reshape the receiver
                        // took and the interface ignored, which reads as letterboxing.
                        + String(
                            format: " shape=%@ reshapes=%d handbacks=%d",
                            room.receivedShape.map { "\($0.width)x\($0.height)" } ?? "unknown",
                            drawn.reshapes,
                            drawn.handbacks
                        )
                        + String(
                            format: " drains=%d refills=%d/%d",
                            drawn.drains, drawn.refills, drawn.observations
                        )
                        + String(
                            format: " gapped=%d crowded=%d stale=%d repaid=%d speed=%d/%.1f%%",
                            drawn.gapped, drawn.crowded, drawn.stale, drawn.reclaimedSlots,
                            drawn.speedShifts, drawn.widestSpeed * 100
                        )
                        + String(
                            format: " grid=%.3f source=%.3f ms phase=%.2f/%.2f ms lead=%.2f/%.0f",
                            drawn.laid * 1000, drawn.arriving * 1000,
                            drawn.phase * 1000, drawn.worstPhase * 1000,
                            drawn.lead, drawn.worstLead
                        )
                        // And whether anything is presenting them. A rate of zero is a queue
                        // filling up behind a clock that never started, which every count above
                        // reports as a stream in perfect health.
                        + String(
                            format: " rate=%.2f ahead=%.0fms status=%d%@",
                            room.timing.rate,
                            room.timing.ahead * 1000,
                            room.timing.status,
                            room.timing.needsFlush ? " needs-flush" : ""
                        )
                        // The figure the delay is actually chosen from, which is the worst few
                        // arrivals rather than the typical one. Read it beside `ahead`: a wide
                        // gap between them is a link delivering in bursts, and a buffer sized
                        // for the tail while the median sits far inside it.
                        + (room.timing.headroom.map {
                            String(format: " headroom=%.0fms", $0 * 1000)
                        } ?? "")
                        // Delivery pauses, and the arrivals not charged to the link because of
                        // them. Widenings that track the pauses are a call paying permanent
                        // latency for transient interruptions.
                        + String(format: " pauses=%d dismissed=%d", drawn.pauses, drawn.dismissed)
                        // How far apart the two devices' clocks run, in parts per million, as
                        // measured by what it takes to stay level with the publisher. Tens of
                        // it is two ordinary crystals; a figure against the limit is the loop
                        // saying the drift is coming from somewhere other than the hardware.
                        + String(format: " trim=%.0fppm", drawn.trim)
                        // How the delay got to where it is, which the delay itself cannot say.
                        // Widenings mean the link's jitter asked for it; a floor means lip sync
                        // did; and neither, with headroom to spare, means it is delay picked up
                        // from whichever frames the schedule anchored on — which the reclaim is
                        // meant to hand back, so a reclaim count that stays at zero while the
                        // delay climbs is the fault rather than the symptom.
                        + String(
                            format: " floor=%.0fms widen=%d tighten=%d floored=%d reclaim=%d",
                            room.playoutFloorInForce.seconds * 1000,
                            drawn.widenings,
                            drawn.tightenings,
                            drawn.floorRaises,
                            drawn.reclaims
                        )
                )
                // The display pipeline's own account, which is the only one that can say a frame
                // was accepted and then not shown.
                //
                // With the change since the last report beside the run's total, because the
                // total on its own cannot answer the only question anyone asks of it. A third
                // of the frames dropped reads as a broken pipeline; a third of the frames
                // dropped in the first two seconds and none since reads as a schedule
                // settling, and the two want opposite responses.
                if let shown = room.presentation {
                    let before = lastPresentation
                    lastPresentation = shown
                    Journal.shared.say(
                        String(
                            format: "SHOW total=%d dropped=%d corrupted=%d delay=%.1f ms"
                                + " · since=%d dropped=%d",
                            shown.total,
                            shown.dropped,
                            shown.corrupted,
                            shown.delay * 1000,
                            shown.total - (before?.total ?? 0),
                            shown.dropped - (before?.dropped ?? 0)
                        )
                            + (room.previewPresentation.map {
                                String(
                                    format: " · preview total=%d dropped=%d",
                                    $0.total,
                                    $0.dropped
                                )
                            } ?? "")
                    )
                }

                // Hoisted rather than inlined below: the chain it belongs to is long enough
                // that adding one more term puts the type-checker past its own budget.
                let delivered = (room.cameraDelivery.map {
                    String(
                        format: " deliver p50=%.1f p95=%.1f max=%.1f ms",
                        $0.median,
                        $0.p95,
                        $0.worst
                    )
                } ?? "")
                    + (room.cameraSensorRate.map { String(format: " sensor=%.0f", $0) } ?? "")

                Journal.shared.say(
                    "GRAB \(room.captureCadence.report())"
                        // What is in those frames, not just how many. Near zero is a black
                        // picture, which every other line here reports as a healthy stream.
                        + (room.captureBrightness.map { String(format: " luma=%.3f", $0) } ?? "")
                        // And what shape they are, which is the only place a capture
                        // connection that would not rotate becomes visible.
                        + (room.captureSize.map { " size=\($0.width)x\($0.height)" } ?? "")
                        + (room.cameraTurn.map { String(format: " turn=%.0f", $0) } ?? "")
                        // Which of the two turns it is. They are meant to be the same picture
                        // and were half a turn apart, so a run where the phones disagree about
                        // which way up they are is a run where this line disagrees too.
                        + (room.cameraTurnsInSoftware ? "(sw)" : "")
                        // What the camera cost before the encoder saw the frame, which the
                        // sensor-to-arrival figure charges to the link because it happens
                        // between the stamp and the first thing this code runs.
                        + delivered
                        // Whether the freezes in the cadence beside this are the system taking
                        // the camera away. They are not the same problem as a slow queue and
                        // they are indistinguishable from one downstream.
                        + (room.cameraInterruptions > 0
                            ? " interrupted=\(room.cameraInterruptions)"
                            + (room.lastCameraInterruption.map { " (\($0))" } ?? "")
                            : "")
                )

                // The same reading at the other end of the wire, decoded here from what
                // actually arrived. Paired with GRAB's it says which side of the link a black
                // tile is on, and it is the only line that can: everything else is a count of
                // frames, and a black picture is a frame.
                if room.receivedPictures > 0 {
                    Journal.shared.say(
                        "SEEN pictures=\(room.receivedPictures)"
                            + (room.receivedBrightness.map { String(format: " luma=%.3f", $0) }
                                ?? "")
                            + (room.receivedSize.map { " size=\($0.width)x\($0.height)" } ?? "")
                    )
                }

                // Audio's own two ends, which share none of the machinery above. It is paced by
                // a device pulling at a fixed rate rather than by a display, so its buffer sizes
                // itself in packets and its failures are audible before they are visible in any
                // video figure: late packets are a buffer too shallow for the jitter, gaps are
                // slots concealed because nothing arrived at all, and the two are fixed by
                // opposite things.
                if let audio = stats?.publishing.audio {
                    Journal.shared.say(
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
                    // The engine and the input device separately, because a mute is
                    // supposed to close one and leave the other alone, and the failure
                    // worth catching is the one where it closed both: a force-muted
                    // participant who cannot hear the room has been removed from it.
                    Journal.shared.say(
                        "OUT engine=\(AudioGraph.shared.isRunning ? "running" : "stopped")"
                            + " input=\(AudioGraph.shared.isMicrophoneSuspended ? "given back" : "held")"
                            + " route=\(Self.describe(session.currentRoute))"
                            // What the hardware granted, which is the thing that decides how
                            // evenly packets leave here. A request is not a setting.
                            + String(format: " io=%.1fms", session.ioBufferDuration * 1000)
                            // The hardware's own delay in each direction, which is
                            // part of mouth-to-ear and is charged to the media path
                            // by everything that only counts packets. Voice
                            // processing raises both, and a phone on a Bluetooth
                            // headset raises them by more than the network costs.
                            + String(
                                format: " out=%.0fms in=%.0fms",
                                session.outputLatency * 1000,
                                session.inputLatency * 1000
                            )
                            + String(
                                format: " late=%.0fms",
                                AudioGraph.shared.capturedLate.seconds * 1000
                            )
                            + " volume=\(String(format: "%.2f", session.outputVolume))"
                            // Which volume that figure is on, which decides whether it can
                            // reach zero at all: a chat mode is a call as far as iOS is
                            // concerned, and a call's output stops short of silence.
                            + " mode=\(session.mode.rawValue.replacingOccurrences(of: "AVAudioSessionMode", with: ""))"
                + " category=\(session.category.rawValue.replacingOccurrences(of: "AVAudioSessionCategory", with: ""))"
                + String(format: " mix=%.2f", AudioGraph.shared.playbackVolume)
                + String(
                    format: " heard=%.1fdB room=%.1fdB sent=%.1fdB",
                    AudioGraph.shared.meter.level,
                    AudioGraph.shared.meter.noiseFloor,
                    AudioGraph.shared.outputLevel
                )
                            + " mic=\(AVAudioApplication.shared.recordPermission == .granted ? "granted" : "not granted")"
                            + (room.lastError.map { " error=\($0)" } ?? "")
                    )
                #endif

                for (who, participant) in stats?.participants ?? [:] {
                    guard let heard = participant.audio else { continue }
                    Journal.shared.say(
                        String(
                            format: "HEAR %@ received=%d played=%d late=%d duplicate=%d gaps=%d"
                                + " target=%.0fms jitter=%.1fms interrupted=%d spacing=%.0fms",
                            String(describing: who.username),
                            heard.packetsReceived,
                            heard.packetsPlayed,
                            heard.packetsLate,
                            heard.packetsDuplicate,
                            heard.gaps,
                            heard.targetDelay.seconds * 1000,
                            heard.jitter.seconds * 1000,
                            heard.discontinuities,
                    heard.worstSpacing * 1000
                        )
                    )

                    // The last inch, which every line above is blind to: packets can arrive,
                    // decode, and be scheduled while containing nothing but zeros.
                    if let played = room.playback(of: who) {
                        Journal.shared.say(
                            String(
                                format: "  SPKR %@ buffers=%d silent=%d peak=%.3f"
                                    + " decoded=%d failed=%d gaps=%d silences=%d"
                                    + " queued=%.0fms target=%.0fms settled=%.0fms"
                                    + " covering=%.0fms pace=%.0fms"
                                    + " trimmed=%d dropped=%d starved=%d",
                                String(describing: who.username),
                                played.buffers,
                                played.silent,
                                played.peak,
                                played.decoding.packets,
                                played.decoding.failures,
                                played.decoding.gaps,
                                played.decoding.silences,
                                played.queued.seconds * 1000,
                                played.target.seconds * 1000,
                                played.settled.seconds * 1000,
                                played.covering.seconds * 1000,
                                played.pacing.seconds * 1000,
                                played.trimmed,
                                played.dropped,
                                played.starved
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
                // The panel's own rate belongs beside them, and for the same reason. A schedule
                // sized against a capability the panel is not currently honouring puts frames
                // just past a refresh boundary, and the display layer drops what it cannot show
                // in the period it has — which arrives looking like a network fault and is not.
                var panel = ""
                #if os(iOS)
                    if let period = panelRate.period, period > 0 {
                        panel = String(
                            format: " panel=%.0fHz slowest=%.0fHz",
                            1 / period,
                            1 / (panelRate.longest ?? period)
                        )
                    }
                #endif

                Journal.shared.say(
                    "HOST thermal=\(Self.describe(ProcessInfo.processInfo.thermalState))"
                        + " lowpower=\(ProcessInfo.processInfo.isLowPowerModeEnabled)"
                        + panel + Self.charge()
                )

                // What the publisher did with the frames it captured, which is where an
                // uneven arrival pattern is explained when the network turns out to be
                // healthy: a source delivering unevenly, or an encoder shedding frames it
                // could not keep up with, produces exactly the same picture at the far end as
                // a link that is losing them.
                if let video = stats?.publishing.video {
                    Journal.shared.say(
                        "SEND submitted=\(video.framesSubmitted)"
                            + " encoded=\(video.framesEncoded)"
                            + " dropped=\(video.framesDropped)"
                            + " muted=\(video.framesMuted)"
                            + " unroutable=\(video.framesUnroutable)"
                            + " objects=\(video.objectsPublished)"
                            + (video.encodersRebuilt > 0
                                ? " rebuilt=\(video.encodersRebuilt)" : "")
                            // Only once something has changed shape, because on a run that
                            // never does these are three zeros in the middle of the line
                            // people read for something else. When they do appear they are
                            // what a handover cost: how many, how many frames were thrown
                            // away because their encoder no longer owned the track, and how
                            // many changes were given up on. The last should be zero, and a
                            // reshape costing much more than a frame or two is the seam
                            // showing.
                            + (video.reshapes > 0 || video.reshapesAbandoned > 0
                                ? " reshapes=\(video.reshapes)"
                                    + " out-of-shape=\(video.framesOutOfShape)"
                                    + " abandoned=\(video.reshapesAbandoned)"
                                : "")
                            + " · encoder emitted=\(video.encoding.emitted)"
                            + " declined=\(video.encoding.declined)"
                            + " unreadable=\(video.encoding.unreadable)"
                            + " overrun=\(video.encoding.overrun)"
                    )

                    // What the scene handed over, when the source is one. The drawable's
                    // size is the number worth watching: it comes from the tile's layout
                    // rather than from the rung, so a scene can be published from fewer
                    // pixels than it is encoded at and nothing else here would say so.
                    #if canImport(ARKit) && !targetEnvironment(simulator)
                        if let scene = room.arScene {
                            Journal.shared.say("SCENE \(scene.status)")
                        }
                    #endif

                    // The shared space, from this device's point of view. Two
                    // logs side by side are the test: the bubble count and the
                    // scores are replicated state, so a line that differs
                    // between the phones is the replication failing — which is
                    // not otherwise visible from either one alone, since each
                    // renders its own copy perfectly happily.
                    if room.isSharing {
                        let scores = room.standings
                            .map { "\($0.who)=\($0.score)" }
                            .joined(separator: " ")
                        // The round as well as the field. An empty field means
                        // two completely different things depending on whether
                        // a round is running, and a log that could not tell
                        // them apart is a log that cannot answer the only
                        // question worth asking about a field with nothing in
                        // it.
                        let round = room.round.map {
                            " round=\($0.number)"
                                + (room.roundIsOver
                                    ? " over"
                                    : " left=\(room.secondsLeftInRound ?? 0)s")
                        } ?? " round=none"
                        Journal.shared.say(
                            "SPACE role=\(room.isRunningTheField ? "authority" : "follower")"
                                + round
                                + " bubbles=\(room.bubblesUp)"
                                + (scores.isEmpty ? "" : " · \(scores)")
                        )
                    }

                    // The two stages between the camera and the wire, separately. Together they
                    // answer the question a frame rate cannot: whether a stutter was made here,
                    // before anything touched the network. An encoder whose p95 matches its
                    // median and a write path whose p95 is thirty times its own are the same
                    // total delay and completely different bugs.
                    Journal.shared.say(
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
                    Journal.shared.say(
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

    /// The key this device's tokens are bound to, by the `cnf` claim.
    ///
    /// A constant, and it should not be: a real client generates a key in the
    /// Secure Enclave at install and derives this from it, which is what makes a
    /// device ban a ban on one phone rather than on every copy of the sample. It
    /// stays a constant because it is a constant in three places — here, in
    /// `moqom-mint`'s default, and in the relay's own fixtures — and a token whose
    /// thumbprint disagrees with the device its holder announces under is a
    /// session the relay is right to refuse. Changing it means changing all three
    /// together, which is a different piece of work from this one.
    static let deviceThumbprint = "sample-device-key"

    /// Why the last attempt to fetch a token failed, if it failed.
    ///
    /// Beside the join screen rather than on the failure screen: nothing has
    /// been dialled, the pasted token is still there to fall back on, and "the
    /// token service refused this name" is a different sentence from "the relay
    /// is unreachable".
    private(set) var tokenProblem: String?

    /// Which tenant to dial as: whichever one the token in hand was minted for.
    ///
    /// Read from the credential rather than configured, because a relay compares a
    /// broadcast's namespace against the tenant in the token and refuses the pair
    /// when they differ. Two fields that have to agree, one of them a token nobody
    /// reads and the other a default from before this deployment existed, is a
    /// mismatch waiting to happen — and it happened: `demo` on the screen against a
    /// token saying `moqom`, which connects and then publishes nothing.
    ///
    /// ``launch`` still decides it when there is no token, which is the relay on a
    /// desk that verifies nothing and admits the session anyway.
    var tenant: String {
        guard let claimed = Credential(relay.token)?.tenant, !claimed.isEmpty else {
            return launch.tenant
        }
        return claimed
    }

    /// Ask for a credential, if this device is allowed to ask and needs one.
    ///
    /// Returns whether joining should continue. Three outcomes rather than two: a
    /// token was fetched, no token was needed or could be asked for, or the ask
    /// failed and the join is abandoned before anything is dialled. That last case
    /// is the one worth stopping for — carrying on with a stale credential reaches
    /// a relay that admits the session and permits it nothing, which is a room
    /// that appears to work until somebody presses Go live.
    private func fetchATokenIfNeeded() async -> Bool {
        tokenProblem = nil

        let room = destinationRoomName(pairing: pairing)
        let name = username.trimmed
        guard let service = relay.tokenService, service.isUsable else {
            // No service configured, which is a legitimate setup: a relay on a desk
            // asks for nothing, and a pasted token still works. Said out loud only
            // when the token in hand will not do, because that combination is the
            // one that produces a puzzling session rather than a working one.
            if relay.host != nil, relay.needsAToken(joining: room, as: name) {
                Journal.shared.say("TOKEN stale and no service configured")
            }
            return true
        }
        guard relay.needsAToken(joining: room, as: name) else { return true }

        Journal.shared.say("TOKEN asking \(service.host):\(service.port) for \(name) in \(room)")
        do {
            let issued = try await service.client().token(
                username: name,
                room: room,
                device: Self.deviceThumbprint
            )
            relay.token = issued.token
            // What the service actually minted, which can differ from what was
            // asked for: a username is normalised on the way in, and a phone
            // showing what it requested while the room shows what was issued is a
            // phone displaying the wrong person's name.
            if !issued.username.isEmpty { username = issued.username }
            Journal.shared.say(
                "TOKEN got one for \(issued.username) in \(issued.room),"
                    + " good for \(Int(issued.expiresAt.timeIntervalSinceNow))s"
            )
            return true
        } catch {
            let complaint = (error as? LocalizedError)?.errorDescription
                ?? String(describing: error)
            tokenProblem = complaint
            Journal.shared.say("TOKEN FAILED \(complaint)")
            phase = .joining
            return false
        }
    }

    /// A clock disciplined against the same service the other device uses.
    private static func trustedClock() throws -> TrustedClock {
        TrustedClock(
            authority: NTPAuthority(exchange: try UDPExchange.apple())
        )
    }

    func join() async {
        guard canJoin else { return }
        phase = .connecting

        // The code is the room, not a lookup. The relay is always the compiled-in
        // GCP endpoint unless a script passed `--relay-host`.
        let sharedCode = pairing
        if !RelayConfiguration.relayHostOverridden || relay.host == nil {
            relay.useDevelopmentEndpoint()
        }

        // Before anything is dialled, because this is the credential the dialling
        // presents. A token lasts fifteen minutes and is checked once, at the
        // start of the session, so the only moment worth having a fresh one is
        // this one.
        if !(await fetchATokenIfNeeded()) { return }

        remember()

        do {
            let identity = try ParticipantIdentity(
                username: Username(username.trimmed),
                // A real client derives this from the Secure Enclave key the
                // token's `cnf` claim is bound to, at install.
                device: DeviceID(thumbprint: Self.deviceThumbprint)
            )
            let session = MoqomSession(
                transport: relay.transport(bestEffort: launch.bestEffort),
                credentials: DeviceCredentials(
                    identity: identity,
                    // Minted by whatever stands in for this application's server: the
                    // sample has none, so `deploy/tools/join.sh` mints one and passes it
                    // in. Empty against a relay that verifies means a session that
                    // connects and may publish nothing.
                    token: relay.token,
                    proofSigner: { challenge in challenge }
                ),
                tenant: TenantID(tenant),
                // The sample opts in, because the sample is what an integrator
                // reads to find out that this exists. `.hashed` even here: a
                // demo's log is the one most likely to end up in a screenshot.
                logger: MoqomLogger(
                    sink: BroadcastLogSink(sinks: [
                        Journal.diagnostics,
                        // And into the file this app keeps, so a session driven by hand can
                        // be read afterwards. Warnings only: the unified log can afford
                        // every subscribe and every object, and a file on a phone cannot.
                        Journal.Sink(minimum: .warning),
                    ]),
                    minimum: launch.quietLogs ? .warning : .debug
                )
            )
            try await session.connect(to: relay.endpoint)
            let room: RoomSession
            switch destination(pairing: sharedCode) {
            case .channel:
                room = try await session.goLive()
            case let .watch(name):
                room = try await session.watch(try Username(name))
            case let .room(name):
                room = try await session.join(room: RoomID(name))
            }
            let model = RoomModel(
                session: session,
                room: room,
                identity: identity,
                locale: launch.locale,
                statisticsInterval: launch.statisticsMilliseconds
                    .map { .milliseconds($0) } ?? .milliseconds(250)
            )
            model.flatLayers = launch.flatLayers
            model.encodesEagerly = launch.eagerEncoding
            model.capturesPlainly = launch.plainCapture
            // Left alone when neither flag was given, so the model's own default decides rather
            // than the absence of a command line quietly meaning "call volume".
            if let mediaVolume = launch.mediaVolume {
                model.broadcastsToAnAudience = mediaVolume
            }
            model.isPlaybackMuted = launch.silenceRoom
            if let mix = launch.mix {
                AudioGraph.shared.monitorOutput()
                AudioGraph.shared.playbackVolume = mix
            }

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

            // Same pairing code is a call: both phones publish as soon as they meet.
            // Scripted joins still decide this themselves — a silent bench that
            // shares a code to find the relay must not get a camera forced on.
            if sharedCode != nil, !launch.autojoin {
                await model.startBroadcast()
                await model.startAudio()
            }
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
        popping?.cancel()
        popping = nil
        reshaping?.cancel()
        reshaping = nil
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

#if os(iOS)
    /// Holds the panel at its fastest rate, and reports what that turned out to be.
    ///
    /// Two jobs, and the first one is not incidental — removing this to save a display link costs
    /// about two percent of every frame received. Asking for the rate is what gets it: a phone
    /// runs this app's screen at sixty however fast the panel is, unless something asks otherwise,
    /// and sixty frames a second onto sixty refreshes a second has no slack anywhere in it. Every
    /// frame has exactly one refresh it can be shown in, so any slop in when it is handed over
    /// puts two frames in one refresh and the display layer drops one. Measured across four runs
    /// a side: 3.9% of frames dropped at sixty against 2.2% at a hundred and twenty, every run
    /// improved, and the slow climb in drops across a call — 1.7x from first half to second —
    /// flattened to 1.1x. It costs latency, which is not yet paid for and wants its own look.
    ///
    /// The ``Info.plist`` key `CADisableMinimumFrameDurationOnPhone` is the other half and neither
    /// works alone.
    ///
    /// Reporting it matters separately, because ``UIScreen/maximumFramesPerSecond`` is a
    /// capability rather than a state: it reports 120 for the whole life of the process while the
    /// screen may be running at any rate the system likes. Anything sizing a schedule against the
    /// capability holds margin for a boundary that is not the one its frame will be shown at, and
    /// it is wrong in the expensive direction. A display link is the only honest source, being
    /// driven by the same clock the panel is.
    @MainActor
    final class PanelRate {
        /// One per app, because it is a property of the screen rather than of any view, and every
        /// tile sizing its schedule against it wants the same answer.
        static let shared = PanelRate()

        private var link: CADisplayLink?
        private var periods: [Double] = []
        private var cursor = 0

        /// A second at 120Hz, long enough to see a settled rate and short enough to follow a
        /// change in one.
        private static let window = 120

        /// The period the panel is currently running at, in seconds, and the longest seen.
        ///
        /// Both, because a rate that changes is the thing worth catching and a median alone hides
        /// it. Reading 8.3 and 8.3 is a panel pinned at its maximum; 8.3 and 16.7 is one that has
        /// been dropping to half of it.
        private(set) var period: Double?
        private(set) var longest: Double?

        func start() {
            guard link == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(tick))

            // The line that does the work. Asked for explicitly because a link that does not ask
            // is given sixty whatever the panel can do — and it would then report sixty as though
            // that were the panel's answer, which is how this was missed the first time round.
            let hertz = Float(UIScreen.main.maximumFramesPerSecond)
            if hertz > 0 {
                link.preferredFrameRateRange = CAFrameRateRange(
                    minimum: min(60, hertz),
                    maximum: hertz,
                    preferred: hertz
                )
            }

            link.add(to: .main, forMode: .common)
            self.link = link
        }

        func stop() {
            link?.invalidate()
            link = nil
        }

        @objc private func tick(_ link: CADisplayLink) {
            // The interval this callback is *for*, rather than the one that has just elapsed,
            // because the second is a reading of how late this callback ran and the first is the
            // panel's period, which is the question.
            let elapsed = link.targetTimestamp - link.timestamp
            guard elapsed > 0 else { return }

            if periods.count < Self.window {
                periods.append(elapsed)
            } else {
                periods[cursor] = elapsed
                cursor = (cursor + 1) % Self.window
            }

            let sorted = periods.sorted()
            period = sorted[sorted.count / 2]
            longest = sorted[sorted.count - 1]
        }
    }
#endif
