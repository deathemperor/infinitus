#!/bin/bash
# fixture.sh [socket] | fixture.sh --stop — a fake ~/.claude with the parity
# fixture (spec §3.6), and the debug app on it.
#
# One session named "Hi", status waiting, whose transcript holds the "Hi"
# pair, an AskUserQuestion with two questions (→ `user-input.requested`) and
# an open `Write` (→ `approval.requested`, SessionTimelineBuilder.finish).
# The phone and the browser page both read it through the unchanged
# pipeline, so a reference capture never depends on real work.
#
# Everything the app could otherwise reach into is redirected under $state:
# the Claude config dir, the profiles list, the team dir and the engine
# (tools/demo-swapd — fabricated fleet, no credentials, no network), and the
# control socket is /tmp/t3fix.sock, never the real app's. The real
# Infinitus.app is untouched.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
# T3FIX_NAME=<short> gives a second fixture its own state dir, socket and log
# (/tmp/<short>, /tmp/<short>.sock, /tmp/<short>.log) so two rounds can run
# side by side; the default is the one the README's recipes name. Unix socket
# paths cap at ~104 bytes, so the name stays short. The defaults domain below
# is still shared: two fixtures see one set of window frames.
name=${T3FIX_NAME:-t3fix}
state=/tmp/$name
sock=${1:-/tmp/$name.sock}
domain=Infinitus   # the unbundled debug binary's defaults domain, never run.infinitus

stop() {
    # The app supervises the demo engine, so its children go too — by PID,
    # walking down from the recorded app pid. Never by pattern: a
    # `pkill -f demo-swapd` would also kill a concurrent tools/e2e.sh run's
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
    for k in mirror_lan_enabled mock_mode workspace.sidebarWidth \
             workspace.filesExplorerOpen workspace.terminalDrawer \
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
# T3FIX_MAC_REF=1: the thread as the Mac reference (`refs/mac-*.png`) has it —
# one "Hi" and the reply T3 Code's own session gave on 2026-09-09, nothing
# parked. The default transcript below is the spec §3.6 fixture the phone's
# references were shot against; the two differ because the desktop's thread
# was recreated by hand after the original was deleted (refs/PROVENANCE.md).
if [ "${T3FIX_MAC_REF:-}" = 1 ]; then
sed -i '' 's/"status":"waiting"/"status":"idle"/' "$CLAUDE_CONFIG_DIR/sessions/$pid.json"
# The reference window's sidebar is T3's 256 CSS px default seen at that
# app's ~1.893 zoom, i.e. 241 pt of ours — `T3Root.preferredSidebarWidth`
# takes it from here so the two columns land on the same x. `stop()` deletes it.
defaults write "$domain" workspace.sidebarWidth -float 256
cat > "$CLAUDE_CONFIG_DIR/projects/$slug/t3fix-hi.jsonl" <<'EOF'
{"type":"user","uuid":"u1","timestamp":"2026-09-09T10:38:20.000Z","sessionId":"t3fix-hi","message":{"role":"user","content":"Hi"}}
{"type":"assistant","uuid":"a1","parentUuid":"u1","timestamp":"2026-09-09T10:38:41.000Z","sessionId":"t3fix-hi","message":{"role":"assistant","content":[{"type":"text","text":"Heads up first: claude-mem can't save memories right now. The memory observer has failed 33 times in a row over 14 minutes. Latest error:\n\n```\nClaude Code process terminated by signal SIGKILL\n```\n\nRestart it here: http://localhost:37701/restart (or `npx claude-mem restart`). Nothing from this or any other session is remembered until then.\n\nHi. On `main` at 024379e2 in the Infinitus repo. What do you want to work on?"}]}}
EOF
else
cat > "$CLAUDE_CONFIG_DIR/projects/$slug/t3fix-hi.jsonl" <<EOF
{"type":"user","uuid":"u1","timestamp":"$t0","sessionId":"t3fix-hi","message":{"role":"user","content":"Hi"}}
{"type":"assistant","uuid":"a1","parentUuid":"u1","timestamp":"$t1","sessionId":"t3fix-hi","message":{"role":"assistant","content":[{"type":"text","text":"Hi. Ready when you are — what's the task?"}]}}
{"type":"user","uuid":"u2","timestamp":"$t2","sessionId":"t3fix-hi","message":{"role":"user","content":"Write the plan and ask me which colour to use"}}
{"type":"assistant","uuid":"a2","parentUuid":"u2","timestamp":"$t2","sessionId":"t3fix-hi","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_q","name":"AskUserQuestion","input":{"questions":[{"question":"Which colour?","header":"Colour","options":[{"label":"Blue","description":"T3's user bubble"},{"label":"Coral","description":"the Claude glyph"}],"multiSelect":false},{"question":"Which platform first?","header":"Platform","options":[{"label":"Mac","description":""},{"label":"Phone","description":""}],"multiSelect":true}]}}]}}
{"type":"assistant","uuid":"a3","parentUuid":"a2","timestamp":"$t2","sessionId":"t3fix-hi","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_w","name":"Write","input":{"file_path":"$cwd/PLAN.md","content":"# Plan\n"}}]}}
EOF
fi
# T3FIX_PANELS=1 (B-41): what the right panel's tabs need — a few files and a
# working-tree patch off one checkpoint (Files, Diff), two settled sub-agents
# (Agents). The Pull request tab stays on its unavailable card: the fixture
# repo has no remote for `gh` to answer about, which is the state the Mac
# reference shows too.
if [ "${T3FIX_PANELS:-}" = 1 ]; then
    (
        cd "$cwd"
        mkdir -p src docs
        printf 'export const greet = (name) => `Hi ${name}`;\n' > src/greet.js
        printf '# Notes\n\nThe parity fixture.\n' > docs/notes.md
        printf 'name = "t3fix"\n' > config.toml
        git add -A && git commit -q -m "seed the panel fixture"
        # `Checkpoints.list` reads `refs/infinitus/checkpoints/<sessionId>/<n>`,
        # whose body line names the live root; the working tree then moves past
        # it, which is exactly the "Working tree" scope's patch.
        git commit -q --allow-empty -m "checkpoint 1" -m "root: $cwd"
        git update-ref "refs/infinitus/checkpoints/t3fix-hi/1" HEAD
        printf 'export const greet = (name) => `Hello, ${name}!`;\n' > src/greet.js
        printf 'todo\n' > src/todo.txt
    )
    # `<transcript>/subagents/agent-<id>.jsonl` + `.meta.json`
    # (`T3Agents.panel(subagentsDir:)`): a log whose last line is text and
    # whose file is old is a SETTLED agent, so neither row spins.
    sub="$CLAUDE_CONFIG_DIR/projects/$slug/t3fix-hi/subagents"
    mkdir -p "$sub"
    for a in "d1|coder|Port the Agents tab|Done: the tab is ported." \
             "d2|general-purpose|Audit the diff panel|Done: three findings, all filed."; do
        IFS='|' read -r id kind desc last <<<"$a"
        cat > "$sub/agent-$id.jsonl" <<EOF
{"type":"user","timestamp":"2026-09-09T10:38:22.000Z","message":{"role":"user","content":"go"}}
{"type":"assistant","timestamp":"2026-09-09T10:38:30.000Z","message":{"role":"assistant","model":"claude-sonnet-4-5-20250929","usage":{"input_tokens":1200,"output_tokens":340},"content":[{"type":"tool_use","name":"Read","input":{}}]}}
{"type":"assistant","timestamp":"2026-09-09T10:39:05.000Z","message":{"role":"assistant","model":"claude-sonnet-4-5-20250929","usage":{"input_tokens":2400,"output_tokens":180},"content":[{"type":"text","text":"$last"}]}}
EOF
        printf '{"agentType":"%s","description":"%s","toolUseId":"toolu_%s","spawnDepth":1}' "$kind" "$desc" "$id" \
            > "$sub/agent-$id.meta.json"
    done
fi

echo "fixture pid=$pid session=t3fix-hi cwd=$cwd"

( cd "$root" && swift build --product Infinitus -q )
# A dev Mac holds the CLIProxyAPI key under the bundle id's ACL: sign the
# debug binary AS that identifier so the launch never blocks on a keychain
# prompt (tools/e2e.sh:36-40).
identity=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/{print $2; exit}')
[ -z "$identity" ] || codesign --force --sign "$identity" --identifier run.infinitus "$root/.build/debug/Infinitus" 2>/dev/null || true

# The mirror is what the phone and the browser page read the fixture over.
defaults write "$domain" mirror_lan_enabled -bool true
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
INFINITUS_APP_SUPPORT=$state/app-support \
INFINITUS_MIRROR_SNAPSHOT=$state/mirror-snapshot.json \
CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR \
INFINITUS_SWAPD_CLI=$root/tools/demo-swapd \
INFINITUS_DEMO_STATE=$state/demo-state.json \
INFINITUS_PROFILES=$state/profiles.json \
INFINITUS_TEAM_DIR=$state/team \
    "$root/.build/debug/Infinitus" -mock_mode NO >"/tmp/$name.log" 2>&1 &
echo $! > "$state/app.pid"
echo "app on $sock (log /tmp/$name.log)"
