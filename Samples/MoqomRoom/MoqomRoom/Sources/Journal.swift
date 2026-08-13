// Everything the console says, kept on the device as well.
//
// The reports this app prints are only reachable when a Mac started the process: `devicectl`
// pipes stdout for an app it launched and for no other. Every fault worth diagnosing so far
// has been reported by somebody using the phone by hand — tapping Go live, changing the
// layout, watching a tile stay black — and that session is exactly the one with nowhere for
// its output to go. Relaunching it from a Mac to get the log changes the run.
//
// So the same lines go to a file in the app's own container, which can be pulled off
// afterwards with `devicectl device copy from` no matter who started the app.
//
// Stdout and the unified log are the other half of that story, and they are how a Mac
// watching the phones over Wi-Fi hitch the radio the media is using. Two live console
// streams stalled both phones' transport writes at once — max 490ms and 1210ms, zero
// loss, p50 untouched — and the picture a person watching called choppy; the same build
// launched by hand, or with the phones on USB, was not. Release therefore writes the
// file and nothing that leaves the device. Debug still prints, because that is how a
// scripted run is read.

import Foundation
import MoqomCore

/// The console, and a file beside it.
final class Journal: @unchecked Sendable {
    static let shared = Journal()

    /// Where the file is, for the script that fetches it.
    static let name = "moqom.log"

    private let queue = DispatchQueue(label: "cloud.moqom.journal", qos: .utility)
    private let url: URL?
    private var handle: FileHandle?

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        url = documents.first?.appendingPathComponent(Self.name)
    }

    /// Start a session's worth of log, discarding the last one.
    ///
    /// Truncated rather than appended, because the question being asked of this file is always
    /// "what did the run I just did do?" and a file that accumulates every run since the app
    /// was installed answers a different one.
    func begin() {
        queue.async { [self] in
            guard let url else { return }
            handle?.closeFile()
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = try? FileHandle(forWritingTo: url)
        }
    }

    func say(_ line: String) {
        #if DEBUG
        print(line)
        #endif

        // Stamped here rather than by whoever reads it. Half of what these lines are used for
        // is lining two of them up — a freeze on one phone against a stall on the other — and
        // a report that only says what the counters were cannot be lined up with anything.
        let stamped = Self.clock.string(from: Date()) + " " + line + "\n"
        queue.async { [self] in
            guard let data = stamped.data(using: .utf8) else { return }
            handle?.write(data)
        }
    }

    /// Where SDK diagnostics go without a live pipe to a Mac.
    ///
    /// The unified log is collected over the same CoreDevice tunnel as stdout. In Debug that
    /// is the point — Console.app is how those lines are read. In Release it is traffic on
    /// the radio the call is using, so the sink is silent and the file is the record.
    static var diagnostics: any LogSink {
        #if DEBUG
        SystemLogSink(subsystem: "cloud.moqom.sample", privacy: .hashed)
        #else
        SilentLogSink()
        #endif
    }

    /// The SDK's own diagnostics, into the same file.
    ///
    /// Warnings especially. The line that says a subscription was refused is written by the
    /// session, goes to the unified log, and is therefore invisible on a phone in somebody's
    /// hand — while the symptom, a tile that is black on a call whose audio is fine, is the
    /// hardest thing here to diagnose without it.
    struct Sink: LogSink {
        let minimum: LogLevel

        func write(_ record: LogRecord) {
            guard record.level >= minimum else { return }
            Journal.shared.say("SDK \(record.level) \(record.category) \(record.line())")
        }
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}
