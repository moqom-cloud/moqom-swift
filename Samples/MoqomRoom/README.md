# MoqomRoom

A SwiftUI sample: join a room, see a gallery of up to sixteen cohosts or a seated
audio room, go live, mute a cohost for yourself only.

## Building

```sh
brew install xcodegen
cd Samples/MoqomRoom
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

## Leaving the app

Two features that only exist once the app is no longer the thing on screen, and
which are in the sample because both are easy to get subtly wrong in ways that
do not fail loudly.

**Picture in Picture.** Background the app while in a room and the video follows
you into the floating window. **Room → In small window** chooses who is in it:
everyone, the host, the cohosts and guests, or whoever is talking. That is
`PictureInPictureCast`, and it is a rule rather than a list, so it keeps
following the room as people join and leave.

Two things in the wiring are load-bearing. The window borrows the
`AVSampleBufferDisplayLayer` each tile is already drawing into — hence
`register(_:for:)` in `RemoteVideoView` — instead of building its own, because a
second layer would mean a second hardware decode of a subscription that already
exists. And the source view is the video area rather than the screen, because
the system measures that view to decide whether to open the window at all; point
it at something zero-sized and the feature silently never triggers.

The reason it is not a composited grid: compositing participants into one buffer
needs a GPU pass per frame, and an app that submits GPU work in the background is
terminated. It appears to work in the simulator, where that is not enforced.

**Live Activities.** Going live puts a card on the Lock Screen and in the Dynamic
Island, drawn by `MoqomRoomWidgets` — an extension, because the card is rendered
out of process while the app is suspended. `BroadcastLiveActivity.follow(room)`
is the whole integration; it tracks participant count, active speaker, connection
quality, recording, and this device's mute and camera state.

The interesting part is what it does *not* send. ActivityKit budgets updates, and
a nine-person room reassigns the active speaker several times a second, so a card
that forwarded each change would exhaust its allowance in the first minute and
then freeze for the rest of the broadcast. Three things prevent that: the elapsed
time is `Text(timerInterval:)` counting from a date the card already holds, so it
costs nothing; updates that would not change a pixel are dropped by
`differsVisibly(from:)`, meaning a viewer count going 1,004 → 1,005 under a card
reading "1K" is free; and everything else waits out a minimum interval except the
transitions where delay would be a lie — recording starting, the stream ending, a
mute the user just pressed.

Both need the *Audio, AirPlay, and Picture in Picture* background mode, which
`project.yml` sets. Without it the system refuses to start the window and reports
it through `onFailure` rather than failing the build — the sample raises that as
an alert so the refusal is visible rather than mysterious.

Neither can be driven from a UI test: the window belongs to the system, and the
simulator will not background the app on request. The UI test covers the part
that can break silently, which is the cast reaching `RoomSession`.

## Where things are

| File | What to read it for |
| --- | --- |
| `RoomModel.swift` | Draining an actor's events into main-actor view state |
| `RoomModel.swift` | `applyAudioPurpose` — why a listener holds no microphone |
| `RoomScreen.swift` | `MoqomGalleryView` — the grid, and how tile sizes reach the layer selector |
| `RoomScreen.swift` | `SeatTile` — an audio room's entire interface is the speaking ring |
| `RoomScreen.swift` | `WatchdogBanner` — why a recorder is not in the grid |
| `SceneEffects.swift` | Where a beauty filter or scene effect attaches |
| `RemoteVideoView.swift` | `AVSampleBufferDisplayLayer` per tile, and lending it to the small window |
| `PictureInPicture.swift` | Handing SwiftUI's `UIView` to the SDK as the source |
| `RoomModel.swift` | `startLiveActivity` — one call, and the card tracks the room |
| `MoqomRoomWidgets/` | The Lock Screen card and Dynamic Island, out of process |

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

The app runs. `MoqomRoomUITests` drives it on a simulator in CI with six tests:
joining puts you in the room over the loopback relay, going live adds a tile
under your username, switching to the audio-room layout reconfigures the audio
session, choosing a Picture in Picture cast reaches `RoomSession`, and leaving
comes back to the join screen. That is the only place the SwiftUI layer executes
— the package's 496 tests drive `RoomSession` directly and never render.

What a green simulator run does **not** cover is everything a simulator does not
have: the camera, the VideoToolbox encoder, the Metal scene capture, and the
RealityKit tap. Those compile and have never executed. `Broadcast` also
publishes a per-frame descriptor rather than encoded bytes, so a tile appearing
means the roster works, not that video moves.

Nor does it cover the two features above actually appearing. The Picture in
Picture window and the Live Activity card have been built and wired but not seen
on hardware: both need a real device, and the pieces most likely to be wrong are
the ones only a device exercises — whether the system accepts the source view
and opens the window unprompted, whether reparenting a layer that is mid-decode
survives the transition, and whether the throttle actually stays inside
ActivityKit's budget over an hour rather than over a unit test.

Requires an Xcode with an iOS 26 SDK; the deployment floor is 26.

```sh
xcodegen generate
xcodebuild test -project MoqomRoom.xcodeproj -scheme MoqomRoomUITests \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO
```
