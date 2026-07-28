// Who is talking, decided on the receiving device.
//
// A gallery of sixteen tiles needs an answer to "who is speaking" for two
// different jobs: the ring around a tile, and — much more importantly — which
// sixteen of twenty people get a tile at all. Without it the gallery falls back
// on whatever order the roster happens to be in, which is alphabetical, and the
// four people left out are chosen by username and stay left out while they talk.
//
// Every other stack computes this on the server. The SFU has the plaintext
// audio, measures the energy, and publishes an active-speaker list. That is a
// reasonable design right up until the media is end-to-end encrypted, at which
// point the server has ciphertext and the feature disappears — which is why
// products that took the server-side route treat E2EE as a mode with features
// missing rather than as the default.
//
// Here the subscriber already has every speaker's audio as separate tracks, so
// it can answer the question itself, and the answer costs nothing extra on the
// wire and survives encryption unchanged.
//
// The input is the publisher's own voice-activity flag rather than a level
// measured here, and that is deliberate in both directions. The publisher has
// the pre-encode signal and its own adaptive noise floor, so its judgement is
// better than anything derivable from a decoded Opus frame; and a boolean is
// all that leaves the device, so the relay learns that somebody is talking —
// which it can already infer from packet timing — and not how loudly.

import Foundation
import MoqomCore

/// Who is currently speaking, and who spoke most recently.
///
/// A value type with `mutating` updates rather than an actor: this is called
/// from whatever already owns the audio path, once per arriving packet, and an
/// `await` per 20ms packet per participant is a cost with nothing to show for
/// it.
public struct ActiveSpeakers: Sendable {
    public struct Policy: Hashable, Sendable {
        /// How long a participant keeps speaking after the last voiced packet.
        ///
        /// Small, because the acoustic hysteresis already happened at the
        /// publisher: ``VoiceActivity`` holds through the gaps between words and
        /// only then reports silence, so this hangover exists to cover jitter
        /// and the absence of packets under DTX, not pauses in speech. The two
        /// compose, and making this one generous is how a speaking ring ends up
        /// staying lit a second after somebody stops.
        public var hangover: Duration

        public init(hangover: Duration = .milliseconds(400)) {
            self.hangover = hangover
        }

        public static let `default` = Policy()
    }

    public var policy: Policy

    /// When each participant last sent a voiced packet.
    private var voiced: [ParticipantIdentity: MonotonicTime] = [:]

    private var live: Set<ParticipantIdentity> = []

    public init(policy: Policy = .default) {
        self.policy = policy
    }

    /// Record a packet's voice-activity flag.
    ///
    /// - Returns: The participants whose speaking state changed, which is empty
    ///   on almost every call and is the only thing worth publishing to a UI.
    @discardableResult
    public mutating func heard(
        voiced isVoiced: Bool,
        from identity: ParticipantIdentity,
        at now: MonotonicTime
    ) -> Set<ParticipantIdentity> {
        if isVoiced { voiced[identity] = now }
        return recompute(at: now)
    }

    /// Record an arriving audio frame.
    @discardableResult
    public mutating func heard(
        _ frame: EncodedAudioFrame,
        from identity: ParticipantIdentity,
        at now: MonotonicTime
    ) -> Set<ParticipantIdentity> {
        heard(voiced: !frame.isSilence, from: identity, at: now)
    }

    /// Let the hangover expire without a packet arriving.
    ///
    /// Has to be driven by something, because under DTX a participant who stops
    /// talking stops sending, and a state machine fed only by arriving packets
    /// would leave the last speaker in a silent room lit up forever.
    @discardableResult
    public mutating func refresh(at now: MonotonicTime) -> Set<ParticipantIdentity> {
        recompute(at: now)
    }

    /// Forget a participant who left, so a rejoin does not inherit their
    /// history and jump the queue for a tile.
    public mutating func remove(_ identity: ParticipantIdentity) {
        voiced.removeValue(forKey: identity)
        live.remove(identity)
    }

    public func isSpeaking(_ identity: ParticipantIdentity) -> Bool {
        live.contains(identity)
    }

    /// When this participant was last voiced, or `nil` if never heard.
    ///
    /// The ordering input for everyone who is not currently talking, which is
    /// most of a large room most of the time.
    public func lastSpoke(_ identity: ParticipantIdentity) -> MonotonicTime? {
        voiced[identity]
    }

    /// Everyone speaking now, most recent first.
    public var speaking: [ParticipantIdentity] {
        live.sorted { lhs, rhs in
            let left = voiced[lhs] ?? .zero
            let right = voiced[rhs] ?? .zero
            if left != right { return left > right }
            return lhs.description < rhs.description
        }
    }

    private mutating func recompute(at now: MonotonicTime) -> Set<ParticipantIdentity> {
        var next: Set<ParticipantIdentity> = []
        for (identity, last) in voiced where now - last < policy.hangover {
            next.insert(identity)
        }
        let changed = next.symmetricDifference(live)
        live = next
        return changed
    }
}
