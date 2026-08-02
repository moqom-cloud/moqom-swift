// Drawing somebody else's simulation, and turning a finger into an intent.
//
// This is the whole of the client half of the shared space: a node per bubble,
// moved when an update says so, removed when one says that. It runs identically
// whether this device is the authority or not, which is the property worth
// protecting — a renderer that knew would grow a fast path for the local player
// and a slow one for the remote, and only the second would ever be tested on
// the phone doing the demo.
//
// # Where the shared space lands
//
// The bubbles arrive in space coordinates: an invented room with its floor at
// the origin, in metres that are nobody's actual metres. ``SpaceAnchor`` is
// what turns those into a place in front of this particular phone, and the
// placement is private — never sent, never agreed with anybody. Two people in
// two cities are looking at the same field of bubbles and neither has told the
// other anything about the room they are standing in.
//
// # Guessing at a pop, and not at anything else
//
// A tap removes the bubble immediately, before the authority has been asked.
// That is a guess, and it is a safe one in exactly one direction: the only
// thing that can invalidate it is somebody else having popped the same bubble
// first, in which case it was going away regardless. The reverse guess —
// drawing a bubble this device has decided to spawn — has no such property, and
// is why spawning is not something a follower may do.
//
// The guess is still held to account: if the bubble is still there a second
// later, the intent was lost, and it comes back rather than leaving a hole in a
// field the other player can see.

#if canImport(ARKit) && !targetEnvironment(simulator)
    import Foundation
    import MoqomCore
    import MoqomKit
    import RealityKit
    import UIKit

    /// The bubbles, as RealityKit entities in front of this device.
    @MainActor
    final class BubbleScene {
        /// Where the shared field sits relative to this phone.
        ///
        /// In front of the camera rather than pinned to the room, and the
        /// reason is the session this rides on: the scene runs face tracking so
        /// the person on the call is in shot, and a device tracking a face is
        /// not tracking a world to anchor anything to. It is also the cheaper
        /// answer thermally, on a phone already encoding sixty frames a second.
        ///
        /// The numbers put the field between the phone and whoever is holding
        /// it: half a metre out, dropped below the eye line so bubbles rise
        /// through the shot rather than starting in the middle of somebody's
        /// face.
        static let placement = SpaceAnchor(
            origin: SpaceVector(x: 0, y: -0.30, z: -0.55),
            rotation: .identity,
            scale: 0.5
        )

        /// How long a guessed pop has to be confirmed before it is taken back.
        private static let grace = Duration.seconds(1)

        /// The anchor everything hangs from. Added to the scene by
        /// ``ARSceneSource``, which owns the view.
        let root = AnchorEntity(.camera)

        /// What this device wants the space to do. Set by the model.
        var onPop: (@MainActor (SpaceEntityID) -> Void)?

        private var nodes: [SpaceEntityID: ModelEntity] = [:]

        /// Bubbles removed on this device before anybody agreed.
        private var guessed: [SpaceEntityID: ContinuousClock.Instant] = [:]

        /// Bubbles the field has said are climbing away.
        ///
        /// Still tappable — a bubble on its way out is the one worth hurrying
        /// for — and if it is not tapped, it leaves without a pop.
        private var leaving: Set<SpaceEntityID> = []

        /// How long an update is expected to be the newest one, which is how
        /// long a node is given to travel to where it now is.
        ///
        /// Interpolation rather than teleportation, and not cosmetic: the
        /// authority ticks at twenty a second into a view drawing at sixty, so
        /// without this every bubble moves in three-frame steps — which on a
        /// broadcast of that view is indistinguishable from a stuttering
        /// encoder, and would send anyone debugging it to the wrong place.
        var cadence: TimeInterval = 1.0 / 20

        init() {}

        /// Take the state as it now is, and what just changed about it.
        func apply(_ state: SpaceSnapshot, _ delta: SpaceDelta) {
            // Before the removals, because an update that both flags a bubble
            // as leaving and drops it is one the renderer must not treat as a
            // pop — and a slow link is exactly where two ticks arrive as one.
            for (id, facts) in delta.entityFacts where facts[BubbleField.leaving] != nil {
                leaving.insert(id)
            }
            for entity in delta.spawned where entity.kind == BubbleField.kind {
                add(entity)
            }
            for id in delta.removed {
                remove(id)
                leaving.remove(id)
                guessed.removeValue(forKey: id)
            }
            for (id, pose) in delta.moved {
                guard let node = nodes[id] else { continue }
                node.move(
                    to: transform(for: pose),
                    relativeTo: root,
                    duration: cadence,
                    timingFunction: .linear
                )
            }

            reconcile(with: state)
        }

        /// Draw a state nothing has been drawn from yet.
        ///
        /// The joining case, and the case after a handover. A delta cannot
        /// express it — there is nothing to be a delta from.
        func reset(to state: SpaceSnapshot) {
            for node in nodes.values { node.removeFromParent() }
            nodes.removeAll()
            guessed.removeAll()
            leaving.removeAll()
            for entity in BubbleField.bubbles(in: state) { add(entity) }
        }

        func clear() {
            for node in nodes.values { node.removeFromParent() }
            nodes.removeAll()
            guessed.removeAll()
            leaving.removeAll()
        }

        /// Whatever bubble is under a point on screen, popped.
        ///
        /// - Returns: Whether anything was hit, so the caller can tell a miss
        ///   from a hit without asking the scene a second question.
        @discardableResult
        func pop(at point: CGPoint, in view: ARView) -> Bool {
            guard let hit = view.entity(at: point) else { return false }

            // Up through the hierarchy, because a hit reports the entity that
            // owns the collision shape and a model with children reports the
            // child. One bubble is one entity today; walking anyway costs a
            // pointer chase and survives the day it is not.
            var candidate: Entity? = hit
            while let current = candidate {
                let id = SpaceEntityID(current.name)
                if nodes[id] != nil {
                    burst(id)
                    onPop?(id)
                    return true
                }
                candidate = current.parent
            }
            return false
        }

        // MARK: - Nodes

        private func add(_ entity: SpaceEntity) {
            if entity.facts[BubbleField.leaving] != nil { leaving.insert(entity.id) }
            guard nodes[entity.id] == nil else { return }
            let hue: Double = if case let .decimal(value) = entity.facts["hue"] { value } else { 0.5 }
            let node = ModelEntity(
                mesh: .generateSphere(radius: BubbleField.Field.radius),
                materials: [
                    SimpleMaterial(
                        color: UIColor(
                            hue: CGFloat(hue),
                            saturation: 0.75,
                            brightness: 1,
                            alpha: 1
                        ),
                        roughness: 0.08,
                        isMetallic: false
                    ),
                ]
            )
            // The identifier travels on the entity so that a hit test answers
            // in the space's own terms rather than in RealityKit's.
            node.name = entity.id.rawValue
            node.transform = transform(for: entity.pose)
            node.generateCollisionShapes(recursive: false)
            root.addChild(node)
            nodes[entity.id] = node
        }

        private func remove(_ id: SpaceEntityID) {
            guard let node = nodes.removeValue(forKey: id) else { return }
            if leaving.remove(id) != nil {
                // It got away. Nothing to celebrate and nothing to draw: by the
                // time the field lets go of it, it is far above the shot, and a
                // burst up there would read as a pop somebody was not credited
                // for.
                node.removeFromParent()
            } else {
                vanish(node)
            }
        }

        /// The pop, as something to look at.
        ///
        /// Swelling and then disappearing rather than simply disappearing,
        /// because a bubble that is gone by the next frame gives no feedback at
        /// all about whether the tap landed — which is the one thing a player
        /// needs to know before deciding the game is broken.
        ///
        /// Large, and larger than looks sensible written down. The whole event
        /// lasts a fifth of a second on a phone held at arm's length, and at
        /// that duration the difference between a modest swell and this one is
        /// the difference between a bubble that disappeared and a bubble that
        /// was hit. It thins as it grows for the same reason: a solid sphere
        /// three times the size reads as a bigger bubble arriving rather than
        /// as the one that was there coming apart.
        private func vanish(_ node: ModelEntity) {
            var swollen = node.transform
            swollen.scale *= 3.2
            node.move(to: swollen, relativeTo: node.parent, duration: 0.18)
            thin(node)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(190))
                node.removeFromParent()
            }
        }

        /// Turn a bubble's skin to something a burst can be seen through.
        ///
        /// A new material rather than an animated one: RealityKit will
        /// interpolate a transform for free and will not interpolate a colour,
        /// and a single step to nearly transparent at the moment of the pop is
        /// what the eye reads as the surface giving way.
        private func thin(_ node: ModelEntity) {
            guard var model = node.model else { return }
            model.materials = model.materials.map { material in
                guard let simple = material as? SimpleMaterial else { return material }
                var faded = simple
                faded.color = .init(tint: simple.color.tint.withAlphaComponent(0.22))
                return faded
            }
            node.model = model
        }

        /// Take a bubble away now and remember that nobody agreed yet.
        private func burst(_ id: SpaceEntityID) {
            guard let node = nodes.removeValue(forKey: id) else { return }
            guessed[id] = ContinuousClock.now
            vanish(node)
        }

        /// Put back anything this device popped that the authority did not.
        ///
        /// Also the repair for a missed spawn: a bubble in the state with no
        /// node is one whose delta went astray, and the next snapshot is what
        /// makes it appear rather than it being lost for the bubble's lifetime.
        private func reconcile(with state: SpaceSnapshot) {
            let now = ContinuousClock.now
            for entity in BubbleField.bubbles(in: state) {
                if let guessedAt = guessed[entity.id] {
                    guard now - guessedAt > Self.grace else { continue }
                    guessed.removeValue(forKey: entity.id)
                }
                add(entity)
            }

            // And the reverse: a node for something the state no longer has.
            for id in nodes.keys where state.entities[id] == nil {
                remove(id)
            }
        }

        private func transform(for pose: SpacePose) -> Transform {
            let placed = Self.placement.world(from: pose)
            return Transform(
                scale: SIMD3(repeating: placed.scale),
                rotation: simd_quatf(
                    ix: placed.rotation.x,
                    iy: placed.rotation.y,
                    iz: placed.rotation.z,
                    r: placed.rotation.w
                ),
                translation: SIMD3(placed.position.x, placed.position.y, placed.position.z)
            )
        }
    }
#endif
