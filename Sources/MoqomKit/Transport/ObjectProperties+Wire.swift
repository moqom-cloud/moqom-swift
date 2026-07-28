// Mapping media metadata onto MOQT object properties.
//
// The codes live in the draft's application range, which exists so that a
// deployment can define its own object metadata without waiting for a registry
// entry. Even codes carry a varint, odd codes carry bytes — the parity *is* the
// discriminator, there is no type tag — so everything MOQOM defines here is
// even and none of it needs a length.
//
// A relay that does not know these forwards them untouched, which is the
// property that makes them safe to add: an old relay in the path costs the
// receiver nothing.

import Foundation
import MoqomCore
import MoqomWire

/// MOQOM's object property codes.
///
/// From the small application range (`0x78...0x7F`), where a code costs one
/// byte of delta. Per-object overhead is the budget being spent here: at 30
/// frames a second across four layers, a second byte per property is 240 bytes
/// a second of pure framing.
public enum MoqomObjectProperty {
    /// Capture time in microseconds.
    ///
    /// Microseconds rather than nanoseconds because a varint of a nanosecond
    /// timestamp is eight bytes for anything past a few seconds of uptime,
    /// and no display pipeline resolves better than a microsecond anyway.
    public static let captureTimeMicroseconds: UInt64 = 0x78

    /// Temporal layer index, `0` being the base.
    public static let temporalLayer: UInt64 = 0x7A

    /// Non-zero when an audio packet is silence.
    ///
    /// A property rather than a flag inside the payload, so a receiver can tell
    /// silence from loss without decoding and a relay can tell it without
    /// decrypting.
    public static let silence: UInt64 = 0x7C
}

extension ObjectProperties {
    /// As wire parameters, omitting anything absent.
    var parameters: Parameters {
        var items: [Parameter] = []
        if let captureTime,
           let parameter = try? Parameter.integer(
               MoqomObjectProperty.captureTimeMicroseconds,
               captureTime.nanoseconds / 1000
           )
        {
            items.append(parameter)
        }
        if let temporalLayer, temporalLayer >= 0,
           let parameter = try? Parameter.integer(
               MoqomObjectProperty.temporalLayer,
               UInt64(temporalLayer)
           )
        {
            items.append(parameter)
        }
        // Only when true. A property that says "not silence" on every packet of
        // a conversation is a byte per packet to state the default.
        if isSilence == true,
           let parameter = try? Parameter.integer(MoqomObjectProperty.silence, 1)
        {
            items.append(parameter)
        }
        return Parameters(items)
    }

    /// From wire parameters, ignoring anything we do not recognise.
    ///
    /// Ignoring rather than rejecting: the draft requires unknown properties to
    /// be forwarded and tolerated, and a receiver that refused an object
    /// because a newer publisher tagged it with something extra would break on
    /// every upgrade.
    init(_ parameters: Parameters) {
        let microseconds = parameters.integer(MoqomObjectProperty.captureTimeMicroseconds)
        let layer = parameters.integer(MoqomObjectProperty.temporalLayer)
        let silence = parameters.integer(MoqomObjectProperty.silence)
        self.init(
            captureTime: microseconds.map { FrameTimestamp(nanoseconds: $0 * 1000) },
            temporalLayer: layer.map { Int($0) },
            // Absent means "not stated", which for audio means not silence. It
            // stays `nil` rather than becoming `false` so a video object does
            // not start claiming to be audible.
            isSilence: silence.map { $0 != 0 }
        )
    }
}
