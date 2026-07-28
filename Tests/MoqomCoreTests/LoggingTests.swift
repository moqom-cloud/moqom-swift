import Foundation
import Testing

@testable import MoqomCore

@Suite("Logging")
struct LoggingTests {
    @Test("a record below the threshold is not built at all")
    func suppressedRecordsCostNothing() {
        // The point of the autoclosures. This is called from the object receive
        // path, so a suppressed `trace` that still formatted its message would
        // add string work per object to produce something nobody reads.
        let sink = RecordingLogSink()
        let logger = MoqomLogger(sink: sink, minimum: .info)

        let built = Counter()
        logger.trace(.transport, built.tick("trace"))
        logger.debug(.transport, built.tick("debug"))

        #expect(sink.records.isEmpty)
        #expect(built.count == 0)

        logger.info(.transport, built.tick("info"))
        #expect(sink.messages == ["info"])
        #expect(built.count == 1)
    }

    @Test("fields are not evaluated for a suppressed record either")
    func suppressedFieldsCostNothing() {
        // Fields are usually the expensive half: walking a roster to describe a
        // room is real work, and a caller has no way to skip it if the logger
        // evaluates the argument before deciding.
        let logger = MoqomLogger(sink: SilentLogSink(), minimum: .error)
        let built = Counter()

        logger.debug(.room, "ignored", [LogField("who", .text(built.tick("field")))])

        #expect(built.count == 0)
    }

    @Test("records(_:) lets a caller skip building fields itself")
    func thresholdIsReadable() {
        let logger = MoqomLogger(sink: SilentLogSink(), minimum: .warning)
        #expect(!logger.records(.info))
        #expect(logger.records(.warning))
        #expect(logger.records(.error))
    }

    @Test("a payload can only be written down as a byte count")
    func payloadsAreReducedToSizes() {
        // The type-level guarantee. `LogValue` has no case holding `Data`, so
        // this is the most a caller can say about a payload — and the rendering
        // has no branch that could ever produce the bytes.
        let field = LogField("payload", .redacted(bytes: 1400))
        #expect(field.value.rendered(.full) == "<1400 bytes>")
        #expect(field.value.rendered(.hashed) == "<1400 bytes>")
    }

    @Test("hashed privacy hides the username but keeps lines correlatable")
    func hashingIsStableAndOpaque() {
        let alice = identity("alice", device: "iphone-0001")
        let value = LogValue.participant(alice)

        let hashed = value.rendered(.hashed)
        #expect(!hashed.contains("alice"))
        #expect(!hashed.contains("iphone-0001"))

        // Stable within and across sessions, which is the whole diagnostic value:
        // two lines about the same person have to be joinable, and `hashValue`
        // could not do this because Swift seeds it per process.
        #expect(hashed == value.rendered(.hashed))
        #expect(hashed == LogValue.participant(identity("alice", device: "iphone-0001"))
            .rendered(.hashed))

        // Different people stay different.
        #expect(hashed != LogValue.participant(identity("bob", device: "iphone-0001"))
            .rendered(.hashed))

        // And the same person on two devices, because multi-device is normal and
        // collapsing them would hide the case where one of the two is broken.
        #expect(hashed != LogValue.participant(identity("alice", device: "ipad-0002"))
            .rendered(.hashed))
    }

    @Test("full privacy is legible, for a log that stays on the device")
    func fullPrivacyIsReadable() {
        let value = LogValue.participant(identity("alice", device: "iphone-0001"))
        #expect(value.rendered(.full) == "alice/iphone-0001")
    }

    @Test("a line renders fields in the order they were written")
    func fieldOrderIsPreserved() {
        // Why fields are an array. A dictionary would reorder them differently on
        // every launch, and a log whose columns move is a log nobody can diff.
        let record = LogRecord(
            level: .info,
            category: .statistics,
            message: "sampled",
            fields: [
                LogField("first", .number(1)),
                LogField("second", .number(2)),
                LogField("third", .number(3)),
            ]
        )
        #expect(record.line() == "sampled first=1 second=2 third=3")
    }

    @Test("every value kind renders without leaking anything")
    func valuesRender() {
        #expect(LogValue.text("hello").rendered(.full) == "hello")
        #expect(LogValue.number(-4).rendered(.full) == "-4")
        #expect(LogValue.decimal(0.125).rendered(.full) == "0.125")
        #expect(LogValue.flag(true).rendered(.full) == "true")
        #expect(LogValue.flag(false).rendered(.full) == "false")
        #expect(LogValue.elapsed(.milliseconds(1500)).rendered(.full) == "1500ms")
    }

    @Test("the recording sink is bounded")
    func recordingSinkIsBounded() {
        // An unbounded diagnostic buffer is a leak that only appears on the
        // longest session, which is the one whose log matters most.
        let sink = RecordingLogSink(limit: 3)
        for index in 0..<10 {
            sink.write(LogRecord(level: .info, category: .session, message: "\(index)"))
        }
        #expect(sink.messages == ["7", "8", "9"])
    }

    @Test("categories and levels are exhaustive so a filter can be built from them")
    func filterableSurface() {
        // Both are `CaseIterable` on purpose: an application building a log-level
        // picker should not have to hard-code the list and then fall behind it.
        #expect(LogLevel.allCases.count == 5)
        #expect(Set(LogCategory.allCases.map(\.rawValue)).count == LogCategory.allCases.count)
        #expect(LogLevel.trace < LogLevel.debug)
        #expect(LogLevel.error > LogLevel.warning)
    }
}

private func identity(_ name: String, device: String = "iphone-0001") -> ParticipantIdentity {
    // Force-unwrapped rather than thrown: these are literals under test control
    // and a throwing helper would put a `try` on every line of every fixture.
    ParticipantIdentity(
        username: try! Username(name),
        device: try! DeviceID(device)
    )
}

/// Counts how many times an autoclosure argument was actually evaluated.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var evaluations = 0

    var count: Int { lock.withLock { evaluations } }

    /// Returns `value`, having recorded that it was asked for.
    func tick(_ value: String) -> String {
        lock.withLock { evaluations += 1 }
        return value
    }
}
