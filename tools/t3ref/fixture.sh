#!/bin/bash
# fixture.sh [socket] | fixture.sh --stop — a fake ~/.claude with the parity
# fixture (spec §3.6), and the debug app on it.
#
# One session named "Hi", status waiting, whose transcript holds the "Hi"
# pair, an AskUserQuestion with two questions (→ `user-input.requested`) and
# an open `Write` (→ `approval.requested`, SessionTimelineBuilder.finish).
# The Mac window, the phone and the browser page all read it through the
# unchanged pipeline, so a reference capture never depends on real work.
#
# Everything the app could otherwise reach into is redirected under $state:
# the Claude config dir, the profiles list, the team dir and the engine
# (tools/demo-cswap — fabricated fleet, no credentials, no network), and the
# control socket is /tmp/t3fix.sock, never the real app's. The real
# Infinitus.app is untouched.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
state=/tmp/t3fix
sock=${1:-/tmp/t3fix.sock}
domain=Infinitus   # the unbundled debug binary's defaults domain, never run.infinitus

stop() {
    # The app supervises the demo engine, so its children go too — by PID,
    # walking down from the recorded app pid. Never by pattern: a
    # `pkill -f demo-cswap` would also kill a concurrent tools/e2e.sh run's
    # own engine child.
    if [ -f "$state/app.pid" ]; then
        app=$(cat "$state/app.pid")
        for child in $(pgrep -P "$app" 2>/dev/null || true); do
            for grandchild in $(pgrep -P "$child" 2>/dev/null || true); do
                kill "$grandchild" 2>/dev/null || true
            done
            kill "$child" 2>/dev/null || true
        done
        kill "$app" 2>/dev/null || true
    fi
    [ -f "$state/pid" ] && kill "$(cat "$state/pid")" 2>/dev/null || true
    for k in mirror_lan_enabled popout_shown mock_mode \
             migrated_from_huuloc_id migrated_from_limitless_id migrated_from_g2 mirror_pair_token; do
        defaults delete "$domain" "$k" >/dev/null 2>&1 || true
    done
    rm -rf "$state"
}

if [ "${1:-}" = "--stop" ]; then stop; echo "fixture stopped"; exit 0; fi
stop   # idempotent: never build over a debug binary this script left running

mkdir -p "$state/claude/sessions" "$state/proj/limitless"
export CLAUDE_CONFIG_DIR=$state/claude
# Detached from this script's stdout/stderr: a background child holding the
# caller's pipe open keeps `fixture.sh` from ever appearing to finish.
sleep 86400 >/dev/null 2>&1 & pid=$!; echo $pid > "$state/pid"
cwd=$state/proj/limitless
( cd "$cwd" && git init -q && git commit -q --allow-empty -m init )
cat > "$CLAUDE_CONFIG_DIR/sessions/$pid.json" <<EOF
{"pid":$pid,"sessionId":"t3fix-hi","cwd":"$cwd","kind":"interactive","status":"waiting","name":"Hi","entrypoint":"cli"}
EOF
slug=$(printf '%s' "$cwd" | sed 's/[^A-Za-z0-9]/-/g'); mkdir -p "$CLAUDE_CONFIG_DIR/projects/$slug"
t0=2026-09-07T08:42:00.000Z; t1=2026-09-07T08:42:03.000Z; t2=2026-09-07T08:42:10.000Z
cat > "$CLAUDE_CONFIG_DIR/projects/$slug/t3fix-hi.jsonl" <<EOF
{"type":"user","uuid":"u1","timestamp":"$t0","sessionId":"t3fix-hi","message":{"role":"user","content":"Hi"}}
{"type":"assistant","uuid":"a1","parentUuid":"u1","timestamp":"$t1","sessionId":"t3fix-hi","message":{"role":"assistant","content":[{"type":"text","text":"Hi. Ready when you are — what's the task?"}]}}
{"type":"user","uuid":"u2","timestamp":"$t2","sessionId":"t3fix-hi","message":{"role":"user","content":"Write the plan and ask me which colour to use"}}
{"type":"assistant","uuid":"a2","parentUuid":"u2","timestamp":"$t2","sessionId":"t3fix-hi","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_q","name":"AskUserQuestion","input":{"questions":[{"question":"Which colour?","header":"Colour","options":[{"label":"Blue","description":"T3's user bubble"},{"label":"Coral","description":"the Claude glyph"}],"multiSelect":false},{"question":"Which platform first?","header":"Platform","options":[{"label":"Mac","description":""},{"label":"Phone","description":""}],"multiSelect":true}]}}]}}
{"type":"assistant","uuid":"a3","parentUuid":"a2","timestamp":"$t2","sessionId":"t3fix-hi","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_w","name":"Write","input":{"file_path":"$cwd/PLAN.md","content":"# Plan\n"}}]}}
EOF
echo "fixture pid=$pid session=t3fix-hi cwd=$cwd"

( cd "$root" && swift build --product Infinitus -q )
# A dev Mac holds the CLIProxyAPI key under the bundle id's ACL: sign the
# debug binary AS that identifier so the launch never blocks on a keychain
# prompt (tools/e2e.sh:36-40).
identity=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/{print $2; exit}')
[ -z "$identity" ] || codesign --force --sign "$identity" --identifier run.infinitus "$root/.build/debug/Infinitus" 2>/dev/null || true

# The mirror is what the phone and the browser page read the fixture over.
defaults write "$domain" mirror_lan_enabled -bool true
defaults write "$domain" popout_shown -bool true
defaults write "$domain" mock_mode -bool false   # the fixture IS the session data; mock mode would hide it

# Identity isolation (final review of A): a fresh debug domain would copy
# the real app's prefs — the LAN pairing token included — via
# AppModel.migrateLegacyDefaults. Mark every hop done, then give the
# fixture a throwaway token so it never answers as the real Mac.
for marker in migrated_from_huuloc_id migrated_from_limitless_id migrated_from_g2; do
    defaults write "$domain" "$marker" -bool true
done
defaults write "$domain" mirror_pair_token -string "t3fix-$(uuidgen | tr -d - | cut -c1-16)"
defaults delete "$domain" team_discoverable >/dev/null 2>&1 || true

INFINITUS_CONTROL_SOCKET=$sock \
CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR \
INFINITUS_CSWAP=$root/tools/demo-cswap \
INFINITUS_DEMO_STATE=$state/demo-state.json \
INFINITUS_PROFILES=$state/profiles.json \
INFINITUS_TEAM_DIR=$state/team \
INFINITUS_WORKSPACE_NO_START=1 \
    "$root/.build/debug/Infinitus" -mock_mode NO >/tmp/t3fix.log 2>&1 &
echo $! > "$state/app.pid"
echo "app on $sock (log /tmp/t3fix.log)"
