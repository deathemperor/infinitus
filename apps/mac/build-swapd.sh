#!/bin/sh
# Build a reproducible engine for release bundles, without installing it on PATH.
set -eu
: "${INFINITUS_ENGINE_BUILD_ROOT:?Set INFINITUS_ENGINE_BUILD_ROOT to a build directory}"
# swapd 0.3.0 + #44: `auto-ignite <slot> on|off`, and the flag edits answer from the store without waiting 5 s for the engine lock (#1481).
# + #47: a pass reads its slots' keychain items a few at a time; `list` on a 13-slot fleet went 0.93 s -> 0.36 s.
# + #48: an account the daemon benched for a dead refresh token reports `relogin-required` instead of listing healthy, so the re-login it needs is offered on the row.
# + #50, #51: `add-oauth` asks for the seven scopes Claude Code itself sends; claude.ai refuses the old five-scope subset with "Invalid request format", which failed every browser sign-in and re-login on its first page. A grant that names no scope is stored as the claude.ai set.
# + #52: `add-oauth` sends a 32-byte `state`, as Claude Code does; claude.ai refuses the 16-byte one with "Invalid request format" — the actual cause of the failed sign-ins, bisected in the browser.
# + #54 (0.3.1): a profile credential without a refresh token is not read back as a rotation.
# + #56: `list` reports each account's banked Claude limit resets as `resets`, and `reset <slot>` spends one as that slot (#1554).
# 0.3.2: #56 released, with #57 (a test).
# + #60: with every account spent, one whose reset has already passed is re-checked after a minute, not five; the daemon had slept past the account coming back.
# 0.3.3: #60 released.
cargo install --locked --git https://github.com/deathemperor/swapd \
    --rev c32c7f0606f9ebd6ef34c3c2df0d2741bedca768 \
    --root "$INFINITUS_ENGINE_BUILD_ROOT" swapd
"$INFINITUS_ENGINE_BUILD_ROOT/bin/swapd" --version
