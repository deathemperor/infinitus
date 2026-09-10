#!/bin/sh
# Forwards the hook payload on stdin to Infinitus (#79): the Mac app, or
# the Linux tray's control socket (#486 slice 3).
# Never blocks a session: exit 0 whatever happens, nothing on stdout.
ctl="${INFINITUS_CTL:-$(command -v infinitusctl 2>/dev/null)}"
[ -x "$ctl" ] || ctl=/Applications/Infinitus.app/Contents/MacOS/infinitusctl
# Linux: where packaging/linux/README.md installs the CLI.
[ -x "$ctl" ] || ctl="$HOME/.local/bin/infinitusctl"
[ -x "$ctl" ] || exit 0
payload=$(cat)
# One retry: the app answers one control command at a time, and two
# sessions' hooks can land together.
printf '%s' "$payload" | "$ctl" event >/dev/null 2>&1 \
  || { sleep 1; printf '%s' "$payload" | "$ctl" event >/dev/null 2>&1; }
exit 0
