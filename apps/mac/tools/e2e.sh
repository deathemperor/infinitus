#!/bin/sh
# End-to-end + performance gate (#18). Launches the DEBUG app against the
# demo engine (tools/demo-swapd: fabricated fleet, no credentials, no
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
# never run.infinitus), INFINITUS_SWAPD_CLI pinned to the demo script.
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
export INFINITUS_TEAM_DIR="$SOCKDIR/team-app"          # the app's team dir + file secrets (#1313: CI has no keychain)
# An empty Claude home (#1204): the stats and token-rate scanners read
# `$CLAUDE_CONFIG_DIR/projects`, and without this the run scanned the
# developer's real transcript tree — 14 GB on one Mac, nothing on CI — so
# the perf gate measured the corpus, not the app. CI and a dev Mac now
# measure the same thing; the scan's own cost is #1204's fix, not hidden.
export CLAUDE_CONFIG_DIR="$SOCKDIR/claude-home"
mkdir -p "$CLAUDE_CONFIG_DIR/projects"
export INFINITUS_SWAPD_CLI="$PWD/tools/demo-swapd"
export INFINITUS_DEMO_STATE="$SOCKDIR/demo-state.json"   # not $TMPDIR: the bundled app in mock mode shares that one
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
    # worktree's demo-swapd runs as /tmp/…/demo-swapd), so the pattern is
    # the stripped form — a substring of both (42 orphans from one day's
    # scratchpad runs, 2026-09-11).
    pkill -f "${INFINITUS_SWAPD_CLI#/private} auto" 2>/dev/null || true
    pkill -f "$SOCKDIR/aws" 2>/dev/null || true
    pkill -f "aws-own-login-listener" 2>/dev/null || true
    pkill -f "profile e2e-orphan" 2>/dev/null || true
    [ -z "${DESK_PID:-}" ] || kill "$DESK_PID" 2>/dev/null || true
    rm -rf "$SOCKDIR"
    "$INFINITUS_SWAPD_CLI" reset >/dev/null 2>&1 || true
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
        # #1007: what the app did on the way here — the input and
        # hook lines name a released login, a nudge's outcome, a refused
        # write; kind and text only (the feed carries no secret).
        echo "--- events (last 40)"; "$CTL" events --limit 40 2>/dev/null | python3 -c "import json,sys
for e in json.load(sys.stdin): print(e.get('kind',''), '|', e.get('text',''))" 2>/dev/null | cut -c1-200
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
except Exception: bad=True     # a JSON null is a legitimate reply
if bad or not ($1):
    open('$LOG.reply','w').write(raw[:800]); sys.exit(1)
" && rm -f "$LOG.reply"
}
# idle_cpu_ok <label> <measured pct> <window seconds> — the idle-CPU gate
# (#1133). A window over budget is measured again and passes if the SECOND
# one is under it: one window on a loaded shared runner is not a stable
# estimate (CI read 8.3 % against a budget of 8, on a diff that adds no
# timer), while a real regression idles tens of points over and misses
# both. Never a blind retry of the whole job, which would hide one.
idle_cpu_ok() {
    if python3 -c "import sys; sys.exit(0 if $2 <= $IDLE_BUDGET_PCT else 1)"; then return 0; fi
    echo "$1 ${2}% over budget ${IDLE_BUDGET_PCT}% — taking a second window"
    IDLE_A="$("$CTL" perf | json "d['cpuSeconds']")"
    sleep "$3"
    IDLE_B="$("$CTL" perf | json "d['cpuSeconds']")"
    IDLE_PCT="$(python3 -c "print(round(($IDLE_B-$IDLE_A)/$3*100,1))")"
    echo "$1 (second window): ${IDLE_PCT}%"
    python3 -c "import sys; sys.exit(0 if $IDLE_PCT <= $IDLE_BUDGET_PCT else 1)" \
        || fail "$1 ${2}% then ${IDLE_PCT}% over budget ${IDLE_BUDGET_PCT}%"
}
acct() { echo "[a for a in d['fleet']['accounts'] if a['number']==$1][0]"; }
popout_visible() { "$CTL" windows | expect "any(w['visible'] and w['content']=='GlassContainerView' for w in d)"; }

"$INFINITUS_SWAPD_CLI" reset >/dev/null   # pristine demo fleet: account 1 active, nothing held or aliased

# Worst-case prefs: pop-out restored on launch, RPG theme, ember burn.
defaults write "$DOMAIN" popout_shown -bool true
defaults write "$DOMAIN" popover_pinned -bool false
defaults write "$DOMAIN" gamification_style rpg
defaults write "$DOMAIN" burn_style ember
defaults write "$DOMAIN" mock_mode -bool true   # demo fleet: the swapd engine is $INFINITUS_SWAPD_CLI (the locator honours it)

# --- AWS sign-in fixtures (must exist before launch: env is read at start) --
# A stub `aws` in place of the real CLI: `login --remote --profile P`
# prints the URL and asks for the code the way the CLI does; the magic
# code signs in, profile e2e-rebind hits the "already configured to use
# session" question (answered n → failed, never rebound).
cat >"$SOCKDIR/aws" <<'STUB'
#!/bin/sh
profile=""; remote=""
while [ $# -gt 0 ]; do [ "$1" = "--profile" ] && profile="$2"; [ "$1" = "--remote" ] && remote=1; shift; done
# The orphan fixture (#274): a login that never finishes.
[ "$profile" = "e2e-orphan" ] && exec sleep 3600
# A session's own login (#275): without --remote the real CLI waits on
# a callback listener; any callback ends the wait and it fails on the state.
if [ -z "$remote" ]; then
    # A port nothing holds (#1007): `40000 + $$ % 10000` alone could land
    # on a listener already there, and a listen on a busy port fails at
    # once — the stub then dies before the app can release it, and the
    # nudge never says it was stopped. Kept out of the ephemeral range: on
    # a port from `bind(0)` the released stub lingered 10 s+ (2 of 2 runs,
    # unexplained). A listen that still fails leaves a marker the fail()
    # socket-dir listing shows.
    port=$(python3 -c 'import socket, sys
for p in [int(sys.argv[1])] + list(range(40000, 50000)):
    s = socket.socket()
    try: s.bind(("127.0.0.1", p)); print(p); break
    except OSError: pass
    finally: s.close()' "$((40000 + $$ % 10000))")
    echo "Attempting to open your default browser. If the browser does not open, open the following URL."
    echo "https://e2e.invalid/authorize?profile=$profile&redirect_uri=http://127.0.0.1:$port/oauth/callback"
    # The callback listener answers like the CLI's own server: it reads
    # the whole request before replying and closing. `nc -l` closed with
    # the request unread, and a close over unread bytes is a TCP reset —
    # the app's callback GET then failed after connecting, counted nothing
    # released, and the nudge lacked the clause while the stub had ended
    # (#1007, third sighting: CI 2026-09-12, nudge 3.3 s after the need,
    # stub gone, no release row).
    python3 -c 'import socket, sys  # aws-own-login-listener
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(1)
c, _ = s.accept(); c.settimeout(5); buf = b""
try:
    while b"\r\n\r\n" not in buf:
        chunk = c.recv(4096)
        if not chunk: break
        buf += chunk
except socket.timeout: pass
c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
try: c.shutdown(socket.SHUT_WR)
except OSError: pass
c.close(); s.close()' "$port" \
        || touch "$(dirname "$0")/aws-own-login-nc-failed"
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
# A stub `gcloud` (#367): `auth login --no-launch-browser` prints the
# SDK's paste-back prompt and reads the code.
cat >"$SOCKDIR/gcloud" <<'STUB'
#!/bin/sh
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
"$CTL" status | json "d['engines']['swapd']['registered']" | grep -q True || fail "swapd not registered"
# #1177: the swapd pane's read-only lines ride `status` (binary path, daemon word).
"$CTL" status | expect "d['engines']['swapd']['binaryPath'].endswith('demo-swapd') and d['engines']['swapd']['daemon'] in ('stopped','running','backingOff','refused','schemaMismatch')" || fail "status swapd binary/daemon"
sleep 4   # first demo snapshot
N="$("$CTL" fleets | json "sum(len(f['accounts']) for f in d)")"
[ "$N" -ge 5 ] || fail "expected the demo fleet (>=5 accounts), got $N"
"$CTL" fleets | json "d[0]['key']" | grep -q '^swapd/claude$' || fail "primary fleet key"
"$CTL" remove swapd/claude 1 >/dev/null 2>&1 && fail "remove without --yes must be refused"
"$CTL" switch nope/x 1 >/dev/null 2>&1 && fail "unknown fleet must be refused"
popout_visible || fail "pop-out window not visible (popout_shown restore)"
echo "functional: ok ($N demo accounts, pop-out visible)"

# --- state round-trips through the demo engine ---------------------------
# Each write replies with the refreshed fleet; the change must be in it.
"$CTL" switch swapd/claude 2 | expect "d['fleet']['activeNumber']==2 and $(acct 2)['active']" || fail "switch 2 didn't take"
"$CTL" hold swapd/claude 3 | expect "$(acct 3).get('disabled')==True" || fail "hold 3 didn't take"
"$CTL" unhold swapd/claude 3 | expect "not $(acct 3).get('disabled')" || fail "unhold 3 didn't take"
"$CTL" rename swapd/claude 3 "E2E Alias" | expect "$(acct 3).get('alias')=='E2E Alias'" || fail "rename didn't take"
"$CTL" rename swapd/claude 3 "" | expect "$(acct 3).get('alias')!='E2E Alias'" || fail "rename clear didn't take"   # demo accounts carry default aliases
"$CTL" prefer swapd/claude 2 on | expect "$(acct 2).get('preferred')==True" || fail "prefer 2 didn't take"
"$CTL" prefer swapd/claude 2 off | expect "$(acct 2).get('preferred')==False" || fail "unprefer 2 didn't take"
# #1481: two writes at once queue in arrival order; the second used to be
# refused with "busy: another control command is running".
"$CTL" prefer swapd/claude 2 on >/dev/null & first=$!
"$CTL" hold swapd/claude 3 >/dev/null & second=$!
wait "$first" || fail "a write racing another was refused (prefer)"
wait "$second" || fail "a write racing another was refused (hold)"
"$CTL" fleets | expect "(lambda by: by[2].get('preferred')==True and by[3].get('disabled')==True)({a['number']: a for a in d[0]['accounts']})" \
    || fail "racing writes didn't both land"
"$CTL" prefer swapd/claude 2 off >/dev/null || fail "unprefer 2 after the race"
"$CTL" unhold swapd/claude 3 >/dev/null || fail "unhold 3 after the race"
NEXT="$("$CTL" fleets | json "d[0]['nextCandidate']")"
"$CTL" rotate swapd/claude | expect "d['fleet']['activeNumber']==$NEXT" || fail "rotate didn't land on the next candidate ($NEXT)"
"$CTL" history swapd/claude --limit 5 | expect "d['fleet']=='swapd/claude' and d['history']['schemaVersion']==1 and d['history']['switches'][0]['to']['slot']==2 and d['history']['switches'][0]['trigger']=='at-limit'" || fail "history hands the engine's switch log on"
"$CTL" history swapd/claude --limit 0 >/dev/null 2>&1 && fail "history must refuse --limit 0"
ORDER="$("$CTL" fleets | json "' '.join(str(a['number']) for a in d[0]['accounts'])")"
REV="$(python3 -c "print(' '.join(reversed('$ORDER'.split())))")"
"$CTL" reorder swapd/claude $REV | expect "[a['number'] for a in d['fleet']['accounts']]==[int(x) for x in '$REV'.split()]" || fail "reorder didn't take"
"$CTL" reorder swapd/claude 1 >/dev/null 2>&1 && fail "partial reorder must be refused"
"$CTL" reorder swapd/claude $ORDER | expect "[a['number'] for a in d['fleet']['accounts']]==[int(x) for x in '$ORDER'.split()]" || fail "reorder restore didn't take"
"$CTL" switch swapd/claude 1 | expect "d['fleet']['activeNumber']==1" || fail "switch back to 1"
# Every account gets a distinct themed name in one command.
"$CTL" randomize-names swapd/claude | expect "len(set(a.get('alias') for a in d['fleet']['accounts']))==len(d['fleet']['accounts']) and len(d['names'])==len(d['fleet']['accounts'])" || fail "randomize-names didn't give every account its own name"
# One account re-rolls alone (#145): one name, worn by that account, still distinct from every other.
"$CTL" randomize-names swapd/claude 2 | expect "len(d['names'])==1 and [a for a in d['fleet']['accounts'] if a['number']==2][0].get('alias')==d['names'][0] and len(set(a.get('alias') for a in d['fleet']['accounts']))==len(d['fleet']['accounts'])" || fail "randomize-names <n> didn't re-roll account 2 alone"
echo "round-trips: ok (switch, rotate, hold, unhold, rename, prefer, reorder, randomize-names)"
"$CTL" plan | expect "'plan' in d and (d['plan'] is None or 'steps' in d['plan'])" || fail "plan verb"
"$CTL" ignite swapd/claude 2 | expect "'fleet' in d" || fail "ignite verb"

# --- swapd: the engine's own capabilities --------------------------------
"$CTL" fleets | expect "'refreshAccount' in d[0]['capabilities']" \
    || fail "swapd must advertise refreshAccount"
# The point of the capability: ignite publishes the account it just
# refreshed, so the reply carries the window the run opened (#338) —
# the demo's forced fetch (a fresh 5h clock at 0%), never the one `list`
# was serving before it.
"$CTL" ignite swapd/claude 1 | expect "[a for a in d['fleet']['accounts'] if a['number']==1][0]['usage']['fiveHour']['pct']==0" \
    || fail "ignite didn't publish the refreshed window"
echo "swapd: ignite published the refreshed window"
# #475: an enabled engine runs its own `auto` under the supervisor.
pgrep -f "${INFINITUS_SWAPD_CLI#/private} auto" >/dev/null || fail "swapd auto must run under the supervisor while the engine is on"
"$CTL" events | expect "not any((e.get('summary') or '') in ('poll', 'sleep') for e in (d if isinstance(d, list) else d.get('events', [])))" \
    || fail "the supervisor must drop the poll/sleep heartbeats (#475)"
# #616: the headroom verdict rides `fleets` only while priority_mode is on;
# the demo's active slot (alpha) sits at 5h 37% / 7d 22% / Fable 18%, so 5h binds
# — once a plain `list` replaces the ignite reply above (a fresh 5h at 0%).
"$CTL" refresh >/dev/null || fail "refresh before the headroom checks"
"$CTL" fleets | expect "all('headroom' not in f for f in d)" || fail "headroom must be absent while priority_mode is off"
"$CTL" prefs set priority_mode hold | expect "d['value']=='hold'" || fail "prefs set priority_mode"
"$CTL" fleets | expect "[f for f in d if f['key']=='swapd/claude'][0]['headroom']['state']=='abundant' and [f for f in d if f['key']=='swapd/claude'][0]['headroom']['window']=='5h' and [f for f in d if f['key']=='swapd/claude'][0]['headroom']['pct']==37" \
    || fail "headroom must judge the fullest window abundant at 37%"
"$CTL" prefs set priority_low_pct 15 | expect "d['value']==15" || fail "prefs set priority_low_pct"
"$CTL" fleets | expect "[f for f in d if f['key']=='swapd/claude'][0]['headroom']['state']=='low'" || fail "headroom must go low once 5h is at or above priority_low_pct"
"$CTL" prefs set priority_low_pct 80 | expect "d['value']==80" || fail "prefs set priority_low_pct back"
"$CTL" fleets | expect "[f for f in d if f['key']=='swapd/claude'][0]['headroom']['state']=='abundant'" || fail "headroom must release at 37% under priority_abundant_pct"
"$CTL" prefs set priority_mode off | expect "d['value']=='off'" || fail "prefs set priority_mode off"
# #828: the status item is a pref — off hides it live, the socket keeps answering, on restores it.
"$CTL" prefs set menu_bar_enabled false | expect "d['value'] is False" || fail "prefs set menu_bar_enabled false"
"$CTL" status | expect "d['badge']" || fail "the socket must keep answering with the menu bar off (#828)"
"$CTL" prefs set menu_bar_enabled true | expect "d['value'] is True" || fail "prefs set menu_bar_enabled true"
"$CTL" fleets | expect "all('headroom' not in f for f in d)" || fail "headroom must drop once priority_mode is off"
echo "headroom: absent off, 5h binds, low/abundant follow the thresholds (#616)"
# #743: the interrupt mode says critical where hold says low, same line.
"$CTL" prefs set priority_mode interrupt | expect "d['value']=='interrupt'" || fail "prefs set priority_mode interrupt"
"$CTL" prefs set priority_low_pct 15 | expect "d['value']==15" || fail "prefs set priority_low_pct (interrupt)"
"$CTL" fleets | expect "[f for f in d if f['key']=='swapd/claude'][0]['headroom']['state']=='critical'" || fail "interrupt mode must judge critical at or above priority_low_pct"
"$CTL" prefs set priority_mode hold | expect "d['value']=='hold'" || fail "prefs set priority_mode hold (back)"
"$CTL" fleets | expect "[f for f in d if f['key']=='swapd/claude'][0]['headroom']['state']=='low'" || fail "hold mode must re-read the same verdict as low"
"$CTL" prefs set priority_low_pct 80 | expect "d['value']==80" || fail "prefs set priority_low_pct back (interrupt)"
"$CTL" prefs set priority_mode off | expect "d['value']=='off'" || fail "prefs set priority_mode off (interrupt)"
echo "headroom: interrupt mode says critical, hold re-reads it as low (#743)"
"$CTL" aws-logins | expect "'logins' in d and isinstance(d['logins'], list)" || fail "aws-logins verb"
"$CTL" forecast | expect "'forecast' in d and (d['forecast'] is None or ('basis' in d['forecast'] and 'accounts' in d['forecast']))" || fail "forecast verb"
"$CTL" utilization --days 7 | expect "d['days']==7 and d['bucketSeconds']==1800 and isinstance(d['samples'], list) and d['windows'][:2]==['5h','7d'] and 'switches' in d['replay']" || fail "utilization verb (#747)"
"$CTL" utilization --days 400 >/dev/null 2>&1 && fail "utilization must refuse an out-of-range day count"
"$CTL" stats --period week | expect "d['period']=='week' and 'total' in d and 'commits' in d['total'] and 'humanMessages' in d['total']" || fail "stats verb"

# `show settings` / `hide settings` refuse since the Settings window retired.
"$CTL" show settings >/dev/null 2>&1 && fail "show settings must refuse (retired)"

# The preference catalog (#558): the table with values, and `get` narrowed.
"$CTL" prefs | expect "any(s['slug']=='display' and s['name']=='Display' for s in d['sections']) and any(p['key']=='popup_layout' and p['section']=='display' and p['effect']=='live' for p in d['prefs'])" || fail "prefs"
"$CTL" prefs get popup_layout engine_swapd_enabled | expect "[p['key'] for p in d['prefs']]==['popup_layout','engine_swapd_enabled'] and d['prefs'][1]['effect']=='restart'" || fail "prefs get"
# A key with no window behind it: a layout swap here would re-lay the
# pop-out twice and leave ~45 MB resident before the RSS gate (2026-09-10).
# The demo fleet this run turned on is a catalog pref now (#1177), restart-effect like the engine toggles.
"$CTL" prefs get mock_mode | expect "d['prefs'][0]['value'] is True and d['prefs'][0]['effect']=='restart' and d['prefs'][0]['section']=='engines'" || fail "prefs get mock_mode"
"$CTL" prefs set revive_lead_minutes 15 | expect "d['key']=='revive_lead_minutes' and d['value']==15" || fail "prefs set"
"$CTL" prefs get revive_lead_minutes | expect "d['prefs'][0]['value']==15" || fail "prefs set did not stick"
"$CTL" prefs set refresh_interval 45 >/dev/null 2>&1 && fail "prefs set accepted a value off the choices"
"$CTL" prefs set revive_lead_minutes 10 | expect "d['value']==10" || fail "prefs set back"
# The reply keeps catalog order (themes before animations), not the order asked.
"$CTL" prefs get intro_speed gamification_style | expect "(lambda p: p['intro_speed']['section']=='animations' and p['intro_speed']['min']==0.4 and p['intro_speed']['max']==2 and any(c['id']=='rpg' for c in p['gamification_style']['choices']))({x['key']:x for x in d['prefs']})" || fail "prefs: animations range / theme choices (#747)"
"$CTL" prefs set intro_speed 3 >/dev/null 2>&1 && fail "prefs set accepted a value outside the range"
"$CTL" prefs set intro_style fade | expect "d['value']=='fade'" || fail "prefs set intro_style"
"$CTL" prefs set intro_style top >/dev/null || fail "prefs set intro_style back"
# #777: where the process runs from, and that a standalone one is not nested.
"$CTL" status | expect "isinstance(d['bundlePath'], str) and d['bundlePath'] != '' and d['nested'] is False" || fail "status must carry bundlePath and nested"
# The Cloudflare tunnels retired with Infinitus Connect: no tunnel in the
# status reply, no tunnel prefs, and nothing spawns cloudflared.
"$CTL" status | expect "'forkTunnel' not in d" || fail "status must not carry a tunnel any more"
"$CTL" prefs set fork_tunnel_enabled true >/dev/null 2>&1 && fail "fork_tunnel_enabled must be gone from the catalog"
"$CTL" prefs set fork_server_port 3841 | expect "d['value']==3841 and d['section']=='devices'" || fail "prefs set fork_server_port"
"$CTL" prefs set fork_server_port 3773 >/dev/null || fail "prefs set fork_server_port back"
# #1178: the Devices page's prefs.
"$CTL" prefs set machine_name "E2E Mac" | expect "d['value']=='E2E Mac' and d['section']=='devices'" || fail "prefs set machine_name"
"$CTL" prefs set machine_name "" | expect "d['value']==''" || fail "prefs set machine_name back"
"$CTL" prefs get sync_settings sync_account_names | expect "[p['value'] for p in d['prefs']]==[False, False]" || fail "prefs get sync_settings sync_account_names"
pgrep -P "$APP_PID" -f cloudflared >/dev/null && fail "the e2e instance ran cloudflared"
echo "prefs: ok"

# JSON-body verbs (#572 N1): the socket takes a JSON body on stdin.
"$CTL" client-activity --body '{"clientId":"e2e","visible":true,"focused":true,"recentlyInteracted":true,"scopes":[{"type":"fleets"}],"ttlMs":5000}' | expect "d['clientId']=='e2e'" || fail "client-activity"
"$CTL" perf | expect "d['leaseScopes'].get('e2e')==['fleets']" || fail "perf must name the lease e2e just took (#499)"
"$CTL" perf | expect "'stats' not in d['leaseScopes'].get('local', [])" || fail "the local client must not hold stats without the Stats pane (#499)"
# #1177: the fork's "Test connection" against a port nothing serves — a
# dev Mac's keychain may hold a real key (CI's never does), so the words
# differ but the verdict and the shape do not; a bad target is a usage
# error; the reply never fails the verb itself.
"$CTL" test-connection cliproxy --url http://127.0.0.1:9 | expect "d['ok'] is False and isinstance(d['error'], str) and d['error'] and 'latencyMs' not in d" || fail "test-connection cliproxy against a dead port"
"$CTL" test-connection 9router --url http://127.0.0.1:9 | expect "d['ok'] is False and isinstance(d['error'], str) and d['error']" || fail "test-connection 9router against a dead port"
"$CTL" test-connection swapd >/dev/null 2>&1 && fail "test-connection must refuse an unknown engine"
# #1375: the thread card left the push verb with the Mac's APNs key; a
# stray shape is still refused, never pushed.
printf '{"kind":"thread.activity","state":null}' | "$CTL" push 2>&1 | grep -q "thread.phase" || fail "push refuses a stray shape"
# #835: a body verb given --body must not wait on a stdin pipe nobody
# closes (a fifo opened read-write never reaches EOF).
mkfifo "$SOCKDIR/hold.fifo"; exec 7<>"$SOCKDIR/hold.fifo"
"$CTL" client-activity --body '{"clientId":"e2e-hold","visible":true,"focused":false,"recentlyInteracted":false,"scopes":[{"type":"fleets"}],"ttlMs":5000}' <&7 >"$LOG.hold" 2>&1 &
HOLD_PID=$!
i=0; while /bin/kill -0 "$HOLD_PID" 2>/dev/null; do
    i=$((i + 1)); [ "$i" -lt 100 ] || { kill "$HOLD_PID" 2>/dev/null; fail "client-activity --body waited on stdin (#835)"; }
    sleep 0.1
done
exec 7>&-
expect "d['clientId']=='e2e-hold'" <"$LOG.hold" || fail "client-activity --body with an open stdin"
echo '{"id":"e2e-crash","platform":"ios","device":"e2e","appVersion":"0","osVersion":"0","at":"2026-09-10T00:00:00Z","kind":"crash","reason":"e2e","frames":[]}' | "$CTL" crash-report | expect "d['id']=='e2e-crash'" || fail "crash-report (stdin body)"
"$CTL" crashes | expect "any(c['id']=='e2e-crash' and c['appVersion']=='0' and 'transcript' not in c for c in d['crashes'])" || fail "crash-report not listed by crashes"
# `--id` is the desktop's Copy: that one report, with the transcript.
"$CTL" crashes --id e2e-crash | expect "len(d['crashes'])==1 and d['crashes'][0]['id']=='e2e-crash' and 'reason: e2e' in d['crashes'][0]['transcript']" || fail "crashes --id must answer the one report with its transcript"
"$CTL" crashes --id nope | expect "d['crashes']==[]" || fail "crashes --id must answer nothing for an unknown id"
# The #677 sign-in verbs are wired (the flow itself needs a human and the Claude CLI): a
# flow nobody started is refused by id, and a fleet that does not exist by name.
"$CTL" signin-status nope 2>&1 | grep -q "no sign-in nope" || fail "signin-status did not refuse an unknown flow"
"$CTL" signin-begin no/such 2>&1 | grep -q "usage: signin-begin" || fail "signin-begin did not refuse an unknown fleet"
"$CTL" crash-report --body '{nope' >/dev/null 2>&1 && fail "crash-report accepted a broken body"
echo "body verbs: ok"

# --- scenarios: all-dead (no candidate, then recovers) -------------------
"$INFINITUS_SWAPD_CLI" simulate alldead >/dev/null
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
idle_cpu_ok "all-dead CPU" "$RPCT" 12
"$INFINITUS_SWAPD_CLI" simulate off >/dev/null
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

# --- AWS sign-in, started by the verb (#1041: no more transcript scan) ----
aws_login_item() { "$CTL" aws-logins | expect "any(l['profile']=='e2e-login' and not l.get('provider') for l in d['logins'])"; }
aws_phase() { "$CTL" aws-logins | json "next((l.get('state') or {}).get('phase') for l in d['logins'] if l['profile']=='$1' and not l.get('provider'))"; }
aws_login_item && fail "aws-logins must be empty before any login starts"
# The phone's flag-less poll reports and never starts (it re-opened the
# sign-in on every poll, 2026-09-03).
"$CTL" aws-login e2e-login --status >/dev/null 2>&1 && fail "--status started a login"
"$CTL" aws-logins | expect "all(l.get('state') is None for l in d['logins'])" || fail "--status left a login in flight"
# Code flow: URL for the phone's browser, then the pasted code.
"$CTL" aws-login e2e-login --remote | expect "d['state']['flow']=='remote'" || fail "aws-login --remote"
aws_login_item || fail "aws-login did not surface the run in aws-logins"
i=0
until [ "$(aws_phase e2e-login)" = "waitingForCode" ]; do
    i=$((i + 1)); [ "$i" -lt 20 ] || fail "login never asked for the code (phase $(aws_phase e2e-login))"
    sleep 1
done
"$CTL" aws-logins | expect "next(l['state']['url'] for l in d['logins'] if l['profile']=='e2e-login').startswith('https://e2e.invalid/')" || fail "no URL for the phone"
"$CTL" aws-login e2e-login --status | expect "d['state']['phase']=='waitingForCode'" || fail "--status did not report the login in flight"
printf 'E2E-CODE-OK' | "$CTL" aws-login-code e2e-login >/dev/null || fail "aws-login-code"
i=0
while aws_login_item; do
    i=$((i + 1)); [ "$i" -lt 20 ] || fail "login did not clear after signing in (phase $(aws_phase e2e-login))"
    sleep 1
done
pgrep -f "$SOCKDIR/aws" >/dev/null && fail "stub aws CLI still running"
echo "aws: code flow signed in from the verb, no --pid"

# --- gcloud sign-in, started by the verb (#367) ----------------------------
gcloud_login_item() { "$CTL" aws-logins | expect "any(l['profile']=='e2e@example.com' and l.get('provider')=='gcloud' for l in d['logins'])"; }
gcloud_phase() { "$CTL" aws-logins | json "next((l.get('state') or {}).get('phase') for l in d['logins'] if l['profile']=='e2e@example.com' and l.get('provider')=='gcloud')"; }
gcloud_login_item && fail "aws-logins must not already carry a gcloud login"
"$CTL" gcloud-login e2e@example.com --remote | expect "d['state']['flow']=='remote' and d['state']['provider']=='gcloud'" || fail "gcloud-login --remote"
gcloud_login_item || fail "gcloud-login did not surface the run in aws-logins"
i=0
until [ "$(gcloud_phase)" = "waitingForCode" ]; do
    i=$((i + 1)); [ "$i" -lt 20 ] || fail "gcloud login never asked for the code (phase $(gcloud_phase))"
    sleep 1
done
"$CTL" aws-logins | expect "next(l['state']['url'] for l in d['logins'] if l.get('provider')=='gcloud').startswith('https://e2e.invalid/')" || fail "no gcloud URL for the phone"
printf 'E2E-GCLOUD-OK' | "$CTL" gcloud-login-code e2e@example.com >/dev/null || fail "gcloud-login-code"
i=0
while gcloud_login_item; do
    i=$((i + 1)); [ "$i" -lt 20 ] || fail "gcloud login did not clear after signing in (phase $(gcloud_phase))"
    sleep 1
done
echo "gcloud: code flow signed in from the verb, no --pid"

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

# --- team (#1313) ----------------------------------------------------------
# The app creates a team on a bare repo; a second identity — the CLI
# in-process, its own INFINITUS_TEAM_DIR — joins with a team code and
# publishes; the app approves and reads it back. No desktop answers here,
# so the publish carries stats and now, and the index stays empty.
"$CTL" team-status | expect "d is None" || fail "team-status must be null before a team exists"
git init -q --bare "$SOCKDIR/team.git"
git -C "$SOCKDIR/team.git" config uploadpack.allowFilter true
"$CTL" team-create Papaya --remote "file://$SOCKDIR/team.git" --as Ann \
    | expect "d['role']=='leader' and d['members'][0]['name']=='Ann' and d['members'][0]['founder'] and 'lockEnabled' not in d" || fail "team-create"
# The lock never touches Team (ruling 2026-09-16): the app mints and approves outright.
CODE="$("$CTL" team-code --days 1 | json "d['code']")"
case "$CODE" in infinitus://join/*) ;; *) fail "team-code shape" ;; esac
CLI_TEAM="$SOCKDIR/team-cli"
printf '%s' "$CODE" | INFINITUS_TEAM_DIR="$CLI_TEAM" "$CTL" team request - --name Bo >/dev/null || fail "cli team request"
KID="$(INFINITUS_TEAM_DIR="$CLI_TEAM" "$CTL" team status | json "d['kid']")"
"$CTL" team-fetch | expect "len(d['requests'])==1 and d['requests'][0]['name']=='Bo'" || fail "the request did not reach the leader"
"$CTL" team-approve "$KID" | expect "any(m['name']=='Bo' and m['role']=='member' for m in d['members'])" || fail "team-approve"
"$CTL" team-fetch | expect "any(m['name']=='Bo' and m['role']=='member' for m in d['members']) and not d['requests']" || fail "the approval did not reach the app"
INFINITUS_TEAM_DIR="$CLI_TEAM" "$CTL" team fetch >/dev/null || fail "cli team fetch"
# #354: on a Mac with the app up and no INFINITUS_TEAM_DIR, `team status` is
# the app's own view, and a subcommand the app has no verb for either refuses
# to mint a second identity or says whose identity it is using.
env -u INFINITUS_TEAM_DIR "$CTL" team status | expect "d['role']=='leader' and d['name']=='Papaya'" || fail "cli team status did not route to the app"
env -u INFINITUS_TEAM_DIR "$CTL" team identity show 2>&1 | grep -q "owns this Mac's team identity\|infinitusctl's own identity" || fail "cli team identity neither refused nor named its own identity beside the app's"
INFINITUS_TEAM_DIR="$CLI_TEAM" "$CTL" team publish | expect "'published' in d" || fail "cli team publish"
INFINITUS_TEAM_DIR="$CLI_TEAM" "$CTL" team share transcripts off \
    | expect "d['byKind']['transcripts']=='off'" || fail "team share transcripts off"
# `now` is the one kind every publish carries; stats need a transcript corpus the CI runner has none of.
"$CTL" team-fetch | expect "any(m['name']=='Bo' and 'now' in m['kinds'] for m in d['members'])" || fail "the member's files are not readable"
"$CTL" team-publish | expect "'published' in d" || fail "team-publish"
"$CTL" team-status | expect "d.get('lastPublish') is not None and d.get('lastError') is None" || fail "loop state after publish"
"$CTL" team-share now team | expect "d['shares']['now']=='team'" || fail "team-share"
"$CTL" team-exclude add secret-repo | expect "'secret-repo' in d['exclusions']" || fail "team-exclude add"
"$CTL" team-exclude remove secret-repo | expect "'secret-repo' not in d['exclusions']" || fail "team-exclude remove"
"$CTL" team-policy requests off | expect "d['policy']['requests']=='off'" || fail "team-policy"
"$CTL" team-insights --period week | expect "d['period']=='week' and isinstance(d['blockers'], list)" || fail "team-insights"
"$CTL" team-identity | expect "len(d['kid'])>8" || fail "team-identity"
echo "team: ok (leader Ann, member Bo $KID)"
# #747: the secret-carrying team verbs refuse an empty stdin by name.
"$CTL" team-join Cy </dev/null 2>&1 | grep -q "needs the team code" || fail "team-join must ask for the code on stdin"
"$CTL" team-leave 2>&1 | grep -q -- "--yes" || fail "team-leave must want --yes"

# #822: the desktop verbs against a demo desktop (tools/demo-desktop): the
# credential comes on stdin like every secret and stays in this run's own
# keychain slot, the CLI reads it back over the socket and talks HTTP.
DESK_PORT=$((50000 + $$ % 10000)); DESK_TOKEN="e2e-desktop-token-$$"
python3 tools/demo-desktop "$DESK_PORT" "$DESK_TOKEN" &
DESK_PID=$!
desk_get() { python3 -c "import json,sys,urllib.request; r=urllib.request.Request('http://127.0.0.1:$DESK_PORT$1', headers={'Authorization':'Bearer $DESK_TOKEN'}); print(urllib.request.urlopen(r, timeout=3).read().decode())"; }
i=0; until desk_get /.well-known/t3/environment >/dev/null 2>&1; do i=$((i + 1)); [ "$i" -lt 50 ] || fail "the demo desktop did not come up"; sleep 0.1; done
"$CTL" environments </dev/null 2>&1 | grep -q "no Infinitus desktop credential" || fail "environments must want a credential first"
"$CTL" desktop status </dev/null | expect "d['credential'] is None and d['reachable'] is False and d['port']==3773" || fail "desktop status without a credential"
printf 'x' | "$CTL" desktop-credential --origin nope 2>&1 | grep -q "http(s) URL" || fail "desktop-credential must want an http origin"
printf '%s' "$DESK_TOKEN" | "$CTL" desktop-credential --origin "http://127.0.0.1:$DESK_PORT" --expiresAt 2099-01-01T00:00:00Z \
    | expect "d['stored'] is True and d['origin']=='http://127.0.0.1:$DESK_PORT' and d['expiresAt']=='2099-01-01T00:00:00Z'" || fail "desktop-credential store"
"$CTL" desktop-status | expect "d['credential']=='…'+'$DESK_TOKEN'[-4:] and d['stale'] is True" || fail "desktop-status must mask the credential and flag the moved port"
"$CTL" desktop status | expect "d['reachable'] is True and d['version']=='0.0.0-demo'" || fail "desktop status reachable"
"$CTL" desktop status | grep -q "$DESK_TOKEN" && fail "desktop status must never print the token"
"$CTL" desktop credential | expect "d['stored'] is True and d['accepted'] is True and d['label'].startswith('…')" || fail "desktop credential accepted"
"$CTL" environments | expect "d[0]['id']=='env-demo' and d[0]['status']=='reachable' and d[0]['origin']=='http://127.0.0.1:$DESK_PORT' and d[0]['platform']=='darwin'" || fail "environments"
"$CTL" projects | expect "d[0]['id']=='p-demo' and d[0]['name']=='Demo project' and d[0]['env']=='env-demo'" || fail "projects"
"$CTL" threads | expect "[t['id'] for t in d]==['t-running','t-idle'] and d[0]['status']=='running' and d[1]['status']=='held' and d[1]['hold']['summary']=='at limit until 09:00' and d[0]['project']=='Demo project'" || fail "threads"
"$CTL" threads --status held | expect "len(d)==1 and d[0]['id']=='t-idle'" || fail "threads --status held"
"$CTL" threads --status bogus 2>&1 | grep -q "usage: threads --status" || fail "threads must refuse an unknown status"
"$CTL" thread show t-idle --turns 1 | expect "d['thread']['status']=='held' and [m['text'] for m in d['messages']]==['hello','hi there']" || fail "thread show"
"$CTL" thread show t-none 2>&1 | grep -q "no thread t-none" || fail "thread show must name a missing thread"
"$CTL" thread send t-running "more" 2>&1 | grep -q "turn running; --steer" || fail "send on a running thread must refuse without --steer"
"$CTL" thread send t-idle "more" 2>&1 | grep -q "turn running; --steer" || fail "send on a held thread must refuse without --steer"
"$CTL" thread send t-running "more" --steer | expect "d['steered'] is True and len(d['messageId'])==36" || fail "thread send --steer"
"$CTL" thread release t-idle | expect "d['released'] is True" || fail "thread release"
"$CTL" thread release t-idle | expect "d['released'] is False and d['reason']=='not held'" || fail "a second release reports the reason"
printf 'ping\n' | "$CTL" thread send t-idle - --wait | expect "d['text']=='echo: ping' and d['turn']['state']=='completed'" || fail "thread send --wait"
"$CTL" thread new --project "Demo project" "Fix the build" --worktree fix/build 2>&1 | grep -q "pass --base" || fail "thread new --worktree must want a base when the project dir is not a repo"
"$CTL" thread new --project "Demo project" "Fix the build" --worktree fix/build --base main --wait | expect "d['text']=='echo: Fix the build' and len(d['threadId'])==36" || fail "thread new --wait"
"$CTL" threads --project p-demo | expect "any(t['title']=='Fix the build' and t['branch']=='fix/build' and t['worktree']=='/tmp/demo-project/.wt/'+t['id'] for t in d)" || fail "the new thread shows its worktree"
"$CTL" thread new --project nope "x" 2>&1 | grep -q "no project nope" || fail "thread new must name a missing project"
"$CTL" thread interrupt t-running | expect "d['ok'] is True and d['turnId']=='u-1'" || fail "thread interrupt"
"$CTL" threads --status running | expect "d==[]" || fail "the interrupted thread is no longer running"
desk_get /api/demo/dispatches | expect "[c['type'] for c in d]==['thread.turn.start','thread.turn.start','thread.turn.start','thread.turn.interrupt'] and d[0]['runtimeMode']=='full-access' and d[0]['message']['role']=='user' and d[0]['message']['attachments']==[] and d[1]['runtimeMode']=='approval-required' and d[2]['bootstrap']['createThread']['projectId']=='p-demo' and d[2]['bootstrap']['createThread']['modelSelection']=={'provider':'claude','model':'opus'} and d[2]['bootstrap']['prepareWorktree']['branch']=='fix/build' and d[2]['bootstrap']['prepareWorktree']['projectCwd']=='/tmp/demo-project' and d[2]['bootstrap']['prepareWorktree']['baseBranch']=='main' and d[2]['titleSeed']=='Fix the build' and d[3]['turnId']=='u-1'" || fail "the dispatched commands must carry the desktop's shapes"
"$CTL" thread new --project "Bare project" "No default here" --wait | expect "d['text']=='echo: No default here'" || fail "thread new must fall back to the environment's default model (#1315)"
"$CTL" thread new --project "Bare project" "Pick one" --model codex/gpt-5 --wait | expect "d['text']=='echo: Pick one'" || fail "thread new --model instance/model"
"$CTL" thread new --project "Demo project" "Bare model" --model haiku --wait | expect "d['text']=='echo: Bare model'" || fail "thread new --model model"
"$CTL" thread new --project "Bare project" "x" --model /haiku 2>&1 | grep -q "wants <instanceId>/<model>" || fail "thread new must refuse a malformed --model"
desk_get /api/demo/dispatches | expect "[c['bootstrap']['createThread']['modelSelection'] for c in d[4:7]]==[{'instanceId':'claude','model':'sonnet'},{'instanceId':'codex','model':'gpt-5'},{'instanceId':'claude','model':'haiku'}]" || fail "the new threads must carry the environment default, the explicit instance/model and the project's instance with the bare model"
# #1313 spec §8, delegated control over the store lane: Ann (the app) grants
# Bo (the CLI identity) send, view and new; Bo drives from his own team dir.
# Ann's now.json predates the grant and carries no endpoints (and the app's
# own httpBaseUrl is loopback, which a driver skips anyway), so the command
# rides the store; the app's next fetch executes it against the demo desktop
# and answers a sealed ack Bo reaps with `team acks`.
ANN_KID="$("$CTL" team-identity | json "d['kid']")"
"$CTL" team-grant "$KID" --cap send,view,new | expect "d['audience']==['$KID'] and d['threads']=='all' and sorted(d['capabilities'])==['new','send','view'] and 'preauthorized' not in d" || fail "team-grant"
"$CTL" team-grants | expect "len(d['grants'])==1" || fail "team-grants"
DRIVE="$(INFINITUS_TEAM_DIR="$CLI_TEAM" "$CTL" team drive "$ANN_KID" t-idle send "hello from Bo via the store")"
printf '%s' "$DRIVE" | expect "d['lane']=='store' and d['outcome']=='queued'" || fail "team drive send must queue on the store (got $DRIVE)"
SEND_ID="$(printf '%s' "$DRIVE" | json "d['id']")"
"$CTL" team-fetch | expect "d['role']=='leader'" || fail "team-fetch after a queued command"
desk_get /api/orchestration/threads/t-idle | expect "any(m.get('role')=='user' and 'hello from Bo via the store' in json.dumps(m) for m in d['messages'])" || fail "the store-lane send did not reach the desktop thread"
INFINITUS_TEAM_DIR="$CLI_TEAM" "$CTL" team acks | expect "any(a['id']=='$SEND_ID' and a['outcome']=='delivered' and a['from']=='$ANN_KID' for a in d)" || fail "team acks after send"
NEW_ID="$(INFINITUS_TEAM_DIR="$CLI_TEAM" "$CTL" team drive "$ANN_KID" - new "Fix the tests" --project "Demo project" | json "d['id'] if d['lane']=='store' and d['outcome']=='queued' else ''")"
[ -n "$NEW_ID" ] || fail "team drive new must queue"
"$CTL" team-fetch >/dev/null || fail "team-fetch after a queued new"
PENDING_ID="$("$CTL" team-pending | json "d[0]['id']")"
"$CTL" team-pending | expect "len(d)==1 and d[0]['name']=='Bo' and d[0]['action']=='new' and d[0]['project']=='Demo project' and d[0]['text']=='Fix the tests'" || fail "team-pending must list the new command waiting for a tap"
"$CTL" team-allow "$PENDING_ID" | expect "d['outcome']=='done' and len(d['detail'])==36" || fail "team-allow must start the thread"
"$CTL" team-pending | expect "d==[]" || fail "an allowed command leaves the wait list"
"$CTL" threads --project p-demo | expect "any(t['title']=='Fix the tests' for t in d)" || fail "the allowed new thread must exist on the desktop"
"$CTL" team-fetch >/dev/null || fail "team-fetch to push the ack"
INFINITUS_TEAM_DIR="$CLI_TEAM" "$CTL" team acks | expect "any(a['id']=='$NEW_ID' and a['outcome']=='done' and len(a['detail'])==36 for a in d)" || fail "team acks after allow"
VIEW_ID="$(INFINITUS_TEAM_DIR="$CLI_TEAM" "$CTL" team drive "$ANN_KID" t-idle view | json "d['id'] if d['lane']=='store' and d['outcome']=='queued' else ''")"
[ -n "$VIEW_ID" ] || fail "team drive view must queue"
"$CTL" team-fetch >/dev/null || fail "team-fetch after a queued view"
INFINITUS_TEAM_DIR="$CLI_TEAM" "$CTL" team acks | expect "any(a['id']=='$VIEW_ID' and a['outcome']=='done' and 'echo: hello from Bo via the store' in a['detail'] for a in d)" || fail "team acks after view must carry the thread's transcript"
"$CTL" team-fetch | expect "any(m['name']=='Bo' and m.get('controls') is None for m in d['members']) and len(d['grants'])==1 and d.get('pending') is None" || fail "team-status must carry the grant and no waits"
GRANT_ID="$("$CTL" team-grants | json "d['grants'][0]['id']")"
"$CTL" team-revoke "$GRANT_ID" | expect "d['removed'] is True" || fail "team-revoke"
LATE_ID="$(INFINITUS_TEAM_DIR="$CLI_TEAM" "$CTL" team drive "$ANN_KID" t-idle send "after the revoke" | json "d['id'] if d['outcome']=='queued' else ''")"
[ -n "$LATE_ID" ] || fail "team drive after revoke must still queue"
"$CTL" team-fetch >/dev/null || fail "team-fetch after the revoke"
INFINITUS_TEAM_DIR="$CLI_TEAM" "$CTL" team acks | expect "any(a['id']=='$LATE_ID' and a['outcome']=='noGrant' for a in d)" || fail "a revoked grant must answer noGrant"
echo "team control: ok"
printf 'wrong' | "$CTL" desktop-credential --origin "http://127.0.0.1:$DESK_PORT" >/dev/null || fail "desktop-credential replace"
rc=0; "$CTL" threads >"$LOG.desk" 2>&1 || rc=$?
[ "$rc" -eq 2 ] && grep -q "no longer accepts this credential" "$LOG.desk" || fail "a revoked credential must exit 2 with the relaunch hint (got $rc: $(head -c 200 "$LOG.desk"))"
"$CTL" desktop credential | expect "d['stored'] is True and d['accepted'] is False" || fail "desktop credential must report the refusal"
"$CTL" desktop-credential </dev/null | expect "d['stored'] is False and d['origin'] is None" || fail "desktop-credential with empty stdin forgets"
"$CTL" desktop status | expect "d['credential'] is None and d['reachable'] is False" || fail "desktop status after forget"
kill "$DESK_PID" 2>/dev/null || true
echo "desktop verbs: ok"


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
idle_cpu_ok "idle CPU" "$PCT" "$WINDOW_S"
# An RSS failure prints where the pages are (#1204): IOSurface / CoreAnimation
# regions say "screen-sized layers", MALLOC says "heap" — the next one is
# diagnosable from the log alone. Diagnostic only; the budget is unchanged.
[ "$RSS" -le "$RSS_BUDGET_MB" ] || {
    echo "--- vmmap --summary $APP_PID"; vmmap --summary "$APP_PID" 2>/dev/null | sed -n '/REGION TYPE/,/TOTAL/p' | head -60
    fail "RSS ${RSS} MB over budget ${RSS_BUDGET_MB} MB"
}
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
idle_cpu_ok "idle CPU with no lease" "$PCT" "$WINDOW_S"
"$CTL" show popout >/dev/null || fail "show popout (restore)"
popout_visible || fail "pop-out not restored after the no-lease window"
# #654: the fork's quit-with-window setting sends `quit`; the app answers,
# then leaves on its own — the wait below is bounded, and the time is printed.
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
pgrep -f "${INFINITUS_SWAPD_CLI#/private} auto" >/dev/null && fail "swapd auto outlived the app (#475)"
echo "quit: ok (exited after $((i / 10)).$((i % 10))s)"
echo "E2E PASS"
