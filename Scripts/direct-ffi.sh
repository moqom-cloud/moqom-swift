#!/usr/bin/env bash
#
# Build moqom-direct-ffi and copy its xcframework into Artifacts/, which turns
# on the MoqomDirectRust module and its tests (see the end of Package.swift).
#
#   Scripts/direct-ffi.sh            # build in ../moqom-engine, then copy
#   Scripts/direct-ffi.sh --copy     # copy what is already built
#   Scripts/direct-ffi.sh --remove   # back to Network.framework only
#
# MOQOM_ENGINE points at moqom-engine if it is not a sibling of this repository.
#
# The manifest cache is purged afterwards. SwiftPM caches the evaluated manifest
# by its text, which does not change when a file appears beside it, so without
# the purge the package goes on looking the way it did.

set -euo pipefail

cd "$(dirname "$0")/.."
ENGINE="${MOQOM_ENGINE:-../moqom-engine}"
FRAMEWORK="$ENGINE/target/MoqomDirectFFI.xcframework"

case "${1:-}" in
--remove)
    rm -rf Artifacts/MoqomDirectFFI.xcframework
    ;;
--copy)
    ;;
*)
    bash "$ENGINE/moqom-direct-ffi/build-apple.sh"
    ;;
esac

if [[ "${1:-}" != "--remove" ]]; then
    if [[ ! -d "$FRAMEWORK" ]]; then
        echo "no $FRAMEWORK; build it first" >&2
        exit 1
    fi
    rm -rf Artifacts/MoqomDirectFFI.xcframework
    mkdir -p Artifacts
    cp -R "$FRAMEWORK" Artifacts/
    echo "==> Artifacts/MoqomDirectFFI.xcframework"
fi

swift package purge-cache
