// Logging, and the one thing it must never do.
//
// A media SDK's logs are read in exactly one situation: something is wrong on a
// device that is not on your desk, and the only evidence is what was written
// down at the time. That makes two properties matter more than convenience.
//
// The first is that a disabled log costs nothing. This is called from the object
// receive path, so a `debug` line that formats its message before discovering
// nobody wants it would add work per object to make a string that is thrown
// away. Every method takes its message and fields as autoclosures and checks the
// level first.
//
// The second is that payloads and keys can never appear. That is enforced by the
// type system rather than by review: `LogValue` has no case that holds `Data`,
// so there is no expression that puts a media payload or a key into a log field.
// Something whose size is worth recording goes in as `.redacted(bytes:)`, which
// can only ever render as a count. A reviewer noticing a leak is a control that
// works until the one time it does not; a case that does not exist is a control
// that cannot be bypassed by anyone in a hurry.

import Foundation
import os

/// How much a log record matters.
public enum LogLevel: Int, Comparable, Sendable, CaseIterable {
    /// Per-object detail. Off in anything resembling production.
    case trace = 0
    /// Decisions and transitions worth reconstructing after the fact.
    case debug = 1
    /// Lifecycle: connected, joined, published, ended.
    case info = 2
    /// Something recovered, but a person should know it happened.
    case warning = 3
    /// Something did not recover.
    case error = 4

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// The four-letter form, so aligned output stays aligned.
    public var label: String {
        switch self {
        case .trace: "TRCE"
        case .debug: "DBUG"
        case .info: "INFO"
        case .warning: "WARN"
        case .error: "ERRO"
        }
    }
}

/// Which part of the SDK a record came from.
///
/// A fixed set rather than free-form strings, because the first thing anybody
/// does with a log is filter it, and a filter only works against names that were
/// agreed in advance.
public enum LogCategory: String, Sendable, CaseIterable {
    /// Connecting, reconnecting, and giving up.
    case session
    /// The QUIC or WebTransport layer under it.
    case transport
    /// Roster, presence, moderation, lifecycle.
    case room
    /// The room control track.
    case control
    /// Capture and encode, outbound.
    case publish
    /// Subscription and layer selection, inbound.
    case subscribe
    /// Capture, playout, and echo cancellation.
    case audio
    /// Raw frames and samples crossing out of the SDK to somebody else's
    /// processing.
    ///
    /// Its own category rather than folded into ``publish`` or ``subscribe``,
    /// because it is the one boundary where media stops being accounted for —
    /// which makes it the first thing anyone auditing what a build does with
    /// media will want to filter on.
    case media
    /// Key handling and object protection.
    case security
    /// Measurement.
    case statistics
}

/// A value attached to a log record.
///
/// Deliberately cannot hold arbitrary bytes. See the note at the top of this
/// file: the absence of a `case data(Data)` is the mechanism that keeps media
/// and keys out of logs, and adding one would remove it.
public enum LogValue: Hashable, Sendable {
    case text(String)
    case number(Int)
    case decimal(Double)
    case flag(Bool)
    case elapsed(Duration)

    /// Something that must not be written down, reduced to its size.
    ///
    /// For payloads, keys, and tokens. The count is genuinely useful — "the
    /// object was 40 bytes" explains a decode failure — and is all that is
    /// available.
    case redacted(bytes: Int)

    /// A participant, rendered according to the sink's privacy policy.
    case participant(ParticipantIdentity)

    /// How this renders, given a privacy policy.
    public func rendered(_ privacy: LogPrivacy) -> String {
        switch self {
        case let .text(value): value
        case let .number(value): String(value)
        case let .decimal(value): String(format: "%.3f", value)
        case let .flag(value): value ? "true" : "false"
        case let .elapsed(value): "\(milliseconds(value))ms"
        case let .redacted(bytes): "<\(bytes) bytes>"
        case let .participant(identity): privacy.render(identity)
        }
    }
}

/// A named value on a log record.
///
/// An array of these rather than a dictionary, because the order they were
/// written in is the order they should be read in, and a dictionary would
/// reorder them differently on every launch.
public struct LogField: Hashable, Sendable {
    public let name: String
    public let value: LogValue

    public init(_ name: String, _ value: LogValue) {
        self.name = name
        self.value = value
    }
}

/// What a sink may reveal about who is in a room.
public enum LogPrivacy: Sendable {
    /// Usernames as they are. For development, and for a log that stays on the
    /// device.
    case full

    /// Usernames replaced by a short stable digest.
    ///
    /// Stable so two lines about the same person can still be correlated, which
    /// is the entire diagnostic value of having the field at all. Not reversible
    /// by anyone reading the log, which is the point — but a *short* digest over
    /// a small set of known usernames is guessable by anyone who can compute it,
    /// so this is a defence against casual disclosure rather than against an
    /// adversary with the user list.
    case hashed

    func render(_ identity: ParticipantIdentity) -> String {
        switch self {
        case .full:
            "\(identity.username.value)/\(identity.device.value)"
        case .hashed:
            "\(Self.digest(identity.username.value))/\(Self.digest(identity.device.value))"
        }
    }

    static func digest(_ value: String) -> String {
        // FNV-1a: not a cryptographic choice and not pretending to be one. It is
        // here to shorten and delink, and `hashValue` would have been wrong for
        // it because Swift seeds that per process — two lines from one session
        // would agree and two sessions would not.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash.multipliedReportingOverflow(by: 0x100_0000_01b3).partialValue
        }
        return String(hash % 0xf_ffff, radix: 36)
    }
}

/// One thing worth writing down.
public struct LogRecord: Sendable {
    public let level: LogLevel
    public let category: LogCategory
    public let message: String
    public let fields: [LogField]

    public init(
        level: LogLevel,
        category: LogCategory,
        message: String,
        fields: [LogField] = []
    ) {
        self.level = level
        self.category = category
        self.message = message
        self.fields = fields
    }

    /// The record as one line, `key=value` after the message.
    public func line(privacy: LogPrivacy = .full) -> String {
        let rendered = fields.map { "\($0.name)=\($0.value.rendered(privacy))" }
        return ([message] + rendered).joined(separator: " ")
    }
}

/// Where log records go.
///
/// A protocol with one requirement, so an integrator can forward MOQOM's
/// diagnostics into whatever they already run rather than being told to read a
/// second log.
public protocol LogSink: Sendable {
    func write(_ record: LogRecord)
}

/// Discards everything.
public struct SilentLogSink: LogSink {
    public init() {}
    public func write(_ record: LogRecord) {}
}

/// Writes to the unified log, one `os.Logger` per category.
///
/// The loggers are built once rather than per record: constructing an
/// `os.Logger` is not free, and this is called from the receive path.
public struct SystemLogSink: LogSink {
    private let privacy: LogPrivacy
    private let loggers: [LogCategory: os.Logger]

    public init(subsystem: String = "cloud.moqom", privacy: LogPrivacy = .hashed) {
        self.privacy = privacy
        loggers = Dictionary(
            uniqueKeysWithValues: LogCategory.allCases.map {
                ($0, os.Logger(subsystem: subsystem, category: $0.rawValue))
            }
        )
    }

    public func write(_ record: LogRecord) {
        guard let logger = loggers[record.category] else { return }
        // Interpolated as `public` on purpose. Everything that needed hiding was
        // already reduced to a count or a digest by the time it got here, and
        // marking the whole line private would produce `<private>` in a support
        // ticket — which is the one situation this exists for.
        let line = record.line(privacy: privacy)
        switch record.level {
        case .trace, .debug: logger.debug("\(line, privacy: .public)")
        case .info: logger.info("\(line, privacy: .public)")
        case .warning: logger.warning("\(line, privacy: .public)")
        case .error: logger.error("\(line, privacy: .public)")
        }
    }
}

/// Keeps records in memory, for tests and for a debug overlay.
///
/// Bounded, because an unbounded diagnostic buffer is a memory leak that only
/// shows up on the longest sessions.
public final class RecordingLogSink: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [LogRecord] = []
    private let limit: Int

    public init(limit: Int = 1024) {
        self.limit = max(1, limit)
    }

    public func write(_ record: LogRecord) {
        lock.withLock {
            storage.append(record)
            if storage.count > limit {
                storage.removeFirst(storage.count - limit)
            }
        }
    }

    /// Everything held, oldest first.
    public var records: [LogRecord] {
        lock.withLock { storage }
    }

    /// The messages only, for asserting on what happened without pinning fields.
    public var messages: [String] {
        records.map(\.message)
    }

    public func clear() {
        lock.withLock { storage.removeAll() }
    }
}

/// The SDK's logger.
///
/// A struct rather than a class: it is copied into every actor that logs, and
/// the only mutable thing behind it is the sink.
public struct MoqomLogger: Sendable {
    public let sink: any LogSink

    /// Records below this are not built at all.
    public let minimum: LogLevel

    public init(sink: any LogSink, minimum: LogLevel = .info) {
        self.sink = sink
        self.minimum = minimum
    }

    /// A logger that writes nothing.
    ///
    /// The default everywhere. An SDK that logs to a host application's console
    /// without being asked is a bug report about the SDK, and the integrator who
    /// wants diagnostics is one line away from ``system(minimum:)``.
    public static let silent = MoqomLogger(sink: SilentLogSink(), minimum: .error)

    /// A logger that writes to the unified log.
    public static func system(minimum: LogLevel = .info) -> MoqomLogger {
        MoqomLogger(sink: SystemLogSink(), minimum: minimum)
    }

    /// Whether anything at `level` would be recorded.
    ///
    /// Public so a caller doing real work to build fields — walking a roster, for
    /// instance — can skip that too.
    public func records(_ level: LogLevel) -> Bool {
        level >= minimum
    }

    /// Write a record, if the level clears the threshold.
    ///
    /// Autoclosures throughout: a suppressed record costs one integer comparison,
    /// and neither the message nor the fields are evaluated.
    public func log(
        _ level: LogLevel,
        _ category: LogCategory,
        _ message: @autoclosure () -> String,
        _ fields: @autoclosure () -> [LogField] = []
    ) {
        guard records(level) else { return }
        sink.write(
            LogRecord(
                level: level,
                category: category,
                message: message(),
                fields: fields()
            )
        )
    }

    public func trace(
        _ category: LogCategory,
        _ message: @autoclosure () -> String,
        _ fields: @autoclosure () -> [LogField] = []
    ) {
        log(.trace, category, message(), fields())
    }

    public func debug(
        _ category: LogCategory,
        _ message: @autoclosure () -> String,
        _ fields: @autoclosure () -> [LogField] = []
    ) {
        log(.debug, category, message(), fields())
    }

    public func info(
        _ category: LogCategory,
        _ message: @autoclosure () -> String,
        _ fields: @autoclosure () -> [LogField] = []
    ) {
        log(.info, category, message(), fields())
    }

    public func warning(
        _ category: LogCategory,
        _ message: @autoclosure () -> String,
        _ fields: @autoclosure () -> [LogField] = []
    ) {
        log(.warning, category, message(), fields())
    }

    public func error(
        _ category: LogCategory,
        _ message: @autoclosure () -> String,
        _ fields: @autoclosure () -> [LogField] = []
    ) {
        log(.error, category, message(), fields())
    }
}

/// Milliseconds, for rendering `.elapsed` fields.
///
/// Deliberately not a public `Duration` extension: `MoqomKit` already has an
/// internal one of the same name, and a public one here would make every use of
/// it inside that module ambiguous.
private func milliseconds(_ duration: Duration) -> Int {
    let (seconds, attoseconds) = duration.components
    return Int(seconds * 1000) + Int(attoseconds / 1_000_000_000_000_000)
}
