#!/bin/bash
# capture-ios.sh <screen> <out.png> — opens the T3 dev client on <screen> in the booted simulator and screenshots it.
# zsh ties $path to PATH and reads $T:thread as a history modifier, so this
# uses `route`/`${T}` names throughout (spec §0).
set -euo pipefail
screen=${1:?usage: capture-ios.sh <screen> <out.png>}
out=${2:?usage: capture-ios.sh <screen> <out.png>}
# Only the thread-scoped routes need the two ids, so `home`/`newtask`/
# `settings` capture with neither exported. There is no `usage` route in
# this build — `t3code-dev://usage` answers "Route not found".
thread_route() {
    local E T
    E=${T3_ENV_ID:?set T3_ENV_ID — cat ~/.t3/userdata/environment-id}
    T=${T3_THREAD_ID:?set T3_THREAD_ID — sqlite3 ~/.t3/userdata/state.sqlite: select thread_id from projection_threads}
    printf 'threads/%s/%s%s' "$E" "$T" "$1"
}
app=com.t3tools.t3code.dev
case "$screen" in
  # `t3code-dev://` with an empty route does not land on the thread list —
  # it hands off to whichever app answered the scheme last. Home is the
  # client's own first screen, so relaunch it instead of deep-linking.
  home)
    xcrun simctl terminate booted "$app" >/dev/null 2>&1 || true
    xcrun simctl launch booted "$app" >/dev/null
    # A cold client pulls its bundle from Metro before it draws anything;
    # 6 s lands on the splash. Override with T3_LAUNCH_WAIT when Metro is slow.
    sleep "${T3_LAUNCH_WAIT:-25}"
    xcrun simctl io booted screenshot "$out" >/dev/null
    echo "→ $out"; exit 0 ;;
  thread) route=$(thread_route "") ;;
  git) route=$(thread_route /git) ;;
  review) route=$(thread_route /review) ;;
  files) route=$(thread_route /files) ;;
  terminal) route=$(thread_route /terminal) ;;
  newtask) route="new" ;;
  settings) route="settings" ;;
  *) echo "unknown screen $screen" >&2; exit 2 ;;
esac
xcrun simctl openurl booted "t3code-dev://$route"
# 3 s of settle for the route transition on top of the 6 s warm-app render
# wait: `openurl` returns before the navigation starts, so the render wait
# on its own could time the shot on the outgoing screen.
sleep 9
xcrun simctl io booted screenshot "$out" >/dev/null
echo "→ $out"
