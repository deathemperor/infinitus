# Where each reference came from

Every PNG here is the **real T3 Code client**, never Infinitus. B and C
diff their own captures against these with `compare.py`.

Reference build: `apps/mobile` dev client `com.t3tools.t3code.dev`,
`v0.0.39-10-gacc0a219e` from `~/death/t3code`, on the **iPhone 17 Pro**
simulator (iOS 26.5) at 1206×2622 — the sizes the spec §0 table names.
All eight decode cleanly with `compare.py` (checked one by one), and the
harness was exercised on them (`ios-thread.png` against itself:
`over: 0.00% max ΔE 0.0`; against `ios-git.png`: `over: 52.09% max ΔE
95.7`, heatmap written).

## The fixture thread

`ios-thread.png` and the four screens under it are the spec §3.6 fixture:
title **Hi**, project **limitless**, the two messages "Hi" / "Hi. Ready
when you are — what's the task?". That is the same thread
`tools/t3ref/fixture.sh` reproduces on the Infinitus side.

| File | Screen | Captured |
|---|---|---|
| `ios-thread.png` | the fixture thread | 2026-09-08 08:04, dev client connected to the desktop server, fixture thread live |
| `ios-git.png` | thread → git sheet | 2026-09-08 08:03, same session |
| `ios-files.png` | thread → files | 2026-09-08 08:03, same session |
| `ios-review.png` | thread → review | 2026-09-08 08:03, same session |
| `ios-terminal.png` | thread → terminal | 2026-09-08 08:04, same session |
| `ios-newtask.png` | new task → Choose project | 2026-09-08 08:04, same session |
| `ios-settings.png` | settings sheet | 2026-09-08 08:04, same session |
| `ios-home.png` | thread list (home) | 2026-09-08 13:16, `capture-ios.sh home` — see the caveat below |

The seven from 08:04 were taken by hand in the session that first built
and paired the dev client (same simulator, same build, same connected
state, same fixture thread). They are not re-capturable: **the `Hi`
thread has since been deleted from the desktop** — `select thread_id from
projection_threads where title = 'Hi'` returns nothing — so every
thread-scoped deep link now lands on "Route not found". Re-creating them
means re-creating the thread in T3 first (send "Hi" from the desktop app,
in a `limitless` project), then re-running `capture-ios.sh`.

`ios-home.png` **was** produced by the harness —
`T3_LAUNCH_WAIT=30 tools/t3ref/capture-ios.sh home refs/ios-home.png` —
so the thread list, search bar, filter and compose controls are exact.
Two regions in it are state, not layout, and B/C should expect them to
diff:

- the header reads **"Reconnecting to …"**: the phone could not reach the
  desktop server at capture time, so the list is served from its local
  cache (the `Hi` row and its `21h` stamp are that cache).
- the status bar carries a **"◀ Infinitus"** back link, left over from
  the app-switch chain that launched the client.

## Redactions

This repository is public. Five of the captures showed the machine's
username, its home path or the Mac's Bonjour name, and the `Hi` thread is
gone from the desktop so none of them can be re-shot. Each region was
flat-filled in place with the surface colour sampled from the three
pixel rows just outside it — same dimensions, 8-bit RGB, so `compare.py`
still decodes them.

| File | Rect `x,y,w,h` | What it hid |
|---|---|---|
| `ios-terminal.png` | `0,546,890,52` | the `pwd` output — the absolute home path and the username |
| `ios-settings.png` | `0,546,890,52` | the same line, dimmed in the Terminal pane behind the sheet |
| `ios-newtask.png` | `218,794,655,48` | the project row's absolute-path subtitle |
| `ios-home.png` | `508,228,296,57` | the Mac's name in the "Reconnecting to …" header |
| `ios-thread.png` | `203,341,208,46` | the Mac's name in the `limitless · …` subtitle |

**`compare.py` counts every one of these rects as a difference.** A clone
draws real text there; the reference is a flat block, and a flat block
has no internal luminance edges, so the glyph mask does not spare it —
close to every pixel in the rect lands in the over-ΔE count. Measured
against the 1206×2622 frame:

| File | Redacted area | Share of frame |
|---|---|---|
| `ios-terminal.png` | 46 280 px | **1.46 %** |
| `ios-settings.png` | 46 280 px | **1.46 %** |
| `ios-newtask.png` | 31 440 px | 0.99 % |
| `ios-home.png` | 16 872 px | 0.53 % |
| `ios-thread.png` | 9 568 px | 0.30 % |

The first two eat the whole 1.5 % budget on their own, so B and C must
**crop these rects out of the region under test** rather than absorb
them — comparing the full frame against `ios-terminal.png` or
`ios-settings.png` can never pass, however exact the clone is.

The remaining `~/de/limitless` shell prompts in the two Terminal shots
are abbreviated and carry no username. `ios-files.png`, `ios-git.png` and
`ios-review.png` needed no redaction.

## Not captured

- **`mac-*.png` — none.** `capture-mac.sh` works (verified: it found the
  T3 Code window, `2755×1646` pt, and `screencapture -l` wrote a PNG that
  `compare.py` decodes), but there is nothing safe to commit. The `Hi`
  thread no longer exists on the desktop, so the window can only be
  captured on whatever thread is open — which, on this Mac, is the
  user's live private work, sidebar thread titles included. Recreate the
  `Hi` thread in a `limitless` project first, then:

  ```
  export T3_ENV_ID=$(cat ~/.t3/userdata/environment-id)
  export T3_THREAD_ID=$(sqlite3 ~/.t3/userdata/state.sqlite \
      "select thread_id from projection_threads where title = 'Hi'")
  tools/t3ref/capture-mac.sh thread tools/t3ref/refs/mac-thread.png
  ```

- **`components/`** — the per-component crops spec §3.7 wants for the
  snapshot tests are cut from these captures when the components land.
