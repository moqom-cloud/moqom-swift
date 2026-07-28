// Why an announcement went away.
//
// This mirrors `DoneReason` in `moqom-engine/moqom-proto`, which is named for the
// message that carries it (`NAMESPACE_DONE`). It is named for the event here
// instead, because that is what a caller on this side is holding: an
// ``AnnouncementEvent/withdrawn(_:_:)``. Same codes, same meanings.
//
// Draft-19 has nowhere to put this, which is the whole reason it needs
// explaining. There is no `UNANNOUNCE` — a publisher withdraws by closing the
// stream that announced it — so both of the ways an announcement can end arrive
// as the same bare message, and a receiver cannot tell them apart. The relay
// can, and this is how it says so. See ``MoqomWire/NamespaceDone/reason`` for
// how it travels without breaking a peer that has never heard of it.

/// Why an announcement stopped.
///
/// The distinction decides behaviour rather than decorating it. A publisher who
/// stopped on purpose has left, and their place in the room can go; one whose
/// session died may be back within seconds, and releasing their place reflows
/// everybody's layout over a lift or a tunnel. Read it through ``mayReturn``,
/// which is the question callers actually have.
public enum WithdrawalReason: Hashable, Sendable {
    /// The publisher withdrew it, by closing the stream that announced it.
    case stopped

    /// The session ended without withdrawing it.
    ///
    /// Covers an idle timeout, a transport failure, and a protocol violation the
    /// relay hung up over — anything, in short, where nobody said they were
    /// going. The publisher may be reconnecting.
    case vanished

    /// A code this build does not know.
    ///
    /// Kept rather than rejected, so a newer relay can add reasons without every
    /// older client treating the extras as a decode failure. ``mayReturn``
    /// resolves it the patient way.
    case other(UInt64)

    private static let stoppedCode: UInt64 = 0
    private static let vanishedCode: UInt64 = 1

    /// Read a wire code, keeping one this build does not recognise.
    public init(code: UInt64) {
        switch code {
        case Self.stoppedCode: self = .stopped
        case Self.vanishedCode: self = .vanished
        default: self = .other(code)
        }
    }

    /// The wire code.
    public var code: UInt64 {
        switch self {
        case .stopped: Self.stoppedCode
        case .vanished: Self.vanishedCode
        case let .other(code): code
        }
    }

    /// Whether the publisher may yet come back.
    ///
    /// Everything other than a deliberate stop answers `true`, including
    /// ``other(_:)``. Erring towards patience is deliberate: waiting for
    /// somebody who has actually left costs one stale roster entry that a
    /// timeout will clear, while dropping somebody who is mid-reconnect is
    /// immediately visible to every viewer in the room.
    public var mayReturn: Bool {
        if case .stopped = self { false } else { true }
    }
}

extension WithdrawalReason? {
    /// Whether the publisher may yet come back, when they may not have said.
    ///
    /// `nil` means "did not say" rather than "no reason" — a draft-19 relay, or
    /// one of ours that lost the reason on the way — and it resolves the same
    /// patient way as an unrecognised code. Defined on the optional so callers
    /// need not spell that decision out at each use, and so that forgetting to
    /// spell it out cannot quietly mean the impatient thing.
    public var mayReturn: Bool { self?.mayReturn ?? true }
}
