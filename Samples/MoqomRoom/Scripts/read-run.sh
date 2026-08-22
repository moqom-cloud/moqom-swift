#!/bin/sh
# Read a run's journals and answer the two questions a run is usually asked: was it smooth, and
# did the phone get hot.
#
# `bench-two-phones.sh` prints each log's *last* report, which answers the first question and
# cannot answer the second. Heat is a trajectory — a phone that ends a run at `fair` and one that
# reached `fair` after four minutes print the same final line — so the interesting figures are
# when the state changed and how fast the battery went down, neither of which is in any single
# report.
#
# The smoothness half exists because the numbers that matter are spread across three lines and
# one of them only means something next to another. `LINK frames` and `DRAW shown` straddle the
# whole receive path: everything between them is this device's own doing, so the two disagreeing
# is the difference between a link that lost frames and a phone that threw them away. That
# distinction took a whole evening to find by hand, and every figure needed to spot it was
# already being printed.
set -eu

if [ "$#" -eq 0 ]; then
    cat >&2 <<'USAGE'
Usage: read-run.sh ROOM [ROOM...]      the room name a bench run was given
       read-run.sh FILE [FILE...]      a journal copied off a phone by hand

Reads /tmp/moqom-ROOM-publisher.journal.log and -viewer.journal.log, which is
where bench-two-phones.sh leaves them.

  Scripts/read-run.sh smooth1
  Scripts/read-run.sh heatAR heatCam     two arms side by side
USAGE
    exit 2
fi

# One log at a time. Everything here is per-device: two phones on the same call can differ by a
# lot, and averaging them hides exactly the case where one is fine and the other is not.
report() {
    log="$1"
    [ -r "$log" ] || return 0

    awk -v LOG="$log" '
        # A value by name rather than by column, because these lines grow fields over time and
        # counting positions is how a reader silently starts printing the wrong number.
        function field(s, key,   v) {
            if (match(s, key "=[^ ]+")) {
                v = substr(s, RSTART + length(key) + 1, RLENGTH - length(key) - 1)
                gsub(/[%x]$/, "", v)
                return v
            }
            return ""
        }
        function secs(t,   a) { split(t, a, ":"); return a[1] * 3600 + a[2] * 60 + a[3] }
        # Runs cross midnight rarely and silently, and a negative duration turns a drain rate
        # into a negative number rather than into an error.
        function span(from, to,   d) { d = to - from; return d < 0 ? d + 86400 : d }
        function pct(x) { return x == "" ? "?" : x }

        {
            stamp = $1
            if (first == "") first = stamp
            last = stamp
        }

        / LIVE / {
            live = stamp
            source = field($0, "source")
            rate = field($0, "fps")
            rung = field($0, "rung")
        }

        # Whether there was a voice in the run at all. None of these line kinds appears in a run
        # published with audio off, which is what the bench does unless MOQOM_AUDIO is set — so a
        # heat figure taken from one describes the video path on its own. Measured on the same
        # scene and the same phone, adding the microphone, the speaker and lip sync moved the
        # drain from 0.89 to about 1.39 %/min and brought `fair` forward from eight minutes to
        # under four, which is enough to reverse a comparison drawn between the two.
        $2 == "TALK" || $2 == "HEAR" || $2 == "SPKR" { audio = 1 }

        / LINK latency frames=/ { received = field($0, "frames"); quality = field($0, "quality") }

        / PLAY cadence / {
            fps = field($0, "fps")
            # `gap p50=` and `p95=`, which is why these are read off the tail of the line rather
            # than by the bare key: LINK carries the same two names for a different thing.
            median = field($0, "p50")
            tail = field($0, "p95")
            worst = field($0, "max")
            uneven = field($0, "uneven")
            freezes = field($0, "freezes")
            frozen = field($0, "frozen")
        }

        / DRAW shown=/ {
            shown = field($0, "shown")
            delivered = field($0, "delivered")
            rebases = field($0, "rebases")
            notready = field($0, "notready")
            undescribed = field($0, "undescribed")
            # The old spelling, so a journal from before the counters were straightened out
            # still reads correctly rather than reporting a blank.
            if (notready == "") notready = field($0, "late")
        }

        / HOST / {
            state = field($0, "thermal")
            charge = field($0, "charge")
            power = field($0, "power")
            if (states == 0 || state != lastState) {
                states++
                changeAt[states] = stamp
                changeTo[states] = state
                lastState = state
            }
            if (firstCharge == "") { firstCharge = charge; chargeFrom = stamp }
            lastCharge = charge
            chargeTo = stamp
            if (power == "plugged") plugged = 1
        }

        END {
            printf "\n--- %s\n", LOG
            if (received == "" && shown == "") {
                print "  nothing was measured — the run never reached a report"
                exit
            }

            if (source != "") printf "  published   %s at %sfps, rung %s\n", source, rate, rung

            print "  smoothness"
            # The comparison the whole receive path hangs on, stated as a sentence because the
            # two numbers being equal is the point and a reader should not have to subtract.
            if (received != "" && shown != "") {
                lost = received - shown
                if (lost <= 0)
                    printf "    frames    %s arrived, all of them reached the screen\n", received
                else
                    printf "    frames    %s arrived but only %s reached the screen — %s lost inside the phone\n",
                        received, shown, lost
            }
            printf "    cadence   %s fps, gap %sms typical / %sms at p95 / %sms worst, %sx uneven\n",
                fps, median, tail, worst, uneven
            printf "    stalls    %s, %s%% of the run frozen\n",
                (freezes == "0" ? "none" : freezes " freezes"), pct(frozen)
            printf "    delivery  %s%% delivered", pct(delivered)
            if (rebases != "") printf ", %s rebases", rebases
            if (notready != "" && notready != "0") printf ", %s dropped not-ready", notready
            if (undescribed != "" && undescribed != "0") printf ", %s undescribed", undescribed
            printf "\n"
            if (quality != "") printf "    link      %s\n", quality

            print "  heat"
            if (states == 0) {
                print "    nothing reported"
            } else {
                base = (live != "" ? live : first)
                if (states == 1) {
                    printf "    thermal   %s for the whole run\n", changeTo[1]
                } else {
                    for (i = 1; i <= states; i++) {
                        if (i == 1)
                            printf "    thermal   started %s\n", changeTo[i]
                        else
                            printf "              %s at %.1f min\n",
                                changeTo[i], span(secs(base), secs(changeAt[i])) / 60
                    }
                }
                minutes = span(secs(chargeFrom), secs(chargeTo)) / 60
                if (firstCharge != "" && minutes > 0) {
                    drop = firstCharge - lastCharge
                    printf "    battery   %s%% to %s%% over %.1f min", firstCharge, lastCharge, minutes
                    if (drop > 0) printf " — %.2f %%/min", drop / minutes
                    printf "\n"
                }
                # The two things that quietly invalidate a heat reading, said here rather than
                # left for somebody to notice a fortnight later. A charging phone is warmed by
                # the charging and its drain rate means nothing; a short run has not had time to
                # reach the state worth measuring — the Air took about eight minutes.
                if (plugged) print "    ! plugged in — this tells you nothing about drain"
                if (minutes < 10)
                    printf "    ! only %.1f min — too short to judge heat, give it fifteen\n", minutes
                if (!audio)
                    print "    ! audio was off — this is the video path alone, not a call." \
                        " Add MOQOM_AUDIO=mic"
            }
        }
    ' "$log"
}

for what in "$@"; do
    if [ -r "$what" ]; then
        report "$what"
    else
        found=""
        for role in publisher viewer; do
            log="/tmp/moqom-$what-$role.journal.log"
            if [ -r "$log" ]; then
                found=1
                report "$log"
            fi
        done
        if [ -z "$found" ]; then
            echo "no journals for '$what' — expected /tmp/moqom-$what-publisher.journal.log" >&2
            echo "(a run that was interrupted never collected them; they are still on the phone)" >&2
        fi
    fi
done
