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

**Input → Video** chooses among three sources, and all three are wired in
`RoomModel.startBroadcast()`. The test pattern needs no hardware and is what a
simulator falls back to. **Camera** is a real `CameraSource`. **AR scene** is
`SceneCapture` behind a RealityKit view — the camera feed with an orb floating
half a metre in front of it — and is the input worth compressing if you want to
know what the codec does with synthetic geometry over hand-held video, since the
orb's hard edge is the first thing to smear when the bitrate is not there.

The AR source carries two constraints the other two do not, both in
`ARSceneSource.swift`. RealityKit only draws what is in a window, so the scene
*is* the self tile rather than being previewed in one, and choosing it switches
the layout to full screen — the tile's size is the drawable's, and a scene
published from a side-by-side thumbnail is a 720p rung upscaled from a third of
that. And the renderer's texture is `bgra10_xr_srgb`, which cannot be copied into
a pixel buffer, so it is converted before `SceneCapture` sees it; skip that and
the broadcast is a uniform field of magenta that every frame counter in the app
reports as healthy.

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

**A moderator's mute is the other case, and it does put the light out.** It
arrives from the relay on the participant's own `.policy` track, and the SDK
closes the capture device rather than only the encoder — `AVCaptureSession`
stopped, `AVAudioSession` dropped to a listening category, indicator off. The
banner at the top of the screen says who did it, and the mute button for that
kind is disabled, because pressing it would do nothing the relay has not already
done.

Lifting it does not turn anything back on. The relay saying it would carry the
media again is permission, and the **Resume** button on that banner is the only
thing in the app that acts on it — `RoomSession.resumeAfterForceMute(_:)`. A
server that could reopen a camera is a server that can open a camera, and the
difference is the whole reason the unmute lives on the device.

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

## Changing the shape of what you publish, mid-call

**Room → Layout → My video shape** turns the live publication between portrait and
landscape while it is running. The rung keeps its name and its short side, so
nothing resubscribes; the switch lands on a keyframe that carries the decoder
configuration for the new size, and the far tile changes proportions between one
frame and the next.

Worth watching on the *other* phone, since that is where it either works or shows.
`Scripts/bench-two-phones.sh` with `MOQOM_RESHAPE_EVERY=8` does it on a timer and
prints both halves: the publisher's `SHAPE` lines against the viewer's `DRAW`, whose
`shape=` and `reshapes=` should follow each one.

What it costs, measured over two phones on a 1.3Mbps link — because "seamless" is a
claim and these are the numbers behind it:

- Nothing is lost or blanked. `delivered=100.0%`, `lost=0`, `failures=0`, and no
  flush: the renderer keeps the last picture until the new one decodes. On the
  publisher's side `out-of-shape=0` and `abandoned=0`, so the handover completes on
  the first keyframe every time and no frame is encoded for a track it no longer owns.
- Two frames go out at the old aspect. A single differently shaped frame is not
  treated as a layout change — a rotation can produce one on its own — so the first
  two are encoded by the old session, which squeezes them. Two frames is 66ms.
- A keyframe per rung, which on a thin link is the real cost. An IDR is many times
  the size of a delta, so the arrival gap at the seam grows from about 170ms to
  between 200 and 270ms, and the cadence report attributes those stalls with
  `onkey=`. Unavoidable in kind: a decoder cannot change format without one.
- On a camera, the capture connection hiccups for about 130ms while it changes
  rotation. That one is the camera's rather than the SDK's — it shows up on the
  publisher's own `GRAB` and `TIME` lines, and it happens whether or not the
  publication follows.

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

**And the camera you lose on the way out.** Backgrounding is also when iOS takes
the camera away. Picture in Picture starting counts as another app in the
foreground, so capture stops while the session, the subscriptions and the
microphone all carry on — measured on two phones as 104 seconds of a frozen tile
with nothing on either screen saying why.

The publication notices its own source has gone quiet for a second and the
session puts it in the catalog, next to the mute and deliberately not folded
into it: `Catalog.interrupted`, arriving as `MuteState.interrupted` and
`MuteReason.interrupted`. Tiles then draw an orange `video.badge.ellipsis` and
"Camera interrupted" rather than the grey `video.slash.fill` that means somebody
chose this. A mute or a force-mute is never reported this way — the frames
stopped because they were stopped, and the room has already been told the true
reason.

To see it, run the two-phone bench and open any other app on the publisher.
The far phone captions the tile within a second, and clears it on the first
frame back.

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

A measured run also stamps the microphone's packets on the same clock, which is
what the `SYNC` line in the log is subtracting. It states lip sync as one signed
number of milliseconds and shows both halves it came from: the eye, being the
network plus however long the tile held the frame, and the ear, being the network
plus the queue in front of the speaker plus what the device says its output path
costs. Positive is a picture behind the voice. Negative is a face that moves
before it speaks, which is the direction people notice, and which measured about
minus two hundred milliseconds before the playout path was pull-driven.

Not currently measurable this way: MLVC. It produces no bitstream on device
because the rANS entropy coder is not wired in, so there is nothing to send.

### Through a relay that is not on the desk

A relay on the Mac shares the phones' Wi-Fi, so the measurement includes that
link twice and the leg an actual call would traverse not at all. The app
therefore defaults to a relay on Compute Engine in Los Angeles, and these two
scripts put a build on it and drive both phones through it:

```sh
MOQOM_GCP_ZONE=us-west2-a MOQOM_GCP_INSTANCE=moqom-relay-la Scripts/relay-on-gcp.sh
. /tmp/moqom-gcp-relay.env && export MOQOM_RELAY_HOST MOQOM_RELAY_PORT MOQOM_RELAY_CERT_HASH
MOQOM_SECONDS=90 Scripts/bench-two-phones.sh
```

Both are idempotent, and the second prints the same block the readout shows,
per phone, at the end of the run. Leave the **Pairing code** field empty when
connecting by hand: it is a Bonjour lookup for a relay on the LAN, and with
nothing advertising the code the connection fails before the host and hash
below it are ever tried.

### The credential

A deployed relay holds the control plane's verification keys, which means it
admits a session with no token and then permits it nothing. On the phone that
is a room that joins and a **Go live** that appears to do nothing.

The phone gets its own token. The join screen's **Token service** section takes
the control plane's address, the hash of *its* certificate — not the relay's,
which is a different machine — and a device credential, and the app fetches a
token in the second before it dials. Fifteen minutes is a fine lifetime for
something acquired automatically and a miserable one for something typed in.

The credential and the address are what `deploy/tools/invite.sh` puts in a QR
code, below. By hand:

```sh
gcloud secrets versions access latest --secret=moqom-dev-device-credential
cd deploy/envs/dev && terraform output -raw join_endpoint
```

The certificate is one the deployment issued itself, which iOS refuses on its
own account after the app has accepted it by pin — App Transport Security wants
a chain to a root the system knows, and reports its refusal as a TLS error with
nothing in it about trust. `project.yml` therefore carries an ATS exception for
that one address. **Moving the join endpoint means editing that address in two
places**: the exception, and `JoinService.development`. Getting only the second
produces `NSURLErrorDomain -1200` and an error line that says the pin matched
and the platform refused it anyway.

**Pasting a token** into the **Credential** section still works and is the
fallback when there is no service configured. It is kept in the Keychain against
the relay it was minted for.

```sh
deploy/tools/join.sh ada demo      # in the moqom repository; prints a token
```

Filed per host, so pairing with a relay on the desk does not throw away the one
for Los Angeles, and so a credential is never offered to a relay it does not
belong to — a relay with keys refuses a token it cannot verify outright, rather
than falling back to admitting the session anonymously.

The screen reads the token's claims back to you: who it names, which room, and
when it expires. Nothing checks the signature and nothing could — the phone
holds no key — so this is display only. It is there because the control plane
caps a token at fifteen minutes, and a saved credential that has gone stale is
otherwise indistinguishable on screen from a good one. It will also say when
the token names a different room or person than the fields above it, which is
the mismatch that costs the most time to find by any other means.

### Scanning a way in

Pasting a token still needs a Mac and a way to get four hundred characters from
it to a phone. The alternative is a QR code:

```sh
deploy/tools/invite.sh ada demo    # prints the code, and opens it as a PNG
```

That carries what a device cannot be told by hand — the relay's address, the
hash of the certificate to pin, the token service beside it and the credential
to spend there — as a `moqom://join?...` link. Point the Camera app at it and
MOQOM opens with a **Scanned link** section at the top of the join screen,
naming the address first and what it enrols the device for second.

It stops there. Agreeing fills the fields in and **Join** still has to be
pressed, because a link chooses which relay this device trusts and which
credential it presents, and a URL can arrive from a message or a web page as
easily as from a code somebody printed. `RelayInvitation` in the SDK parses;
consent is the application's.

The tenant comes out of the token rather than from a field, so the two cannot
contradict each other — the contradiction being a relay that admits the session
and refuses every track, which on the phone is a Join that works and a **Go
live** that does nothing.

What a code is worth has changed, and it is worth reading before printing one.
It used to carry a token, which made it good for fifteen minutes: reassuring,
and useless in practice, because codes were routinely stale by the time somebody
held a phone up to one. It now carries the enrolment credential, so the phone
fetches its own token every time and the code keeps working — for whoever
photographs it, too, until the credential is rotated. What bounds it is what the
credential can buy: joining rooms in one tenant, never moderation and never
ownership, refused at the endpoint whatever is asked for.

Los Angeles rather than Oregon on measurement: mean round trip from this desk
was 21.8ms against 47.5ms, which is most of a frame at sixty. A recent
ninety-second run measured 56–57ms glass to glass at the median and 70ms at the
95th, 720p at thirty frames a second in both directions, every frame delivered.
Compare any number here against `Scripts/relay-metrics-gcp.sh` before believing
it — a run that looks clean on the phones while the relay reports shed subgroups
was smooth because somebody's frames were thrown away.

## The shared bubble field

Two phones in AR mode can share one world. Bubbles rise in front of both, and a
tap on either pops it on both. It is a small game and a real test of the SDK's
shared-space path: everything about it travels the same relay as the video.

Nothing pops on its own. A bubble that reaches the top of the field accelerates
away and is dropped once it is well out of shot, so every pop in the game is one
somebody caused and a score is the whole story of the round. The field only
counts the reachable ones against its capacity, so the ones on their way out do
not leave the playable part empty behind them.

**Turn it on.** Set the video source to **AR scene**, go live, and press
**Bubbles**. A scoreboard appears at the top with everybody's count. There is no
setup handshake to wait for — a device that finds the space unclaimed claims it.

**Who simulates.** One participant runs the field and the rest render what
arrives. The scoreboard says which you are, and the two are meant to be
indistinguishable to play. Nobody chooses this: `SpaceSession` claims an unheard
space after a quiet interval, stands down when it sees a higher epoch, and
settles a two-way tie by name. A host that walks into a tunnel is replaced
inside a few seconds, and the bubbles that were up stay up, because the successor
continues from the last state it received rather than starting a new world.

**What a tap does.** A viewer cannot write to the space — one writer is what
keeps the two devices from disagreeing. A tap publishes a `SpaceIntent` on the
tapper's own track instead, and whoever is simulating decides. The pop is drawn
immediately on the tapper's screen and reconciled from the next authoritative
update, so a race is resolved by the loser seeing the winner's name on the score
rather than by their own bubble un-popping.

**Scripted.** Neither half needs a finger to test:

```sh
MOQOM_ROOM=bubbles MOQOM_VIDEO=scene MOQOM_BUBBLES=1 MOQOM_POP_EVERY=2 \
    MOQOM_SECONDS=60 Scripts/bench-two-phones.sh
```

`--pop-every` stands in for a tap, and both logs then carry a `SPACE` line each
report with the role, the bubbles up, and every score. Diffing the two is the
test: the scores are replicated state, so a line that disagrees between the
phones is replication failing — which neither phone can tell you on its own,
since each renders its own copy perfectly happily.

A sixty-second run through the Los Angeles relay: one authority, one follower,
61 pops between them, and identical scoreboards on both handsets at every
report. Video ran alongside it the whole time at 720p thirty frames a second,
66ms glass to glass on the follower, nothing dropped or unroutable.

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
RealityKit tap. Those compile and are only exercised on hardware — the AR path
has since been run on two phones through a relay, at 60 frames a second each way
with nothing skipped, which is the first thing to drive the SDK's RealityKit hook
end to end. The shared bubble field has been run the same way, with scripted
pops in place of taps; what remains unexercised on hardware there is the tap
itself — the raycast into the bubble and the optimistic hide — since everything
downstream of it is what the scripted run drives. `Broadcast` also
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
