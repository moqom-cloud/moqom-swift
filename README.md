# MoqomRoom

A SwiftUI sample: join a room, see a participant grid, go live, mute a cohost
for yourself only.

## Building

```sh
brew install xcodegen
cd samples/ios
cp Local.xcconfig.example Local.xcconfig   # only needed for a device
xcodegen generate
open MoqomRoom.xcodeproj
```

There is no checked-in `.xcodeproj`. See the comment at the top of `project.yml`
for why.

Signing is in `Signing.xcconfig`, which optionally includes a gitignored
`Local.xcconfig`. Fill in `DEVELOPMENT_TEAM` there to run on a device; the
simulator needs nothing. The Team ID stays out of the repository because the
Apple account is personal for now, and moving to an organisation account later
is a change to that one file.

The bundle prefix is `example.moqom.cloud`, the reverse of `cloud.moqom.example`
— the same hostname the Terraform uses for `dns_domain`, so the two stay in step.
That name is still a placeholder: RFC 2606 reserves `.example`, so it cannot be
registered. Harmless for a bundle identifier, which is only a unique string, and
not harmless for DNS. If a personal team cannot register the identifier,
override `MOQOM_BUNDLE_PREFIX` locally.

## What it actually does

It talks to `MoqomLoopback`, an in-memory relay, because `moqom-transport` does
not exist yet. Everything above the transport is real: the roster is built from
namespace announcements, layer selection responds to how large the tiles are,
per-viewer mute is an unsubscribe that never reaches the relay, and moderation
is refused when the grants do not allow it.

Nothing decodes, because nothing is encoded — the broadcast publishes synthetic
frames carrying only their shape. Swapping `FrameRelay` for `CameraSource` or
`SceneCapture` in `RoomModel.startBroadcast()` is the change that makes it
real, and requires a device.

## Where things are

| File | What to read it for |
| --- | --- |
| `RoomModel.swift` | Draining an actor's events into main-actor view state |
| `RoomScreen.swift` | `.moqomRenderBox` — how a tile's size reaches the layer selector |
| `RoomScreen.swift` | `WatchdogBanner` — why a recorder is not in the grid |
| `SceneEffects.swift` | Where a beauty filter or scene effect attaches |
| `RemoteVideoView.swift` | `AVSampleBufferDisplayLayer` per tile |

## Verification status

The Swift sources typecheck under Swift 6 language mode with complete strict
concurrency, against the macOS SDK. The `#if os(iOS)` branches — the
`UIViewRepresentable` in `RemoteVideoView.swift` and one text field modifier in
`MoqomRoomApp.swift` — cannot be compiled on a machine whose `xcode-select`
points at the Command Line Tools, so CI builds this project for the iOS
Simulator on a macOS runner, which is the only place those branches are read.

The app has still never been run. A simulator build proves it compiles; it says
nothing about the camera, the encoder, or the RealityKit tap, none of which
exist in a simulator.
