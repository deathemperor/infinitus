#!/bin/sh
# Build a reproducible engine for release bundles, without installing it on PATH.
set -eu
: "${INFINITUS_ENGINE_BUILD_ROOT:?Set INFINITUS_ENGINE_BUILD_ROOT to a build directory}"
cargo install --locked --git https://github.com/deathemperor/swapd \
    --rev a1253c5ee9d4ef3c130bb78581892c2fc959a7a7 \
    --root "$INFINITUS_ENGINE_BUILD_ROOT" swapd
"$INFINITUS_ENGINE_BUILD_ROOT/bin/swapd" --version
