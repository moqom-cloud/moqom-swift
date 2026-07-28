// Where global time comes from.
//
// `time.cloudflare.com`, anycast from a few hundred locations, which is the
// property that matters more than the accuracy: every client and every server
// reaches a *nearby* instance of the same logical clock, so a phone in Lagos
// and a relay in Frankfurt land on one timeline without either of them being
// the authority for the other. We are not in the business of telling anyone
// what time it is, which is one fewer service to run and one fewer thing to be
// wrong.
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
    /// Cloudflare's anycast time service.
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
