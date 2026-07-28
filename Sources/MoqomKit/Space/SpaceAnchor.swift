// Where the shared space sits in one person's actual room.
//
// This is the file that makes remote shared AR possible, and the idea in it is
// the one most likely to be got wrong, so it is worth stating plainly.
//
// # Why not a shared physical anchor
//
// The obvious way to build shared AR is the way Apple documents: a collaborative
// `ARSession`, world maps exchanged between devices, everyone resolving the same
// physical feature points and agreeing on a real table in a real room. It works
// well and it is completely unavailable to us, because it requires the
// participants to be standing in the same place. A host in Lagos and a guest in
// Seoul have no common feature points, no shared plane, and no physical origin
// to resolve against. Waiting for one is waiting forever.
//
// # The synthetic origin
//
// So the shared frame is invented rather than discovered. Every participant
// agrees on a space whose origin is nowhere in particular: the floor at the
// centre of the play area, +Y up, −Z forward. All replicated geometry is in that
// frame, and it is the only frame that crosses the wire.
//
// Each device then decides, privately and alone, where that frame lands in its
// own world. Ada drops it on her coffee table. Grace puts it on her desk at
// two-thirds scale because her desk is smaller. A viewer on a laptop with no
// camera renders it in a virtual room with an orbit camera. All three see the
// same game, because they agree about space coordinates and disagree only about
// something none of them needs to know about the others.
//
// That is the whole trick, and three good properties fall out of it.
//
// **Viewers need no AR hardware.** A frame that is synthetic can be rendered by
// anything — a headset, a phone held up, a browser, a 2D top-down canvas. Making
// the shared frame physical would have made AR a requirement for watching.
//
// **Nothing about anyone's room is transmitted.** A placement is a private
// transform. The alternative — exchanging world maps or plane geometry — means
// shipping a photogrammetric reconstruction of a user's home to strangers, which
// is a privacy question with no good answer.
//
// **Scale is a local comfort setting.** Someone on a phone at a desk and someone
// in a headset in a living room can play the same game at the sizes their spaces
// allow, because the size of the space in metres of carpet is not a property of
// the game.
//
// # What this file deliberately does not do
//
// It does not detect planes, run an `ARSession`, or place anything. Choosing a
// surface is an application's job and an intensely design-dependent one. This
// supplies the transform and the arithmetic on both sides of it.

import Foundation
import MoqomCore

/// Where a device has put the shared space, in that device's own world.
///
/// Private to the device that holds it. Never encoded, never published, and
/// deliberately not `Codable` so that it cannot become either by accident — the
/// moment a placement crosses the wire, a participant is telling a room where
/// their furniture is.
public struct SpaceAnchor: Hashable, Sendable {
    /// Where the space's origin sits in the device's world coordinates.
    public var origin: SpaceVector

    /// How the space is turned relative to the device's world.
    ///
    /// Usually a yaw: which way the board faces the person looking at it. There
    /// is rarely a reason to tilt a shared space relative to gravity, and it
    /// makes people ill.
    public var rotation: SpaceRotation

    /// Metres of the device's world per metre of space.
    ///
    /// A comfort setting, not a game rule. A board designed at one metre across
    /// can be played at 0.3 on a desk and 2.0 on a floor, and the game does not
    /// know the difference because nothing it replicates is measured in the
    /// user's carpet.
    public var scale: Float

    public init(
        origin: SpaceVector = .zero,
        rotation: SpaceRotation = .identity,
        scale: Float = 1
    ) {
        self.origin = origin
        self.rotation = rotation
        self.scale = scale.isFinite && scale > 0 ? scale : 1
    }

    /// The space placed at the device's world origin, unrotated and unscaled.
    ///
    /// The right anchor for a viewer rendering into a virtual room rather than a
    /// real one, which is most of them.
    public static let identity = SpaceAnchor()

    /// Bring a pose from space coordinates into the device's world.
    ///
    /// The direction used when rendering: everything arriving from the network
    /// is in space coordinates and has to be put somewhere real.
    public func world(from pose: SpacePose) -> SpacePose {
        SpacePose(
            position: world(from: pose.position),
            rotation: compose(rotation, pose.rotation),
            scale: pose.scale * scale
        )
    }

    /// Bring a point from space coordinates into the device's world.
    public func world(from point: SpaceVector) -> SpaceVector {
        let scaled = SpaceVector(x: point.x * scale, y: point.y * scale, z: point.z * scale)
        let turned = rotate(scaled, by: rotation)
        return SpaceVector(
            x: turned.x + origin.x,
            y: turned.y + origin.y,
            z: turned.z + origin.z
        )
    }

    /// Take a pose from the device's world into space coordinates.
    ///
    /// The direction used when acting: a user reaches out and touches something
    /// at a position their own device measured, and what the room needs to hear
    /// is where that is on the shared board.
    public func space(from pose: SpacePose) -> SpacePose {
        SpacePose(
            position: space(from: pose.position),
            rotation: compose(inverse(rotation), pose.rotation),
            scale: pose.scale / scale
        )
    }

    /// Take a point from the device's world into space coordinates.
    public func space(from point: SpaceVector) -> SpaceVector {
        let shifted = SpaceVector(
            x: point.x - origin.x,
            y: point.y - origin.y,
            z: point.z - origin.z
        )
        let turned = rotate(shifted, by: inverse(rotation))
        return SpaceVector(x: turned.x / scale, y: turned.y / scale, z: turned.z / scale)
    }
}

// MARK: - Quaternion arithmetic

// Written out rather than taken from `simd` so that the anchor works wherever
// `MoqomCore` does. These are the only three operations needed and they are
// short; the `simd` bridging on the geometry types is there for callers who want
// to do something more involved.

private func compose(_ left: SpaceRotation, _ right: SpaceRotation) -> SpaceRotation {
    SpaceRotation(
        x: left.w * right.x + left.x * right.w + left.y * right.z - left.z * right.y,
        y: left.w * right.y - left.x * right.z + left.y * right.w + left.z * right.x,
        z: left.w * right.z + left.x * right.y - left.y * right.x + left.z * right.w,
        w: left.w * right.w - left.x * right.x - left.y * right.y - left.z * right.z
    )
}

/// The conjugate, which for a unit quaternion is the inverse.
private func inverse(_ rotation: SpaceRotation) -> SpaceRotation {
    SpaceRotation(x: -rotation.x, y: -rotation.y, z: -rotation.z, w: rotation.w)
}

private func rotate(_ vector: SpaceVector, by rotation: SpaceRotation) -> SpaceVector {
    // v + 2r × (r × v + wv), the standard form that avoids building the full
    // quaternion sandwich.
    let rx = rotation.x, ry = rotation.y, rz = rotation.z, rw = rotation.w
    let tx = 2 * (ry * vector.z - rz * vector.y)
    let ty = 2 * (rz * vector.x - rx * vector.z)
    let tz = 2 * (rx * vector.y - ry * vector.x)
    return SpaceVector(
        x: vector.x + rw * tx + ry * tz - rz * ty,
        y: vector.y + rw * ty + rz * tx - rx * tz,
        z: vector.z + rw * tz + rx * ty - ry * tx
    )
}
