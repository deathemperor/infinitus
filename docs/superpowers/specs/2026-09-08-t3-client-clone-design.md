# T3 Code client clone — iOS and Mac — design

User ask (2026-09-08): "a pixel perfect client clone of t3 code for both
iOS and mac so I can manage Claude sessions". Decisions taken with the
user the same day: the clone lives **inside Infinitus** (not new app
targets); v1 covers **all four T3 surface groups** (core threads,
settings + projects, diffs/review + git controls, terminal + usage +
pull requests); the pixel reference is the **installed T3 Code (Alpha)
desktop app** for the Mac and a **locally built T3 mobile dev client**
for the phone; the terminal engine is **SwiftTerm**; work is split
**Infi4 = spec + Mac, Infi3 = iOS, Infi = bundle rebuilds**.

This spec covers sub-projects **A (foundation), B (Mac window) and C
(iOS screens)**. D (settings + projects), E (git + review) and F
(terminal, usage, PRs) get their own specs once A–C are on main; §9
fixes their interfaces so nothing in A–C has to be reopened.

Related: #223 (research + phases 1–6, all shipped), #151 (owned
sessions), #144 (several Macs), #167 (checkpoints).

## 0. Reference material and its versions

| Surface | Reference | Version | How captured |
|---|---|---|---|
| Mac | `/Applications/T3 Code (Alpha).app` (Electron around `apps/web`) | 0.0.38 (`com.t3tools.t3code`) | `screencapture -l <windowId>` of the running window (1800×1050 default) |
| iOS | `apps/mobile` dev client, built from the checkout | `v0.0.39-10-gacc0a219e` (`~/death/t3code`) | `xcrun simctl io booted screenshot` on iPhone 17 Pro (1206×2622 @3x) |
| Source | `~/death/t3code` | same | file:line references below |

The checkout is ten commits past the installed desktop build. Where the
two disagree, **the installed app wins for the Mac and the checkout wins
for the phone** (the phone has no installed build). `upstream/t3code.json`
moves to `acc0a219e` with this spec.

The mobile dev client recipe (already run once, works):
`cd apps/mobile && APP_VARIANT=development EXPO_NO_GIT_STATUS=1 pnpm exec
expo prebuild --clean --platform ios && pnpm exec expo run:ios --device
"iPhone 17 Pro"`, then `pnpm exec expo start --dev-client --scheme
t3code-dev --lan`, open `t3code-dev://expo-development-client/?url=http://localhost:8081`.
Pair it to the desktop server with `cd apps/server && node src/bin.ts
pair` and open `t3code-dev://connections/new?autoConnect=1&pairingUrl=<url-encoded>`.
Every screen is reachable by deep link (`apps/mobile/src/Stack.tsx`
`linking:` entries; threads are `threads/:environmentId/:threadId[/git|/review|/files|/terminal]`),
so the parity harness never taps.

Gotcha for scripts: zsh ties `$path` to `PATH`, and `$T:thread` is a
history modifier — the harness uses `route`/`${T}` names.

## 1. What T3's clients are, concretely

**Mac (`apps/web`, React 19 + Tailwind v4 + TanStack Router, in Electron).**
Layout (`AppSidebarLayout.tsx`, `components/ui/sidebar.tsx`, `ChatView.tsx`):
a 16 rem sidebar (`SIDEBAR_WIDTH`) with search, "All projects" scope
picker, project groups and thread cards (`Sidebar.tsx`, status colours per
`Sidebar.logic.ts`: colour only for approval / working / failed); a 52 px
top bar (`--workspace-topbar-height`) with project › thread breadcrumb,
"Add action", "Open", "Commit & push" and the panel toggles; the
messages timeline (`MessagesTimeline.tsx`, rows from
`MessagesTimeline.logic.ts:281-366`); a floating composer
(`ChatComposer.tsx`: prompt editor, model · effort · permission pickers,
attach, send/stop) over a docked git line (`BranchToolbar.tsx`: checkout,
branch); a right panel with tabs Browser / Terminal / Files / Diff /
Pull request / Agents (`RightPanelTabs.tsx`). Fonts: system
(`--font-sans: -apple-system…`). Icons: lucide-react. Tokens:
`apps/web/src/index.css` (`:root` light, `@variant dark`; radius 0.625 rem;
zinc/neutral scales; `--primary: oklch(0.488 0.217 264)` light,
`oklch(0.571 0.21 264)` dark).

**iOS (`apps/mobile`, Expo 57 / RN, native stack).** Root stack
(`Stack.tsx`): Home (`HomeScreen.tsx`: `T3 Code` wordmark + DEV badge,
thread list v2 grouped by project with a relative time, status glyph;
bottom pill bar filter · search · compose), Thread
(`ThreadDetailScreen.tsx`/`ThreadFeed.tsx`: title + `project · environment`
subtitle, terminal/files/settings header pills, feed with blue user
bubbles and plain assistant text, timestamps + copy, docked composer
"Ask the repo agent, or run a command…" with `+` and send), New Task
sheet (`NewTaskRouteScreen.tsx` "Choose project" → `NewTaskDraftScreen.tsx`
draft with environment/branch/settings sub-routes), Thread settings
sheet, Git sheet (`ThreadGitControls.tsx`: branch title, Commit / Push /
Create PR / Pull latest / Review changes rows with state subtitles),
Review (`t3-review-diff` native Swift view, "Turn N" header), Files,
Terminal (`t3-terminal` native view over libghostty), Settings sheet
(Environments, Project grouping, auto-settle toggles, days stepper,
Usage, Archive, Appearance, Client storage, Legal), Environments +
Connections/new (host + pairing code), Add project. Fonts: DM Sans
400/500/700 (`@expo-google-fonts/dm-sans`, OFL). Icons: SF Symbols via
`expo-symbols` on iOS (`AppSymbol.ios.tsx`). Tokens:
`apps/mobile/global.css` (`@variant light` / `@variant dark` under
`@layer theme`; e.g. light screen `#f2f2f7`, card `#ffffff`, foreground
`#262626`, user bubble `#007aff`; dark screen `#0a0a0a`, card `#171717`,
foreground `#f5f5f5`).

**Shared logic worth porting verbatim (pure, tested upstream):**
`packages/client-runtime/src/pendingRequests.ts` (already mirrored as
`PendingRequests` in Core), `state/thread-settled.ts`, `state/thread-sort.ts`,
`work-log/presentation.ts` + `commandLabel.ts` (tool rows → labels),
`apps/mobile/src/features/threads/threadListV2.ts` (status, sections,
paging), `apps/web/src/components/chat/MessagesTimeline.logic.ts`
(`deriveMessagesTimelineRows`, `computeStableMessagesTimelineRows`),
`apps/web/src/components/Sidebar.logic.ts` (sections, drop plans,
traversal).

## 2. Architecture

```
InfinitusCore            (exists)  timeline, facts, attention, owned sessions, mirror wire
InfinitusUI              (exists)  shared SwiftUI (Mac + phone)
  └─ T3/                 (new, A)  tokens, typography, icons, component kit, presentation reducers
Sources/Infinitus/T3Window/   (new, B)  the Mac window (AppKit shell + SwiftUI content)
ios/InfinitusMobile/T3/       (new, C)  the phone screens (replace the current ones)
tools/t3ref/                  (new, A)  reference capture + parity diff
```

Rules carried over from CLAUDE.md: gate on `capabilities`, never on
engine identity; every host touchpoint stays a subprocess or the mirror
wire; idle CPU near 0 % with the window open (`infinitusctl perf` gate);
continuous motion goes through `LayerEffect`, never a TimelineView.

### 2.1 Data mapping (T3 → Infinitus)

| T3 | Infinitus | Source of truth today |
|---|---|---|
| environment | a Mac (`MachineIdentity`, #144) | `MirrorSnapshot.machine`, `.well-known/infinitus` |
| project (`projectId`, name, cwd, favicon) | a repo/cwd; name = folder name, grouped like `sidebarProjectGrouping.ts` | `recentCwds`, session `cwd`, profiles |
| thread (`threadId`, title, branch, `latestTurn`, counts) | a session (`sessionId`; pid while alive) | `ClaudeSessionRecord`, `SessionFacts` |
| thread `session.status` | `SessionFacts.status` | facts |
| `hasPendingApprovals` / `hasPendingUserInput` | same names | facts (`PendingRequests`) |
| settled / snoozed / pinned | `AttentionStore` overlays | `POST /sessions/{pid}/attention` |
| archived thread | past session | `PastSessions` |
| messages + activities + turns | `SessionTimeline` | `GET /sessions/{pid}/timeline`, `TimelineCache` |
| proposed plan | `PendingRequest.planMarkdown` | owned sessions |
| model / effort / permission mode | `SessionStart` fields, `SessionInput.Kind.mode` | start form, mode route |
| turn diff summary | checkpoint diff | `Checkpoints` (E extends) |

New host data A–C need and don't have: **project list** (distinct cwds
across live + past sessions + profiles, with a stable `projectId` =
SHA-1 of the realpath, a display name, and git facts: branch, dirty
count, ahead/behind) and **thread title** (first user prompt, ≤ 80 chars,
already `SessionNaming.displayName`). Both are additive fields on
`MirrorSnapshot` (`projects: [ProjectSummary]?`, `SessionRow.title`),
decoded with `decodeIfPresent`, and reachable on the Mac without the
wire through `AppModel`. Everything else A–C render already exists.

### 2.2 The status vocabulary

`ThreadListV2Status` (`threadListV2.ts:134-150`) ported as
`T3ThreadStatus: approval | input | working | failed | ready`, derived
from `SessionFacts` in that order. Colour only for approval, working and
failed (T3's rule); ready has no colour; input uses the approval treatment
with a question glyph (T3 mobile `thread-list-v2-items.tsx`).

## 3. Sub-project A — foundation (`InfinitusUI/T3`, `tools/t3ref`)

### 3.1 Tokens (`T3Theme.swift`, generated)

`tools/t3ref/gen-tokens.py` reads `apps/mobile/global.css` and
`apps/web/src/index.css` from the checkout and writes
`Sources/InfinitusUI/T3/T3Theme.generated.swift`: two token sets,
`T3Theme.mobile` and `T3Theme.web`, each with `.light` and `.dark`
`Color`s named exactly as the CSS custom properties (`screen`, `card`,
`foregroundSecondary`, `userBubble`, … / `background`, `sidebar`,
`sidebarRowSelected`, `primary`, `messageSurface`, …). oklch and
`color-mix` are resolved at generation time to sRGB (Python, no
runtime cost). The generator is idempotent and checked in with its
output; CI fails if the output drifts from the committed file.
`radius` (0.625 rem → 10 pt), `controlRadius`, `sidebarWidth` (256),
`topbarHeight` (52), `sidebarContentInset` (8), `sidebarRowContentInset`
(10) come from the same file.

A view reads tokens through `@Environment(\.t3)` (`T3Environment`:
`platform: .mobile | .web`, `scheme`), never through a global, so the
Mac window and the phone can render each other's set in previews and in
the parity harness.

### 3.2 Typography

Phone: DM Sans 400/500/700 bundled under
`ios/InfinitusMobile/Fonts/` (OFL text alongside), registered in
`project.yml` `UIAppFonts`; `T3Font.body(size:weight:)` maps
`--font-sans/medium/bold`. Phone sizes are T3's own scale
(`global.css` `@theme`, mirrored in `src/lib/typography.ts`): 3xs 11/14,
2xs 12/16, xs 13/17, sm 14/19, base 16/23, lg 18/23, xl 21/28, 2xl 26/32,
3xl 30/36 (pt / line height). Mac: `.system` (SF) with Tailwind v4's
web scale (xs 12/16, sm 14/20, base 16/24, lg 18/28, xl 20/28, 2xl 24/32)
plus the literal sizes T3 uses in classes (`text-[13px]`, `text-[15px]`).

### 3.3 Icons

Phone: SF Symbols, names copied from `AppSymbol.ios.tsx` (one Swift
enum `T3Symbol` with the raw names; a unit test asserts every case
resolves with `UIImage(systemName:)`). Mac: the lucide SVGs T3 imports
(`grep -o "Icon[A-Za-z]*" Icons.tsx` → ~90 names) vendored as
`Sources/InfinitusUI/T3/Lucide.xcassets` symbol images (lucide is ISC;
LICENSE file next to them), rendered with `Image("lucide/<name>")` at
T3's `size-4` (16 pt) / `size-3.5` (14 pt) with `stroke-width 2`.

### 3.4 Component kit (`Sources/InfinitusUI/T3/Components/`)

One Swift view per T3 primitive, same name, same props where sensible:

- web `ui/*` (Mac): `T3Button` (variants default / secondary / ghost /
  outline / destructive; sizes sm / default / icon), `T3Badge`,
  `T3Input`, `T3Textarea`, `T3Select` / `T3Combobox` (NSMenu-backed
  popover), `T3Tooltip`, `T3Kbd`, `T3Separator`, `T3ScrollArea`
  (6 px scrollbar, `--app-scrollbar-thumb`), `T3Dialog`, `T3Toast`,
  `T3Sidebar` (+ `Group`, `Menu`, `MenuItem`, `Rail`), `T3Skeleton`,
  `T3Spinner`.
- mobile `components/*` (phone): `T3ControlPill`, `T3StatusPill`,
  `T3GlassSurface` (UIVisualEffect `.systemMaterial` + tint from
  `glassSurface`/`glassTint`), `T3EmptyState`, `T3LoadingStrip`,
  `T3ErrorBanner`, `T3BrandMark` / `T3Wordmark` (the `T3 Code` +
  variant badge header), `T3ComposerToolbar`, `T3ComposerAttachmentStrip`,
  `T3ThemedSwitch`, `T3AndroidAnchoredMenu` (not ported),
  `T3ProjectFavicon`, `T3ProviderIcon` (the Claude asterisk glyph;
  sampled from the references: `#c67152` on the dark Mac sidebar,
  `#e3a897` on the light phone list — one glyph tinted by `t3.platform`
  and scheme, values regenerated by `gen-tokens.py` from the captures).

Each component has a SwiftUI preview and a snapshot test against a
cropped reference PNG (§3.7).

### 3.5 Presentation reducers (`Sources/InfinitusCore/T3/`)

Pure Swift ports in InfinitusCore (no SwiftUI, so `swift test` covers
them on Linux too, next to `ThreadFeedPresentation`), one file per
upstream module, with the upstream test cases transcribed as XCTest data
tables:

- `T3ThreadList.swift` ← `threadListV2.ts` + `client-runtime/state/thread-sort.ts`
  + `thread-settled.ts`: `status(facts:)`, `orderedSection`, `buildItems`
  (pinned → active → snoozed shelf → settled tail with the 10 / 25 paging),
  swipe actions, snooze presets and wake labels.
- `T3SidebarList.swift` ← `Sidebar.logic.ts`: sections, markers, drop
  plan/verb, adjacent-thread traversal, unseen-completion.
- `T3TimelineRows.swift` ← `MessagesTimeline.logic.ts`: the row union
  (`work`, `workLive`, `workToggle`, `turnFold`, `contextCompaction`,
  `message`, `assistantMeta`, `proposedPlan`, `working`, `thinking`),
  `deriveRows(timeline:latestTurn:expandedTurns:expandedGroups:activeWorkStartedAt:)`
  and the stable-rows step (the live slot keeps one id).
- `T3WorkLog.swift` ← `work-log/presentation.ts` + `commandLabel.ts`:
  tool entry → label/detail/icon, group summaries ("Read 3 files,
  changed 2 files, and ran 1 command").
- `T3ProjectGrouping.swift` ← `sidebarProjectGrouping.ts`.

These are the only place presentation rules live; both platforms render
their output. Existing `ThreadFeedPresentation` (#223 phase 2) is
replaced by `T3TimelineRows`; the old reducer is removed once the last
caller (the browser page) moves, tracked in §9.

### 3.6 Reference capture and parity harness (`tools/t3ref/`)

- `capture-mac.sh <screen>`: finds the T3 window id (`winlist.swift`),
  drives the T3 app to the named screen through its own deep-link
  scheme (`t3code://…`, `apps/desktop` protocol) or the CLI, waits,
  `screencapture -l`. Screens: `sidebar-empty`, `thread-empty`,
  `thread-conversation`, `composer-focused`, `right-panel-diff`,
  `settings-general`, … (the list grows per sub-project).
- `capture-ios.sh <screen>`: boots the simulator, opens the deep link,
  `simctl io screenshot`.
- `capture-ours.sh <platform> <screen>`: Mac via the control socket
  (`infinitusctl t3 open <screen>` — a debug-only route) and
  `screencapture`; phone via `xcodebuild test` UI-test that navigates and
  attaches a screenshot.
- `compare.py a.png b.png --out diff.png`: same-size check, per-pixel
  ΔE in Lab, prints the fraction of pixels over ΔE 6 and the max; writes a
  side-by-side + heatmap.
- **Acceptance per screen: ≤ 1.5 % of pixels over ΔE 6** with text
  antialiasing excluded (a 1-px dilation mask around glyph edges), at the
  reference sizes. Content that is inherently different (real thread
  text, timestamps, the DEV badge) is driven by a **fixture**: one
  Infinitus session and one T3 thread with the same title, the same two
  messages ("Hi" / "Hi. Ready when you are — what's the task?"), the same
  project name `limitless`. The Infinitus side is `tools/t3ref/fixture.sh`:
  it writes a `CLAUDE_CONFIG_DIR` the way `tools/e2e.sh` does (a
  `sessions/<pid>.json` with status `waiting`, a `projects/<slug>/<id>.jsonl`
  with the "Hi" pair, an open `Write` tool_use for the pending approval
  and an `AskUserQuestion` tool_use with two questions), then launches
  the real app (`INFINITUS_CONTROL_SOCKET=/tmp/t3fix.sock`) with the
  mirror on, so the Mac window, the phone and the browser page all read
  the same fixture through the unchanged pipeline. The harness reports;
  CI does not gate on it yet (the reference app is not on CI machines) —
  the numbers go in the PR description.

### 3.7 Testing (A)

`swift test` on Core/UI reducers (ported tables); iOS unit tests for
`T3Symbol`; a token drift check; component snapshot tests via
`XCTAttachment` comparisons against `tools/t3ref/refs/components/*.png`
cropped from the captures.

## 4. Sub-project B — the Mac window (`Sources/Infinitus/T3Window/`)

### 4.1 Shell

`T3WindowController: NSWindowController`. `NSWindow` with
`[.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]`,
`titlebarAppearsTransparent`, `titleVisibility = .hidden`, traffic lights
inset to T3's Electron geometry (`--workspace-controls-left` 12 px,
`titlebar-area-height` 52) via `standardWindowButton(...)?.frame`. Default
size 1800×1050 (the reference); min 960×600. Content is a single
`NSHostingView<T3Root>`; the window never lets the hosting view size it
(PinnedRoot rule). `NSGlassEffectView` is not used (T3 has no glass on
desktop; its `.glass` class is a CSS backdrop, ≈ `--glass-blur 12px` —
rendered with `NSVisualEffectView.hudWindow`-free plain colours since the
reference is opaque). Opened from the menu bar popup ("Open T3 window"),
`infinitusctl t3 open`, and ⌘⇧T; one window, reused (closed windows keep
their NSWindow, content detached — the wall's lesson).

### 4.2 Layout (T3Root)

```
┌ sidebar 256 ─┬ topbar 52 ───────────────────────────────┬ right panel (0 | ≥ 360) ┐
│ brand row    │ breadcrumb   Add action  Open  Commit & push │ tabs …                  │
│ search  ✎    ├───────────────────────────────────────────┤                         │
│ scope ▾  +   │  timeline (max-width 48 rem, centred)      │                         │
│ project group│                                             │                         │
│  thread card │                                             │                         │
│  …           │  ┌ composer (floating, 16 px inset) ─────┐ │                         │
│ settings ⑂ ⫶ │  └ git line: checkout · branch ▾ ───────┘ │                         │
└──────────────┴───────────────────────────────────────────┴─────────────────────────┘
```

Every dimension is a token from §3.1; the sidebar collapses to the 3 rem
icon rail (`SIDEBAR_WIDTH_ICON`) with ⌘B like T3. The right panel is a
frame in B (tab strip + empty states); its tabs fill in E (Diff, Files,
Pull request) and F (Terminal, Agents = subagents from `task.*`
activities; Browser is out of scope, hidden by capability).

### 4.3 State

`T3WindowModel` (`@MainActor`, `@Observable`) over `AppModel`: projects
(§2.1), sessions with facts, attention overlays, the selected thread
(`sessionId`, not pid), sidebar scope/search, expanded turns/groups,
composer drafts per thread (persisted in `UserDefaults` like
`composerPromptHistory.ts`, last 50), right-panel tab per thread. Timeline
per thread comes from `TimelineCache` directly (no HTTP on the Mac),
refreshed on the same `SessionFeedReader.waitForChange` wake the chat
window uses. Sends go through `SessionInput.deliver` with a `commandId`.
Starting a thread goes through `SessionStart` (owned when the engine
supports it, else terminal — gated on capabilities). Attention actions
go through `AttentionStore` so the phone sees them.

### 4.4 Screens in B

- Sidebar with project groups, thread cards (title, status glyph, relative
  time, unseen dot), pinned/active/snoozed/settled sections, context menu
  (pin, settle, snooze presets, archive = park, rename), search filter,
  scope picker (All projects / one project), new-thread button (opens a
  draft in the current project like `_chat.draft.$draftId.tsx`).
- Thread view: breadcrumb, timeline rows per §3.5 with T3's markdown
  styling (`ChatMarkdown.tsx` rules → `MarkdownText` extensions: code
  fences with copy, tables, task lists), user message surface
  (`--message-surface`), assistant meta row (time, copy, turn diff stat
  — the stat comes in E), turn folds ("Worked for 2m 14s"), work groups
  with the toggle summary, proposed-plan card (approve → `SessionInput`
  answers the parked ExitPlanMode; edit → text in the composer), pending
  approval panel and user-input panel above the composer
  (`ComposerPendingApprovalPanel.tsx`, `ComposerPendingUserInputPanel.tsx`),
  thread error banner, usage-limit banner (`ComposerUsageLimits.tsx`
  over `LimitNote`), working / thinking rows.
- Composer: multiline prompt (⏎ send, ⇧⏎ newline), `/` command menu from
  `~/.claude/commands` + skills, `@` file mention (fuzzy over the project
  via `git ls-files`), attachments (drop, paste, picker → images to the
  owned session per #151, files to the terminal path), model picker
  (from `model-manifest` names the engine reports; falls back to the
  current session's model), effort picker (low/medium/high/max where the
  engine supports `effort`), permission picker (the four modes +
  "Ask every time"), send/stop button, queued-message badge (a send
  while running queues; T3's steer-vs-queue is E).
- Top bar actions: "Add action" (project scripts — placeholder menu in B,
  real in D), "Open" (Finder / Terminal / VS Code / Cursor like
  `OpenInPicker.tsx`), "Commit & push" (disabled with T3's tooltip until E),
  right-panel toggle, sidebar toggle.
- Empty states: no projects hero (`NoProjectsHero.tsx`), no active thread
  (`NoActiveThreadState.tsx`), draft hero headline (`DraftHeroHeadline.tsx`).
- Keyboard: ⌘N new thread, ⌘⇧N new in project, ⌘B sidebar, ⌘J right
  panel, ⌘[ / ⌘] previous/next thread, ⌘K command palette (B ships a
  thread switcher only; the full palette is D).

### 4.5 Performance

Idle with the window open: no timers. Relative times update on a 60 s
`Timer` only while the window is key. The working row's shimmer is a
`LayerEffect`. Timeline rows are `LazyVStack` inside a `ScrollView` with
stable ids (the live slot id never changes), scroll anchoring like
`timelineScrollAnchoring.ts` (stay pinned to the end while at the end;
preserve the top row on disclosure toggles). Markdown is rendered once per
message id and cached. `infinitusctl perf` twice, 15 s apart, with the
window open must stay under 1 %.

### 4.6 Testing (B)

Reducer tests (A). View tests: `T3WindowModel` unit tests with a fake
`AppModel` seam (projects derivation, selection survives a pid change on
resume, drafts persist). e2e (`tools/e2e.sh`): open the window through
`infinitusctl t3 open`, assert the perf gate, capture the fixture screens
and run `compare.py` against the refs, printing the numbers into the PR.

## 5. Sub-project C — the phone (`ios/InfinitusMobile/T3/`)

### 5.1 Navigation

One `NavigationStack` + sheets mirroring `Stack.tsx` routes 1:1 (names
kept, so deep links and the harness share vocabulary):

| T3 route | Screen | Presentation |
|---|---|---|
| `` (Home) | `T3HomeScreen` | root |
| `threads/:env/:thread` | `T3ThreadScreen` | push |
| `…/git` | `T3GitSheet` | form sheet 0.55 / 0.7 |
| `…/git/commit`, `…/git/branches`, `…/git-confirm` | E | sheet |
| `…/review`, `…/review-comment` | E (`T3ReviewDiffView` port) | push / sheet |
| `…/files`, `…/files/:path*` | E | push |
| `…/terminal` | F (SwiftTerm) | push |
| `new`, `draft`, `draft/environment`, `draft/branch`, `draft/settings` | `T3NewTaskSheet` (+ pickers) | form sheet 0.6 / 0.95 |
| `settings`, `settings/*` | D (`T3SettingsSheet`) | form sheet |
| `environments`, `connections`, `connections/new` | D | sheet |
| `add-project/*` | D | sheet |
| `archive`, `usage` | D / F | push |

Infinitus deep links (`infinitus://…`) keep their current paths; the T3
paths are internal names, not a public scheme.

### 5.2 Screens in C

- **Home**: `T3 Code`-style header (Infinitus wordmark in the same type
  and layout, environment badge instead of DEV), project group headers
  (folder glyph, name, relative time on the right), thread rows
  (title, status glyph at trailing edge — the coral asterisk is
  "working"), pinned/active/snoozed/settled shelves with the shelf
  headers and "Show more" paging, swipe actions (settle/unsettle, snooze,
  archive = park), long-press menu, bottom pill bar (filter menu, search
  field, compose). Empty state "No environments connected / Add
  environment" becomes "No Macs paired / Pair a Mac" (same type, same
  button). Data: `MirrorModel` rows + facts + attention (all exist).
- **Thread**: header title + `project · Mac` subtitle, header pills
  (terminal, files, thread settings), feed rows from `T3TimelineRows`:
  blue user bubble (`userBubble`, radius 20, trailing), assistant text
  (plain, `mdBody`), timestamps + copy glyphs, work groups and toggles,
  turn folds, proposed-plan card, pending approval card
  (`PendingApprovalCard.tsx`) and user-input card
  (`PendingUserInputCard.tsx`, multi-question with one Send — #330),
  floating working control (`floating-working-control.tsx`: "Working…"
  pill with stop), live-follow rule (`thread-feed-live-follow.ts`).
  Composer: `+` (attachments: photos, camera, files, screenshots —
  existing pickers), text field "Ask the repo agent, or run a command…",
  `/` command popover, send/stop, usage-limit strip. Data: the existing
  `/tail` long-poll rows are replaced by the `/timeline` route (#223 phase
  4 — the poller that was deliberately left unbuilt lands here, with the
  tombstone / snapshot-authoritative rules from the #223 note).
- **New Task**: "Choose project" list (favicon, name, path, `+` add),
  draft screen (title-less prompt hero, environment row, branch row,
  settings row → model / effort / permission / worktree toggle), start →
  `POST /sessions/start` with `commandId`.
- **Thread settings sheet**: title regenerate, model, permission mode,
  archive/delete-equivalents mapped to park/stop.
- **Git sheet** (shell only in C: branch title + the five rows with
  their subtitles from git facts; the actions light up in E).

### 5.3 Native module ports

- `t3-composer-editor/ios/T3ComposerEditorView.swift` (UITextView with
  inline chips) → `ios/InfinitusMobile/T3/Native/T3ComposerEditor.swift`,
  UIViewRepresentable, verbatim where the RN bridge isn't involved.
- `t3-review-diff/ios/T3ReviewDiffView.swift` (2.7 k lines) → E.
- `t3-native-controls` (keyboard commands, file/video presentation) →
  C, the presentation parts only.
- `t3-terminal` → F on SwiftTerm (decision above); the view chrome
  (header "Terminal / project", keyboard accessory) is ported, the
  emulator is not.
- `t3-markdown-text` (ObjC++ TextKit) → C, reimplemented over
  `MarkdownText` with the same run styles (`md*` tokens).

### 5.4 What is removed on the phone

`SessionsScreen`, `SessionFeedScreen`, `SessionDetailScreen`,
`StartSessionSheet`, `PastSessionsScreen`, `FleetScreen` / `NativeFleetScreen`
(fleet stats fold into Usage in F), `OutlookScreen` (Usage in F). Kept:
pairing (`PairScanner`, `MacPairing`), Live Activities, share sheet,
widgets, Team screens (no T3 equivalent; they move under Settings ›
Team), AWS login (a banner + sheet, restyled with the kit), and — the
user asked for these earlier and has not agreed to lose them — the RPG
row themes (`ThemeChooserScreen`, `MotionChooser`) under Appearance ›
"Infinitus theme", and the #329 chat-header HUD behind its `chat_header`
pref (off by default in the T3 look). Removal is the last PR of C, after
every replacement screen is on main behind a `t3Screens` flag that
defaults on.

### 5.5 Testing (C)

Reducer tests (A). `ios` CI job builds and runs the unit tests; UI tests
navigate every route and attach screenshots; the harness compares the
fixture screens.

## 6. Data-flow notes

- The Mac window reads local models; the phone reads the mirror. Both
  render through the same reducers, so a row that looks wrong on one
  platform is a reducer bug, not a platform bug.
- Attention (pin / settle / snooze) is host state; both clients post and
  re-read, never keep a private copy.
- Sends are idempotent by `commandId`; a queued send while a turn runs is
  shown as T3's queued-message icon and delivered when the turn ends.
- Owned sessions carry the full T3 feature set (plans, questions, images,
  interrupt); terminal-hosted sessions render the same rows but the
  composer disables what the capability descriptor says is missing.

## 7. Error handling

Wire errors surface as T3 does: a thread error banner (dismiss per
session), a provider status banner when the engine is down ("Claude Code
is not running" with the start action), the environment connection dot
in the sidebar/home header, and toasts for failed commands (T3 `toast.tsx`
logic: stacked thread toasts, 5 s, hover holds). Nothing swallows an
error into a log only.

## 8. Order of work and PR plan

A (Infi4): tokens generator + theme, typography + fonts, icons, component
kit (two PRs: web set, mobile set), reducers (one PR per module, tests
included), harness. ~7 PRs, each `size:M` or smaller.

B (Infi4, after A's tokens + reducers): shell + sidebar, thread view +
composer, panels/empty states/keyboard, e2e + parity. ~4 PRs.

C (Infi3, after A's tokens + reducers): home, thread + composer (+
timeline poller), new task + settings shell, native ports, removal. ~5 PRs.

Infi rebuilds Mac + phone after each merge that touches a screen. The
parity numbers go in every PR description; the first PR of B and C posts
the before/after captures on #223.

## 9. Interfaces fixed now for D, E, F

- D: `T3SettingsSheet` / Mac `settings.*` routes render `SettingsSyncModel`
  sections; projects list = §2.1 `ProjectSummary` (+ scripts, favicon).
- E: `GET /sessions/{pid}/git` (branch, dirty, ahead/behind, remote,
  PR), `POST /sessions/{pid}/git/{commit|push|pull|pr}` with `commandId`,
  `GET /sessions/{pid}/diff?scope=turn|worktree|base&turn=` returning
  `Checkpoints`' unified diff; the right-panel Diff tab and
  `T3ReviewDiffView` consume it. Turn diff stat on assistant meta rows
  reads the same route.
- F: `POST /sessions/{pid}/terminal` (PTY over the mirror, ticket-in-URL
  WebSocket like T3's `terminal` channel — the one place a socket earns
  its keep), SwiftTerm on both; Usage = `Stats` over T3's usage screen;
  Pull requests = `gh pr list --json` per project.
- The old feed (`SessionFeedItem`, `/tail`) stays until the browser page
  moves to `/timeline`; then it is removed in its own PR.
