// Watchdogs: the third entity class.
//
// The dividing line is output, not intent. If it produces something
// participants see or hear, it is an agent and belongs in the roster with the
// people. If it only subscribes, it is a watchdog. A captions agent and an
// avatar are agents — clients render their tracks, so they need priority,
// spotlight, and the ability to be muted. A recorder, a safety detector, an
// analytics collector, and a customer's own archiver are watchdogs.
//
// Note what this type does not have: a `ParticipantSlot`. It publishes nothing,
// so it has no namespace announcement, so there is no way to construct one and
// no `Roster` that will take it. That same property is why it needs explicit
// room state — invisible to the roster mechanism, a watchdog would otherwise be
// invisible entirely, which is not acceptable for something recording you.
//
// And the verbs are different, which is the other half. You do not kick a
// recorder, you stop it. `WatchdogAction` and `ModerationAction` share no
// cases, so "kick the recorder" is a compile error rather than a support
// ticket.

import Foundation
import MoqomCore

/// Identifies an attached watchdog.
public struct WatchdogID: Hashable, Sendable, Codable, ExpressibleByStringLiteral {
    public let value: String

    public init(stringLiteral value: String) { self.value = value }
    public init(_ value: String) { self.value = value }
}

/// What a watchdog is for.
public enum WatchdogKind: Hashable, Sendable {
    case recording
    case safety
    case analytics
    case compliance
    case custom(String)

    public var identifier: String {
        switch self {
        case .recording: "recording"
        case .safety: "safety"
        case .analytics: "analytics"
        case .compliance: "compliance"
        case let .custom(name): name
        }
    }

    /// Read back from an identifier.
    ///
    /// A custom kind named `recording` becomes ``recording``, which is
    /// deliberate rather than lossy: ``WatchdogSet/isRecording`` drives the
    /// disclosure indicator off this case, and a tenant who could name their way
    /// around it would have a recorder that users are never told about.
    public init(identifier: String) {
        switch identifier {
        case "recording": self = .recording
        case "safety": self = .safety
        case "analytics": self = .analytics
        case "compliance": self = .compliance
        default: self = .custom(identifier)
        }
    }
}

extension WatchdogKind: Codable {
    /// A bare string, because this appears in a disclosure that a third party
    /// may have to read — a compliance auditor, or an operator diagnosing why a
    /// customer's recorder is not attached. `{"custom":{"_0":"acme"}}` is what
    /// the synthesised conformance would produce.
    public init(from decoder: any Decoder) throws {
        self.init(identifier: try String(from: decoder))
    }

    public func encode(to encoder: any Encoder) throws {
        try identifier.encode(to: encoder)
    }
}

/// Who runs it.
///
/// A named third party is a distinct case from the tenant because the
/// disclosure a user is owed differs: "this room is being recorded" and "this
/// room is being recorded by Acme Compliance Ltd" are not the same statement.
public enum WatchdogOperator: Hashable, Sendable {
    /// MOQOM itself. Platform-mandated safety scanning lives here.
    case platform

    /// The customer whose room this is.
    case tenant

    /// Someone else, disclosed by name.
    case thirdParty(String)
}

extension WatchdogOperator: Codable {
    private enum Key: String, CodingKey {
        case operator_ = "operator"
        case name
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        switch try container.decode(String.self, forKey: .operator_) {
        case "platform":
            self = .platform
        case "tenant":
            self = .tenant
        case "thirdParty":
            self = .thirdParty(try container.decode(String.self, forKey: .name))
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .operator_,
                in: container,
                debugDescription: "unknown operator \(other)"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        switch self {
        case .platform:
            try container.encode("platform", forKey: .operator_)
        case .tenant:
            try container.encode("tenant", forKey: .operator_)
        case let .thirdParty(name):
            try container.encode("thirdParty", forKey: .operator_)
            try container.encode(name, forKey: .name)
        }
    }
}

/// Operational state, which is not the same shape as a participant's presence.
///
/// A participant is connected, reconnecting, or away — a social state. A
/// watchdog is attached, degraded, or failed — an operational one. A customer
/// whose recorder died wants that surfaced in room state, not inferred from a
/// missing file afterwards.
public enum WatchdogHealth: String, Hashable, Sendable, Codable {
    case attached
    case degraded
    case failed
}

/// A subscriber that observes the room without appearing in it.
public struct Watchdog: Hashable, Sendable, Identifiable, Codable {
    public let id: WatchdogID

    public let kind: WatchdogKind

    public let operatedBy: WatchdogOperator

    /// Shown to users. Required, and deliberately not derived from ``kind`` —
    /// "Recording for your compliance team" and "Recording" are different
    /// disclosures and only the tenant knows which is true.
    public let descriptor: String

    /// Which tracks it observes.
    public let scope: TrackNamespace

    public let attachedAt: Date

    public var health: WatchdogHealth

    /// Whether this attachment accrues watchdog-minutes.
    ///
    /// An attribute rather than something inferred from ``kind``, so a tenant
    /// who opts into safety scanning above our baseline can be charged for the
    /// increment without reclassifying anything. Platform-mandated scanning is
    /// our cost of operating and is not billed.
    public let isBillable: Bool

    /// The layer it holds regardless of viewer demand.
    ///
    /// Two subscribers must pin, and both are easy to miss. A recorder holds
    /// the top layer, or a stream nobody happens to be watching at full
    /// resolution gets archived at thumbnail quality. A safety detector holds a
    /// minimum, because a classifier running on 180p is both less accurate and
    /// an obvious evasion vector once someone works out that an empty room
    /// downgrades the stream the detector sees.
    public let pinnedLayer: LayerID?

    public init(
        id: WatchdogID,
        kind: WatchdogKind,
        operatedBy: WatchdogOperator,
        descriptor: String,
        scope: TrackNamespace,
        attachedAt: Date,
        health: WatchdogHealth = .attached,
        isBillable: Bool = true,
        pinnedLayer: LayerID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.operatedBy = operatedBy
        self.descriptor = descriptor
        self.scope = scope
        self.attachedAt = attachedAt
        self.health = health
        self.isBillable = isBillable
        self.pinnedLayer = pinnedLayer
    }
}

/// What can be done to a watchdog.
///
/// Shares no cases with ``ModerationAction`` on purpose. There is no `kick`
/// here and no `stop` there, so the two vocabularies cannot be confused at a
/// call site.
public enum WatchdogAction: Hashable, Sendable {
    case attach(WatchdogRequest)
    case detach(WatchdogID)
    case start(WatchdogID)
    case stop(WatchdogID)
}

/// A request to attach one.
public struct WatchdogRequest: Hashable, Sendable {
    public let kind: WatchdogKind
    public let operatedBy: WatchdogOperator
    public let descriptor: String
    public let scope: TrackNamespace
    public let pinnedLayer: LayerID?

    public init(
        kind: WatchdogKind,
        operatedBy: WatchdogOperator,
        descriptor: String,
        scope: TrackNamespace,
        pinnedLayer: LayerID? = nil
    ) {
        self.kind = kind
        self.operatedBy = operatedBy
        self.descriptor = descriptor
        self.scope = scope
        self.pinnedLayer = pinnedLayer
    }
}

/// Everything attached to a room.
public struct WatchdogSet: Hashable, Sendable {
    private var storage: [WatchdogID: Watchdog]

    /// Cap on simultaneous attachments.
    ///
    /// Watchdogs are cheap to attach and unbounded attachment is both a cost
    /// surprise and a plausible denial of service against a publisher, since
    /// each one pins a layer and keeps an encode session alive.
    public let limit: Int

    public init(limit: Int = 8) {
        storage = [:]
        self.limit = limit
    }

    /// Build from a disclosure the room's authority published.
    ///
    /// The limit stretches to fit rather than truncating, and the reason is that
    /// ``limit`` bounds *attaching* — a cost surprise and a denial of service
    /// against a publisher — while this is the list a user has a right to see. A
    /// recorder dropped on the floor by a client-side cap is a recorder nobody
    /// was told about, which is the one failure here that matters.
    public init(_ watchdogs: some Collection<Watchdog>, limit: Int = 8) {
        storage = Dictionary(
            watchdogs.map { ($0.id, $0) },
            uniquingKeysWith: { _, later in later }
        )
        self.limit = max(limit, storage.count)
    }

    public var all: [Watchdog] { storage.values.sorted { $0.attachedAt < $1.attachedAt } }

    public var isEmpty: Bool { storage.isEmpty }

    public subscript(id: WatchdogID) -> Watchdog? { storage[id] }

    /// Whether the room should show a recording indicator.
    ///
    /// Clients render this as room-level chrome, never as a tile.
    public var isRecording: Bool {
        storage.values.contains { $0.kind == .recording && $0.health != .failed }
    }

    /// Attachments a user must be told about, whoever operates them.
    public var disclosures: [Watchdog] { all }

    /// - Throws: ``MoqomError/rejected(_:)`` when the room is at its cap.
    public mutating func attach(_ watchdog: Watchdog) throws(MoqomError) {
        guard storage.count < limit || storage[watchdog.id] != nil else {
            throw MoqomError.rejected(.limitExceeded("watchdogs per room (\(limit))"))
        }
        storage[watchdog.id] = watchdog
    }

    @discardableResult
    public mutating func detach(_ id: WatchdogID) -> Watchdog? {
        storage.removeValue(forKey: id)
    }

    public mutating func setHealth(_ health: WatchdogHealth, for id: WatchdogID) {
        storage[id]?.health = health
    }

    /// The lowest layer any watchdog requires, which the publisher must keep
    /// producing even when no human is watching it.
    public func pinnedLayers() -> Set<LayerID> {
        Set(storage.values.compactMap(\.pinnedLayer))
    }
}
