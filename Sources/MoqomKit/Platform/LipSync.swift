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
    /// Sixty rather than the hundred-and-some the detection threshold would permit, because this
    /// is a standing offset and the measured one wanders on top of it: across a fourteen minute
    /// call the two legs moved over a range of about eighty milliseconds on their own. Sixty
    /// standing plus that wander stays inside the threshold at its worst, and the last forty
    /// milliseconds are worth much less than the certainty.
    public static let pictureMayLead = Duration.milliseconds(60)

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
