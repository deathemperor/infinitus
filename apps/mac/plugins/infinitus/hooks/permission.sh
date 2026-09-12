#!/bin/sh
# PermissionRequest: routes the prompt to the Infinitus desktop and web
# (#79) when this session has remote asks on (`infinitusctl session-remote
# <pid> on`). Registers the ask, parks up to 60 s for an Allow/Deny, and
# prints the decision; anything else (no app, busy, not remote, no
# decision) → silence, so Claude Code shows its own prompt. Never a
# silent allow.
ctl="${INFINITUS_CTL:-$(command -v infinitusctl 2>/dev/null)}"
[ -x "$ctl" ] || ctl=/Applications/Infinitus.app/Contents/MacOS/infinitusctl
[ -x "$ctl" ] || ctl="$HOME/.local/bin/infinitusctl"
[ -x "$ctl" ] || exit 0
payload=$(cat)
# One retry: the app answers one write at a time, and two sessions' hooks
# can land together.
reply=$(printf '%s' "$payload" | "$ctl" permission 2>/dev/null) \
  || { sleep 1; reply=$(printf '%s' "$payload" | "$ctl" permission 2>/dev/null) || exit 0; }
id=$(printf '%s' "$reply" | sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p')
[ -n "$id" ] || exit 0
decision=$("$ctl" permission-wait "$id" 2>/dev/null) || exit 0
case "$decision" in
  *'"allow"'*) printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}' ;;
  *'"deny"'*) printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from Infinitus"}}}' ;;
esac
exit 0
