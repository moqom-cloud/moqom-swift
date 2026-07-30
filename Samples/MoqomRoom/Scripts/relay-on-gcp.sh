#!/bin/sh
# Put a relay on a Compute Engine instance and print what the phones need to reach it.
#
# On a VM rather than Cloud Run, and that is forced: MOQT is QUIC, QUIC is UDP, and Cloud Run
# accepts TCP only. A serverless relay is not a configuration away, it is a different transport.
#
# Reached by address with a pinned certificate rather than by name with a public one. The pinning
# path is already how the phones talk to the relay on the Mac, so this changes one leg of the test
# — the network — and nothing else. Certificate issuance and DNS are their own days of work and
# neither of them makes a latency number more honest.
#
# Idempotent throughout. Run it again to rebuild and restart the relay on the instance that is
# already there; run it after deleting the instance and it builds a new one.
set -eu

PROJECT="${MOQOM_GCP_PROJECT:-moqom-503700}"
ZONE="${MOQOM_GCP_ZONE:-us-west1-a}"
INSTANCE="${MOQOM_GCP_INSTANCE:-moqom-relay-bench}"
MACHINE="${MOQOM_GCP_MACHINE:-e2-standard-4}"
PORT="${MOQOM_RELAY_PORT:-4443}"
ENGINE="$(cd "$(dirname "$0")/../../../../moqom-engine" && pwd)"
ENV_FILE="${MOQOM_GCP_ENV:-/tmp/moqom-gcp-relay.env}"

# Attribution for anything this script creates, and the flag form on every call rather than
# `gcloud config set project`: a script that mutates the caller's default project is a script that
# breaks the next unrelated command they run.
export CLOUDSDK_METRICS_ENVIRONMENT=datacloud.cursor
GCLOUD="gcloud --project=$PROJECT --quiet"

# A key of this script's own rather than the usual ~/.ssh/google_compute_engine. That one is
# very often passphrase-protected, and an unattended run cannot answer the prompt: ssh reaches
# for an askpass program that does not exist on a Mac and fails as "Permission denied
# (publickey)", which reads like an authorisation problem rather than a locked key.
KEY="${MOQOM_GCP_SSH_KEY:-$HOME/.ssh/moqom_bench}"
if [ ! -r "$KEY" ]; then
    ssh-keygen -q -t ed25519 -N '' -C moqom-bench -f "$KEY"
fi
SSH_ARGS="--ssh-key-file=$KEY --strict-host-key-checking=no"

say() { printf '%s\n' "$*"; }

say "project $PROJECT, zone $ZONE, instance $INSTANCE"

# Enabling is a no-op when it is already on, and the failure without it is a permission error that
# reads like a credentials problem.
$GCLOUD services enable compute.googleapis.com >/dev/null

# One rule for the media port. Opened to the internet because the phones are behind whatever
# network they are on and their addresses are not knowable in advance; the relay's own quotas and
# the fact that it speaks only MOQT are what limit it. The admin port is deliberately not opened —
# it is read over the SSH tunnel below.
if ! $GCLOUD compute firewall-rules describe moqom-relay-media >/dev/null 2>&1; then
    say "opening udp/$PORT"
    $GCLOUD compute firewall-rules create moqom-relay-media \
        --direction=INGRESS --action=ALLOW --rules="udp:$PORT" \
        --source-ranges=0.0.0.0/0 --target-tags=moqom-relay >/dev/null
fi

if ! $GCLOUD compute instances describe "$INSTANCE" --zone="$ZONE" >/dev/null 2>&1; then
    say "creating $INSTANCE ($MACHINE)"
    # Four cores for the build rather than for the relay, which forwards a couple of megabits
    # without noticing. The default network tier is premium, which is the point of putting it
    # here: the leg being measured should be Google's backbone, not the public internet's worst
    # path between two consumer ISPs.
    $GCLOUD compute instances create "$INSTANCE" \
        --zone="$ZONE" --machine-type="$MACHINE" --tags=moqom-relay \
        --image-family=debian-12 --image-project=debian-cloud \
        --boot-disk-size=40GB --boot-disk-type=pd-balanced >/dev/null
fi

ADDRESS="$(
    $GCLOUD compute instances describe "$INSTANCE" --zone="$ZONE" \
        --format='value(networkInterfaces[0].accessConfigs[0].natIP)'
)"
say "address $ADDRESS"

run() { $GCLOUD compute ssh "$INSTANCE" --zone="$ZONE" $SSH_ARGS --command="$1"; }

# SSH comes up after the instance reports RUNNING, so the first attempt on a fresh instance fails
# on connection refused rather than on anything worth reporting.
say "waiting for ssh"
attempt=1
while [ "$attempt" -le 30 ]; do
    if run true >/dev/null 2>&1; then break; fi
    attempt=$((attempt + 1))
    sleep 5
done
run true >/dev/null 2>&1 || { say "ssh never came up"; exit 1; }

say "installing the toolchain"
run 'set -eu
    if [ ! -x "$HOME/.cargo/bin/cargo" ]; then
        sudo apt-get update -qq
        sudo apt-get install -y -qq build-essential pkg-config >/dev/null
        curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal >/dev/null
    fi' >/dev/null

# Source over the wire as a tarball rather than a recursive copy: the build directory is several
# gigabytes and `scp --recurse` has no idea it should be left behind.
say "copying the relay source"
TARBALL="$(mktemp -t moqom-engine)"
trap 'rm -f "$TARBALL"' EXIT
# COPYFILE_DISABLE because macOS tar otherwise stores its extended attributes, and GNU tar on the
# far side prints a warning for every file it does not understand — several hundred lines of noise
# that buries whatever the build says afterwards.
COPYFILE_DISABLE=1 tar czf "$TARBALL" -C "$ENGINE" \
    --exclude=target --exclude=.git --exclude=fuzz/target .
$GCLOUD compute scp "$TARBALL" "$INSTANCE:/tmp/moqom-engine.tgz" --zone="$ZONE" \
    $SSH_ARGS >/dev/null

say "building (several minutes the first time)"
run 'set -eu
    rm -rf ~/moqom-engine && mkdir -p ~/moqom-engine
    tar xzf /tmp/moqom-engine.tgz -C ~/moqom-engine
    cd ~/moqom-engine
    . "$HOME/.cargo/env"
    cargo build --release -p moqom-relay --bin moqom-relay 2>&1 | tail -3'

# A certificate that outlives the experiment, so a restart does not invalidate the hash already
# typed into two phones. The address goes in as a SAN even though pinning does not check names:
# a certificate that describes what it is for costs nothing and reads correctly in a packet trace.
say "preparing tls"
run "set -eu
    if [ ! -r ~/relay-tls/cert.pem ]; then
        mkdir -p ~/relay-tls
        openssl req -x509 -newkey rsa:2048 -sha256 -days 365 -nodes \
            -keyout ~/relay-tls/key.pem -out ~/relay-tls/cert.pem \
            -subj '/CN=moqom-relay' -addext 'subjectAltName=IP:$ADDRESS' 2>/dev/null
    fi" >/dev/null

say "installing the service"
# Under systemd rather than nohup, because a relay that dies when the SSH session ends is a relay
# that dies halfway through a fifteen minute run for reasons nobody will connect to the SSH client.
#
# Limits off on purpose. Unauthenticated sessions are charged to the address the relay sees, and
# both phones arrive from one home NAT: with limits on, the second phone is refused by a quota
# designed to stop exactly what this test is doing.
#
# The receive buffer is raised because quinn cannot pace what the kernel has already dropped, and
# the default 208KB is small enough to lose bursts on a link this fast.
run "set -eu
    sudo tee /etc/sysctl.d/99-moqom.conf >/dev/null <<'SYSCTL'
net.core.rmem_max = 8388608
net.core.wmem_max = 8388608
SYSCTL
    sudo sysctl -q --system

    sudo tee /etc/systemd/system/moqom-relay.service >/dev/null <<UNIT
[Unit]
Description=moqom relay
After=network-online.target

[Service]
ExecStart=/home/\$USER/moqom-engine/target/release/moqom-relay
Environment=MOQOM_RELAY_ADDR=0.0.0.0:$PORT
Environment=MOQOM_RELAY_CERT=/home/\$USER/relay-tls/cert.pem
Environment=MOQOM_RELAY_KEY=/home/\$USER/relay-tls/key.pem
Environment=MOQOM_RELAY_ADMIN_ADDR=127.0.0.1:9443
Environment=MOQOM_RELAY_LIMITS=off
Environment=RUST_LOG=info
User=\$USER
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT
    sudo systemctl daemon-reload
    sudo systemctl enable --now moqom-relay >/dev/null 2>&1
    sudo systemctl restart moqom-relay" >/dev/null

# Through a file rather than a pipe, for the reason pair-relay.sh gives: openssl writes DER as
# binary and some builds quietly produce nothing when it is piped straight into the digest, which
# yields a plausible hash of an empty input.
HASH="$(
    run 'set -eu
        openssl x509 -in ~/relay-tls/cert.pem -outform DER -out /tmp/relay.der
        openssl dgst -sha256 -binary /tmp/relay.der | base64' | tr -d '\r\n'
)"

sleep 2
STATE="$(run 'systemctl is-active moqom-relay' | tr -d '\r\n')"
say ""
say "relay $STATE on $ADDRESS:$PORT"
say "certificate $HASH"

cat > "$ENV_FILE" <<EOF
MOQOM_RELAY_HOST=$ADDRESS
MOQOM_RELAY_PORT=$PORT
MOQOM_RELAY_CERT_HASH=$HASH
MOQOM_GCP_PROJECT=$PROJECT
MOQOM_GCP_ZONE=$ZONE
MOQOM_GCP_INSTANCE=$INSTANCE
EOF

cat <<EOF

Written to $ENV_FILE, which bench-two-phones.sh reads. To run the two phones through it:

  . $ENV_FILE && export MOQOM_RELAY_HOST MOQOM_RELAY_PORT MOQOM_RELAY_CERT_HASH
  Scripts/bench-two-phones.sh

The relay's own view, over the SSH tunnel rather than an open port:

  Scripts/relay-metrics-gcp.sh
EOF
