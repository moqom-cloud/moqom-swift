// The geometry that crosses the wire in a shared space.
//
// Deliberately its own value types rather than `simd_float3` and friends. Three
// reasons, in order of how much trouble they save.
//
// **These are wire types.** They are encoded, relayed, cached, and decoded by a
// web client and an Android client that have never heard of `simd`. Pinning the
// representation here — rather than inheriting whatever Apple's layout happens
// to be — is what makes the other implementations possible to write against.
//
// **`simd` is Darwin-only.** `MoqomCore` is the layer the other modules build
// on, and tying it to a framework that does not exist off Apple platforms would
// make a port a rewrite. The bridging lives at the bottom of this file behind
// `canImport`, so a caller on iOS still gets `SIMD3<Float>` for free.
//
// **A quaternion that is not a unit quaternion silently scales geometry.** A raw
// four-float struct invites one; ``SpaceRotation`` normalises on the way in, so
// a value that exists is a rotation.
//
// # Conventions, stated once
//
// Metres, right-handed, **+Y up**, **−Z forward**, matching ARKit and RealityKit
// so that no conversion is needed on the platform most likely to be rendering
// this. Rotations are unit quaternions in `(x, y, z, w)` order — the order the
// wire uses, chosen because it is what `simd_quatf.vector` gives and what WebXR
// and glTF both use. Note that `simd_quatf`'s *initialiser* takes `w` first,
// which is exactly the sort of trap worth naming.
//
// Everything here is in **space coordinates**: the shared, synthetic frame that
// every participant agrees on. Where that frame sits in any particular person's
// living room is a private matter and is not represented in this file. See
// ``SpaceAnchor``.

import Foundation

/// A point or displacement in space coordinates, in metres.
public struct SpaceVector: Hashable, Sendable {
    public var x: Float
    public var y: Float
    public var z: Float

    public init(x: Float, y: Float, z: Float) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static let zero = SpaceVector(x: 0, y: 0, z: 0)

    /// Straight-line distance to another point, in metres.
    public func distance(to other: SpaceVector) -> Float {
        let dx = other.x - x
        let dy = other.y - y
        let dz = other.z - z
        return (dx * dx + dy * dy + dz * dz).squareRoot()
    }

    /// Straight-line travel between two points.
    ///
    /// Used to fill the gap between two received states, so it is deliberately
    /// unclamped: an `amount` past 1 extrapolates, which is what a renderer
    /// wants when the next state has not arrived yet and the alternative is
    /// freezing.
    public static func interpolated(
        from start: SpaceVector,
        to end: SpaceVector,
        amount: Float
    ) -> SpaceVector {
        SpaceVector(
            x: start.x + (end.x - start.x) * amount,
            y: start.y + (end.y - start.y) * amount,
            z: start.z + (end.z - start.z) * amount
        )
    }
}

/// An orientation in space coordinates, as a unit quaternion.
public struct SpaceRotation: Hashable, Sendable {
    public let x: Float
    public let y: Float
    public let z: Float
    public let w: Float

    /// Builds a rotation, normalising the components.
    ///
    /// Immutable stored properties and a normalising initialiser, together, are
    /// what make the unit-length invariant hold: there is no way to reach a
    /// value that scales the thing it rotates. A degenerate input — all zeros,
    /// or a NaN arriving from a decoder — becomes the identity rather than
    /// poisoning every transform it touches.
    public init(x: Float, y: Float, z: Float, w: Float) {
        let length = (x * x + y * y + z * z + w * w).squareRoot()
        guard length.isFinite, length > 1e-6 else {
            self.x = 0
            self.y = 0
            self.z = 0
            self.w = 1
            return
        }
        self.x = x / length
        self.y = y / length
        self.z = z / length
        self.w = w / length
    }

    public static let identity = SpaceRotation(x: 0, y: 0, z: 0, w: 1)

    /// A rotation about an axis, in radians.
    public init(angle: Float, axis: SpaceVector) {
        let length = (axis.x * axis.x + axis.y * axis.y + axis.z * axis.z).squareRoot()
        guard length.isFinite, length > 1e-6 else {
            self = .identity
            return
        }
        let half = angle / 2
        let scale = sin(half) / length
        self.init(x: axis.x * scale, y: axis.y * scale, z: axis.z * scale, w: cos(half))
    }

    /// Rotation about the up axis, which is the one a tabletop game mostly uses.
    public static func yaw(_ radians: Float) -> SpaceRotation {
        SpaceRotation(angle: radians, axis: SpaceVector(x: 0, y: 1, z: 0))
    }

    /// The shortest rotation between two orientations.
    ///
    /// Spherical interpolation, with two corrections that matter in practice.
    ///
    /// A quaternion and its negation are the same orientation but opposite ways
    /// round the sphere, so the sign is flipped when the inputs point apart —
    /// without it, a piece rotating through a half turn takes the long way and
    /// visibly spins backwards.
    ///
    /// And when the two are nearly identical the spherical formula divides by a
    /// sine approaching zero, so it falls back to straight interpolation, which
    /// is indistinguishable at that separation and does not produce infinities.
    public static func interpolated(
        from start: SpaceRotation,
        to end: SpaceRotation,
        amount: Float
    ) -> SpaceRotation {
        var dot = start.x * end.x + start.y * end.y + start.z * end.z + start.w * end.w
        var target = end
        if dot < 0 {
            target = SpaceRotation(unchecked: -end.x, -end.y, -end.z, -end.w)
            dot = -dot
        }

        guard dot < 0.9995 else {
            return SpaceRotation(
                x: start.x + (target.x - start.x) * amount,
                y: start.y + (target.y - start.y) * amount,
                z: start.z + (target.z - start.z) * amount,
                w: start.w + (target.w - start.w) * amount
            )
        }

        let theta = acos(min(max(dot, -1), 1))
        let sinTheta = sin(theta)
        let fromScale = sin((1 - amount) * theta) / sinTheta
        let toScale = sin(amount * theta) / sinTheta
        return SpaceRotation(
            x: start.x * fromScale + target.x * toScale,
            y: start.y * fromScale + target.y * toScale,
            z: start.z * fromScale + target.z * toScale,
            w: start.w * fromScale + target.w * toScale
        )
    }

    /// Skips normalisation, for values already known to be unit length.
    ///
    /// Only used to negate a quaternion, which cannot change its length.
    private init(unchecked x: Float, _ y: Float, _ z: Float, _ w: Float) {
        self.x = x
        self.y = y
        self.z = z
        self.w = w
    }
}

/// Where something is in space coordinates, and how big.
public struct SpacePose: Hashable, Sendable {
    public var position: SpaceVector
    public var rotation: SpaceRotation

    /// Uniform scale.
    ///
    /// Uniform rather than per-axis on purpose. Non-uniform scale is rare in the
    /// things a shared game replicates, it triples the cost of the field on
    /// every object of every tick, and it introduces shear under composition,
    /// which is a class of bug nobody wants to debug over a network.
    public var scale: Float

    public init(
        position: SpaceVector = .zero,
        rotation: SpaceRotation = .identity,
        scale: Float = 1
    ) {
        self.position = position
        self.rotation = rotation
        self.scale = scale.isFinite && scale > 0 ? scale : 1
    }

    public static let identity = SpacePose()

    /// The pose between two, for rendering a moment that was never transmitted.
    public static func interpolated(
        from start: SpacePose,
        to end: SpacePose,
        amount: Float
    ) -> SpacePose {
        SpacePose(
            position: .interpolated(from: start.position, to: end.position, amount: amount),
            rotation: .interpolated(from: start.rotation, to: end.rotation, amount: amount),
            scale: start.scale + (end.scale - start.scale) * amount
        )
    }
}

// MARK: - Wire format

// Fixed-length arrays rather than keyed objects: `[0.5,0,-1.2]` against
// `{"x":0.5,"y":0,"z":-1.2}` is a third of the bytes, and a pose is the field
// that repeats for every entity on every tick, so it is the one place in this
// design where the encoding is worth choosing deliberately. Still JSON, and
// still readable in a packet capture, which is worth more than the remaining
// bytes until there is a profile saying otherwise.

extension SpaceVector: Codable {
    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        x = try container.decode(Float.self)
        y = try container.decode(Float.self)
        z = try container.decode(Float.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(x)
        try container.encode(y)
        try container.encode(z)
    }
}

extension SpaceRotation: Codable {
    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let x = try container.decode(Float.self)
        let y = try container.decode(Float.self)
        let z = try container.decode(Float.self)
        let w = try container.decode(Float.self)
        // Through the normalising initialiser on purpose. A peer that sends a
        // drifted quaternion — or a hostile one that sends zeros — gets it
        // corrected here rather than scaling everything downstream.
        self.init(x: x, y: y, z: z, w: w)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(x)
        try container.encode(y)
        try container.encode(z)
        try container.encode(w)
    }
}

extension SpacePose: Codable {
    private enum CodingKeys: String, CodingKey {
        case position = "p"
        case rotation = "r"
        case scale = "s"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Each field is optional and defaulted, so a still object costs three
        // bytes rather than forty. Most entities in most ticks are not scaled
        // and not rotated.
        self.init(
            position: try container.decodeIfPresent(SpaceVector.self, forKey: .position) ?? .zero,
            rotation: try container.decodeIfPresent(SpaceRotation.self, forKey: .rotation) ?? .identity,
            scale: try container.decodeIfPresent(Float.self, forKey: .scale) ?? 1
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if position != .zero { try container.encode(position, forKey: .position) }
        if rotation != .identity { try container.encode(rotation, forKey: .rotation) }
        if scale != 1 { try container.encode(scale, forKey: .scale) }
    }
}

// MARK: - simd

#if canImport(simd)
    import simd

    public extension SpaceVector {
        init(_ value: SIMD3<Float>) {
            self.init(x: value.x, y: value.y, z: value.z)
        }

        var simd: SIMD3<Float> { SIMD3(x, y, z) }
    }

    public extension SpaceRotation {
        init(_ value: simd_quatf) {
            let vector = value.vector
            self.init(x: vector.x, y: vector.y, z: vector.z, w: vector.w)
        }

        /// Note the argument order: `simd_quatf` takes the real part first,
        /// while the wire — and every other API in this file — puts it last.
        var simd: simd_quatf { simd_quatf(ix: x, iy: y, iz: z, r: w) }
    }

    public extension SpacePose {
        /// The pose as a transform, for handing to a renderer.
        ///
        /// Scale, then rotate, then translate, which is the order that keeps a
        /// uniformly scaled child from shearing when its parent is rotated.
        var matrix: simd_float4x4 {
            var transform = simd_float4x4(rotation.simd)
            transform.columns.0 *= scale
            transform.columns.1 *= scale
            transform.columns.2 *= scale
            transform.columns.3 = SIMD4(position.x, position.y, position.z, 1)
            return transform
        }
    }
#endif
