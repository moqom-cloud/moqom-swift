// The seam the real client plugs into.
//
// A note on where this boundary sits, because the obvious place is not the
// right one. A "transport" protocol would naturally be QUIC-shaped — open a
// unidirectional stream, open a bidirectional stream, send a datagram, accept
// an inbound stream, reset. That seam exists and matters, but it belongs
// *below* this one, inside `moqom-client`, because the wire codec is written
// once in Rust and reused by every platform. Reimplementing draft-19 framing in
// Swift would give us a second decoder to keep in agreement with the first, and
// the README is explicit that the interop risk we are most exposed to is two
// implementations misreading the draft the same way.
//
// So `Transport` here is expressed in MOQT *operations*: announce, subscribe,
// subscribe to a namespace prefix, write objects. Those are exactly the calls a
// UniFFI binding over `moqom-client` will expose, and exactly what an in-memory
// loopback can satisfy honestly. Everything above this line — rooms, rosters,
// layer selection, mute, moderation — is Swift, is testable today, and is where
// the SDK's design decisions actually live.

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
    /// final RFC will use bare `moqt`.
    public let alpn: [String]

    public init(host: String, port: UInt16 = 443, alpn: [String] = ["moqt-19"]) {
        self.host = host
        self.port = port
        self.alpn = alpn
    }
}

/// What the client presents to the relay.
///
/// The token is a CAT bound to a hardware key by its `cnf` claim. The SDK never
/// holds the private key; signing a DPoP proof is a call into the Secure
/// Enclave, which is why ``proofSigner`` is a closure rather than key material.
public struct DeviceCredentials: Sendable {
    /// The user this device belongs to.
    public let identity: ParticipantIdentity

    /// The encoded Common Access Token.
    public let token: Data

    /// Produces a DPoP proof over the given challenge.
    ///
    /// A proof binds to the action and track rather than to the QUIC
    /// connection, so it is per-request rather than per-session.
    public let proofSigner: @Sendable (Data) async throws -> Data

    public init(
        identity: ParticipantIdentity,
        token: Data,
        proofSigner: @escaping @Sendable (Data) async throws -> Data
    ) {
        self.identity = identity
        self.token = token
        self.proofSigner = proofSigner
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

    /// Begin publishing one track.
    func publish(
        _ track: FullTrackName,
        priority: UInt8
    ) async throws(MoqomError) -> any TrackWriter

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
    func withdraw() async
}

/// A namespace appearing under or leaving a watched prefix.
public enum AnnouncementEvent: Hashable, Sendable {
    case announced(TrackNamespace)
    case withdrawn(TrackNamespace)
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

    public init(track: FullTrackName, priority: UInt8 = 128, deliveryTimeout: Duration? = nil) {
        self.track = track
        self.priority = priority
        self.deliveryTimeout = deliveryTimeout
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

    func cancel() async
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

    public init(
        group: UInt64,
        object: UInt64,
        priority: UInt8 = 128,
        payload: Data,
        isKeyFrame: Bool = false
    ) {
        self.group = group
        self.object = object
        self.priority = priority
        self.payload = payload
        self.isKeyFrame = isKeyFrame
    }
}
