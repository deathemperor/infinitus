#!/bin/sh
# Dev loop: rebuild the bundle and relaunch Infinitus whenever a source
# file changes. Closest thing to hot reload that fits headless CLI dev —
# make-app.sh keeps the same bundle path, so notification/login grants
# survive each relaunch. entr, not watchexec: watchexec 2.7 fails to
# spawn anything on this machine ("No such file or directory").
#
# UNBUNDLED=1 ./dev.sh relaunches through run-unbundled.sh instead of
# `open` — the workaround while a ControlCenter session is wedged.
# Relaunches are debounced to one per 10s: rapid relaunch churn is what
# wedged ControlCenter in the first place (docs/TODO.md, 2026-08-29).
cd "$(dirname "$0")" || exit 1
command -v entr >/dev/null || { echo "needs entr (brew install entr)"; exit 1; }
while :; do
    # -d: exit when a NEW file appears so the outer loop re-lists;
    # -n: no TTY (runs fine in the background).
    find Sources -name '*.swift' | entr -n -d sh -c '
        sleep 1                                  # coalesce save bursts
        ./make-app.sh || exit 0                  # build errors: no relaunch
        now=$(date +%s); last=$(cat .dev-relaunch 2>/dev/null || echo 0)
        gap=$(( now - last ))
        [ "$gap" -lt 10 ] && sleep $(( 10 - gap ))
        date +%s > .dev-relaunch
        if [ -n "${UNBUNDLED:-}" ]; then
            ./run-unbundled.sh
        else
            pkill -x Infinitus
            open Infinitus.app
        fi
        echo "== relaunched $(date +%H:%M:%S)"'
done
