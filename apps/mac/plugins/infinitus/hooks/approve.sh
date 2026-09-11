#!/bin/sh
# PreToolUse: asks the Infinitus Mac app whether the phone allowed this
# tool for the rest of the session (#79). Allowed → Claude Code skips the
# prompt; anything else (no app, busy, no rule) → silence, the normal
# prompt appears. Never blocks, never denies.
ctl="${INFINITUS_CTL:-$(command -v infinitusctl 2>/dev/null)}"
[ -x "$ctl" ] || ctl=/Applications/Infinitus.app/Contents/MacOS/infinitusctl
[ -x "$ctl" ] || exit 0
reply=$("$ctl" approve 2>/dev/null) || exit 0
case "$reply" in
  *'"allow"'*) printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"Allowed from the phone for this session (Infinitus)"}}' ;;
esac
exit 0
