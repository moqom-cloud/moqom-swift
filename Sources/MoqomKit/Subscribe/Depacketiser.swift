// Turning a track back into frames.
//
// The exact inverse of what `Broadcast` does on the way out, and it lives in
// one file with the forward direction's format helper for the obvious reason:
// two implementations of a length-prefix convention in different files will
// disagree eventually, and the symptom is a decoder that fails on a stream we
// produced ourselves.
//
// Three things happen here that are not just unwrapping.
//
// A decoder cannot start in the middle of a group, so objects before the first
// keyframe are dropped rather than handed on. Passing them along would produce
// a picture made of macroblocks that reference frames that never arrived, which
// looks like a corrupt encoder rather than a normal join.
//
// Gaps are detected and reported instead of hidden. Object IDs within a group
// are consecutive by construction, so a jump means the relay shed something or
// the link lost it — and the renderer's correct response is to flush and wait,
// which it can only do if someone tells it.
//
// Parameter sets come from the catalog, not from the bitstream. That is the
// whole reason a viewer can join at an arbitrary group: the configuration
// arrived before the media did, so there is no wait for the next IDR to carry
// it inline.

import Foundation
import MoqomCore

/// How parameter sets travel: length-prefixed and concatenated.
///
/// A flat buffer rather than an array because it has to survive a trip through
/// JSON as one hex string in the catalog, and because a decoder is configured
/// by walking it once.
public enum DecoderConfiguration {
    /// Concatenate, in the order the encoder produced them. Order matters —
    /// VPS before SPS before PPS — and is the encoder's to decide.
    public static func encode(_ parameterSets: [Data]) -> Data {
        var data = Data()
        for set in parameterSets {
            withUnsafeBytes(of: UInt32(set.count).bigEndian) { data.append(contentsOf: $0) }
            data.append(set)
        }
        return data
    }

    /// Split back apart.
    ///
    /// Returns `nil` on a truncated or self-inconsistent buffer rather than
    /// returning the sets it managed to read: a partial set list builds a
    /// format description that is wrong rather than absent, and the resulting
    /// failure surfaces frames later.
    public static func decode(_ data: Data) -> [Data]? {
        var sets: [Data] = []
        var index = data.startIndex

        while index < data.endIndex {
            guard data.distance(from: index, to: data.endIndex) >= 4 else { return nil }
            let lengthEnd = data.index(index, offsetBy: 4)
            let length = data[index ..< lengthEnd].reduce(into: UInt32(0)) { total, byte in
                total = total << 8 | UInt32(byte)
            }
            guard
                length > 0,
                data.distance(from: lengthEnd, to: data.endIndex) >= Int(length)
            else { return nil }

            let end = data.index(lengthEnd, offsetBy: Int(length))
            sets.append(Data(data[lengthEnd ..< end]))
            index = end
        }

        return sets.isEmpty ? nil : sets
    }
}

/// One frame, plus what happened before it.
public struct DepacketisedFrame: Sendable {
    public let frame: EncodedFrame

    /// Objects went missing between the previous frame and this one.
    ///
    /// A renderer should flush on this. Enqueueing across a gap means feeding
    /// the decoder frames whose references are missing, and the artefacts
    /// persist until the next keyframe regardless.
    public let followsGap: Bool
}

/// Reassembles a video track's objects into decodable frames.
///
/// One per subscribed track. Reused across a rung change would be wrong: the
/// parameter sets differ per rung, and the object numbering restarts.
public struct VideoDepacketiser: Sendable {
    /// Objects dropped because no keyframe had been seen yet.
    public private(set) var objectsAwaitingKeyFrame = 0

    /// Objects that never arrived, inferred from gaps in object IDs.
    public private(set) var objectsLost = 0

    public private(set) var framesProduced = 0

    private var parameterSets: [Data] = []
    private var started = false
    private var group: UInt64?
    private var object: UInt64?

    /// Set when the next frame follows a hole, cleared when it is reported.
    private var gapPending = false

    public init() {}

    /// Whether a decoder can be configured yet.
    public var isConfigured: Bool { !parameterSets.isEmpty }

    /// The parameter sets, for building a format description.
    public var decoderParameterSets: [Data] { parameterSets }

    /// Install the configuration from a catalog track.
    ///
    /// - Returns: Whether the buffer parsed. A rejected configuration leaves
    ///   the previous one in place, because a viewer already decoding should
    ///   not be stopped by a malformed republish.
    @discardableResult
    public mutating func setDecoderConfiguration(_ data: Data) -> Bool {
        guard let sets = DecoderConfiguration.decode(data) else { return false }
        guard sets != parameterSets else { return true }
        parameterSets = sets

        // A configuration change means a different bitstream. Whatever was
        // being decoded no longer applies, so the next frame has to be a
        // keyframe and the renderer has to flush — but only if there was
        // something to flush. Reporting a gap on the first configuration, which
        // normally arrives before any media, would have every stream open by
        // announcing that it had already lost something.
        gapPending = started
        started = false
        return true
    }

    /// Convenience for the hex form the catalog carries.
    @discardableResult
    public mutating func setDecoderConfiguration(hexadecimal: String) -> Bool {
        guard let data = Data(hexadecimal: hexadecimal) else { return false }
        return setDecoderConfiguration(data)
    }

    /// Objects a fetch reported as not existing.
    public private(set) var objectsSkipped = 0

    /// Account for objects a fetch said were never published.
    ///
    /// The difference from a gap in a live stream is that this one is final. A
    /// missing live object might still be in flight, so the depacketiser waits;
    /// an object a publisher says does not exist is never arriving, and counting
    /// it as lost would make a sparse track look like a broken link.
    public mutating func skip(through object: UInt64) {
        guard let current = self.object, object > current else { return }
        objectsSkipped += Int(object - current)
        self.object = object
        gapPending = started
    }

    /// Take one object off the track.
    ///
    /// - Returns: A frame, or `nil` when this object cannot start or continue
    ///   a decodable sequence.
    public mutating func accept(_ input: TrackObject) -> DepacketisedFrame? {
        if !started, !input.isKeyFrame {
            objectsAwaitingKeyFrame += 1
            return nil
        }

        noteContinuity(of: input)
        started = true
        group = input.group
        object = input.object

        // The sets go on the keyframe rather than every frame so the assembler
        // rebuilds its format description at group boundaries and nowhere
        // else. They come from the catalog either way; this just chooses where
        // to hand them over.
        let frame = EncodedFrame(
            timestamp: input.properties.captureTime ?? FrameTimestamp(nanoseconds: 0),
            isKeyFrame: input.isKeyFrame,
            temporalLayer: input.properties.temporalLayer ?? 0,
            data: input.payload,
            parameterSets: input.isKeyFrame ? parameterSets : []
        )
        framesProduced += 1

        defer { gapPending = false }
        return DepacketisedFrame(frame: frame, followsGap: gapPending)
    }

    /// Work out whether anything is missing in front of this object.
    ///
    /// Within a group, object IDs are consecutive, so the arithmetic is exact.
    /// Across groups it is not — a shed group leaves no trace in the numbering
    /// of the next one — so a group jump counts as a gap without counting how
    /// many objects it cost.
    private mutating func noteContinuity(of input: TrackObject) {
        guard let group, let object else { return }

        if input.group != group {
            // Rewinding is not a gap. It happens on a resubscribe, and the new
            // group is decodable on its own.
            if input.group > group + 1 { gapPending = true }
            return
        }

        if input.object > object + 1 {
            objectsLost += Int(input.object - object - 1)
            gapPending = true
        }
    }
}
