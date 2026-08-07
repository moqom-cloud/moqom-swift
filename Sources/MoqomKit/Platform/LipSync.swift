import Foundation

/// How much delay the picture must take on to stay in sync with the voice.
///
/// Separated from the view that applies it for the same reason as ``PlayoutDelay``: the decision
/// is arithmetic over two measured delays and can be run against made-up numbers in a test, while
/// the thing that applies it needs a renderer, a participant and a running call.
public enum LipSync {
    /// How far the picture may be shown ahead of the voice before anyone would call it out of
    /// sync.
    ///
    /// The two directions are not alike and this is the whole reason the type exists. Sound
    /// arriving before its picture is noticed at a few tens of milliseconds — it reads as a badly
    /// dubbed film. Picture arriving before its sound is noticed far later, past a tenth of a
    /// second, because it is what distance does in the physical world and every listener has a
    /// lifetime of practice with it.
    ///
    /// So the picture is allowed to lead and is never allowed to lag. Making the delay symmetric
    /// costs real latency to correct an error in the direction nobody perceives.
    ///
    /// A hundred, against a detection threshold for this direction of about a hundred and
    /// twenty-five. This was sixty, held back on the grounds that the offset wanders and the
    /// wander would add to the lead. It does not: this figure sets a *floor* under the picture's
    /// delay, so the picture leads by this much only when it is sitting exactly on that floor,
    /// and every millisecond the buffer spends above the floor is a millisecond of lead given
    /// back. Wander can only ever reduce it — which is what ``LipSyncTests/onlyOneDirection``
    /// asserts — so the standing figure is the worst case rather than a starting point, and there
    /// is no reason to hold two thirds of the allowance in reserve against something that cannot
    /// happen.
    public static let pictureMayLead = Duration.milliseconds(100)

    /// The least delay the picture may be held at, given what the voice is holding.
    ///
    /// - Parameters:
    ///   - voice: The delay the voice's buffer is running at. The picture follows this and never
    ///     the other way round: audio is a twentieth of the bitrate and every packet stands alone,
    ///     so it arrives when video cannot, and holding it back to match a struggling picture
    ///     would throw away the one part of the call still working.
    ///   - bounds: The floor the application asked for and the ceiling it will tolerate. A voice
    ///     buffer that has grown to half a second is describing a link in trouble, and following
    ///     it there would put half a second on the picture too; past the ceiling the two are
    ///     allowed to drift apart, which is the better failure.
    public static func floor(voice: Duration, bounds: (floor: Duration, ceiling: Duration)) -> Duration {
        let led = max(.zero, voice - pictureMayLead)
        return min(max(bounds.floor, led), bounds.ceiling)
    }
}
