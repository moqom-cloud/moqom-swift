// Audio on the way in.
//
// The counterpart to `AudioPublication`, and the reason the jitter buffer is not
// a component with nothing plugged into it.
//
// Sequence numbers are the interesting problem. A jitter buffer needs a single
// monotonic index per packet, and MOQT gives a (group, object) pair whose object
// numbers restart at every group boundary. Deriving the index from
// `group * packetsPerGroup + object` would need the publisher's group size,
// which is a publisher-side configuration a subscriber never sees. So the index
// comes from the capture timestamp instead: every packet carries one, packets
// are a fixed duration apart, and dividing gives exactly the sequence the
// publisher would have assigned. It survives a group size change mid-stream,
// which the arithmetic version would not.
//
// The alternative — number packets by arrival — is what this exists to avoid.
// Arrival order on a lossy path is not send order, and a buffer that trusted it
// would reorder nothing and detect no loss.

import Foundation
import MoqomCore

/// What to do with an arriving audio object.
public struct AudioReceiver: Sendable {
    /// The format the publisher's catalog names, which sets the packet duration
    /// and therefore the sequence arithmetic.
    public private(set) var format: AudioFormat

    public private(set) var buffer: JitterBuffer

    /// Packets whose timestamp could not be turned into a sequence number.
    ///
    /// Counted rather than guessed at. A publisher that omits capture time is
    /// out of spec for this SDK, and inventing an order for its packets would
    /// hide that behind audio that sounds slightly wrong.
    public private(set) var packetsWithoutTiming = 0

    public init(format: AudioFormat = .voice) {
        self.format = format
        buffer = JitterBuffer(format: format)
    }

    /// Adopt the format the catalog describes.
    ///
    /// Resets the buffer: the packet duration is what sequence numbers are
    /// measured in, so held packets are indexed against the old scale.
    public mutating func setFormat(_ format: AudioFormat) {
        guard format != self.format else { return }
        self.format = format
        buffer = JitterBuffer(format: format)
    }

    /// Take one object off the audio track.
    ///
    /// - Parameter arrival: A monotonic reading, for the jitter estimate.
    /// - Returns: Whether the packet was accepted into the buffer.
    @discardableResult
    public mutating func accept(_ object: TrackObject, at arrival: Duration) -> Bool {
        guard let timestamp = object.properties.captureTime else {
            packetsWithoutTiming += 1
            return false
        }

        let packetNanoseconds = UInt64(
            max(1, format.frameDuration.components.seconds * 1_000_000_000
                + format.frameDuration.components.attoseconds / 1_000_000_000)
        )

        buffer.insert(
            sequence: timestamp.nanoseconds / packetNanoseconds,
            EncodedAudioFrame(
                timestamp: timestamp,
                duration: format.frameDuration,
                data: object.payload,
                isSilence: object.properties.isSilence ?? false
            ),
            at: arrival
        )
        return true
    }

    /// Pull the next slot, for whatever drives the speaker.
    public mutating func next() -> JitterBufferOutput {
        buffer.next()
    }

    /// Throw away what is held. For a resubscribe or a network change.
    public mutating func reset() {
        buffer.reset()
    }
}

public extension AudioFormat {
    /// Read a format out of a catalog's audio track.
    ///
    /// Frame duration is not in the catalog and is not guessed per publisher:
    /// 20ms is what this SDK publishes and what any interoperating stack will
    /// send. A publisher using something else would need to say so, which is a
    /// catalog change rather than an inference.
    init(_ track: CatalogTrack) {
        self.init(
            sampleRate: track.sampleRate ?? 48000,
            channels: track.channels ?? 1
        )
    }
}
