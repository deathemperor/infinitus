# `tools/t3ref` — T3 Code reference capture and parity harness

Sub-projects B (the Mac window) and C (the phone) prove pixel parity
against the real T3 Code clients with these scripts. A screen passes when
**≤ 1.5 % of its pixels differ by more than ΔE 6**, glyph antialiasing
masked out (spec §3.6). The harness only reports — CI does not gate on it
(the reference app is not on CI machines); the numbers go in the PR
description.

Reference versions (spec §0):

| Surface | Reference | Version | Size |
|---|---|---|---|
| Mac | `/Applications/T3 Code (Alpha).app` | 0.0.38 (`com.t3tools.t3code`) | window-sized, `screencapture -l` |
| iOS | `apps/mobile` dev client from `~/death/t3code` | `v0.0.39-10-gacc0a219e` | iPhone 17 Pro, 1206×2622 |

## The pieces

| File | What it does |
|---|---|
| `compare.py` | `compare.py a.png b.png [--out diff.png] [--threshold 1.5]` — pure-stdlib PNG decode, per-pixel CIE ΔE76, 1-px dilated luminance-edge mask. Prints `over: 0.83% max ΔE 41.2`, exits 1 above the threshold. |
| `fixture.sh` | A fake `CLAUDE_CONFIG_DIR` holding the parity fixture, plus the debug app on it. `fixture.sh --stop` tears it down. |
| `winlist.swift` | `winlist <owner-substring> [title-substring\|WxH]` → `id width height` of that app's first matching normal-layer window. The filter picks the workspace out of an Infinitus that also has the pop-out open; `WxH` matches the bounds exactly (`kCGWindowName` is empty without Screen Recording permission). |
| `capture-mac.sh` | `capture-mac.sh <sidebar\|thread\|composer> <out.png>` — screenshots the running T3 Code window. |
| `capture-ios.sh` | `capture-ios.sh <screen> <out.png>` — deep-links the T3 dev client in the booted simulator and screenshots it. |
| `capture-ours.sh` | `capture-ours.sh <mac\|ios> <screen> <out.png>` — the same screen in Infinitus. |
| `compare-harness.sh` | `compare-harness.sh <thread\|home> [shots-dir]` — the phone's number from the render harness's `parity-*` shots (InfinitusMobile tests) against `refs/ios-<screen>.png`, the status bar masked. No fixture app or pairing needed. |
| `refs/` | The committed reference PNGs B and C diff against. |

`compare.py` is pure Python 3 stdlib on purpose (no wheels on a fresh
Mac). The decode is O(pixels) in Python: about 20 s for one 1206×2622
frame, ~50 s for a `compare` of two. Acceptable for a harness.

```
$ python3 tools/t3ref/compare.py --selftest
selftest ok
```

`winlist` compiles itself into `tools/t3ref/.build/` on first use
(git-ignored). `screencapture -l` needs Screen Recording permission for
the terminal that runs it; without it the frame comes out blank.

## The fixture

Real thread text, timestamps and the DEV badge differ between the two
apps, so parity is measured against a **fixture**: one Infinitus session
and one T3 thread with the same title `Hi`, the same two messages, and
the same project name `limitless`.

The Infinitus side is `fixture.sh`. It writes a `CLAUDE_CONFIG_DIR` the
way `tools/e2e.sh` does — a `sessions/<pid>.json` with status `waiting`,
a `projects/<slug>/t3fix-hi.jsonl` with the "Hi" pair, an
`AskUserQuestion` with two questions and an **open** `Write` tool_use —
then launches the debug app on it. `SessionTimelineBuilder` turns those
into the two activity kinds every T3 thread screen needs:
`user-input.requested` (the question) and `approval.requested` (the open
`Write` under status `waiting`, `finish(status:)`).

Everything the app could otherwise reach into is redirected under
`/tmp/t3fix`: the Claude config dir, the profiles list, the team dir and
the engine (`tools/demo-cswap` — fabricated fleet, no credentials, no
network). The control socket is `/tmp/t3fix.sock`, **never** the real
app's — running a debug instance without that would unlink the real
socket and break `infinitusctl` and the phone until the bundle relaunches.

```
$ tools/t3ref/fixture.sh
fixture pid=50008 session=t3fix-hi cwd=/tmp/t3fix/proj/limitless
app on /tmp/t3fix.sock (log /tmp/t3fix.log)
```

Verify the session (give the app ~5 s to come up):

```
$ INFINITUS_CONTROL_SOCKET=/tmp/t3fix.sock .build/debug/infinitusctl sessions
[
  {
    "cwd" : "/tmp/t3fix/proj/limitless",
    "kind" : "interactive",
    "name" : "Hi",
    "permissionMode" : null,
    "pid" : 50008,
    "profile" : null,
    "status" : "waiting"
  }
]
```

Verify the timeline over the mirror. The real app usually holds the
default port 47824, so the fixture instance takes an ephemeral one — read
it off the process, and the pairing token out of the debug binary's
defaults domain (`Infinitus`, not `run.infinitus`). Neither is ever
printed here; the token stays inside the command substitution.

```
$ APP=$(cat /tmp/t3fix/app.pid)
$ PORT=$(lsof -nP -iTCP -sTCP:LISTEN -a -p "$APP" | awk 'NR>1{split($9,a,":"); print a[2]; exit}')
$ PID=$(cat /tmp/t3fix/pid)
$ curl -s -H "Authorization: Bearer $(defaults read Infinitus mirror_pair_token)" \
      "http://127.0.0.1:$PORT/sessions/$PID/timeline" | jq '.snapshot.timeline.activities[].kind'
"user-input.requested"
"tool.started"
"approval.requested"
```

(The route answers a `TimelineSync`, so the activities live under
`.snapshot.timeline`, not `.timeline`.)

Tear it down when you are done — no debug app may be left running:

```
$ tools/t3ref/fixture.sh --stop
fixture stopped
```

## Capturing the T3 references

### Mac

T3 Code must be open on the fixture thread. The desktop registers the
`t3code` scheme (`apps/desktop` `protocol`) with routes mirroring the web
router (`/:environmentId/:threadId`), so exporting `T3_ENV_ID` and
`T3_THREAD_ID` routes it; without them the script only raises the window
and captures whatever is on screen.

```
$ export T3_ENV_ID=$(cat ~/.t3/userdata/environment-id)
$ export T3_THREAD_ID=$(sqlite3 ~/.t3/userdata/state.sqlite \
      "select thread_id from projection_threads where title = 'Hi'")
$ tools/t3ref/capture-mac.sh thread tools/t3ref/refs/mac-thread.png
```

Nothing is committed under `refs/mac-*.png` yet: the `Hi` thread is gone
from the desktop, so the window can only be shot on the user's live work.
Recreate the fixture thread in T3 Code first — see `refs/PROVENANCE.md`.

### iOS

The dev client recipe (spec §0), already run once on this Mac — the app
`com.t3tools.t3code.dev` is installed on the *iPhone 17 Pro* simulator,
so a rebuild is only needed if it is gone:

```
$ cd ~/death/t3code/apps/mobile
$ APP_VARIANT=development EXPO_NO_GIT_STATUS=1 pnpm exec expo prebuild --clean --platform ios
$ pnpm exec expo run:ios --device "iPhone 17 Pro"
```

Then, per capture session:

```
$ xcrun simctl boot "iPhone 17 Pro"; open -a Simulator
$ cd ~/death/t3code/apps/mobile && pnpm exec expo start --dev-client --scheme t3code-dev --lan --port 8081 &
$ xcrun simctl openurl booted "t3code-dev://expo-development-client/?url=http%3A%2F%2Flocalhost%3A8081"
# pair it to the desktop server once:
$ cd ~/death/t3code/apps/server && node src/bin.ts pair
$ xcrun simctl openurl booted "t3code-dev://connections/new?autoConnect=1&pairingUrl=<url-encoded>"
```

Every screen is a deep link (`apps/mobile/src/Stack.tsx` `linking:`), so
the harness never taps:

```
$ export T3_ENV_ID=… T3_THREAD_ID=…
$ tools/t3ref/capture-ios.sh thread   tools/t3ref/refs/ios-thread.png
$ tools/t3ref/capture-ios.sh home     tools/t3ref/refs/ios-home.png
$ tools/t3ref/capture-ios.sh newtask  tools/t3ref/refs/ios-newtask.png
$ tools/t3ref/capture-ios.sh git      tools/t3ref/refs/ios-git.png
$ tools/t3ref/capture-ios.sh settings tools/t3ref/refs/ios-settings.png
```

The script's `sleep 9` is a warm-app number: 3 s of settle for the route
transition (`openurl` returns before the navigation starts) plus the 6 s
render wait. A cold dev client has to
pull the bundle from Metro first — open the `expo-development-client` URL
and give it ~25 s before the first deep link.

Screens: `home`, `thread`, `git`, `review`, `files`, `terminal`,
`newtask`, `settings`. Only the thread-scoped five need
`T3_ENV_ID`/`T3_THREAD_ID`. `home` is the odd one: `t3code-dev://` with
an empty route hands off to whichever app answered the scheme last, so
the script relaunches the client instead and waits `T3_LAUNCH_WAIT`
(default 25 s) for its bundle.

The simulator is shut down by the repo's `SubagentStop`/`Stop` hook
(`tools/sim-teardown.sh`) whenever no `simctl`/`xcodebuild` is running —
so an agent must do boot, launch and capture inside **one** shell
invocation, or the device is gone by the next one.

## Comparing

`capture-ours.sh` takes the same screen out of Infinitus. The Mac route
landed with sub-project B — `infinitusctl show workspace
<sidebar|thread|composer|draft|switcher>`, next to `show wall`, on the
fixture's socket — and raises the workspace to the front, but the window
list is not ordered front-to-back within an app, so the open pop-out was
being captured instead (#442): the script now asks `winlist` for the
window whose bounds are the preset workspace frame. The phone's
`infinitus://t3/<screen>` is still to come with C, so `capture-ours.sh
ios …` prints `not yet` and exits 4.

```
$ tools/t3ref/capture-ours.sh ios thread /tmp/ours-thread.png
$ python3 tools/t3ref/compare.py tools/t3ref/refs/ios-thread.png /tmp/ours-thread.png --out /tmp/diff.png
over: 0.83% max ΔE 41.2
```

`--out` writes a heatmap: the reference dimmed to 30 % luminance with the
red channel raised where ΔE went over.

### B parity — 2026-09-09

`refs/mac-thread.png` and `refs/mac-composer.png` (2756×1646 — the workspace
window shot on the 2× display with T3's zoom reset, the sidebar at its 16 rem
default and the pointer off the content; the two differ by focus only) against
`capture-ours.sh mac …` on `T3FIX_MAC_REF=1 fixture.sh`, whose transcript is
the reference thread's own "Hi" and reply, with the workspace window preset to
the same frame:

```
$ defaults write Infinitus "NSWindow Frame Workspace" "96 55 1378 823 0 0 1800 1169"
$ T3FIX_MAC_REF=1 tools/t3ref/fixture.sh && sleep 12
$ INFINITUS_CONTROL_SOCKET=/tmp/t3fix.sock tools/t3ref/capture-ours.sh mac composer /tmp/ours.png
$ python3 tools/t3ref/compare.py tools/t3ref/refs/mac-thread.png /tmp/ours.png --out /tmp/diff.png
$ tools/t3ref/fixture.sh --stop; rm -f /tmp/t3fix.sock
```

| screen | over ΔE 6 (≤ 1.5 % passes) | max ΔE |
|---|---|---|
| thread | 1.17 % ✅ | 107.4 |
| composer | 1.17 % ✅ | 107.4 |

No crop: the sizes match. The two screens are one window, so both rows read
the same capture. 2.12 % before the six fixes in #435 (2.72 % before the first
round). The first Mac pair was a 1× capture of a window zoomed 1.893× — every
content measurement was off by that factor however exact the port — and was
replaced by this one rather than normalized around.

**What closed the gap**, in order of area: the chat markdown and the composer's
editor were each one full leading short (SwiftUI's `.lineSpacing` goes only
BETWEEN lines, where CSS splits the extra leading half above the first line and
half below the last), which put the reply 18 px high and grew to 47 by the last
paragraph; the sidebar's scope row was missing its flex-1 trigger and its
`New project` button and carried a bottom padding that sat every card 8 px low;
the sidebar card's third line was blank where the reference names the branch
and the provider; the top bar was missing the terminal-drawer toggle and the
git control's chevron segment; and `px-[calc(--spacing(n)-1px)]` had been read
as the step rather than as the class's own arithmetic, widening every button by
2 pt.

What is left in the heatmap: the app's own wordmark and project glyph, the
composer's model / effort / access controls (capability-gated here, the
reference session has them), the sidebar row's relative timestamp, and two
pieces of reference STATE — the `5:38 PM` stamp (upstream's message footer is
`opacity-0 group-hover/assistant:opacity-100`, so the cursor was over the reply
when the first pair was shot) and the composer's "Ask for changes, send
follow-ups, or attach images", which `ChatComposer.tsx:5432-5450` reaches only
through `phase === "disconnected"`: the reference's thread was recreated by
hand and never ran, while the fixture's session is `idle`, i.e. `ready`
(`T3ComposerPlaceholder` ports the whole ladder). Future Mac references should
be captured with the pointer off the content.

**B-8 (inline code).** `.chat-markdown :not(pre) > code` (index.css:1792-1799)
is ported: `--muted` behind a 12 pt mono run in full `foreground`, grown by a
kerned mono space on each side for the `0.35rem` padding plus the 1 px border
(`MarkdownInline.CodeChip` — a `Text` run's `backgroundColor` is a rectangle,
so the 6 px radius and the hairline are not reachable inline). The reply's
`main` chip now measures 43 × 16 pt against the reference's 42 × 19.5, and its
glyphs land on the same x — the chip's block is gone from the heatmap. The
re-measure could NOT be the one above: the 2× panel that pair was shot on was
not attached, so both sides were read at 1× (the reference downscaled to
1378×823) — 0.86 % before, 0.81 % after, a number comparable only to itself,
never to the 2× rows. What still moves that paragraph's wrap is the favicon
upstream draws before a link (≈17 pt), not the chip.

**B-9 (the link favicon slot).** `MarkdownLinkFavicon`
(ChatMarkdown.tsx:1190-1215) is ported as a 20.3 pt image in the text flow —
lucide's `globe` at 14 pt inside the span's `ms-[0.25em]`/`me-[0.2em]` margins,
drawn in the link's colour — so a paragraph carrying links is built as
concatenated `Text`s (`MarkdownInline.LinkGlyph`: an `NSTextAttachment` in a
`Text`'s `AttributedString` draws nothing, `Text(Image(nsImage:))` in a
concatenation draws inline). The reply's third line now wraps where the
reference's does — "session" moved to the second line — and the slot lands on
the reference's own x (both 530-551 px at 1×); the glyph sits ON the baseline
rather than `-0.125em` below it, because `.baselineOffset` is the only way down
and it grows the line box by the offset. No favicon is fetched, so the
reference's Google-served raster globe stays a difference in that 14 px square.
The same 1× proxy as B-8, both sides at 1×: **0.81 % → 0.77 %** (max ΔE 108.5).
The 2× rows above are untouched — no scale-2 display was attached — and this
capture is the first taken with the harness fix (#442): before it,
`capture-ours.sh mac` shot whichever Infinitus window the window server listed
first, which with the pop-out open is not the workspace.

### C parity — 2026-09-09

From `compare-harness.sh` on the render harness's `parity-*` shots at
main 9c7e7a9b, against `refs/ios-home.png` / `refs/ios-thread.png`
(2026-09-08 captures), status bar masked:

| screen | over ΔE 6 (≤ 1.5 % passes) |
|---|---|
| home | 1.44 % ✅ |
| thread | 4.79 % |

Thread's remainder is the header block: the reference frames the thread
as a modal card (rounded top, dimmed parent, content ~19 pt lower) while
the phone keeps spec §5.1's push (user decision, #223). Composer, bubble
and reply rows are within 4 px. The number moves only with a new
`refs/ios-thread.png` captured on a pushed thread.

## What is in `refs/`

See `refs/PROVENANCE.md` — it records how each committed PNG was
produced, and which screens have no reference yet.
