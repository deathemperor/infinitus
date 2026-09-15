#!/bin/sh
# Build a reproducible engine for release bundles, without installing it on PATH.
set -eu
: "${INFINITUS_ENGINE_BUILD_ROOT:?Set INFINITUS_ENGINE_BUILD_ROOT to a build directory}"
cargo install --locked --git https://github.com/deathemperor/swapd \
    --rev 219aefe349de4e8c9c8904bc8407127308f63c8b \
    --root "$INFINITUS_ENGINE_BUILD_ROOT" swapd
"$INFINITUS_ENGINE_BUILD_ROOT/bin/swapd" --version
