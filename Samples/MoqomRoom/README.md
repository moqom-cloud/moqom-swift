# MoqomRoom

A SwiftUI sample: join a room, see a gallery of up to sixteen cohosts or a seated
audio room, go live, mute a cohost for yourself only.

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

## The two layouts

**Room → Layout** switches between them, and **Room → Tiles** changes the box
count, which is the control a real client turns down when the device gets hot.

The gallery is `MoqomGalleryView` over `room.slots`, which comes from the SDK
rather than from the roster — with more cohosts than boxes, the SDK decides who
gets one, ranking spotlight and pin above speech and speech above silence, and
holding each tile long enough that a conversation does not rearrange the grid.
Anyone it leaves out appears as a count under the grid and stays audible. Tap a
tile to pin it, which takes effect immediately rather than waiting out that hold.

Two things to try with a second client: talk on one and watch the ring appear on
the other within a fraction of a second, with nothing on the relay having read the
audio; then set **Tiles** to 4 with five people in the room and watch which tile
the fifth person takes, and how long it takes them to take it.

The audio room is the same layout code with square seats and no video. What makes
it a different product is in `RoomModel.applyAudioPurpose()`: a device that is not
publishing moves to `AudioGraph.Purpose.listening`, which is a playback session —
no microphone held, no orange indicator, and audio that survives the screen
locking, which is what the `audio` background mode in `Info.plist` is for.

## Where things are

| File | What to read it for |
| --- | --- |
| `RoomModel.swift` | Draining an actor's events into main-actor view state |
| `RoomModel.swift` | `applyAudioPurpose` — why a listener holds no microphone |
| `RoomScreen.swift` | `MoqomGalleryView` — the grid, and how tile sizes reach the layer selector |
| `RoomScreen.swift` | `SeatTile` — an audio room's entire interface is the speaking ring |
| `RoomScreen.swift` | `WatchdogBanner` — why a recorder is not in the grid |
| `SceneEffects.swift` | Where a beauty filter or scene effect attaches |
| `RemoteVideoView.swift` | `AVSampleBufferDisplayLayer` per tile |

## Measuring echo cancellation on a device

This is the one thing in the SDK that cannot be tested anywhere but on hardware,
held by a person, in a room. The app has the instrument for it: pick
**Input → Microphone** and a readout appears with the capture level, the estimated
noise floor, whether the system agreed to cancel echo, and whether it currently
thinks somebody is speaking.

Why it needs measuring at all: cancellation is invisible when it works. A silent
readout proves nothing, because a microphone that is not working looks the same.
So the procedure removes the cancellation and watches what comes back.

**Setup.** Two devices in the same room *of the app* and in different rooms *of
the building* — otherwise the microphone under test hears the far end directly
and there is nothing to attribute. Device A is under test.

1. On A: join, **Input → Microphone**, tap **Audio**, then **Go live**. The
   camera matters: it puts the session in the video-call configuration, which is
   what routes output to the loudspeaker rather than the earpiece.
2. On B: join and publish continuous speech. A podcast held near B works better
   than talking, because it does not pause.
3. On A: turn the volume to about 80% and say nothing. B should be clearly
   audible from A's speaker.

**Read.** With the ear badge green, A's level should sit within a few dB of its
noise floor and **Speaking** should stay dark, even though the room is full of
B's voice. That is the canceller subtracting its reference.

**Then measure.** Turn on **Input → Bypass voice processing** and watch the level
climb. The difference is the echo return loss the canceller was providing, and it
is the number to record. Turning it back off should drop the level again within a
second or two as the canceller reconverges.

**What is good enough.** 25 dB or better of difference at 80% volume, the level
staying within about 6 dB of the floor while cancellation is on, and — the
product-visible one — **Speaking** never lighting up across a minute of far-end
audio. That last criterion is the one that matters beyond audio quality: a false
speaking verdict marks published packets as speech, keeps the speaking indicator
lit for somebody who is silent, and would wake the on-device inference that voice
activity is supposed to gate.

**What will go wrong first.** Distortion at high volume, because a loudspeaker
driven hard is nonlinear and a linear canceller cannot model what it cannot
predict; the residual suppressor is what covers that, and it has limits. Then
route changes: put on AirPods mid-test and the input format changes underneath the
graph, which is meant to reinstall itself and reset its estimate of the room.
Then heat, since this runs alongside hardware video encode.

## Verification status

The app runs. `MoqomRoomUITests` drives it on a simulator in CI: joining puts
you in the room over the loopback relay, going live adds a tile under your
username, switching to the audio-room layout reconfigures the audio session, and
leaving comes back to the join screen. That is the only place the SwiftUI layer
executes — the package's 380 tests drive `RoomSession` directly and never render.

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
