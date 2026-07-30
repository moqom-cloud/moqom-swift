#!/bin/sh
# What the relay saw, from the relay's side.
#
# The third measurement, and the one neither phone can make. A publisher knows what it sent and a
# viewer knows what arrived; only the relay knows the round trip to each of them separately, which
# is what splits a bad glass-to-glass figure into a bad uplink and a bad downlink.
#
# Read over the SSH tunnel rather than an opened port. An observability endpoint on a public
# address is the kind of thing that stays open long after the experiment it was opened for.
set -eu

ENV_FILE="${MOQOM_GCP_ENV:-/tmp/moqom-gcp-relay.env}"
if [ -r "$ENV_FILE" ]; then . "$ENV_FILE"; fi

PROJECT="${MOQOM_GCP_PROJECT:-moqom-503700}"
ZONE="${MOQOM_GCP_ZONE:-us-west1-a}"
INSTANCE="${MOQOM_GCP_INSTANCE:-moqom-relay-bench}"

export CLOUDSDK_METRICS_ENVIRONMENT=datacloud.cursor

# The same dedicated key relay-on-gcp.sh uses, for the same reason: a passphrase-protected
# default key turns an unattended read into an unanswerable prompt.
KEY="${MOQOM_GCP_SSH_KEY:-$HOME/.ssh/moqom_bench}"
SSH="gcloud --project=$PROJECT --quiet compute ssh $INSTANCE --zone=$ZONE --ssh-key-file=$KEY --strict-host-key-checking=no"

case "${1:-summary}" in
raw)
    $SSH --command='curl -s localhost:9443/metrics'
    ;;
tracks)
    $SSH --command='curl -s localhost:9443/tracks; echo; curl -s localhost:9443/sessions'
    ;;
log)
    $SSH --command='journalctl -u moqom-relay -n 60 --no-pager'
    ;;
*)
    # The lines worth reading, named. A full scrape is a hundred series and the four that answer
    # "is the server the problem" are lost in it.
    $SSH --command='curl -s localhost:9443/metrics' \
        | grep -E '^moqom_relay_(sessions|rooms|participants|tracks|tracks_silent|objects_forwarded_total|subgroups_total|forwarded_bytes_total|ingress_bytes_total|egress_bytes_total|udp_(rx|tx)_bytes_total|lost_packets_total|congestion_events_total|connection_rtt_seconds|fanout_failures_total|refusals_total)'
    ;;
esac
