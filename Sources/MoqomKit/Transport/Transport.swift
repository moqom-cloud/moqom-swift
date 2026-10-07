// The seam the real client plugs into.
//
// A note on where this boundary sits, because the obvious place is not the
// right one. A "transport" protocol would naturally be QUIC-shaped — open a
// unidirectional stream, open a bidirectional stream, send a datagram, accept
// an inbound stream, reset. That seam exists and matters, and it is one layer
// down: `QUICCarrier`, which `MoqtSession` is written against.
//
// This one is expressed in MOQT *operations* instead: announce, subscribe,
// subscribe to a namespace prefix, fetch, write objects. The reason to put a
// seam here rather than only at QUIC is that an in-memory relay can satisfy
// these honestly, which is what lets the room model, layer selection, mute, and
// moderation be tested end to end with no socket involved. `MoqomLoopback` is
// that implementation and `MoqtSession` is the real one.

import Foundation
import MoqomCore

/// Establishes MOQT sessions.
public protocol Transport: Sendable {
    /// Open a session to a relay.
    ///
    /// Steering is the caller's concern: by the time this is called the
    /// director has already chosen which relay to use, so this takes an
    /// endpoint rather than a service name.
    func connect(
        to endpoint: RelayEndpoint,
        credentials: DeviceCredentials
    ) async throws(MoqomError) -> any TransportSession
}

/// Where a relay is.
public struct RelayEndpoint: Hashable, Sendable {
    public let host: String
    public let port: UInt16

    /// ALPN identifiers offered, in preference order.
    ///
    /// Version negotiation is ALPN — moq-wg PR #499 removed it from SETUP
    /// entirely — so this list is the version list. Drafts use `moqt-NN`; the
    /// final RFC will use bare `moqt`. The default offers draft-22 first and
    /// falls back to MOQOM's draft-19 profile for relays not yet upgraded;
    /// the session speaks whichever the relay picks.
    public let alpn: [String]

    /// Whose relay this is, which decides what a session may ask of it.
    public let profile: RelayProfile

    /// The draft-16 PATH setup parameter: the path, with any query, a raw-QUIC
    /// client would have put in a URL. `nil` for relays that take their
    /// credential from the token instead.
    ///
    /// May hold a bearer credential, which is why ``description`` does not
    /// print it.
    public let path: String?

    public init(
        host: String,
        port: UInt16 = 443,
        alpn: [String] = ["moqt-22", "moqt-19"],
        profile: RelayProfile = .moqom,
        path: String? = nil
    ) {
        self.host = host
        self.port = port
        self.alpn = alpn
        self.profile = profile
        self.path = path
    }

    /// A Cloudflare MoQ relay, which speaks draft-16 and authorises by a token
    /// in the setup PATH.
    ///
    /// - Parameter token: the JWT Cloudflare issued, sent as PATH `/<token>`.
    /// - Parameter host: the relay; the default is Cloudflare's public
    ///   draft-16 endpoint.
    public static func cloudflare(
        token: String,
        host: String = "draft-16.cloudflare.mediaoverquic.com",
        draft: CloudflareDraft = .draft16
    ) -> RelayEndpoint {
        RelayEndpoint(host: host, port: 443, alpn: [draft.alpn], profile: .cloudflare, path: "/" + token)
    }
}

extension RelayEndpoint: CustomStringConvertible {
    public var description: String {
        "\(host):\(port) \(alpn.joined(separator: ",")) \(profile)" + (path == nil ? "" : " path=<redacted>")
    }
}

/// The drafts Cloudflare's relay is reachable on that this SDK speaks.
///
/// Its own enumeration, rather than ``MoqtDraft``, so that asking for a draft
/// Cloudflare runs and this SDK does not is a compile error rather than a
/// failed handshake. Adding draft-18 is a case here and a dialect for it.
public enum CloudflareDraft: Sendable, CaseIterable {
    case draft16

    var alpn: String {
        switch self {
        case .draft16: "moqt-16"
        }
    }
}

/// Whose relay an endpoint is, and so which features a session can use.
public enum RelayProfile: Hashable, Sendable, CustomStringConvertible {
    /// A MOQOM relay: every feature this SDK has.
    case moqom
    /// Cloudflare's MoQ relay, as of its draft-16 deployment.
    case cloudflare

    /// What this relay does not implement, and so what a session refuses to
    /// ask of it.
    public var unsupported: Set<RelayFeature> {
        switch self {
        case .moqom:
            []
        case .cloudflare:
            // From Cloudflare's published draft-16 support matrix: no FETCH,
            // no REQUEST_UPDATE, no GOAWAY. MOQOM's admission (its token and
            // proof) and in-session renewal are MOQOM's own.
            [.fetch, .requestUpdate, .credentialRenewal, .goaway]
        }
    }

    public var description: String {
        switch self {
        case .moqom: "MOQOM relay"
        case .cloudflare: "Cloudflare relay"
        }
    }
}

/// A capability a relay may lack.
public enum RelayFeature: Hashable, Sendable, CaseIterable, CustomStringConvertible {
    /// FETCH, and with it catch-up on join and seeking back through a track.
    case fetch
    /// REQUEST_UPDATE, which is how a live subscription is paused and resumed
    /// (FORWARD) and how its priority is changed.
    case requestUpdate
    /// Replacing the session's credential without reconnecting.
    case credentialRenewal
    /// GOAWAY, the relay asking a client to move.
    case goaway

    public var description: String {
        switch self {
        case .fetch: "FETCH (catch-up and history)"
        case .requestUpdate: "REQUEST_UPDATE (pausing a subscription or changing its priority)"
        case .credentialRenewal: "renewing a credential in-session"
        case .goaway: "GOAWAY"
        }
    }
}

/// What the client presents to the relay.
///
/// The token is a CAT bound to a hardware key by its `cnf` claim, and
/// ``deviceKey`` is the key it is bound to. Holding the key rather than a
/// signing closure is deliberate: a proof carries the public half in its header,
/// so a closure that could only sign was never enough to build one, and the
/// closure that used to be here was consequently never called.
public struct DeviceCredentials: Sendable {
    /// The user this device belongs to.
    public let identity: ParticipantIdentity

    /// The encoded Common Access Token.
    public let token: Data

    /// The key ``token`` was issued to, which proves the token is this device's.
    ///
    /// `nil` presents no proof, and the relay then decides what that is worth:
    /// one in `bearer` or `observed` mode admits the session, one in `required`
    /// mode refuses it. That is the right answer for a loopback with no tokens
    /// at all, and the wrong one for anything shipping — see
    /// ``DeviceKey/installed(label:)``.
    ///
    /// It must be the same key across a renewal, because the replacement token
    /// commits to the same thumbprint. ``replacing(with:)`` keeps it for that
    /// reason.
    public let deviceKey: DeviceKey?

    /// When ``token`` stops being accepted, if the caller knows.
    ///
    /// Supplied rather than parsed out of the token, for the reason
    /// ``IssuedToken/expiresAt`` gives: a client that has to decode its own
    /// credential to find out when to replace it is a client that gets the
    /// decoding wrong once and then caches the mistake.
    ///
    /// `nil` means the SDK will not renew on its own. That is the right answer
    /// for a relay holding no verification keys, which accepts anything and
    /// enforces no expiry, and it is what every caller that predates renewal
    /// gets.
    public let expiresAt: Date?

    /// Produces a replacement credential, called shortly before the current one
    /// lapses.
    ///
    /// A closure rather than a token because the whole point is to obtain one
    /// later, and a closure rather than a `TokenService` because the SDK should
    /// not care where a credential comes from: a caller minting tokens from
    /// their own backend is the ordinary case, and
    /// ``TokenService/token(username:room:device:session:)`` is one
    /// implementation of this signature rather than the only one.
    ///
    /// `nil` disables renewal, and a session whose relay enforces expiry will
    /// then be closed when its token runs out. That is the honest outcome and it
    /// is why this is worth passing: the relay stopped treating a token's
    /// lifetime as a property of the handshake alone.
    public let renew: (@Sendable () async throws -> IssuedToken)?

    /// Where a room's end-to-end encryption keys are agreed, when the SDK is
    /// to manage them.
    ///
    /// Set, in a room whose token says encryption is required, and the room
    /// keys itself with MLS: no key passes through the application and none
    /// reaches MOQOM's servers, which only order and forward ciphertext. A key
    /// given to ``RoomSession/useEncryption(_:)`` overrides it. `nil` keeps the
    /// earlier behaviour, where a required room publishes nothing until the
    /// application supplies a key. ``TokenService/keyDelivery`` is MOQOM's.
    public let keyDelivery: (any MLSDeliveryService)?

    public init(
        identity: ParticipantIdentity,
        token: Data,
        deviceKey: DeviceKey?,
        expiresAt: Date? = nil,
        renew: (@Sendable () async throws -> IssuedToken)? = nil,
        keyDelivery: (any MLSDeliveryService)? = nil
    ) {
        self.identity = identity
        self.token = token
        self.deviceKey = deviceKey
        self.expiresAt = expiresAt
        self.renew = renew
        self.keyDelivery = keyDelivery
    }

    /// The same credentials carrying a token that has just been issued.
    ///
    /// Keeps the identity, the key and the renewal closure, which is what makes
    /// renewal repeatable: the replacement has to be able to replace itself, and
    /// to prove itself with the key the new token was issued to.
    public func replacing(with issued: IssuedToken) -> DeviceCredentials {
        DeviceCredentials(
            identity: identity,
            token: issued.token,
            deviceKey: deviceKey,
            expiresAt: issued.expiresAt,
            renew: renew,
            keyDelivery: keyDelivery
        )
    }
}

/// A live MOQT session.
///
/// Everything is `async` and there are no completion handlers, including on the
/// paths where a callback would be marginally cheaper. Mixing the two styles in
/// one SDK forces every consumer to bridge somewhere, and the bridge is always
/// written by the person least equipped to get the cancellation semantics
/// right.
public protocol TransportSession: Sendable, AnyObject {
    /// What the peer agreed to at SETUP.
    var negotiated: NegotiatedParameters { get async }

    /// The session ending without anyone having asked it to.
    ///
    /// Yields at most once and then finishes; a session closed through
    /// ``close(code:reason:)`` finishes it without yielding. ``MoqomSession``
    /// reconnects on whatever arrives here, so the two cases have to stay
    /// distinguishable — the alternative is a redial on every clean exit.
    var interruptions: AsyncStream<TransportFailure> { get }

    /// Announce a namespace, making its publisher visible to prefix
    /// subscribers. Releasing the handle withdraws the announcement.
    func announce(_ namespace: TrackNamespace) async throws(MoqomError) -> any AnnouncementHandle

    /// Watch a namespace prefix.
    ///
    /// This is the roster: a participant appears because they announced, and
    /// disappears because they withdrew. There is no separate roster protocol
    /// and therefore no roster that can disagree with who is actually
    /// publishing.
    func announcements(
        matching prefix: TrackNamespace
    ) async throws(MoqomError) -> AsyncStream<AnnouncementEvent>

    /// Subscribe to one track.
    func subscribe(
        _ request: SubscribeRequest
    ) async throws(MoqomError) -> any SubscriptionHandle

    /// Tracks the peer has pushed without being asked for them.
    ///
    /// Draft-19's server-initiated PUBLISH, and the only way a relay can tell a
    /// session something it did not ask about. MOQOM uses it for exactly one
    /// thing — see ``ParticipantPolicy`` — because it is the only mechanism
    /// that reaches a participant who is publishing and subscribing to nothing
    /// relevant, which is precisely the person a moderator wants to mute.
    ///
    /// Each offer's objects begin flowing whether or not anybody reads them, so
    /// a consumer that ignores this stream costs a bounded buffer and nothing
    /// else.
    var offers: AsyncStream<TrackOffer> { get }

    /// Ask for objects that have already been published.
    ///
    /// The counterpart to `subscribe`, and the only way to get anything the
    /// publisher sent before we arrived. A subscription starts at the live edge
    /// by construction; without this, joining a stream mid-group means waiting
    /// for the next keyframe before anything can be decoded.
    func fetch(_ request: FetchRequest) async throws(MoqomError) -> any FetchHandle

    /// Begin publishing one track.
    func publish(
        _ track: FullTrackName,
        priority: UInt8
    ) async throws(MoqomError) -> any TrackWriter

    /// Hand the relay a replacement credential without reconnecting.
    ///
    /// The relay closes a session when the token that admitted it runs out, so
    /// on a long call this is what keeps it open. Both halves are needed and
    /// neither is any use alone: enforcing an expiry without renewal would end
    /// every call at the token's lifetime, and renewing without enforcement
    /// would be ceremony.
    ///
    /// Travels as a `REQUEST_UPDATE` carrying an authorization token parameter,
    /// which is draft-19's mechanism for it — there is no session-level message
    /// for a credential, and the update exists precisely because a token is a
    /// parameter of a request that may outlive it. That has a consequence worth
    /// knowing: it needs a request stream to write on, so a session that is
    /// announcing nothing, watching nothing and subscribed to nothing cannot
    /// renew. In practice every participant watches a namespace to learn who
    /// else is in the room.
    ///
    /// - Throws: ``MoqomError/invalidState(expected:actual:)`` when there is no
    ///   request stream to carry it.
    func renewCredential(_ token: Data) async throws(MoqomError)

    /// Close the session.
    ///
    /// `code` and `reason` land in the peer's `applicationError`. They are not
    /// how a moderated stream communicates its reason — that goes out as media
    /// on the lifecycle track first, so it arrives before the teardown rather
    /// than being indistinguishable from a dead network.
    func close(code: UInt64, reason: String) async
}

/// What SETUP settled.
public struct NegotiatedParameters: Hashable, Sendable {
    /// The ALPN the peer chose.
    public let alpn: String

    /// Whether the peer will accept objects over datagrams.
    public let supportsDatagrams: Bool

    /// Largest datagram payload the path will carry, if any.
    public let maximumDatagramSize: Int

    public init(alpn: String, supportsDatagrams: Bool, maximumDatagramSize: Int) {
        self.alpn = alpn
        self.supportsDatagrams = supportsDatagrams
        self.maximumDatagramSize = maximumDatagramSize
    }
}

/// Keeps a namespace announced for as long as it is held.
public protocol AnnouncementHandle: Sendable, AnyObject {
    var namespace: TrackNamespace { get }

    /// Why the relay refused this announcement, once it has said so.
    ///
    /// Suspends until there is an answer, and answers `nil` when the
    /// announcement ends without ever having been refused — so this is the
    /// outcome of the announcement rather than a poll, and belongs in a task
    /// beside the publisher rather than in front of it.
    ///
    /// Waiting is the only way to ask. A relay that accepts a namespace sends
    /// nothing at all, because the stream carrying the announcement stays open
    /// for exactly as long as the announcement stands; the single frame it will
    /// ever write there is a refusal. There is no acknowledgement to wait for
    /// and therefore no way to confirm acceptance quickly, which is why
    /// ``Transport/announce(_:)`` returns a handle without blocking and reports
    /// the refusal here instead.
    var refusal: MoqomError? { get async }

    func withdraw() async
}

public extension AnnouncementHandle {
    /// Never refused, for transports that cannot refuse. The loopback is the
    /// case that matters: it has no tokens and no policy, so an announcement
    /// there is accepted by construction.
    var refusal: MoqomError? {
        get async { nil }
    }
}

/// A namespace appearing under or leaving a watched prefix.
public enum AnnouncementEvent: Hashable, Sendable {
    case announced(TrackNamespace)

    /// A namespace is no longer served, and why, if the relay said.
    ///
    /// The reason is what makes this actionable rather than merely informative:
    /// see ``MoqomCore/WithdrawalReason``. `nil` from a relay that predates the
    /// extension, and treated the same as ``MoqomCore/WithdrawalReason/vanished``.
    case withdrawn(TrackNamespace, WithdrawalReason?)

    /// The namespace either way, for the common case of resolving who this is
    /// about before deciding what the event means.
    public var namespace: TrackNamespace {
        switch self {
        case let .announced(namespace), let .withdrawn(namespace, _): namespace
        }
    }
}

/// What to subscribe to, and how urgently.
public struct SubscribeRequest: Hashable, Sendable {
    public let track: FullTrackName

    /// Draft-19 subscriber priority. Lower is more urgent.
    ///
    /// This is what makes a grid behave correctly under congestion without a
    /// heuristic: the speaker's track outranks the thumbnails, so the relay
    /// sheds thumbnails first.
    public let priority: UInt8

    /// Drop objects that cannot arrive within this window rather than queueing
    /// them behind the live edge. A frame delivered after its deadline is not
    /// late, it is worthless.
    public let deliveryTimeout: Duration?

    /// Where in the track to begin.
    public let start: Start

    public enum Start: Hashable, Sendable {
        /// The next group the publisher opens.
        ///
        /// Right for live video: the current group is already partly gone, and
        /// the objects still in it reference a keyframe that will not be
        /// resent.
        case nextGroup

        /// The most recent complete group, replayed from its start.
        ///
        /// Right for anything where the current value is the point rather than
        /// the live edge — the catalog above all, where a viewer that waited
        /// for the next version would wait until the publisher happened to
        /// change something.
        case latestGroup
    }

    public init(
        track: FullTrackName,
        priority: UInt8 = 128,
        deliveryTimeout: Duration? = nil,
        start: Start = .nextGroup
    ) {
        self.track = track
        self.priority = priority
        self.deliveryTimeout = deliveryTimeout
        self.start = start
    }
}

public extension TransportSession {
    /// No offers, for a session whose peer never pushes.
    var offers: AsyncStream<TrackOffer> {
        AsyncStream { $0.finish() }
    }

    /// Accepted and discarded, for a transport with no credentials to replace.
    ///
    /// The loopback is the case that matters: it has no tokens and no expiry, so
    /// a renewal there is satisfied by construction. Succeeding rather than
    /// throwing is deliberate — a caller that wired up renewal correctly should
    /// not have to special-case running against an in-memory relay.
    func renewCredential(_: Data) async throws(MoqomError) {}
}

/// A track the peer opened on its own.
public struct TrackOffer: Sendable {
    public let track: FullTrackName

    /// Objects as they arrive, ending when the peer stops the offer.
    public let objects: AsyncStream<TrackObject>

    public init(track: FullTrackName, objects: AsyncStream<TrackObject>) {
        self.track = track
        self.objects = objects
    }
}

/// A live subscription.
public protocol SubscriptionHandle: Sendable, AnyObject {
    var track: FullTrackName { get }

    /// Objects as they arrive.
    var objects: AsyncStream<TrackObject> { get }

    /// Change priority without tearing the subscription down.
    ///
    /// Updates coalesce at the relay — a hundred queued priority changes need
    /// only the final value applied — so callers may drive this from a
    /// scroll position without rate-limiting it themselves.
    func updatePriority(_ priority: UInt8) async

    /// Ask the publisher to stop, or resume, sending this subscription's
    /// objects without ending it: draft-19's FORWARD parameter in a
    /// REQUEST_UPDATE.
    ///
    /// A request rather than a switch. A relay that does not act on it keeps
    /// sending, and one that does resumes at the start of the next group, not
    /// mid-group, because it forwards whole subgroups.
    func updateForwarding(_ forward: Bool) async

    func cancel() async
}

public extension SubscriptionHandle {
    /// Nothing to pause: a transport with no relay in it delivers only what
    /// it is given.
    func updateForwarding(_: Bool) async {}
}

/// What history to ask for.
public struct FetchRequest: Hashable, Sendable {
    /// The track, and the range within it.
    public let range: Range

    /// Draft-19 subscriber priority. Lower is more urgent.
    ///
    /// A fetch defaults to *less* urgent than a subscription, which is the
    /// opposite of what "the user is waiting for this" suggests. It is right
    /// anyway: catch-up competes with live media on the same link, and winning
    /// that competition means stalling the live edge to deliver the past.
    public let priority: UInt8

    /// Whether to walk groups forwards or backwards.
    ///
    /// Descending is for a seek backwards through history — the most recent
    /// group first, so something is on screen before the whole range arrives.
    public let order: GroupOrder

    public enum Range: Hashable, Sendable {
        /// An explicit span of a named track.
        case standalone(track: FullTrackName, from: Location, to: FetchEnd)

        /// The last `groups` groups before wherever a subscription is now.
        ///
        /// The catch-up case, and the reason to prefer it over a standalone
        /// fetch: the publisher resolves the range against the subscription's
        /// own position, so there is no window in which the live edge moves
        /// between working out what to ask for and asking for it.
        case joining(subscription: any SubscriptionHandle, groups: UInt64)

        /// From an absolute group up to wherever a subscription is now.
        ///
        /// The seek form. ``joining(subscription:groups:)`` asks for a distance
        /// back from the live edge, which is what a joiner wants because it does
        /// not know where the edge is; this asks from a group the caller has
        /// already seen, which is what resuming from a known position wants. Only
        /// the end is resolved against the edge.
        case joiningFrom(subscription: any SubscriptionHandle, group: UInt64)

        public static func == (lhs: Range, rhs: Range) -> Bool {
            switch (lhs, rhs) {
            case let (.standalone(a, b, c), .standalone(x, y, z)):
                a == x && b == y && c == z
            case let (.joining(a, b), .joining(x, y)):
                a === x && b == y
            case let (.joiningFrom(a, b), .joiningFrom(x, y)):
                a === x && b == y
            default:
                false
            }
        }

        public func hash(into hasher: inout Hasher) {
            switch self {
            case let .standalone(track, from, to):
                hasher.combine(0)
                hasher.combine(track)
                hasher.combine(from)
                hasher.combine(to)
            case let .joining(subscription, groups):
                hasher.combine(1)
                hasher.combine(ObjectIdentifier(subscription))
                hasher.combine(groups)
            case let .joiningFrom(subscription, group):
                hasher.combine(2)
                hasher.combine(ObjectIdentifier(subscription))
                hasher.combine(group)
            }
        }
    }

    public init(range: Range, priority: UInt8 = 200, order: GroupOrder = .ascending) {
        self.range = range
        self.priority = priority
        self.order = order
    }

    /// Catch up on the group a subscription is in the middle of.
    ///
    /// One group, because that is what buys a keyframe. Asking for more is a
    /// seek, not a join.
    public static func catchUp(
        on subscription: any SubscriptionHandle,
        groups: UInt64 = 1
    ) -> FetchRequest {
        FetchRequest(range: .joining(subscription: subscription, groups: groups))
    }
}

/// A fetch in progress.
public protocol FetchHandle: Sendable, AnyObject {
    /// The range the publisher agreed to serve, which is the requested range
    /// clamped to what exists. `nil` until FETCH_OK arrives.
    var served: FetchEnd? { get async }

    /// Objects and gaps, in the requested group order.
    ///
    /// The stream ends when the range does. Unlike a subscription's, this
    /// terminating is the normal outcome rather than a failure.
    var records: AsyncStream<FetchedRecord> { get }

    func cancel() async
}

/// What a fetch delivers.
///
/// Gaps are in the stream rather than filtered out of it, because a receiver
/// needs them: an object that is missing from history is never arriving, and a
/// decoder that waited for it would wait forever. Distinguishing "not there"
/// from "cannot say" matters for the same reason — the second is worth retrying
/// against another relay and the first is not.
public enum FetchedRecord: Hashable, Sendable {
    case object(TrackObject)

    /// Nothing exists from after the previous record through this location.
    case missing(through: Location)

    /// Nothing is *known* from after the previous record through this location.
    case unknown(through: Location)
}

/// Writes objects to a track.
public protocol TrackWriter: Sendable, AnyObject {
    var track: FullTrackName { get }

    /// Append an object to the current group.
    func write(_ object: TrackObject) async throws(MoqomError)

    /// Close the current group and start a new one at `group`.
    func startGroup(_ group: UInt64) async throws(MoqomError)

    func finish() async
}

/// One MOQT object.
///
/// The payload is opaque here on purpose. Encryption covers only the payload,
/// leaving group, object, and priority visible to the relay *and*
/// cryptographically authenticated as additional data — which is why caching,
/// deduplication, and priority scheduling survive end-to-end encryption intact.
/// Modelling the payload as anything richer than bytes at this layer would put
/// the SDK in a position to depend on plaintext it should not have.
public struct TrackObject: Hashable, Sendable {
    public let group: UInt64
    public let object: UInt64

    /// Draft-19 publisher priority. Lower is more urgent.
    public let priority: UInt8

    public let payload: Data

    /// Whether this object begins a decodable point.
    public let isKeyFrame: Bool

    /// Metadata the relay may read and the payload's encryption authenticates.
    public let properties: ObjectProperties

    public init(
        group: UInt64,
        object: UInt64,
        priority: UInt8 = 128,
        payload: Data,
        isKeyFrame: Bool = false,
        properties: ObjectProperties = ObjectProperties()
    ) {
        self.group = group
        self.object = object
        self.priority = priority
        self.payload = payload
        self.isKeyFrame = isKeyFrame
        self.properties = properties
    }
}

/// What travels alongside an object's bytes.
///
/// These go on the wire as MOQT object properties rather than inside the
/// payload, and the reason is end-to-end encryption. A relay has to schedule,
/// deduplicate, and drop objects it cannot read; a receiver has to know when a
/// frame should be presented before it can decrypt anything. Both need this
/// visible. Putting it in the payload would either break the relay or force it
/// to hold the key.
///
/// Being visible is not the same as being unprotected: SFrame authenticates
/// these as additional data, so a relay can read them and cannot alter them.
public struct ObjectProperties: Hashable, Sendable {
    /// When the frame was captured, on the publisher's clock.
    ///
    /// Presentation timing, not arrival timing. A receiver that paced from
    /// arrival would reproduce every jitter the network added.
    public var captureTime: FrameTimestamp?

    /// The parameter sets a decoder needs for this group, on its keyframe.
    ///
    /// Present so that a group can be decoded without reference to anything
    /// that arrived before it. The publisher's geometry is allowed to change
    /// while a track runs — a host switching layout — and when it does, the
    /// keyframe that opens the new geometry carries the configuration for it.
    /// A viewer therefore never has to wait for a catalog to catch up with a
    /// picture that has already changed shape.
    ///
    /// In ``DecoderConfiguration``'s length-prefixed form, and `nil` on
    /// everything but a keyframe.
    public var configuration: Data?

    /// `0` for the base layer, higher for frames nothing depends on.
    ///
    /// The relay drops the highest layer first under congestion, which lowers
    /// the frame rate rather than corrupting the picture — and it can do that
    /// without parsing a bitstream it may not be able to read.
    public var temporalLayer: Int?

    /// Whether an audio packet is the encoder's idea of silence.
    ///
    /// On the object rather than inside the payload because the receiver has to
    /// act on it before decoding: a packet that never arrived needs
    /// concealment, and one the publisher marked as silence needs quiet.
    /// Deriving it from the payload would mean decoding to find out, and
    /// deriving it from a missing sequence number is exactly the confusion this
    /// exists to prevent.
    public var isSilence: Bool?

    public init(
        captureTime: FrameTimestamp? = nil,
        configuration: Data? = nil,
        temporalLayer: Int? = nil,
        isSilence: Bool? = nil
    ) {
        self.captureTime = captureTime
        self.configuration = configuration
        self.temporalLayer = temporalLayer
        self.isSilence = isSilence
    }

    public var isEmpty: Bool {
        captureTime == nil && configuration == nil && temporalLayer == nil && isSilence == nil
    }
}
