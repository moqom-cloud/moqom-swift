// The shared space track on the wire.
//
// This is the one track in MOQOM where the encoding was worth designing rather
// than defaulting, and the two decisions that matter are both about the same
// thing: what a *tick* costs, because a tick happens sixty times a second and
// goes to everybody.
//
// # Entities are numbered, not named
//
// ``SpaceEntityID`` is an application-chosen string, and that is the right thing
// for an API — making a game wait for the authority to allocate an identifier
// costs a round trip at the exact moment it wants to feel immediate. It is the
// wrong thing to put on the wire sixty times a second. `"player-2-left-hand"` is
// nineteen bytes to say something the receiver already knows.
//
// So the strings are interned. A snapshot carries the names and assigns each a
// `UInt32` handle; deltas carry handles alone. This is safe because of a rule
// the design already had for other reasons — every group begins with a snapshot,
// and a subscriber joins at a group boundary — so the mapping always arrives
// before anything that uses it. A spawn mid-group carries both.
//
// The consequence is that the codec is *stateful*: an encoder and a decoder each
// hold a table, one per publication or subscription, and a snapshot replaces it
// outright. That last part is what makes handles survive an authority handover,
// since the new authority numbers things its own way and says so in the snapshot
// that opens its epoch.
//
// A handle nobody has seen is an error rather than a skipped entity. It means a
// snapshot was missed, the whole delta is suspect, and the caller should repair
// rather than quietly render a space with a hole in it.
//
// # Movement is two arrays, not a list of pairs
//
// The obvious encoding of `moved` is a repeated record of (handle, pose). That
// spends a key and a length on every entity of every tick, and scatters the
// poses through the buffer so that nothing can read them in bulk.
//
// Instead the handles and the poses are two parallel fixed-layout arrays, index
// aligned. The poses are then 32N contiguous bytes of little-endian float, which
// is exactly the layout a renderer wants, and ``FixedArray`` hands them over
// without decoding them. Nothing is allocated per entity, and a viewer drawing
// thirty of a hundred entities reads thirty poses.
//
// The two arrays must be the same length. A buffer where they are not is
// malformed and is rejected as such — that check is the price of the layout, and
// it is one comparison per tick.

import Foundation
import MoqomCore

// MARK: - Field numbers

// Tags 1 through 15 encode their key in a single byte; above that costs two. The
// hot fields are numbered accordingly, and the numbers are permanent — changing
// one is a format break, which is what `version` is for.

private enum UpdateTag {
    static let version: UInt32 = 1
    static let epoch: UInt32 = 2
    static let step: UInt32 = 3
    static let nanoseconds: UInt32 = 4
    static let uncertainty: UInt32 = 5
    static let trust: UInt32 = 6
    static let snapshot: UInt32 = 7
    static let delta: UInt32 = 8
}

private enum DeltaTag {
    static let movedHandles: UInt32 = 1
    static let movedPoses: UInt32 = 2
    static let removed: UInt32 = 3
    static let spawned: UInt32 = 4
    static let claimed: UInt32 = 5
    static let facts: UInt32 = 6
    static let entityFacts: UInt32 = 7
    static let forgotten: UInt32 = 8
}

private enum SnapshotTag {
    static let entity: UInt32 = 1
    static let fact: UInt32 = 2
    static let authority: UInt32 = 3
}

private enum EntityTag {
    static let handle: UInt32 = 1
    static let id: UInt32 = 2
    static let kind: UInt32 = 3
    static let pose: UInt32 = 4
    static let owner: UInt32 = 5
    static let fact: UInt32 = 6
}

/// Which tag carries the value tells the reader its type, so no discriminator is
/// written. A fact is a key and exactly one of four value fields.
private enum FactTag {
    static let key: UInt32 = 1
    static let flag: UInt32 = 2
    static let number: UInt32 = 3
    static let decimal: UInt32 = 4
    static let text: UInt32 = 5
}

private enum ClaimTag {
    static let handle: UInt32 = 1
    static let owner: UInt32 = 2
}

private enum EntityFactsTag {
    static let handle: UInt32 = 1
    static let fact: UInt32 = 2
}

private enum IdentityTag {
    static let username: UInt32 = 1
    static let device: UInt32 = 2
}

/// Position, rotation, scale: eight little-endian floats.
private let poseStride = 32

/// A handle is four little-endian bytes.
private let handleStride = 4

// MARK: - Geometry

private extension RecordWriter {
    mutating func rawPose(_ pose: SpacePose) {
        rawFloat(pose.position.x)
        rawFloat(pose.position.y)
        rawFloat(pose.position.z)
        rawFloat(pose.rotation.x)
        rawFloat(pose.rotation.y)
        rawFloat(pose.rotation.z)
        rawFloat(pose.rotation.w)
        rawFloat(pose.scale)
    }

    /// A single pose, as a fixed-size payload rather than a nested record.
    ///
    /// A record would spend a key per component to describe a shape that never
    /// varies. Entities carry one of these each, and a snapshot carries every
    /// entity there is.
    mutating func pose(_ tag: UInt32, _ pose: SpacePose) {
        fixedArray(tag, stride: poseStride, count: 1) { _, buffer in
            buffer.rawPose(pose)
        }
    }
}

private extension FixedArray {
    /// Read element `index` as a pose.
    ///
    /// Normalises the rotation on the way out, because this is a wire type and
    /// nothing stops a peer sending a drifted or zeroed quaternion — which would
    /// otherwise silently scale every transform it touches.
    func pose(_ index: Int) -> SpacePose {
        // One entry into the buffer for all eight floats. Reading them a field
        // at a time is eight, and at fifty entities a tick that is four hundred,
        // which measurably undoes the reason the poses are contiguous.
        withElement(index) { raw in
            func float(_ offset: Int) -> Float {
                Float(bitPattern: UInt32(
                    littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                ))
            }
            return SpacePose(
                position: SpaceVector(x: float(0), y: float(4), z: float(8)),
                rotation: SpaceRotation(
                    x: float(12),
                    y: float(16),
                    z: float(20),
                    w: float(24)
                ),
                scale: float(28)
            )
        }
    }
}

private extension RecordReader {
    mutating func pose() throws(WireError) -> SpacePose {
        let array = try fixedArray(stride: poseStride)
        guard array.count == 1 else {
            throw WireError.invalid("a pose field holding \(array.count) poses")
        }
        return array.pose(0)
    }
}

// MARK: - Leaf records

private extension RecordWriter {
    mutating func identity(_ tag: UInt32, _ who: ParticipantIdentity) {
        record(tag) { inner in
            inner.string(IdentityTag.username, who.username.description)
            inner.string(IdentityTag.device, who.device.description)
        }
    }

    mutating func fact(_ tag: UInt32, key: String, value: SpaceValue) {
        record(tag) { inner in
            inner.string(FactTag.key, key)
            switch value {
            case let .flag(flag):
                // Written even when false. Which field is present is what says
                // what type the value is, so an omitted `false` would not read
                // as `false` — it would read as a fact with no value at all.
                inner.boolean(FactTag.flag, flag)
            case let .number(number): inner.fixed64(FactTag.number, number)
            case let .decimal(decimal): inner.double(FactTag.decimal, decimal)
            case let .text(text): inner.string(FactTag.text, text)
            }
        }
    }

    /// Facts in a stable order, so that encoding the same state twice gives the
    /// same bytes. Dictionaries do not promise an order, and a track whose bytes
    /// change without its meaning changing is one that cannot be diffed, cached
    /// by content, or compared in a test.
    mutating func facts(_ tag: UInt32, _ facts: [String: SpaceValue]) {
        for key in facts.keys.sorted() {
            fact(tag, key: key, value: facts[key]!)
        }
    }
}

private extension RecordReader {
    mutating func identity() throws(WireError) -> ParticipantIdentity {
        var inner = try record()
        var username: String?
        var device: String?
        while let key = try inner.nextKey() {
            switch key.tag {
            case IdentityTag.username: username = try inner.string()
            case IdentityTag.device: device = try inner.string()
            default: try inner.skip(key)
            }
        }
        guard let username, let device else {
            throw WireError.invalid("an identity missing its username or device")
        }
        do {
            return ParticipantIdentity(
                username: try Username(username),
                device: try DeviceID(device)
            )
        } catch {
            throw WireError.invalid("unusable identity: \(error)")
        }
    }

    mutating func fact() throws(WireError) -> (key: String, value: SpaceValue) {
        var inner = try record()
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

// MARK: - Interning

/// The mapping between entity names and the numbers that stand for them.
///
/// Held by an encoder and, separately, by a decoder. A snapshot replaces it; a
/// spawn extends it. Handles are never reused within an epoch, so a delta that
/// arrives after the entity it names has gone resolves to nothing rather than to
/// the wrong thing.
private struct HandleTable {
    private var byID: [SpaceEntityID: UInt32] = [:]
    private var byHandle: [UInt32: SpaceEntityID] = [:]
    private var next: UInt32 = 0

    mutating func reset() {
        byID.removeAll(keepingCapacity: true)
        byHandle.removeAll(keepingCapacity: true)
        next = 0
    }

    /// Allocate the next handle for a name, or return the one it already has.
    mutating func intern(_ id: SpaceEntityID) -> UInt32 {
        if let existing = byID[id] { return existing }
        let handle = next
        next += 1
        byID[id] = handle
        byHandle[handle] = id
        return handle
    }

    /// Record a name at a handle the peer chose.
    mutating func adopt(_ id: SpaceEntityID, at handle: UInt32) {
        byID[id] = handle
        byHandle[handle] = id
        next = max(next, handle + 1)
    }

    func handle(for id: SpaceEntityID) -> UInt32? { byID[id] }

    func name(of handle: UInt32) throws(WireError) -> SpaceEntityID {
        guard let id = byHandle[handle] else {
            throw WireError.invalid(
                "entity handle \(handle) was never introduced; a snapshot was missed"
            )
        }
        return id
    }
}

// MARK: - Encoding

/// Writes a shared space's updates, interning entity names as it goes.
///
/// One per publication. The handle table it accumulates is the reason this is a
/// type rather than a function: the encoding of a delta depends on every
/// snapshot and spawn before it.
public struct SpaceEncoder: Sendable {
    private var handles = HandleTable()

    public init() {}

    /// Discard the handle table.
    ///
    /// Needed when a publication restarts and the peer will not have seen what
    /// came before. Encoding a snapshot does this implicitly.
    public mutating func reset() {
        handles.reset()
    }

    public mutating func encode(_ update: SpaceUpdate) throws -> Data {
        var writer = RecordWriter(capacity: 128)
        writer.varInt(UpdateTag.version, UInt64(update.version))
        writer.varInt(UpdateTag.epoch, UInt64(update.tick.epoch))
        writer.varInt(UpdateTag.step, update.tick.step)
        writer.fixed64(UpdateTag.nanoseconds, update.at.nanoseconds)
        writer.varInt(
            UpdateTag.uncertainty,
            UInt64(max(0, update.at.uncertainty.wholeNanoseconds))
        )
        writer.varInt(UpdateTag.trust, UInt64(update.at.trust.wireCode))

        switch update.body {
        case let .snapshot(snapshot):
            let body = encodeSnapshot(snapshot)
            writer.bytes(UpdateTag.snapshot, body)
        case let .delta(delta):
            let body = try encodeDelta(delta)
            writer.bytes(UpdateTag.delta, body)
        }
        return writer.bytes
    }

    private mutating func encodeSnapshot(_ snapshot: SpaceSnapshot) -> Data {
        // A snapshot is the whole truth, so it renumbers from scratch. Keeping
        // the old numbering would mean a joiner and an incumbent disagree about
        // what handle 3 is, which is the one failure this scheme must not have.
        handles.reset()

        var writer = RecordWriter(capacity: 64 * snapshot.entities.count)
        for id in snapshot.entities.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            let entity = snapshot.entities[id]!
            let handle = handles.intern(id)
            writer.bytes(SnapshotTag.entity, encodeEntity(entity, handle: handle))
        }
        writer.facts(SnapshotTag.fact, snapshot.facts)
        if let authority = snapshot.authority {
            writer.identity(SnapshotTag.authority, authority)
        }
        return writer.bytes
    }

    private func encodeEntity(_ entity: SpaceEntity, handle: UInt32) -> Data {
        var writer = RecordWriter(capacity: 64)
        writer.varInt(EntityTag.handle, UInt64(handle))
        writer.string(EntityTag.id, entity.id.rawValue)
        writer.string(EntityTag.kind, entity.kind)
        if entity.pose != .identity { writer.pose(EntityTag.pose, entity.pose) }
        if let owner = entity.owner { writer.identity(EntityTag.owner, owner) }
        writer.facts(EntityTag.fact, entity.facts)
        return writer.bytes
    }

    private mutating func encodeDelta(_ delta: SpaceDelta) throws -> Data {
        var writer = RecordWriter(capacity: 64 + 36 * delta.moved.count)

        // Spawns come first so that a delta can create a thing and move it in
        // the same tick: the handle has to exist before anything references it.
        for entity in delta.spawned {
            let handle = handles.intern(entity.id)
            writer.bytes(DeltaTag.spawned, encodeEntity(entity, handle: handle))
        }

        let moved = try delta.moved
            .map { (handle: try resolve($0.key), pose: $0.value) }
            .sorted { $0.handle < $1.handle }
        if !moved.isEmpty {
            writer.fixedArray(
                DeltaTag.movedHandles,
                stride: handleStride,
                count: moved.count
            ) { index, buffer in
                buffer.rawUInt32(moved[index].handle)
            }
            writer.fixedArray(
                DeltaTag.movedPoses,
                stride: poseStride,
                count: moved.count
            ) { index, buffer in
                buffer.rawPose(moved[index].pose)
            }
        }

        let removed = try delta.removed.map { try resolve($0) }.sorted()
        if !removed.isEmpty {
            writer.fixedArray(
                DeltaTag.removed,
                stride: handleStride,
                count: removed.count
            ) { index, buffer in
                buffer.rawUInt32(removed[index])
            }
        }

        for (id, owner) in try delta.claimed
            .map({ (handle: try resolve($0.key), owner: $0.value) })
            .sorted(by: { $0.handle < $1.handle })
        {
            writer.record(DeltaTag.claimed) { inner in
                inner.varInt(ClaimTag.handle, UInt64(id))
                // An absent owner is a release. Three states, two encodings, and
                // the third — "unchanged" — is the claim not being here at all.
                if let owner { inner.identity(ClaimTag.owner, owner) }
            }
        }

        writer.facts(DeltaTag.facts, delta.facts)

        // Keys rather than a key and an empty value, because "no longer present"
        // is not one of the four things a ``SpaceValue`` can be.
        for key in delta.forgotten.sorted() {
            writer.string(DeltaTag.forgotten, key)
        }

        for (id, facts) in try delta.entityFacts
            .map({ (handle: try resolve($0.key), facts: $0.value) })
            .sorted(by: { $0.handle < $1.handle })
        {
            var inner = RecordWriter(capacity: 32)
            inner.varInt(EntityFactsTag.handle, UInt64(id))
            inner.facts(EntityFactsTag.fact, facts)
            writer.bytes(DeltaTag.entityFacts, inner.bytes)
        }

        return writer.bytes
    }

    /// The handle for a name that must already have one.
    ///
    /// Failing here means the authority is moving something it never spawned or
    /// snapshotted, which is a bug in the simulation rather than in the wire
    /// format — and one that would otherwise reach subscribers as a delta they
    /// cannot apply.
    private func resolve(_ id: SpaceEntityID) throws -> UInt32 {
        guard let handle = handles.handle(for: id) else {
            throw MoqomError.invalidState(
                expected: "entity \(id) introduced by a snapshot or a spawn",
                actual: "a delta referring to it first"
            )
        }
        return handle
    }
}

// MARK: - Reading a tick without unpacking it

/// A tick, located but not unpacked.
///
/// ``SpaceDecoder/decode(_:)`` returns a ``SpaceUpdate``, which is the pleasant
/// thing to hold: named entities, Swift dictionaries, value semantics. Building
/// it costs a dictionary insertion and a string hash per moved entity, and at
/// sixty ticks a second that is most of what decoding costs — enough to undo
/// the reason this format exists.
///
/// This is the other path. The poses stay in the received buffer and are read
/// out by index, so walking a tick allocates nothing at all. Entities are
/// identified by handle rather than by name, which is the part that makes it
/// free: a renderer holding its nodes in a handle-keyed array does no hashing
/// and no string work per frame. ``SpaceDecoder/name(of:)`` is there for the
/// cases that do need a name.
///
/// ```swift
/// let tick = try decoder.view(bytes)
/// for index in 0 ..< tick.moveCount {
///     let move = tick.move(index)
///     nodes[move.handle]?.transform = move.pose
/// }
/// ```
///
/// Snapshots and spawns are not on this path and do not need to be: they are
/// rare, they carry names by definition, and ``SpaceDecoder/view(_:)`` folds
/// them into the handle table for you before returning.
public struct SpaceTickView: Sendable {
    public let version: Int
    public let tick: SpaceTick
    public let at: Timecode

    /// The full update, when the object was a snapshot or carried anything
    /// beyond movement. `nil` for a plain movement tick, which is the case this
    /// type exists to keep cheap.
    public let rest: SpaceUpdate?

    private let handles: FixedArray?
    private let poses: FixedArray?

    init(
        version: Int,
        tick: SpaceTick,
        at: Timecode,
        rest: SpaceUpdate?,
        handles: FixedArray?,
        poses: FixedArray?
    ) {
        self.version = version
        self.tick = tick
        self.at = at
        self.rest = rest
        self.handles = handles
        self.poses = poses
    }

    /// How many entities moved.
    public var moveCount: Int { handles?.count ?? 0 }

    /// One entity's new pose, read out of the received bytes.
    public func move(_ index: Int) -> (handle: UInt32, pose: SpacePose) {
        guard let handles, let poses else {
            preconditionFailure("move(\(index)) on a tick with no movement")
        }
        return (handles.uint32(index, at: 0), poses.pose(index))
    }

    /// The poses as raw memory, for a consumer that wants to hand the whole run
    /// to something else — a Metal buffer, say — rather than walk it.
    ///
    /// Eight little-endian floats per entity: position, then rotation as
    /// `(x, y, z, w)`, then a uniform scale.
    public func withUnsafePoses<T>(_ body: (UnsafeRawBufferPointer) throws -> T) rethrows -> T? {
        try poses?.withUnsafeBytes(body)
    }
}

// MARK: - Decoding

/// Reads a shared space's updates, resolving handles back to names.
///
/// One per subscription, and it must see the same sequence of objects the
/// encoder produced. That is what a MOQT track delivers within a group, and a
/// group always opens with a snapshot, so a subscriber that starts at a group
/// boundary always has the table before anything needs it.
public struct SpaceDecoder: Sendable {
    private var handles = HandleTable()

    public init() {}

    public mutating func reset() {
        handles.reset()
    }

    /// The name an entity handle stands for.
    ///
    /// Needed by anything that walks a ``SpaceTickView``, which deals in handles
    /// so that it can avoid strings entirely on the frames where it does not
    /// need one.
    public func name(of handle: UInt32) throws -> SpaceEntityID {
        try handles.name(of: handle)
    }

    /// Read a tick without unpacking its movement.
    ///
    /// The fast path, and the one a renderer should be on. Everything rare — a
    /// snapshot, a spawn, a claim — is decoded as usual and lands in
    /// ``SpaceTickView/rest``; the poses stay where they arrived. See
    /// ``SpaceTickView``.
    public mutating func view(_ data: Data) throws -> SpaceTickView {
        let header = try readHeader(data)

        if let snapshot = header.snapshot {
            let update = SpaceUpdate(
                tick: header.tick,
                at: header.at,
                body: .snapshot(try decodeSnapshot(snapshot)),
                version: header.version
            )
            return SpaceTickView(
                version: header.version,
                tick: header.tick,
                at: header.at,
                rest: update,
                handles: nil,
                poses: nil
            )
        }

        guard let body = header.delta else {
            throw WireError.invalid("a space update with neither a snapshot nor a delta")
        }
        let scanned = try scanDelta(body)
        try check(scanned.handles, against: scanned.poses)

        // Only build an update when there is something in it beyond movement.
        // On an ordinary tick there is not, and skipping it is the difference
        // this type exists to make.
        let rest: SpaceUpdate? = scanned.delta.isEmpty ? nil : SpaceUpdate(
            tick: header.tick,
            at: header.at,
            body: .delta(scanned.delta),
            version: header.version
        )
        return SpaceTickView(
            version: header.version,
            tick: header.tick,
            at: header.at,
            rest: rest,
            handles: scanned.handles,
            poses: scanned.poses
        )
    }

    public mutating func decode(_ data: Data) throws -> SpaceUpdate {
        let header = try readHeader(data)

        let body: SpaceUpdate.Body
        if let snapshot = header.snapshot {
            body = .snapshot(try decodeSnapshot(snapshot))
        } else if let delta = header.delta {
            var scanned = try scanDelta(delta)
            try check(scanned.handles, against: scanned.poses)
            if let names = scanned.handles, let poses = scanned.poses {
                scanned.delta.moved.reserveCapacity(names.count)
                for index in 0 ..< names.count {
                    let id = try handles.name(of: names.uint32(index, at: 0))
                    scanned.delta.moved[id] = poses.pose(index)
                }
            }
            body = .delta(scanned.delta)
        } else {
            throw WireError.invalid("a space update with neither a snapshot nor a delta")
        }

        return SpaceUpdate(
            tick: header.tick,
            at: header.at,
            body: body,
            version: header.version
        )
    }

    /// Everything outside the body, plus the body's bytes.
    private struct Header {
        var version = 0
        var tick = SpaceTick.zero
        var at = Timecode.fallback()
        var snapshot: Data?
        var delta: Data?
    }

    private func readHeader(_ data: Data) throws -> Header {
        var reader = RecordReader(data)
        var header = Header()
        var epoch: UInt32 = 0
        var step: UInt64 = 0
        var nanoseconds: Int64 = 0
        var uncertainty = Duration.zero
        var trust = TimeTrust.fallback

        while let key = try reader.nextKey() {
            switch key.tag {
            case UpdateTag.version:
                header.version = Int(try reader.varInt())
            case UpdateTag.epoch:
                guard let value = UInt32(exactly: try reader.varInt()) else {
                    throw WireError.invalid("epoch beyond 32 bits")
                }
                epoch = value
            case UpdateTag.step:
                step = try reader.varInt()
            case UpdateTag.nanoseconds:
                nanoseconds = try reader.fixed64()
            case UpdateTag.uncertainty:
                uncertainty = .nanoseconds(try reader.varInt())
            case UpdateTag.trust:
                trust = TimeTrust(wireCode: UInt8(truncatingIfNeeded: try reader.varInt()))
            case UpdateTag.snapshot:
                header.snapshot = try reader.bytes()
            case UpdateTag.delta:
                header.delta = try reader.bytes()
            default:
                try reader.skip(key)
            }
        }

        guard header.version <= SpaceUpdate.currentVersion else {
            throw WireError.invalid(
                "space update version \(header.version), which this build cannot read"
            )
        }
        header.tick = SpaceTick(epoch: epoch, step: step)
        header.at = Timecode(
            nanoseconds: nanoseconds,
            uncertainty: uncertainty,
            trust: trust
        )
        return header
    }

    /// The one check the parallel-array layout costs.
    ///
    /// One comparison per tick, and without it a peer could send ten handles and
    /// one pose and walk a reader off the end of the pose array.
    private func check(_ handles: FixedArray?, against poses: FixedArray?) throws {
        switch (handles, poses) {
        case let (names?, poses?):
            guard names.count == poses.count else {
                throw WireError.invalid(
                    "\(names.count) moved handles against \(poses.count) poses"
                )
            }
        case (nil, nil):
            break
        default:
            throw WireError.invalid("moved handles without poses, or the reverse")
        }
    }

    private mutating func decodeSnapshot(_ data: Data) throws -> SpaceSnapshot {
        handles.reset()

        var reader = RecordReader(data)
        var snapshot = SpaceSnapshot()
        while let key = try reader.nextKey() {
            switch key.tag {
            case SnapshotTag.entity:
                let entity = try decodeEntity(try reader.bytes())
                snapshot.entities[entity.id] = entity
            case SnapshotTag.fact:
                let fact = try reader.fact()
                snapshot.facts[fact.key] = fact.value
            case SnapshotTag.authority:
                snapshot.authority = try reader.identity()
            default:
                try reader.skip(key)
            }
        }
        return snapshot
    }

    private mutating func decodeEntity(_ data: Data) throws -> SpaceEntity {
        var reader = RecordReader(data)
        var handle: UInt32?
        var id: SpaceEntityID?
        var kind: String?
        var pose = SpacePose.identity
        var owner: ParticipantIdentity?
        var facts: [String: SpaceValue] = [:]

        while let key = try reader.nextKey() {
            switch key.tag {
            case EntityTag.handle:
                handle = UInt32(exactly: try reader.varInt())
            case EntityTag.id:
                id = SpaceEntityID(try reader.string())
            case EntityTag.kind:
                kind = try reader.string()
            case EntityTag.pose:
                pose = try reader.pose()
            case EntityTag.owner:
                owner = try reader.identity()
            case EntityTag.fact:
                let fact = try reader.fact()
                facts[fact.key] = fact.value
            default:
                try reader.skip(key)
            }
        }

        guard let handle, let id, let kind else {
            throw WireError.invalid("an entity missing its handle, name, or kind")
        }
        handles.adopt(id, at: handle)
        return SpaceEntity(id: id, kind: kind, pose: pose, owner: owner, facts: facts)
    }

    /// Everything in a delta except the movement, which is left where it lies.
    ///
    /// Splitting the two is what lets ``view(_:)`` skip the only expensive part
    /// of decoding — a dictionary insertion and a string hash per moved entity —
    /// while still handling the rare fields properly.
    private mutating func scanDelta(
        _ data: Data
    ) throws -> (delta: SpaceDelta, handles: FixedArray?, poses: FixedArray?) {
        var reader = RecordReader(data)
        var delta = SpaceDelta()
        var movedHandles: FixedArray?
        var movedPoses: FixedArray?

        while let key = try reader.nextKey() {
            switch key.tag {
            case DeltaTag.spawned:
                // Decoded as it is read rather than collected, because a spawn
                // introduces a handle that a later field of this same delta may
                // use, and the encoder wrote spawns first for that reason.
                delta.spawned.append(try decodeEntity(try reader.bytes()))
            case DeltaTag.movedHandles:
                movedHandles = try reader.fixedArray(stride: handleStride)
            case DeltaTag.movedPoses:
                movedPoses = try reader.fixedArray(stride: poseStride)
            case DeltaTag.removed:
                let removed = try reader.fixedArray(stride: handleStride)
                for index in 0 ..< removed.count {
                    delta.removed.append(try handles.name(of: removed.uint32(index, at: 0)))
                }
            case DeltaTag.claimed:
                let claim = try decodeClaim(try reader.bytes())
                delta.claimed[claim.id] = claim.owner
            case DeltaTag.facts:
                let fact = try reader.fact()
                delta.facts[fact.key] = fact.value
            case DeltaTag.forgotten:
                delta.forgotten.append(try reader.string())
            case DeltaTag.entityFacts:
                let entry = try decodeEntityFacts(try reader.bytes())
                delta.entityFacts[entry.id] = entry.facts
            default:
                try reader.skip(key)
            }
        }

        return (delta, movedHandles, movedPoses)
    }

    private func decodeClaim(
        _ data: Data
    ) throws -> (id: SpaceEntityID, owner: ParticipantIdentity?) {
        var reader = RecordReader(data)
        var handle: UInt32?
        var owner: ParticipantIdentity?
        while let key = try reader.nextKey() {
            switch key.tag {
            case ClaimTag.handle: handle = UInt32(exactly: try reader.varInt())
            case ClaimTag.owner: owner = try reader.identity()
            default: try reader.skip(key)
            }
        }
        guard let handle else { throw WireError.invalid("a claim with no entity") }
        return (try handles.name(of: handle), owner)
    }

    private func decodeEntityFacts(
        _ data: Data
    ) throws -> (id: SpaceEntityID, facts: [String: SpaceValue]) {
        var reader = RecordReader(data)
        var handle: UInt32?
        var facts: [String: SpaceValue] = [:]
        while let key = try reader.nextKey() {
            switch key.tag {
            case EntityFactsTag.handle: handle = UInt32(exactly: try reader.varInt())
            case EntityFactsTag.fact:
                let fact = try reader.fact()
                facts[fact.key] = fact.value
            default: try reader.skip(key)
            }
        }
        guard let handle else { throw WireError.invalid("entity facts with no entity") }
        return (try handles.name(of: handle), facts)
    }
}
