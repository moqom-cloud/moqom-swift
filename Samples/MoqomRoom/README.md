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

The bundle prefix is `cloud.moqom`, the reverse of `moqom.cloud` — the same
domain the Terraform uses for `dns_domain`, so the two stay in step. If a
personal team cannot register the identifier, override `MOQOM_BUNDLE_PREFIX`
locally.

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

The app runs. `MoqomRoomUITests` drives it on a simulator in CI: joining puts
you in the room over the loopback relay, going live adds a tile under your
username, and leaving comes back to the join screen. That is the only place the
SwiftUI layer executes — `MoqomKit`'s 103 tests drive `RoomSession` directly and
never render.

What a green simulator run does **not** cover is everything a simulator does not
have: the camera, the VideoToolbox encoder, the Metal scene capture, and the
RealityKit tap. Those compile and have never executed. `Broadcast` also
publishes a per-frame descriptor rather than encoded bytes, so a tile appearing
means the roster works, not that video moves.

Requires an Xcode with an iOS 26 SDK; the deployment floor is 26.

```sh
xcodegen generate
xcodebuild test -project MoqomRoom.xcodeproj -scheme MoqomRoomUITests \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO
```
