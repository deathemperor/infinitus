#!/bin/sh
# Build a reproducible engine for release bundles, without installing it on PATH.
set -eu
: "${INFINITUS_ENGINE_BUILD_ROOT:?Set INFINITUS_ENGINE_BUILD_ROOT to a build directory}"
# swapd 0.2.2: show weekly pace starting one minute after reset.
cargo install --locked --git https://github.com/deathemperor/swapd \
    --rev 3d43075d2ffefdfb71ffef8e3f5d2672d4eb13b0 \
    --root "$INFINITUS_ENGINE_BUILD_ROOT" swapd
"$INFINITUS_ENGINE_BUILD_ROOT/bin/swapd" --version
