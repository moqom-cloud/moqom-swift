// Pointing a phone at a development relay by typing four digits.
//
// Setting a two-device run up by hand means telling each phone an address and a certificate
// hash. The address is a nuisance and the hash is worse: 44 characters of base64, typed twice,
// where one wrong character produces a failed handshake that looks exactly like a relay that
// is not running.
//
// The obvious fix is to make the short code *be* the trust decision, and it is the wrong one.
// Four digits is thirteen bits, so a policy that accepted any certificate matching a short
// code would accept a certificate an attacker on the same network could produce in about a
// second. Worse, it would live in the SDK, where a development convenience becomes the thing
// somebody ships.
//
// So the code is a lookup and not a credential. The Mac advertises the relay over Bonjour
// under `moqom-<code>`, with the real certificate hash in its TXT record, and the phone
// resolves the code into the same pinned configuration it would have been given by hand. The
// pin is still the exact certificate; the only thing that got shorter is the typing.
//
// Which means the honest scope of this: it works because everything is on one trusted LAN,
// where anyone who could tamper with the advertisement could also just be the relay. That is
// a fine assumption for a testbed on a desk and not one for anything else, which is why this
// lives in the sample rather than in MoqomKit.

import Foundation
import Network

enum RelayPairing {
    /// The Bonjour type the Mac-side script registers under.
    ///
    /// Must also appear in `NSBonjourServices`, or browsing silently returns nothing.
    static let serviceType = "_moqom-relay._udp"

    /// Service names are `moqom-4242`, so the code can be matched without resolving.
    static func serviceName(for code: String) -> String { "moqom-\(code)" }

    /// Find the relay advertising itself under `code`, or `nil` if none does.
    ///
    /// Bounded rather than open-ended, because "no relay is advertising that code" is a
    /// normal outcome — the script is not running, the phone is on the guest network, the
    /// code was mistyped — and a browse that waits forever presents all of those as a hang.
    static func find(
        code: String,
        within timeout: Duration = .seconds(6)
    ) async -> RelayConfiguration? {
        let code = code.trimmed
        guard !code.isEmpty else { return nil }

        return await withCheckedContinuation { continuation in
            // TXT records are the point of the lookup, and the descriptor that omits them
            // reports the service with no metadata at all rather than fetching it later.
            let browser = NWBrowser(
                for: .bonjourWithTXTRecord(type: serviceType, domain: nil),
                using: NWParameters()
            )
            let once = Pairing(continuation: continuation, browser: browser)

            browser.browseResultsChangedHandler = { results, _ in
                for result in results {
                    guard case let .service(name, _, _, _) = result.endpoint,
                          name == serviceName(for: code),
                          case let .bonjour(record) = result.metadata,
                          let configuration = RelayConfiguration(advertised: record)
                    else { continue }
                    once.finish(with: configuration)
                }
            }

            browser.stateUpdateHandler = { state in
                // A browser that cannot start is not a relay that is absent, but there is
                // nothing more to wait for either. Failing now beats holding the interface
                // until the deadline for a result that cannot arrive.
                if case .failed = state { once.finish(with: nil) }
            }

            browser.start(queue: .main)

            Task {
                try? await Task.sleep(for: timeout)
                once.finish(with: nil)
            }
        }
    }
}

/// Resumes the continuation exactly once, and stops browsing when it does.
///
/// Three things race to answer — a matching advertisement, a failed browser, and the
/// deadline — and a continuation resumed twice is a crash rather than a wrong answer.
private final class Pairing: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<RelayConfiguration?, Never>?
    private let browser: NWBrowser

    init(continuation: CheckedContinuation<RelayConfiguration?, Never>, browser: NWBrowser) {
        self.continuation = continuation
        self.browser = browser
    }

    func finish(with configuration: RelayConfiguration?) {
        let claimed = lock.withLock { () -> CheckedContinuation<RelayConfiguration?, Never>? in
            defer { continuation = nil }
            return continuation
        }
        guard let claimed else { return }
        browser.cancel()
        claimed.resume(returning: configuration)
    }
}

extension RelayConfiguration {
    /// Read from what the Mac-side script put in the TXT record.
    ///
    /// The address is carried in the record rather than resolved from the service, because
    /// the QUIC carrier dials a host and a port and there is nothing to hand an unresolved
    /// endpoint to. A hash is required: an advertisement without one would connect to a
    /// self-signed relay under platform validation and fail the handshake, which is a
    /// confusing way to report a misconfigured script.
    init?(advertised record: NWTXTRecord) {
        guard let host = record["addr"], !host.isEmpty,
              let hash = record["hash"], !hash.isEmpty
        else { return nil }

        self.init(
            host: host,
            port: record["port"].flatMap(UInt16.init) ?? 443,
            certificateHashes: [hash]
        )
    }
}
