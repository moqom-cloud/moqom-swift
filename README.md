# MoqomKit

The Apple-platform client SDK for [MOQOM](https://github.com/moqom-cloud/moqom),
the Media Over QUIC Orchestration Mesh. iOS, visionOS, macOS, and tvOS.

Documentation is at [moqom.dev](https://moqom.dev), starting with the
[iOS & macOS guide](https://moqom.dev/guides/ios-macos/).

## Install

In Xcode, **File → Add Package Dependencies…** and enter
`https://github.com/moqom-cloud/moqom-swift`, or in `Package.swift`:

```swift
.package(url: "https://github.com/moqom-cloud/moqom-swift", from: "0.1.0")

// in your target
.product(name: "MoqomKit", package: "moqom-swift")
```

## Quickstart

Your backend mints a token bound to this device's key (see
[moqom-go](https://github.com/moqom-cloud/moqom-go) or
[moqom-rust](https://github.com/moqom-cloud/moqom-rust)); the app connects, joins,
and goes live.

```swift
import MoqomKit
import MoqomCore

let deviceKey = try DeviceKey.installed()   // Secure Enclave where available
let issued = try await myBackend.moqomToken(room: "demo", thumbprint: deviceKey.thumbprint)

let session = MoqomSession(
    transport: MoqtTransport.network(),
    credentials: DeviceCredentials(
        identity: ParticipantIdentity(
            username: try Username(issued.username),
            device: try DeviceID(thumbprint: deviceKey.thumbprint)
        ),
        token: issued.token,
        deviceKey: deviceKey,
        expiresAt: issued.expiresAt,
        renew: { try await myBackend.moqomToken(room: "demo", thumbprint: deviceKey.thumbprint) }
    ),
    tenant: TenantID("t_3f9a0c1d2e4b5a69")
)
try await session.connect(to: RelayEndpoint(host: "relay.example.moqom.cloud"))
let room = try await session.join(room: RoomID("demo"))

let camera = try CameraSource(format: CaptureFormat(size: PixelSize(width: 1280, height: 720), frameRate: 30))
camera.start()
try await room.startBroadcast(from: camera).start()
```

The full walkthrough, including the backend half, is the
[quickstart](https://moqom.dev/getting-started/quickstart/).

## Where this came from

This was the first piece to leave the monorepo, and for a reason peculiar to
SwiftPM: it resolves a git dependency by looking for `Package.swift` at the
repository *root*, with no way to point at a subdirectory, so a nested package
cannot be consumed by URL at all. The rest followed later for their own reasons
— [`moqom`](https://github.com/moqom-cloud/moqom) is now the platform,
[`moqom-engine`](https://github.com/moqom-cloud/moqom-engine) the media path,
and [`moqom-go`](https://github.com/moqom-cloud/moqom-go) and
[`moqom-rust`](https://github.com/moqom-cloud/moqom-rust) the backend SDKs.

```sh
swift build
swift test
```

Swift 6 language mode, complete strict concurrency. The deployment floor is 26
on every platform — see [Why 26](#why-26) — so this needs a toolchain with a 26
SDK.

## Targets

| Target | What it is |
| --- | --- |
| `MoqomCore` | Namespaces, identity, layer ladders, frame and audio types, logging |
| `MoqomWire` | The MoQ Transport codecs for drafts 16, 19 and 22: varints, parameters, control messages, datagrams, subgroup streams |
| `MoqomKit` | Session, MOQT transport, rooms, publishing, subscribing, layer selection, SFrame, platform capture |
| `MoqomLoopback` | An in-memory relay and an in-memory QUIC carrier, so the tests exercise the whole stack |
| `MoqomDirectRust` | Optional. Direct paths over the Rust `moqom-direct-ffi` instead of `Network.framework`; present only when its xcframework is (see [Direct backends](#direct-backends)) |

## Status

There is a transport, and it has talked to something that is not itself.
`MoqtSession` speaks draft-19 over anything that provides QUIC streams,
`NetworkQUICCarrier` provides them from `Network.framework`, and `MemoryCarrier`
provides them from a buffer so the session is testable without a socket.
`Transport` remains a protocol and `MoqomLoopback` remains one of its
implementations, but it is no longer the only one.

Three tests connect to `moqom-relay` — the Rust relay from the platform
repository — over a real socket and check setup, announcement propagation, and
objects arriving under a rewritten alias. They are the only evidence that this
codec reads the draft the same way an independently written one does. See
[Interop](#interop).

The codec is a second implementation of draft-19, ported from the Rust
`moqom-proto` rather than bound to it. That is a cost — two implementations to
keep in agreement — paid because there is no C ABI to bind to, and because
`Network.framework`'s QUIC removes the reason to carry a Rust runtime on the
client at all. The ports are byte-checked against the Rust encoder's output in
`MoqomWireTests`.

The `Transport` seam still sits at MOQT *operations* — announce, subscribe,
subscribe to a prefix, write objects — rather than at QUIC streams, which is
what lets the loopback relay stand in for a network. The reasoning is at the
top of `Sources/MoqomKit/Transport/Transport.swift`.

### Verified: builds and is tested

957 tests across 145 suites. All but the three interop tests run on every
`swift test`; those need a relay binary and skip without one.

- **Namespaces and identity.** Tuple construction, field limits in UTF-8 bytes,
  Unicode canonicalisation, prefix matching, and recovering a participant from
  an announcement. Usernames are strings; there is no numeric UID anywhere and
  no place to add one.
- **A refused announcement.** That the relay's denial is read rather than
  dropped, and that it arrives naming the namespace it was about. This one is
  awkward by construction: a relay accepts by saying nothing, because the stream
  carrying the announcement stays open for as long as the announcement stands, so
  the only frame it ever writes there is a refusal. There is nothing to wait for
  on the way in and no acknowledgement to time out against, and the case is
  therefore easy to leave unread — which it was, and a publisher whose token
  named the wrong tenant encoded happily into a namespace the relay had dropped.
  Both directions are tested, because a peer that does acknowledge must not be
  mistaken for one that refused.
- **Session lifecycle.** A pure state machine over connected, reconnecting,
  away, and the four distinguishable terminal reasons, with time injected so
  the deadlines are testable without waiting.
- **Room model.** Rosters built from announcements, multi-device counting,
  backstage separation, the four kinds of mute, stage invitations and their
  expiry, capability-based moderation, and the subset rule that stops a cohost
  escalating to owner.
- **Watchdogs.** That a recorder is disclosed as room state and cannot be in
  the roster. This is structural — `Roster` cannot hold a `Watchdog` — so the
  test asserts the type system's guarantee rather than a runtime filter.
- **Render-aware layer selection.** Picking a rung from the box a view will be
  drawn into, at the right display scale; hysteresis that survives a window
  drag across a rung boundary; dropping video but keeping audio off screen;
  dividing a link estimate across the tiles actually being drawn; and degrading
  the overflow past a decode budget rather than refusing to subscribe.
- **The gallery.** Which sixteen of twenty participants get a tile, and the
  properties that make that usable: a speaker at the end of the alphabet gets
  one, an utterance from the overflow waits out the dwell before it moves
  anything, a pin does not wait, a tile does not move because somebody else
  started talking, a cohost who drops keeps their tile and is first to lose it,
  and a departure frees one immediately. Plus the column arithmetic — sixteen
  16:9 tiles on a portrait phone want two columns, not four, which is worth two
  and a half times the visible pixels and a rung on the ladder.
- **Active speakers.** Speech starting on a voiced packet and ending without one,
  because a publisher using DTX stops sending when it stops talking; silence
  packets not extending it; and recency outliving it, since that is what orders a
  quiet room. Then the whole path over loopback: the publisher's detector sets a
  flag, it survives the wire as an object property, and the subscriber turns it
  back into a speaking tile with no server having read the audio.
- **Loopback integration.** Going live populating other clients' rosters,
  announcement withdrawal emptying them, frames becoming objects, backpressure
  dropping the oldest frame, and — asserted explicitly — that per-viewer mute
  produces no relay traffic at all, and that a publisher never subscribes under
  its own namespace. The second is there because announcing is what fills the
  roster and this device announces itself, so the natural loop asks the relay to
  send back the catalog it just published; a few hundred bytes is small enough
  that only a test would notice.
- **The wire codec.** Varints against the RFC 9000 vectors, delta-encoded
  parameters, control message framing and its 64 KiB body limit, object
  datagrams, and subgroup streams with their delta-encoded object IDs. Byte
  sequences are pinned against the Rust implementation's output rather than
  against our own encoder, which would agree with itself either way.
- **MOQT sessions.** Two `MoqtSession`s connected over a `MemoryCarrier`:
  setup, announce and withdraw, prefix subscription including a subscriber that
  arrives late, subscribe and unsubscribe, object flow over both datagrams and
  subgroup streams, and a payload large enough to span reads.
- **FETCH.** A standalone fetch over a closed range, a joining fetch that hands
  back the groups preceding a live subscription, gap markers where the publisher
  no longer holds what was asked for, and a room-level seek. Also the case that
  cost a day: a rung change must not refetch the history of the rung being left.
- **Reconnection.** A carrier reporting its own loss, the session surfacing it,
  the retry driver backing off and giving up, a publisher re-announcing and
  republishing its catalog on the way back, a room rebinding subscriptions
  without the application laying out again, and closing during a pending
  reconnect not resurrecting the session.
- **Interop with the Rust relay.** Three tests over a loopback socket, described
  under [Interop](#interop).
- **The publish pipeline.** Group and object numbering across keyframe
  boundaries, priority per rung, and the object properties — capture time and
  temporal layer — surviving to the wire.
- **Reassembly.** Dropping what precedes the first keyframe, counting holes in
  object numbering, distinguishing the next group from a skipped one, and
  parameter sets arriving both from the catalog and on each keyframe — with the
  keyframe winning, because the catalog is a different track and can arrive after
  the media it describes. Plus a round trip: a broadcast through the real
  packetiser, the relay, and the real depacketiser, arriving as the frames that
  were encoded.
- **A live change of shape.** A host changing layout mid-call: the rung keeps its
  name and its short side, a new encoder overlaps only until its first keyframe,
  and the switch is a group boundary carrying the decoder configuration for the
  new geometry. Asserted from the viewer's side, which is where it matters — one
  reshape reported, no gap, frames either side of the seam, and a timeline that
  does not restart. Also that a single odd-sized frame is not a layout change,
  that a handover which loses its keyframe recovers rather than stalling, and
  that a viewer joining afterwards can decode a cached group from before it.
- **Audio.** Encoder framing, and a jitter buffer's fill behaviour, reordering,
  late and duplicate packets, gap concealment, and jitter estimate.
- **Voice activity.** That silence, a constant offset, and a steady room are all
  not speech; that speech over a loud room is; that a stream opening mid-sentence
  is not deaf; that a monologue does not teach the estimator its own voice is the
  room; and that a room which gets permanently louder is eventually learned
  rather than reported as speech forever. Levels are asserted as real dBFS, so
  the numbers can drive a meter.
- **Audio session purpose.** Which arrangement of the system each purpose asks
  for. Untested here is the graph itself, which needs a device; what is tested is
  the decision, because choosing wrongly does not look like a configuration bug
  from outside — a video call on the earpiece reads as broken hardware.
- **SFrame (RFC 9605).** Header encoding, key derivation, and AEAD against the
  RFC's test vectors; then through the room path, where the relay is asserted
  to see only ciphertext and tampering with an object's group, object number,
  priority, or properties is asserted to fail authentication. Also what it
  costs, because "does encryption add lag" deserves a number rather than a
  reassurance: roughly 7µs fixed per object plus 0.25µs per KB, so 7.5µs on an
  Opus packet and 54µs on a 1080p keyframe, against a 33ms frame budget. The
  cost that is actually worth caring about is the 19 bytes per object, which is
  under 1% of a video object and about a third of an Opus packet. And that
  arriving out of order is not mistaken for a replay, since subgroups ride
  separate QUIC streams and a strict counter rule would read reordering as loss.
- **Proof of possession.** Relays require it by default
  (`MOQOM_RELAY_POSSESSION=required`), so a token presented without a proof from
  the key it is bound to is refused. Tested: that a session presents a proof beside its token at
  SETUP and a fresh one on every renewal, and that the proof verifies: the
  signature is checked under the key the proof carries, the RFC 7638 thumbprint
  of that key is recomputed canonically, and the claims are matched — which is
  the relay's own check, written a second time in Swift so a client-side
  encoding mistake fails in `swift test` rather than as a refused handshake with
  the reason in a Rust log. Then across languages, which is the check the other
  one cannot make: `ProofInteropTests` writes proofs and thumbprint vectors into
  `moqom-relay/tests/testdata/possession.json`, and the relay's own tests verify
  every proof in it while Go recomputes every thumbprint — so a client and a relay
  written from the same description cannot quietly disagree about the one detail
  nobody wrote down. The anchor is RFC 7638's worked example, pinned in all three.
  `DeviceKey` generates the key in the Secure Enclave, records where it ended up
  when it could not, and the sample's join screen prints both.
- **The catalog.** Document round trips and determinism, refusing a future
  version, per-version groups, and — the one that matters — a viewer's ladder
  coming from the publisher's catalog rather than from `.defaultCamera()`.
- **Bandwidth estimation.** Steady arrival, rising delay being read as
  congestion, recovery, a single late frame not triggering a downgrade, and a
  layout decision that uses the measurement rather than an app-supplied number.
- **Statistics and quality.** One snapshot carrying the link, the uplink, every
  participant and the control track, read at one instant. Then the judgement
  calls, which are the part worth testing: a room that has measured nothing
  reports `unknown` rather than `bad`, a controller backing off costs one level
  and cannot on its own reach `bad`, and a participant's own loss overrides the
  room aggregate so one cohost on a train does not pull every tile down with
  them. Also that a quality change is emitted once rather than per sample, and
  that a client which has not yet received its first control snapshot wants one
  without having a gap.
- **Logging.** That a suppressed record is never built — neither its message nor
  its fields — because this is called per object. That a payload can only be
  written as a byte count, which is a property of the type rather than of the
  call sites. That hashed identities stay stable across processes so two lines
  about one person remain joinable, and that two devices of one user do not
  collapse into each other. And that the default logger writes nothing at all.
- **Raw media taps.** The four points where frames and samples leave the SDK for
  somebody else's processing, and the three claims the contract makes about
  them. That a consumer which never reads loses its own frames and costs the
  publisher none — the invariant the whole design turns on. That asking for
  keyframes only genuinely declines the decode rather than filtering after it,
  which is what makes safety classification affordable. And that a tap in an
  encrypted room receives plaintext, because doing the inference on the device
  that holds the key is the only way end-to-end encryption and content
  classification can both be true. Plus the arithmetic that is easy to get
  wrong: ten frames a second out of a thirty frame source is ten and not seven
  and a half, a stream that pauses for thirty seconds delivers immediately on
  resumption without then admitting everything, and stopping a tap or dropping a
  tile releases the decoder it was holding.
- **Picture in Picture casting.** Who the window draws, expressed as a rule
  rather than a list, so a cohost promoted while the window is open appears in
  it: the host alone, cohosts and guests, an explicit set, or any combination of
  those. The bounds are the interesting part. Four tiles is the ceiling because
  the PiP window is a fifth of the screen and a fifth tile is below any rung the
  ladder offers. A cast that follows the speaker keeps admitting them for six
  seconds after they stop, because `Gallery`'s dwell protects an occupant from
  being displaced and somebody the cast stopped admitting has not been displaced
  — they have left, and a one-tile window would go black in every gap between
  sentences. And the default cast admits everyone rather than naming roles,
  since roles come from grants that arrive on the control track a moment after
  the participant does, and a role-based default shows an empty window until
  then and forever in a room with no control authority.
- **Layout takeover.** That entering the window *replaces* the grid's reported
  geometry rather than adding to it, and that leaving restores it in one pass.
  This is the difference between a feature and a support ticket: backgrounding
  an app does not tear its views down, so every `GeometryReader` in the grid
  still holds the size it had when the user swiped home, and a window that only
  added four small boxes would keep paying for nine full-size streams to draw
  four thumbnails — on cellular, with the screen off, where nothing looks wrong.
- **Live Activity budget.** ActivityKit throttles updates and a broadcast
  generates changes far faster than any budget allows, so the policy is the
  feature and it is tested without a device. That an update nobody would notice
  is never sent, comparing at display precision so a viewer count ticking
  40,001 -> 40,002 under a card reading "40K" costs nothing while the fourth
  person joining a room of three costs one. That twenty active-speaker changes
  in two seconds cost one update rather than twenty. That an update held back
  for the interval still arrives, because a room where the speaker changes once
  and then falls silent would otherwise show the wrong name for the rest of the
  stream. And that the three changes a delay would make actively wrong — a mute
  the user just pressed, a recorder attaching, the stream ending — skip the
  queue.
- **End-to-end encryption by default.** `EncryptionPolicy` reads the room's
  `e2ee` claim from the token and nothing else, so there is no client-side
  switch to forget. A room is encrypted unless its owner's backend relaxed it,
  and that change is in the room's audit log. An SDK holding no key refuses to
  publish into a room that requires one.
- **MLS-managed room keys.** `ManagedRoomKeys` runs group membership for small
  encrypted rooms so an application never handles a key. Each epoch has its
  own SFrame keys. Senders switch the moment a removal is ordered, so a removed
  member's last key stops being used, and an ordinary epoch change drops no
  frames.
  `MLSGroup` is a deliberately small subset of MLS (RFC 9420). The primitives
  and key schedule are RFC 9420 and are checked against its test vectors
  (`MLSConformanceTests`); the group protocol keeps the RFC's epochs, commits,
  Welcomes and transcript hashes but uses a flat member list instead of a
  ratchet tree. The comment at the top of `MLSGroup.swift` lists what differs.
  `MLSDelivery` is the ordering service: it only ever sees public key packages
  and sealed commits, never anything that derives a key. The committer is the
  lowest live leaf, with a fallback, so there is no election.
  Groups are founded in a hybrid post-quantum suite,
  `MLS_128_MLKEM768X25519_AES128GCM_SHA256_Ed25519` from
  draft-ietf-mls-pq-ciphersuites (the X-Wing KEM: ML-KEM-768 with X25519).
  The draft has no code point yet, so MoqomKit uses `0xF0A1` from RFC 9420's
  private-use range, and no other MLS implementation will recognise it. Every
  commit secret and joiner secret is sealed to X-Wing, so the epoch secrets
  and the SFrame keys derived from them stay confidential unless both
  ML-KEM-768 and X25519 are broken. Signatures are not post-quantum: MLS
  signatures are Ed25519, device proofs are ES256, and tokens are EdDSA. They
  authenticate members during a call, and breaking one later would not
  decrypt recorded traffic. Suite `0x0001` still works for existing groups. A
  group keeps one suite for its whole life, and a key package in another suite
  is refused. X-Wing makes a key package about 2.5 KB and adds about 1.2 KB per
  member to each commit and Welcome. `MLSHybridSuiteTests` checks CryptoKit's
  X-Wing against the HPKE working group's KEM `0x647a` test vector.
- **Direct (peer-to-peer) calls**, in `Sources/MoqomKit/Direct/`. Wire-compatible
  with the Rust client's `moqom_client::direct`, so either SDK can be either
  end:
  - `DirectEligibility`: small, end-to-end encrypted rooms where everyone has
    agreed and nobody is an audience. Viewers never get a direct path, because
    it would tell them the publisher's network address.
  - `CandidateOffer` and `DirectOffers`: addresses and a certificate hash,
    sealed with AES-256-GCM under a key from the room's MLS group and sent on
    the participant's own track. The relay carries them and cannot read or
    forge them.
  - `DirectEndpoint`: one UDP port, STUN, hole-punching (the lower certificate
    hash dials), then pinned mutual TLS against the hash in the offer, and a
    MOQT SETUP carrying the MOQOM token plus a proof bound to the peer's
    certificate.
  - `DirectPeerCheck`: a port of the relay's token and possession checks, with
    the proof required. A refused peer is closed with `0x03`.
  - `DualSubscription`: the relay subscription stays open as the fallback. Once
    the direct path keeps up, the relay copy is paused with `FORWARD=0`, and it
    resumes on loss or after 500 ms of direct silence.
  - `DirectTicket`: the relay signs a ticket about once a minute while a
    participant is direct, and meters direct minutes from it. Each side presents
    its tickets to the other and drops the direct path when the peer's are
    missing, forged or expired, so one honest app is enough to keep the pair
    billed.

  #### In a room

  On by default. `MoqomSession(directPolicy:)` is `.automatic` unless the app
  says otherwise, and a 1:1 call or a small private room moves to direct paths
  wherever it qualifies. Choosing automatic accepts, on the user's behalf, that
  the other participants of such a room learn this device's IP addresses, so
  say so in the app; `.relayOnly` never offers them:

  ```swift
  let session = MoqomSession(
      transport: transport,
      credentials: credentials,      // authorityKeys: what peers are verified against
      tenant: tenant,
      directPolicy: .automatic(stun: (host: "stun.example.com", port: 3478)) // or .relayOnly
  )
  let room = try await session.join(room: "standup")
  for await event in room.events {
      if case let .directPathChanged(who, path) = event { print(who, path) } // relay(why) / connecting / direct
  }
  ```

  `join(room:directPolicy:)` overrides the session's policy for one room, and
  `.custom(DirectRoomOptions(...))` sets every option by hand.
  `RoomSession.setDirect(_:)` does the same on a room already joined, and `nil`
  turns it off. The room's own policy from the control plane, which comes
  with each token (`IssuedToken.direct`), can lower the participant limit or
  keep the room on the relay, and a renewed token that changes it reaches a
  room in progress. Opting in is published as `direct: true` on this device's
  catalog, which is how the others count it. The room then applies
  `DirectEligibility` as it stands: end-to-end encryption required and in use,
  no watchdog, this device publishing, at most four participants (fewer if the
  room's policy says so), and
  every one of them opted in. Participants are everyone publishing where this
  device publishes (on stage, or backstage with the other cohosts there) plus
  every member of the room's MLS group, so a viewer holding the room's keys
  keeps the room on the relay. While the rules hold, for each other
  participant the room:

  - binds an endpoint on the session's `directBackend`, sends its sealed offer
    on this participant's `.direct` track every second until the peer answers,
    reads the peer's, and establishes with the newest offer it hasn't tried;
  - once up, subscribes on its own relay to its ticket track
    `.direct/{peer}`, presents its tickets and holds the peer to theirs
    (`DirectTicketGuard`). It closes that subscription when the path ends;
  - publishes every media track on the direct session as well as the relay.
    The copy is made under the encryption, so both paths carry the same
    ciphertext with the same object numbers. A stalled direct path drops its
    own queued objects and never holds up the relay;
  - reads each of the peer's tracks through a `DualSubscription`, the relay
    subscription staying the one of record.

  Any end of the path (the guard, the session closing, the peer offering a
  new endpoint, the room no longer qualifying) leaves media
  on the relay and calls `networkChanged()` on the merges. Another attempt
  follows after a backoff that starts at `retry` (2 s) and doubles up to a
  minute. A departure or `leave` tears that participant's path down, tickets
  included. A new MLS epoch reseals the offers and offers again to anyone not
  yet direct. Paths already up are kept. `RoomSession.directPaths` gives each
  participant's state and how many objects came over each path.

  The offer key is an MLS exporter secret from the managed group
  (`MLS-Exporter("MOQOM direct offer", "", 32)`), run through
  `DirectRoomSecret`'s HKDF. A room keyed by the app instead (`useEncryption`)
  passes `offerSecret`, or it reports `awaitingKeys`.

  `DirectEndpointTests` runs two endpoints over loopback on macOS, and
  `DirectRoomTests` runs whole rooms on the loopback relay with a stand-in
  ticket issuer. It covers two people going direct, a viewer staying on the
  relay, a participant who hasn't opted in keeping everyone there, fallback
  when the session is killed, lapsed tickets and leaving.
  `RustDirectRoomTests` repeats the first case on the Rust backend. None of
  this has run across real networks.

  #### Direct backends

  `DirectEndpoint` is the MOQT half of a direct path. The socket under it —
  the port, the certificate, probing, dialling and accepting — sits behind
  `DirectSocketProvider` and `DirectSocket`, and is chosen when the SDK is
  made:

  ```swift
  import MoqomDirectRust

  let session = MoqomSession(
      transport: transport, credentials: credentials, tenant: tenant,
      directBackend: .rust
  )
  let endpoint = try await session.bindDirectEndpoint(configuration, eligibility: eligibility, exposure: exposure)
  ```

  - `.networkFramework`, the default, is the code that was there before,
    moved rather than rewritten: the accepting side probes in a burst only,
    and the listener is cancelled before dialling. `DirectEndpointTests` runs
    on it unchanged.
  - `.rust`, from `MoqomDirectRust`, is quinn behind `moqom-direct-ffi` in
    `moqom-engine`. One socket listens and dials at once, so it probes on
    both sides for the whole of establishment, and it carries QUIC datagrams.
    `RustDirectBackend.isCompatible` checks the library's ABI version; a
    mismatch fails `bind` instead of calling into it.
  - `.custom(_:)` takes any other `DirectSocketProvider`.

  The module exists only when the xcframework does, so a checkout without it
  builds exactly as before. `Scripts/direct-ffi.sh` runs the engine's
  `build-apple.sh` and copies `MoqomDirectFFI.xcframework` into `Artifacts/`
  (ignored by git), which the manifest looks for; `--copy` skips the build
  and `--remove` takes it out again. The manifest is sandboxed and cannot see
  the sibling repository, so the alternatives are environment variables:
  `MOQOM_DIRECT_RUST=1` uses `../moqom-engine/target/MoqomDirectFFI.xcframework`,
  and `MOQOM_DIRECT_FFI_XCFRAMEWORK` names any relative path. SwiftPM caches
  the manifest's answer, so after the framework appears or goes, run
  `swift package purge-cache` (the script does). iOS and macOS only: the
  engine builds no visionOS or tvOS slices, and the Rust target links the
  framework on those two platforms alone.

  `MoqomDirectRustTests` establishes a direct session for every pairing —
  Rust to Rust, `Network.framework` dialling Rust, and Rust dialling
  `Network.framework` — and in each sends media both ways and refuses a
  viewer, an impostor and the wrong certificate. Below MOQT it checks
  bidirectional and 300 KB unidirectional streams, finish, reset, datagrams,
  and that a deliberate close is not reported as loss. All of it passes on
  macOS, from both the `Artifacts/` copy and `MOQOM_DIRECT_RUST=1`. Three
  things it found:

  - `NWConnectionGroup` opens a bidirectional stream of its own and never
    writes to it, and quinn hands that stream to the acceptor first, ahead
    of the control stream. `RustQUICCarrier` therefore offers an inbound
    bidirectional stream only once it has carried a byte or ended. The Rust
    client's `moqom_client::direct` accepting from this SDK's
    `Network.framework` backend should have the same problem, and that has not
    been tested.
  - A reset from a `NetworkQUICCarrier` stream, on the side that accepted,
    never reaches a Rust reader while the stream is open. It is recorded as a
    known issue, not a pass.
  - On the iOS Simulator, the refusal scenarios crash inside
    `NetworkQUICCarrier.close`, which sets the application error on a
    connection the peer has already closed, and `Network.framework` traps.
    It happens with `Network.framework` on both ends as well, so the Rust
    backend did not cause it, but nothing had run those paths on iOS
    before. The scenarios without a `Network.framework` acceptor pass
    there. `MoqomDirectRust` builds for iOS devices and the simulator, and
    has not run on a phone.
- **Space edits, events and playout.** `SpaceEdit` adds spawn, move, despawn
  and event without the app writing a simulation; the simulation can still
  refuse them. `SpaceEvents` delivers moments (a goal, a turn) exactly once and
  in order, alongside the forgiving state ticks. `SpacePlayout` interpolates
  ticks for smooth drawing, and can hold the board in step with the video
  beside it.
- **Grant changes mid-session** (`GrantChangeTests`). A viewer promoted to
  guest, or sent back to the audience, stays on the same connection. The new
  token is presented there, the next renewal mints the new role, and a
  publication the relay withdraws is stopped instead of encoding into nothing.

### Verified on two phones, not by the test suite

Written against the platform frameworks, compiled on every build, and driven end
to end on hardware — a 15 Pro and an iPhone Air, in calls through the Compute
Engine relay in Los Angeles. None of it is covered by `swift test`, and that
distinction is worth keeping rather than blurring: a run on two phones is an
observation, not a regression guard. It says these paths worked on that day, on
those handsets, on that network. It will not tell anybody the day one of them
stops working.

What the runs produced is in the sample's own readout: 540p at 60 frames a
second, 600 kbps, and 69 ms from glass to glass, with lip sync stated as a signed
number beside it. Those figures cannot exist unless capture, encode, the wire,
decode, and display all ran, which is why they are quoted here instead of a
claim. This section used to say the whole list had never executed, while two of
its own entries described measurements taken on two phones — the list had simply
not been revisited after the phones started working.

- `Platform/VideoEncoder.swift` — VideoToolbox with low-latency rate control,
  frame reordering off, and a temporal base layer. The session creation and its
  fallback do run in the simulator, which has an encoder for both codecs and a
  low-latency one for neither; encoding itself took a device, and has had one.
- `Platform/PlatformAudioEncoder.swift` — Opus through AudioToolbox.
- `Platform/AudioGraph.swift` — the one `AVAudioEngine` capture and playback
  share, which is what makes echo cancellation possible: the canceller subtracts
  what the speaker played, so a player on a second engine is audio it cannot
  subtract. Also the audio session, voice processing, and reinstalling the tap
  across route changes and interruptions. Playback is a render callback pulling
  from a ring per participant, rather than buffers scheduled onto a player node:
  a pushed queue is as deep as the last burst left it and stays that way, which
  put a fifth of a second between a face and its voice on two phones and, in one
  direction, half of one.
- `Platform/AudioPlayer.swift` — the depth that ring is held at. It follows the
  jitter buffer's target, grows when the device asks for samples that are not
  there, and comes back down by dropping silence once a talker has stopped —
  which is inaudible, and is the only way the delay a burst added is ever given
  back. Capture timestamps are quoted on the host clock, the same one the camera
  uses, so a receiver can put a voice beside a face; `MoqomRoom` prints the
  result as `SYNC`, signed, with both halves of the arithmetic beside it.
- `Platform/MicrophoneSource.swift` — the `AudioSource` a publication takes,
  over the shared graph.
- `Platform/SceneCapture.swift` — a pooled, IOSurface-backed blit from a
  renderer's `MTLTexture`. The frame never leaves the GPU.
- `Platform/RealityKitCapture.swift` — `RealityView`'s
  `renderingEffects.customPostProcessing` via `SceneCaptureEffect`, plus the
  same handoff through `ARView.renderCallbacks.postProcess` for UIKit hosts.
- `Platform/CameraSource.swift` — `AVCaptureSession` in the encoder's pixel
  format.
- `Platform/VideoRenderer.swift` — sample buffer assembly and
  `AVSampleBufferDisplayLayer`. The preview path draws in the simulator; the
  decode path took a stream from a real encoder, and has had one.
- `Platform/VideoDecoder.swift` — the `VTDecompressionSession` a receive tap
  decodes through, including the rebuild a rung change forces. Exists because
  the display layer decodes privately and returns nothing, so anything wanting
  pixels has to own a session. The tap machinery around it is tested with an
  injected decoder; this file took a real bitstream, and has had one.
- `Subscribe/LayoutObserver.swift` — the SwiftUI modifier that reports a tile's
  size to the layer selector. The takeover half of it is tested; the modifier
  took a view hierarchy, and the sample has given it one.
### Verified: compiles, never runs

The two features whose entire purpose is what happens after the user leaves the
app, which is exactly what neither a simulator nor a phone on a desk in front of
somebody demonstrates. Both are built and wired; neither has been seen.

- `Platform/PictureInPictureController.swift` — `AVPictureInPictureController`
  with a video-call content source, and a grid of `AVSampleBufferDisplayLayer`s
  inside it. The layers are borrowed from the renderers the grid was already
  using rather than built fresh, because a second layer for the same
  participant is a second hardware decode of the same subscription. Notably not
  a composite: drawing four participants into one buffer is app GPU work, and an
  app that submits GPU work in the background is terminated — which is fatal for
  a feature whose whole purpose is to run in the background, and invisible in a
  simulator, where the rule is not enforced.
- `Platform/BroadcastLiveActivity.swift` — ActivityKit. The card's clock is a
  date rather than a duration so `Text(timerInterval:)` counts on its own, which
  turns the single largest consumer of the update budget into nothing. Push
  tokens are read from `pushTokenUpdates` rather than from the property, which
  is always `nil` immediately after starting and rotates mid-activity — an app
  that reads it once ends up with a control plane pushing into a dead token and
  no error anywhere to explain the silence.

### Not written

- Direct paths in a room are on by default (`DirectPolicy.automatic`) and
  still partial:
  - Automatic needs `DeviceCredentials.authorityKeys` to verify a peer with;
    a session without them stays on the relay. It offers only this device's
    own addresses unless the app passes `.automatic(stun:)`, and MOQOM runs
    no STUN service, so out of the box a direct path opens on the same
    network and falls back to the relay behind a NAT.
  - The room's policy (`direct_paths`, `max_direct_participants`) reaches the
    device through the token service's `direct` field. A backend that mints
    through the admin API has to pass `MintClientTokenResponse.direct` on
    itself; one that does not leaves the SDK's own default, allowed for up to
    four. The relay refuses direct tickets in a relay-only room, so a
    modified client cannot keep a path there either.
  - Backstage pairs only with backstage, and a device starts watching the
    backstage prefix only once it publishes there. A stage device and a
    backstage one stay on the relay with each other.
  - The Rust client has the same policy type and room limit
    (`moqom_client::direct::DirectPolicy`) but isn't wired into a room, so
    nothing on that side derives the offer key from the MLS exporter yet.
  - On the loopback relay `FORWARD=0` does nothing, so the 500 ms quiet resume
    is covered only by the `DualSubscription` tests in `DirectTests`.
- Media kinds are not enforced per track. `moqt.pub` distinguishes audio from
  video from screen, and the relay checks only that it is non-empty, so a token
  minted for audio can publish video under a namespace it does own.
- A relay with no verification keys authorises everything. That is the default,
  and it is what the loopback and the benchmarks run against. It is the right
  default for a laptop and the wrong one to ship, and the only thing standing
  between the two is an environment variable.
- Datagram media over a real carrier. `MoqtSession` sends and receives object
  datagrams, and the tests for that path all run over `MemoryCarrier`; the relay
  forwards subgroup streams only, so the interop tests do not cover it.
- Fetch against a relay over a real socket. Both sides are now written — the
  client asks and answers fetches, and the relay retains groups to answer with —
  but the interop tests do not yet cover the pair, so the evidence that they
  agree is still two test suites rather than one.
- Round-trip time. `Network.framework` does not surface a QUIC RTT estimate, so
  the client reports the one-way delay gradient it can measure and leaves true
  RTT to the relay, which has the QUIC state machine in reach. Pairing a client
  snapshot with the relay's view of the same session is the intended way to
  answer "them or me", and nothing automates that yet.

## What still has not run

The iOS branches compile, the sample builds and publishes, the UI tests drive it
on a simulator, and two phones have held camera and AR calls through a relay in
another city. What remains unobserved is narrower than it was, and specific:

- **A network that misbehaves on purpose.** The runs to Los Angeles put real
  packets over a real path, which is the thing the loopback interface could never
  be, and they were measured on a good Wi-Fi connection having a good day. Loss,
  reordering, and a path that changes mid-session — the walk out of the house
  that hands a call from Wi-Fi to cellular — are all still unmeasured, and they
  are what a congestion controller would be judged on. Distance is no longer the
  gap; adversity is.
- **Camera switching and rotation.** Flipping between front and back has never
  been executed, and the parts most likely to be wrong are the ones only hardware
  reaches: whether the reconfiguration is quick enough not to stall the encoder,
  whether the two cameras agree on a format, and whether the preview transform
  survives. Rotation is not handled at all — `CameraSource` never sets the
  capture connection's rotation angle, so a portrait phone publishes a sideways
  picture.
- **The Secure Enclave branch of `DeviceKey`, under `swift test`.** Every test of
  it constructs its key from material a caller supplies, which is the software
  branch by definition — so what they prove is that the two kinds produce the
  same thumbprint and the same proof, not that `installed()` can obtain either.

  Two claims that stood here were wrong, and both were corrected by running the
  sample rather than by reading it. The first said the enclave path had never
  run: it has, on both phones, and a relay set to
  `MOQOM_RELAY_POSSESSION=required` admitted them and relayed between them —
  which it does only after recomputing the RFC 7638 thumbprint of the key that
  signed the proof and matching it to the token's `cnf.jkt`. So an enclave key
  was generated, signed, and had its signature verified by another
  implementation.

  The second said a simulator has no enclave and therefore exercises the
  Keychain fallback. On Apple silicon it reports one and takes that branch: the
  sample's join screen prints an enclave-backed thumbprint on a simulator, which
  is how the claim was found to be false. The fallback is the path that has now
  never run anywhere — and it had never *worked* anywhere either, since the app
  carried no entitlement and so could store neither kind of key. That is fixed,
  and the lesson is the one this whole section is about: the branch nobody can
  reach is the branch nobody notices is broken.

  What is still missing is a check that runs by itself. Reading a thumbprint off
  a screen is two people-minutes and will not notice the day either branch
  breaks.
- **A backgrounded app.** Picture in Picture and Live Activities are both
  features about what happens after the user swipes home, and the simulator does
  not enforce the rules that make that interesting: background GPU work is
  allowed there, and the ActivityKit budget is not applied. The selection and
  the throttling are tested; that the window keeps drawing and the card keeps
  updating on a real device for a real hour is not.

## MoQ Transport drafts

The draft is chosen by ALPN during the QUIC handshake. Three are spoken:

| ALPN | Session | Used for |
| --- | --- | --- |
| `moqt-22` | `MoqtSession` | MOQOM relays, preferred |
| `moqt-19` | `MoqtSession` | MOQOM relays not yet on draft-22, and direct calls |
| `moqt-16` | `Draft16Session` | Cloudflare's relay |

`RelayEndpoint(host:)` offers `moqt-22` then `moqt-19`. `DirectEndpoint` speaks
`moqt-19` only. Draft-16 is never offered to a MOQOM relay.

Draft-22 makes any Message Parameter the receiver does not define a protocol
violation, so MOQOM's extras are negotiated there. Each end's SETUP carries the
private option MOQOM_PARAMETERS (0x4D50) = 1. Once both have declared it, a
session sends NAMESPACE_DONE's withdrawal reason and a renewal's
AUTHORIZATION_PROOF (0x4D51), and accepts RELAY_HOPS (0x4D50) and
AUTHORIZATION_PROOF from the peer. With any other draft-22 peer, neither end
sends them, and receiving one ends the session. Draft-19 needs no
negotiation, and the Cloudflare profile never declares it.

### Cloudflare

```swift
let session = try await MoqtTransport.network().connect(
    to: .cloudflare(token: jwt),          // draft-16.cloudflare.mediaoverquic.com:443
    credentials: credentials              // identity only; the token is not sent
)
let initSegment = try await session.subscribe(
    SubscribeRequest(track: FullTrackName(namespace: TrackNamespace(["bbb"]), name: TrackName("0.mp4")),
                     start: .latestGroup)
)
```

The token is sent as the draft-16 PATH setup parameter (`/<token>`), next to
AUTHORITY and MAX_REQUEST_ID. MOQOM's own setup options, token and proof are
not sent. `RelayEndpoint.description` does not print the path.

Cloudflare's relay does not support the following, and the SDK behaves as
listed:

| Feature | On Cloudflare |
| --- | --- |
| FETCH, so catch-up on join and seeking back | `fetch` throws `MoqomError.unsupportedByRelay(feature: .fetch, …)`; a room skips catch-up and waits for the next group |
| REQUEST_UPDATE, so priority changes and pause/resume | `updatePriority` and `updateForwarding` do nothing |
| Credential renewal | `renewCredential` throws `.unsupportedByRelay(feature: .credentialRenewal, …)`; the session ends when the token does |
| GOAWAY | Not sent. One received is reported as an interruption |

End-to-end encryption works the same on every draft: payloads are sealed above
the transport and the object properties it authenticates go through unchanged.
Publishing to Cloudflare is covered by unit tests against a scripted relay,
not against Cloudflare.

`CloudflareLiveTests` subscribes to `bbb` on the public relay. It is skipped
unless asked for:

```sh
MOQOM_CF_DEMO_TOKEN=fetch swift test --filter CloudflareLiveTests   # reads the demo token from Cloudflare's docs
MOQOM_CF_DEMO_TOKEN=<jwt> swift test --filter CloudflareLiveTests
```

## Interop

`Tests/MoqomKitTests/RelayInteropTests.swift` runs against `moqom-relay`, which
lives in [`moqom-engine`](https://github.com/moqom-cloud/moqom-engine). It is
skipped unless told where the binary is:

```sh
(cd ../moqom-engine && cargo build --bin moqom-relay)
MOQOM_RELAY_BIN=$PWD/../moqom-engine/target/debug/moqom-relay swift test
```

Skipping rather than failing is the right trade for a client SDK whose CI has no
Rust toolchain, and the cost is worth stating plainly: a green run without that
variable is not evidence of interop.

The relay generates a certificate on startup and prints its SHA-256 to stdout
along with the port it bound. The harness reads both, pins the certificate
through `RelayTrust`, and connects with `NetworkQUICCarrier`. There is no
"disable verification for development" switch anywhere in this SDK, because the
thing about such switches is that nothing distinguishes a development build from
a shipped one at runtime. A pin is stricter than system trust rather than weaker,
and it cannot be widened by a configuration mistake: an empty pin list trusts
nothing and fails every handshake.

What these three tests catch that nothing else can is a misreading of the draft.
A rule misread the same way by an encoder and its own decoder is self-consistent,
and every other test in this package passes regardless. The relay's codec was
written separately, so a disagreement shows up as a failure rather than as a
convention.

`ProofInteropTests` answers the same question about proof of possession without
needing a relay to be running, because a fixture can be committed where a session
cannot. It writes proofs and thumbprint vectors into
`moqom-relay/tests/testdata/possession.json`, which the relay verifies on every
`cargo test` and the Go control plane reads to check it derives the same `cnf.jkt`
— three implementations, one file, and no toolchain needed on any side but the one
being run. It skips when `moqom-engine` is not checked out beside this repository;
`MOQOM_ENGINE_ROOT` says where it is, and `MOQOM_REQUIRE_INTEROP=1` turns the skip
into a failure. Regenerate with:

```sh
MOQOM_WRITE_FIXTURES=1 swift test --filter ProofInteropTests
```

Expect the signatures to change and nothing else: ECDSA signs with a fresh nonce,
so a regeneration that alters a thumbprint or a claim is a real change to the
format and every token already minted against the old one is now unusable.

### Why 26

The floor is 26 on every platform, which is a real cost — it excludes older
devices — bought for a specific thing: the two APIs this SDK is designed around
both arrived in that release train, and supporting anything earlier means a
second capture path and a second transport path, each needing hardware to test.
In practice the fallback is the one that never gets tested, running on the older
devices. There is not one availability check in this package.

An earlier probe here reported that this SDK had neither
`RealityView.renderingEffects.customPostProcessing` nor
`NetworkConnection<QUIC>`. That probe ran against the Command Line Tools SDK,
which is macOS-only — it was measuring the absence of an iOS SDK, not the
absence of the APIs. Against iPhoneOS 26.2 both are there:

| API | Where |
| --- | --- |
| `renderingEffects.customPostProcessing` | `_RealityKit_SwiftUI.swiftinterface` |
| `NetworkConnection<Network.QUIC>` | `Network.swiftinterface`, alongside `QUICStream` and `QUICDatagram` |

The deployment floor is now 26 across every platform, so both are reachable
unconditionally and the SDK contains no availability checks. `SceneCapture` is
still not typed against RealityKit, which remains the right call for a
different reason than before: it keeps the capture surface testable without a
renderer, rather than working around an SDK that lacked the callback.

## The sample

[`Samples/MoqomRoom`](Samples/MoqomRoom) is a SwiftUI room app, and it lives in
this repository on purpose. It depends on `MoqomKit` by path, so it builds
against the working tree and a breaking SDK change fails CI here rather than
after a release. That is the property that makes it an integration test instead
of a demo that rots.

```sh
cd Samples/MoqomRoom
xcodegen generate
xcodebuild test -scheme MoqomRoomUITests \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO
```

Its five UI tests are the only place the SwiftUI layer executes — the package
tests drive `RoomSession` directly and never render. One of them goes
live, publishes audio, and attaches a screenshot of the result, because the
tile is the only place a whole-pipeline failure shows up: the roster, the
buttons, and the catalog can all be right while nothing ever draws. Another
switches to the audio-room layout, which reconfigures the audio session
underneath — a listener holds no microphone — and fails on the alert that a
refused reconfiguration would raise.

`PatternSource` stands in for the camera. It renders an animated gradient into
pooled pixel buffers at 30fps, so "Go live" in a simulator produces bytes that
encode rather than a namespace with no media behind it.

## Decisions worth a second opinion

- **No `ExpressibleByStringLiteral` on validating types.** `Username`,
  `DeviceID`, and `TrackName` all validate in `init`, and adding a literal
  conformance means overload resolution silently prefers the non-throwing
  literal initialiser — so `Username("")` traps instead of throwing. This cost
  an afternoon; the reasoning is recorded in `TrackName.swift` so it is not
  reintroduced. `TenantID`, `RoomID`, and `LayerID` do not validate and do have
  the conformance.
- **`Transport` is MOQT-operation-shaped, not QUIC-shaped.** Discussed above.
- **A second draft-19 implementation.** `MoqomWire` is a port of the Rust
  codec, not a binding to it. Two implementations of a wire format is a thing
  to regret, and the alternative was a C ABI, a Rust runtime on every device,
  and a build that cross-compiles for four Apple platforms — to reach a QUIC
  stack that `Network.framework` already provides. The mitigation is that the
  tests pin bytes the Rust side produced rather than bytes we produced.
- **A Rust runtime after all, for direct paths only, and optional.** The
  argument above holds for the relay, where one connection is dialled and
  `Network.framework` is enough. A direct path is different. It needs one port
  that listens and dials at once and keeps probing until somebody gets
  through, and `Network.framework` can do this only by cancelling its listener
  before dialling and limiting the accepting side to a burst of probes. The
  Rust backend has neither limit, and it is the same QUIC stack as the Rust
  client at the other end. It sits behind `DirectSocket`, so the MOQT, the
  token checks and the tickets stay in one Swift implementation. It is opt-in
  per session, and absent from any build that has not fetched its
  framework, so an app that never asks for it carries no Rust at all.
- **Time is injected into the session state machine.** `MonotonicTime` is a
  parameter on every transition and there is no clock inside the SDK. It makes
  the reconnect windows testable in microseconds, and it means an app with a
  display link does not need a second timer — but it does mean the app has to
  call `tick(at:)`.
- **Capabilities, not roles.** `Grants` is an `OptionSet` plus an `isOwner`
  flag; `ParticipantRole` is derived for display and is explicitly not a source
  of truth. This follows the plan, and it is the decision most likely to be
  argued with, because "make them a moderator" is a natural thing for an API to
  want to offer.
- **The SDK owns reassembly, not just delivery.** `RoomSession.frames(from:)`
  hands back decodable frames, and `media(from:)` is still there for anything
  that wants the objects as they arrived. Depacketising in the application
  would mean every integrator reimplements dropping pre-keyframe objects and
  detecting gaps, and getting either subtly wrong looks like a codec bug rather
  than like their own.
- **`VideoEncoder` accepts a session without low-latency rate control.** The
  simulator has no low-latency encoder for either codec, so refusing would mean
  the SDK cannot encode anything without a device. The degradation is real —
  the encoder will buffer to hit a bitrate — so it is reported on
  `usesLowLatencyRateControl` rather than swallowed.
- **The adaptive delay aims at what the display needs, not at what it last asked
  for.** `PlayoutDelay` is separated from the renderer because this loop has been
  wrong twice and neither time was visible outside a two-phone bench. The fault:
  the give-back — running the clock up to 6% fast, the only graceful way to
  return a large delay — was gated on measured headroom exceeding the delay in
  force. Those two drift apart, because re-anchoring places the grid by whatever
  the controller believes, so a schedule anchored on an unusually early frame
  leaves the frames with less headroom than the delay claims. Measured, frames
  waited 143ms while the controller believed it had asked for 196, concluded from
  `143 < 196` that it had nothing to hand back, and left 119ms past what the
  display needed to the two-millisecond-per-quarter-second trickle. Now the
  target is fixed by the display and by lip sync — 18ms plus a deadband, or the
  voice's floor — and the delay in force is set to what the give-back achieved,
  so it stops being a fiction the next re-anchor will spend again. On two phones
  a call changing layout every eight seconds holds a flat 24ms of buffer with two
  give-backs and no widenings, against 57ms and climbing before; glass-to-glass
  is 61ms, which is what a call making no layout changes at all costs.
- **A running capture connection is never reconfigured to rotate.** Changing
  `videoRotationAngle` on a live connection stops the camera: measured on two
  phones, the sensor's own timestamps show holes of 133ms and 167ms at each
  layout change, which are exact multiples of the frame interval, so the device
  dropped three to five frames rather than anything downstream falling behind. So
  `CameraSource.rotationDegrees` reconfigures the connection only while the
  session is stopped — at start, at resume from a suspend, and across a camera
  swap — and a change while running goes to `VTPixelRotationSession` instead,
  which is hardware and hands the encoder the surface type it already wanted. The
  cost moves from a stall at every layout change to one pass per frame while the
  published shape differs from the angle the connection was given. With this and
  the burst cap, a call changing layout every eight seconds holds a flat 33.3ms
  capture cadence, an 87ms worst arrival against 203-267ms before, and no freezes
  at all.
- **Encoders are held to a short-window byte cap, not just an average bitrate.**
  `EncoderConfiguration.burstAllowance` lets a keyframe spend a quarter more than
  the average over any half second, where hardware left alone will spend eight
  times a delta frame's share. On a link whose capacity is near the target that
  one object owns the wire for a fifth of a second, everything behind it queues,
  and a receiver that sees late arrivals buys latency to cover them. Measured on
  two phones through a relay, capping it took the arrival tail from a 116ms 99th
  percentile to 84ms and the viewer's buffer from 38ms to 19ms on an ordinary
  call, and on a call changing layout every eight seconds — a forced keyframe
  each time — from 144-164ms and eleven re-anchors down to 81ms and five, which
  is what a call with no layout changes at all used to cost. The encoder pays in
  quality on that one picture. The average bitrate is unchanged either way: the
  same bits, spent less unevenly.
- **`FrameRelay` defaults to a three-frame buffer and drops the oldest.** Right
  for live media, wrong for anything with a deadline it can miss. A burst
  submitted without yielding will lose frames — which is correct, and surprised
  the tests before it surprised anyone else.
- **Taps hand out raw media and the SDK stops accounting for it.** Four of them:
  `Broadcast.tapFrames`, `AudioPublication.tapSamples`, `RoomSession.tapVideo`,
  and `RoomSession.tapAudio`, the last two decoding through a `VideoDecoding` or
  `AudioDecoding` you can substitute the way `encoderFactory` already lets you
  substitute an encoder. The receive taps are the ones with a cost — the display
  layer decodes privately, so a tap starts a decompression session that would
  not otherwise exist, which is why `TapPolicy.classification` decodes only
  keyframes and why the SDK releases the session when the consumer walks away.
  The uncomfortable part is that the SDK cannot tell an on-device transcriber
  from an upload, and saying so in the doc comment is the whole of the
  mitigation; `Watchdog` is the mechanism if an integrator wants to disclose it.

## Contribute

Bug reports, fixes and examples are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md):
the first pull request asks you to sign the CLA, and `swift test` runs with no
account or network.

## Security

Do not open a public issue for a vulnerability. Email
[security@moqom.cloud](mailto:security@moqom.cloud); see [SECURITY.md](SECURITY.md).

## Donate

The SDKs and samples are free. If they save you time, you can support the
open-source work at [elliottwave.dev/donate](https://elliottwave.dev/donate/).

## Licence

Apache-2.0; see [LICENSE](LICENSE) and [NOTICE](NOTICE), which also carries the
notices for third-party components. © 2026 Elliott Wave LLC.
