#!/bin/sh
# Build a reproducible engine for release bundles, without installing it on PATH.
set -eu
: "${INFINITUS_ENGINE_BUILD_ROOT:?Set INFINITUS_ENGINE_BUILD_ROOT to a build directory}"
# swapd 0.3.0: `auto-ignite <slot> on|off`, the keep-warm flag the Accounts page toggles.
cargo install --locked --git https://github.com/deathemperor/swapd \
    --rev 8dd8c7244339fa33191a6134f45777b0648f6415 \
    --root "$INFINITUS_ENGINE_BUILD_ROOT" swapd
"$INFINITUS_ENGINE_BUILD_ROOT/bin/swapd" --version
