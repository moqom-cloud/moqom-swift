// What somebody wants to happen, as distinct from what has happened.
//
// A shared space has one authority and everybody else watches. That is what
// makes it consistent, and on its own it would also make it unplayable: only
// one person in the room could ever do anything. This is the other direction —
// the small, rare, upstream channel that lets a viewer reach into a simulation
// they do not own.
//
// # An intent is not a state change
//
// The temptation is to let a participant write to the space track directly and
// have readers merge. That is a multi-writer replicated type, and every one of
// them either needs a conflict rule per field or arrives at a state no single
// participant ever intended. Two people grabbing the same piece is the case
// that kills it: merged, they both hold it.
//
// So an intent says *what was wanted*, not what is now true. The authority
// decides — and the loser of a race finds out by seeing the winner's name on
// the thing rather than by watching their own local drag get silently
// overruled. That decision is application logic, which is why nothing here
// interprets `verb`.
//
// # Why it is idempotent and numbered
//
// Intents travel on a track like everything else, so they can be redelivered
// after a repair, and a re-applied "fire" is a second shot. Each sender numbers
// its own intents, and the authority ignores a number it has already seen —
// which is a per-sender high-water mark and nothing more, because a sender's
// own intents arrive in order on one track.
//
// The numbering is per sender rather than global for the same reason entity
// identifiers are chosen by the application: allocating from the authority
// would cost a round trip at the exact moment a tap wants to feel immediate.

import Foundation
import MoqomCore

/// Something a participant asks the space to do.
///
/// The application decides what a verb means. This carries it, says who wanted
/// it and when, and gives the authority enough to ignore a repeat.
public struct SpaceIntent: Hashable, Sendable {
    /// Format version, so a peer refuses an intent it would misread.
    public var version: Int

    /// This sender's own count, from 1, in the order it meant them.
    ///
    /// The authority keeps the highest it has applied per sender and drops
    /// anything at or below it, which makes a redelivery inert.
    public var sequence: UInt64

    /// What was wanted. Application-defined, like ``SpaceEntity/kind``.
    public var verb: String

    /// What it was wanted for, when the verb takes an object.
    public var subject: SpaceEntityID?

    /// Where it happened, in space coordinates — never the device's own.
    ///
    /// A tap is a point in somebody's living room until ``SpaceAnchor`` turns
    /// it into a point on the shared board. Sending the raw one would tell the
    /// room where the sender's furniture is and would mean nothing to anybody
    /// else's renderer.
    public var at: SpaceVector?

    /// Anything else the verb needs. Absolute values, as everywhere here.
    public var facts: [String: SpaceValue]

    /// A kind or a name the verb needs: what to spawn, which event to send.
    public var kind: String?

    /// A whole pose, for a verb that places something rather than points at it.
    public var pose: SpacePose?

    /// When the sender wanted it, on the shared timeline.
    ///
    /// The authority can use this to resolve a race by intent rather than by
    /// arrival, which is the difference between the faster player winning and
    /// the closer-to-the-relay player winning.
    public var when: Timecode

    public static let currentVersion = 1

    public init(
        verb: String,
        subject: SpaceEntityID? = nil,
        at: SpaceVector? = nil,
        facts: [String: SpaceValue] = [:],
        sequence: UInt64 = 0,
        when: Timecode = .fallback(),
        version: Int = SpaceIntent.currentVersion,
        kind: String? = nil,
        pose: SpacePose? = nil
    ) {
        self.version = version
        self.kind = kind
        self.pose = pose
        self.sequence = sequence
        self.verb = verb
        self.subject = subject
        self.at = at
        self.facts = facts
        self.when = when
    }
}

public extension SpaceIntent {
    /// The track a participant publishes their intents on, under their own
    /// namespace.
    ///
    /// Per sender rather than one shared upstream track, because the relay
    /// authorises by namespace: a participant may write under their own prefix
    /// and nowhere else. A shared track would need every participant to hold a
    /// grant on it, and a grant that everybody holds is not a grant.
    static let trackName = ".intent"

    /// Ahead of the space track's 24, behind control and media.
    ///
    /// An intent is tens of bytes and happens when a finger lands. The state it
    /// provokes is kilobytes and happens sixty times a second, and queueing the
    /// tap behind a burst of that is the one delay a player attributes to the
    /// game being unresponsive rather than to the network.
    static let priority: UInt8 = 20
}

// MARK: - The wire

private enum IntentTag {
    static let version: UInt32 = 1
    static let sequence: UInt32 = 2
    static let verb: UInt32 = 3
    static let subject: UInt32 = 4
    static let at: UInt32 = 5
    static let nanoseconds: UInt32 = 6
    static let uncertainty: UInt32 = 7
    static let trust: UInt32 = 8
    static let fact: UInt32 = 9
    static let kind: UInt32 = 10
    static let pose: UInt32 = 11
}

private enum FactTag {
    static let key: UInt32 = 1
    static let flag: UInt32 = 2
    static let number: UInt32 = 3
    static let decimal: UInt32 = 4
    static let text: UInt32 = 5
}

/// Three little-endian floats.
private let vectorStride = 12

/// Position, rotation, scale: eight little-endian floats, as on the space track.
private let poseStride = 32

public extension SpaceIntent {
    /// The bytes to publish.
    ///
    /// Free-standing, unlike ``SpaceUpdate``, because an intent interns nothing
    /// — it is a single message that has to make sense on its own, sent by a
    /// participant who may have joined a moment ago and holds no table.
    func encoded() -> Data {
        var writer = RecordWriter(capacity: 96)
        writer.varInt(IntentTag.version, UInt64(version))
        writer.varInt(IntentTag.sequence, sequence)
        writer.string(IntentTag.verb, verb)
        if let subject { writer.string(IntentTag.subject, subject.rawValue) }
        if let at {
            writer.fixedArray(IntentTag.at, stride: vectorStride, count: 1) { _, buffer in
                buffer.rawFloat(at.x)
                buffer.rawFloat(at.y)
                buffer.rawFloat(at.z)
            }
        }
        if let kind { writer.string(IntentTag.kind, kind) }
        if let pose {
            writer.fixedArray(IntentTag.pose, stride: poseStride, count: 1) { _, buffer in
                buffer.rawFloat(pose.position.x)
                buffer.rawFloat(pose.position.y)
                buffer.rawFloat(pose.position.z)
                buffer.rawFloat(pose.rotation.x)
                buffer.rawFloat(pose.rotation.y)
                buffer.rawFloat(pose.rotation.z)
                buffer.rawFloat(pose.rotation.w)
                buffer.rawFloat(pose.scale)
            }
        }
        writer.fixed64(IntentTag.nanoseconds, when.nanoseconds)
        writer.varInt(IntentTag.uncertainty, UInt64(max(0, when.uncertainty.wholeNanoseconds)))
        writer.varInt(IntentTag.trust, UInt64(when.trust.wireCode))

        // Sorted, so the same intent encodes to the same bytes twice.
        for key in facts.keys.sorted() {
            writer.record(IntentTag.fact) { inner in
                inner.string(FactTag.key, key)
                switch facts[key]! {
                case let .flag(value): inner.boolean(FactTag.flag, value)
                case let .number(value): inner.fixed64(FactTag.number, value)
                case let .decimal(value): inner.double(FactTag.decimal, value)
                case let .text(value): inner.string(FactTag.text, value)
                }
            }
        }
        return writer.bytes
    }

    /// Read an intent somebody published.
    init(decoding data: Data) throws(WireError) {
        var reader = RecordReader(data)
        var version = 0
        var sequence: UInt64 = 0
        var verb: String?
        var subject: SpaceEntityID?
        var at: SpaceVector?
        var nanoseconds: Int64 = 0
        var uncertainty = Duration.zero
        var trust = TimeTrust.fallback
        var facts: [String: SpaceValue] = [:]
        var kind: String?
        var pose: SpacePose?

        while let key = try reader.nextKey() {
            switch key.tag {
            case IntentTag.version:
                version = Int(try reader.varInt())
            case IntentTag.sequence:
                sequence = try reader.varInt()
            case IntentTag.verb:
                verb = try reader.string()
            case IntentTag.subject:
                subject = SpaceEntityID(try reader.string())
            case IntentTag.at:
                let array = try reader.fixedArray(stride: vectorStride)
                guard array.count == 1 else {
                    throw WireError.invalid("an intent carrying \(array.count) positions")
                }
                at = array.withElement(0) { raw in
                    func float(_ offset: Int) -> Float {
                        Float(bitPattern: UInt32(
                            littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                        ))
                    }
                    return SpaceVector(x: float(0), y: float(4), z: float(8))
                }
            case IntentTag.kind:
                kind = try reader.string()
            case IntentTag.pose:
                let array = try reader.fixedArray(stride: poseStride)
                guard array.count == 1 else {
                    throw WireError.invalid("an intent carrying \(array.count) poses")
                }
                // Through the normalising initialisers, so a drifted or hostile
                // quaternion arrives as a rotation.
                pose = array.withElement(0) { raw in
                    func float(_ offset: Int) -> Float {
                        Float(bitPattern: UInt32(
                            littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                        ))
                    }
                    return SpacePose(
                        position: SpaceVector(x: float(0), y: float(4), z: float(8)),
                        rotation: SpaceRotation(x: float(12), y: float(16), z: float(20), w: float(24)),
                        scale: float(28)
                    )
                }
            case IntentTag.nanoseconds:
                nanoseconds = try reader.fixed64()
            case IntentTag.uncertainty:
                uncertainty = .nanoseconds(try reader.varInt())
            case IntentTag.trust:
                trust = TimeTrust(wireCode: UInt8(truncatingIfNeeded: try reader.varInt()))
            case IntentTag.fact:
                let fact = try Self.fact(from: try reader.record())
                facts[fact.key] = fact.value
            default:
                try reader.skip(key)
            }
        }

        guard version <= SpaceIntent.currentVersion else {
            throw WireError.invalid(
                "space intent version \(version), which this build cannot read"
            )
        }
        guard let verb else {
            throw WireError.invalid("a space intent with no verb")
        }

        self.init(
            verb: verb,
            subject: subject,
            at: at,
            facts: facts,
            sequence: sequence,
            when: Timecode(
                nanoseconds: nanoseconds,
                uncertainty: uncertainty,
                trust: trust
            ),
            version: version,
            kind: kind,
            pose: pose
        )
    }

    private static func fact(
        from reader: RecordReader
    ) throws(WireError) -> (key: String, value: SpaceValue) {
        var inner = reader
        var name: String?
        var value: SpaceValue?
        while let key = try inner.nextKey() {
            switch key.tag {
            case FactTag.key: name = try inner.string()
            case FactTag.flag: value = .flag(try inner.flag())
            case FactTag.number: value = .number(try inner.fixed64())
            case FactTag.decimal: value = .decimal(try inner.double())
            case FactTag.text: value = .text(try inner.string())
            default: try inner.skip(key)
            }
        }
        guard let name, let value else {
            throw WireError.invalid("a fact missing its key or its value")
        }
        return (name, value)
    }
}
