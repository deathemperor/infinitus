#!/bin/sh
# Build a reproducible engine for release bundles, without installing it on PATH.
set -eu
: "${INFINITUS_ENGINE_BUILD_ROOT:?Set INFINITUS_ENGINE_BUILD_ROOT to a build directory}"
# swapd 0.3.0 + #44: `auto-ignite <slot> on|off`, and the flag edits answer from the store without waiting 5 s for the engine lock (#1481).
# + #47: a pass reads its slots' keychain items a few at a time; `list` on a 13-slot fleet went 0.93 s -> 0.36 s.
# + #48: an account the daemon benched for a dead refresh token reports `relogin-required` instead of listing healthy, so the re-login it needs is offered on the row.
# + #50: `add-oauth` asks for the seven scopes Claude Code itself sends; claude.ai refuses the old five-scope subset with "Invalid request format", which failed every browser sign-in and re-login on its first page.
cargo install --locked --git https://github.com/deathemperor/swapd \
    --rev bd2db6fa3e3782cde6670d129b0025b4ee83d9df \
    --root "$INFINITUS_ENGINE_BUILD_ROOT" swapd
"$INFINITUS_ENGINE_BUILD_ROOT/bin/swapd" --version
