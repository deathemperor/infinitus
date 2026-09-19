#!/bin/sh
# Build a reproducible engine for release bundles, without installing it on PATH.
set -eu
: "${INFINITUS_ENGINE_BUILD_ROOT:?Set INFINITUS_ENGINE_BUILD_ROOT to a build directory}"
# swapd 0.3.0 + #44: `auto-ignite <slot> on|off`, and the flag edits answer from the store without waiting 5 s for the engine lock (#1481).
cargo install --locked --git https://github.com/deathemperor/swapd \
    --rev 426a75ecedabefc59f191cd36e9e5eb90787fe13 \
    --root "$INFINITUS_ENGINE_BUILD_ROOT" swapd
"$INFINITUS_ENGINE_BUILD_ROOT/bin/swapd" --version
