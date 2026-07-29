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
frames carrying only their shape. **Input → Video → Camera** swaps the test
pattern for a real `CameraSource` and is the change that makes it real; it needs
a device, since a simulator has no camera and the app falls back to the pattern.
`SceneCapture` is the third option, and the swap is in
`RoomModel.startBroadcast()`.

## Camera, microphone, and mute

Four controls, and the interesting thing about them is which ones stay live
while the publication does.

**Mute** and **Camera off** stop the bytes without taking anything down. They
call `RoomSession.setSelfMuted(_:)`, which suppresses the encoders and says so
on the catalog. The publication stays up, the tracks stay offered, and every
subscriber keeps their subscription — so coming back is the next captured frame
rather than a resubscribe. **End audio** is the other thing, deliberately kept
as a separate button: it ends the publication, closes the track, and makes
everyone unsubscribe.

That distinction is the whole reason self-mute rides the catalog rather than
being implemented as stop-and-restart. A viewer whose objects simply stopped
cannot tell a muted microphone from a dead uplink, and the two want opposite
interfaces — one draws a mute badge, the other a reconnecting spinner. The
catalog is the one document a participant authors about themselves, so it is
where a claim about their own microphone belongs; the room's control track is
written by the authority and carries moderator mutes, which are a different
feature that happens to share a word.

**Flip** switches front camera for back without interrupting anything. The same
`CameraSource` keeps feeding the same encoders, so nobody sees the participant
leave the stage; what they get is a keyframe, because the new camera is a new
scene and predicting it from the old one looks like a second of smeared video.

**Mirroring** is two questions that share a word, and the sample answers them
differently. The self-preview of a front camera is mirrored, because a preview
that is not feels broken to the person in it. What is published is not, because
that copy is the real scene and mirroring it puts every letter on a T-shirt or
a whiteboard backwards — and the person on camera is the one who cannot tell.
The preview half is `VideoRenderer.isMirrored`, a transform on the layer that
costs nothing per frame; the other half is `CameraSource.publishesMirrored`,
which is off and which the sample leaves off.

Two things worth noticing on a device. The self-preview keeps running while the
camera is muted, which is what every video app does and for a good reason: the
person who muted needs to see what they will be sending when they come back. And
muting does not put the hardware indicator out, because the capture device is
still open — the SDK is explicit that this stops the bytes rather than releasing
the camera, and an app that wants the stronger claim has to stop the device and
pay the reacquisition latency.

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
| `RoomModel.swift` | `flipCamera` — switching input without restarting the publication |
| `RoomModel.swift` | `localPreview` — why the camera self-view is a tap and not a second `frames()` |
| `RemoteVideoView.swift` | `AVSampleBufferDisplayLayer` per tile, and lending it to the small window |
| `RemoteVideoView.swift` | `isMirrored` — mirroring the preview and not the published frames |
| `PictureInPicture.swift` | Handing SwiftUI's `UIView` to the SDK as the source |
| `RoomModel.swift` | `startLiveActivity` — one call, and the card tracks the room |
| `MoqomRoomWidgets/` | The Lock Screen card and Dynamic Island, out of process |
| `RelayConfiguration.swift` | Choosing between the loopback and a relay without a code change |
| `RelayPairing.swift` | Why a four digit code is a lookup and never a trust decision |
| `Measurement.swift` | Stamping frames on a clock both devices share, and what that costs |

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

## Measuring latency between two devices

The app runs on an in-process loopback by default, which is the right default and
measures nothing about a network: a loopback hands frames between two objects, so
latency, jitter, loss and congestion response are all absent. Two phones pointed
at the same relay is the only arrangement where the numbers mean anything.

**The relay.** Start `moqom-relay` on the Mac with a certificate that persists
across restarts, because the phones pin it and a relay that regenerates one on
every launch invalidates the pin:

```sh
MOQOM_RELAY_ADDR=0.0.0.0:4443 \
MOQOM_RELAY_CERT=/tmp/relay-tls/cert.pem \
MOQOM_RELAY_KEY=/tmp/relay-tls/key.pem \
    ./target/release/moqom-relay
```

Bind `0.0.0.0` rather than `[::]`, or phones dialling an IPv4 address are not
answered and the failure looks like a relay that is down.

**Pairing.** The phones need the relay's address and the SHA-256 of that
certificate. Rather than typing 44 characters of base64 into each one, advertise
both over Bonjour and look them up by a short code:

```sh
Scripts/pair-relay.sh 4242
```

The code is a lookup and not a credential — the phone still pins the exact
certificate the advertisement named. That is only safe because it assumes a
trusted LAN, where anyone able to forge the advertisement could equally well be
the relay, which is why it lives in this sample and not in MoqomKit.

**On each phone.** Enter the code as the **Pairing code**, turn on **Measure this
run**, and Join — the host, port and hash fill themselves in, so the interface
still shows where the media is going. Allow local network access when asked;
until that prompt is answered iOS blackholes the traffic and the connection hangs
rather than failing. Use a different username on each phone and the same room on
both.

**Read.** Measured runs publish one pinned 720p HEVC rung from the camera instead
of a ladder, because a viewer free to move between three rungs makes any figure
taken across the run describe no single one of them. Both phones stamp frames on
a clock disciplined against NTP, so the readout at the bottom of the room shows
the median and 95th percentile of capture-to-arrival, and beside them the clock's
own error bar. That last figure is the one to check first: it turns orange when it
exceeds the median, which means the two clocks have not agreed closely enough for
the subtraction between them to be a latency at all.

Not currently measurable this way: MLVC. It produces no bitstream on device
because the rANS entropy coder is not wired in, so there is nothing to send.

## Verification status

The app runs. `MoqomRoomUITests` drives it on a simulator in CI with eight tests:
joining puts you in the room over the loopback relay, going live adds a tile
under your username, muting the microphone and camera leaves both publications
running, switching to the audio-room layout reconfigures the audio session,
choosing a Picture in Picture cast reaches `RoomSession`, and leaving comes back
to the join screen. That is the only place the SwiftUI layer executes — the
package's 505 tests drive `RoomSession` directly and never render.

What a green simulator run does **not** cover is everything a simulator does not
have: the camera, the VideoToolbox encoder, the Metal scene capture, and the
RealityKit tap. Those compile and have never executed. `Broadcast` also
publishes a per-frame descriptor rather than encoded bytes, so a tile appearing
means the roster works, not that video moves.

Camera switching and mirroring are in that untested set, and they are the two
things above that a simulator cannot say anything about. Muting is covered — the
suppression, the catalog round trip, and the keyframe on resume all run in the
package tests — but flipping cameras has never been executed, and the parts most
likely to be wrong are the ones only hardware reaches: whether the session
reconfiguration is quick enough not to stall the encoder, whether the two
cameras agree on a format, and whether the preview transform survives the
switch. Rotation is not handled at all: `CameraSource` never sets the capture
connection's rotation angle, so a portrait phone publishes a sideways picture.

Nor does a green run cover Picture in Picture or the Live Activity card actually
appearing. Both have been built and wired but not seen on hardware, and the
pieces most likely to be wrong are again the ones only a device exercises —
whether the system accepts the source view and opens the window unprompted,
whether reparenting a layer that is mid-decode survives the transition, and
whether the throttle actually stays inside ActivityKit's budget over an hour
rather than over a unit test.

Requires an Xcode with an iOS 26 SDK; the deployment floor is 26.

```sh
xcodegen generate
xcodebuild test -project MoqomRoom.xcodeproj -scheme MoqomRoomUITests \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO
```
