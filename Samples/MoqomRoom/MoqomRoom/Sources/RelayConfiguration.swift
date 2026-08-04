// Where this build of the sample looks for a relay.
//
// The sample has always run on the in-memory loopback, which is the right default: it
// works with nothing else installed and nothing else running. But a loopback carries
// frames between two objects in one process, so everything a network does to a broadcast —
// latency, jitter, loss, congestion response — is absent, and none of the numbers the app
// reports mean anything about a real link.
//
// So a relay is configuration rather than a code change. Given a host, the sample dials it
// over the system QUIC stack; given nothing, it falls back to loopback and behaves exactly
// as it did before. Two phones pointed at the same host are then a real broadcast over a
// real network, which is the only way to measure one.
//
// Read from launch arguments as well as defaults so a run can be driven from a script. A
// benchmark across two devices means starting the same app twice with matching settings,
// and doing that by thumb is how the two ends end up disagreeing about the room.

import Foundation
import MoqomCore
import MoqomKit
import MoqomLoopback

struct RelayConfiguration {
    /// The relay's hostname or address. `nil` means run on the loopback.
    var host: String?
    var port: UInt16

    /// SHA-256 hashes of certificates to trust, base64, as `moqom-relay` prints them.
    ///
    /// A development relay generates its own certificate, which no platform has any way to
    /// validate, so trusting it means pinning it. Empty means use platform validation,
    /// which is what a deployed relay with a real certificate wants.
    var certificateHashes: [String]

    /// The token this device presents when it dials, or empty for none.
    ///
    /// An application mints these on its own server, where it knows who its user is; the
    /// phone never asks the control plane for one, because a phone that could mint its own
    /// token could mint any token. This sample has no server, so `deploy/tools/join.sh`
    /// stands in for one and hands the result to a launch argument.
    ///
    /// Empty is a working configuration and not a broken one. A relay with no verification
    /// keys admits the session and charges it to its address; a relay with keys admits it
    /// and permits it nothing, which looks like a broadcast that connects and then carries
    /// no tracks. That second case is the one worth recognising from a screenshot, so the
    /// summary below says which of the two this is.
    var token: Data

    /// The relay this project is developed against.
    ///
    /// A device that has never been told where to go gets this rather than the loopback,
    /// which is the difference between an app that works when it is installed and one that
    /// joins a room containing only itself and reports excellent numbers for it. Reinstalling
    /// wipes the defaults database, and this sample is reinstalled from a script several times
    /// an hour, so "type the address and the hash again" was the most common step in every
    /// session — and typing a hash by hand is how a run ends up debugging a typo.
    ///
    /// A development address in the source is a development address in the source. It is
    /// pinned to a certificate that only this relay holds, so the worst a stale one can do is
    /// fail to connect.
    /// Los Angeles rather than Oregon, which is the other region and is kept for comparison.
    /// Measured over the same two-phone run: 22ms mean round trip against Oregon's 48ms, and
    /// 37ms of link in the glass-to-glass figure against 63ms. Both regions run the same build,
    /// so the whole of that difference is distance. Oregon is `34.53.113.58`.
    ///
    /// These are load balancers now, not machines: each address is a forwarding rule in front
    /// of a managed instance group, and the certificate is one the whole fleet shares, so the
    /// hash below survives an instance being replaced. Port 443 rather than 4443, because a
    /// phone on a hotel network reaches 443 and often reaches nothing else.
    /// No token here, deliberately: one expires within the hour, so a token compiled into
    /// the app would be wrong for all but the first run after every build.
    static let development = RelayConfiguration(
        host: "35.235.101.37",
        port: 443,
        certificateHashes: ["polQTlHHCA5xpWTb02GZUdgIJoX5b0rUh0sy+VNWUto="],
        token: Data()
    )

    /// Read from launch arguments first, then the defaults database, then ``development``.
    ///
    /// Arguments win so that a scripted run can override whatever was last set by hand in
    /// the interface, rather than silently inheriting it.
    static func current(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        defaults: UserDefaults = .standard
    ) -> RelayConfiguration {
        var host: String?
        var port: UInt16?
        var hashes: [String] = []
        var token: Data?

        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            let value: String? = index + 1 < arguments.count ? arguments[index + 1] : nil
            switch flag {
            case "--relay-host": host = value
            case "--relay-port": port = value.flatMap(UInt16.init)
            case "--relay-cert-hash": value.map { hashes.append($0) }
            // An argument and not a saved setting: a token lasts an hour, and one
            // remembered across launches would be a puzzle rather than a convenience —
            // the app would work in the morning and stop by lunchtime with no change to
            // anything a person could see.
            case "--relay-token": token = value.flatMap { $0.data(using: .utf8) }
            default: break
            }
            index += 1
        }

        // Whether anything was ever saved, rather than whether what was saved is empty. The
        // two are different answers: a blank host that somebody typed means the loopback and
        // has to keep meaning it, and a blank host nobody has ever typed means this is a
        // fresh install with nothing to inherit.
        let remembered: RelayConfiguration = defaults.object(forKey: "relayHost") == nil
            ? .development
            : RelayConfiguration(
                host: defaults.string(forKey: "relayHost").flatMap { $0.isEmpty ? nil : $0 },
                port: UInt16(defaults.integer(forKey: "relayPort")).nonZero ?? 443,
                certificateHashes: defaults.stringArray(forKey: "relayCertificateHashes") ?? [],
                token: Data()
            )

        return RelayConfiguration(
            host: host ?? remembered.host,
            port: port ?? remembered.port,
            certificateHashes: hashes.isEmpty ? remembered.certificateHashes : hashes,
            token: token ?? Data()
        )
    }

    /// Remember these settings for the next launch.
    ///
    /// Typed once per device rather than once per run. A phone that has to be told where the
    /// relay is every time it is picked up is a phone that gets tested from a script, and a
    /// script cannot answer the local network prompt or hold the camera up to anything.
    func save(to defaults: UserDefaults = .standard) {
        defaults.set(host ?? "", forKey: "relayHost")
        defaults.set(Int(port), forKey: "relayPort")
        defaults.set(certificateHashes, forKey: "relayCertificateHashes")
    }

    /// A transport that dials this relay, or the loopback where there is none.
    func transport() -> any Transport {
        #if canImport(Network)
            guard host != nil else { return LoopbackTransport() }
            return MoqtTransport.network(
                trust: certificateHashes.isEmpty
                    ? .system
                    : .pinned(base64CertificateHashes: certificateHashes)
            )
        #else
            return LoopbackTransport()
        #endif
    }

    /// The endpoint to connect to.
    ///
    /// The loopback ignores the host but still needs one, and a name that reads as
    /// unreachable is better than a plausible one nobody dialled.
    var endpoint: RelayEndpoint {
        RelayEndpoint(host: host ?? "relay.moqom.invalid", port: port)
    }

    /// What to show in the interface, so a run is identifiable from a screenshot.
    var summary: String {
        guard let host else { return "loopback (no relay configured)" }
        let trust = certificateHashes.isEmpty ? "system trust" : "pinned"
        // Worth a word even though it is one more thing on the screen: a session with no
        // token connects to a relay that verifies and then carries nothing, and the two
        // failures — cannot reach the relay, and reached it with no credential — look
        // identical from the outside.
        let credential = token.isEmpty ? "no token" : "token"
        return "\(host):\(port), \(trust), \(credential)"
    }
}

/// Everything else a scripted run has to settle before the app is on screen.
///
/// A two-device benchmark is the same app started twice, and the two ends have to agree
/// about the room while disagreeing about the name. Doing that by thumb is how a run ends up
/// measuring two people in different rooms, which looks exactly like a relay that drops
/// everything.
struct LaunchOptions {
    var username: String?
    var room: String?

    /// Which tenant this session belongs to.
    ///
    /// It has to match the tenant the token was minted for, because that is half of what a
    /// relay compares a namespace against: a token for one tenant and a broadcast under
    /// another is a session that connects, announces, and is refused every track. The
    /// default suits the loopback, where nothing checks.
    var tenant = "demo"

    /// A pairing code to resolve instead of being told the relay's address and hash.
    ///
    /// Here as well as in the interface so that a scripted run exercises the same lookup a
    /// person does, rather than the two paths drifting until only the scripted one works.
    var pairingCode: String?

    /// Join without waiting to be asked, and go live once in.
    var autojoin = false

    /// Publish the camera on one pinned rung, for measuring rather than for calling.
    var benchmark = false

    /// Go live on launch the way the button does, choosing the rung from the layout.
    ///
    /// Separate from ``benchmark`` because the two paths had quietly stopped being the same
    /// program. Every scripted run pinned a rung and every run by hand sized one from the
    /// screen, so a fault that lived in the second was invisible to all the automation aimed
    /// at finding it — thirty frames a second in every measured run and two a second in the
    /// hands of the person reporting the bug.
    var live = false

    /// Whether this launch should start publishing by itself.
    var goesLive: Bool { benchmark || live }

    /// Encode one flat layer instead of splitting the rung into two temporal ones.
    ///
    /// A switch rather than a decision, because it is the thing being tested. Temporal
    /// layering gives the relay something to shed under pressure, and it also asks the
    /// hardware encoder to emit frames that reference each other in a pattern — which is a
    /// plausible source of frames arriving in bunches on an otherwise even link. The only way
    /// to know is to measure the same scene both ways, minutes apart, and a scene with a
    /// ceiling fan in it is not one you can compare across rebuilds.
    var flatLayers = false

    /// Ask the hardware encoder for speed instead of power efficiency.
    ///
    /// The other half of the same experiment as ``flatLayers``, and a trade rather than a
    /// fix: power efficiency is what keeps a long call from throttling its own camera, and it
    /// is also several milliseconds a frame in a budget being asked to fit inside two frames
    /// at sixty. Measured both ways or it is an opinion.
    var eagerEncoding = false

    /// Frames per second to capture, encode, and advertise.
    ///
    /// One number for all three on purpose. The rung's rate is what the encoder is told to
    /// expect and what the catalog advertises; the capture format's rate is what the camera is
    /// asked for. Setting them separately is how a run ends up encoding thirty frames while
    /// claiming sixty.
    var frameRate: Double?

    /// What to give the encoder, overriding what the frame rate would imply.
    ///
    /// A separate knob because bitrate and frame rate are separate questions, and
    /// tying them together means a judder investigation cannot tell a link that is
    /// too full from a cadence that is too fast.
    var kilobitsPerSecond: Int?

    /// Milliseconds between statistics samples, or nil for the app's default of 250.
    ///
    /// A knob because the default is a suspect. Sampling walks the roster and hops between the
    /// actors that also carry media, four times a second, which is the same period as a stutter
    /// that was reported as happening "maybe every quarter second".
    var statisticsMilliseconds: Int?

    /// Milliseconds a remote tile holds frames before presenting them. Zero means on arrival.
    ///
    /// The knob that turns a smoothness complaint into a number. Both settings are worth
    /// measuring: on arrival is the lowest latency the stack can produce, and the difference
    /// between them is what the smooth picture cost.
    var playoutMilliseconds: Int?

    /// The share of frames the adaptive delay may leave unshown. See
    /// ``VideoRenderer/playoutTolerance``. Ignored when a fixed delay is given.
    var playoutTolerance: Double?

    /// The smallest delay the adaptive buffer may settle at. See ``VideoRenderer/playoutBounds``.
    var playoutFloorMilliseconds: Int?

    /// Publish audio as well as video: `tone` or `mic`, and nothing at all when absent.
    ///
    /// A tone by default even though a microphone is more realistic, because two phones on one
    /// desk publishing microphones is a feedback loop, and what it measures is the room.
    var audio: String?

    /// What to publish as video: `camera` or `pattern`. The camera by default.
    ///
    /// The pattern is the bisect. Everything from the encoder onwards treats the two identically,
    /// so a pattern that arrives when a camera does not says the fault is in front of the
    /// encoder, and a pattern that does not arrive either says it is behind it. Without it, a
    /// dark room and a broken display path look exactly the same from both ends.
    var video: String?

    /// Join the shared bubble field once the broadcast is up.
    ///
    /// Here rather than only in the interface because the interesting half of a
    /// shared space is what two devices agree about, and agreement is a thing
    /// to read out of two logs rather than to judge by looking at two screens.
    /// Popping still takes a finger; everything before it does not.
    var bubbles = false

    /// Seconds between scripted pops, where a run has nobody to tap.
    var popEverySeconds: Double?

    /// Seconds between scripted turns of the published picture, portrait to landscape and back.
    ///
    /// Because the thing being tested is what happens to the *other* phone, and the other
    /// phone's account of it is a log rather than a screen. Doing this by thumb means the
    /// moment of the change is known only approximately and only to the person who tapped,
    /// which is no use for reading a viewer's frame arrivals either side of the seam. On a
    /// timer, both logs bracket it.
    var reshapeEverySeconds: Double?

    static func current(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> LaunchOptions {
        var options = LaunchOptions()
        var index = 0
        while index < arguments.count {
            let value: String? = index + 1 < arguments.count ? arguments[index + 1] : nil
            switch arguments[index] {
            case "--username": options.username = value
            case "--room": options.room = value
            case "--tenant": value.map { options.tenant = $0 }
            case "--pairing-code": options.pairingCode = value
            case "--autojoin": options.autojoin = true
            case "--benchmark": options.benchmark = true
            case "--live": options.live = true
            case "--flat-layers": options.flatLayers = true
            case "--eager-encoding": options.eagerEncoding = true
            case "--fps": options.frameRate = value.flatMap(Double.init)
            case "--kbps": options.kilobitsPerSecond = value.flatMap(Int.init)
            case "--stats-ms": options.statisticsMilliseconds = value.flatMap(Int.init)
            case "--playout-ms": options.playoutMilliseconds = value.flatMap(Int.init)
            case "--tolerance": options.playoutTolerance = value.flatMap(Double.init)
            case "--floor-ms": options.playoutFloorMilliseconds = value.flatMap(Int.init)
            case "--audio": options.audio = value ?? "tone"
            case "--video": options.video = value ?? "camera"
            case "--bubbles": options.bubbles = true
            case "--pop-every": options.popEverySeconds = value.flatMap(Double.init)
            case "--reshape-every": options.reshapeEverySeconds = value.flatMap(Double.init)
            default: break
            }
            index += 1
        }
        return options
    }
}

private extension UInt16 {
    var nonZero: UInt16? { self == 0 ? nil : self }
}
