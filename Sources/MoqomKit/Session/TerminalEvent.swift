// Why a stream ended.
//
// This exists as a structured object on the room's lifecycle track rather than
// as a reason phrase on SUBSCRIBE_DONE, and the ordering matters as much as the
// shape: the reason is published as media, fanning out to every viewer through
// the same relay tree at media latency, and only then does the transport wind
// down. Tear the subscription down first and every viewer sees an
// indistinguishable connection drop with no way to tell moderation from a dead
// network.
//
// The four terminal states below want four different user-facing behaviours.
// Collapsing them into one disconnect event is the sort of UX bug that gets
// baked in early and is painful to unpick later, so the type refuses to let a
// caller be vague.

import Foundation

/// The four ways a session ends, and what caused it.
public enum TerminalReason: Hashable, Sendable {
    /// A moderation decision. Carries the policy code so an app can route to an
    /// appeals screen, trigger age verification, or fire analytics.
    case moderated(code: ModerationCode)

    /// The host ended the broadcast deliberately. The expected case, and the
    /// one that should never look like a failure.
    case hostEnded

    /// The transport could not be recovered within the away window.
    case networkFailure

    /// Authorisation lapsed and revalidation failed. Distinct from
    /// ``networkFailure`` because the remedy is a token refresh, not a retry.
    case tokenExpired
}

extension TerminalReason {
    /// A stable short name, used on the wire and in logs.
    ///
    /// One list rather than one per direction: the moderation code stays out of
    /// it so that this is safe to log, since a policy code beside a username is
    /// a record of an enforcement decision and belongs wherever the tenant keeps
    /// those, not in a client's diagnostics.
    public var identifier: String {
        switch self {
        case .moderated: "moderated"
        case .hostEnded: "hostEnded"
        case .networkFailure: "networkFailure"
        case .tokenExpired: "tokenExpired"
        }
    }
}

extension TerminalReason: Codable {
    private enum Key: String, CodingKey {
        case reason
        case code
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        switch try container.decode(String.self, forKey: .reason) {
        case "moderated":
            self = .moderated(code: try container.decode(ModerationCode.self, forKey: .code))
        case "hostEnded":
            self = .hostEnded
        case "networkFailure":
            self = .networkFailure
        case "tokenExpired":
            self = .tokenExpired
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .reason,
                in: container,
                debugDescription: "unknown terminal reason \(other)"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(identifier, forKey: .reason)
        if case let .moderated(code) = self {
            try container.encode(code, forKey: .code)
        }
    }
}

/// Why moderation acted, as a code the SDK and the app can both switch on.
public enum ModerationCode: String, Hashable, Sendable, Codable {
    case adultContent
    case violence
    case harassment
    case selfHarm
    case copyright
    case ageVerificationRequired
    case tenantPolicy
    case operatorAction
}

/// The terminal object, as it arrives on the lifecycle track.
public struct TerminalEvent: Hashable, Sendable, Codable {
    /// What happened.
    public let reason: TerminalReason

    /// Copy that renders sensibly with zero integration work.
    public let defaultDisplayString: String

    /// A key the app can use to render its own copy in its own languages. The
    /// default string is English and unlocalisable; this is the escape hatch
    /// that stops that from being a product limit.
    public let localizationKey: String?

    /// Passed through untouched. The SDK does not parse it and never will —
    /// that opacity is what lets a tenant evolve their own payload without
    /// waiting for an SDK release.
    public let tenantPayload: Data?

    public init(
        reason: TerminalReason,
        defaultDisplayString: String,
        localizationKey: String? = nil,
        tenantPayload: Data? = nil
    ) {
        self.reason = reason
        self.defaultDisplayString = defaultDisplayString
        self.localizationKey = localizationKey
        self.tenantPayload = tenantPayload
    }

    /// Whether the app should offer a retry.
    ///
    /// A moderated stream must not auto-retry — the publisher's token is
    /// revoked so revalidation fails on reconnect anyway, and a client that
    /// hammers the relay after enforcement looks exactly like an evasion
    /// attempt.
    public var isRetryable: Bool {
        switch reason {
        case .networkFailure: true
        case .moderated, .hostEnded, .tokenExpired: false
        }
    }

    public static let networkFailure = TerminalEvent(
        reason: .networkFailure,
        defaultDisplayString: "Connection lost.",
        localizationKey: "moqom.terminal.network_failure"
    )

    public static let hostEnded = TerminalEvent(
        reason: .hostEnded,
        defaultDisplayString: "The broadcast has ended.",
        localizationKey: "moqom.terminal.host_ended"
    )

    public static let tokenExpired = TerminalEvent(
        reason: .tokenExpired,
        defaultDisplayString: "Your session expired. Sign in again to continue.",
        localizationKey: "moqom.terminal.token_expired"
    )

    public static func moderated(
        _ code: ModerationCode,
        display: String = "This broadcast was ended for violating the community guidelines.",
        tenantPayload: Data? = nil
    ) -> TerminalEvent {
        TerminalEvent(
            reason: .moderated(code: code),
            defaultDisplayString: display,
            localizationKey: "moqom.terminal.moderated.\(code.rawValue)",
            tenantPayload: tenantPayload
        )
    }
}
