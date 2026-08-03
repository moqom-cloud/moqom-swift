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
  MOQOM_FPS=60           capture and publish rate (default: 30)
  MOQOM_KBPS=2000        publish bitrate
  MOQOM_AUDIO=mic        publish audio: mic, or tone for a synthetic source
  MOQOM_VIDEO=camera     publish video: camera, pattern, or scene for the AR orb
  MOQOM_PLAYOUT_MS=40    fixed playout delay, instead of the adaptive one
  MOQOM_CALL=1           publish the layout's rung, as a call does, not a pinned one
  MOQOM_EAGER=1          encode for speed rather than power, at the cost of heat
  MOQOM_FLOOR_MS / MOQOM_TOLERANCE / MOQOM_STATS_MS / MOQOM_FLAT_LAYERS
  MOQOM_PUBLISHER / MOQOM_VIEWER   device names (default: iPhone Air, 15 Pro)
  MOQOM_MINT=1           mint a token per phone from the deployed control plane
  MOQOM_TENANT=moqom     which tenant, and it must be the token's

For example:
  MOQOM_ROOM=turn3 MOQOM_SECONDS=20 MOQOM_FPS=60 MOQOM_AUDIO=mic ./Scripts/bench-two-phones.sh
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
TENANT="${MOQOM_TENANT:-moqom}"
PUBLISHER_TOKEN="${MOQOM_PUBLISHER_TOKEN:-}"
VIEWER_TOKEN="${MOQOM_VIEWER_TOKEN:-}"
if [ -n "${MOQOM_MINT:-}" ]; then
    JOIN="${MOQOM_JOIN:-$HERE/../../../moqom/deploy/tools/join.sh}"
    if [ ! -x "$JOIN" ]; then
        echo "MOQOM_MINT is set but $JOIN is not there — set MOQOM_JOIN to it" >&2
        exit 2
    fi
    echo "minting a token for each phone"
    PUBLISHER_TOKEN="$(MOQOM_TENANT=$TENANT "$JOIN" publisher "$ROOM")"
    VIEWER_TOKEN="$(MOQOM_TENANT=$TENANT "$JOIN" viewer "$ROOM")"
fi

# Where the relay is. Bonjour discovery by default, which only works for the relay on this Mac —
# a pairing code is a local-network mechanism and there is nothing to discover across the
# internet. With MOQOM_RELAY_HOST set, as relay-on-gcp.sh writes it, the phones are told the
# address and the certificate to expect instead.
FPS="${MOQOM_FPS:-30}"
if [ -n "${MOQOM_RELAY_HOST:-}" ]; then
    WHERE="--relay-host $MOQOM_RELAY_HOST --relay-port ${MOQOM_RELAY_PORT:-4443}"
    if [ -n "${MOQOM_RELAY_CERT_HASH:-}" ]; then
        WHERE="$WHERE --relay-cert-hash $MOQOM_RELAY_CERT_HASH"
    fi
    echo "relay: $MOQOM_RELAY_HOST:${MOQOM_RELAY_PORT:-4443}"
else
    WHERE="--pairing-code $CODE"
    echo "relay: whatever answers to pairing code $CODE on this network"
fi
WHERE="$WHERE --fps $FPS${MOQOM_FLAT_LAYERS:+ --flat-layers}"
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
WHERE="$WHERE${MOQOM_BUBBLES:+ --bubbles}"
WHERE="$WHERE${MOQOM_POP_EVERY:+ --pop-every $MOQOM_POP_EVERY}"

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
    xcrun devicectl device process terminate --device "$device" \
        --bundle-id "$BUNDLE" >/dev/null 2>&1 || true
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
    if grep -q '^LIVE' "$PUBLISHER_LOG" 2>/dev/null; then break; fi
    sleep 2
    waited=$((waited + 2))
done
if ! grep -q '^LIVE' "$PUBLISHER_LOG" 2>/dev/null; then
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
        if grep -q '^LIVE' "$VIEWER_LOG" 2>/dev/null; then break; fi
        sleep 1
        waited=$((waited + 1))
    done
    if ! grep -q '^LIVE' "$VIEWER_LOG" 2>/dev/null; then
        echo "the late joiner never went live — see $VIEWER_LOG" >&2
    fi
    sleep "$MOQOM_SECONDS"

    # The console launches are background jobs holding a pipe this script's caller is reading, so
    # leaving them behind means a bounded run neither ends nor prints, and the apps keep streaming
    # long after anybody stopped watching. Consoles first, then the apps they were attached to.
    for job in $(jobs -p); do kill "$job" 2>/dev/null || true; done
    pkill -f "devicectl device process launch.*$BUNDLE" >/dev/null 2>&1 || true

    for device in "$PUBLISHER" "$VIEWER"; do
        xcrun devicectl device process terminate --device "$device" \
            --bundle-id "$BUNDLE" >/dev/null 2>&1 || true
    done

    # Both logs' last report, which is what a short run is for. Printed here so the answer is in
    # the terminal that asked rather than in two files somebody has to go and read.
    for log in "$PUBLISHER_LOG" "$VIEWER_LOG"; do
        echo
        echo "--- $log"
        grep -E '^(LINK|GLASS|PLAY|TIME|DRAW|SHOW|GRAB|SEEN|HOST|SEND|COST|TALK|HEAR|OUT|  SPKR|  VIEW)' \
            "$log" | tail -14
    done
    exit 0
fi

wait
