# MoqomKit

The iOS, visionOS, and macOS client SDK.

```sh
cd sdk/ios
swift build
swift test
```

Swift 6 language mode, complete strict concurrency. Builds and tests on the
host platform under the Command Line Tools alone — no Xcode required for
anything in this package.

## Targets

| Target | What it is |
| --- | --- |
| `MoqomCore` | Namespaces, identity, layer ladders, frame types |
| `MoqomKit` | Session, rooms, publishing, subscribing, layer selection, platform capture |
| `MoqomLoopback` | An in-memory relay, so the tests exercise the whole stack |

## Status

There is no transport. `moqom-transport` accepts QUIC sessions but nothing
above it speaks MOQT yet, and there is no crate to bind to. So `Transport` is a
protocol and `MoqomLoopback` is the only implementation.

The seam sits at MOQT *operations* — announce, subscribe, subscribe to a prefix,
write objects — rather than at QUIC streams. That is deliberate: the wire codec
is written once in Rust and reused by every platform, and a second draft-19
implementation in Swift would be a second thing to keep in agreement with the
first. The reasoning is at the top of `Sources/MoqomKit/Transport/Transport.swift`.

### Verified: builds and is tested

103 tests across 14 suites. Everything here runs on every `swift test`.

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
- **Loopback integration.** Going live populating other clients' rosters,
  announcement withdrawal emptying them, frames becoming objects, backpressure
  dropping the oldest frame, and — asserted explicitly — that per-viewer mute
  produces no relay traffic at all.

### Verified: compiles, never runs

Written against the platform frameworks and compiled on every build, but not
reachable without a GPU, a camera, or a device. None of it is exercised by a
test.

- `Platform/VideoEncoder.swift` — VideoToolbox with low-latency rate control,
  frame reordering off, and a temporal base layer.
- `Platform/SceneCapture.swift` — a pooled, IOSurface-backed blit from a
  renderer's `MTLTexture`. The frame never leaves the GPU.
- `Platform/RealityKitCapture.swift` — `ARView.renderCallbacks.postProcess`.
- `Platform/CameraSource.swift` — `AVCaptureSession` in the encoder's pixel
  format.
- `Platform/VideoRenderer.swift` — sample buffer assembly and
  `AVSampleBufferDisplayLayer`.
- `Subscribe/LayoutObserver.swift` — the SwiftUI modifier that reports a tile's
  size to the layer selector.

### Not written

- Audio. No capture, no encode, no jitter buffer. `MediaKind.audio` exists in
  the model and nothing produces it.
- SFrame end-to-end encryption.
- The catalog track. Ladders are handed to the SDK rather than discovered.
- Congestion control feedback. `NetworkAllowance` is an input the app supplies;
  nothing measures it.
- Encoded frames reaching the transport. `Broadcast` publishes a descriptor of
  each frame — timestamp and dimensions — so the group and object numbering,
  the priority mapping, and the transport contract are all exercised without a
  GPU. Connecting `VideoEncoder` to `TrackWriter` is the missing wire.

## Blocked on Xcode

`xcode-select -p` is `/Library/Developer/CommandLineTools`. Changing it needs
`sudo`. Until it points at Xcode:

- **No iOS build of anything.** The package compiles for macOS only, so the
  `#if os(iOS)` branches — three of them, all small — have never been through a
  compiler. Everything else is gated on `canImport`, which resolves true on
  macOS, so the platform layer above is genuinely compiled.
- **The sample app cannot be built or run.** Its Swift sources do typecheck;
  see below.
- **No device or simulator testing**, so nothing in "compiles, never runs" has
  been observed to work.
- **iOS 26 APIs are invisible.** This SDK has no
  `RealityView.renderingEffects.customPostProcessing` and no
  `NetworkConnection<QUIC>`, both of which the plan expects to use. Verified by
  probe, not assumed. `SceneCapture.submit(texture:at:on:)` is deliberately not
  typed against RealityKit so the newer callback can call it unchanged.

### How the sample was typechecked without Xcode

The sample's sources were compiled as a macOS library target against this
package, under Swift 6 with complete strict concurrency:

```sh
mkdir -p /tmp/samplecheck/Sources
ln -s "$PWD/../../samples/ios/MoqomRoom/Sources" /tmp/samplecheck/Sources/MoqomRoomCheck
# Package.swift: one macOS target depending on .package(path: "sdk/ios")
cd /tmp/samplecheck && swift build
```

It builds clean. That covers the view models, the SwiftUI screens, the
`NSViewRepresentable` branch, and every call into `MoqomKit`. It does not cover
the `UIViewRepresentable` branch or `textInputAutocapitalization`.

## Decisions worth a second opinion

- **No `ExpressibleByStringLiteral` on validating types.** `Username`,
  `DeviceID`, and `TrackName` all validate in `init`, and adding a literal
  conformance means overload resolution silently prefers the non-throwing
  literal initialiser — so `Username("")` traps instead of throwing. This cost
  an afternoon; the reasoning is recorded in `TrackName.swift` so it is not
  reintroduced. `TenantID`, `RoomID`, and `LayerID` do not validate and do have
  the conformance.
- **`Transport` is MOQT-operation-shaped, not QUIC-shaped.** Discussed above.
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
- **`Broadcast` publishes a frame descriptor.** It keeps the publish path
  testable off-device. It is also a placeholder that will be deleted, and it
  would be easy to mistake for a real payload.
- **`FrameRelay` defaults to a three-frame buffer and drops the oldest.** Right
  for live media, wrong for anything with a deadline it can miss. A burst
  submitted without yielding will lose frames — which is correct, and surprised
  the tests before it surprised anyone else.
