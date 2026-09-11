#!/bin/sh
# End-to-end + performance gate (#18). Launches the DEBUG app against the
# demo engine (tools/demo-cswap: fabricated fleet, no credentials, no
# network), drives it through infinitusctl on a private control socket,
# and fails on:
#   - any command that errors, a missing window, a wrong fleet shape
#   - a switch/rotate/hold/unhold/rename/reorder that doesn't round-trip
#     into `fleets`
#   - the all-dead scenario not producing the no-candidate fleet, or not
#     recovering
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
RSS_BUDGET_MB="${RSS_BUDGET_MB:-240}"
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
export INFINITUS_APP_SUPPORT="$SOCKDIR/app-support"   # every file the instance writes stays out of the real Infinitus/ (#506)
export INFINITUS_CSWAP="$PWD/tools/demo-cswap"
export INFINITUS_DEMO_STATE="$SOCKDIR/demo-state.json"   # not $TMPDIR: the bundled app in mock mode shares that one
# Spec §11 e2e: the app is a team leader on a bare repo in $SOCKDIR with
# its own team dir (file secrets, no keychain), and publishes a fixture
# projects dir instead of this Mac's real transcripts.
export INFINITUS_PROFILES="$SOCKDIR/profiles.json"   # #165: never the real list
export INFINITUS_TEAM_DIR="$SOCKDIR/team-app"
export INFINITUS_TEAM_PROJECTS="$SOCKDIR/fixture/projects"
LOG="$(mktemp -t infinitus-e2e)"
# This run's own defaults domain (#690): unbundled debug binaries used to
# share one, so a peer's leftover fork_server_port could fail another
# session's run. Deleted whole in cleanup.
DOMAIN="infinitus-e2e-$$"
export INFINITUS_DEFAULTS_SUITE="$DOMAIN"

cleanup() {
    pkill -f "$APP" 2>/dev/null || true
    # The supervised demo engine outlives its app (four orphans found
    # sleeping from earlier runs, 2026-09-03). Foundation's Process spawns
    # it with the path's /private prefix stripped (a /private/tmp
    # worktree's demo-cswap runs as /tmp/…/demo-cswap), so the pattern is
    # the stripped form — a substring of both (42 orphans from one day's
    # scratchpad runs, 2026-09-11).
    pkill -f "${INFINITUS_CSWAP#/private} auto" 2>/dev/null || true
    pkill -f "$SOCKDIR/aws" 2>/dev/null || true
    pkill -f "nc -l 127.0.0.1 4[0-9]{4}$" 2>/dev/null || true
    pkill -f "profile e2e-orphan" 2>/dev/null || true
    [ -z "${SESSION_PID:-}" ] || kill "$SESSION_PID" 2>/dev/null || true
    [ -z "${SEED_PID:-}" ] || kill "$SEED_PID" 2>/dev/null || true
    rm -rf "$SOCKDIR"
    "$INFINITUS_CSWAP" reset >/dev/null 2>&1 || true
    defaults delete "$DOMAIN" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# On a failure the log carries what #637 needs: the app's unix sockets
# (is the listener fd still there?), the socket dir's inodes (did the path
# change under it?) and one more `status` (is it refusing or just slow?).
fail() {
    echo "E2E FAIL: $*"
    [ -s "$LOG.reply" ] && { echo "--- last rejected reply"; cat "$LOG.reply"; echo; }
    echo "--- app log"; tail -20 "$LOG"
    if [ -n "${APP_PID:-}" ]; then
        echo "--- app unix sockets"; lsof -p "$APP_PID" -a -U 2>/dev/null | tail -n +2 | cut -c1-140 | head -12
        echo "--- socket dir"; /bin/ls -li "$SOCKDIR" 2>/dev/null | head -8
        # #637: the app itself gone (no crash report, no last line) is one of
        # the two readings of "connection refused"; its wait status names
        # the signal (141 SIGPIPE, 143 SIGTERM, 137 SIGKILL).
        # (`|| st=$?`: under set -e a bare non-zero `wait` ends the script before the echo.)
        if /bin/kill -0 "$APP_PID" 2>/dev/null; then echo "--- app alive: $(ps -o pid=,stat=,etime= -p "$APP_PID")"; else st=0; wait "$APP_PID" 2>/dev/null || st=$?; echo "--- app gone: wait status $st"; fi
        echo "--- status retry"; "$CTL" status 2>&1 | head -c 300; echo
    fi
    exit 1
}
json() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
# expect <python-bool-over-d> — the reply on stdin must satisfy it. A miss
# keeps the reply in $LOG.reply, which `fail` prints: the flake's evidence
# lands in the log without every retry loop's expected miss doing so.
expect() {
  python3 -c "
import json,sys
raw=sys.stdin.read()
try: d=json.loads(raw); bad=False
except Exception: bad=True     # a JSON null is a legitimate reply (team-status before a team)
if bad or not ($1):
    open('$LOG.reply','w').write(raw[:800]); sys.exit(1)
" && rm -f "$LOG.reply"
}
acct() { echo "[a for a in d['fleet']['accounts'] if a['number']==$1][0]"; }
popout_visible() { "$CTL" windows | expect "any(w['visible'] and w['content']=='GlassContainerView' for w in d)"; }

"$INFINITUS_CSWAP" reset >/dev/null   # pristine demo fleet: account 1 active, nothing held or aliased

# Worst-case prefs: pop-out restored on launch, RPG theme, ember burn.
defaults write "$DOMAIN" popout_shown -bool true
defaults write "$DOMAIN" popover_pinned -bool false
defaults write "$DOMAIN" gamification_style rpg
defaults write "$DOMAIN" burn_style ember
defaults write "$DOMAIN" mock_mode -bool true
defaults write "$DOMAIN" engine_swapd_enabled -bool true   # the swapd engine beside cswap (preview)

# --- swapd stub (must exist before launch: the binary is located at start) --
# The app's ONLY swapd touchpoint is `swapd … --json`, so this script is
# the whole contract under test. Two accounts, slot 1 active. `list`
# carries slot 1's window as it stood BEFORE an ignite; `refresh` and
# `ignite` carry the one a forced fetch saw — which is how the ignite
# assertion below tells the two calls apart.
cat >"$SOCKDIR/swapd" <<'STUB'
#!/bin/sh
payload() {   # $1 = slot 1's 5h resetsAt
    cat <<JSON
{"schemaVersion":1,"providers":[{"provider":"claude","installed":true,"activeSlot":1,
 "nextCandidate":2,"accounts":[
  {"slot":1,"email":"one@swapd.test","organizationName":"Swapd E2E","organizationUuid":"org-1",
   "plan":"Max 20x","alias":"swapd one","active":true,"disabled":false,"preferred":false,
   "usageStatus":"ok","fetchedAt":"2026-09-09T01:00:00Z","ageSeconds":12,
   "windows":[{"kind":"5h","pct":4,"resetsAt":"$1"},
              {"kind":"7d","pct":18,"resetsAt":"2030-01-08T00:00:00Z",
               "pace":{"expectedPct":20,"ahead":false,"lastsToReset":true}}]},
  {"slot":2,"email":"two@swapd.test","organizationName":"Swapd E2E","organizationUuid":"org-2",
   "active":false,"disabled":false,"preferred":false,"usageStatus":"ok",
   "windows":[{"kind":"5h","pct":61,"resetsAt":"2030-01-01T03:00:00Z"}]}]}]}
JSON
}
case "$1" in
    version) echo '{"schemaVersion":1,"version":"0.1.0-e2e"}' ;;
    doctor)  echo '{"schemaVersion":1,"home":"/tmp/swapd-e2e","providers":[{"provider":"claude","installed":true,"path":"/usr/bin/true"}]}' ;;
    list)    payload "2030-01-01T00:00:00Z" ;;
    refresh|ignite) payload "2030-06-01T05:59:59Z" ;;
    auto)
        # The supervised-daemon contract: events on stdout, exit on stdin EOF.
        echo '{"schemaVersion":1,"event":"poll","ts":"2026-09-09T01:00:00Z","provider":"claude","active":{"number":1,"slot":1,"email":"one@swapd.test"},"threshold":10}'
        echo '{"schemaVersion":1,"event":"sleep","ts":"2026-09-09T01:00:00Z","provider":"claude","active":{"number":1,"slot":1,"email":"one@swapd.test"},"summary":"sleep","threshold":10}'
        cat >/dev/null
        ;;
    *) echo '{"schemaVersion":1,"error":{"code":"unsupported","message":"stub swapd: no such verb"}}'; exit 1 ;;
esac
STUB
chmod +x "$SOCKDIR/swapd"
export INFINITUS_SWAPD_CLI="$SOCKDIR/swapd"

# --- AWS sign-in fixtures (must exist before launch: env is read at start) --
# A stub `aws` in place of the real CLI: `login --remote --profile P`
# prints the URL and asks for the code the way the CLI does; the magic
# code signs in, profile e2e-rebind hits the "already configured to use
# session" question (answered n → failed, never rebound).
cat >"$SOCKDIR/aws" <<'STUB'
#!/bin/sh
# `sts get-caller-identity`: the app's probe (#313) — signed in only
# once the gate says so with a flag file next to this stub.
if [ "$1" = "sts" ]; then
    [ -f "$(dirname "$0")/aws-probe-ok" ] && exit 0
    echo "aws: [ERROR]: Your session has expired. Please reauthenticate using 'aws login'."; exit 255
fi
profile=""; remote=""
while [ $# -gt 0 ]; do [ "$1" = "--profile" ] && profile="$2"; [ "$1" = "--remote" ] && remote=1; shift; done
# The orphan fixture (#274): a login that never finishes.
[ "$profile" = "e2e-orphan" ] && exec sleep 3600
# A session's own login (#275): without --remote the real CLI waits on
# a callback listener; any callback ends the wait and it fails on the state.
if [ -z "$remote" ]; then
    port=$((40000 + $$ % 10000))
    echo "Attempting to open your default browser. If the browser does not open, open the following URL."
    echo "https://e2e.invalid/authorize?profile=$profile&redirect_uri=http://127.0.0.1:$port/oauth/callback"
    printf 'HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n' | nc -l 127.0.0.1 "$port" >/dev/null
    echo "aws: [ERROR]: Error loading or redeeming a login authorization code: State parameter infinitus does not match expected value e2e."; exit 255
fi
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
export INFINITUS_MIRROR_SNAPSHOT="$SOCKDIR/mirror-snapshot.json"
export INFINITUS_AWS_PROBE_S=2
# A stub `gcloud` (#367): `auth login --no-launch-browser` prints the
# SDK's paste-back prompt and reads the code; `auth print-access-token`
# is the app's probe — signed in only once the gate says so.
cat >"$SOCKDIR/gcloud" <<'STUB'
#!/bin/sh
if [ "$2" = "print-access-token" ]; then
    [ -f "$(dirname "$0")/gcloud-probe-ok" ] && exit 0
    echo "ERROR: (gcloud.auth.print-access-token) You do not currently have an active account selected."; exit 1
fi
echo "Go to the following link in your browser, and complete the sign-in prompts:"
echo ""
echo "    https://e2e.invalid/o/oauth2/auth?client_id=e2e"
echo ""
printf 'Once finished, enter the verification code provided in your browser: '
read code
[ "$code" = "E2E-GCLOUD-OK" ] || { echo "ERROR: (gcloud.auth.login) invalid_grant: Bad Request"; exit 1; }
echo "You are now logged in as [e2e@example.com]."
STUB
chmod +x "$SOCKDIR/gcloud"
export INFINITUS_GCLOUD_CLI="$SOCKDIR/gcloud"
# The fake Claude session: a process with no tty (setsid, so the nudge
# can't fall back to typing into THIS terminal) listening on the record's
# messaging socket, writing every frame it receives to an inbox file.
export CLAUDE_CONFIG_DIR="$SOCKDIR/claude"
PEER_SOCK="$SOCKDIR/peer.sock"; INBOX="$SOCKDIR/inbox.ndjson"
python3 - "$PEER_SOCK" "$INBOX" <<'PEER' &
import os, socket, subprocess, sys
os.setsid()
# The session's own `aws login`, stuck on its callback (#275): a child of
# this process, so the app finds it under the session's pid.
subprocess.Popen([os.environ["INFINITUS_AWS_CLI"], "login", "--profile", "e2e-login"],
                 stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
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
 "peerProtocol":1,"messagingSocketPath":"$PEER_SOCK","name":"e2e-aws","startedAt":1700000000000}
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
# A second session with the same lapse, met by a login that finished
# before this app instance started: the ledger is the only place the
# app can learn that, and it only did once a login was asked for — so
# every relaunch showed the met need as "Log in here" (2026-09-07).
sleep 3600 &
SEED_PID=$!
cat >"$CLAUDE_CONFIG_DIR/sessions/$SEED_PID.json" <<EOF
{"pid":$SEED_PID,"sessionId":"e2e-seed","cwd":"$SESSION_CWD","kind":"interactive","status":"idle","name":"e2e-seed"}
EOF
cat >"$CLAUDE_CONFIG_DIR/projects/$SLUG/e2e-seed.jsonl" <<EOF
{"type":"assistant","timestamp":"$TS","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_seed","name":"Bash","input":{"command":"aws sts get-caller-identity --profile e2e-seeded"}}]}}
{"type":"user","timestamp":"$TS","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_seed","content":"\naws: [ERROR]: Your session has expired. Please reauthenticate using 'aws login'.\n"}]}}
EOF
cat >"$INFINITUS_AWS_LEDGER" <<EOF
[{"phase":"done","flow":"remote","message":"signed in","startedAt":$(date +%s),"pid":$SEED_PID,"profile":"e2e-seeded"}]
EOF
# A login wrapper an earlier instance left behind (#274): spawned from a
# subshell that exits, so it is launchd's child like the real leftover.
( /usr/bin/script -q /dev/null "$SOCKDIR/aws" login --remote --profile e2e-orphan </dev/null >/dev/null 2>&1 & )
sleep 1
pgrep -f "profile e2e-orphan" >/dev/null || fail "orphan login fixture did not start"

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
i=0
while pgrep -f "profile e2e-orphan" >/dev/null; do
    i=$((i + 1)); [ "$i" -lt 15 ] || fail "orphan login wrapper from an earlier instance not swept at launch"
    sleep 1
done
echo "aws: orphan login wrapper swept at launch"

# --- functional ---------------------------------------------------------
"$CTL" manifest | json "len(d['commands'])" | grep -qE '^[1-9][0-9]*$' || fail "manifest empty"
"$CTL" manifest | expect "next(c for c in d['commands'] if c['name']=='signin-code')['stdin']=='secret' and 'stdin' not in next(c for c in d['commands'] if c['name']=='status')" || fail "manifest: stdin flag (#747)"
"$CTL" lock-status | expect "d['enabled'] is False and d['locked'] is False and d['relock']=='1 h'" || fail "biometric lock must default to off, unlocked, re-lock 1 h"
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
# One account re-rolls alone (#145): one name, worn by that account, still distinct from every other.
"$CTL" randomize-names cswap/claude 2 | expect "len(d['names'])==1 and [a for a in d['fleet']['accounts'] if a['number']==2][0].get('alias')==d['names'][0] and len(set(a.get('alias') for a in d['fleet']['accounts']))==len(d['fleet']['accounts'])" || fail "randomize-names <n> didn't re-roll account 2 alone"
"$CTL" profile-set e2e-review --cwd /tmp --mode acceptEdits --model opus --allow "Edit, Bash git" | expect "d['profile']['name']=='e2e-review' and d['profile']['permissionMode']=='acceptEdits' and d['profile']['model']=='opus' and d['profile']['allowTools']==['Edit','Bash git']" || fail "profile-set didn't save the fields"
"$CTL" profiles | expect "[p['name'] for p in d['profiles']]==['e2e-review']" || fail "profiles didn't list the saved profile"
"$CTL" profile-remove e2e-review | expect "d['removed'] is True" || fail "profile-remove didn't remove"
"$CTL" past-sessions --limit 3 | expect "isinstance(d['sessions'], list) and len(d['sessions'])<=3" || fail "past-sessions didn't list"
echo "round-trips: ok (switch, rotate, hold, unhold, rename, prefer, reorder, randomize-names, past-sessions, profiles)"
"$CTL" plan | expect "'plan' in d and (d['plan'] is None or 'steps' in d['plan'])" || fail "plan verb"
"$CTL" ignite cswap/claude 2 | expect "'fleet' in d" || fail "ignite verb"

# --- swapd: the second engine runs beside cswap ------------------------
"$CTL" status | json "d['engines']['swapd']['registered']" | grep -q True || fail "swapd not registered"
"$CTL" fleets | expect "[f['key'] for f in d][0]=='cswap/claude' and any(f['key']=='swapd/claude' for f in d)" \
    || fail "swapd/claude missing, or it displaced cswap as the primary fleet"
"$CTL" fleets | expect "'refreshAccount' in [f for f in d if f['key']=='swapd/claude'][0]['capabilities']" \
    || fail "swapd must advertise refreshAccount"
# The point of the capability: ignite publishes the account it just
# refreshed, so the reply carries the window the run opened (#338) —
# the stub's refresh reset, never the one `list` was serving before it.
"$CTL" ignite swapd/claude 1 | expect "[a for a in d['fleet']['accounts'] if a['number']==1][0]['usage']['fiveHour']['resetsAt']=='2030-06-01T05:59:59Z'" \
    || fail "ignite didn't publish the refreshed window"
echo "swapd: registered beside cswap, ignite published the refreshed window"
# #475: an enabled engine runs its own `auto` under the supervisor.
pgrep -f "$SOCKDIR/swapd auto" >/dev/null || fail "swapd auto must run under the supervisor while the engine is on"
"$CTL" events | expect "not any((e.get('summary') or '') in ('poll', 'sleep') for e in (d if isinstance(d, list) else d.get('events', [])))" \
    || fail "the supervisor must drop the poll/sleep heartbeats (#475)"
# #616: the headroom verdict rides `fleets` only while priority_mode is on;
# the stub's active slot sits at 5h 4% / 7d 18%, so 7d binds.
"$CTL" fleets | expect "all('headroom' not in f for f in d)" || fail "headroom must be absent while priority_mode is off"
"$CTL" prefs set priority_mode hold | expect "d['value']=='hold'" || fail "prefs set priority_mode"
"$CTL" fleets | expect "[f for f in d if f['key']=='swapd/claude'][0]['headroom']['state']=='abundant' and [f for f in d if f['key']=='swapd/claude'][0]['headroom']['window']=='7d' and [f for f in d if f['key']=='swapd/claude'][0]['headroom']['pct']==18" \
    || fail "headroom must judge the fullest window abundant at 18%"
"$CTL" prefs set priority_low_pct 15 | expect "d['value']==15" || fail "prefs set priority_low_pct"
"$CTL" fleets | expect "[f for f in d if f['key']=='swapd/claude'][0]['headroom']['state']=='low'" || fail "headroom must go low once 7d is at or above priority_low_pct"
"$CTL" prefs set priority_low_pct 80 | expect "d['value']==80" || fail "prefs set priority_low_pct back"
"$CTL" fleets | expect "[f for f in d if f['key']=='swapd/claude'][0]['headroom']['state']=='abundant'" || fail "headroom must release at 18% under priority_abundant_pct"
"$CTL" prefs set priority_mode off | expect "d['value']=='off'" || fail "prefs set priority_mode off"
"$CTL" fleets | expect "all('headroom' not in f for f in d)" || fail "headroom must drop once priority_mode is off"
echo "headroom: absent off, 7d binds, low/abundant follow the thresholds (#616)"
"$CTL" aws-logins | expect "'logins' in d and isinstance(d['logins'], list)" || fail "aws-logins verb"
"$CTL" forecast | expect "'forecast' in d and (d['forecast'] is None or ('basis' in d['forecast'] and 'accounts' in d['forecast']))" || fail "forecast verb"
"$CTL" stats --period week | expect "d['period']=='week' and 'total' in d and 'commits' in d['total'] and 'humanMessages' in d['total']" || fail "stats verb"

# --- windows: Settings open idles too ------------------------------------
# The Settings-open case sat at 18% for a week (#346: transcript reads,
# the past-sessions walk, the team publish and the machine sampler all
# ran on behind it) while the pop-out gate read 0.5%; this is the gate
# that would have caught it. Settle first: the window builds its tabs on
# the first open.
settings_visible() { "$CTL" windows | expect "any(w['visible'] and w.get('title')=='Settings' for w in d)"; }
"$CTL" show settings | expect "d['shown']=='settings'" || fail "show settings"
sleep 3
settings_visible || fail "Settings window not visible after show settings"
sleep 9
SA="$("$CTL" perf | json "d['cpuSeconds']")"
sleep 15
SB="$("$CTL" perf | json "d['cpuSeconds']")"
SPCT="$(python3 -c "print(round(($SB-$SA)/15*100,1))")"
echo "idle CPU with Settings open: ${SPCT}%"
python3 -c "import sys; sys.exit(0 if $SPCT <= $IDLE_BUDGET_PCT else 1)" || fail "Settings idle CPU ${SPCT}% over budget ${IDLE_BUDGET_PCT}%"
"$CTL" hide settings | expect "d['hidden']=='settings'" || fail "hide settings"
sleep 1
settings_visible && fail "Settings still visible after hide"
echo "windows: ok (Settings open idle ${SPCT}%, hidden)"

# The preference catalog (#558): the table with values, and `get` narrowed.
"$CTL" prefs | expect "any(s['slug']=='display' and s['name']=='Display' for s in d['sections']) and any(p['key']=='popup_layout' and p['section']=='display' and p['effect']=='live' for p in d['prefs'])" || fail "prefs"
"$CTL" prefs get popup_layout engine_cswap_enabled | expect "[p['key'] for p in d['prefs']]==['popup_layout','engine_cswap_enabled'] and d['prefs'][1]['effect']=='restart'" || fail "prefs get"
# A key with no window behind it: a layout swap here would re-lay the
# pop-out twice and leave ~45 MB resident before the RSS gate (2026-09-10).
"$CTL" prefs set revive_lead_minutes 15 | expect "d['key']=='revive_lead_minutes' and d['value']==15" || fail "prefs set"
"$CTL" prefs get revive_lead_minutes | expect "d['prefs'][0]['value']==15" || fail "prefs set did not stick"
"$CTL" prefs set refresh_interval 45 >/dev/null 2>&1 && fail "prefs set accepted a value off the choices"
"$CTL" prefs set revive_lead_minutes 10 | expect "d['value']==10" || fail "prefs set back"
# The reply keeps catalog order (themes before animations), not the order asked.
"$CTL" prefs get intro_speed gamification_style | expect "(lambda p: p['intro_speed']['section']=='animations' and p['intro_speed']['min']==0.4 and p['intro_speed']['max']==2 and any(c['id']=='rpg' for c in p['gamification_style']['choices']))({x['key']:x for x in d['prefs']})" || fail "prefs: animations range / theme choices (#747)"
"$CTL" prefs set intro_speed 3 >/dev/null 2>&1 && fail "prefs set accepted a value outside the range"
"$CTL" prefs set intro_style fade | expect "d['value']=='fade'" || fail "prefs set intro_style"
"$CTL" prefs set intro_style top >/dev/null || fail "prefs set intro_style back"
# The fork server's tunnel (#572): off by default on T3's port; a mock
# instance named Infinitus is `blocked`, so enabling it here never runs
# cloudflared — the gate is what this checks.
"$CTL" status | expect "d['forkTunnel']['state']=='off' and d['forkTunnel']['port']==3773 and d['forkTunnel']['enabled'] is False and d['forkTunnel'].get('url') is None" || fail "fork tunnel must default to off on 3773"
"$CTL" prefs set fork_tunnel_enabled true | expect "d['value'] is True" || fail "prefs set fork_tunnel_enabled"
"$CTL" status | expect "d['forkTunnel']['state']=='blocked'" || fail "a mock instance must report the fork tunnel blocked, not run it"
"$CTL" prefs set fork_server_port 70000 | expect "d['value']==70000" || fail "prefs set fork_server_port"
"$CTL" status | expect "d['forkTunnel']['state']=='invalidPort'" || fail "an out-of-range fork port must report invalidPort"
"$CTL" prefs set fork_server_port 3773 >/dev/null || fail "prefs set fork_server_port back"
"$CTL" prefs set fork_tunnel_enabled false | expect "d['value'] is False" || fail "prefs set fork_tunnel_enabled back"
"$CTL" prefs set fork_tunnel_hostname code.e2e.invalid | expect "d['value']=='code.e2e.invalid'" || fail "prefs set fork_tunnel_hostname"
"$CTL" prefs get fork_tunnel_hostname | expect "d['prefs'][0]['value']=='code.e2e.invalid'" || fail "prefs get fork_tunnel_hostname"
"$CTL" prefs set fork_tunnel_hostname '""' | expect "d['value']==''" || fail "prefs set fork_tunnel_hostname back"
"$CTL" status | expect "d['forkTunnel']['state']=='off'" || fail "fork tunnel must be off again"
pgrep -P "$APP_PID" -f cloudflared >/dev/null && fail "the e2e instance ran cloudflared for the fork port"
echo "prefs: ok"

# JSON-body verbs (#572 N1): the socket takes what the mirror routes take.
"$CTL" client-activity --body '{"clientId":"e2e","visible":true,"focused":true,"recentlyInteracted":true,"scopes":[{"type":"fleets"}],"ttlMs":5000}' | expect "d['clientId']=='e2e'" || fail "client-activity"
"$CTL" perf | expect "d['leaseScopes'].get('e2e')==['fleets']" || fail "perf must name the lease e2e just took (#499)"
"$CTL" perf | expect "'stats' not in d['leaseScopes'].get('local', [])" || fail "the local client must not hold stats without the Stats pane (#499)"
# #572 G6: a phone withdraws its own alert registration; a second withdrawal is a no-op, not an error.
"$CTL" activities-token --body '{"kind":"alert","token":"00ff","deviceId":"e2e-phone","deviceName":"e2e phone","environment":"sandbox","registeredAt":"2026-09-11T00:00:00Z"}' | expect "d['slot']=='e2e-phone/alert'" || fail "activities-token register"
"$CTL" activities-token --forget e2e-phone/alert | expect "d['forgotten'] is True" || fail "activities-token --forget"
"$CTL" activities-token --forget e2e-phone/alert | expect "d['forgotten'] is False" || fail "activities-token --forget twice"
echo '{"id":"e2e-crash","platform":"ios","device":"e2e","appVersion":"0","osVersion":"0","at":"2026-09-10T00:00:00Z","kind":"crash","reason":"e2e","frames":[]}' | "$CTL" crash-report | expect "d['id']=='e2e-crash'" || fail "crash-report (stdin body)"
"$CTL" crashes | expect "any(c['id']=='e2e-crash' for c in d['crashes'])" || fail "crash-report not listed by crashes"
# The #677 sign-in verbs are wired (the flow itself needs a human and the Claude CLI): a
# flow nobody started is refused by id, and a fleet that does not exist by name.
"$CTL" signin-status nope 2>&1 | grep -q "no sign-in nope" || fail "signin-status did not refuse an unknown flow"
"$CTL" signin-begin no/such 2>&1 | grep -q "usage: signin-begin" || fail "signin-begin did not refuse an unknown fleet"
"$CTL" crash-report --body '{nope' >/dev/null 2>&1 && fail "crash-report accepted a broken body"
echo "body verbs: ok"

# --- scenarios: all-dead (no candidate, then recovers) -------------------
"$INFINITUS_CSWAP" simulate alldead >/dev/null
"$CTL" refresh | expect "d[0].get('nextCandidate') is None and d[0].get('nextRecovery') is not None" \
    || fail "all-dead scenario not reflected in fleets"
sleep 2
popout_visible || fail "pop-out lost during all-dead"
# The reviver band (#227) is a CA breath on the pop-out: once the re-sort
# has settled, the all-dead state must idle like any other — a per-frame
# regression shows up here, not only in the long idle gate at the end.
# Settle first: the re-sort's tail and a loaded runner's scheduling noise
# read as 14 % over a 6 s window (#428).
sleep 8
RA="$("$CTL" perf | json "d['cpuSeconds']")"
sleep 12
RB="$("$CTL" perf | json "d['cpuSeconds']")"
RPCT="$(python3 -c "print(round(($RB-$RA)/12*100,1))")"
echo "all-dead CPU with the reviver band: ${RPCT}%"
python3 -c "import sys; sys.exit(0 if $RPCT <= $IDLE_BUDGET_PCT else 1)" || fail "all-dead CPU ${RPCT}% over budget ${IDLE_BUDGET_PCT}%"
"$INFINITUS_CSWAP" simulate off >/dev/null
"$CTL" refresh | expect "d[0].get('nextCandidate') is not None" || fail "fleet didn't recover after simulate off"
echo "scenarios: ok (all-dead and back)"

# --- control socket self-heal -------------------------------------------
# A dev instance launched without INFINITUS_CONTROL_SOCKET unlinks and
# re-binds the path; killed, it leaves an inode nobody answers and the
# bundle was unreachable for 25 minutes (2026-09-03). The app must notice
# on its next snapshot and bind again.
# The refusal is asserted right here, in the same process that planted the
# inode: the app re-binds on its next snapshot, and a `status` probe from the
# shell a few ms later already raced that heal once (#434).
python3 - "$SOCKDIR/control.sock" <<'PYS' || fail "a dead socket path should refuse"
import os, socket, sys
p = sys.argv[1]; os.unlink(p)
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.bind(p); s.listen(1); s.close()  # dead inode stays
c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); c.settimeout(2)
try:
    c.connect(p)
except (ConnectionRefusedError, socket.timeout):
    sys.exit(0)
sys.exit(1)
PYS
i=0
until "$CTL" status >/dev/null 2>&1; do
    i=$((i + 1)); [ "$i" -le 75 ] || fail "control socket not re-bound within a refresh interval"
    sleep 1
done
echo "control: ok (dead socket path re-bound after ${i}s)"

# --- AWS sign-in from the phone -------------------------------------------
# The transcript scan surfaces the expired profile against the session.
aws_login_item() { "$CTL" aws-logins | expect "any(l['profile']=='e2e-login' and l['pid']==$SESSION_PID and not l.get('provider') for l in d['logins'])"; }
aws_phase() { "$CTL" aws-logins | json "next((l.get('state') or {}).get('phase') for l in d['logins'] if l['profile']=='$1' and not l.get('provider'))"; }
i=0
until aws_login_item; do
    i=$((i + 1)); [ "$i" -lt 60 ] || fail "expired AWS session never surfaced in aws-logins"
    sleep 1
done
echo "aws: need surfaced after ${i}s"
# #612: the row carries the id, the start and the need the fork's list shows;
# the by-hand nudge is a no-op with its reason on a session that never stopped.
"$CTL" sessions | expect "any(s['pid']==$SESSION_PID and s['sessionId']=='e2e-aws' and s['startedAt']=='2023-11-14T22:13:20Z' and 'aws-login:e2e-login' in s['needs'] for s in d)" || fail "sessions row fields (#612)"
"$CTL" nudge "$SESSION_PID" | expect "d['pid']==$SESSION_PID and d['nudged']==False and d['reason'].startswith('not resumable')" || fail "nudge no-op"
"$CTL" aws-logins | expect "not any(l['profile']=='e2e-seeded' for l in d['logins'])" || fail "a need met before launch (ledger) still shows"
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
# The session's own stuck login (#275) was released before the nudge,
# and the nudge says so.
i=0
while pgrep -f "aws login --profile e2e-login" >/dev/null; do
    i=$((i + 1)); [ "$i" -lt 10 ] || fail "the session's own aws login was not released"
    sleep 1
done
grep -q "Your own .aws login. was stopped" "$INBOX" || fail "nudge does not say the session's own login was stopped"
echo "aws: the session's own stuck login released, nudge says so"
# --- gcloud sign-in from the phone (#367) --------------------------------
# The same session's gcloud call dies on lapsed credentials: the need
# surfaces as a gcloud item against the pid, the paste-back flow signs
# in, the item clears, the session is nudged with the gcloud wording.
TS2="$(python3 -c "import datetime;print(datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.000Z'))")"
cat >>"$CLAUDE_CONFIG_DIR/projects/$SLUG/e2e-aws.jsonl" <<EOF
{"type":"assistant","timestamp":"$TS2","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_gc","name":"Bash","input":{"command":"gcloud storage ls --account=e2e@example.com"}}]}}
{"type":"user","timestamp":"$TS2","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_gc","content":"ERROR: (gcloud.storage.ls) There was a problem refreshing your current auth tokens: invalid_grant\nPlease run:\n\n  $ gcloud auth login\n\nto obtain new credentials."}]}}
EOF
gcloud_login_item() { "$CTL" aws-logins | expect "any(l['profile']=='e2e@example.com' and l['pid']==$SESSION_PID and l.get('provider')=='gcloud' for l in d['logins'])"; }
gcloud_phase() { "$CTL" aws-logins | json "next((l.get('state') or {}).get('phase') for l in d['logins'] if l['profile']=='e2e@example.com' and l.get('provider')=='gcloud')"; }
i=0
until gcloud_login_item; do
    i=$((i + 1)); [ "$i" -lt 60 ] || fail "lapsed gcloud credentials never surfaced in aws-logins"
    sleep 1
done
echo "gcloud: need surfaced after ${i}s"
"$CTL" gcloud-login e2e@example.com --remote --pid "$SESSION_PID" | expect "d['state']['flow']=='remote' and d['state']['provider']=='gcloud'" || fail "gcloud-login --remote"
i=0
until [ "$(gcloud_phase)" = "waitingForCode" ]; do
    i=$((i + 1)); [ "$i" -lt 20 ] || fail "gcloud login never asked for the code (phase $(gcloud_phase))"
    sleep 1
done
"$CTL" aws-logins | expect "next(l['state']['url'] for l in d['logins'] if l.get('provider')=='gcloud').startswith('https://e2e.invalid/')" || fail "no gcloud URL for the phone"
printf 'E2E-GCLOUD-OK' | "$CTL" gcloud-login-code e2e@example.com >/dev/null || fail "gcloud-login-code"
i=0
while gcloud_login_item; do
    i=$((i + 1)); [ "$i" -lt 20 ] || fail "gcloud need did not clear after the login (phase $(gcloud_phase))"
    sleep 1
done
i=0
until grep -q "gcloud login for e2e@example.com completed from the phone" "$INBOX" 2>/dev/null; do
    i=$((i + 1)); [ "$i" -lt 20 ] || fail "session never got the gcloud continue nudge"
    sleep 1
done
echo "gcloud: code flow signed in, need cleared, session nudged"
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
# A second lapse after the login, met outside the app (#313): the ledger
# can't clear it, the probe does once the CLI says the profile works.
TS2="$(python3 -c "import datetime;print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(seconds=1)).strftime('%Y-%m-%dT%H:%M:%S.000Z'))")"
cat >>"$CLAUDE_CONFIG_DIR/projects/$SLUG/e2e-aws.jsonl" <<EOF
{"type":"assistant","timestamp":"$TS2","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_e2e2","name":"Bash","input":{"command":"aws sts get-caller-identity --profile e2e-login"}}]}}
{"type":"user","timestamp":"$TS2","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_e2e2","content":"\naws: [ERROR]: Your session has expired. Please reauthenticate using 'aws login'.\n"}]}}
EOF
i=0
until aws_login_item; do
    i=$((i + 1)); [ "$i" -lt 60 ] || fail "second lapse never surfaced in aws-logins"
    sleep 1
done
touch "$SOCKDIR/aws-probe-ok"
i=0
while aws_login_item; do
    i=$((i + 1)); [ "$i" -lt 30 ] || fail "need did not clear once the CLI said the profile works"
    sleep 1
done
"$CTL" aws-login e2e-login --status | expect "'outside the app' in d['state']['message']" || fail "probe outcome not recorded"
echo "aws: lapse met outside the app cleared by the probe"

# --- team (spec §11) -------------------------------------------------------
# The app creates a team on a bare repo; a second identity — the CLI
# in-process, its own INFINITUS_TEAM_DIR — joins with a team code and
# publishes a fixture transcript; the app approves and reads it back.
"$CTL" team-status | expect "d is None" || fail "team-status must be null before a team exists"
git init -q --bare "$SOCKDIR/team.git"
"$CTL" team-create Papaya --remote "file://$SOCKDIR/team.git" --as Ann \
    | expect "d['role']=='leader' and d['members'][0]['name']=='Ann' and d['members'][0]['founder']" || fail "team-create"
CODE="$("$CTL" team-code --days 1 | json "d['code']")"
case "$CODE" in infinitus://join/*) ;; *) fail "team-code shape" ;; esac
NOW="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
mkdir -p "$SOCKDIR/fixture/projects/-tmp-e2e"
printf '%s\n%s\n' \
    "{\"type\":\"user\",\"cwd\":\"/tmp/e2e\",\"timestamp\":\"$NOW\",\"origin\":{\"kind\":\"human\"},\"message\":{\"role\":\"user\",\"content\":\"hello team\"}}" \
    "{\"type\":\"assistant\",\"timestamp\":\"$NOW\",\"message\":{\"id\":\"e2e-1\",\"model\":\"claude-opus-5\",\"usage\":{\"input_tokens\":10,\"output_tokens\":1},\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}}" \
    > "$SOCKDIR/fixture/projects/-tmp-e2e/e2e1.jsonl"
CLI_TEAM="$SOCKDIR/team-cli"
printf '%s' "$CODE" | INFINITUS_TEAM_DIR="$CLI_TEAM" "$CTL" team request - --name Bo >/dev/null || fail "cli team request"
KID="$(INFINITUS_TEAM_DIR="$CLI_TEAM" "$CTL" team status | json "d['kid']")"
"$CTL" team-fetch | expect "len(d['requests'])==1 and d['requests'][0]['name']=='Bo'" || fail "the request did not reach the leader"
"$CTL" team-approve "$KID" | expect "any(m['name']=='Bo' and m['role']=='member' for m in d['members']) and not d['requests']" || fail "team-approve"
INFINITUS_TEAM_DIR="$CLI_TEAM" "$CTL" team fetch >/dev/null || fail "cli team fetch"
# #354: on a Mac with the app up and no INFINITUS_TEAM_DIR, `team status` is
# the app's own view, and a subcommand the app has no verb for either refuses
# to mint a second identity or says whose identity it is using.
env -u INFINITUS_TEAM_DIR "$CTL" team status | expect "d['role']=='leader' and d['name']=='Papaya'" || fail "cli team status did not route to the app"
env -u INFINITUS_TEAM_DIR "$CTL" team identity show 2>&1 | grep -q "owns this Mac's team identity\|infinitusctl's own identity" || fail "cli team identity neither refused nor named its own identity beside the app's"
INFINITUS_TEAM_DIR="$CLI_TEAM" "$CTL" team publish --projects "$SOCKDIR/fixture/projects" \
    | expect "d['transcriptChunks']>=1" || fail "cli team publish"
# "Nobody" (spec §7): the appended line WOULD chunk — the point of the
# assertion is that it does not while transcripts are off. Do not drop it.
INFINITUS_TEAM_DIR="$CLI_TEAM" "$CTL" team share transcripts off \
    | expect "d['byKind']['transcripts']=='off'" || fail "team share transcripts off"
printf '%s\n' \
    "{\"type\":\"assistant\",\"timestamp\":\"$NOW\",\"message\":{\"id\":\"e2e-2\",\"model\":\"claude-opus-5\",\"usage\":{\"input_tokens\":3,\"output_tokens\":1},\"content\":[{\"type\":\"text\",\"text\":\"more\"}]}}" \
    >> "$SOCKDIR/fixture/projects/-tmp-e2e/e2e1.jsonl"
INFINITUS_TEAM_DIR="$CLI_TEAM" "$CTL" team publish --projects "$SOCKDIR/fixture/projects" \
    | expect "d['transcriptChunks']==0" || fail "transcripts off must publish no chunks"
INFINITUS_TEAM_DIR="$CLI_TEAM" "$CTL" team share transcripts leaders \
    | expect "d['byKind']['transcripts']=='leaders'" || fail "restore the transcripts audience"
"$CTL" team-fetch | expect "any(m['name']=='Bo' and 'stats' in m['kinds'] and 'transcripts' in m['kinds'] for m in d['members'])" || fail "the member's files are not readable"
"$CTL" team-publish | expect "'published' in d" || fail "team-publish"
"$CTL" team-status | expect "d.get('lastPublish') is not None and d.get('lastError') is None" || fail "loop state after publish"
echo "team: ok (leader Ann, member Bo $KID)"

# --- team control (#220, grantor) ------------------------------------------
# Bo lets leaders send to one session; the hint rides Bo's now.json and
# Ann's snapshot says what Bo lets her do. Driving itself lands with the
# driver PR (the mirror listener is off in mock mode).
INFINITUS_TEAM_DIR="$CLI_TEAM" "$CTL" team grant leaders --sessions s-e2e --send \
    | expect "d['audience']=='leaders' and d['sessions']==['s-e2e'] and d['capabilities']==['send']" || fail "team grant"
GRANT="$(INFINITUS_TEAM_DIR="$CLI_TEAM" "$CTL" team grants | json "d['grants'][0]['id']")"
INFINITUS_TEAM_DIR="$CLI_TEAM" "$CTL" team publish --projects "$SOCKDIR/fixture/projects" >/dev/null || fail "publish with a grant"
"$CTL" team-fetch | expect "[m for m in d['members'] if m['name']=='Bo'][0].get('controls')==['send']" || fail "the grant hint did not reach the leader's snapshot"
INFINITUS_TEAM_DIR="$CLI_TEAM" "$CTL" team revoke "$GRANT" | expect "d['removed']" || fail "team revoke"
INFINITUS_TEAM_DIR="$CLI_TEAM" "$CTL" team grants | expect "d['grants']==[]" || fail "revoke left the grant"
# Driver over the store lane: Ann grants Bo `send` on the live session;
# Bo's send finds no endpoint in Ann's now.json (no listener in mock
# mode) and lands in the store; Ann's next fetch executes it into the
# session's peer inbox and acks; Bo reads the ack. A capability Bo was
# NOT given is acked as a refusal. (The HTTP lanes are unit-tested: a
# listener here would collide with the real app's mirror port.)
ANN_KID="$("$CTL" team-status | json "d['kid']")"
"$CTL" team grant "$KID" --sessions e2e-aws --send | expect "d['capabilities']==['send']" || fail "ann grant"
ANN_GRANT="$("$CTL" team grants | json "d['grants'][0]['id']")"
printf 'hello from Bo via the store' | INFINITUS_TEAM_DIR="$CLI_TEAM" "$CTL" team send "$ANN_KID" e2e-aws \
    | expect "d['lane']=='store' and d['outcome']=='queued'" || fail "team send"
INFINITUS_TEAM_DIR="$CLI_TEAM" "$CTL" team mode "$ANN_KID" e2e-aws acceptEdits | expect "d['lane']=='store'" || fail "team mode"
"$CTL" team-fetch >/dev/null || fail "grantor fetch"
grep -q 'hello from Bo via the store' "$INBOX" \
    || fail "the store command never reached the session (events: $("$CTL" events --limit 100 | python3 -c "import json,sys; print([e['text'] for e in json.load(sys.stdin) if e['icon']=='person.2'])"); acks: $(INFINITUS_TEAM_DIR="$CLI_TEAM" "$CTL" team acks 2>&1 | head -c 400))"
INFINITUS_TEAM_DIR="$CLI_TEAM" "$CTL" team acks \
    | expect "sorted(r['outcome'] for r in d)==['delivered','noGrant']" || fail "acks (got: $(INFINITUS_TEAM_DIR="$CLI_TEAM" "$CTL" team acks 2>&1 | head -c 300))"
"$CTL" team revoke "$ANN_GRANT" | expect "d['removed']" || fail "ann revoke"
"$CTL" events --limit 100 | expect "d and all(e['id'] and e['kind'] for e in d) and any(e['kind']=='team-control' and e['icon']=='person.2' for e in d)" || fail "events rows carry id and kind (#615)"
LAST_EVENT=$("$CTL" events --limit 100 | python3 -c "import json,sys; print(json.load(sys.stdin)[-1]['id'])")
"$CTL" events --after "$LAST_EVENT" | expect "d['known'] is True and d['after']=='$LAST_EVENT' and d['rows']==[]" || fail "events --after the newest id is known with no rows (#346)"
"$CTL" events --after nope --limit 3 | expect "d['known'] is False and len(d['rows'])==3" || fail "events --after an unknown id re-seeds with the full tail (#346)"
echo "team control: ok (grantor + store-lane driver)"

# --- performance --------------------------------------------------------
# Sampled AFTER the churn above so a timer left behind by a closed window
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

# --- no lease (#223 phase 5) --------------------------------------------
# The Mac's own pop-out is a client-activity lease; with it closed and no
# phone reporting, nothing per-session runs, so idle must match the gate.
"$CTL" hide popout | expect "d['hidden']=='popout'" || fail "hide popout"
popout_visible && fail "pop-out still visible for the no-lease window"
"$CTL" perf | expect "d.get('leases', 0) == 0" || fail "the local lease survives hide popout"
sleep 5
A="$("$CTL" perf | json "d['cpuSeconds']")"
sleep "$WINDOW_S"
B="$("$CTL" perf | json "d['cpuSeconds']")"
PCT="$(python3 -c "print(round(($B-$A)/$WINDOW_S*100,1))")"
echo "idle CPU with no lease (pop-out closed, no phone): ${PCT}%  (budget ${IDLE_BUDGET_PCT}%)"
python3 -c "import sys; sys.exit(0 if $PCT <= $IDLE_BUDGET_PCT else 1)" || fail "idle CPU with no lease ${PCT}% over budget ${IDLE_BUDGET_PCT}%"
"$CTL" show popout >/dev/null || fail "show popout (restore)"
popout_visible || fail "pop-out not restored after the no-lease window"
# #654: the fork's quit-with-window setting sends `quit`; the app answers,
# then leaves on its own (tunnels, terminals, owned sessions first). This
# instance leads a team with a git remote, and applicationShouldTerminate
# holds the quit for the team's now.json delete (TeamModel.quitBound,
# 20s) — the wait is bounded above that, and the time is printed.
"$CTL" quit | expect "d['quitting'] is True" || fail "quit"
# The app is this shell's child: until `wait` reaps it the pid lingers as
# a zombie, so the exit shows as state Z, not as a missing pid.
i=0
while [ "$(ps -o stat= -p "$APP_PID" 2>/dev/null | cut -c1)" ] \
      && [ "$(ps -o stat= -p "$APP_PID" 2>/dev/null | cut -c1)" != "Z" ]; do
    i=$((i + 1)); [ "$i" -lt 300 ] || fail "the app did not exit within 30s of quit"
    sleep 0.1
done
wait "$APP_PID" 2>/dev/null
pgrep -f "$SOCKDIR/swapd auto" >/dev/null && fail "swapd auto outlived the app (#475)"
echo "quit: ok (exited after $((i / 10)).$((i % 10))s)"
echo "E2E PASS"
