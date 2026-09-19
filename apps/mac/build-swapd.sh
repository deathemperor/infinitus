#!/bin/sh
# Build a reproducible engine for release bundles, without installing it on PATH.
set -eu
: "${INFINITUS_ENGINE_BUILD_ROOT:?Set INFINITUS_ENGINE_BUILD_ROOT to a build directory}"
# swapd 0.3.0 + #44: `auto-ignite <slot> on|off`, and the flag edits answer from the store without waiting 5 s for the engine lock (#1481).
# + #47: a pass reads its slots' keychain items a few at a time; `list` on a 13-slot fleet went 0.93 s -> 0.36 s.
cargo install --locked --git https://github.com/deathemperor/swapd \
    --rev ffe34f65e0560de0d61a50ef6c342c4c6166abb7 \
    --root "$INFINITUS_ENGINE_BUILD_ROOT" swapd
"$INFINITUS_ENGINE_BUILD_ROOT/bin/swapd" --version
