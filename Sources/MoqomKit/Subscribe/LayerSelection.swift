// Subscribing to what you can actually see.
//
// Nine participants at 1080p is roughly 22 Mbps of downlink; the same grid at
// the resolution the boxes actually render is closer to 5. In a grid this is
// the dominant cost, not an optimisation at the margin.
//
// The mistake this file is built to prevent is conflating two independent
// limits. Render size is a function of layout and is measured on the client.
// Network capacity is a function of congestion and is owned by the congestion
// controller. The subscription is the *minimum* of both. Treating quality as
// one number driven by bandwidth alone is the common version of this, and it
// leaves the grid case entirely unsolved: a viewer on gigabit fibre watching a
// thumbnail should still receive 360p.
//
// The other thing it exists to prevent is oscillation. Snapping to the nearest
// rung without hysteresis means a window drag flips between layers, and every
// switch costs a keyframe — so the upgrade threshold sits above the downgrade
// threshold and a change has to be worth making before it is made.

import Foundation
import MoqomCore

#if canImport(CoreGraphics)
    import CoreGraphics
#endif

/// Whether the view is actually on screen.
///
/// Off-screen means unsubscribe from video entirely while keeping audio, which
/// is the single largest saving available — which is why visibility matters as
/// much as size, and why this is not a boolean.
public enum RenderVisibility: String, Hashable, Sendable {
    /// On screen and drawn.
    case visible

    /// In the hierarchy but covered, or scrolled out of a clipping view.
    case occluded

    /// Not in the hierarchy.
    case offScreen

    /// The app is not in the foreground.
    case appBackgrounded

    var wantsVideo: Bool { self == .visible }
}

/// How big a track will be drawn, and whether it will be drawn at all.
///
/// Sizes are in layout points with a separate scale, because that is how every
/// UI framework reports them and converting at the boundary is the only way to
/// stop a 320pt view on a 3× display from being served 320px of video. That
/// under-serves every high-DPI client, and it is invisible in a simulator at
/// 1×.
public struct RenderBox: Hashable, Sendable {
    /// Width in layout points.
    public let width: Double

    /// Height in layout points.
    public let height: Double

    /// Device pixel ratio.
    public let scale: Double

    public let visibility: RenderVisibility

    public init(width: Double, height: Double, scale: Double, visibility: RenderVisibility = .visible) {
        self.width = max(0, width)
        self.height = max(0, height)
        self.scale = max(1, scale)
        self.visibility = visibility
    }

    #if canImport(CoreGraphics)
        public init(size: CGSize, scale: CGFloat, visibility: RenderVisibility = .visible) {
            self.init(
                width: Double(size.width),
                height: Double(size.height),
                scale: Double(scale),
                visibility: visibility
            )
        }
    #endif

    /// What the box needs, in device pixels.
    public var pixelSize: PixelSize {
        PixelSize(width: Int((width * scale).rounded()), height: Int((height * scale).rounded()))
    }

    /// A box that is not being drawn.
    public static let hidden = RenderBox(width: 0, height: 0, scale: 1, visibility: .offScreen)
}

/// What the link will carry for this track.
///
/// Supplied by the congestion controller. Kept as a separate input rather than
/// folded into the box so that the two constraints stay visibly distinct at the
/// call site.
public struct NetworkAllowance: Hashable, Sendable {
    /// Bits per second this subscription may use.
    public let bitrate: Int

    /// A hard ceiling irrespective of bitrate, used when the client is over its
    /// subscribe budget — the bound that replaces Agora's "subscribe to at most
    /// 50" with something that degrades instead of refusing.
    public let ceiling: LayerID?

    public init(bitrate: Int, ceiling: LayerID? = nil) {
        self.bitrate = bitrate
        self.ceiling = ceiling
    }

    /// Effectively unlimited, for the common case where congestion control has
    /// nothing to say yet.
    public static let unconstrained = NetworkAllowance(bitrate: .max)
}

/// What to subscribe to.
public struct LayerSelection: Hashable, Sendable {
    /// The video layer, or `nil` for no video at all.
    public let video: LayerID?

    /// Audio is subscribed independently and survives the video being dropped.
    public let audio: Bool

    /// Why the selector landed here. Useful in a debug overlay and in support
    /// tickets, where "why is this blurry" is otherwise unanswerable.
    public let reason: SelectionReason

    public init(video: LayerID?, audio: Bool, reason: SelectionReason) {
        self.video = video
        self.audio = audio
        self.reason = reason
    }
}

/// Which constraint decided the outcome.
public enum SelectionReason: String, Hashable, Sendable {
    case renderSize
    case networkCapacity
    case subscribeBudget
    case notVisible
    case prewarming
    case publisherOffered
}

/// Thresholds that stop the ladder oscillating.
public struct LayerSelectionPolicy: Hashable, Sendable {
    /// The box must need this multiple of the current rung's pixels before
    /// climbing. Above 1 so that a few points of growth do not cost a keyframe.
    public var upgradeFactor: Double

    /// The box must fall to this multiple of the *lower* rung's pixels before
    /// descending onto it.
    ///
    /// Measured against the rung being descended to, not against the rung being
    /// held. Against the held rung it would never bind — ladder steps are
    /// roughly 4× apart, so any box small enough to select a lower rung is
    /// already far below any fraction of the current one, and the guard would
    /// silently do nothing.
    public var downgradeFactor: Double

    /// Keep audio when video is dropped for visibility.
    public var keepsAudioWhenHidden: Bool

    /// Treat an occluded view as hidden. Off by default because occlusion is
    /// often momentary — a sheet being dismissed — and dropping video for it
    /// costs a keyframe on the way back.
    public var treatsOccludedAsHidden: Bool

    public init(
        upgradeFactor: Double = 1.2,
        downgradeFactor: Double = 0.8,
        keepsAudioWhenHidden: Bool = true,
        treatsOccludedAsHidden: Bool = false
    ) {
        self.upgradeFactor = upgradeFactor
        self.downgradeFactor = downgradeFactor
        self.keepsAudioWhenHidden = keepsAudioWhenHidden
        self.treatsOccludedAsHidden = treatsOccludedAsHidden
    }

    public static let `default` = LayerSelectionPolicy()

    /// Screenshare degrades frame rate to nothing before it gives up
    /// resolution, so the hysteresis band on *size* is much tighter — a
    /// screenshare that drops a resolution rung makes text unreadable, which is
    /// a qualitatively worse outcome than a soft face.
    public static let screenShare = LayerSelectionPolicy(
        upgradeFactor: 1.05,
        downgradeFactor: 0.95
    )
}

/// Picks a layer for one track, and remembers what it picked.
///
/// A value type with a `mutating` update rather than an actor: selection is
/// pure arithmetic over the last decision, and making it an actor would put an
/// `await` in a layout pass for no benefit. The owning ``SubscriptionPlanner``
/// provides whatever isolation is needed.
public struct LayerSelector: Sendable {
    public let ladder: LayerLadder
    public var policy: LayerSelectionPolicy

    /// The last decision, or `nil` before the first.
    public private(set) var current: LayerSelection?

    /// A layer requested ahead of need.
    ///
    /// Fullscreen must pre-warm: start the higher layer when the *intent*
    /// appears, on hover or touch-down, so the frame is ready before the
    /// animation finishes rather than a second after.
    private var prewarmed: LayerID?

    public init(ladder: LayerLadder, policy: LayerSelectionPolicy? = nil) {
        self.ladder = ladder
        self.policy = policy ?? (ladder.kind == .screenShare ? .screenShare : .default)
    }

    /// Carry the decision already in force onto a selector for a new ladder.
    ///
    /// A ladder can be replaced while a subscription is live — the catalog
    /// lands after the default, grants arrive, a publisher restates what it is
    /// offering — and ``current`` is a fact about the wire rather than about
    /// the ladder: it is what the relay was last asked for, and it stays true
    /// across the swap. Dropping it makes the selector believe it holds no
    /// subscription, so the next layout that hides this participant produces no
    /// unsubscribe and the track keeps arriving for a tile nobody is drawing.
    public mutating func adopt(_ selection: LayerSelection?) {
        current = selection
    }

    /// Request a layer before the layout that needs it.
    ///
    /// Cleared by the next ``update(box:allowance:)`` that would meet or exceed
    /// it, so a pre-warm that turns out to be wrong does not pin a high layer
    /// indefinitely.
    public mutating func prewarm(for box: RenderBox) {
        guard let target = ladder.lowestCovering(pixels: box.pixelSize.pixelCount) else { return }
        prewarmed = target.id
    }

    public mutating func cancelPrewarm() {
        prewarmed = nil
    }

    /// Recompute, returning the new selection only when it changed.
    ///
    /// `nil` means "no subscription change needed", which lets a caller drive
    /// this from every layout pass without generating traffic.
    @discardableResult
    public mutating func update(
        box: RenderBox,
        allowance: NetworkAllowance = .unconstrained
    ) -> LayerSelection? {
        let next = evaluate(box: box, allowance: allowance)
        guard next != current else { return nil }
        current = next
        return next
    }

    private func evaluate(box: RenderBox, allowance: NetworkAllowance) -> LayerSelection {
        let hidden = !box.visibility.wantsVideo
            && (box.visibility != .occluded || policy.treatsOccludedAsHidden)

        if hidden || box.pixelSize.isEmpty {
            return LayerSelection(
                video: nil,
                audio: policy.keepsAudioWhenHidden,
                reason: .notVisible
            )
        }

        guard let renderChoice = ladder.lowestCovering(pixels: box.pixelSize.pixelCount) else {
            return LayerSelection(video: nil, audio: true, reason: .publisherOffered)
        }

        // The two constraints, resolved independently and then intersected.
        var choice = renderChoice
        var reason = SelectionReason.renderSize

        if let networkChoice = ladder.highestWithin(bitrate: allowance.bitrate),
           let networkIndex = ladder.index(of: networkChoice.id),
           let renderIndex = ladder.index(of: renderChoice.id),
           networkIndex < renderIndex
        {
            choice = networkChoice
            reason = .networkCapacity
        }

        if let ceiling = allowance.ceiling,
           let ceilingIndex = ladder.index(of: ceiling),
           let chosenIndex = ladder.index(of: choice.id),
           ceilingIndex < chosenIndex,
           let capped = ladder.layer(id: ceiling)
        {
            choice = capped
            reason = .subscribeBudget
        }

        if let prewarmed,
           let prewarmIndex = ladder.index(of: prewarmed),
           let chosenIndex = ladder.index(of: choice.id),
           prewarmIndex > chosenIndex,
           let target = ladder.layer(id: prewarmed),
           target.bitrate <= allowance.bitrate
        {
            return LayerSelection(video: target.id, audio: true, reason: .prewarming)
        }

        // Hysteresis. Only applied against a previous *video* selection, so
        // coming back from hidden goes straight to the right rung instead of
        // climbing one step per layout pass.
        if let currentID = current?.video,
           let currentIndex = ladder.index(of: currentID),
           let currentLayer = ladder.layer(id: currentID),
           let chosenIndex = ladder.index(of: choice.id),
           reason == .renderSize
        {
            let needed = Double(box.pixelSize.pixelCount)
            if chosenIndex > currentIndex {
                let threshold = Double(currentLayer.size.pixelCount) * policy.upgradeFactor
                if needed < threshold { choice = currentLayer }
            } else if chosenIndex < currentIndex {
                let threshold = Double(choice.size.pixelCount) * policy.downgradeFactor
                if needed > threshold { choice = currentLayer }
            }
        }

        return LayerSelection(video: choice.id, audio: true, reason: reason)
    }
}
