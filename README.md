# MoqomKit

The Apple-platform client SDK for [MOQOM](https://github.com/moqom-cloud/moqom),
a Media over QUIC platform. iOS, visionOS, macOS, and tvOS.

```swift
.package(url: "https://github.com/moqom-cloud/moqom-swift", from: "0.1.0")
```

This is its own repository rather than a directory in the platform monorepo for
one reason: SwiftPM resolves a git dependency by looking for `Package.swift` at
the repository *root*, with no way to point at a subdirectory. A package nested
inside the monorepo cannot be consumed by URL at all.

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
- `Platform/RealityKitCapture.swift` — `RealityView`'s
  `renderingEffects.customPostProcessing` via `SceneCaptureEffect`, plus the
  same handoff through `ARView.renderCallbacks.postProcess` for UIKit hosts.
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

## What still has not run

Xcode is selected now, so the iOS branches compile, the sample builds, and the
UI tests drive it on a simulator. What remains unobserved is narrower than it
was, and specific:

- **Nothing touching hardware.** The VideoToolbox encoder, the Metal scene
  capture, the RealityKit tap, `AVCaptureSession`, and display-layer rendering
  compile and have never executed. A simulator does not exercise any of them.
- **Encoded bytes still do not reach the transport**, per the list above. The
  UI tests going green means the room, the roster and the layer math work; it
  does not mean video moves.

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

Its three UI tests are the only place the SwiftUI layer executes — the 103
package tests drive `RoomSession` directly and never render.

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
