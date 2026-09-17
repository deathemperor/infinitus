#!/bin/sh
# Build a reproducible engine for release bundles, without installing it on PATH.
set -eu
: "${INFINITUS_ENGINE_BUILD_ROOT:?Set INFINITUS_ENGINE_BUILD_ROOT to a build directory}"
# swapd 0.2.1: retry Keychain after temporary failures so auto-switching recovers.
cargo install --locked --git https://github.com/deathemperor/swapd \
    --rev 4fc16d4024068f41ac75436ffff20b28fd7c1616 \
    --root "$INFINITUS_ENGINE_BUILD_ROOT" swapd
"$INFINITUS_ENGINE_BUILD_ROOT/bin/swapd" --version
