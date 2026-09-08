#!/bin/bash
# capture-mac.sh <screen> <out.png> — screenshots the running T3 Code (Alpha) window on <screen>.
# Needs Screen Recording permission for the terminal that runs it, or
# `screencapture -l` writes a blank/desktop frame.
set -euo pipefail
screen=${1:?usage: capture-mac.sh <sidebar|thread|composer> <out.png>}
out=${2:?usage: capture-mac.sh <sidebar|thread|composer> <out.png>}
here=$(cd "$(dirname "$0")" && pwd)
[ -x "$here/.build/winlist" ] || { mkdir -p "$here/.build"; swiftc -O "$here/winlist.swift" -o "$here/.build/winlist"; }
line=$("$here/.build/winlist" "T3 Code") || { echo "no T3 Code window on screen — open the app first" >&2; exit 3; }
read -r id w h <<<"$line"
[ -n "${id:-}" ] || { echo "winlist gave no window id" >&2; exit 3; }
case "$screen" in
  # The app is already on the fixture thread; these screens differ by focus
  # only. `t3code://<environmentId>/<threadId>` routes to a thread when
  # T3_ENV_ID/T3_THREAD_ID are exported (apps/desktop `protocol`, routes
  # mirroring the web router) — otherwise the bare scheme just raises it.
  sidebar|thread|composer)
    if [ -n "${T3_ENV_ID:-}" ] && [ -n "${T3_THREAD_ID:-}" ]; then
        open "t3code://${T3_ENV_ID}/${T3_THREAD_ID}"
    else
        open "t3code://"
    fi
    ;;
  *) echo "unknown screen $screen" >&2; exit 2 ;;
esac
sleep 1
screencapture -x -o -l"$id" "$out"
echo "window $id ${w}x${h} pt → $out ($(sips -g pixelWidth -g pixelHeight "$out" | awk '/pixel/{printf "%s ", $2}'))"
