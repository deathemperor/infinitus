# Infinitus — project rules

Native macOS menu bar app for the claude-swap engine. Split out of
`~/death/claude-swap/swift/CswapBar` on 2026-08-29 with history.

## Non-negotiables
- **Infinitus is not tied to cswap — forever** (user 2026-09-05: "Infinitus
  has nothing tight to cswap, not anymore. this is a forever decision").
  cswap is one `AccountEngine` adapter among several; no feature, design,
  data format, CLI or publisher may depend on cswap existing. Anything
  cross-platform ships from THIS repo (InfinitusCore + InfinitusCLI on
  Swift for macOS/Linux/Windows), never as a cswap subcommand.
- **Everything is Swift; the engine is fully isolated.** Every engine
  touchpoint is a `cswap … --json` subprocess (InfinitusCore/Engines/Cswap/CswapCLI.swift).
  Never read engine internals (`~/.claude-swap-backup/*`). Reading
  Claude Code's own files is fine: `~/.claude/settings.json`,
  `~/.claude/sessions/*.json` (+ `.key`), `~/.claude/projects/*/*.jsonl`.
- **The resume-nudge mechanism lives HERE, not in the engine** (user
  2026-08-30; upstream never merged PR #250's copy). InfinitusCore
  ClaudeSessions/Transcript/PeerSocket/PtyHosts/PtyNudge/SessionResume
  + ResumeService. Never rebuild it engine-side.
- **Bundle id is `run.infinitus`**, the phone's `run.infinitus.mobile`
  (+`.widgets`, `.share`), every derived service id under the same
  prefix (user-approved explicit ask, 2026-09-05, with the paid Apple
  team `Q783W6B4FA`; before it `com.huuloc.infinitus` from 2026-09-03,
  `com.huuloc.limitless` from 2026-08-30, before that the CswapBar g2
  id). Prefs copy-migrate from the previous id's domain on first launch
  (AppModel.migrateLegacyDefaults). App Support is `Infinitus/`
  (copy-migrated from `Limitless/`, which came from `CswapBar/`; legacy
  dirs left for rollback). The local checkout may still live at
  `~/death/limitless`. Notification Center and login-item grants key on
  the id and must be re-granted once under it; keychain items are
  ACL'd to the old signature, so the proxy key is re-entered and the
  phone re-paired. Never change the id casually again — the 2026-08-29
  casual change cost a day of ControlCenter-ban debugging.
- **Push nothing to any remote** unless explicitly asked. Commit locally.
- **main takes commits only through pull requests** (GitHub ruleset
  "main via pull requests", user 2026-09-04): no direct push, no
  force-push, no deletion; 0 required approvals (solo repo); required
  checks test, e2e, linux, ios green on the PR head (never windows,
  2026-09-06, #206). Work on a branch, `gh pr create`, merge with
  `gh pr merge --squash` (or `--merge` when the branch history matters)
  once tests pass; `--auto` queues the merge behind the checks. PRs get
  `size:*` and `vouch:*` labels automatically.
- **Every commit carries `Co-Authored-By: Claude Code
  <noreply@anthropic.com>`** (user 2026-09-04: "some commits still
  missing Claude in author"). `tools/githooks/prepare-commit-msg`
  appends it; each clone/worktree owner runs `git config core.hooksPath
  tools/githooks` once (shared across worktrees of one clone). Subagent
  briefs still say it explicitly.
- Secrets (webhook URLs, bot tokens) travel over stdin, never argv; shown
  masked only. Usage-cost figures are estimates, never billing truth.
- **Release notes: one feature, one line** (user 2026-09-04). A CHANGELOG
  bullet is a single short sentence — no multi-sentence paragraphs, no
  wrapped essays; details live in the site/README, not the note.
- Surgical changes; match existing style; no speculative abstractions.
- **Todos and research notes go to GitHub issues, never to files**
  (user 2026-09-04: "stop noting TODO file to avoid a PR, just log to
  issue"). `gh issue create` / `gh issue comment`; docs/TODO.md is the
  shipped log only.
- **Account policy lives in the engines** (user 2026-09-03). Auto-swap,
  pick-first, ordering come from each engine's own knobs (cswap
  `autoswitch.*`, the proxy's priority); the app only sets those and
  never runs a second policy on top (the app-side auto-order writer was
  removed for this). Missing knob → upstream PR, never a fork.
- **Keep performance in check with every feature** (user 2026-09-03):
  idle CPU with the pop-out open must stay near 0% (`infinitusctl perf`
  twice, 15s apart; `tools/e2e.sh` gates it in CI). Any continuous
  motion goes through Core Animation (`LayerEffect`), never a
  TimelineView / repeatForever `.animation` — see the hard-won fact.

## Hard-won facts
- NSPopover measures content once; wholesale content-shape swaps must go
  through `withAnimation` so it re-measures live. Never close/reopen.
- macOS ignores Dynamic Type — popup scaling is `PopupScale`
  (fixedSize → measure → scaleEffect + matching frame). Measuring without
  `fixedSize` feeds the scaled width back in and runs away ×scale.
- The pop-out window must NOT let NSHostingView size it (crash on
  unbounded ideal width); PinnedRoot reports its fixedSize geometry and
  `fitPinned` applies it.
- Never `cp` over the RUNNING unbundled binary — overwriting a signed
  executable in place gets the process killed on its next page-in
  (the dev instance "mysteriously died" 2026-08-30). pkill first.
- macOS 26 ControlCenter can stop adopting new bundled apps' status items
  after rapid relaunch churn — only a logout clears it; `run-unbundled.sh`
  is the workaround. Don't run the dev loop's kill/reopen cycle for hours.
- NSPopover windows refuse CABackdropLayer at every level (renders a
  black slab; probed 2026-08-30) — the anchored popup is therefore a
  borderless non-activating NSPanel. CABackdropLayer + CAFilter
  gaussianBlur in a plain window is the only tunable-blur glass.
- NSGlassEffectView does NOT deactivate when its window resigns key —
  the "goes solid unfocused" repro was the probe window being occluded.
  Never reintroduce a focus-swap around it; glass runs in all states.
- usernoted refuses dev-cert builds without a provisioning profile;
  notifications fall back to osascript (working mode, not an error).
- SwiftUI Grid: spanning cells span the widest row's real column count;
  placeholders need `.frame(maxWidth: .infinity)` +
  `.gridCellUnsizedAxes(.horizontal)`.
- macOS 26: a VStack of mixed text+gauge rows under-reports its ideal
  HEIGHT under two-axis fixedSize (last row clips to slivers) — give
  every such row its own `.fixedSize()`.
- A GridRow can't wear a modifier (collapses to one cell), but a Group
  INSIDE it distributes the modifier to every cell — that's how the
  rows intro slides a whole grid row.
- Multi-engine (#8): every engine is an `AccountEngine` yielding
  `EngineFleet`s; the popup stacks one `FleetState` per fleet and
  `AppModel` is only a FleetModel FACADE over the primary Claude fleet.
  Gate UI on `capabilities`, never on engine identity.
- The CLIProxyAPI key lives in the keychain (`run.infinitus.cliproxy`,
  account = base URL). Unsigned debug binaries trip an ACL prompt on
  every rebuild — reads skip UI, and the dev loop codesigns the debug
  binary with the Apple Development identity so the grant sticks.
- Every SwiftUI-driven frame (TimelineView tick, repeatForever
  `.animation`) commits a CA transaction: display-list diff, AppKit
  drag-region + tracking-area rebuild, a WindowServer fence — ~7 ms
  each, the same whether one leaf or the whole grid changed. Five RPG
  effects at 20 fps idled the pop-out at 43% CPU (#18, 2026-09-03);
  as CAAnimations on a LayerEffect host they idle at 0.4%, burn
  overlays included (CAEmitterLayer sparks; a `.line` emitter's
  emissionLongitude is a quarter turn off a `.point` one's: 0 = up).
  A per-second `.contentTransition(.numericText)` grows the CG glyph
  cache ~2 MB/min for as long as it ticks (macOS 26) — never on a
  countdown; the e2e gate checks idle heap growth via `perf.heapBytes`.
  An ordered-out window keeps its SwiftUI content ticking (the wall's
  15 fps TimelineView cost ~8% idle after every visit): detach the
  hosting controller on close, and reuse the NSWindow — a closed
  borderless one lingers in AppKit's list regardless.
- Dev instances: sign the debug binary `--identifier
  run.infinitus` (tools/e2e.sh does) or the keychain ACL prompt
  blocks AppModel.init forever (no socket, SecurityAgent spawns).
  `swift build --target X` may not relink — use `--product`, ONE per
  invocation: with two `--product` flags SwiftPM builds only the last
  (CI's e2e ran a stale app binary for a day, 2026-09-03).
- Two Claude sessions work this repo (since 2026-09-02 evening): the
  second one lives in its OWN worktree `../limitless-e2` on branch `e2`
  (one `cd` there; separate `.build`). Main (`~/death/limitless`) is
  merge-only and owned by the first session, which also owns
  `Infinitus.app` rebuild/relaunch (always from a clean worktree at a
  main sha) and the PRs. Ship flow: e2 commits → "merge e2 at <sha>" →
  push `e2` → `gh pr create --base main --head e2` → tests → `gh pr
  merge --merge` → `git pull` main → rebuild → relaunch. Never edit the
  other session's tree; in either tree stage by explicit path.

## Release
- Every release updates **site/** (infinitus.run) and the **GitHub
  README** with the new features so app, site and README stay in sync
  (user 2026-09-03). Do it in the release commit, not after.

- Any dev/smoke instance of the app (debug binary, `-mock_mode`, a
  second bundle) MUST run with `INFINITUS_CONTROL_SOCKET=/tmp/<short>.sock`
  — without it, ControlServer.start() unlinks the real app's control
  socket and `infinitusctl`/the phone get "connection refused" until
  the bundle relaunches (bit us 2026-09-03 08:21). Short path: unix
  sockets cap at ~104 bytes, so never the scratchpad dir.

## Build / run / test
`./make-app.sh && open Infinitus.app` · `swift test` · `./dev.sh` (entr)
· `./run-unbundled.sh` (menu bar wedge workaround).
