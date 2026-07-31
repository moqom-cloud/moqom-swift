#!/bin/sh
# Pull the log the app keeps in its own container off both phones.
#
# For the runs nobody scripted. `devicectl` only pipes stdout for a process it started itself,
# so a session driven by thumb — join, go live, change the layout, watch a tile stay black —
# produces no console anywhere, and relaunching it from here to get one is a different run.
# The app writes the same lines to a file as it prints them; this fetches it.
#
# Install the current build first if the app predates the journal, or this will find nothing.
set -eu

BUNDLE="cloud.moqom.room"
OUT="${MOQOM_OUT:-/tmp}"

device() {
    xcrun devicectl list devices 2>/dev/null \
        | awk -v name="$1" '
            $0 ~ name && (/available/ || /connected/) {
                for (i = 1; i <= NF; i++) {
                    if ($i ~ /^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-/) { print $i; exit }
                }
            }'
}

fetch() {
    name="$1"
    id="$(device "$name")"
    if [ -z "$id" ]; then
        echo "no device matching '$name'" >&2
        return 1
    fi

    # Onto a filename, not a directory: the copy writes the destination path it is given and
    # refuses one that already exists as a directory.
    slug="$(echo "$name" | tr ' ' '-')"
    rm -f "$OUT/moqom-$slug.log"
    xcrun devicectl device copy from \
        --device "$id" \
        --domain-type appDataContainer \
        --domain-identifier "$BUNDLE" \
        --source Documents/moqom.log \
        --destination "$OUT/moqom-$slug.log" > /dev/null

    if [ ! -s "$OUT/moqom-$slug.log" ]; then
        echo "nothing came back from $name" >&2
        return 1
    fi
    echo "$OUT/moqom-$slug.log"
}

for phone in "${MOQOM_PUBLISHER:-iPhone Air}" "${MOQOM_VIEWER:-15 Pro}"; do
    fetch "$phone" || true
done
