// Who is in the little window, and how the little window stays cheap.
//
// Picture in Picture is not a smaller copy of the grid. It is a different
// product with a different bound, and the difference is a factor of twenty in
// area: a nine-up grid on an iPhone gives each participant about 130x73 points,
// and the same nine participants in a PiP window get 53x30. At that size a face
// is four pixels of eye and nothing else, so the honest maximum is four tiles
// and this file enforces it rather than letting an integrator discover it.
//
// The second difference is that PiP runs while the app is in the background,
// which is exactly when a stale layout is most expensive. An application that
// enters PiP and leaves the grid's render boxes in place keeps downloading nine
// streams of 360p to draw four thumbnails, on cellular, with the screen off. The
// bytes are invisible — no frame drops, no stutter, nothing on screen looks
// wrong — and they turn up a month later as a support ticket about battery. So
// entering PiP *replaces* the reported layout rather than adding to it, which is
// what ``LayoutObserver/takeOver(_:)`` exists for.
//
// What is deliberately not here: compositing. The obvious way to put four people
// in one PiP window is to draw them into one pixel buffer and hand that to a
// single layer, and it is wrong on this platform, because the composite is app
// GPU work and an app that submits GPU work in the background is killed. Four
// participants therefore means four `AVSampleBufferDisplayLayer`s side by side,
// each decoded and scheduled by the media system, which is allowed to keep
// working while we are not.

import Foundation
import MoqomCore

/// Who appears in the Picture in Picture window.
///
/// Three shapes cover almost every product, and they compose rather than being
/// an enumeration of the combinations:
///
/// ```swift
/// .host                              // just whoever is running the room
/// .cohostsAndGuests                  // everyone on stage except the host
/// .host.including(.guest)            // a combination
/// .stage.excluding(someone)          // everyone on stage, minus one
/// ```
///
/// Membership is a rule, not a list, so a cohost promoted while the window is
/// open appears in it without the application noticing the promotion. The
/// escape hatch for products that want a literal list is ``only(_:)``, which
/// sets no roles and therefore admits exactly the identities named.
public struct PictureInPictureCast: Hashable, Sendable {
    /// The most tiles the window will ever draw.
    ///
    /// A legibility bound rather than a decode one. The PiP window is between a
    /// quarter and a third of the screen's width; four tiles inside it are
    /// already at the bottom rung of the ladder, and a fifth buys nothing that
    /// can be seen. Compare ``Gallery/maximumVideoBoxes``, which is sixteen
    /// because a full-screen grid has the room for it.
    public static let maximumBoxes = 4

    /// Admit anybody the roster contains.
    ///
    /// Not the same as listing every role, and the difference is what
    /// ``stage`` is built on. A participant exists in the roster because they
    /// announced a namespace, so the roster is by construction the set of
    /// people publishing — but their *role* is derived from grants, and grants
    /// arrive later on the room control track. Between joining and the first
    /// grants message every participant reads as a viewer, so a cast that
    /// spelled out `[.owner, .cohost, .guest]` would show an empty window for
    /// that whole interval, and forever in a room with no control authority.
    public var admitsEveryone: Bool

    /// Roles admitted wholesale. Empty means no role admits anybody, which is
    /// what makes ``only(_:)`` mean what it says.
    ///
    /// > Note: Roles need the room control track. A cast that names roles is
    /// > empty until grants have been published; ``admitsEveryone`` is the
    /// > one rule that works without them.
    public var roles: Set<ParticipantRole>

    /// Admitted whatever their role.
    public var included: Set<ParticipantIdentity>

    /// Refused whatever their role. Wins over everything else, including
    /// ``included`` and ``followsSpeaker`` — a viewer who muted someone does not
    /// want them reappearing in the corner of the Home Screen because they
    /// started talking.
    public var excluded: Set<ParticipantIdentity>

    /// Admit whoever is talking, whatever their role.
    ///
    /// The behaviour a one-tile window wants: a viewer who backgrounds a panel
    /// discussion wants to see the person speaking, not the person who happens
    /// to own the room. ``Gallery`` already promotes speech, so this only widens
    /// who is eligible; the ordering and the dwell that stops the window
    /// flickering between two people interrupting each other are unchanged.
    public var followsSpeaker: Bool

    /// How many tiles to draw, clamped to ``maximumBoxes``.
    public var boxes: Int

    public init(
        admitsEveryone: Bool = false,
        roles: Set<ParticipantRole> = [],
        included: Set<ParticipantIdentity> = [],
        excluded: Set<ParticipantIdentity> = [],
        followsSpeaker: Bool = false,
        boxes: Int = maximumBoxes
    ) {
        self.admitsEveryone = admitsEveryone
        self.roles = roles
        self.included = included
        self.excluded = excluded
        self.followsSpeaker = followsSpeaker
        self.boxes = boxes
    }

    /// Tiles after the legibility bound is applied.
    public var capacity: Int { max(1, min(boxes, Self.maximumBoxes)) }

    // MARK: - Common casts

    /// Whoever is running the room: the owner, or the cohost holding it while
    /// the owner is away.
    ///
    /// One tile, because a broadcast backgrounded to watch the host is the case
    /// where the window should be as large as the system will draw it.
    public static let host = PictureInPictureCast(roles: [.owner], boxes: 1)

    /// Everyone on stage who is not the host.
    public static let cohostsAndGuests = PictureInPictureCast(roles: [.cohost, .guest])

    /// Everyone publishing.
    ///
    /// The default, and the only cast that needs nothing from the room control
    /// track — see ``admitsEveryone``.
    public static let stage = PictureInPictureCast(admitsEveryone: true)

    /// Whoever is talking, and nobody when nobody is.
    ///
    /// Falls back to the host rather than to an empty window, because a window
    /// that empties itself during a pause in the conversation reads as a
    /// crashed stream.
    public static let speaker = PictureInPictureCast(
        roles: [.owner],
        followsSpeaker: true,
        boxes: 1
    )

    /// Exactly these people, whatever happens to their roles.
    public static func only(_ identities: some Sequence<ParticipantIdentity>) -> Self {
        PictureInPictureCast(included: Set(identities))
    }

    // MARK: - Composition

    public func including(_ roles: ParticipantRole...) -> Self {
        var copy = self
        copy.roles.formUnion(roles)
        return copy
    }

    public func including(_ identities: ParticipantIdentity...) -> Self {
        var copy = self
        copy.included.formUnion(identities)
        copy.excluded.subtract(identities)
        return copy
    }

    public func excluding(_ identities: ParticipantIdentity...) -> Self {
        var copy = self
        copy.excluded.formUnion(identities)
        copy.included.subtract(identities)
        return copy
    }

    public func showing(atMost boxes: Int) -> Self {
        var copy = self
        copy.boxes = boxes
        return copy
    }

    public func followingSpeaker(_ follows: Bool = true) -> Self {
        var copy = self
        copy.followsSpeaker = follows
        return copy
    }

    // MARK: - Resolution

    /// Whether this participant belongs in the window.
    ///
    /// - Parameters:
    ///   - isActingHost: Whether the room has handed them the host's role for
    ///     the duration of the owner's absence. Checked separately from
    ///     ``ParticipantRole/owner`` because succession grants the job without
    ///     granting ownership, so an acting host's derived role is still
    ///     `cohost` — and a cast of ``host`` that dropped them would black out
    ///     the window at precisely the moment the room needed watching.
    ///   - isVocal: Whether ``followsSpeaker`` should count them as a speaker.
    ///     Deliberately not "is talking right now": see
    ///     ``PictureInPictureStage``, which holds this true for a while after
    ///     the speech stops.
    public func admits(
        _ participant: Participant,
        isActingHost: Bool = false,
        isVocal: Bool = false
    ) -> Bool {
        if excluded.contains(participant.id) { return false }

        // Backstage is not a cast decision. A guest waiting in the wings is
        // not published to the audience at all, and a window that showed them
        // would be showing a namespace the viewer is not subscribed to.
        if participant.slot.isBackstage { return false }

        if admitsEveryone { return true }
        if included.contains(participant.id) { return true }
        if roles.contains(participant.role) { return true }
        if roles.contains(.owner), isActingHost { return true }
        if followsSpeaker, isVocal { return true }
        return false
    }
}

/// The occupants of the Picture in Picture window, kept stable across updates.
///
/// A thin wrapper over ``Gallery`` rather than a second ranking implementation.
/// The two layouts want the same thing — speech promotes, dwell stops churn,
/// spotlight and pin outrank both — and the only difference is who is eligible
/// and how many fit. Writing that ranking twice would mean the window and the
/// grid disagreeing about who matters, which is visible the moment a viewer
/// backgrounds the app mid-conversation and the window shows somebody else.
///
/// Dwell is longer here than in a grid. A tile changing in a full-screen layout
/// is a face moving; the same change in a one-tile window is the entire window
/// going black for a keyframe, so the churn is worth much more to avoid.
public struct PictureInPictureStage: Sendable {
    /// How long after speech stops a ``PictureInPictureCast/followsSpeaker``
    /// cast keeps admitting somebody.
    ///
    /// Without it, speaker-follow admits on the rising edge and refuses on the
    /// falling one, and `Gallery`'s dwell cannot help: dwell protects an
    /// occupant from being *displaced*, and somebody the cast has stopped
    /// admitting has not been displaced, they have left. The window would go
    /// dark in every gap between sentences. Matching the dwell means a speaker
    /// is only ever replaced by another speaker.
    public static let speechHold = Duration.seconds(6)

    public var cast: PictureInPictureCast {
        didSet {
            guard cast.capacity != oldValue.capacity else { return }
            gallery.policy = Self.policy(for: cast)
        }
    }

    /// The viewer's own identity, which never gets a tile: their camera is a
    /// self view, and PiP is for the people they cannot see.
    public var viewer: ParticipantIdentity?

    private var gallery: Gallery

    public init(cast: PictureInPictureCast = .stage, viewer: ParticipantIdentity? = nil) {
        self.cast = cast
        self.viewer = viewer
        gallery = Gallery(policy: Self.policy(for: cast))
    }

    /// Who to draw, in order.
    public var slots: [Gallery.Slot] { gallery.slots }

    /// Just the identities, which is what the layout override is keyed by.
    public var order: [ParticipantIdentity] { gallery.order }

    /// Everyone in the room the window is not drawing.
    ///
    /// They keep their audio: the point of the window is to stop paying for
    /// pixels nobody is looking at, not to leave the viewer listening to a
    /// conversation with half the voices missing.
    public var silentPartners: [ParticipantIdentity] { gallery.overflow }

    /// Recompute occupancy.
    ///
    /// - Returns: Whether anything moved, so a caller can drive this from every
    ///   room event without relaying out a window that has not changed.
    @discardableResult
    public mutating func update(
        _ state: RoomState,
        speakers: ActiveSpeakers,
        at now: MonotonicTime
    ) -> Bool {
        let actingHost: ParticipantIdentity? = if case let .actingHost(who) = state.lifecycle {
            who
        } else {
            nil
        }

        // Expressed to `Gallery` as a deny list, because that is the shape it
        // takes. Everyone the cast refuses is excluded; the ranking among those
        // it admits is `Gallery`'s to make.
        var refused: Set<ParticipantIdentity> = []
        for participant in state.roster.participants {
            let admitted = cast.admits(
                participant,
                isActingHost: participant.id == actingHost,
                isVocal: isVocal(participant.id, speakers: speakers, at: now)
            )
            if !admitted { refused.insert(participant.id) }
        }
        if let viewer { refused.insert(viewer) }

        gallery.excluded = refused
        return gallery.update(state.roster, speakers: speakers, at: now)
    }

    private func isVocal(
        _ identity: ParticipantIdentity,
        speakers: ActiveSpeakers,
        at now: MonotonicTime
    ) -> Bool {
        if speakers.isSpeaking(identity) { return true }
        guard let last = speakers.lastSpoke(identity) else { return false }
        return now - last < Self.speechHold
    }

    private static func policy(for cast: PictureInPictureCast) -> Gallery.Policy {
        Gallery.Policy(kind: .video, boxes: cast.capacity, dwell: speechHold)
    }
}
