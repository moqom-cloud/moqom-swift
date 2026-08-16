// Drawing somebody else's simulation, and turning a finger into an intent.
//
// The wire is the scorekeeper, not the animator. A spawn is a bubble that
// appears and starts climbing. A pop is a bubble that bursts. Pose ticks in
// between used to be written onto the nodes, and on a phone that only
// redraws when SwiftUI refreshes that looked like the whole field jumping
// once a second. The climb is a RealityKit move from where the bubble was
// first seen to the top of the field, linear, and it is not touched again
// until someone pops it.
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
        static let tilePlacement = SpaceAnchor(
            origin: SpaceVector(x: 0, y: -0.30, z: -0.55),
            rotation: .identity,
            scale: 0.5
        )

        /// Framed for the overlay camera: floor at the bottom of the view,
        /// ceiling at the top. The previous origin sat the floor near the
        /// middle of the phone, which is what "they stop too high" was.
        static let screenPlacement = SpaceAnchor(
            origin: SpaceVector(x: 0, y: -0.70, z: 0),
            rotation: .identity,
            scale: 1.0
        )

        /// The virtual camera the overlay uses, so taps can be projected
        /// without asking RealityKit for a hit test it will not give us.
        enum OverlayCamera {
            static let distance: Float = 1.35
            static let fieldOfView: Float = 50
        }

        var placement = tilePlacement

        /// How long a guessed pop has to be confirmed before it is taken back.
        private static let grace = Duration.seconds(1)

        /// The bubbles themselves. A plain entity so the overlay can parent it
        /// in world space. ``AnchorEntity/camera`` follows the face-tracking
        /// camera, and adding that to a RealityView still bound it to the AR
        /// session — which drew the field inside the self tile and clipped it
        /// to that rounded rect.
        let root = Entity()

        /// Used only when the field lives in the AR tile.
        let cameraAnchor = AnchorEntity(.camera)

        /// Hang the field off the face-tracking camera.
        func lockToCamera() {
            if root.parent !== cameraAnchor {
                root.removeFromParent()
                cameraAnchor.addChild(root)
            }
        }

        /// Hang the field in world space, for the full-screen overlay.
        func lockToWorld() {
            root.removeFromParent()
            cameraAnchor.removeFromParent()
            // Hierarchical: a collision on any bubble is then a tap target,
            // including ones that spawned before we started setting the
            // component on each node.
            root.components.set(InputTargetComponent())
        }

        /// What this device wants the space to do. Set by the model.
        var onPop: (@MainActor (SpaceEntityID) -> Void)?

        private var nodes: [SpaceEntityID: ModelEntity] = [:]

        /// Bubbles removed on this device before anybody agreed.
        private var guessed: [SpaceEntityID: ContinuousClock.Instant] = [:]

        /// Two gestures fire for one finger. The second must not take a neighbour.
        private var lastPopAt: ContinuousClock.Instant?

        /// Bubbles the field has said are climbing away.
        ///
        /// Still tappable — a bubble on its way out is the one worth hurrying
        /// for — and if it is not tapped, it leaves without a pop.
        private var leaving: Set<SpaceEntityID> = []

        /// How long an update is expected to be the newest one, used only when
        /// the clocks cannot be compared. With a shared clock the display loop
        /// samples ``SpaceTimeline`` instead, so both phones draw the same
        /// instant rather than the follower sitting a round-trip behind.
        var cadence: TimeInterval = 1.0 / 20

        /// The clock the ticks were stamped on. Same closure the space uses.
        var clock: @Sendable () -> Timecode = { .fallback() }

        private var appearing: [SpaceEntityID: ContinuousClock.Instant] = [:]
        private var pulse: FramePulse?
        private var link: CADisplayLink?

        /// How long a new bubble takes to arrive, in seconds.
        private static let fadeIn: Double = 0.32

        init() {}

        /// Drive poses from the panel, not from RealityKit's scene tick.
        ///
        /// The overlay used to subscribe to `SceneEvents.Update`. That fires
        /// when RealityView decides to draw, and SwiftUI re-subscribes it
        /// every time the room model publishes — scores, cadence, statistics
        /// four times a second. The bubbles then jumped to each new tick
        /// instead of interpolating between them. A display link is the same
        /// clock the glass is on, and it does not care what SwiftUI is doing.
        func startPresenting(in _: Scene? = nil) {
            guard link == nil else { return }
            let pulse = FramePulse(scene: self)
            let link = CADisplayLink(target: pulse, selector: #selector(FramePulse.fire))
            let hertz = Float(UIScreen.main.maximumFramesPerSecond)
            if hertz > 0 {
                link.preferredFrameRateRange = CAFrameRateRange(
                    minimum: min(60, hertz),
                    maximum: hertz,
                    preferred: hertz
                )
            }
            link.add(to: .main, forMode: .common)
            self.pulse = pulse
            self.link = link
        }

        func stopPresenting() {
            link?.invalidate()
            link = nil
            pulse = nil
        }

        /// The display link's target. `CADisplayLink` retains it, so this
        /// must not retain the scene. `@unchecked Sendable` because the
        /// callback is scheduled on the main run loop, which is the scene's
        /// actor — the compiler cannot see that.
        private final class FramePulse: NSObject, @unchecked Sendable {
            weak var scene: BubbleScene?
            init(scene: BubbleScene) { self.scene = scene }
            @objc func fire(_ link: CADisplayLink) {
                let scene = scene
                MainActor.assumeIsolated { scene?.present() }
            }
        }

        /// Take the state as it now is, and what just changed about it.
        func apply(_ state: SpaceSnapshot, _ delta: SpaceDelta, at time: Timecode) {
            // Before the removals, because an update that both flags a bubble
            // as leaving and drops it is one the renderer must not treat as a
            // pop — and a slow link is exactly where two ticks arrive as one.
            for (id, facts) in delta.entityFacts where facts[BubbleField.leaving] != nil {
                leaving.insert(id)
            }
            for entity in delta.spawned where entity.kind == BubbleField.kind {
                add(entity, at: time)
            }
            for id in delta.removed {
                remove(id)
                leaving.remove(id)
                guessed.removeValue(forKey: id)
            }
            // Pose ticks are ignored. Applying them is what made the field
            // hitch: each arrival snapped every bubble to a new height.

            reconcile(with: state, at: time)
        }

        /// Draw a state nothing has been drawn from yet.
        ///
        /// The joining case, and the case after a handover. A delta cannot
        /// express it — there is nothing to be a delta from.
        func reset(to state: SpaceSnapshot, at time: Timecode? = nil) {
            let stamped = time ?? clock()
            for node in nodes.values { node.removeFromParent() }
            nodes.removeAll()
            appearing.removeAll()
            guessed.removeAll()
            leaving.removeAll()
            for entity in BubbleField.bubbles(in: state) { add(entity, at: stamped) }
        }

        func clear() {
            stopPresenting()
            for node in nodes.values { node.removeFromParent() }
            nodes.removeAll()
            appearing.removeAll()
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
            return pop(hitting: hit)
        }

        /// A tap in the overlay, projected through the same camera that drew it.
        ///
        /// RealityView's `SpatialTapGesture.targetedToAnyEntity()` does not see
        /// these spheres — that path wants an `InputTargetComponent` and still
        /// misses more often than it hits. The AR view used `entity(at:)`, which
        /// this view does not have. Projecting the nodes we already have is the
        /// same test a finger is making.
        @discardableResult
        func pop(at point: CGPoint, in size: CGSize) -> Bool {
            let depthToPlane = OverlayCamera.distance
            let halfHeight = tan(OverlayCamera.fieldOfView * .pi / 360)
            let aspect = Float(size.width / max(size.height, 1))
            let halfWidth = halfHeight * aspect
            let finger = max(44 as CGFloat, 1)

            var best: (SpaceEntityID, CGFloat)?
            for (id, node) in nodes {
                let world = node.position(relativeTo: nil)
                let depth = depthToPlane - world.z
                guard depth > 0.05 else { continue }
                let screen = CGPoint(
                    x: CGFloat(world.x / (depth * halfWidth) * 0.5 + 0.5) * size.width,
                    y: CGFloat(-world.y / (depth * halfHeight) * 0.5 + 0.5) * size.height
                )
                let radius = CGFloat(
                    BubbleField.Field.radius * placement.scale / depth
                        * Float(size.height) / (2 * halfHeight)
                )
                let dx = point.x - screen.x
                let dy = point.y - screen.y
                let distance = (dx * dx + dy * dy).squareRoot()
                guard distance <= max(radius * 1.8, finger) else { continue }
                if best == nil || distance < best!.1 {
                    best = (id, distance)
                }
            }
            guard let id = best?.0 else { return false }
            return commitPop(id)
        }

        /// Whatever bubble owns this entity, popped.
        @discardableResult
        func pop(hitting entity: Entity) -> Bool {
            // Up through the hierarchy, because a hit reports the entity that
            // owns the collision shape and a model with children reports the
            // child. One bubble is one entity today; walking anyway costs a
            // pointer chase and survives the day it is not.
            var candidate: Entity? = entity
            while let current = candidate {
                let id = SpaceEntityID(current.name)
                if nodes[id] != nil {
                    return commitPop(id)
                }
                candidate = current.parent
            }
            return false
        }

        // MARK: - Nodes

        private func add(_ entity: SpaceEntity, at time: Timecode) {
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
            // Input only — no physics. A slightly fat sphere so a finger that
            // lands on the highlight still counts; the drawn mesh stays the
            // true radius.
            var collision = CollisionComponent(
                shapes: [.generateSphere(radius: BubbleField.Field.radius * 1.8)]
            )
            collision.filter = CollisionFilter(group: [], mask: [])
            node.components.set(collision)
            node.components.set(InputTargetComponent())
            root.addChild(node)
            nodes[entity.id] = node
            appearing[entity.id] = .now
            node.components.set(OpacityComponent(opacity: 0))
            climb(node, from: entity.pose, id: entity.id)
        }

        /// Send a bubble to the top under its own power, swaying as it goes.
        ///
        /// The path is the same integration the authority uses — rise plus the
        /// sine/cosine drift — baked into a RealityKit animation so the view
        /// keeps drawing frames. A straight `move` was smooth and lifeless.
        private func climb(_ node: ModelEntity, from pose: SpacePose, id: SpaceEntityID) {
            let course = course(for: id)
            let distance = max(0, BubbleField.Field.departure - pose.position.y)
            let duration = TimeInterval(distance / course.speed)
            guard duration > 0.05 else { return }

            let interval: Float = 1.0 / 30.0
            let steps = max(2, Int(ceil(duration / TimeInterval(interval))))
            var pose = pose
            var phase = course.phase
            var frames: [Transform] = []
            frames.reserveCapacity(steps + 1)
            for step in 0 ... steps {
                frames.append(transform(for: pose))
                guard step < steps else { break }
                pose.position.y += course.speed * interval
                pose.position.x += sin(phase * 1.7) * course.sway * interval
                pose.position.z += cos(phase * 1.1) * course.sway * interval
                phase += interval
            }

            let animation = SampledAnimation(
                frames: frames,
                name: "climb",
                tweenMode: .linear,
                frameInterval: interval,
                bindTarget: .transform
            )
            guard let resource = try? AnimationResource.generate(with: animation) else { return }
            node.playAnimation(resource)
        }

        /// The same course on every phone, from the name.
        private func course(for id: SpaceEntityID) -> (speed: Float, sway: Float, phase: Float) {
            let sum = id.rawValue.unicodeScalars.reduce(UInt64(0)) { $0 &* 131 + UInt64($1.value) }
            let a = Float(sum % 1000) / 1000
            let b = Float((sum / 1000) % 1000) / 1000
            let c = Float((sum / 1_000_000) % 1000) / 1000
            return (
                speed: BubbleField.Rules.default.rise * (0.75 + 0.5 * a),
                sway: 0.4 + 0.8 * b,
                phase: c * 6.28
            )
        }

        private func remove(_ id: SpaceEntityID) {
            appearing.removeValue(forKey: id)
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
            // The climb is an animation. `node.transform` is still the spawn
            // pose, so a pop that used it burst on the floor. Bake where it
            // actually is, then swell from there.
            let parent = node.parent
            node.transform = Transform(
                scale: node.scale(relativeTo: parent),
                rotation: node.orientation(relativeTo: parent),
                translation: node.position(relativeTo: parent)
            )
            node.stopAllAnimations()
            var swollen = node.transform
            swollen.scale *= 3.2
            node.move(to: swollen, relativeTo: parent, duration: 0.18)
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

        /// One finger, one bubble — even when both tap gestures fire.
        private func commitPop(_ id: SpaceEntityID) -> Bool {
            let now = ContinuousClock.now
            if let last = lastPopAt, now - last < .milliseconds(80) { return false }
            lastPopAt = now
            burst(id)
            onPop?(id)
            return true
        }

        /// Take a bubble away now and remember that nobody agreed yet.
        private func burst(_ id: SpaceEntityID) {
            appearing.removeValue(forKey: id)
            guard let node = nodes.removeValue(forKey: id) else { return }
            guessed[id] = ContinuousClock.now
            vanish(node)
        }

        /// Put back anything this device popped that the authority did not.
        ///
        /// Also the repair for a missed spawn: a bubble in the state with no
        /// node is one whose delta went astray, and the next snapshot is what
        /// makes it appear rather than it being lost for the bubble's lifetime.
        private func reconcile(with state: SpaceSnapshot, at time: Timecode) {
            let now = ContinuousClock.now
            for entity in BubbleField.bubbles(in: state) {
                if let guessedAt = guessed[entity.id] {
                    guard now - guessedAt > Self.grace else { continue }
                    guessed.removeValue(forKey: entity.id)
                }
                add(entity, at: time)
            }

            // And the reverse: a node for something the state no longer has.
            for id in nodes.keys where state.entities[id] == nil {
                remove(id)
            }
        }

        /// Fade new bubbles in. Positions are left to the climb animation.
        private func present() {
            for (id, node) in nodes {
                guard let born = appearing[id] else { continue }
                let elapsed = Double((ContinuousClock.now - born).wholeNanoseconds)
                    / 1_000_000_000
                let fade = Float(min(1, elapsed / Self.fadeIn))
                let eased = 1 - (1 - fade) * (1 - fade)
                node.components.set(OpacityComponent(opacity: eased))
                if fade >= 1 { appearing.removeValue(forKey: id) }
            }
        }

        private func transform(for pose: SpacePose) -> Transform {
            let placed = placement.world(from: pose)
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
