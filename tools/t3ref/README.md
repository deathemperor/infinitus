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
| `compare.py` | `compare.py a.png b.png [--out diff.png] [--threshold 1.5] [--crop x,y,w,h]` — pure-stdlib PNG decode, per-pixel CIE ΔE76, 1-px dilated luminance-edge mask. Prints `over: 0.83% max ΔE 41.2`, exits 1 above the threshold. `--crop` takes the same pixel rect out of both images first (a panel column, a tab strip), before the mask and before the size check. |
| `fixture.sh` | A fake `CLAUDE_CONFIG_DIR` holding the parity fixture, plus the debug app on it. `fixture.sh --stop` tears it down. |
| `recite.py` | `tools/t3ref/recite.py [--dry] OLD NEW file.swift…` moves a Swift file's upstream `File.tsx:NN` citations from OLD's line numbers to NEW's (difflib over `git show`; only files that changed between the shas move). Run it over files whose citations are all at OLD — the T3 working tree sits at acc0a219e while the port pins 6c583620f, so a coder who read the tree cites the wrong lines. |
| `winmove.swift` | `winmove <window-id> <x> <y> [w h]` moves that window's top-left corner to a CG point, then sizes it, through its own process's accessibility tree (`capture-ours.sh` runs it when `T3REF_WINDOW_ORIGIN="x y"` is set, with `T3REF_WINDOW_SIZE=WxH` or the preset's size). Not System Events: `process whose unix id is N` resolves by name there, and with two Infinitus processes it moves the other one's window. |
| `winlist.swift` | `winlist <owner-substring> [title-substring\|WxH]` → `id width height` of that app's first matching normal-layer window. The filter picks the workspace out of an Infinitus that also has the pop-out open; `WxH` matches the bounds exactly (`kCGWindowName` is empty without Screen Recording permission). |
| `capture-mac.sh` | `capture-mac.sh <sidebar\|thread\|composer\|panel-{diff,files,pr,terminal,agents}> <out.png>` — screenshots the running T3 Code window; a `panel-*` screen presses the right-panel toggle and that tab first, and exits 5 rather than opening a surface the reference does not already have. |
| `axpress.swift` | `axpress <dump\|win\|find\|press> <pid> [label] [--exact] [--in x,y,w,h] [--index N] [--no-front]` — the read-only UI driver: find one control (AXButton / AXCheckBox / AXRadioButton / AXTab) by title, description or help and `AXPress` it, but only once that pid is frontmost. `find` exits 4 when nothing matches, which is how a script tells an open right panel from a closed one; `win` lists that pid's windows as `id w h x y`, the way to pick a fixture's own window when two are on screen. `--no-front` is for a fixture we own that cannot take the front from the other fixture — never for the reference app. |
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
network); `T3FIX_NAME=<short>` moves all of it to `/tmp/<short>*` so a second
fixture can run beside the first (two rounds sharing one fixture stopped each
other's app, 2026-09-10). The control socket is `/tmp/t3fix.sock`, **never** the real
app's — running a debug instance without that would unlink the real
socket and break `infinitusctl` and the phone until the bundle relaunches.
`INFINITUS_MIRROR_SNAPSHOT` points `MirrorExporter` at
`/tmp/t3fix/mirror-snapshot.json` too, so the fixture never overwrites
the real app's mirror snapshot (#474).

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
$ T3REF_WINDOW_ORIGIN="1900 1500" T3REF_WINDOW_SIZE=1378x823 \
    INFINITUS_CONTROL_SOCKET=/tmp/t3fix.sock tools/t3ref/capture-ours.sh mac composer /tmp/ours.png
$ python3 tools/t3ref/compare.py tools/t3ref/refs/mac-thread.png /tmp/ours.png --out /tmp/diff.png
$ tools/t3ref/fixture.sh --stop; rm -f /tmp/t3fix.sock
```

The frame preset alone lands the window on the MAIN display (the controller
clamps a restored frame onto `NSScreen.main`), so when the 2× panel is a
secondary display `T3REF_WINDOW_ORIGIN` drags it there — the point is the
panel's CG origin plus a margin (`/tmp/screens` prints the Cocoa frames; a
panel at Cocoa y −1169 sits at CG y 1440 below a 1440-pt main display), and
`T3REF_WINDOW_SIZE` carries the reference size with it: the app writes the
window's frame back into the `NSWindow Frame Workspace` default on every move,
and a preset whose screen rect names no attached display is not honoured at
all (the window opens at the controller's 620 pt minimum), so the default
cannot be trusted past the first open. Verify with `sips -g pixelWidth`: 2756,
not 1378, and `pixelHeight` 1646.

| screen | over ΔE 6 (≤ 1.5 % passes) | max ΔE |
|---|---|---|
| thread | 1.10 % ✅ | 107.4 |
| composer | 1.10 % ✅ | 107.4 |

No crop: the sizes match. The two screens are one window, so both rows read
the same capture (re-measured after B-12 and B-15, 2026-09-10; 1.11 % before
them). 1.17 % before B-8, B-9 and #446 (re-measured at 2× with the
window moved onto the built-in panel by the Accessibility API, since the
autosave preset is clamped back onto the main display at show time). 2.12 % before the six fixes in #435 (2.72 % before the first
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

**B-11** (the four upstream one-liners 577b6cc22 / 5ec6f77ec / 72d94087b /
12f560444, acc0a219e → v0.0.40) changed no code — sidebar spacing already
matched (card top y=138 at 1×, 276 at 2×), the other three have no B
counterpart — so the same 1× proxy as B-8/B-9 (`refs/mac-thread.png`
downscaled to 1378×823, PIL LANCZOS) reads **0.77 %** (max ΔE 108.5),
unchanged.

### B-41 — the right panel's tabs, 2026-09-10

Five new Mac screens — `panel-diff`, `panel-files`, `panel-pr`,
`panel-terminal`, `panel-agents`: the thread screen with the right panel open
on that tab, at the same 1378×823 pt frame as `thread`/`composer` (2756×1646
at 2×). `capture-mac.sh` drives the reference read-only — `open -a` to satisfy
axpress's frontmost guard, the panel toggle if the panel is shut, the tab, the
screenshot, nothing else. `capture-ours.sh mac panel-<tab>` asks
`show workspace thread` (ControlServer knows no panel screen: the tab is
`T3RightPanel`'s own `@State`) and presses the same two controls in the
fixture app.

| screen | full panel, toast in (≤ 1.5 % passes) | chrome (tab strip) | drift note |
|---|---|---|---|
| panel-agents | 4.55 % ❌ (max ΔE 97.3) — an update toast the harness may not dismiss covers ~9 % of this crop; below it the body reads 0.66 % | 2.76 % ❌ (max ΔE 93.8) | the only tab with a reference |
| panel-diff | no reference | no reference | no Diff **surface** open in the reference; opening one is a write to the user's app |
| panel-files | no reference | no reference | same |
| panel-pr | no reference | no reference | same |
| panel-terminal | no reference | no reference | same, and it would fork a real shell in the user's repo |

**Why four rows have no number.** The reference's strip is not a fixed set of
tabs: it renders ONE TAB PER OPEN SURFACE (`RightPanelTabs.tsx:1009`
`props.surfaces.map`, each with its own `Close <title>` button) beside an
`Add panel surface` launcher, and an empty panel shows the card launcher
instead (`RightPanelEmptyState`, `:293`). The user's app had exactly one
surface open — Agents — so that is the only tab a press can reach. Adding
Diff/Files/Pull request/Terminal means pressing the launcher, which persists a
surface in their app (and the only undo is the Close button the harness must
not press); Terminal would also start a real shell in their repository. The
harness therefore reports a missing tab and never creates one
(`capture-mac.sh` exits 5). This is a **port deviation, not version drift**: the
surface model is what the running build's own accessibility tree shows, and it
is the model at `acc0a219e` and at the pinned `6c583620f` alike
(`props.surfaces.map`, `RightPanelEmptyState`); all five surface labels are in
the 0.0.40 asar on disk too. `T3RightPanel.swift` already states the fixed
five-tab strip as a deviation.

**Which build the reference is.** The bundle on disk is 0.0.40, but the
process being captured is the one before it: started 7 Sep 14:03, holding an
`app.asar` whose inode no longer matches the file at that path (the bundle was
replaced 8 Sep 06:54), with `Update 0.0.40 downloaded. Click to restart and
install.` in its own sidebar. That button was not pressed. Treat the panel
reference as pre-0.0.40 until the user restarts the app and it is re-shot.

**The crop.** Both panels are right-docked, so the crop is right-anchored:
`--crop 1676,0,1080,1646` is the reference's whole panel (540 pt) and the
matching column of ours, `--crop 1676,0,1080,104` is the tab strip — 52 pt,
the `--workspace-topbar-height` the strip is built on
(`RightPanelTabs.tsx:987`), measured on both sides (the tab strip group is 52
pt tall in the reference's AX tree and the toggles are centred at 26). Our
panel is 560 pt — `min(max(0.42 × 1378, 360), 560)`, the shell's
`w-[42vw] min-w-[360px] max-w-[560px]` — against the reference's 540, because
a surface persists the width the user dragged it to; the 20 pt shifts every
row 40 px left in the crop and is reference state, not a port delta.

A third number is the honest one for the body: the reference is showing a
`Update Available: Codex v0.154.0` toast over its panel (360×116 pt, ~9 % of
the crop) and its Dismiss button is a press the harness does not make, so
below it — `--crop 1676,420,1080,1226` — the two read **0.66 %**. That number
is mostly shared dark background: the reference's rows are the user's real
subagents, the fixture's are two seeded ones, and the edge mask drops the
glyph edges where they differ.

**Top deltas per tab.** Only `panel-agents` is measured; the first two apply
to every tab and are what the heatmap is made of.

- **panel-agents.** (1) The strip: five fixed labels of ours against one
  `Agents` pill carrying the bot icon, a close X and the `+` launcher
  (`RightPanelTabs.tsx:1009-1060`, `:1106`). (2) The layout controls — maximize,
  terminal drawer, right panel — sit INSIDE the panel's strip row upstream
  (the reference's AX tree puts them at the window's right edge, x 3173/3205/3237
  of a window ending at 3278, `props.layoutControls` at `:993-999`), while ours
  keeps them in the chat top bar left of the panel and has no maximize at all.
  (3) Row pitch: our agent rows step ~140 px at 2× against the reference's
  ~122, though the first row's top (y≈190) and the `N settled · Σ tok` footer
  land on the same y.
- **panel-diff.** (1) and (2) above. (3) Unmeasured: our header is the
  `Working tree ⌄` scope pill with `+2 −1` and three icon buttons; upstream's
  `DiffPanel.tsx:564,748,782` has the same scope word, the same stat and an
  `Expand/Collapse all files` toggle whose position cannot be checked without a
  reference.
- **panel-files.** (1) and (2). (3) Unmeasured: our tree is a search row over
  `docs/ src/ config.toml`; the phone's Files reference (C) put the search in a
  BOTTOM toolbar, so the Mac's row position is the first thing to check when a
  reference exists.
- **panel-pr.** (1) and (2). (3) Ours draws the unavailable card ("Pull
  request / This project has no GitHub remote."); upstream has no card there at
  all — an unavailable surface is a greyed LAUNCHER card with a one-line reason
  (`RightPanelTabs.tsx:138-142`), which is the deviation the tab strip forces.
- **panel-terminal.** (1) and (2). (3) Our tab renames itself `Terminal 1`
  on the first shell, matching upstream's per-terminal title
  (`surfaceTitle`, `:598-602`) — pass `T3REF_TAB_LABEL` to name it when
  capturing — but the pane is still empty 3 s after the press, no prompt drawn.

The recipe (the fixture seeds the tabs' content: a few files, a working-tree
patch off one checkpoint, two settled sub-agents; the Pull request tab stays
on its unavailable card, which is what the reference's launcher hint says too):

```
$ defaults write Infinitus "NSWindow Frame Workspace" "96 55 1378 823 0 0 1800 1169"
$ T3FIX_NAME=t3b41 T3FIX_MAC_REF=1 T3FIX_PANELS=1 tools/t3ref/fixture.sh && sleep 12
$ tools/t3ref/capture-mac.sh panel-agents tools/t3ref/refs/mac-panel-agents.png
$ T3REF_WINDOW_ORIGIN="1900 1500" T3REF_WINDOW_SIZE=1378x823 \
    INFINITUS_CONTROL_SOCKET=/tmp/t3b41.sock \
    tools/t3ref/capture-ours.sh mac panel-agents /tmp/ours-agents.png
$ python3 tools/t3ref/compare.py tools/t3ref/refs/mac-panel-agents.png /tmp/ours-agents.png \
      --crop 1676,0,1080,104 --out /tmp/diff-chrome.png
$ T3FIX_NAME=t3b41 tools/t3ref/fixture.sh --stop; rm -f /tmp/t3b41.sock
```

Two things the reference window needs and one it refuses: `winmove <id> x y w h`
applies the size but NOT the position on an Electron window in one call — move
it, then call `winmove <id> x y` again — and a size set while the window is on
the smaller panel is clamped to that panel, so restoring the original frame
takes a second `winmove` once it is back on the main display (the reference was
returned to 1706×1319 @3414,31 with its panel shut, the state it was found in).
`refs/mac-panel-*.png` and `refs/ours-panel-*.png` are git-ignored: they are
the user's real repository on screen.

### C parity — 2026-09-09

From `compare-harness.sh` on the render harness's `parity-*` shots at
main 9c7e7a9b, against `refs/ios-home.png` / `refs/ios-thread.png`
(2026-09-08 captures), status bar masked:

| screen | over ΔE 6 (≤ 1.5 % passes) |
|---|---|
| home | 1.44 % ✅ |
| thread | 4.79 % |
| files | 6.51 % |

Thread's remainder is the header block: the reference frames the thread
as a modal card (rounded top, dimmed parent, content ~19 pt lower) while
the phone keeps spec §5.1's push (user decision, #223). Composer, bubble
and reply rows are within 4 px. The number moves only with a new
`refs/ios-thread.png` captured on a pushed thread.

Files (`parity-files`, the Files screen over `refs/ios-files.png`'s tree,
measured with the Files PR) matches row for row — 42 pt rows, 18 pt per
depth, the search pill in a bottom toolbar over the fade — and carries
the thread's framing offset (the ref is the modal card again, content
~17 pt lower) plus the back chevron a push needs and the ref's gear
button (gone upstream at `6c583620f`, not drawn). Same caveat: the number
moves only with a re-shot reference.

The phone refs were shot from the dev client at upstream `acc0a219e`
(PROVENANCE). Ports of later upstream commits — the Working label's sky
tint (`357b8d521`), the account badge on Home rows (`2c8e95a4b`) —
read as drift against them by design; the home number is not chased
until the refs are re-shot from a newer dev client.

The Usage screen (Settings → Usage: limits #458, cost tab #466) is a
post-ref port of upstream `6c583620f`'s `features/usage/` — the route did
not exist at `acc0a219e`, so there is no reference for it and it is
unmeasured. The harness renders it as `settings-usage-dark`; a number
comes only with an `refs/ios-usage.png` shot from a newer dev client.

## What is in `refs/`

See `refs/PROVENANCE.md` — it records how each committed PNG was
produced, and which screens have no reference yet.
