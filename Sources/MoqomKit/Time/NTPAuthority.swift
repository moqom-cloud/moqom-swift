// Where global time comes from.
//
// `time.apple.com`, anycast, which gives the property that matters most here:
// every client and every server reaches a *nearby* instance of the same logical
// clock, so a phone in Lagos and a relay in Frankfurt land on one timeline
// without either of them being the authority for the other. We are not in the
// business of telling anyone what time it is, which is one fewer service to run
// and one fewer thing to be wrong.
//
// # Why not the obvious anycast choice
//
// This was `time.cloudflare.com` on exactly that reasoning, and the reasoning
// was right about anycast and wrong about what it would cost, because it only
// counted the network. A server states how far it is from a real reference as
// its root distance — half its root delay plus its dispersion — and
// ``TrustedClock`` adds that to half the round trip, because a reading cannot
// be better than the clock it came from. Cloudflare's instances answer at
// stratum 3 with a root delay near 35ms, so they declare about 18ms before a
// single packet of ours crosses the network. Measured from one network, five
// samples each: Cloudflare 18.2ms, `time.apple.com` 0.2ms, `time.google.com`
// 0.1ms. Those are stratum 1 and it is not close.
//
// Eighteen milliseconds was, at the time of the switch, the largest term in
// this device's uncertainty — larger than the round trip, and around four times
// the drift between polls. It bought nothing: Cloudflare's *actual* offset from
// UTC measured well under a millisecond, and the 18ms is a bound it is being
// honest about rather than error it is committing. But an honest bound is still
// the number every consumer has to plan against, and a cross-device latency
// figure carries two of them.
//
// Apple over Google by a tenth of a millisecond that does not matter, for two
// reasons that do. It is the platform's own service, so on the devices this SDK
// runs on the traffic is unremarkable and reachability is as good as the OS's
// own. And Google smears leap seconds, which is a fine policy and the wrong one
// to adopt silently: it would put every client on a timeline that leaves UTC by
// up to half a second and disagrees with any peer that did not make the same
// choice. See ``AuthorityReading/leapSecondPending``.
//
// # Being a good guest
//
// It is free and public, and an SDK is a bad way to find out how a free public
// service feels about a million devices. Three things follow from that and none
// are optional. The poll interval stays at NTP's conventional floor rather than
// whatever we could get away with. A kiss-of-death reply silences this client
// for a good long while instead of being retried. And ``TrustedClock`` spreads
// its polls with jitter, because the failure mode of a large fleet is not the
// average rate, it is every device syncing on the same second.
//
// # The socket
//
// Split behind ``DatagramExchange`` so that the parts with rules — nonces,
// retries, back-off, what counts as usable — are testable, and the part that
// opens a port is a thin shim. That shim carries the same warning as
// `NetworkQUICCarrier`: it typechecks on every build and no test has ever run
// it, because nothing in this suite touches the network.
//
// UDP on port 123 is also the one thing here that fails for reasons we cannot
// fix. Hotel portals, enterprise egress filters and a few mobile carriers block
// or redirect it. A client that cannot reach the server does not fall back to
// the device's wall clock and does not guess — it reports unsynchronised and
// lets the caller decide what a recording without trusted time is worth.

import Foundation
import MoqomCore

/// One datagram out, one datagram back.
public protocol DatagramExchange: Sendable {
    func exchange(_ request: Data, timeout: Duration) async throws(MoqomError) -> Data
}

/// A ``TimeAuthority`` backed by an NTP server.
public actor NTPAuthority: TimeAuthority {
    /// Apple's anycast time service, answering at stratum 1.
    public static let apple = "time.apple.com"

    @available(*, deprecated, renamed: "apple", message: """
    Cloudflare answers at stratum 3 and declares about 18ms of root distance, \
    which lands in every reading taken from it. Prefer `apple`.
    """)
    public static let cloudflare = "time.cloudflare.com"

    public static let port: UInt16 = 123

    /// How long to wait for a reply before assuming the datagram was lost.
    static let timeout = Duration.seconds(2)

    /// Attempts per ``read()``.
    ///
    /// Two, not more. UDP loses packets and a retry is cheap, but a client that
    /// retries hard turns a brief outage into a stampede against a shared
    /// service. Everything above this already tolerates a failed exchange.
    static let attempts = 2

    /// How long to stay quiet after being told to.
    ///
    /// Deliberately far longer than any poll interval. A server that says
    /// `RATE` is describing a client that is already misbehaving, and the only
    /// response that helps is to stop for long enough to matter.
    static let penance = Duration.seconds(3600)

    private let exchange: any DatagramExchange
    private let logger: MoqomLogger
    private let nonces: @Sendable () -> UInt64

    /// Set when the server has asked us to go away.
    private var silencedUntil: ContinuousClock.Instant?

    public init(
        exchange: any DatagramExchange,
        logger: MoqomLogger = .silent,
        nonces: @escaping @Sendable () -> UInt64 = { UInt64.random(in: .min ... .max) }
    ) {
        self.exchange = exchange
        self.logger = logger
        self.nonces = nonces
    }

    public func read() async throws(MoqomError) -> AuthorityReading {
        if let silencedUntil, ContinuousClock.now < silencedUntil {
            throw MoqomError.transport(.unreachable)
        }

        var last: MoqomError = .transport(.unreachable)
        for attempt in 0 ..< Self.attempts {
            // A fresh nonce per attempt, so that a slow reply to the first one
            // cannot be mistaken for a prompt reply to the second and have its
            // round trip measured far too short.
            let nonce = nonces()
            do {
                let reply = try await exchange.exchange(
                    NTPPacket.request(nonce: nonce),
                    timeout: Self.timeout
                )
                return try adopt(NTPPacket.read(reply, nonce: nonce))
            } catch let failure as NTPFailure {
                last = classify(failure)
                if case let .kissOfDeath(code) = failure {
                    silencedUntil = ContinuousClock.now.advanced(by: Self.penance)
                    logger.error(.session, "time server refused us", [
                        LogField("code", .text(code)),
                    ])
                    throw last
                }
                // A forged or stale reply is worth another try; a server that
                // says it is adrift will say so again, so stop asking.
                if case .unsynchronised = failure { throw last }
            } catch let error as MoqomError {
                last = error
            } catch {
                last = .transport(.unreachable)
            }
            if attempt + 1 < Self.attempts {
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        throw last
    }

    private func adopt(_ reading: NTPReading) -> AuthorityReading {
        AuthorityReading(
            receivedAt: reading.receivedAt,
            repliedAt: reading.repliedAt,
            uncertainty: reading.rootDistance,
            isDisciplined: true,
            leapSecondPending: reading.leap.isPending
        )
    }

    private func classify(_ failure: NTPFailure) -> MoqomError {
        switch failure {
        case .malformed, .impostor:
            // Not a routing problem. Something on the path is answering for the
            // server, which on port 123 is usually a captive portal rather than
            // an attacker, but is untrustworthy either way.
            .transport(.untrustedPeer)
        case .kissOfDeath, .unsynchronised:
            .transport(.unreachable)
        }
    }
}
