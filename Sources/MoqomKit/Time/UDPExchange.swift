// The part that opens a port.
//
// > Important: like `NetworkQUICCarrier`, this typechecks on every build and no
// > test has ever executed it. Nothing in the suite touches the network. The
// > rules that decide whether a reply is believed live in ``NTPPacket`` and
// > ``NTPAuthority``, which are tested without a socket; what is here is the
// > send, the receive, and the timeout around them.

#if canImport(Network)
    import Foundation
    import MoqomCore
    import Network

    /// A reusable UDP socket to one host.
    ///
    /// Kept open between exchanges rather than dialled per request, and that is
    /// a correctness property rather than an efficiency one. ``TrustedClock``
    /// measures the round trip by bracketing the call, so anything else inside
    /// it — a DNS lookup, path setup — is counted as network delay and inflates
    /// the uncertainty of the sample. Warm, the call is one packet each way.
    ///
    /// The first exchange after opening still pays that cost. It is left to the
    /// opening burst to deal with, which it does for free: four samples are
    /// taken and the one with the shortest round trip wins, so the slow first
    /// exchange loses to the three behind it.
    public actor UDPExchange: DatagramExchange {
        private let endpoint: NWEndpoint
        private var connection: NetworkConnection<UDP>?

        public init(host: String, port: UInt16) throws(MoqomError) {
            guard let port = NWEndpoint.Port(rawValue: port) else {
                throw MoqomError.transport(.unreachable)
            }
            endpoint = .hostPort(host: NWEndpoint.Host(host), port: port)
        }

        /// A socket to Cloudflare's anycast time service.
        public static func cloudflare() throws(MoqomError) -> UDPExchange {
            try UDPExchange(host: NTPAuthority.cloudflare, port: NTPAuthority.port)
        }

        public func exchange(_ request: Data, timeout: Duration) async throws(MoqomError) -> Data {
            let connection = warm()
            do {
                return try await withThrowingTaskGroup(of: Data.self) { group in
                    group.addTask {
                        try await connection.send(request)
                        return try await connection.receive().content
                    }
                    group.addTask {
                        try await Task.sleep(for: timeout)
                        throw MoqomError.transport(.idleTimeout)
                    }
                    // Whichever finishes first decides; cancelling the group
                    // tears down the loser, which for the timeout branch is the
                    // outstanding receive.
                    guard let first = try await group.next() else {
                        throw MoqomError.transport(.unreachable)
                    }
                    group.cancelAll()
                    return first
                }
            } catch let error as MoqomError {
                throw error
            } catch {
                // A failed exchange invalidates the socket. Dropping it means
                // the next attempt redials rather than sending into a path that
                // has gone away — which is the common case on a phone, where
                // the interface changes under us.
                self.connection = nil
                throw MoqomError.transport(.unreachable)
            }
        }

        private func warm() -> NetworkConnection<UDP> {
            if let connection { return connection }
            // No `start()` on a one-to-one connection: it establishes on first
            // use, which is the send below.
            let connection = NetworkConnection(to: endpoint) { UDP() }
            self.connection = connection
            return connection
        }
    }

    public extension TrustedClock {
        /// A clock disciplined by Cloudflare's public time service.
        ///
        /// The default for a client, and the reason there is no time endpoint
        /// on our own control plane: a global anycast reference that both the
        /// devices and the servers use puts everyone on one timeline without
        /// us running a service or being trusted to run it honestly.
        static func cloudflare(logger: MoqomLogger = .silent) throws(MoqomError) -> TrustedClock {
            TrustedClock(
                authority: NTPAuthority(exchange: try UDPExchange.cloudflare(), logger: logger),
                logger: logger
            )
        }
    }
#endif
