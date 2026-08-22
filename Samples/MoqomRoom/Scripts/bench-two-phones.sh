#!/bin/sh
# Run the two-phone benchmark: install the current Release build on both devices, join them to
# the same room through the relay on this Mac, and capture each one's console to a file.
#
# Release rather than Debug, and that is not a detail. The same link measured on a Debug build
# spent 11.4% of the run with the picture held and stalled 42 times; on Release it was 0.5% and
# three times. A Debug build invents stutter of its own and there is no point measuring it.
#
# The publisher goes first and the second phone joins late, because the two orders exercise
# different code: the late joiner needs the other's catalog restated to it, which is the failure
# that made one direction of this test work and the other stay black.
#
# Both phones must be unlocked, with Auto-Lock off — a locked phone refuses the launch outright,
# and one that locks mid-run takes its camera with it.
set -eu

# Settings come from the environment, and anything on the command line is a mistake — so it is
# refused rather than ignored. Ignoring it was worse than it sounds: three runs invoked with
# `--room`, `--seconds` and `--video` ran instead with the defaults, for as long as nobody
# stopped them, with no audio published at all, and the numbers they produced were read as a
# latency regression and a broken microphone. A run that does not do what it was asked should
# say so before it starts, not encode the difference into its output.
if [ "$#" -gt 0 ]; then
    cat >&2 <<'USAGE'
This script takes no arguments; everything is an environment variable.

  MOQOM_ROOM=name        room to join (default: bench)
  MOQOM_SECONDS=20       stop after this long, and print each log's last report
  MOQOM_FPS=60           capture and publish rate (default: the app's own, 30)
  MOQOM_KBPS=2000        publish bitrate
  MOQOM_AUDIO=mic        publish audio: mic, or tone for a synthetic source
  MOQOM_VIDEO=camera     publish video: camera, pattern, or scene for the AR orb
  MOQOM_PLAYOUT_MS=40    fixed playout delay, instead of the adaptive one
  MOQOM_RESHAPE_EVERY=6  turn the publisher's picture on its side this often, and back
  MOQOM_CALL=1           publish the layout's rung, as a call does, not a pinned one
  MOQOM_EAGER=1          encode for speed rather than power, at the cost of heat
  MOQOM_BUBBLES=1        pop bubbles on a timer, which is what BURST reports on. Going
                         live joins the field on its own, so 0 is the setting that means
                         something new: no field, and therefore no RealityKit at all
  MOQOM_POP_EVERY=2      pop a bubble this often, since a scripted run has no finger.
                         Needs MOQOM_BUBBLES, and it is what fills in `mine` and `trip`
                         on BURST — without it the only bursts are the other phone's.
  MOQOM_FLOOR_MS / MOQOM_TOLERANCE / MOQOM_STATS_MS / MOQOM_FLAT_LAYERS
  MOQOM_PUBLISHER / MOQOM_VIEWER   device names (default: iPhone Air, 15 Pro)
  MOQOM_MINT=1           mint a token per phone from the deployed control plane
  MOQOM_TENANT=moqom     which tenant, and it must be the token's

For example:
  MOQOM_ROOM=turn3 MOQOM_SECONDS=20 MOQOM_AUDIO=mic ./Scripts/bench-two-phones.sh
USAGE
    exit 2
fi

# Checked here rather than passed through, because the app has to choose something and a
# wrong value spends the whole run being the wrong thing quietly. MOQOM_AUDIO=1 reads like
# "yes, audio" and published a test tone, which is audible, plausible, and not what was asked.
case "${MOQOM_AUDIO:-mic}" in
    mic | tone) ;;
    *)
        echo "MOQOM_AUDIO must be mic or tone, not '$MOQOM_AUDIO'" >&2
        exit 2
        ;;
esac
case "${MOQOM_VIDEO:-camera}" in
    camera | pattern | scene) ;;
    *)
        echo "MOQOM_VIDEO must be camera, pattern or scene, not '$MOQOM_VIDEO'" >&2
        exit 2
        ;;
esac

ROOM="${MOQOM_ROOM:-bench}"
CODE="${MOQOM_PAIRING_CODE:-4242}"
BUNDLE="cloud.moqom.room"
HERE="$(cd "$(dirname "$0")/.." && pwd)"

# Who the relay thinks these phones are.
#
# A deployed relay verifies the token a session presents and permits nothing to
# a session with none — it connects, announces, and every track is refused,
# which from the phone is indistinguishable from a relay that drops everything.
# So a run against one needs a token per phone, and the tenant has to be the
# tenant the token was minted for.
#
# Minted here rather than checked in, because they expire in fifteen minutes.
# The relay against a laptop has no keys and needs none of this, which is why
# this is off unless asked for.
#
# A pasted token now bounds the run and not just the joining of it: a relay with
# keys closes a session whose credential has lapsed, and a token handed in this
# way cannot replace itself. That collides with the advice at the bottom of this
# file to give a run fifteen minutes or more — so for the long runs, enrol the
# phones with the join service instead (MOQOM_JOIN_* on the Join screen, or a
# scanned link) and they fetch and renew their own credentials for as long as the
# run lasts.
TENANT="${MOQOM_TENANT:-moqom}"
PUBLISHER_TOKEN="${MOQOM_PUBLISHER_TOKEN:-}"
VIEWER_TOKEN="${MOQOM_VIEWER_TOKEN:-}"
if [ -n "${MOQOM_MINT:-}" ]; then
    JOIN="${MOQOM_JOIN:-$HERE/../../../moqom/deploy/tools/join.sh}"
    if [ ! -x "$JOIN" ]; then
        echo "MOQOM_MINT is set but $JOIN is not there — set MOQOM_JOIN to it" >&2
        exit 2
    fi
    # Each phone's own thumbprint, which its join screen prints beneath the
    # username. There is no default and there cannot be one: a token is bound to
    # a key in that phone's Secure Enclave, and one minted against any other
    # thumbprint is refused by a relay requiring proof of possession. Read them
    # off the two screens once; they do not change.
    if [ -z "${MOQOM_PUBLISHER_DEVICE:-}" ] || [ -z "${MOQOM_VIEWER_DEVICE:-}" ]; then
        echo "MOQOM_MINT needs MOQOM_PUBLISHER_DEVICE and MOQOM_VIEWER_DEVICE:" >&2
        echo "  the thumbprint each phone's join screen prints under its username" >&2
        echo "  (or leave MOQOM_MINT unset and enrol both with the join service)" >&2
        exit 2
    fi
    echo "minting a token for each phone"
    PUBLISHER_TOKEN="$(MOQOM_TENANT=$TENANT "$JOIN" publisher "$ROOM" "$MOQOM_PUBLISHER_DEVICE")"
    VIEWER_TOKEN="$(MOQOM_TENANT=$TENANT "$JOIN" viewer "$ROOM" "$MOQOM_VIEWER_DEVICE")"
fi

# Where the relay is. The app already dials the compiled-in GCP endpoint. A host
# here overrides that; a pairing code is the room, not a lookup.
if [ -n "${MOQOM_RELAY_HOST:-}" ]; then
    WHERE="--relay-host $MOQOM_RELAY_HOST --relay-port ${MOQOM_RELAY_PORT:-4443}"
    if [ -n "${MOQOM_RELAY_CERT_HASH:-}" ]; then
        WHERE="$WHERE --relay-cert-hash $MOQOM_RELAY_CERT_HASH"
    fi
    echo "relay: $MOQOM_RELAY_HOST:${MOQOM_RELAY_PORT:-4443}"
else
    WHERE=""
    echo "relay: compiled-in GCP default"
fi
# Unset unless asked for, so the rate is the app's own and a measured run cannot drift from a
# hand-opened one. Naming a default here is what made them disagree before: the same binary,
# different frame rates, and nothing on any line of output saying which you were reading.
WHERE="$WHERE${MOQOM_FPS:+ --fps $MOQOM_FPS}${MOQOM_FLAT_LAYERS:+ --flat-layers}"
WHERE="$WHERE${MOQOM_EAGER:+ --eager-encoding}"
WHERE="$WHERE${MOQOM_KBPS:+ --kbps $MOQOM_KBPS}"
WHERE="$WHERE${MOQOM_STATS_MS:+ --stats-ms $MOQOM_STATS_MS}"
WHERE="$WHERE${MOQOM_PLAYOUT_MS:+ --playout-ms $MOQOM_PLAYOUT_MS}"
WHERE="$WHERE${MOQOM_TOLERANCE:+ --tolerance $MOQOM_TOLERANCE}"
WHERE="$WHERE${MOQOM_FLOOR_MS:+ --floor-ms $MOQOM_FLOOR_MS}"
WHERE="$WHERE${MOQOM_AUDIO:+ --audio $MOQOM_AUDIO}"
WHERE="$WHERE${MOQOM_VIDEO:+ --video $MOQOM_VIDEO}"
# Joins the shared bubble field on both phones. Only does anything with
# MOQOM_VIDEO=scene, since the bubbles are entities in the AR session's view —
# and the reason to script it at all is that the state is meant to be identical
# on both devices, which is a thing to diff two logs for rather than to judge by
# glancing between two screens.
# Three states, not two. Unset is what the app does on its own — going live joins the field
# whatever the video source is — so `--bubbles` only adds the scripted popping on top of it,
# and 0 is the only way to ask for a run with no field and therefore no RealityKit in it.
case "${MOQOM_BUBBLES:-}" in
    "") ;;
    0 | no | off) WHERE="$WHERE --no-bubbles" ;;
    *) WHERE="$WHERE --bubbles" ;;
esac
WHERE="$WHERE${MOQOM_POP_EVERY:+ --pop-every $MOQOM_POP_EVERY}"
# Turns the publisher's picture on its side and back on a timer, which is a layout change
# without a thumb. On a timer because the evidence is in the other phone's log and has to be
# lined up against the moment: the publisher prints SHAPE, and the viewer's DRAW line should
# change its `shape=` and add one to `reshapes` without its gap or stall counters moving.
WHERE="$WHERE${MOQOM_RESHAPE_EVERY:+ --reshape-every $MOQOM_RESHAPE_EVERY}"

# A measured run or a call. The difference is which rung gets published — a pinned one, or the
# one the layout on screen asks for — and it is worth being able to script both, because for a
# while only the pinned path was ever scripted and only the other path was ever used.
MODE="--benchmark"
if [ -n "${MOQOM_CALL:-}" ]; then
    MODE="--live"
    echo "mode: call — the rung comes from the layout, as it does under a thumb"
fi

# By name rather than by hard-coded identifier, so this survives a re-pair. The identifier is
# found by its shape rather than its column, because the state field ("available (paired)")
# contains a space and counting columns lands on the wrong one.
#
# Two spellings of usable, because a phone that has just had a tunnel torn down reports
# "connected" for a while before it says "available (paired)" again. Matching only the second
# makes a rerun immediately after a previous run fail to find phones that are sitting right there.
device() {
    xcrun devicectl list devices 2>/dev/null \
        | awk -v name="$1" '
            $0 ~ name && (/available/ || /connected/) {
                for (i = 1; i <= NF; i++) {
                    if ($i ~ /^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-/) { print $i; exit }
                }
            }'
}

PUBLISHER_NAME="${MOQOM_PUBLISHER:-iPhone Air}"
VIEWER_NAME="${MOQOM_VIEWER:-15 Pro}"

PUBLISHER="$(device "$PUBLISHER_NAME")"
VIEWER="$(device "$VIEWER_NAME")"

if [ -z "$PUBLISHER" ] || [ -z "$VIEWER" ]; then
    echo "could not find both devices — is each one plugged in, unlocked, and paired?" >&2
    xcrun devicectl list devices >&2
    exit 1
fi

# Passed on the command line rather than relied on from the project, because the project is
# generated: `xcodegen generate` rewrites the team to whatever `project.yml` names, and the
# team that can sign on the machine running this is not necessarily that one. The failure is
# also unhelpfully worded — "Supported platforms ... is empty" — so a run that lost this would
# look like a broken toolchain rather than a missing account.
TEAM="${MOQOM_TEAM:-LHS49D8RYY}"

echo "building Release"
APP="$(
    xcodebuild -project "$HERE/MoqomRoom.xcodeproj" -scheme MoqomRoom \
        -destination 'generic/platform=iOS' -configuration Release \
        DEVELOPMENT_TEAM="$TEAM" \
        -showBuildSettings 2>/dev/null \
        | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{d=$2} / FULL_PRODUCT_NAME/{n=$2} END{print d"/"n}'
)"
xcodebuild -project "$HERE/MoqomRoom.xcodeproj" -scheme MoqomRoom \
    -destination 'generic/platform=iOS' -configuration Release \
    DEVELOPMENT_TEAM="$TEAM" \
    -allowProvisioningUpdates build >/dev/null

# Retried, because the tunnel to a phone on Wi-Fi is not reliable enough to assume. It resets,
# times out, and occasionally reports the device as disconnected the instant after connecting,
# none of which says anything about whether the install would have worked. A run abandoned for
# that reason wastes the setup around it.
persist() {
    what="$1"
    shift
    attempt=1
    while [ "$attempt" -le 8 ]; do
        if "$@" >/tmp/moqom-devicectl.log 2>&1; then return 0; fi
        echo "  $what failed (attempt $attempt), retrying"
        attempt=$((attempt + 1))
        sleep 4
    done
    echo "$what did not succeed after $((attempt - 1)) attempts:" >&2
    tail -12 /tmp/moqom-devicectl.log >&2
    return 1
}

# Stopping the app, which takes the process and not the bundle.
#
# `devicectl device process terminate` accepts `--pid` and refuses `--bundle-id`. This script
# asked it for the second, with the usage error sent to /dev/null and `|| true` after it, so
# the call has never stopped anything. Both places that meant to stop the app were doing
# nothing at all: every bounded run left the apps capturing, encoding and publishing after it
# printed its summary, and the only thing that ever ended one was the next run's
# `--terminate-existing`. That is the abandoned session the comment below the launch loop
# describes at length — arranged for rather than avoided — and a run interrupted before its
# teardown left a phone streaming until somebody noticed.
stop() {
    xcrun devicectl device info processes --device "$1" 2>/dev/null \
        | awk '$2 ~ /MoqomRoom\.app\/MoqomRoom$/ { print $1 }' \
        | while read -r pid; do
            xcrun devicectl device process terminate \
                --device "$1" --pid "$pid" >/dev/null 2>&1 || true
        done
}

# So does a run that is cut short, which is the case the teardown at the bottom cannot cover.
# An interrupted sweep left a phone publishing to the relay on its own, and the picture the
# next run put on screen was judged against it.
trap 'echo; echo "interrupted — stopping both phones"; for d in "$PUBLISHER" "$VIEWER"; do stop "$d"; done; exit 130' INT TERM

# The log each phone keeps for itself, and where this script leaves its copy.
JOURNAL="moqom.log"
journal() { echo "$LOGS-$1.journal.log"; }
collect() {
    rm -f "$2"
    xcrun devicectl device copy from --device "$1" \
        --domain-type appDataContainer --domain-identifier "$BUNDLE" \
        --source "Documents/$JOURNAL" --destination "$2" >/dev/null 2>&1 || true
}

# Whether a phone has gone live, asked of the log in its own container.
#
# Not of the console, which on the build this script makes is empty. ``Journal`` prints only
# under DEBUG — two live console streams over Wi-Fi stalled both phones' transport writes at
# once, so Release writes the file and sends nothing off the device. Waiting on a console line
# that cannot arrive is not a slow check, it is a check that always fails: every run spent
# ninety seconds and then three hundred deciding neither phone had started, printed two empty
# summaries, and left the numbers on the phones.
went_live() {
    rm -f /tmp/moqom-live-probe.log
    xcrun devicectl device copy from --device "$1" \
        --domain-type appDataContainer --domain-identifier "$BUNDLE" \
        --source "Documents/$JOURNAL" --destination /tmp/moqom-live-probe.log \
        >/dev/null 2>&1 || return 1
    grep -q ' LIVE ' /tmp/moqom-live-probe.log
}

for device in "$PUBLISHER" "$VIEWER"; do
    echo "installing on $device"
    persist "install on $device" \
        xcrun devicectl device install app --device "$device" "$APP"
done

# Killed before launching rather than relying on --terminate-existing, and waited out.
#
# A previous instance does not stop when its console is disconnected: it keeps capturing,
# encoding and publishing under the same participant identity. Two sessions announcing one
# identity is bad enough, but the failure is worse than duplication — when the abandoned session
# finally times out at the relay, its namespace withdrawal takes the live instance's publication
# with it, and both phones sit there with a frozen picture, `rung=none` and no catalog, for
# reasons nothing in the new run's own log explains.
#
# The pause is the relay's idle timeout: launching into a room the old sessions have not yet been
# evicted from reproduces exactly what it is meant to avoid.
for device in "$PUBLISHER" "$VIEWER"; do
    stop "$device"
done
sleep 5

# Launched in a loop of its own, for the same reason installs are retried, plus one more: a
# launch that fails because the tunnel dropped looks nothing like a launch that fails because
# the phone is locked, and only the second is worth telling somebody about.
launch() {
    device="$1"
    who="$2"
    out="$3"
    token="${4:-}"
    (
        # Patient rather than prompt, because the thing being waited for is often a person. A
        # phone that locks itself between the install and the launch refuses the launch, and
        # sixty seconds of retrying is not long enough for somebody to notice, pick it up, and
        # unlock it. Ten minutes is, and a run that starts as soon as the phone is unlocked is
        # worth far more than one that gave up quietly two minutes earlier.
        attempt=1
        while [ "$attempt" -le 200 ]; do
            # Unquoted on purpose: $WHERE is several flags, not one argument.
            # shellcheck disable=SC2086
            # `|| true` because of `set -e` at the top, which without it makes this loop a
            # lie: the first refused launch would exit the subshell outright, so the two
            # hundred attempts and the message about unlocking the phone were both dead
            # code, and every locked-phone run appeared to give up instantly.
            xcrun devicectl device process launch --device "$device" --console \
                --terminate-existing "$BUNDLE" \
                --autojoin $MODE --username "$who" --room "$ROOM" \
                --tenant "$TENANT" ${token:+--relay-token "$token"} $WHERE \
                > "$out" 2>&1 || true
            # Printed by the console only once the process is actually up.
            if grep -q 'Waiting for the application to terminate' "$out"; then exit 0; fi
            # Said once rather than on every attempt: the whole point of retrying for this long
            # is that somebody may be walking over to the phone, and two hundred identical
            # lines scrolling past is how they miss the one that matters.
            if grep -q 'reason: Locked' "$out" && [ "$attempt" -eq 1 ]; then
                echo "$who is locked — unlock it and this will pick it up" >&2
            fi
            attempt=$((attempt + 1))
            sleep 3
        done
        echo "gave up launching $who" >&2
    ) &
}

# Named after the run rather than after the role, because two runs writing to one path is how a
# previous generation's numbers end up being read as this one's.
LOGS="/tmp/moqom-$ROOM"
PUBLISHER_LOG="$LOGS-publisher.log"
VIEWER_LOG="$LOGS-viewer.log"
: > "$PUBLISHER_LOG"
: > "$VIEWER_LOG"

echo "launching $PUBLISHER_NAME as the publisher"
launch "$PUBLISHER" publisher "$PUBLISHER_LOG" "$PUBLISHER_TOKEN"

# Waited on the publisher actually going live rather than on a fixed delay, because the point of
# the ordering is that the second phone arrives at a room that is already broadcasting. A sleep
# long enough to be safe on a slow tunnel is a sleep wasted on every fast one.
waited=0
while [ "$waited" -lt 90 ]; do
    if went_live "$PUBLISHER"; then break; fi
    sleep 5
    waited=$((waited + 5))
done
if ! went_live "$PUBLISHER"; then
    echo "the publisher never went live — see $PUBLISHER_LOG" >&2
fi

echo "launching $VIEWER_NAME as the late joiner"
launch "$VIEWER" viewer "$VIEWER_LOG" "$VIEWER_TOKEN"

cat <<EOF

Running. Reports appear every five seconds in:
  $PUBLISHER_LOG
  $VIEWER_LOG

What each line means:
  LINK   one-way latency percentiles, with the clock's error bar. Treat a median narrower
         than the ± as an impression rather than a measurement.
  PLAY   arrival cadence: frame rate, the gap between frames, and stalls. This is what
         "choppy" is. An even stream has a p95 gap close to its median. onkey and every
         attribute the stalls: onkey close to the stall count, spaced at the keyframe
         interval, means the encoder's own group boundaries are the stutter.
  GRAB   the same on the frames going into the encoder, so an uneven picture can be blamed
         on capture or on everything after it.
  SEND   what the publisher did with them. unroutable=0 is the one to watch: anything else
         means frames are being encoded and discarded, which used to be silent.
  VIEW   per publisher — the rung subscribed, the rung offered, and whether anything arrived.
  BURST  how fast a bubble popping crosses, on the same relay as the picture. wire is a
         burst the other phone decided, one way; trip is one this phone asked for, there
         and back. Read wire against LINK: the space track is lower priority than video,
         so it is the first thing a tight link starves. Only with MOQOM_BUBBLES.

Give it fifteen minutes or more. The failure worth catching only appeared after eleven.
EOF

# A bounded run, for the loop where somebody is watching the picture rather than waiting for a
# failure that takes a quarter of an hour to appear. Ten seconds of streaming is plenty to judge
# smoothness and is the difference between five iterations an hour and thirty.
if [ -n "${MOQOM_SECONDS:-}" ]; then
    # Patient for the same reason the launch loop is: the thing being waited for is often a person
    # walking over to a phone that locked itself. A bounded run whose bound starts before the run
    # does measures nothing and reports it as a result.
    waited=0
    while [ "$waited" -lt 300 ]; do
        if went_live "$VIEWER"; then break; fi
        sleep 5
        waited=$((waited + 5))
    done
    if ! went_live "$VIEWER"; then
        echo "the late joiner never went live — see $VIEWER_LOG" >&2
    fi
    sleep "$MOQOM_SECONDS"

    # The console launches are background jobs holding a pipe this script's caller is reading, so
    # leaving them behind means a bounded run neither ends nor prints, and the apps keep streaming
    # long after anybody stopped watching. Consoles first, then the apps they were attached to.
    for job in $(jobs -p); do kill "$job" 2>/dev/null || true; done
    pkill -f "devicectl device process launch.*$BUNDLE" >/dev/null 2>&1 || true

    for device in "$PUBLISHER" "$VIEWER"; do
        stop "$device"
    done

    # Both logs' last report, which is what a short run is for. Printed here so the answer is in
    # the terminal that asked rather than in two files somebody has to go and read.
    # Off the phones rather than out of the consoles, which on a Release build are empty. See
    # ``went_live``. Fetched after the apps are stopped so the last report is in the file.
    collect "$PUBLISHER" "$(journal publisher)"
    collect "$VIEWER" "$(journal viewer)"

    for log in "$(journal publisher)" "$(journal viewer)"; do
        echo
        echo "--- $log"
        # The timestamp `Journal` stamps every line with is why this is not anchored at the
        # start: these lines are prefixed in the file and were not on the console.
        # Eighteen because that is how many kinds of line one report is now, SPACE and
        # BURST included. A tail shorter than the report shows part of it and part of the
        # one before, which reads as a report whose numbers contradict each other.
        grep -E '^\S+ (LINK|GLASS|PLAY|TIME|DRAW|SHOW|GRAB|SEEN|HOST|SEND|COST|TALK|HEAR|OUT|SPKR|VIEW|SPACE|BURST)' \
            "$log" 2>/dev/null | tail -18
    done

    # A run that changed shape gets its own answer, because the tail above cannot give it: the
    # question is not what the last report said but whether the picture followed the publisher
    # each time and cost nothing when it did. So: every shape the viewer decoded in order,
    # against every change the publisher made.
    if [ -n "${MOQOM_RESHAPE_EVERY:-}" ]; then
        echo
        echo "--- shape changes"
        grep -h '^\S* SHAPE' "$(journal publisher)" | sed 's/^/publisher: /'
        # Only when it changes, so a run of identical reports collapses to the moments that
        # matter. The stall count comes along because a seam that cost a freeze shows up there
        # and nowhere else.
        grep -o 'shape=[0-9x]* reshapes=[0-9]*' "$(journal viewer)" | awk '
            $0 != last { print "viewer:    " $0; last = $0 }'
    fi
    exit 0
fi

wait
