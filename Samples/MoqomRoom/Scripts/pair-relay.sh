#!/bin/sh
# Advertise a running development relay under a four digit code.
#
# What the phones actually need is an address and the SHA-256 of the certificate the relay
# signed for itself, and typing 44 characters of base64 into two phones is how a test run ends
# up debugging a typo. So the Mac publishes both over Bonjour and the phone looks them up by a
# code short enough to type: the pin is still the exact certificate, and only the typing got
# shorter.
#
# Runs alongside the relay rather than inside it. Nothing here needs the relay's cooperation —
# the certificate is a file on disk and the hash is a digest of it — and keeping it out means a
# development convenience cannot end up in a deployed binary.
#
# Usage: pair-relay.sh [code]
#
# Environment:
#   MOQOM_RELAY_CERT  the relay's certificate, PEM (default /tmp/relay-tls/cert.pem)
#   MOQOM_RELAY_PORT  the port it listens on (default 4443)
#   MOQOM_RELAY_ADDR  the address to advertise (default: this Mac's Wi-Fi address)

set -eu

CODE="${1:-4242}"
CERT="${MOQOM_RELAY_CERT:-/tmp/relay-tls/cert.pem}"
PORT="${MOQOM_RELAY_PORT:-4443}"

if [ ! -r "$CERT" ]; then
    echo "no certificate at $CERT — set MOQOM_RELAY_CERT to the one the relay was started with" >&2
    exit 1
fi

# Wi-Fi specifically, and not the first address that answers. A Mac on Ethernet with Wi-Fi up,
# or running a VPN, has several, and the phones can only reach the one they share a network
# with. Override MOQOM_RELAY_ADDR when that guess is wrong.
ADDR="${MOQOM_RELAY_ADDR:-$(ipconfig getifaddr en0 || true)}"
if [ -z "$ADDR" ]; then
    echo "could not find this Mac's address — set MOQOM_RELAY_ADDR" >&2
    exit 1
fi

# Through a file rather than a pipe: openssl writes DER as binary and piping it straight into
# the digest silently produces nothing on some builds, which yields a valid-looking
# advertisement carrying the hash of an empty input.
DER="$(mktemp -t moqom-relay-cert)"
trap 'rm -f "$DER"' EXIT
openssl x509 -in "$CERT" -outform DER -out "$DER"
HASH="$(openssl dgst -sha256 -binary "$DER" | base64)"

echo "advertising $ADDR:$PORT as code $CODE"
echo "certificate $HASH"
echo "enter $CODE as the pairing code on each phone, on this Wi-Fi network. Ctrl-C to stop."

# Registration lasts as long as this process does, which is the behaviour worth having: the
# advertisement cannot outlive the relay it describes and go on pointing phones at a port that
# stopped listening.
exec dns-sd -R "moqom-$CODE" _moqom-relay._udp local "$PORT" \
    "addr=$ADDR" "port=$PORT" "hash=$HASH"
