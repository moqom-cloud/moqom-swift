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
// Parameter sets arrive two ways and the difference is not redundancy. The
// catalog carries them ahead of the media, which is what lets a viewer join at
// an arbitrary group without waiting for an IDR. Each keyframe carries them
// again, which is what lets the picture change shape: a publisher may switch
// geometry mid-track when its host changes layout, and the group that opens the
// new geometry describes itself rather than depending on a catalog update
// winning a race against the media it describes.
//
// So the keyframe wins where they disagree, and a disagreement is not a fault.

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

    /// This keyframe describes a different picture than the one before it.
    ///
    /// Deliberately not a kind of gap, though the code once treated it as one.
    /// Nothing was lost: the publisher changed geometry and this frame opens the
    /// new one, complete and decodable. Reporting it as a gap made a renderer
    /// blank itself and re-anchor its clock, so a host rotating their phone cost
    /// every viewer a black flash — for an event where the correct behaviour is
    /// to keep showing the last picture until this one decodes and then simply
    /// be a different size.
    public let changesFormat: Bool

    public init(frame: EncodedFrame, followsGap: Bool, changesFormat: Bool = false) {
        self.frame = frame
        self.followsGap = followsGap
        self.changesFormat = changesFormat
    }
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

    /// Whether a keyframe has supplied the configuration. See
    /// ``setDecoderConfiguration(_:)``.
    private var configuredInBand = false

    /// Set when the next frame follows a hole, cleared when it is reported.
    private var gapPending = false

    public init() {}

    /// Whether a decoder can be configured yet.
    public var isConfigured: Bool { !parameterSets.isEmpty }

    /// The parameter sets, for building a format description.
    public var decoderParameterSets: [Data] { parameterSets }

    /// Install the configuration from a catalog track.
    ///
    /// Only until the media starts describing itself. The first keyframe to
    /// carry its own configuration ends the catalog's authority here, and the
    /// reason is a race that has a wrong answer rather than a slow one: the
    /// catalog is a different track, so a publisher that changes geometry
    /// publishes a new catalog version and a reshaped keyframe at nearly the
    /// same moment, and they can arrive in either order. If the catalog could
    /// still write here, a version describing the *old* geometry landing just
    /// after the new keyframe would replace a correct configuration with a stale
    /// one — and the viewer would tear the picture until the next keyframe
    /// rather than simply changing size.
    ///
    /// - Returns: Whether the buffer parsed. A rejected configuration leaves
    ///   the previous one in place, because a viewer already decoding should
    ///   not be stopped by a malformed republish.
    @discardableResult
    public mutating func setDecoderConfiguration(_ data: Data) -> Bool {
        guard let sets = DecoderConfiguration.decode(data) else { return false }
        guard !configuredInBand else { return true }
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

        // Taken before the continuity check, because a keyframe that carries its
        // own configuration is decodable whatever preceded it, and because the
        // answer changes what the frame means: the same keyframe is a recovery
        // after loss or a change of shape, and a renderer treats those
        // differently.
        let reshaped = adoptConfiguration(carriedBy: input)

        noteContinuity(of: input)
        started = true
        group = input.group
        object = input.object

        // The sets go on the keyframe rather than every frame so the assembler
        // rebuilds its format description at group boundaries and nowhere else.
        let frame = EncodedFrame(
            timestamp: input.properties.captureTime ?? FrameTimestamp(nanoseconds: 0),
            isKeyFrame: input.isKeyFrame,
            temporalLayer: input.properties.temporalLayer ?? 0,
            data: input.payload,
            parameterSets: input.isKeyFrame ? parameterSets : []
        )
        framesProduced += 1

        defer { gapPending = false }
        return DepacketisedFrame(
            frame: frame,
            followsGap: gapPending,
            changesFormat: reshaped
        )
    }

    /// Take the configuration a keyframe carries, if it says something new.
    ///
    /// - Returns: Whether this object changed the format. False when the sets
    ///   match what is already installed, which is the common case: every
    ///   keyframe carries them and almost none of them are news.
    private mutating func adoptConfiguration(carriedBy input: TrackObject) -> Bool {
        guard
            input.isKeyFrame,
            let carried = input.properties.configuration,
            let sets = DecoderConfiguration.decode(carried)
        else { return false }

        configuredInBand = true
        guard sets != parameterSets else { return false }
        parameterSets = sets

        // No `gapPending` and no reset of `started`, which is the entire
        // difference from taking a configuration off the catalog. There the sets
        // arrive detached from the media and the frame they apply to is still to
        // come, so everything in flight is suspect. Here they arrive *on* the
        // first frame they describe.
        //
        // First configuration of the stream is not a change of shape either. It
        // is the shape, and a viewer that reported its own first frame as a
        // reshape would make every join look like a layout switch.
        return framesProduced > 0
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
