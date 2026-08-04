# MoqomKit

The Apple-platform client SDK for [MOQOM](https://github.com/moqom-cloud/moqom),
the Media Over QUIC Orchestration Mesh. iOS, visionOS, macOS, and tvOS.

```swift
.package(url: "https://github.com/moqom-cloud/moqom-swift", from: "0.1.0")
```

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
| `MoqomWire` | The `draft-ietf-moq-transport-19` codec: varints, parameters, control messages, datagrams, subgroup streams |
| `MoqomKit` | Session, MOQT transport, rooms, publishing, subscribing, layer selection, SFrame, platform capture |
| `MoqomLoopback` | An in-memory relay and an in-memory QUIC carrier, so the tests exercise the whole stack |

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

464 tests across 76 suites. All but the three interop tests run on every
`swift test`; those need a relay binary and skip without one.

- **Namespaces and identity.** Tuple construction, field limits in UTF-8 bytes,
  Unicode canonicalisation, prefix matching, and recovering a participant from
  an announcement. Usernames are strings; there is no numeric UID anywhere and
  no place to add one.
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
  parameter sets arriving from the catalog rather than the bitstream. Plus a
  round trip: a broadcast through the real packetiser, the relay, and the real
  depacketiser, arriving as the frames that were encoded.
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

### Verified: compiles, never runs

Written against the platform frameworks and compiled on every build, but not
reachable without a GPU, a camera, or a device. Nothing here is covered by
`swift test`; a couple of entries are partly reached by the simulator, and say
which part.

- `Platform/VideoEncoder.swift` — VideoToolbox with low-latency rate control,
  frame reordering off, and a temporal base layer. The session creation and its
  fallback do run in the simulator, which has an encoder for both codecs and a
  low-latency one for neither; encoding itself needs a device.
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
  decode path needs a stream from a real encoder.
- `Platform/VideoDecoder.swift` — the `VTDecompressionSession` a receive tap
  decodes through, including the rebuild a rung change forces. Exists because
  the display layer decodes privately and returns nothing, so anything wanting
  pixels has to own a session. The tap machinery around it is tested with an
  injected decoder; this file needs a real bitstream.
- `Subscribe/LayoutObserver.swift` — the SwiftUI modifier that reports a tile's
  size to the layer selector. The takeover half of it is tested; the modifier
  needs a hierarchy.
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

- Authorisation. Credentials are carried in Setup Options and the relay parses
  and ignores them, so nothing yet stops a session publishing under a namespace
  that is not its own. The tokens are a placeholder for CAT+DPoP.
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

The iOS branches compile, the sample builds and publishes, and the UI tests
drive it on a simulator. What remains unobserved is narrower than it was, and
specific:

- **Camera, GPU capture, and hardware encode.** `AVCaptureSession`, the Metal
  scene blit, the RealityKit tap, and VideoToolbox actually compressing a frame
  have never executed. The simulator publishes a rendered pattern through the
  same pipeline, which exercises everything downstream of the encoder but is
  not the same as a camera.
- **A network with distance in it.** The interop tests put real QUIC packets on
  the loopback interface, which proves the framing and the handshake and nothing
  about loss, reordering, or a path that changes mid-session. Every measurement
  of that kind is still ahead.
- **A backgrounded app.** Picture in Picture and Live Activities are both
  features about what happens after the user swipes home, and the simulator does
  not enforce the rules that make that interesting: background GPU work is
  allowed there, and the ActivityKit budget is not applied. The selection and
  the throttling are tested; that the window keeps drawing and the card keeps
  updating on a real device for a real hour is not.

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
