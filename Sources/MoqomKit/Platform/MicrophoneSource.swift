// The microphone.
//
// Thin, now, because everything that used to be here is in ``AudioGraph``: the
// engine, the format conversion, the accumulation into whole packets, and the
// route changes that invalidate all three. What is left is the reason to keep
// the name -- it is the ``AudioSource`` a publication takes, and it reads as the
// counterpart of a camera rather than as a graph operation.
//
// The default is the shared graph, and that is the substantive change. Capture
// and playback have to sit on one engine for echo cancellation to be possible at
// all, so a microphone that built its own engine could not be cancelled against
// anything the room was saying. Anyone who genuinely wants an isolated graph can
// pass one; nobody gets one by accident.
//
// > Important: This compiles wherever AVFAudio does and nothing in the test
// > suite runs it. It needs real hardware and, on iOS, a microphone
// > permission grant.

import Foundation
import MoqomCore

#if canImport(AVFAudio)
    import AVFAudio

    /// Captured audio from the system input device.
    public final class MicrophoneSource: AudioSource, @unchecked Sendable {
        public let format: AudioFormat

        private let graph: AudioGraph
        private let relay: AudioRelay
        private let owned: Bool
        private let lock = NSLock()
        private var running = false

        /// - Parameters:
        ///   - graph: where to capture from. The shared graph unless there is a
        ///     reason, because that is the one playback is mixed into and
        ///     therefore the only one whose echo canceller has a reference.
        ///   - format: what the encoder wants, which is not necessarily what the
        ///     hardware produces.
        public init(
            graph: AudioGraph = .shared,
            format: AudioFormat = .voice
        ) throws(MoqomError) {
            self.format = format
            self.graph = graph
            // Started here only when this is the shared graph and nothing else
            // has claimed it. A caller holding its own graph is running the
            // lifecycle itself, and starting it from underneath would take the
            // decision away.
            owned = graph === AudioGraph.shared
            relay = try graph.microphone(format: format)
        }

        public func frames() -> AsyncStream<AudioFrame> { relay.frames() }

        /// Open the device and start delivering.
        public func start() throws(MoqomError) {
            lock.lock()
            defer { lock.unlock() }
            guard !running else { return }
            if owned { try graph.start() }
            running = true
        }

        public func stop() {
            lock.lock()
            if running {
                if owned { graph.stop() }
                running = false
            }
            lock.unlock()
            relay.stop()
        }

        /// What the microphone is hearing, for a level meter.
        public var meter: AudioMeter { graph.meter }

        /// Whether the system is cancelling the room's own output.
        ///
        /// Worth surfacing in an interface. A broadcaster on speakerphone
        /// without cancellation is the source of everybody else's echo and is
        /// the last person in the room to find out.
        public var isCancellingEcho: Bool { graph.isCancellingEcho }
    }
#endif
