#!/bin/bash
# capture-ours.sh <mac|ios> <screen> <out.png> — the same screen in Infinitus,
# for `compare.py refs/<platform>-<screen>.png <out.png>`.
#
# Mac: the debug app's workspace window over the control socket (fixture.sh's
# socket by default), through `infinitusctl show workspace <screen>`. Exits 4
# when no app answers that socket, or when it refuses the screen name.
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
        echo "no app on $INFINITUS_CONTROL_SOCKET, or it refused the screen '$screen'" >&2; exit 4
    fi
    # A cold app answers the first request before its thread list exists, so
    # the screen lands on "Pick a thread to continue"; the request is one-shot
    # and idempotent, so ask again once the list is there.
    sleep 2
    "$ctl" show workspace "$screen" >/dev/null 2>&1 || true
    if [ ! -x "$here/.build/winlist" ] || [ "$here/winlist.swift" -nt "$here/.build/winlist" ]; then
        mkdir -p "$here/.build"; swiftc -O "$here/winlist.swift" -o "$here/.build/winlist"
    fi
    # The workspace and the menu-bar pop-out share the normal window layer and
    # the pop-out is listed first whenever it is open (#442), so ask for the
    # workspace by its own frame — the one the README's parity procedure
    # presets. Without the preset there is nothing to match on and the first
    # window wins, as before.
    # T3REF_WINDOW_SIZE=WxH wins over the preset: the app writes the frame
    # BACK into that default on every move/resize (and clamps a preset whose
    # screen rect names no attached display to its fallback size), so after
    # the first capture the default no longer says what the reference wants.
    want=${T3REF_WINDOW_SIZE:-$(defaults read Infinitus "NSWindow Frame Workspace" 2>/dev/null \
           | awk 'NF >= 4 { printf "%dx%d", $3, $4 }' || true)}
    line=$("$here/.build/winlist" Infinitus ${want:+"$want"}) || {
        # With a move requested the frame is about to be set anyway, so any
        # workspace-sized window will do (the preset is not honoured when its
        # screen rect names no attached screen; the window then opens at the
        # controller's fallback size).
        [ -n "${T3REF_WINDOW_ORIGIN:-}" ] && line=$("$here/.build/winlist" Infinitus) || {
            echo "no Infinitus window${want:+ of $want pt} on screen — is the workspace open at that frame?" >&2
            exit 3
        }
    }
    read -r id _w _h <<<"$line"
    # T3REF_WINDOW_ORIGIN="x y" (CG points, main display's top-left origin)
    # drags the window there first — the way to land it on the 2× laptop
    # panel when that panel is not the main display: T3WindowController clamps
    # the autosaved frame onto NSScreen.main at show time, so the frame preset
    # alone cannot. winmove goes through the app's own accessibility tree.
    if [ -n "${T3REF_WINDOW_ORIGIN:-}" ]; then
        if [ ! -x "$here/.build/winmove" ] || [ "$here/winmove.swift" -nt "$here/.build/winmove" ]; then
            swiftc -O "$here/winmove.swift" -o "$here/.build/winmove"
        fi
        # The preset's size travels with the move, so the window ends at the
        # reference frame wherever it opened.
        # shellcheck disable=SC2086
        "$here/.build/winmove" "$id" $T3REF_WINDOW_ORIGIN ${want:+$(echo "$want" | tr x ' ')}
        sleep 1
    fi
    # The same settle as capture-mac.sh: a cold first open still has the
    # thread's timeline to load after `show workspace` has returned.
    sleep 3
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
