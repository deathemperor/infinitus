#!/bin/sh
# End-to-end + performance gate (#18). Launches the DEBUG app against the
# demo engine (tools/demo-cswap: fabricated fleet, no credentials, no
# network), drives it through infinitusctl on a private control socket,
# and fails on:
#   - any command that errors, a missing window, a wrong fleet shape
#   - a switch/rotate/hold/unhold/rename/reorder that doesn't round-trip
#     into `fleets`
#   - the wall not taking over from the pop-out (and giving it back), or
#     the all-dead scenario not producing the no-candidate fleet
#   - idle CPU above IDLE_BUDGET_PCT with the pop-out open on the RPG
#     theme (the worst case: every effect armed — the 2026-09-03
#     regression idled at 39%)
#   - RSS above RSS_BUDGET_MB, or the live heap growing faster than
#     GROWTH_BUDGET_KB_MIN while idle (the 2026-09-03 per-second
#     numericText countdown grew the glyph cache ~2 MB/min for as long
#     as it ticked)
# Runs on a dev Mac (`tools/e2e.sh`) and in CI (ci.yml e2e job). The
# real app, if running, is untouched: separate socket, separate defaults
# suite (the executable name "Infinitus" from .build → domain "Infinitus",
# never run.infinitus), INFINITUS_CSWAP pinned to the demo script.
set -eu
cd "$(dirname "$0")/.."

IDLE_BUDGET_PCT="${IDLE_BUDGET_PCT:-8}"   # measured 0.3-0.5% on every theme/burn combo (2026-09-03, all effects on CA); loaded CI runners add noise, not tens of points
RSS_BUDGET_MB="${RSS_BUDGET_MB:-220}"
GROWTH_BUDGET_KB_MIN="${GROWTH_BUDGET_KB_MIN:-768}"   # idle heap growth; ~80 KB/min after the fix, 2.1 MB/min before
WINDOW_S="${WINDOW_S:-30}"   # long enough for the growth rate to mean something

BIN="$(swift build --show-bin-path)"
APP="$BIN/Infinitus"
CTL="$BIN/infinitusctl"
[ -x "$APP" ] && [ -x "$CTL" ] || { echo "build first: swift build"; exit 2; }
# A dev Mac holds the CLIProxyAPI key under the bundle id's ACL: sign the
# debug binary AS that identifier so the launch never blocks on a keychain
# prompt (ci: no identity, no key, nothing to prompt for).
ID="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/{print $2; exit}')"
[ -z "$ID" ] || codesign --force --sign "$ID" --identifier run.infinitus "$APP" 2>/dev/null || true

# Its own directory: the server chmods the socket's parent to 0700.
SOCKDIR="/tmp/infinitus-e2e-$$"; mkdir -p "$SOCKDIR"
export INFINITUS_CONTROL_SOCKET="$SOCKDIR/control.sock"
export INFINITUS_CSWAP="$PWD/tools/demo-cswap"
export INFINITUS_DEMO_STATE="$SOCKDIR/demo-state.json"   # not $TMPDIR: the bundled app in mock mode shares that one
LOG="$(mktemp -t infinitus-e2e)"
DOMAIN=Infinitus   # the unbundled debug binary's defaults domain

cleanup() {
    pkill -f "$APP" 2>/dev/null || true
    # The supervised demo engine outlives its app (four orphans found
    # sleeping from earlier runs, 2026-09-03).
    pkill -f "$INFINITUS_CSWAP auto" 2>/dev/null || true
    pkill -f "$SOCKDIR/aws" 2>/dev/null || true
    [ -z "${SESSION_PID:-}" ] || kill "$SESSION_PID" 2>/dev/null || true
    rm -rf "$SOCKDIR"
    "$INFINITUS_CSWAP" reset >/dev/null 2>&1 || true
    # Leave the dev domain as we found it for the keys we touched.
    for k in popout_shown popover_pinned gamification_style burn_style mock_mode engine_9router_enabled; do
        defaults delete "$DOMAIN" "$k" >/dev/null 2>&1 || true
    done
}
trap cleanup EXIT

fail() { echo "E2E FAIL: $*"; echo "--- app log"; tail -20 "$LOG"; exit 1; }
json() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
# expect <python-bool-over-d> — the reply on stdin must satisfy it.
expect() { python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if ($1) else 1)"; }
acct() { echo "[a for a in d['fleet']['accounts'] if a['number']==$1][0]"; }
popout_visible() { "$CTL" windows | expect "any(w['visible'] and w['content']=='GlassContainerView' for w in d)"; }
wall_visible() { "$CTL" windows | expect "any(w['visible'] and 'WallRoot' in w['content'] for w in d)"; }

"$INFINITUS_CSWAP" reset >/dev/null   # pristine demo fleet: account 1 active, nothing held or aliased

# Worst-case prefs: pop-out restored on launch, RPG theme, ember burn.
defaults write "$DOMAIN" popout_shown -bool true
defaults write "$DOMAIN" popover_pinned -bool false
defaults write "$DOMAIN" gamification_style rpg
defaults write "$DOMAIN" burn_style ember
defaults write "$DOMAIN" mock_mode -bool true
# Explicitly off: the dev Mac's real ~/.claude/settings.json routes Claude Code
# at the LAN 9Router, and any dev launch that sees it writes the key true for
# good (AppModel only writes it while absent). The demo run shares this domain,
# so it inherited the engine and polled the real router — 401s and a dead run.
defaults write "$DOMAIN" engine_9router_enabled -bool false

# --- AWS sign-in fixtures (must exist before launch: env is read at start) --
# A stub `aws` in place of the real CLI: `login --remote --profile P`
# prints the URL and asks for the code the way the CLI does; the magic
# code signs in, profile e2e-rebind hits the "already configured to use
# session" question (answered n → failed, never rebound).
cat >"$SOCKDIR/aws" <<'STUB'
#!/bin/sh
profile=""
while [ $# -gt 0 ]; do [ "$1" = "--profile" ] && profile="$2"; shift; done
echo "Please visit the following URL:"
echo "https://e2e.invalid/authorize?profile=$profile"
printf 'Enter the authorization code: '
read code
if [ "$profile" = "e2e-rebind" ]; then
    printf 'Profile %s is already configured to use session arn:aws:iam::1:user/a. Do you want to overwrite it to use arn:aws:iam::2:user/a instead? (y/n): ' "$profile"
    read answer
    echo "aws: [ERROR]: Login cancelled."; exit 255
fi
[ "$code" = "E2E-CODE-OK" ] || { echo "aws: [ERROR]: Invalid authorization code."; exit 255; }
echo "Updated profile $profile to use arn:aws:iam::1:user/e2e credentials."
STUB
chmod +x "$SOCKDIR/aws"
export INFINITUS_AWS_CLI="$SOCKDIR/aws"
export INFINITUS_AWS_LEDGER="$SOCKDIR/aws-logins.json"
# The fake Claude session: a process with no tty (setsid, so the nudge
# can't fall back to typing into THIS terminal) listening on the record's
# messaging socket, writing every frame it receives to an inbox file.
export CLAUDE_CONFIG_DIR="$SOCKDIR/claude"
PEER_SOCK="$SOCKDIR/peer.sock"; INBOX="$SOCKDIR/inbox.ndjson"
python3 - "$PEER_SOCK" "$INBOX" <<'PEER' &
import os, socket, sys
os.setsid()
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.bind(sys.argv[1]); s.listen(4)
while True:
    c, _ = s.accept(); c.settimeout(3); data = b""
    try:
        while True:
            chunk = c.recv(65536)
            if not chunk: break
            data += chunk
    except socket.timeout: pass
    with open(sys.argv[2], "ab") as f: f.write(data)
    c.close()
PEER
SESSION_PID=$!
SESSION_CWD="$SOCKDIR/proj"
export DEMO_SESSION_PID="$SESSION_PID" DEMO_SESSION_CWD="$SESSION_CWD"
mkdir -p "$CLAUDE_CONFIG_DIR/sessions"
cat >"$CLAUDE_CONFIG_DIR/sessions/$SESSION_PID.json" <<EOF
{"pid":$SESSION_PID,"sessionId":"e2e-aws","cwd":"$SESSION_CWD","kind":"interactive","status":"idle",
 "peerProtocol":1,"messagingSocketPath":"$PEER_SOCK","name":"e2e-aws"}
EOF
# Its transcript: an aws call that died on the expired session, stamped a
# minute back so it is unmistakably older than any login started below.
SLUG="$(printf '%s' "$SESSION_CWD" | sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$CLAUDE_CONFIG_DIR/projects/$SLUG"
TS="$(python3 -c "import datetime;print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=60)).strftime('%Y-%m-%dT%H:%M:%S.000Z'))")"
cat >"$CLAUDE_CONFIG_DIR/projects/$SLUG/e2e-aws.jsonl" <<EOF
{"type":"assistant","timestamp":"$TS","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_e2e","name":"Bash","input":{"command":"aws sts get-caller-identity --profile e2e-login"}}]}}
{"type":"user","timestamp":"$TS","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_e2e","content":"\naws: [ERROR]: Your session has expired. Please reauthenticate using 'aws login'.\n"}]}}
EOF

"$APP" >"$LOG" 2>&1 &
APP_PID=$!
i=0
until "$CTL" status >/dev/null 2>&1; do
    i=$((i + 1))
    if [ "$i" -ge 60 ]; then
        # What CI can't show otherwise: the client's error, whether the
        # socket file exists, and where the app's threads are stuck.
        echo "--- last client attempt"; "$CTL" status 2>&1 | head -3 || true
        echo "--- socket"; ls -l "$SOCKDIR" 2>&1 || true
        echo "--- app log (all)"; cat "$LOG"
        echo "--- threads"; sample "$APP_PID" 2 -file "$LOG.sample" >/dev/null 2>&1 \
            && awk '/^Call graph/,/^Total number/' "$LOG.sample" | grep -E "Thread_|^\s*\+? *[0-9]+ [^ ]" | cut -c1-150 | head -150 || true
        fail "control socket never came up"
    fi
    sleep 1
done
echo "app up after ${i}s"

# --- functional ---------------------------------------------------------
"$CTL" manifest | json "len(d['commands'])" | grep -qE '^[1-9][0-9]*$' || fail "manifest empty"
"$CTL" status | json "d['engines']['cswap']['registered']" | grep -q True || fail "cswap not registered"
sleep 4   # first demo snapshot
N="$("$CTL" fleets | json "sum(len(f['accounts']) for f in d)")"
[ "$N" -ge 5 ] || fail "expected the demo fleet (>=5 accounts), got $N"
"$CTL" fleets | json "d[0]['key']" | grep -q '^cswap/claude$' || fail "primary fleet key"
"$CTL" remove cswap/claude 1 >/dev/null 2>&1 && fail "remove without --yes must be refused"
"$CTL" switch nope/x 1 >/dev/null 2>&1 && fail "unknown fleet must be refused"
popout_visible || fail "pop-out window not visible (popout_shown restore)"
echo "functional: ok ($N demo accounts, pop-out visible)"

# --- state round-trips through the demo engine ---------------------------
# Each write replies with the refreshed fleet; the change must be in it.
"$CTL" switch cswap/claude 2 | expect "d['fleet']['activeNumber']==2 and $(acct 2)['active']" || fail "switch 2 didn't take"
"$CTL" hold cswap/claude 3 | expect "$(acct 3).get('disabled')==True" || fail "hold 3 didn't take"
"$CTL" unhold cswap/claude 3 | expect "not $(acct 3).get('disabled')" || fail "unhold 3 didn't take"
"$CTL" rename cswap/claude 3 "E2E Alias" | expect "$(acct 3).get('alias')=='E2E Alias'" || fail "rename didn't take"
"$CTL" rename cswap/claude 3 "" | expect "$(acct 3).get('alias')!='E2E Alias'" || fail "rename clear didn't take"   # demo accounts carry default aliases
"$CTL" prefer cswap/claude 2 on | expect "$(acct 2).get('preferred')==True" || fail "prefer 2 didn't take"
"$CTL" prefer cswap/claude 2 off | expect "$(acct 2).get('preferred')==False" || fail "unprefer 2 didn't take"
NEXT="$("$CTL" fleets | json "d[0]['nextCandidate']")"
"$CTL" rotate cswap/claude | expect "d['fleet']['activeNumber']==$NEXT" || fail "rotate didn't land on the next candidate ($NEXT)"
ORDER="$("$CTL" fleets | json "' '.join(str(a['number']) for a in d[0]['accounts'])")"
REV="$(python3 -c "print(' '.join(reversed('$ORDER'.split())))")"
"$CTL" reorder cswap/claude $REV | expect "[a['number'] for a in d['fleet']['accounts']]==[int(x) for x in '$REV'.split()]" || fail "reorder didn't take"
"$CTL" reorder cswap/claude 1 >/dev/null 2>&1 && fail "partial reorder must be refused"
"$CTL" reorder cswap/claude $ORDER | expect "[a['number'] for a in d['fleet']['accounts']]==[int(x) for x in '$ORDER'.split()]" || fail "reorder restore didn't take"
"$CTL" switch cswap/claude 1 | expect "d['fleet']['activeNumber']==1" || fail "switch back to 1"
# Every account gets a distinct themed name in one command.
"$CTL" randomize-names cswap/claude | expect "len(set(a.get('alias') for a in d['fleet']['accounts']))==len(d['fleet']['accounts']) and len(d['names'])==len(d['fleet']['accounts'])" || fail "randomize-names didn't give every account its own name"
echo "round-trips: ok (switch, rotate, hold, unhold, rename, prefer, reorder, randomize-names)"
"$CTL" plan | expect "'plan' in d and (d['plan'] is None or 'steps' in d['plan'])" || fail "plan verb"
"$CTL" ignite cswap/claude 2 | expect "'fleet' in d" || fail "ignite verb"
"$CTL" aws-logins | expect "'logins' in d and isinstance(d['logins'], list)" || fail "aws-logins verb"
"$CTL" forecast | expect "'forecast' in d and (d['forecast'] is None or ('basis' in d['forecast'] and 'accounts' in d['forecast']))" || fail "forecast verb"
"$CTL" stats --period week | expect "d['period']=='week' and 'total' in d and 'commits' in d['total'] and 'humanMessages' in d['total']" || fail "stats verb"

# --- windows: the wall takes over from the pop-out and gives it back ----
"$CTL" show wall | expect "d['shown']" || fail "show wall"
sleep 2
wall_visible || fail "wall window not visible after show wall"
popout_visible && fail "pop-out still visible under the wall"
"$CTL" show wall >/dev/null || fail "show wall (toggle off)"
sleep 2
wall_visible && fail "wall still visible after toggling off"
popout_visible || fail "pop-out not restored after the wall closed"
echo "windows: ok (wall over pop-out, restored)"

# --- scenarios: all-dead (every window maxed, no candidate) --------------
"$INFINITUS_CSWAP" simulate alldead >/dev/null
"$CTL" refresh | expect "d[0].get('nextCandidate') is None and d[0].get('nextRecovery') is not None" \
    || fail "all-dead scenario not reflected in fleets"
sleep 2
popout_visible || fail "pop-out lost during all-dead"
# The floating revival countdown (#1's macOS equivalent) rides the same
# state: up while all-dead, gone — content detached — once the fleet is back.
revival_visible() { "$CTL" windows | expect "any(w['visible'] and 'RevivalRoot' in w['content'] for w in d)"; }
i=0
until revival_visible; do
    i=$((i + 1)); [ "$i" -lt 10 ] || fail "revival panel not shown during all-dead"
    sleep 1
done
"$INFINITUS_CSWAP" simulate off >/dev/null
"$CTL" refresh | expect "d[0].get('nextCandidate') is not None" || fail "fleet didn't recover after simulate off"
sleep 1
revival_visible && fail "revival panel outlived the all-dead"
"$CTL" windows | expect "not any('RevivalRoot' in w['content'] for w in d)" || fail "revival panel content not detached"
echo "scenarios: ok (all-dead and back, revival panel up and gone)"

# --- control socket self-heal -------------------------------------------
# A dev instance launched without INFINITUS_CONTROL_SOCKET unlinks and
# re-binds the path; killed, it leaves an inode nobody answers and the
# bundle was unreachable for 25 minutes (2026-09-03). The app must notice
# on its next snapshot and bind again.
python3 - "$SOCKDIR/control.sock" <<'PYS'
import os, socket, sys
p = sys.argv[1]; os.unlink(p)
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.bind(p); s.listen(1); s.close()  # dead inode stays
PYS
"$CTL" status >/dev/null 2>&1 && fail "a dead socket path should refuse"
i=0
until "$CTL" status >/dev/null 2>&1; do
    i=$((i + 1)); [ "$i" -le 75 ] || fail "control socket not re-bound within a refresh interval"
    sleep 1
done
echo "control: ok (dead socket path re-bound after ${i}s)"

# --- AWS sign-in from the phone -------------------------------------------
# The transcript scan surfaces the expired profile against the session.
aws_login_item() { "$CTL" aws-logins | expect "any(l['profile']=='e2e-login' and l['pid']==$SESSION_PID for l in d['logins'])"; }
aws_phase() { "$CTL" aws-logins | json "next((l.get('state') or {}).get('phase') for l in d['logins'] if l['profile']=='$1')"; }
i=0
until aws_login_item; do
    i=$((i + 1)); [ "$i" -lt 60 ] || fail "expired AWS session never surfaced in aws-logins"
    sleep 1
done
echo "aws: need surfaced after ${i}s"
# The phone's flag-less poll reports and never starts (it re-opened the
# sign-in on every poll, 2026-09-03).
"$CTL" aws-login e2e-login --status >/dev/null 2>&1 && fail "--status started a login"
"$CTL" aws-logins | expect "all(l.get('state') is None for l in d['logins'])" || fail "--status left a login in flight"
# Code flow: URL for the phone's browser, then the pasted code.
"$CTL" aws-login e2e-login --remote --pid "$SESSION_PID" | expect "d['state']['flow']=='remote'" || fail "aws-login --remote"
i=0
until [ "$(aws_phase e2e-login)" = "waitingForCode" ]; do
    i=$((i + 1)); [ "$i" -lt 20 ] || fail "login never asked for the code (phase $(aws_phase e2e-login))"
    sleep 1
done
"$CTL" aws-logins | expect "next(l['state']['url'] for l in d['logins'] if l['profile']=='e2e-login').startswith('https://e2e.invalid/')" || fail "no URL for the phone"
"$CTL" aws-login e2e-login --status | expect "d['state']['phase']=='waitingForCode'" || fail "--status did not report the login in flight"
printf 'E2E-CODE-OK' | "$CTL" aws-login-code e2e-login >/dev/null || fail "aws-login-code"
# Signed in: the item drops (the failure predates the login) and the
# session gets its nudge over its own inbox socket.
i=0
while aws_login_item; do
    i=$((i + 1)); [ "$i" -lt 20 ] || fail "need did not clear after the login (phase $(aws_phase e2e-login))"
    sleep 1
done
i=0
until grep -q "AWS login for profile e2e-login completed from the phone" "$INBOX" 2>/dev/null; do
    i=$((i + 1)); [ "$i" -lt 20 ] || fail "session never got the continue nudge (inbox: $(cat "$INBOX" 2>/dev/null | head -c 300))"
    sleep 1
done
echo "aws: code flow signed in, need cleared, session nudged"
# Rebind refusal: the CLI asks to overwrite the profile's session; the
# app answers n and reports which account it was bound to.
"$CTL" aws-login e2e-rebind --remote >/dev/null || fail "aws-login e2e-rebind"
i=0
until [ "$(aws_phase e2e-rebind)" = "waitingForCode" ]; do
    i=$((i + 1)); [ "$i" -lt 20 ] || fail "rebind login never asked for the code"
    sleep 1
done
printf 'E2E-CODE-OK' | "$CTL" aws-login-code e2e-rebind >/dev/null || fail "aws-login-code e2e-rebind"
i=0
until [ "$(aws_phase e2e-rebind)" = "failed" ]; do
    i=$((i + 1)); [ "$i" -lt 20 ] || fail "rebind was not refused (phase $(aws_phase e2e-rebind))"
    sleep 1
done
"$CTL" aws-logins | expect "'bound to account 1 but you signed in to 2' in next(l['state']['message'] for l in d['logins'] if l['profile']=='e2e-rebind')" || fail "rebind message"
pgrep -f "$SOCKDIR/aws" >/dev/null && fail "stub aws CLI still running"
echo "aws: rebind refused"

# --- performance --------------------------------------------------------
# Sampled AFTER the churn above so a timer left behind by a closed wall
# or a scenario swap shows up as idle cost.
sleep 10  # animations settle, launch-time caches land
A="$("$CTL" perf | json "d['cpuSeconds']")"
HEAP_A="$("$CTL" perf | json "int(d['heapBytes']/1024)")"
sleep "$WINDOW_S"
B="$("$CTL" perf | json "d['cpuSeconds']")"
HEAP_B="$("$CTL" perf | json "int(d['heapBytes']/1024)")"
RSS="$("$CTL" perf | json "int(d['rssBytes']/1048576)")"
PCT="$(python3 -c "print(round(($B-$A)/$WINDOW_S*100,1))")"
GROWTH="$(python3 -c "print(int(($HEAP_B-$HEAP_A)*60/$WINDOW_S))")"
echo "idle CPU with pop-out open (rpg + ember): ${PCT}%  rss: ${RSS} MB  heap growth: ${GROWTH} KB/min  (budgets ${IDLE_BUDGET_PCT}% / ${RSS_BUDGET_MB} MB / ${GROWTH_BUDGET_KB_MIN} KB/min)"
python3 -c "import sys; sys.exit(0 if $PCT <= $IDLE_BUDGET_PCT else 1)" || fail "idle CPU ${PCT}% over budget ${IDLE_BUDGET_PCT}%"
[ "$RSS" -le "$RSS_BUDGET_MB" ] || fail "RSS ${RSS} MB over budget ${RSS_BUDGET_MB} MB"
[ "$GROWTH" -le "$GROWTH_BUDGET_KB_MIN" ] || fail "idle heap growth ${GROWTH} KB/min over budget ${GROWTH_BUDGET_KB_MIN} KB/min"
echo "E2E PASS"
