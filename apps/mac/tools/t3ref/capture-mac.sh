#!/bin/bash
# capture-mac.sh <screen> <out.png> — screenshots the running T3 Code (Alpha) window on <screen>.
# Needs Screen Recording permission for the terminal that runs it, or
# `screencapture -l` writes a blank/desktop frame.
set -euo pipefail
usage='usage: capture-mac.sh <sidebar|thread|composer|panel-{diff,files,pr,terminal,agents}> <out.png>'
screen=${1:?$usage}
out=${2:?$usage}
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
  # The right panel on one tab (B-41). Read-only UI driving: the app is
  # activated, the panel toggle is pressed if the panel is shut, the tab is
  # pressed, and nothing else — 0.0.40's strip carries one tab per OPEN
  # SURFACE plus an "Add panel surface" launcher (`RightPanelTabs.tsx:1009`,
  # `RightPanelEmptyState` at `:293`), and opening a surface persists in the
  # user's app (and forks a real shell for Terminal), so a missing tab is
  # reported, never created.
  panel-*)
    case "${screen#panel-}" in
      diff) label=Diff ;;
      files) label=Files ;;
      pr) label="Pull request" ;;
      # A terminal surface's tab is titled by its terminal, not "Terminal"
      # (`surfaceTitle`, `RightPanelTabs.tsx:598-602`) — pass T3REF_TAB_LABEL
      # to name it.
      terminal) label=${T3REF_TAB_LABEL:-Terminal} ;;
      agents) label=Agents ;;
      *) echo "unknown screen $screen" >&2; exit 2 ;;
    esac
    if [ ! -x "$here/.build/axpress" ] || [ "$here/axpress.swift" -nt "$here/.build/axpress" ]; then
        mkdir -p "$here/.build"; swiftc -O "$here/axpress.swift" -o "$here/.build/axpress"
    fi
    ax="$here/.build/axpress"
    pid=$(pgrep -f "MacOS/T3 Code \(Alpha\)$" | head -1)
    [ -n "$pid" ] || { echo "no T3 Code process" >&2; exit 3; }
    # `open -a` is the only activation that works from a command-line tool
    # here (NSRunningApplication.activate leaves whoever was in front there),
    # and axpress refuses to press anything unless that pid is frontmost.
    open -a "/Applications/T3 Code (Alpha).app"
    sleep 1
    # "Maximize panel" exists only while the right panel is open.
    "$ax" find "$pid" "Maximize panel" >/dev/null 2>&1 || {
        "$ax" press "$pid" "Toggle right panel" >/dev/null || exit 5
        sleep 2
    }
    read -r _wid ww _wh wx wy <<<"$("$ax" win "$pid" | head -1)"
    # The tab strip is the top bar's height (52 pt) over the panel column;
    # `--exact` keeps "Agents" off "Close Agents", the rect keeps it off a
    # sidebar thread of the same name.
    if ! "$ax" press "$pid" "$label" --exact --in "$((wx + ww - 620)),$wy,620,52"; then
        echo "no '$label' tab: that surface is not open in the reference, and the harness never adds one" >&2
        exit 5
    fi
    ;;
  *) echo "unknown screen $screen" >&2; exit 2 ;;
esac
# `open` returns as soon as the URL is handed over; the window still has to
# route, load the thread and settle its animations. 1 s caught half-drawn
# frames, so the settle is 3.
sleep 3
screencapture -x -o -l"$id" "$out"
echo "window $id ${w}x${h} pt → $out ($(sips -g pixelWidth -g pixelHeight "$out" | awk '/pixel/{printf "%s ", $2}'))"
