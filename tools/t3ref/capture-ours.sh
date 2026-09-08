#!/bin/bash
# capture-ours.sh <mac|ios> <screen> <out.png> — the same screen in Infinitus,
# for `compare.py refs/<platform>-<screen>.png <out.png>`.
#
# Mac: the debug app's workspace window over the control socket (fixture.sh's
# socket by default). `infinitusctl show workspace <screen>` is the route
# sub-project B adds next to `show wall`; until then this prints "not yet"
# and exits 4.
# iOS: `infinitus://t3/<screen>` — sub-project C adds the deep link.
set -euo pipefail
platform=${1:?usage: capture-ours.sh <mac|ios> <screen> <out.png>}
screen=${2:?usage: capture-ours.sh <mac|ios> <screen> <out.png>}
out=${3:?usage: capture-ours.sh <mac|ios> <screen> <out.png>}
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
case "$platform" in
  mac)
    ctl="$root/.build/debug/infinitusctl"
    [ -x "$ctl" ] || { echo "build first: swift build --product infinitusctl" >&2; exit 2; }
    export INFINITUS_CONTROL_SOCKET=${INFINITUS_CONTROL_SOCKET:-/tmp/t3fix.sock}
    if ! "$ctl" show workspace "$screen" >/dev/null 2>&1; then
        echo "not yet: infinitusctl show workspace <screen> lands with sub-project B" >&2; exit 4
    fi
    [ -x "$here/.build/winlist" ] || { mkdir -p "$here/.build"; swiftc -O "$here/winlist.swift" -o "$here/.build/winlist"; }
    line=$("$here/.build/winlist" Infinitus) || { echo "no Infinitus window on screen" >&2; exit 3; }
    read -r id _w _h <<<"$line"
    sleep 1
    screencapture -x -o -l"$id" "$out"
    ;;
  ios)
    if ! xcrun simctl openurl booted "infinitus://t3/$screen" 2>/dev/null; then
        echo "not yet: infinitus://t3/<screen> lands with sub-project C" >&2; exit 4
    fi
    sleep 6
    xcrun simctl io booted screenshot "$out" >/dev/null
    ;;
  *) echo "unknown platform $platform" >&2; exit 2 ;;
esac
echo "→ $out"
