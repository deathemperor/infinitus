# T3 Clone — Sub-project B (the Mac window) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A T3 Code–identical workspace window on the Mac — sidebar, thread timeline, composer, top bar, empty states, keyboard — over Infinitus's own session data, opened from the popup, `infinitusctl show workspace`, and ⌘⇧T.

**Architecture:** One `NSWindow` held by `T3WindowController` (the `WallWindowController` shape: bare window + `NSHostingController`, `sizingOptions = []`, content detached on close). `T3WindowModel` (`@MainActor final class: ObservableObject`) bridges `AppModel` to the A reducers: `SessionFacts` → `T3Thread` (new `T3ThreadBridge`), `TimelineCache` → `T3TimelineEntry.entries(from:pending:)` → `T3TimelineRows`, `ProjectSummary` → `T3ProjectGrouping.Project`. Views under `Sources/Infinitus/T3Window/` render the A component kit with `T3Environment(platform: .web)`. No new policy: sends go through `AppModel.deliverSessionInput`, starts through `AppModel.startSession`, attention through `SessionAttention.apply` via one new `AppModel.applyAttention`.

**Tech Stack:** Swift 6 / SwiftUI / AppKit (macOS 14+), SwiftPM, XCTest; A's `InfinitusCore/T3` reducers and `InfinitusUI/T3` kit; upstream T3 Code checkout at `~/death/t3code` (`acc0a219e`) for transcription.

**Spec:** `docs/superpowers/specs/2026-09-08-t3-client-clone-design.md` §4 (B), with §2 (data), §3 (A's kit), §7 (harness), and the Naming rule.

## Global Constraints

- **Naming (spec, user decision #345):** nothing user-visible says "T3" — the popup item is **"Open workspace"**, the control verb is `show workspace [sidebar|thread|composer]`, the window title is the constant "Infinitus" (`titleVisibility = .hidden` never shows it; the breadcrumb carries the thread name). `T3` stays in type names, file names, and comments only.
- **Infinitus is never tied to cswap**; every engine touchpoint is a `cswap … --json` subprocess; never read engine internals. Reading `~/.claude/*` is fine.
- **Account policy lives in the engines** — the window sets no policy of its own.
- **Idle CPU ≈ 0 % with the window open** (`infinitusctl perf` twice, 15 s apart; `tools/e2e.sh` gates ≤ 1 %). No `TimelineView`, no `repeatForever` `.animation`, no `Timer` while idle except the 60 s relative-time tick **while the window is key**. Continuous motion only through `LayerEffect` hosts (`T3Spinner`, `T3Skeleton`, `T3LoadingStrip`). Never `.contentTransition(.numericText)` on anything that ticks.
- **Never let `NSHostingView` size the window** (`host.sizingOptions = []`); detach `contentViewController` before `orderOut`; reuse the one `NSWindow`.
- **Core stays Linux-clean**: `Sources/InfinitusCore/**` imports Foundation only (no SwiftUI/AppKit/UIKit/CoreGraphics). UI code under `Sources/Infinitus/T3Window/` is macOS-only (the `Infinitus` target already is).
- **Gate UI on capabilities, never on engine identity**: owned-session affordances (image attachments, approval verdicts, permission-mode change) show only when `OwnedWire.supportsOwnedSessions(version:)` is true for the session's host; terminal sessions get the key/text path.
- **Upstream wins over brief prose.** When the T3 source (`~/death/t3code/apps/web/src/…`) contradicts a value written in a task, use upstream and say so in the report. Every visible dimension/colour is a token from `T3Theme.webLight/webDark` or `T3Theme.Metrics`, never a literal — unless T3 itself uses a literal class (`text-[13px]`), in which case `T3Font.webLiteral`.
- **Dev instances** run with `INFINITUS_CONTROL_SOCKET=/tmp/<short>.sock` (`tools/t3ref/fixture.sh` sets `/tmp/t3fix.sock`).
- **Secrets never on argv**; no new network; usage figures are estimates.
- **Repo flow:** branch + PR, required checks `test`, `e2e`, `linux`, `ios` (never `windows`), `gh pr merge --squash --auto`; every commit carries `Co-Authored-By: Claude Code <noreply@anthropic.com>` (the `tools/githooks/prepare-commit-msg` hook; `git config core.hooksPath tools/githooks` once per clone). Todos → GitHub issues, never files. CHANGELOG bullets are one line.
- **Tests run with `swift test --filter <Suite>`** for the task's suites; the full suite (`swift test`) at PR time. Known flake #365 (`OwnedSessionsProcessTests/testDeliverRoutesMessageKeyApproveAndEscape` under `--parallel`) is not yours.
- **Two Claude sessions share this repo**: work only in this worktree; stage by explicit path; never touch `../limitless-e2` or `~/death/limitless`.

## Deviations from spec §4 (ruled here, disclosed to the user)

| Spec §4 says | Plan does | Why |
|---|---|---|
| `T3WindowController: NSWindowController` | plain `@MainActor final class T3WindowController` holding an `NSWindow` | The codebase has zero `NSWindowController`s; `WallWindowController`/`SessionChatWindows` are the shell pattern, with the detach-on-close rule already encoded. |
| `T3WindowModel` is `@Observable` | `ObservableObject` + `@Published` | Every model in `Sources/Infinitus` is `ObservableObject`; `AppModel` is consumed via `@ObservedObject`. Mixing frameworks buys nothing. |
| §4.6 "`T3WindowModel` unit tests with a fake `AppModel` seam" | the state lives in Core as `T3WorkspaceState` (pure, tested in `InfinitusCoreTests`); `T3WindowModel` is a thin publisher over it | `Package.swift` has one test target and it depends on Core only; a fake-`AppModel` seam would need a new macOS test target for a class that is otherwise glue. |
| §4.5 "relative times update on a 60 s `Timer` only while the window is key" | kept, plus `model.now` is the only clock views read | same behaviour; the rule "views never call `Date()`" makes the tick auditable. |
| context menu "archive = park, rename" | hidden in B (no host API for either; `ParkedCache` is the phone's offline cache) | Filed as follow-ups; the menu shows pin / settle / snooze / unsnooze only. |
| composer model picker "from `model-manifest`", effort picker | model picker shows the session's current model read-only; effort picker absent | No engine reports a manifest or accepts `effort`; both are engine knobs (upstream PR territory, never app policy). |
| composer `/` commands "from `~/.claude/commands` + skills" | new `SlashCommands.discover(cwd:home:)` in Core reading `~/.claude/commands/**/*.md`, `<cwd>/.claude/commands/**/*.md`, and `~/.claude/skills/*/SKILL.md` + `<cwd>/.claude/skills/*/SKILL.md` | No host API existed; the discovery is pure file reading (Claude Code's own files are fair game). |
| thread view "approve → answers the parked ExitPlanMode" | approve/deny go through `SessionInput.Request(kind: .approve/.key …)` like the chat window; the plan card renders when `T3TimelineRows` yields `.proposedPlan` (no Infinitus producer yet — A's documented gap) | Same wire as the phone; a producer is E's `Message.updatedAt`-class builder work, not B's. |

## File Structure

```
Sources/InfinitusCore/
  SessionTimeline.swift                 (modify) Message.updatedAt
  SessionTimelineBuilder.swift          (modify) updatedAt on merge; payload command/toolCallId
  T3/T3TimelineEntry.swift              (modify) init(message:) uses updatedAt
  T3/T3ThreadBridge.swift               (create) T3Thread(record:facts:progress:startedAt:now:), Project(summary:)
  SlashCommands.swift                   (create) command/skill discovery
  T3/T3WorkspaceState.swift             (create) the window's pure state reducer
  T3/T3TimelineInput.swift              (create) SessionTimeline → T3TimelineRows.Input
  T3/T3RelativeTime.swift               (create) T3's relative-time labels
  T3/T3ComposerDraft.swift              (create) drafts, prompt history, send verdict
  T3/T3FileMention.swift, T3/T3ComposerTrigger.swift (create) @-file ranking, / and @ trigger detection
  MarkdownBlocks.swift                  (create) block parser moved out of MarkdownText (+ tables, tasks)
  ControlProtocol.swift                 (modify) show workspace [screen], hide workspace
Sources/Infinitus/
  AppModel.swift                        (modify) showWorkspace hook, applyAttention, uiSurface("workspace")
  ControlServer.swift                   (modify) show workspace [screen]
  StatusItemController.swift            (modify) lazy workspace controller, wiring, toggleWorkspace(screen:)
  MacSessionsPopover.swift              (modify) "Open workspace" row
  InfinitusApp.swift                    (modify) ⌘⇧T hidden button
  T3Window/T3WindowController.swift     (create) shell
  T3Window/T3WindowModel.swift          (create) state over AppModel
  T3Window/T3TimelineStore.swift        (create) per-thread long-poll store
  T3Window/T3Root.swift                 (create) layout: sidebar | topbar+timeline+composer | right panel
  T3Window/T3SidebarView.swift          (create) sidebar
  T3Window/T3ThreadRowView.swift        (create) one sidebar thread card + context menu
  T3Window/T3TopBar.swift               (create) breadcrumb + actions
  T3Window/T3ThreadView.swift           (create) timeline scroll + banners + panels
  T3Window/T3TimelineRowViews.swift     (create) one view per T3TimelineRows.Row case
  T3Window/T3ComposerView.swift         (create) composer
  T3Window/T3ComposerMenus.swift        (create) / command menu, @ mention menu
  T3Window/T3PendingPanels.swift        (create) approval + user-input panels, banners
  T3Window/T3EmptyStates.swift          (create) no projects / no thread / draft hero
  T3Window/T3RightPanel.swift           (create) tab strip frame + empty states
  T3Window/T3ThreadSwitcher.swift       (create) ⌘K
Sources/InfinitusUI/
  MarkdownText.swift                    (modify) tables, task lists, fence copy affordance seam
  T3/Components/T3ChatMarkdown.swift    (create) T3's ChatMarkdown styling over MarkdownText blocks
Tests/InfinitusCoreTests/                (the only test target — Package.swift; UI/app code is exercised by the fixture smoke + e2e)
  SessionTimelineBuilderTests.swift     (modify) updatedAt, command, toolCallId
  T3/T3ThreadBridgeTests.swift, T3/T3WorkspaceStateTests.swift, T3/T3TimelineInputTests.swift,
  T3/T3RelativeTimeTests.swift, T3/T3ComposerDraftTests.swift, T3/T3FileMentionTests.swift,
  T3/T3ComposerTriggerTests.swift, SlashCommandsTests.swift, MarkdownBlocksTests.swift (create)
  ControlProtocolTests.swift            (modify) show/hide args
tools/e2e.sh                            (modify) show workspace + perf gate with the window open
tools/t3ref/capture-mac.sh              (modify) settle sleep; refs/PROVENANCE.md Mac recipe
tools/t3ref/refs/mac-*.png              (create, PR-time) Mac references
CHANGELOG.md                            (modify) one line per PR
```

## PR stacking

Five stacked PRs, each `--squash --auto` behind `test`/`e2e`/`linux`/`ios`:

| PR | Tasks | Branch | Touches host files Infi must know about |
|---|---|---|---|
| B-1 bridge | 1, 2, 3 | `t3-clone-b1` | none (Core only) |
| B-2 shell | 4, 5 | `t3-clone-b2` | AppModel, ControlServer, ControlProtocol, StatusItemController, MacSessionsPopover, InfinitusApp — **flag to Infi before opening** |
| B-3 sidebar + layout | 6, 7, 8 | `t3-clone-b3` | none |
| B-4 thread view | 9, 10, 11, 12 | `t3-clone-b4` | MarkdownText (shared with the phone — Infi3 informed) |
| B-5 composer + polish | 13, 14, 15, 16 | `t3-clone-b5` | e2e.sh |

Each later branch is stacked on the previous; after a squash merge, `git rebase --onto origin/main <old-base> <branch>`.

---

### Task 1: `Message.updatedAt` and the builder's `command` / `toolCallId` payload keys

**Files:**
- Modify: `Sources/InfinitusCore/SessionTimeline.swift:53-67` (Message)
- Modify: `Sources/InfinitusCore/SessionTimelineBuilder.swift:122-126, 208-212, 315-326, 375-385`
- Modify: `Sources/InfinitusCore/T3/T3TimelineEntry.swift:137-147`
- Test: `Tests/InfinitusCoreTests/SessionTimelineBuilderTests.swift`, `Tests/InfinitusCoreTests/T3/T3TimelineEntryTests.swift`

**Interfaces:**
- Consumes: `SessionTimeline.Message` (A), `T3TimelineEntry.init(message:)` (A).
- Produces: `SessionTimeline.Message.updatedAt: Date` (Codable, optional on decode → `createdAt`); `tool.started` payload keys `command` (Bash only) and `toolCallId`; `tool.completed` payload `toolCallId`. `T3ChatMessage.updatedAt` now honours it.

Why: A's `T3TimelineEntry.init(message:)` documents the divergence "no `updatedAt`, so a turn fold ends at the assistant message's start". T3's `MessagesTimeline.logic.ts` measures folds to `updatedAt`. The upstream work-log (`T3WorkLog`) reads `payload.command` for Bash labels and `toolCallId` to pair started/completed — the builder never emitted either (A's ledger, Task 8).

- [ ] **Step 1: Failing tests**

Append to `Tests/InfinitusCoreTests/SessionTimelineBuilderTests.swift` (inside the existing test class; use its existing `build(_ lines: [String])` / fixture helper — read the file first and adapt the helper name):

```swift
    func testAssistantMessageUpdatedAtAdvancesWithStreamedBlocks() throws {
        let t = try build([
            user("u1", "Hi", at: 1_000),
            assistantText("a1", "One", at: 2_000),
            assistantText("a2", "Two", at: 5_000),
        ])
        let m = try XCTUnwrap(t.messages.first { $0.role == .assistant })
        XCTAssertEqual(m.createdAt, Date(timeIntervalSince1970: 2))
        XCTAssertEqual(m.updatedAt, Date(timeIntervalSince1970: 5))
        XCTAssertEqual(m.text, "One\n\nTwo")
    }

    func testUserMessageUpdatedAtEqualsCreatedAt() throws {
        let t = try build([user("u1", "Hi", at: 1_000)])
        let m = try XCTUnwrap(t.messages.first)
        XCTAssertEqual(m.updatedAt, m.createdAt)
    }

    func testMessageDecodesWithoutUpdatedAt() throws {
        let json = """
        {"id":"m","role":"user","text":"x","turnId":"t","streaming":false,"createdAt":"2026-01-01T00:00:00Z"}
        """
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let m = try d.decode(SessionTimeline.Message.self, from: Data(json.utf8))
        XCTAssertEqual(m.updatedAt, m.createdAt)
    }

    func testBashToolStartedCarriesCommandAndToolCallId() throws {
        let t = try build([
            user("u1", "run", at: 1_000),
            toolUse("tu1", name: "Bash", input: ["command": "ls -la", "description": "list"], at: 2_000),
            toolResult("tu1", "a\nb", at: 3_000),
        ])
        let started = try XCTUnwrap(t.activities.first { $0.kind == "tool.started" })
        XCTAssertEqual(started.payload["command"]?.stringValue, "ls -la")
        XCTAssertEqual(started.payload["toolCallId"]?.stringValue, "tu1")
        let completed = try XCTUnwrap(t.activities.first { $0.kind == "tool.completed" })
        XCTAssertEqual(completed.payload["toolCallId"]?.stringValue, "tu1")
        XCTAssertEqual(completed.payload["command"]?.stringValue, "ls -la")
    }

    func testNonBashToolStartedHasNoCommandKey() throws {
        let t = try build([
            user("u1", "read", at: 1_000),
            toolUse("tu2", name: "Read", input: ["file_path": "/a/b.swift"], at: 2_000),
        ])
        let started = try XCTUnwrap(t.activities.first { $0.kind == "tool.started" })
        XCTAssertNil(started.payload["command"])
        XCTAssertEqual(started.payload["toolCallId"]?.stringValue, "tu2")
    }
```

If the test file has no `user/assistantText/toolUse/toolResult` line builders, add them as private helpers producing Claude Code transcript JSONL lines (`{"type":"user","uuid":…,"timestamp":…,"message":{"role":"user","content":"…"}}`, `{"type":"assistant",…,"message":{"content":[{"type":"text","text":…}]}}`, `{"type":"assistant",…,"content":[{"type":"tool_use","id":…,"name":…,"input":…}]}`, `{"type":"user",…,"content":[{"type":"tool_result","tool_use_id":…,"content":…}]}`) — copy the shapes from the existing fixtures in that file; `at:` is epoch milliseconds → ISO8601 `timestamp`.

In `Tests/InfinitusCoreTests/T3/T3TimelineEntryTests.swift` add:

```swift
    func testChatMessageUpdatedAtComesFromMessage() {
        let m = SessionTimeline.Message(id: "a", role: .assistant, text: "x", images: nil, sender: nil,
                                        turnId: "t", streaming: false,
                                        createdAt: Date(timeIntervalSince1970: 10),
                                        updatedAt: Date(timeIntervalSince1970: 40))
        let c = T3ChatMessage(message: m)
        XCTAssertEqual(c.createdAt, Date(timeIntervalSince1970: 10))
        XCTAssertEqual(c.updatedAt, Date(timeIntervalSince1970: 40))
    }
```

- [ ] **Step 2: Run, expect compile failure** (`updatedAt` label unknown)

```bash
swift test --filter 'SessionTimelineBuilderTests|T3TimelineEntryTests' 2>&1 | tail -20
```

- [ ] **Step 3: Implement**

`SessionTimeline.swift` — replace the `Message` struct:

```swift
    public struct Message: Codable, Sendable, Equatable {
        public enum Role: String, Codable, Sendable { case user, assistant }
        public let id: String
        public let role: Role
        public let text: String
        public let images: [String]?
        public let sender: String?
        public let turnId: String
        public let streaming: Bool
        public let createdAt: Date
        /// Last streamed block's time (T3 `updatedAt`); equals `createdAt`
        /// for user messages and single-block replies.
        public let updatedAt: Date
        public init(id: String, role: Role, text: String, images: [String]?, sender: String?,
                    turnId: String, streaming: Bool, createdAt: Date, updatedAt: Date? = nil) {
            self.id = id; self.role = role; self.text = text; self.images = images; self.sender = sender
            self.turnId = turnId; self.streaming = streaming; self.createdAt = createdAt
            self.updatedAt = updatedAt ?? createdAt
        }

        enum CodingKeys: String, CodingKey { case id, role, text, images, sender, turnId, streaming, createdAt, updatedAt }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            role = try c.decode(Role.self, forKey: .role)
            text = try c.decode(String.self, forKey: .text)
            images = try c.decodeIfPresent([String].self, forKey: .images)
            sender = try c.decodeIfPresent(String.self, forKey: .sender)
            turnId = try c.decode(String.self, forKey: .turnId)
            streaming = try c.decode(Bool.self, forKey: .streaming)
            createdAt = try c.decode(Date.self, forKey: .createdAt)
            updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        }
    }
```

(Encoding stays synthesized — `updatedAt` is always written; the phone decodes it or ignores it.)

`SessionTimelineBuilder.swift`:
- `appendAssistantText` merge branch (≈:318-322): pass `updatedAt: at` when rebuilding the merged message (`createdAt: m.createdAt, updatedAt: at`).
- The streaming rewrite (≈:381-382): carry `updatedAt: m.updatedAt`.
- `tool.started` (≈:208-212): after `var payload…`, add
  ```swift
            payload["toolCallId"] = .string(id)
            if let command { payload["command"] = .string(command) }
  ```
- `tool.completed` (≈:262-264): add `payload["toolCallId"] = .string(toolUseId)` and `if let c = open.command { payload["command"] = .string(c) }`.

`T3TimelineEntry.swift:137-147` — replace the divergence comment and init:

```swift
    /// `updatedAt` is the message's last streamed block (Task B-1); a turn
    /// fold measured from timestamps ends at the reply's last token.
    public init(message m: SessionTimeline.Message) {
        let turn = m.turnId.isEmpty ? nil : m.turnId
        self.init(id: m.id, role: m.role == .user ? .user : .assistant, text: m.text,
                  turnId: m.role == .user ? nil : turn, streaming: m.streaming,
                  createdAt: m.createdAt, updatedAt: m.updatedAt)
    }
```

- [ ] **Step 4: Run the two suites, then every Core suite that decodes timelines**

```bash
swift test --filter 'SessionTimelineBuilderTests|T3TimelineEntryTests|SessionTimelineTests|T3TimelineRowsTests|SessionFactsTests|ThreadFeedPresentationTests' 2>&1 | tail -5
```
Expected: all pass. If a fixture JSON in `Tests/InfinitusCoreTests/Fixtures` compares encoded output byte-for-byte, regenerate it and say so in the report.

- [ ] **Step 5: Commit**

```bash
git add Sources/InfinitusCore/SessionTimeline.swift Sources/InfinitusCore/SessionTimelineBuilder.swift Sources/InfinitusCore/T3/T3TimelineEntry.swift Tests/InfinitusCoreTests/SessionTimelineBuilderTests.swift Tests/InfinitusCoreTests/T3/T3TimelineEntryTests.swift
git commit -m "timeline: messages carry updatedAt; tool activities carry command and toolCallId (T3 clone B-1)"
```

---

### Task 2: `T3ThreadBridge` — `SessionFacts` + record → `T3Thread`

**Files:**
- Create: `Sources/InfinitusCore/T3/T3ThreadBridge.swift`
- Test: `Tests/InfinitusCoreTests/T3/T3ThreadBridgeTests.swift`

**Interfaces:**
- Consumes: `T3Thread` (A), `SessionFacts` (`Sources/InfinitusCore/SessionFacts.swift:8-33`), `ClaudeSessionRecord` (`ClaudeSessions.swift:9-29`), `SessionProgress` (`SessionProgress.swift:6`: `title`, `goal`, `lastActivityAt`), `SessionNaming.displayName(name:autoName:cwd:)`, `ProjectSummary.projectId(cwd:)`, `T3ThreadStatus`.
- Produces:
  ```swift
  extension T3Thread {
      public static let localEnvironmentId = "local"
      public init(record: ClaudeSessionRecord, facts: SessionFacts,
                  progress: SessionProgress?, startedAt: Date?, now: Date)
      /// The phone's rows (team mirror): no record, facts optional until the lease answers.
      public init(session: SessionDetail, facts: SessionFacts?, progress: SessionProgress?,
                  environmentId: String, now: Date)
  }
  extension T3ProjectGrouping.Project {
      public init(summary: ProjectSummary, environmentId: String = T3Thread.localEnvironmentId)
      // id: summary.id, name: summary.name, cwd: summary.cwd
  }
  ```
  `id = record.sessionId`, `environmentId = "local"`, `projectId = ProjectSummary.projectId(cwd: record.cwd)`, `title = SessionNaming.displayName(name: record.name, autoName: progress?.autoName, cwd: record.cwd)` (`SessionProgress.autoName` is the Haiku name, `SessionProgress.swift:51`), `createdAt = startedAt ?? facts.latestTurn?.requestedAt ?? record.statusUpdatedAt ?? now`, `updatedAt = max(progress?.lastActivityAt, record.statusUpdatedAt, facts.latestTurn?.completedAt ?? facts.latestTurn?.startedAt ?? facts.latestTurn?.requestedAt, createdAt)`, `session = .init(status: SessionStatus(facts.status), updatedAt: record.statusUpdatedAt ?? updatedAt)` (the A close-out's converters `T3Thread.SessionStatus.init(_: SessionFacts.Status)` / `T3Thread.Turn.State.init(_: SessionTimeline.Turn.State)` — never rawValue), `latestTurn` mapped field-by-field, **`settledOverride = SessionListPresentation.isSettled(facts) ? .settled : .active`** (Infinitus auto-settles through `settledAt`/`unsettledAt` with no override, and `T3ThreadList` reads only the override — the phone's `T3HomeThreads` already maps this way, and both clients must place a thread in the same section), the other attention fields copied 1:1 (`settledAt`, `unsettledAt`, `snoozedUntil`, `snoozedAt`, `pinnedAt`), `hasPendingApprovals`/`hasPendingUserInput` copied, `hasActionableProposedPlan = false` (no producer in B), `latestUserMessageAt` copied, `archivedAt = nil`, `pinOrderKey`/`activeOrderKey` nil, `lastVisitedAt = nil` (the window model owns visits).

  The mirror-side overload (`SessionDetail` is `Models.swift:73`: `pid`, `cwd`, `status` engine word, `kind`, `startedAt` epoch-ms) shares one private helper with the record init. Differences: `id = "pid:\(session.pid)"` when facts are nil, else `facts.sessionId` if `SessionFacts` carries one (read `SessionFacts.swift:8-33`; if it does not, use the pid form for both and say so in the report), `environmentId` = the argument, `createdAt = Date(timeIntervalSince1970: session.startedAt / 1000)`, `title = SessionNaming.displayName(name: progress?.name, autoName: progress?.autoName, cwd: session.cwd)`. **Facts nil**: `session.status = .init(status: session.status == "busy" ? .running : .idle, updatedAt: createdAt)`, `hasPendingApprovals = (session.status == "waiting")`, `hasPendingUserInput = false`, `settledOverride = nil`, `latestTurn = nil`, `latestUserMessageAt = nil`. **Facts present**: identical to the record path (status from `SessionStatus(facts.status)`, settled from `isSettled`). Lift the two phone tests for these rules from `ios/InfinitusMobileTests/T3HomeTests.swift` (the `facts nil → engine word` case and the `isSettled → .settled` case) into `T3ThreadBridgeTests` verbatim, adapted to the new signature.

- [ ] **Step 1: Failing tests** — `Tests/InfinitusCoreTests/T3/T3ThreadBridgeTests.swift`:

```swift
import XCTest
@testable import InfinitusCore

final class T3ThreadBridgeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private func record(_ status: String? = "idle", name: String? = nil, statusAt: Date? = nil) -> ClaudeSessionRecord {
        ClaudeSessionRecord(pid: 42, sessionId: "sess-1", cwd: "/Users/me/death/limitless", status: status,
                            name: name, statusUpdatedAt: statusAt)
    }
    private func facts(status: SessionFacts.Status = .ready, approvals: Bool = false, input: Bool = false,
                       turn: SessionTimeline.Turn? = nil, pinnedAt: Date? = nil,
                       settled: AttentionStore.SettledOverride? = nil, snoozedUntil: Date? = nil) -> SessionFacts {
        SessionFacts(status: status, hasPendingApprovals: approvals, hasPendingUserInput: input, hasPlan: false,
                     latestTurn: turn, planProgress: nil, latestUserMessageAt: turn?.requestedAt,
                     settledOverride: settled, settledAt: settled == .settled ? now : nil, unsettledAt: nil,
                     snoozedUntil: snoozedUntil, snoozedAt: snoozedUntil == nil ? nil : now, pinnedAt: pinnedAt)
    }

    func testIdentityAndProject() {
        let t = T3Thread(record: record(), facts: facts(), progress: nil, startedAt: nil, now: now)
        XCTAssertEqual(t.id, "sess-1")
        XCTAssertEqual(t.environmentId, T3Thread.localEnvironmentId)
        XCTAssertEqual(t.projectId, ProjectSummary.projectId(cwd: "/Users/me/death/limitless"))
        XCTAssertEqual(t.title, SessionNaming.displayName(name: nil, autoName: nil, cwd: "/Users/me/death/limitless"))
    }

    private func progress(autoName: String? = nil, lastActivityAt: Date? = nil) -> SessionProgress {
        var p = SessionProgress(lastActivityAt: lastActivityAt, nowDoing: nil, todos: nil, title: nil, goal: nil)
        p.autoName = autoName
        return p
    }

    func testTitlePrefersRecordNameThenAutoName() {
        XCTAssertEqual(T3Thread(record: record(name: "Fix login"), facts: facts(), progress: progress(autoName: "auto"), startedAt: nil, now: now).title, "Fix login")
        XCTAssertEqual(T3Thread(record: record(), facts: facts(), progress: progress(autoName: "Auto name"), startedAt: nil, now: now).title, "Auto name")
    }

    func testProjectFromSummary() {
        let s = ProjectSummary(id: "abc", name: "limitless", cwd: "/Users/me/death/limitless", branch: "main", liveCount: 1, lastActivityAt: nil)
        let p = T3ProjectGrouping.Project(summary: s)
        XCTAssertEqual(p.id, "abc"); XCTAssertEqual(p.name, "limitless"); XCTAssertEqual(p.cwd, s.cwd)
        XCTAssertEqual(p.environmentId, T3Thread.localEnvironmentId)
        XCTAssertEqual(T3ProjectGrouping.physicalKey(p), "local:abc")
    }

    func testStatusMapsOneToOne() {
        for s in SessionFacts.Status.allCases {
            let t = T3Thread(record: record(), facts: facts(status: s), progress: nil, startedAt: nil, now: now)
            XCTAssertEqual(t.session?.status.rawValue, s.rawValue)
        }
    }

    func testTurnStateMapsOneToOne() {
        for s in SessionTimeline.Turn.State.allCases {
            let turn = SessionTimeline.Turn(id: "t", state: s, requestedAt: now, startedAt: now, completedAt: nil,
                                            userMessageId: "u", assistantMessageId: nil)
            let t = T3Thread(record: record(), facts: facts(turn: turn), progress: nil, startedAt: nil, now: now)
            XCTAssertEqual(t.latestTurn?.state.rawValue, s.rawValue)
            XCTAssertEqual(t.latestTurn?.requestedAt, now)
        }
    }

    func testTimestampsFallBackInOrder() {
        let started = now.addingTimeInterval(-600), statusAt = now.addingTimeInterval(-60)
        let t = T3Thread(record: record(statusAt: statusAt), facts: facts(), autoName: nil, progress: nil, startedAt: started, now: now)
        XCTAssertEqual(t.createdAt, started)
        XCTAssertEqual(t.updatedAt, statusAt)
        XCTAssertEqual(t.session?.updatedAt, statusAt)
        let bare = T3Thread(record: record(), facts: facts(), progress: nil, startedAt: nil, now: now)
        XCTAssertEqual(bare.createdAt, now)
        XCTAssertEqual(bare.updatedAt, now)
    }

    func testUpdatedAtIsTheLatestSignal() {
        let statusAt = now.addingTimeInterval(-300), activity = now.addingTimeInterval(-30)
        let t = T3Thread(record: record(statusAt: statusAt), facts: facts(), progress: progress(lastActivityAt: activity), startedAt: nil, now: now)
        XCTAssertEqual(t.updatedAt, activity)
    }

    func testAttentionFieldsCopyThrough() {
        let until = now.addingTimeInterval(3600)
        let t = T3Thread(record: record(), facts: facts(approvals: true, pinnedAt: now, settled: .settled, snoozedUntil: until),
                         progress: nil, startedAt: nil, now: now)
        XCTAssertTrue(t.hasPendingApprovals)
        XCTAssertEqual(t.pinnedAt, now)
        XCTAssertEqual(t.settledOverride, .settled)
        XCTAssertEqual(t.settledAt, now)
        XCTAssertEqual(t.snoozedUntil, until)
        XCTAssertEqual(t.snoozedAt, now)
        XCTAssertFalse(t.hasActionableProposedPlan)
        XCTAssertNil(t.archivedAt)
        XCTAssertEqual(T3ThreadStatus(t), T3ThreadStatus(facts: facts(approvals: true)))
    }
}
```

`SessionProgress`'s memberwise init may have more fields than shown — read `SessionProgress.swift:6-60` and fill the extra labels with `nil`/defaults in the `progress(...)` helper; `autoName` is a `public var` (`:51`). If `SessionFacts.Status` is not `CaseIterable`, add `CaseIterable` to it in `SessionFacts.swift:9` (pure addition).

- [ ] **Step 2: Run, expect "no exact matches in call to initializer"**

```bash
swift test --filter T3ThreadBridgeTests 2>&1 | tail -20
```

- [ ] **Step 3: Implement** — `Sources/InfinitusCore/T3/T3ThreadBridge.swift`:

```swift
import Foundation

/// Infinitus facts → T3's thread shell (spec §2.2 / §4.3): the one place a
/// live session becomes the `T3Thread` that `T3SidebarList`, `T3ThreadSort`,
/// `T3ThreadSettled` and `T3ThreadStatus` reason over. The phone has the
/// same mapping at its seam; the Mac window uses this one.
extension T3Thread {
    /// The Mac's own sessions; remote environments arrive with the team
    /// mirror (F), never here.
    public static let localEnvironmentId = "local"

    public init(record: ClaudeSessionRecord, facts: SessionFacts,
                progress: SessionProgress?, startedAt: Date?, now: Date) {
        let turn = facts.latestTurn.map {
            Turn(state: Turn.State($0.state),
                 requestedAt: $0.requestedAt, startedAt: $0.startedAt, completedAt: $0.completedAt)
        }
        let createdAt = startedAt ?? facts.latestTurn?.requestedAt ?? record.statusUpdatedAt ?? now
        let turnAt = facts.latestTurn.map { $0.completedAt ?? $0.startedAt ?? $0.requestedAt }
        let updatedAt = [progress?.lastActivityAt, record.statusUpdatedAt, turnAt, createdAt]
            .compactMap { $0 }.max() ?? now
        self.init(id: record.sessionId,
                  environmentId: Self.localEnvironmentId,
                  projectId: ProjectSummary.projectId(cwd: record.cwd),
                  title: SessionNaming.displayName(name: record.name, autoName: progress?.autoName, cwd: record.cwd),
                  createdAt: createdAt, updatedAt: updatedAt,
                  pinnedAt: facts.pinnedAt,
                  settledOverride: SessionListPresentation.isSettled(facts) ? .settled : .active,
                  settledAt: facts.settledAt, unsettledAt: facts.unsettledAt,
                  snoozedUntil: facts.snoozedUntil, snoozedAt: facts.snoozedAt,
                  hasPendingApprovals: facts.hasPendingApprovals, hasPendingUserInput: facts.hasPendingUserInput,
                  hasActionableProposedPlan: false,
                  latestUserMessageAt: facts.latestUserMessageAt, latestTurn: turn,
                  session: Session(status: SessionStatus(facts.status),
                                   updatedAt: record.statusUpdatedAt ?? updatedAt))
    }

    /// The phone's row shape (team mirror, #337): `SessionDetail` + optional facts.
    /// Facts nil → status from the engine word, approvals from "waiting".
    public init(session: SessionDetail, facts: SessionFacts?, progress: SessionProgress?,
                environmentId: String, now: Date) {
        let createdAt = Date(timeIntervalSince1970: session.startedAt / 1000)
        let turn = facts?.latestTurn.map {
            Turn(state: Turn.State($0.state),
                 requestedAt: $0.requestedAt, startedAt: $0.startedAt, completedAt: $0.completedAt)
        }
        let turnAt = facts?.latestTurn.map { $0.completedAt ?? $0.startedAt ?? $0.requestedAt }
        let updatedAt = [progress?.lastActivityAt, turnAt, createdAt].compactMap { $0 }.max() ?? now
        let status: SessionStatus = facts.map { SessionStatus($0.status) }
            ?? (session.status == "busy" ? .running : .idle)
        self.init(id: "pid:\(session.pid)",           // see the brief: facts' session id when it has one
                  environmentId: environmentId,
                  projectId: ProjectSummary.projectId(cwd: session.cwd),
                  title: SessionNaming.displayName(name: progress?.name, autoName: progress?.autoName, cwd: session.cwd),
                  createdAt: createdAt, updatedAt: updatedAt,
                  pinnedAt: facts?.pinnedAt,
                  settledOverride: facts.map { SessionListPresentation.isSettled($0) ? .settled : .active },
                  settledAt: facts?.settledAt, unsettledAt: facts?.unsettledAt,
                  snoozedUntil: facts?.snoozedUntil, snoozedAt: facts?.snoozedAt,
                  hasPendingApprovals: facts?.hasPendingApprovals ?? (session.status == "waiting"),
                  hasPendingUserInput: facts?.hasPendingUserInput ?? false,
                  hasActionableProposedPlan: false,
                  latestUserMessageAt: facts?.latestUserMessageAt, latestTurn: turn,
                  session: Session(status: status, updatedAt: updatedAt))
    }
}

extension T3ProjectGrouping.Project {
    /// `ProjectSummary` (the mirror's `projects`) → T3's project row; the
    /// same rule on both clients so grouping keys agree.
    public init(summary: ProjectSummary, environmentId: String = T3Thread.localEnvironmentId) {
        self.init(id: summary.id, environmentId: environmentId, name: summary.name, cwd: summary.cwd)
    }
}
```

If the A close-out (`t3-clone-a6`) already added `T3Thread.SessionStatus.init(_ s: SessionFacts.Status)` and `T3Thread.Turn.State.init(_:)`, use those converters instead of the `rawValue` round-trips above.

- [ ] **Step 4: Run** `swift test --filter T3ThreadBridgeTests` → pass. Then `swift test --filter 'T3'` → pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/InfinitusCore/T3/T3ThreadBridge.swift Tests/InfinitusCoreTests/T3/T3ThreadBridgeTests.swift Sources/InfinitusCore/SessionFacts.swift
git commit -m "t3: SessionFacts and a session record become a T3Thread (T3 clone B-2)"
```

---

### Task 3: `SlashCommands` — `/` command and skill discovery

**Files:**
- Create: `Sources/InfinitusCore/SlashCommands.swift`
- Test: `Tests/InfinitusCoreTests/SlashCommandsTests.swift`

**Interfaces:**
- Consumes: Foundation only.
- Produces:
  ```swift
  public struct SlashCommand: Sendable, Equatable, Identifiable {
      public enum Source: String, Sendable { case userCommand = "user", projectCommand = "project", userSkill = "user-skill", projectSkill = "project-skill" }
      public let name: String          // "review", "frontend:design" (namespaced by sub-folder), skill dir name
      public let description: String   // frontmatter `description:` else first non-empty body line, else ""
      public let source: Source
      public var id: String { "\(source.rawValue):\(name)" }
      public var insertion: String { "/\(name) " }
  }
  public enum SlashCommands {
      public static func discover(cwd: String, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                  fileManager: FileManager = .default) -> [SlashCommand]
      public static func filter(_ all: [SlashCommand], query: String) -> [SlashCommand]
  }
  ```
  `discover` reads, in this order and dedups by `name` (first wins): `<cwd>/.claude/commands/**/*.md` (project), `<home>/.claude/commands/**/*.md` (user), `<cwd>/.claude/skills/*/SKILL.md` (project skill), `<home>/.claude/skills/*/SKILL.md` (user skill). Command name = path relative to `commands/` with `/` → `:` and `.md` dropped (Claude Code's own namespacing). Sorted by name. `filter` = T3's `composerSlashCommandSearch.ts`: empty query → all; else case-insensitive prefix match on name first, then substring on name, then substring on description; stable within a tier.

- [ ] **Step 1: Failing tests** — `Tests/InfinitusCoreTests/SlashCommandsTests.swift`:

```swift
import XCTest
@testable import InfinitusCore

final class SlashCommandsTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("slash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func write(_ rel: String, _ body: String) throws {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: url, atomically: true, encoding: .utf8)
    }

    func testDiscoversCommandsAndSkillsWithNamespacesAndDescriptions() throws {
        try write("home/.claude/commands/review.md", "---\ndescription: Review the diff\n---\nDo a review.")
        try write("home/.claude/commands/frontend/design.md", "Design something.\n\nMore.")
        try write("proj/.claude/commands/ship.md", "---\ndescription: Ship it\nargument-hint: <pr>\n---\n")
        try write("home/.claude/skills/writing-plans/SKILL.md", "---\nname: writing-plans\ndescription: Write a plan\n---\n")
        try write("proj/.claude/skills/deploy/SKILL.md", "Deploy steps.")
        let found = SlashCommands.discover(cwd: root.appendingPathComponent("proj").path,
                                           home: root.appendingPathComponent("home"))
        XCTAssertEqual(found.map(\.name), ["deploy", "frontend:design", "review", "ship", "writing-plans"])
        XCTAssertEqual(found.first { $0.name == "review" }?.description, "Review the diff")
        XCTAssertEqual(found.first { $0.name == "frontend:design" }?.description, "Design something.")
        XCTAssertEqual(found.first { $0.name == "ship" }?.source, .projectCommand)
        XCTAssertEqual(found.first { $0.name == "writing-plans" }?.source, .userSkill)
        XCTAssertEqual(found.first { $0.name == "deploy" }?.source, .projectSkill)
        XCTAssertEqual(found.first { $0.name == "deploy" }?.description, "Deploy steps.")
        XCTAssertEqual(found.first { $0.name == "ship" }?.insertion, "/ship ")
    }

    func testProjectCommandShadowsUserCommandOfTheSameName() throws {
        try write("home/.claude/commands/review.md", "---\ndescription: user\n---\n")
        try write("proj/.claude/commands/review.md", "---\ndescription: project\n---\n")
        let found = SlashCommands.discover(cwd: root.appendingPathComponent("proj").path, home: root.appendingPathComponent("home"))
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].source, .projectCommand)
    }

    func testMissingDirectoriesYieldNothing() {
        XCTAssertEqual(SlashCommands.discover(cwd: root.appendingPathComponent("nope").path, home: root.appendingPathComponent("nohome")), [])
    }

    func testFilterRanksPrefixThenNameSubstringThenDescription() {
        let all = [
            SlashCommand(name: "review", description: "Review the diff", source: .userCommand),
            SlashCommand(name: "preview", description: "Open a preview", source: .userCommand),
            SlashCommand(name: "ship", description: "Create a PR and review it", source: .projectCommand),
            SlashCommand(name: "deploy", description: "Deploy", source: .projectSkill),
        ]
        XCTAssertEqual(SlashCommands.filter(all, query: "").map(\.name), ["review", "preview", "ship", "deploy"])
        XCTAssertEqual(SlashCommands.filter(all, query: "re").map(\.name), ["review", "preview", "ship"])
        XCTAssertEqual(SlashCommands.filter(all, query: "REV").map(\.name), ["review", "preview", "ship"])
        XCTAssertEqual(SlashCommands.filter(all, query: "zzz"), [])
    }
}
```

- [ ] **Step 2: Run, expect "cannot find 'SlashCommands'"**

```bash
swift test --filter SlashCommandsTests 2>&1 | tail -5
```

- [ ] **Step 3: Implement** — `Sources/InfinitusCore/SlashCommands.swift`:

```swift
import Foundation

/// A Claude Code slash command or skill the composer's `/` menu offers
/// (T3 `ComposerCommandMenu.tsx` over the provider's command list). Read
/// from Claude Code's own files — `~/.claude/commands`, `<cwd>/.claude/commands`,
/// and the `skills/*/SKILL.md` folders — never from any engine.
public struct SlashCommand: Sendable, Equatable, Identifiable {
    public enum Source: String, Sendable {
        case userCommand = "user", projectCommand = "project", userSkill = "user-skill", projectSkill = "project-skill"
    }
    public let name: String
    public let description: String
    public let source: Source
    public init(name: String, description: String, source: Source) {
        self.name = name; self.description = description; self.source = source
    }
    public var id: String { "\(source.rawValue):\(name)" }
    /// What the composer inserts when the row is picked.
    public var insertion: String { "/\(name) " }
}

public enum SlashCommands {
    /// Project first so it shadows a same-named user command (Claude Code's
    /// own precedence); commands before skills; sorted by name.
    public static func discover(cwd: String, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                fileManager: FileManager = .default) -> [SlashCommand] {
        let project = URL(fileURLWithPath: cwd).appendingPathComponent(".claude")
        let user = home.appendingPathComponent(".claude")
        var seen = Set<String>()
        var out: [SlashCommand] = []
        func add(_ c: SlashCommand) { if seen.insert(c.name).inserted { out.append(c) } }
        for c in commands(under: project.appendingPathComponent("commands"), source: .projectCommand, fm: fileManager) { add(c) }
        for c in commands(under: user.appendingPathComponent("commands"), source: .userCommand, fm: fileManager) { add(c) }
        for c in skills(under: project.appendingPathComponent("skills"), source: .projectSkill, fm: fileManager) { add(c) }
        for c in skills(under: user.appendingPathComponent("skills"), source: .userSkill, fm: fileManager) { add(c) }
        return out.sorted { $0.name < $1.name }
    }

    /// `composerSlashCommandSearch.ts`: prefix on name, then name substring,
    /// then description substring; case-insensitive; stable within a tier.
    public static func filter(_ all: [SlashCommand], query: String) -> [SlashCommand] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        let prefix = all.filter { $0.name.lowercased().hasPrefix(q) }
        let name = all.filter { !$0.name.lowercased().hasPrefix(q) && $0.name.lowercased().contains(q) }
        let desc = all.filter { !$0.name.lowercased().contains(q) && $0.description.lowercased().contains(q) }
        return prefix + name + desc
    }

    private static func commands(under dir: URL, source: SlashCommand.Source, fm: FileManager) -> [SlashCommand] {
        guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var out: [SlashCommand] = []
        for case let url as URL in e where url.pathExtension == "md" {
            let rel = url.path.dropFirst(dir.path.count + 1).dropLast(3)   // strip "<dir>/" and ".md"
            let name = rel.replacingOccurrences(of: "/", with: ":")
            out.append(SlashCommand(name: name, description: describe(url), source: source))
        }
        return out
    }

    private static func skills(under dir: URL, source: SlashCommand.Source, fm: FileManager) -> [SlashCommand] {
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.compactMap { name in
            let skill = dir.appendingPathComponent(name).appendingPathComponent("SKILL.md")
            guard fm.fileExists(atPath: skill.path) else { return nil }
            return SlashCommand(name: name, description: describe(skill), source: source)
        }
    }

    /// Frontmatter `description:`; else the first non-empty body line.
    static func describe(_ url: URL) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            var i = 1
            var description: String?
            while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces) != "---" {
                let line = lines[i].trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("description:") {
                    description = String(line.dropFirst("description:".count)).trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                }
                i += 1
            }
            if let description, !description.isEmpty { return description }
            lines = Array(lines.dropFirst(min(i + 1, lines.count)))
        }
        return lines.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?.trimmingCharacters(in: .whitespaces) ?? ""
    }
}
```

- [ ] **Step 4: Run** `swift test --filter SlashCommandsTests` → pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/InfinitusCore/SlashCommands.swift Tests/InfinitusCoreTests/SlashCommandsTests.swift
git commit -m "core: slash command and skill discovery for the workspace composer (T3 clone B-3)"
```

**→ PR B-1 (`t3-clone-b1`)**: Tasks 1–3. CHANGELOG line: `- Workspace groundwork: timeline messages carry updatedAt, tool rows carry their command, slash-command discovery.`

---

### Task 4: `T3WorkspaceState` — the window's pure state reducer (Core)

**Files:**
- Create: `Sources/InfinitusCore/T3/T3WorkspaceState.swift`
- Test: `Tests/InfinitusCoreTests/T3/T3WorkspaceStateTests.swift`

**Interfaces:**
- Consumes: `T3Thread(record:facts:progress:startedAt:now:)` and `T3ProjectGrouping.Project(summary:)` (Task 2), `T3SidebarList.searchByTitle`, `T3ThreadSort.sortPinned/sortActive`, `T3ThreadSettled.effectiveSnoozed(_:now:)`, `T3SidebarList.hasUnseenCompletion`, `T3ProjectGrouping.groups(projects:settings:primaryEnvironmentId:environmentLabel:)`, `T3SidebarList.adjacentThreadId`.
- Produces (all `Sendable, Equatable`):
  ```swift
  public struct T3WorkspaceInputs: Sendable, Equatable {
      public var records: [ClaudeSessionRecord]
      public var facts: [Int32: SessionFacts]          // by pid; a pid without facts is skipped
      public var progress: [Int32: SessionProgress]
      public var startedAt: [Int32: Date]
      public var projects: [ProjectSummary]
      public init(records:facts:progress:startedAt:projects:)
  }
  public enum T3SidebarScope: Sendable, Equatable { case all, project(id: String) }
  public struct T3WorkspaceState: Sendable, Equatable {
      public var threads: [T3Thread]                    // every live session, sorted by updatedAt desc
      public var projects: [T3ProjectGrouping.Project]
      public var groups: [T3ProjectGrouping.Group]
      public var selectedThreadId: String?              // sessionId — survives a pid change on resume
      public var scope: T3SidebarScope = .all
      public var search: String = ""
      public var expandedTurnIds: [String: Set<String>] = [:]      // by threadId
      public var expandedWorkGroupIds: [String: Set<String>] = [:]
      public var lastVisitedAt: [String: Date] = [:]               // by threadId (T3 `lastVisitedAt`)
      public var sidebarCollapsed = false
      public var rightPanelOpen = false

      public init()
      public mutating func apply(_ inputs: T3WorkspaceInputs, now: Date)
      // apply() remembers the first `createdAt` it saw per thread id (`firstSeenCreatedAt: [String: Date]`)
      // and rewrites each incoming thread's createdAt (and an updatedAt equal to it) with the remembered
      // value: the bridge falls back to `now` for a session with no birth record/turn/statusUpdatedAt, and
      // without this memory such a thread re-sorts and re-diffs the sidebar on every tick (B-1 review #4).
      // Test: apply twice, 1 s apart, the same record-less thread → equal T3Thread values, one createdAt.
      public mutating func select(_ threadId: String?, now: Date)   // stamps lastVisitedAt
      public func pid(of threadId: String) -> Int32?
      public var selectedThread: T3Thread?
      public func visibleThreads(now: Date) -> [T3Thread]           // scope + search applied
      public struct SidebarSection: Sendable, Equatable { public let kind: T3SidebarList.Section; public let threads: [T3Thread] }
      public func sidebarSections(now: Date) -> [SidebarSection]     // pinned, active, snoozed, settled — empty sections omitted; T3 order
      public func adjacentThreadId(_ direction: T3SidebarList.Traversal, now: Date) -> String?
      public mutating func toggleTurn(_ turnId: String)             // on the selected thread
      public mutating func toggleWorkGroup(_ groupId: String)
  }
  ```
  Section rules (T3 `Sidebar.logic.ts` as ported in `T3SidebarList`/`T3ThreadList`): pinned = `pinnedAt != nil` sorted with `T3ThreadSort.sortPinned`; snoozed = not pinned and `T3ThreadSettled.effectiveSnoozed(t, now:)`; settled = not pinned/snoozed and `T3ThreadList` would place it settled — reuse `T3ThreadList.orderedSection(_:section:now:)` if its signature fits (read `T3ThreadList.swift:40-80`); otherwise a thread is settled when `settledOverride == .settled` or (`settledOverride == nil` and `T3ThreadStatus(t) == .ready` and `latestTurn?.completedAt` is older than the thread's `lastVisitedAt`) — pick the reducer's rule and say which in the report; active = the rest sorted with `T3ThreadSort.sortActive`.
  Selection survival: `apply` keeps `selectedThreadId` when a thread with that id is still present (pid may differ); clears it when the id vanished. `pid(of:)` looks the record up by `sessionId`.

- [ ] **Step 1: Failing tests** — `Tests/InfinitusCoreTests/T3/T3WorkspaceStateTests.swift`:

```swift
import XCTest
@testable import InfinitusCore

final class T3WorkspaceStateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)
    private func record(pid: Int32, id: String, cwd: String = "/w/a", status: String? = "idle") -> ClaudeSessionRecord {
        ClaudeSessionRecord(pid: pid, sessionId: id, cwd: cwd, status: status, statusUpdatedAt: now)
    }
    private func facts(_ status: SessionFacts.Status = .ready, pinnedAt: Date? = nil, snoozedUntil: Date? = nil,
                       settled: AttentionStore.SettledOverride? = nil) -> SessionFacts {
        SessionFacts(status: status, hasPendingApprovals: false, hasPendingUserInput: false, hasPlan: false,
                     latestTurn: nil, planProgress: nil, latestUserMessageAt: nil, settledOverride: settled,
                     settledAt: settled == nil ? nil : now, unsettledAt: nil, snoozedUntil: snoozedUntil,
                     snoozedAt: snoozedUntil == nil ? nil : now, pinnedAt: pinnedAt)
    }
    private func inputs(_ pairs: [(ClaudeSessionRecord, SessionFacts)], projects: [ProjectSummary] = []) -> T3WorkspaceInputs {
        T3WorkspaceInputs(records: pairs.map(\.0), facts: Dictionary(uniqueKeysWithValues: pairs.map { ($0.0.pid, $0.1) }),
                          progress: [:], startedAt: [:], projects: projects)
    }

    func testApplyBuildsThreadsAndProjects() {
        var s = T3WorkspaceState()
        let summary = ProjectSummary(id: ProjectSummary.projectId(cwd: "/w/a"), name: "a", cwd: "/w/a", branch: nil, liveCount: 1, lastActivityAt: nil)
        s.apply(inputs([(record(pid: 1, id: "s1"), facts())], projects: [summary]), now: now)
        XCTAssertEqual(s.threads.map(\.id), ["s1"])
        XCTAssertEqual(s.threads[0].projectId, summary.id)
        XCTAssertEqual(s.projects.map(\.id), [summary.id])
        XCTAssertEqual(s.groups.count, 1)
        XCTAssertEqual(s.groups[0].members.map(\.id), [summary.id])
    }

    func testPidWithoutFactsIsSkipped() {
        var s = T3WorkspaceState()
        s.apply(T3WorkspaceInputs(records: [record(pid: 1, id: "s1"), record(pid: 2, id: "s2")],
                                  facts: [1: facts()], progress: [:], startedAt: [:], projects: []), now: now)
        XCTAssertEqual(s.threads.map(\.id), ["s1"])
    }

    func testSelectionSurvivesPidChangeAndClearsWhenGone() {
        var s = T3WorkspaceState()
        s.apply(inputs([(record(pid: 1, id: "s1"), facts())]), now: now)
        s.select("s1", now: now)
        XCTAssertEqual(s.pid(of: "s1"), 1)
        XCTAssertEqual(s.lastVisitedAt["s1"], now)
        s.apply(inputs([(record(pid: 9, id: "s1"), facts())]), now: now)   // resumed under a new pid
        XCTAssertEqual(s.selectedThreadId, "s1")
        XCTAssertEqual(s.pid(of: "s1"), 9)
        s.apply(inputs([]), now: now)
        XCTAssertNil(s.selectedThreadId)
        XCTAssertNil(s.selectedThread)
    }

    func testSectionsPinnedActiveSnoozedSettled() {
        var s = T3WorkspaceState()
        s.apply(inputs([
            (record(pid: 1, id: "pinned"), facts(pinnedAt: now)),
            (record(pid: 2, id: "active", status: "busy"), facts(.running)),
            (record(pid: 3, id: "snoozed"), facts(snoozedUntil: now.addingTimeInterval(3600))),
            (record(pid: 4, id: "settled"), facts(settled: .settled)),
        ]), now: now)
        let sections = s.sidebarSections(now: now)
        XCTAssertEqual(sections.map(\.kind), [.pinned, .active, .snoozed, .settled])
        XCTAssertEqual(sections.map { $0.threads.map(\.id) }, [["pinned"], ["active"], ["snoozed"], ["settled"]])
    }

    func testEmptySectionsAreOmitted() {
        var s = T3WorkspaceState()
        s.apply(inputs([(record(pid: 2, id: "active", status: "busy"), facts(.running))]), now: now)
        XCTAssertEqual(s.sidebarSections(now: now).map(\.kind), [.active])
    }

    func testScopeAndSearchFilterVisibleThreads() {
        var s = T3WorkspaceState()
        let a = ProjectSummary(id: ProjectSummary.projectId(cwd: "/w/a"), name: "a", cwd: "/w/a", branch: nil, liveCount: 1, lastActivityAt: nil)
        s.apply(inputs([
            (record(pid: 1, id: "s1", cwd: "/w/a"), facts()),
            (record(pid: 2, id: "s2", cwd: "/w/b"), facts()),
        ], projects: [a]), now: now)
        s.scope = .project(id: a.id)
        XCTAssertEqual(s.visibleThreads(now: now).map(\.id), ["s1"])
        s.scope = .all
        s.search = "B"   // titles fall back to the cwd's last path component: "a", "b"
        XCTAssertEqual(s.visibleThreads(now: now).map(\.id), ["s2"])
        XCTAssertEqual(s.sidebarSections(now: now).flatMap { $0.threads.map(\.id) }, ["s2"])
    }

    func testAdjacentThreadWalksTheVisibleOrder() {
        var s = T3WorkspaceState()
        s.apply(inputs([
            (record(pid: 1, id: "pinned"), facts(pinnedAt: now)),
            (record(pid: 2, id: "active"), facts()),
        ]), now: now)
        s.select("pinned", now: now)
        XCTAssertEqual(s.adjacentThreadId(.next, now: now), "active")
        XCTAssertNil(s.adjacentThreadId(.previous, now: now))
        s.select(nil, now: now)
        XCTAssertEqual(s.adjacentThreadId(.next, now: now), "pinned")
    }

    func testToggleTurnAndGroupAreScopedToTheSelectedThread() {
        var s = T3WorkspaceState()
        s.apply(inputs([(record(pid: 1, id: "s1"), facts()), (record(pid: 2, id: "s2"), facts())]), now: now)
        s.select("s1", now: now)
        s.toggleTurn("t1"); s.toggleWorkGroup("g1")
        XCTAssertEqual(s.expandedTurnIds["s1"], ["t1"])
        XCTAssertEqual(s.expandedWorkGroupIds["s1"], ["g1"])
        XCTAssertNil(s.expandedTurnIds["s2"])
        s.toggleTurn("t1")
        XCTAssertEqual(s.expandedTurnIds["s1"], [])
    }
}
```

The `adjacentThreadId` expectations depend on `T3SidebarList.adjacentThreadId(_:current:direction:)` — read `T3SidebarList.swift:128-136` and keep the upstream semantics (no wrap-around, `nil` current → first for `.next`); if upstream wraps, change the test's `XCTAssertNil(.previous)` to upstream's answer and say so.

- [ ] **Step 2: Run, expect "cannot find 'T3WorkspaceState'"** — `swift test --filter T3WorkspaceStateTests 2>&1 | tail -5`

- [ ] **Step 3: Implement** — `Sources/InfinitusCore/T3/T3WorkspaceState.swift`:

```swift
import Foundation

/// What the window model hands the reducer on every fleet tick — the raw
/// Infinitus facts, never a T3 type, so the mapping lives in one place.
public struct T3WorkspaceInputs: Sendable, Equatable {
    public var records: [ClaudeSessionRecord]
    public var facts: [Int32: SessionFacts]
    public var progress: [Int32: SessionProgress]
    public var startedAt: [Int32: Date]
    public var projects: [ProjectSummary]
    public init(records: [ClaudeSessionRecord], facts: [Int32: SessionFacts], progress: [Int32: SessionProgress],
                startedAt: [Int32: Date], projects: [ProjectSummary]) {
        self.records = records; self.facts = facts; self.progress = progress
        self.startedAt = startedAt; self.projects = projects
    }
}

public enum T3SidebarScope: Sendable, Equatable { case all, project(id: String) }

/// The workspace window's state as a value (spec §4.3): threads, projects,
/// selection, sidebar scope/search, disclosure. `T3WindowModel` owns one
/// and republishes it; everything here is testable without AppKit.
public struct T3WorkspaceState: Sendable, Equatable {
    public var threads: [T3Thread] = []
    public var projects: [T3ProjectGrouping.Project] = []
    public var groups: [T3ProjectGrouping.Group] = []
    public var selectedThreadId: String?
    public var scope: T3SidebarScope = .all
    public var search = ""
    public var expandedTurnIds: [String: Set<String>] = [:]
    public var expandedWorkGroupIds: [String: Set<String>] = [:]
    public var lastVisitedAt: [String: Date] = [:]
    public var sidebarCollapsed = false
    public var rightPanelOpen = false
    private var pidBySession: [String: Int32] = [:]

    public init() {}

    public mutating func apply(_ inputs: T3WorkspaceInputs, now: Date) {
        var next: [T3Thread] = []
        var pids: [String: Int32] = [:]
        for r in inputs.records {
            guard let f = inputs.facts[r.pid] else { continue }
            var t = T3Thread(record: r, facts: f, progress: inputs.progress[r.pid], startedAt: inputs.startedAt[r.pid], now: now)
            t.lastVisitedAt = lastVisitedAt[t.id]
            next.append(t)
            pids[t.id] = r.pid
        }
        threads = next.sorted { $0.updatedAt > $1.updatedAt }
        pidBySession = pids
        projects = inputs.projects.map { T3ProjectGrouping.Project(summary: $0) }
        groups = T3ProjectGrouping.groups(projects: projects, settings: .init(),
                                          primaryEnvironmentId: T3Thread.localEnvironmentId, environmentLabel: { _ in nil })
        if let id = selectedThreadId, pids[id] == nil { selectedThreadId = nil }
    }

    public mutating func select(_ threadId: String?, now: Date) {
        selectedThreadId = threadId
        guard let threadId else { return }
        lastVisitedAt[threadId] = now
        if let i = threads.firstIndex(where: { $0.id == threadId }) { threads[i].lastVisitedAt = now }
    }

    public func pid(of threadId: String) -> Int32? { pidBySession[threadId] }
    public var selectedThread: T3Thread? { selectedThreadId.flatMap { id in threads.first { $0.id == id } } }

    public func visibleThreads(now: Date) -> [T3Thread] {
        var out = threads
        if case let .project(id) = scope { out = out.filter { $0.projectId == id } }
        return T3SidebarList.searchByTitle(out, query: search)
    }

    public struct SidebarSection: Sendable, Equatable {
        public let kind: T3SidebarList.Section
        public let threads: [T3Thread]
    }

    public func sidebarSections(now: Date) -> [SidebarSection] {
        let visible = visibleThreads(now: now)
        let pinned = T3ThreadSort.sortPinned(visible.filter { $0.pinnedAt != nil })
        let rest = visible.filter { $0.pinnedAt == nil }
        let snoozed = rest.filter { T3ThreadSettled.effectiveSnoozed($0, now: now) }
        let unsnoozed = rest.filter { !T3ThreadSettled.effectiveSnoozed($0, now: now) }
        let settled = unsnoozed.filter { Self.isSettled($0) }
        let active = T3ThreadSort.sortActive(unsnoozed.filter { !Self.isSettled($0) })
        return [SidebarSection(kind: .pinned, threads: pinned), SidebarSection(kind: .active, threads: active),
                SidebarSection(kind: .snoozed, threads: snoozed),
                SidebarSection(kind: .settled, threads: settled.sorted { ($0.settledAt ?? .distantPast) > ($1.settledAt ?? .distantPast) })]
            .filter { !$0.threads.isEmpty }
    }

    /// `threadListV2.ts` settled rule: an explicit settle, or a ready thread
    /// whose last completion the user has already looked at.
    static func isSettled(_ t: T3Thread) -> Bool {
        if let o = t.settledOverride { return o == .settled }
        guard T3ThreadStatus(t) == .ready, let done = t.latestTurn?.completedAt, let seen = t.lastVisitedAt else { return false }
        return seen >= done
    }

    public func adjacentThreadId(_ direction: T3SidebarList.Traversal, now: Date) -> String? {
        let ids = sidebarSections(now: now).flatMap { $0.threads.map(\.id) }
        return T3SidebarList.adjacentThreadId(ids, current: selectedThreadId, direction: direction)
    }

    public mutating func toggleTurn(_ turnId: String) {
        guard let id = selectedThreadId else { return }
        var set = expandedTurnIds[id] ?? []
        if !set.insert(turnId).inserted { set.remove(turnId) }
        expandedTurnIds[id] = set
    }

    public mutating func toggleWorkGroup(_ groupId: String) {
        guard let id = selectedThreadId else { return }
        var set = expandedWorkGroupIds[id] ?? []
        if !set.insert(groupId).inserted { set.remove(groupId) }
        expandedWorkGroupIds[id] = set
    }
}
```

Before keeping `isSettled` as written, read `T3ThreadList.swift` for the reducer A already ported (`orderedSection` / the settled predicate) and call **that** instead if it exists as a reusable function — one settled rule, not two. Report which you used.

- [ ] **Step 4: Run** `swift test --filter 'T3WorkspaceStateTests|T3SidebarListTests|T3ThreadListTests'` → pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/InfinitusCore/T3/T3WorkspaceState.swift Tests/InfinitusCoreTests/T3/T3WorkspaceStateTests.swift
git commit -m "t3: workspace state reducer — threads, projects, selection, sidebar sections (T3 clone B-4)"
```

---

### Task 5: The window shell, `T3WindowModel`, and the three ways in

**Files:**
- Create: `Sources/Infinitus/T3Window/T3WindowController.swift`, `Sources/Infinitus/T3Window/T3WindowModel.swift`, `Sources/Infinitus/T3Window/T3Root.swift` (placeholder root this task; Task 6 fills it)
- Modify: `Sources/InfinitusCore/ControlProtocol.swift:235-237`, `Sources/Infinitus/ControlServer.swift:628-638`, `Sources/Infinitus/StatusItemController.swift:55, 103-107, 456-460, 717-728`, `Sources/Infinitus/AppModel.swift:351, 1598-1606`, `Sources/Infinitus/MacSessionsPopover.swift:26-31`, `Sources/Infinitus/InfinitusApp.swift:367-373`
- Test: `Tests/InfinitusCoreTests/ControlProtocolTests.swift`

**Interfaces:**
- Consumes: `WallWindowController` pattern (`WallWindow.swift:12-95`), `SessionChatWindows` (`SessionChatWindow.swift:14-70`), `AppModel.uiSurface(_:visible:)`, `AppModel.sessionProgress.$byPid/$facts`, `AppModel.sessionBirths`, `AppModel.projectSummaries(profiles:)`, `AppModel.sessionProfiles` (find the profiles accessor: `grep -n 'profiles' Sources/Infinitus/AppModel.swift | head`), `T3WorkspaceState` (Task 4), `SessionAttention.apply` (`SessionAttention.swift:28`).
- Produces:
  - `ControlCommand "show"` args `["popout|settings|wall|workspace [sidebar|thread|composer]"]`; ControlServer `case "workspace": controller.showWorkspace(screen: r.args.dropFirst().first)`; reply `{"shown":"workspace"}`.
  - `AppModel.showWorkspace: ((String?) -> Void)?`; `AppModel.applyAttention(pid:_:) -> SessionAttention.Outcome?` (nonisolated; the body lifted out of the `mirrorServer.attention.set` closure, which now calls it).
  - `StatusItemController.showWorkspace(screen: String?)` (opens or raises; never a toggle — a second `show workspace` is a no-op raise, unlike the wall).
  - **What a screen does** (`T3WindowModel.focusedScreen`, consumed after the first `state.apply`): `sidebar` and `thread` select the first thread in sidebar order when nothing is selected (so the parity captures land on the fixture thread, never the empty state); `composer` does the same and sets `composerFocusRequested = true`, which Task 13's field consumes (`@FocusState` set on appear) and clears. `nil` changes nothing.
  - `T3WindowController` (`@MainActor final class`): `show(model:screen:)`, `close()`, `isVisible`, `visibilityChanged`.
  - `T3WindowModel: ObservableObject` (`@MainActor`): `@Published private(set) var state: T3WorkspaceState`, `func start()` / `stop()` (Combine sink on `model.sessionProgress.$facts` + `$byPid`, debounced `0.2 s`; each tick builds `T3WorkspaceInputs` off the main actor via `Task.detached` — `ClaudeSessions.list`, `projectSummaries` — then `state.apply` on main), `func select(_:)`, `func attention(_ action: AttentionStore.Action, until: Date?)` on the selected thread, `var now: Date` (a stored `Date()` refreshed on every publish and by the 60 s key-window tick — views read `model.now`, never `Date()`), `func toggleSidebar()`, `func toggleRightPanel()`, `func setScope/setSearch`.
  - Popup row **"Open workspace"** in `MacSessionsPopover` under the sessions card; hidden ⌘⇧T button in `InfinitusApp` (the ⌘F pattern).
  - Window: `styleMask [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]`, `titlebarAppearsTransparent = true`, `titleVisibility = .hidden`, default content 1800×1050 (`T3Theme.Metrics` has no window size — literal is fine here, it is the reference geometry), `contentMinSize 960×600`, `setFrameAutosaveName("Workspace")`, traffic lights moved to x 12 / vertically centred in the 52 pt title band (`standardWindowButton(.closeButton/.miniaturizeButton/.zoomButton)?.setFrameOrigin`, re-applied in `windowDidResize`), `isReleasedWhenClosed = false`, `LockGate` wrapping (the wall/Settings rule, #55), `uiSurface("workspace", visible:)`, activation like the chat window (`NSApp.activate(ignoringOtherApps: true)`, no policy flip).

- [ ] **Step 1: Failing test** — append to `Tests/InfinitusCoreTests/ControlProtocolTests.swift` in the existing args test (≈ line 50-66):

```swift
        XCTAssertEqual(ControlCommand.named("show")?.args, ["popout|settings|wall|workspace [sidebar|thread|composer]"])
```

Run `swift test --filter ControlProtocolTests` → fails (current value `["popout|settings|wall"]`).

- [ ] **Step 2: Control route** — `ControlProtocol.swift:235-237`:

```swift
        ControlCommand(name: "show", args: ["popout|settings|wall|workspace [sidebar|thread|composer]"], effect: .write,
                       summary: "Open a window: the pinned pop-out, Settings, the wall (toggle), or the workspace (optionally on a screen).",
                       replyShape: "{shown}"),
```

`ControlServer.swift:632-637`:

```swift
            switch r.args.first {
            case "popout": controller.showPinnedWindow()
            case "settings": controller.showSettingsWindow()
            case "wall": controller.toggleWall()
            case "workspace":
                let screen = r.args.dropFirst().first
                if let screen, !["sidebar", "thread", "composer"].contains(screen) {
                    throw Fail("usage: show workspace [sidebar|thread|composer]")
                }
                controller.showWorkspace(screen: screen)
            default: throw Fail("usage: show popout|settings|wall|workspace [sidebar|thread|composer]")
            }
```

Run `swift test --filter ControlProtocolTests` → pass. (`InfinitusCLI` passes args through untouched — check `Sources/InfinitusCLI` for a per-verb arity check on `show`; if one exists, allow 1–2 args.)

- [ ] **Step 3: AppModel hooks** — `AppModel.swift` next to `showWall` (:351):

```swift
    /// Opens the workspace window (T3 clone B), optionally on a screen
    /// ("sidebar" | "thread" | "composer" — the parity harness's names).
    var showWorkspace: ((String?) -> Void)?
```

Lift the attention closure (:1598-1606) into a method — place it near `deliverSessionInput` (:1657):

```swift
    /// Settle / snooze / pin one session (#223 phase 3) — the mirror's
    /// attention route and the workspace window share it.
    nonisolated func applyAttention(pid: Int32, _ request: SessionAttention.Request) -> SessionAttention.Outcome? {
        let claudeDir = ClaudeSessions.configHome()
        guard let record = ClaudeSessions.list(claudeDir: claudeDir).first(where: { $0.pid == pid }),
              let timeline = timelineCache.timeline(record: record, claudeDir: claudeDir) else { return nil }
        let pending = ownedBox.existing?.pending(pid: pid) ?? []
        return SessionAttention.apply(request, sessionId: record.sessionId,
                                      timeline: timeline.appending(pending: pending),
                                      status: record.status, store: attentionStore)
    }
```

and replace the closure body with `mirrorServer.attention.set { [unowned self] pid, request in self.applyAttention(pid: pid, request) }` (match how neighbouring `set` closures capture `self` — several capture `let` copies because `self` is main-actor-isolated; `timelineCache`/`attentionStore`/`ownedBox` are `let`/`lazy let`, so if the compiler rejects `self` access from the nonisolated closure, keep the existing captured-`let` closure and have it call a `static func` version that takes `timelineCache`, `attentionStore`, `ownedBox` as parameters, with the instance method forwarding to it). Build: `swift build 2>&1 | grep -E 'error|warning: var' | head`.

- [ ] **Step 4: The window model** — `Sources/Infinitus/T3Window/T3WindowModel.swift`:

```swift
import SwiftUI
import Combine
import InfinitusCore

/// The workspace window's model (spec §4.3): one `T3WorkspaceState`
/// republished on every fleet tick. Reads ride `SessionProgressModel`'s
/// publishers — no timer of its own; the only clock is the 60 s
/// relative-time tick the controller runs while the window is key.
@MainActor
final class T3WindowModel: ObservableObject {
    @Published private(set) var state = T3WorkspaceState()
    /// The instant labels are computed against; refreshed on publish and
    /// by the key-window tick. Views read this, never `Date()`.
    @Published private(set) var now = Date()
    @Published var focusedScreen: String?
    private(set) weak var model: AppModel?
    private var sink: AnyCancellable?
    private var refreshing = false
    /// Task 13's composer focuses its field when this flips true, then clears it.
    @Published var composerFocusRequested = false

    /// `show workspace <screen>` (Task 5 interface): select the first thread when
    /// nothing is selected; `composer` also asks for field focus. One-shot.
    private func applyFocusedScreen(_ screen: String) {
        focusedScreen = nil
        if state.selectedThreadId == nil, let first = state.sidebarSections(now: now).first?.threads.first {
            state.select(first.id, now: now)
        }
        if screen == "composer" { composerFocusRequested = true }
    }

    init(model: AppModel) { self.model = model }

    func start() {
        guard sink == nil, let model else { return }
        sink = model.sessionProgress.$facts.combineLatest(model.sessionProgress.$byPid)
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.refresh() }
        refresh()
    }

    func stop() { sink = nil }

    func tick() { now = Date() }

    private func refresh() {
        guard let model, !refreshing else { return }
        refreshing = true
        let facts = model.sessionProgress.facts, progress = model.sessionProgress.byPid
        let births = model.sessionBirths
        let profiles = model.sessionProfiles.profiles   // adapt to the real accessor
        // `projectSummaries(profiles:)` memoizes its PastSessions walk itself
        // (#369: 60 s, keyed on the live session set) — call it, never wrap
        // it in a second cache (that doubles the cost the memo removed).
        Task.detached(priority: .utility) { [weak self] in
            let records = ClaudeSessions.list(claudeDir: ClaudeSessions.configHome())
            let projects = model.projectSummaries(profiles: profiles)
            let inputs = T3WorkspaceInputs(
                records: records,
                facts: Dictionary(uniqueKeysWithValues: facts.map { (Int32($0.key), $0.value) }),
                progress: Dictionary(uniqueKeysWithValues: progress.map { (Int32($0.key), $0.value) }),
                startedAt: Dictionary(uniqueKeysWithValues: births.compactMap { pid, b in b.startedAt.map { (Int32(pid), $0) } }),
                projects: projects)
            await MainActor.run {
                guard let self else { return }
                let now = Date()
                self.now = now
                self.state.apply(inputs, now: now)
                if let screen = self.focusedScreen { self.applyFocusedScreen(screen) }
                self.refreshing = false
            }
        }
    }

    func select(_ threadId: String?) { state.select(threadId, now: now) }
    func toggleSidebar() { state.sidebarCollapsed.toggle() }
    func toggleRightPanel() { state.rightPanelOpen.toggle() }
    func setScope(_ s: T3SidebarScope) { state.scope = s }
    func setSearch(_ q: String) { state.search = q }
    func toggleTurn(_ id: String) { state.toggleTurn(id) }
    func toggleWorkGroup(_ id: String) { state.toggleWorkGroup(id) }
    func selectAdjacent(_ d: T3SidebarList.Traversal) { if let id = state.adjacentThreadId(d, now: now) { select(id) } }

    /// Attention on any thread; the fleet tick republishes the result.
    func attention(_ action: AttentionStore.Action, threadId: String, until: Date? = nil) {
        guard let model, let pid = state.pid(of: threadId) else { return }
        let request = SessionAttention.Request(action: action, until: until, commandId: UUID().uuidString)
        Task.detached(priority: .userInitiated) { _ = model.applyAttention(pid: pid, request) }
    }
}
```

`SessionBirth` has no `startedAt` — check `SessionBirth.swift:8-30`; if it lacks a date, drop the `startedAt` dictionary (pass `[:]`) and note it (the bridge falls back to the latest turn / status time). `SessionAttention.Request`'s memberwise init may be internal — read `SessionAttention.swift:9-18`; if it is `public init(action:until:commandId:)` use it, else add that public init (Core, one line).

- [ ] **Step 5: The controller** — `Sources/Infinitus/T3Window/T3WindowController.swift`:

```swift
import SwiftUI
import AppKit
import InfinitusCore
import InfinitusUI

/// The workspace window (spec §4.1) — T3 Code's desktop shell over
/// Infinitus's sessions. One window, reused (WallWindow's lesson); the
/// content is detached on close so nothing ticks while it is hidden.
@MainActor
final class T3WindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var windowModel: T3WindowModel?
    private var minuteTick: Timer?
    var visibilityChanged: (() -> Void)?
    var isVisible: Bool { window?.isVisible == true }

    static let referenceSize = NSSize(width: 1800, height: 1050)
    static let minimumSize = NSSize(width: 960, height: 600)
    /// T3's Electron traffic-light inset (`--workspace-controls-left` 12,
    /// `titlebar-area-height` 52).
    static let controlsLeft: CGFloat = 12
    static let titleBandHeight: CGFloat = 52

    func show(model: AppModel, screen: String?) {
        let wm = windowModel ?? T3WindowModel(model: model)
        windowModel = wm
        wm.focusedScreen = screen
        if let w = window, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let root = LockGate(lock: model.lock) { T3Root(model: wm, app: model) }
        let host = NSHostingController(rootView: root)
        host.sizingOptions = []            // never let the hosting view size the window
        let w = window ?? {
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: Self.referenceSize),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.contentMinSize = Self.minimumSize
            w.setFrameAutosaveName("Workspace")
            w.center()
            w.delegate = self
            return w
        }()
        let frame = w.frame
        w.contentViewController = host
        if frame.width < Self.minimumSize.width { w.setContentSize(Self.referenceSize); w.center() } else { w.setFrame(frame, display: true) }
        w.title = "Infinitus"
        window = w
        placeTrafficLights(w)
        wm.start()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.uiSurface("workspace", visible: true)
        visibilityChanged?()
    }

    func close() { window?.performClose(nil) }

    /// Electron puts the three buttons at x 12, centred in a 52 pt band.
    private func placeTrafficLights(_ w: NSWindow) {
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        var x = Self.controlsLeft
        for type in buttons {
            guard let b = w.standardWindowButton(type), let bar = b.superview else { continue }
            let y = bar.bounds.height - (Self.titleBandHeight + b.frame.height) / 2
            b.setFrameOrigin(NSPoint(x: x, y: y))
            x += b.frame.width + 6   // Electron's 6 pt gap between lights
        }
    }

    func windowDidResize(_ notification: Notification) { if let w = window { placeTrafficLights(w) } }
    func windowDidBecomeKey(_ notification: Notification) {
        minuteTick?.invalidate()
        minuteTick = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.windowModel?.tick() }
        }
        windowModel?.tick()
        windowModel?.model?.lock.surfaceShown()
    }
    func windowDidResignKey(_ notification: Notification) { minuteTick?.invalidate(); minuteTick = nil }
    func windowWillClose(_ notification: Notification) {
        minuteTick?.invalidate(); minuteTick = nil
        window?.contentViewController = nil            // detach: nothing ticks while hidden
        windowModel?.stop()
        windowModel?.model?.uiSurface("workspace", visible: false)
        windowModel?.model?.lock.surfaceHidden()
        visibilityChanged?()
    }
}
```

If `standardWindowButton(...).superview` reports a `bounds.height` that makes the lights land outside the title band (macOS 14 vs 15 differ), compute `y` from `w.contentLayoutRect` instead: `y = w.frame.height - w.contentLayoutRect.height … `; verify visually with the fixture (Step 8) and report the formula that worked. `lock.surfaceShown()`/`surfaceHidden()` exist (`StatusItemController.swift:190, 741`); if `surfaceHidden` is private to LockModel, mirror what `settingsClosed` calls.

`Sources/Infinitus/T3Window/T3Root.swift` — the placeholder Task 6 replaces:

```swift
import SwiftUI
import InfinitusCore
import InfinitusUI

struct T3Root: View {
    @ObservedObject var model: T3WindowModel
    @ObservedObject var app: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t3 = T3Environment(platform: .web, scheme: scheme)
        ZStack {
            t3.web.background.color.ignoresSafeArea()
            Text("\(model.state.threads.count) threads")
                .font(T3Font.web(.sm))
                .foregroundStyle(t3.web.mutedForeground.color)
        }
        .frame(minWidth: T3WindowController.minimumSize.width, minHeight: T3WindowController.minimumSize.height)
        .environment(\.t3, t3)
    }
}
```

(`T3Theme.WebPalette` fields are `T3RGBA` with `.color` — check `T3Theme.generated.swift` for the exact accessor name and use it.)

- [ ] **Step 6: Wiring** — `StatusItemController.swift`:
  - next to `wall` (:103): `private lazy var workspace: T3WindowController = { let w = T3WindowController(); w.visibilityChanged = { [weak self] in self?.syncLocalLease() }; return w }()`
  - in `StatusItemHolder.init` after `model.showWall = …` (:55): `model.showWorkspace = { [weak controller] screen in controller?.showWorkspace(screen: screen) }`
  - `syncLocalLease` (:456): add `model.uiSurface("workspace", visible: workspace.isVisible)`
  - new method beside `toggleWall` (:717): `func showWorkspace(screen: String?) { model.lock.surfaceShown(); workspace.show(model: model, screen: screen) }` — the workspace is NOT a mode: it does not close the popup or the pop-out.

  `MacSessionsPopover.swift` after the `SessionListCard(...)` (:26-31):

```swift
            Button {
                model.sessionsShown = false
                model.showWorkspace?(nil)
            } label: {
                Label("Open workspace", systemImage: "rectangle.3.group")
                    .font(PopupFont.caption)
            }
            .buttonStyle(.plain)
```

  Match the neighbouring rows' style (read how `CheckpointsSection`/`StartSessionSection` style their buttons and copy that; `PopupFont.caption` is what the surrounding labels use).

  `InfinitusApp.swift` — beside the ⌘F hidden button (:367-373), inside the same `.overlay { }` (turn the single `Button` into a `Group` of two if needed):

```swift
            Button("") { model.showWorkspace?(nil) }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .buttonStyle(.plain)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
```

  That overlay lives on the Settings window's root — a shortcut only fires while Settings is key. For the popup/pop-out, add the same hidden button to the popup root (`AnchoredRoot`/`PinnedRoot` — find where `.keyboardShortcut` is used in `InfinitusApp.swift`; if the popup roots have no overlay pattern, add the hidden button to `PinnedRoot` only and say so). Global (app-inactive) hotkeys are out of scope.

- [ ] **Step 7: Build and run the unit suites**

```bash
swift build --product Infinitus 2>&1 | grep -E 'error' | head; swift test --filter 'ControlProtocolTests|T3WorkspaceStateTests' 2>&1 | tail -3
```

- [ ] **Step 8: Smoke on the fixture** (mandatory; no e2e change yet — that is Task 16)

```bash
tools/t3ref/fixture.sh                      # debug app on /tmp/t3fix.sock
sleep 6
INFINITUS_CONTROL_SOCKET=/tmp/t3fix.sock .build/debug/infinitusctl show workspace | head -2
INFINITUS_CONTROL_SOCKET=/tmp/t3fix.sock .build/debug/infinitusctl windows | python3 -c "import json,sys; print([w for w in json.load(sys.stdin) if 'T3Root' in w['content'] or 'LockGate' in w['content']])"
INFINITUS_CONTROL_SOCKET=/tmp/t3fix.sock .build/debug/infinitusctl perf; sleep 15; INFINITUS_CONTROL_SOCKET=/tmp/t3fix.sock .build/debug/infinitusctl perf
tools/t3ref/fixture.sh --stop
```

Expected: `{"shown":"workspace"}`; a visible window whose `content` names the hosting view; idle CPU from the two `cpuSeconds` deltas ≤ 1 % over 15 s. Put the two perf lines in the report. Then close the window (⌘W in the window or `osascript -e 'tell application "System Events" to keystroke "w" using command down'` while it is key) and confirm `windows` shows it not visible and `perf` shows `leases` unchanged from before opening.

- [ ] **Step 9: Commit**

```bash
git add Sources/InfinitusCore/ControlProtocol.swift Sources/Infinitus/ControlServer.swift Sources/Infinitus/AppModel.swift Sources/Infinitus/StatusItemController.swift Sources/Infinitus/MacSessionsPopover.swift Sources/Infinitus/InfinitusApp.swift Sources/Infinitus/T3Window/T3WindowController.swift Sources/Infinitus/T3Window/T3WindowModel.swift Sources/Infinitus/T3Window/T3Root.swift Tests/InfinitusCoreTests/ControlProtocolTests.swift
git commit -m "workspace: the window shell — show workspace, Open workspace, ⌘⇧T; state model over the fleet tick (T3 clone B-5)"
```

**→ PR B-2 (`t3-clone-b2`)**: Tasks 4–5. Before opening, message Infi with the host hunks (AppModel `showWorkspace`/`applyAttention`, ControlServer `show workspace`, StatusItemController, MacSessionsPopover, InfinitusApp) — Infi rebuilds the Mac app after it merges. CHANGELOG: `- Open workspace: a T3-style window over your sessions, from the popup, ⌘⇧T, or infinitusctl show workspace.` — wait: the CHANGELOG line must not say "T3-style" (Naming rule). Use: `- Open workspace: a full window over your sessions — sidebar, thread, composer — from the popup, ⌘⇧T, or infinitusctl show workspace.`

---

## Before Task 6 — controller step, not a dispatch

Capture the Mac references the parity tasks compare against (the harness README's recipe, `tools/t3ref/refs/PROVENANCE.md` "what B must recreate"): in T3 Code (Alpha) 0.0.38, project `limitless`, one thread titled "Hi" with the two fixture messages, then

```bash
tools/t3ref/capture-mac.sh sidebar  tools/t3ref/refs/mac-sidebar.png
tools/t3ref/capture-mac.sh thread   tools/t3ref/refs/mac-thread.png
tools/t3ref/capture-mac.sh composer tools/t3ref/refs/mac-composer.png   # composer focused, "/" menu closed
```

Redact anything private (path, machine name) with the PROVENANCE rect convention, record the window size (expect 1800×1050 pt → 3600×2100 px on a 2× display), and commit them with PR B-3. Every UI task below says "compare against `refs/mac-<screen>.png`"; without the refs the reviewer cannot judge parity.

---

### Task 6: `T3Root` layout — sidebar | main | right panel, collapse and toggles

**Files:**
- Modify: `Sources/Infinitus/T3Window/T3Root.swift` (replace the Task 5 placeholder)
- Create: `Sources/Infinitus/T3Window/T3RightPanel.swift`, `Sources/Infinitus/T3Window/T3EmptyStates.swift`
- Upstream to transcribe: `~/death/t3code/apps/web/src/components/AppSidebarLayout.tsx` (262 lines — the whole layout), `components/ui/sidebar.tsx:27-29, 160-260` (widths, collapse), `components/threadSidebarWidth.ts` (min 208, default 256, main min 640), `components/NoActiveThreadState.tsx`, `components/NoProjectsHero.tsx`, `components/RightPanelTabs.tsx:990-1020` (tab strip only), `components/WorkspacePageHeader.tsx`.

**Interfaces:**
- Consumes: `T3WindowModel` (Task 5: `state.sidebarCollapsed`, `state.rightPanelOpen`, `state.threads`, `state.projects`, `state.selectedThread`, `toggleSidebar()`, `toggleRightPanel()`), `T3Theme.Metrics.sidebarWidth/sidebarWidthIcon/topbarHeight`, `T3Theme.WebPalette.background/sidebar/sidebarBorder/border/foreground/mutedForeground`, `T3Button`, `T3SidebarRail`, `LucideIcon`.
- Produces: `T3Root` with three slots the later tasks fill — `T3SidebarView` (Task 7; this task renders a `T3SidebarPlaceholder` listing thread titles), `T3TopBar` (Task 8; placeholder = breadcrumb text), `T3ThreadView` (Task 9; placeholder = `T3NoActiveThreadState`), `T3RightPanel` (this task: tab strip "Diff · Files · Pull request · Terminal · Agents" with T3's styling, every tab an empty state "Coming with a later release", hidden when `!state.rightPanelOpen`). `T3EmptyStates.swift`: `T3NoProjectsHero` ("What should we work on?" / "Add a project to start your first thread." / `T3Button("Add project", size: .sm)` with `LucideIcon(.plus)` — the button opens `model.startNewThread(projectId: nil)` which Task 15 wires; until then it is disabled), `T3NoActiveThreadState` (header "No active thread" `xs` `mutedForeground` at 50 %, body title "Pick a thread to continue" `xl`, description "Select an existing thread or create a new one to get started." `sm` `mutedForeground` at 78 %).

Layout rules (from `AppSidebarLayout.tsx` + `ui/sidebar.tsx`): the sidebar column is `Metrics.sidebarWidth` (256) or `Metrics.sidebarWidthIcon` (48) when collapsed, background `sidebar`, right border `sidebarBorder` 1 px; the main column has a `Metrics.topbarHeight` (52) header band that is also the window-drag region (`.fullSizeContentView` — the title band must stay draggable: put a `WindowDragRegion` `NSViewRepresentable` whose `mouseDownCanMoveWindow` returns true behind the top bar, interactive controls on top), then content; the right panel is a third column of width 360 minimum (T3 `RightPanelTabs` `min-w-[360px]` — confirm the literal in `RightPanelTabs.tsx`, use upstream's) with a left border `border`. The sidebar collapses to the icon rail with ⌘B (`keybindings.ts:34 "mod+b" → sidebar.toggle`); the right panel toggles with ⌘J (`:28 "mod+j"` — upstream binds ⌘J to `terminal.toggle` in some contexts; B has no terminal, so ⌘J toggles the panel and the report says so). Traffic lights: with the sidebar expanded the brand row starts after a 90 pt inset (`MACOS_TRAFFIC_LIGHTS_LEFT_INSET = "90px"`, `AppSidebarLayout.tsx:49`); collapsed, the rail's first icon sits below the lights.

- [ ] **Step 1: Skeleton** — `T3Root.swift`:

```swift
import SwiftUI
import AppKit
import InfinitusCore
import InfinitusUI

struct T3Root: View {
    @ObservedObject var model: T3WindowModel
    @ObservedObject var app: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t3 = T3Environment(platform: .web, scheme: scheme)
        HStack(spacing: 0) {
            sidebar(t3)
                .frame(width: model.state.sidebarCollapsed ? T3Theme.Metrics.sidebarWidthIcon : T3Theme.Metrics.sidebarWidth)
                .background(t3.web.sidebar.color)
                .overlay(alignment: .trailing) { Rectangle().fill(t3.web.sidebarBorder.color).frame(width: 1) }
            main(t3)
                .frame(minWidth: 640, maxWidth: .infinity)
            if model.state.rightPanelOpen {
                T3RightPanel(model: model)
                    .frame(minWidth: 360, idealWidth: 360)
                    .overlay(alignment: .leading) { Rectangle().fill(t3.web.border.color).frame(width: 1) }
            }
        }
        .background(t3.web.background.color)
        .frame(minWidth: T3WindowController.minimumSize.width, minHeight: T3WindowController.minimumSize.height)
        .environment(\.t3, t3)
        .background { keyboard }   // hidden buttons: the ⌘F pattern
    }

    @ViewBuilder private func sidebar(_ t3: T3Environment) -> some View {
        if model.state.sidebarCollapsed { T3SidebarRail() }          // A's rail primitive; Task 7 fills it
        else { T3SidebarPlaceholder(model: model) }                   // Task 7 replaces with T3SidebarView
    }

    @ViewBuilder private func main(_ t3: T3Environment) -> some View {
        VStack(spacing: 0) {
            ZStack {
                WindowDragRegion()
                T3TopBarPlaceholder(model: model)                    // Task 8 replaces with T3TopBar
            }
            .frame(height: T3Theme.Metrics.topbarHeight)
            if model.state.projects.isEmpty && model.state.threads.isEmpty {
                T3NoProjectsHero(action: nil)
            } else if model.state.selectedThread == nil {
                T3NoActiveThreadState()
            } else {
                T3ThreadPlaceholder(model: model)                    // Task 9 replaces with T3ThreadView
            }
        }
    }

    private var keyboard: some View {
        Group {
            Button("") { model.toggleSidebar() }.keyboardShortcut("b", modifiers: .command)
            Button("") { model.toggleRightPanel() }.keyboardShortcut("j", modifiers: .command)
        }
        .buttonStyle(.plain).opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }
}

/// The title band doubles as the drag region under `.fullSizeContentView`.
struct WindowDragRegion: NSViewRepresentable {
    final class DragView: NSView { override var mouseDownCanMoveWindow: Bool { true } }
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}
}
```

Placeholders (`T3SidebarPlaceholder`, `T3TopBarPlaceholder`, `T3ThreadPlaceholder`) are `private struct`s in `T3Root.swift`, each a `Text` in `T3Font.web(.sm)` — they exist only so this task builds and the fixture smoke shows three regions; Tasks 7–9 delete them.

- [ ] **Step 2: `T3RightPanel.swift` and `T3EmptyStates.swift`** — transcribe the tab strip from `RightPanelTabs.tsx:990-1020` (height, gap 1, tab font `sm` medium, selected = `foreground`, unselected = `mutedForeground`, underline/background per upstream) and the two empty states from the files named above. Tabs are a `@State private var tab = "diff"`; each body is `T3EmptyState(title: "<Tab> arrives with a later release", message: "")` — check `T3EmptyState`'s look against T3's `ui/empty.tsx` (`EmptyTitle` `xl`, `EmptyDescription` `sm` muted) and prefer a local `T3WebEmpty` view in `T3EmptyStates.swift` if the kit's mobile `T3EmptyState` diverges (it is the phone's component).

- [ ] **Step 3: Build, smoke, compare**

```bash
swift build --product Infinitus 2>&1 | grep error | head
tools/t3ref/fixture.sh; sleep 6
tools/t3ref/capture-ours.sh mac sidebar /tmp/ours-sidebar.png
python3 tools/t3ref/compare.py tools/t3ref/refs/mac-sidebar.png /tmp/ours-sidebar.png --out /tmp/diff-sidebar.png
tools/t3ref/fixture.sh --stop
```

Parity is not expected to pass yet (placeholders), but the **frame geometry** must: open `/tmp/diff-sidebar.png` and confirm the sidebar/main/title-band edges coincide (the heatmap shows no vertical band at x = 256 and no horizontal band at y = 52). Record the compare numbers in the report. Idle perf: two `infinitusctl perf` samples 15 s apart with the window open, ≤ 1 %.

- [ ] **Step 4: Commit**

```bash
git add Sources/Infinitus/T3Window/T3Root.swift Sources/Infinitus/T3Window/T3RightPanel.swift Sources/Infinitus/T3Window/T3EmptyStates.swift
git commit -m "workspace: three-column layout, icon rail, right-panel frame, empty states (T3 clone B-6)"
```

---

### Task 7: The sidebar — brand row, search, scope, project groups, thread rows, context menu

**Files:**
- Create: `Sources/Infinitus/T3Window/T3SidebarView.swift`, `Sources/Infinitus/T3Window/T3ThreadRowView.swift`, `Sources/InfinitusCore/T3/T3RelativeTime.swift`, `Sources/InfinitusCore/T3/T3ProjectIcon.swift` (port of `ProjectFavicon.tsx` `selectProjectIcon` + `PROJECT_ICONS`)
  (CORRECTION, B-3 review — upstream wins over this task's prose below: the desktop row's LEADING glyph is always the project icon (`ProjectFavicon.tsx:44-123`: favicon → emoji → a Lucide icon from the 22-entry `PROJECT_ICONS` table chosen by `selectProjectIcon`, coloured per name/cwd — never an initial letter); status is a TRAILING text label per `SidebarThreadRow`'s `topStatus` (`Sidebar.tsx` ≈:1155-1177), never a leading `hand`/`message-circle-question`/`circle-x` glyph. Brand row inset when expanded = 90 + 28 + 12 = 130 pt (`AppSidebarLayout.tsx:49`, `ui/sidebar.tsx:169-170`, `SidebarChrome.tsx:89`).)
  (Width, from upstream `threadSidebarWidth.ts`: expanded width = `min(Metrics.sidebarWidth, max(208, windowWidth - 640))` — 208 = `THREAD_SIDEBAR_MIN_WIDTH`, 640 = `THREAD_MAIN_CONTENT_MIN_WIDTH`; read the window width with a `GeometryReader` at the root and pass it down. CORRECTION (B-3 whole-branch review): upstream mounts `<Sidebar collapsible="offcanvas">` (`AppSidebarLayout.tsx:227`, `ui/sidebar.tsx:285,298`) — collapsed width is 0 and the container slides off-screen; `SIDEBAR_WIDTH_ICON` (48) is for `collapsible="icon"`, which T3 never uses. Collapsed = no sidebar column at all; the top bar's 130 pt inset then starts content 12 pt right of the toggle. Row variants (`Sidebar.tsx:4627` `isCard = section === "active" || section === "pinned"`): active/pinned rows are CARDS — `h-[4.875rem]` 78 pt, two lines: project display name on top, title below, `topStatus` pill in the status slot (`:1723-1815`); snoozed/settled rows are SLIM — 36 pt, `h-9 gap-2.5 px-2.5` (`:1538-1636`), trailing `settledTimeLabel`/`threadTimeLabel` only, never `topStatus`. Tailwind colour stops come from the pinned tailwindcss@4 `theme.css` (OKLCH), generated by `gen-tokens.py`, never hand-typed v3 hex.)
- Modify: `Sources/Infinitus/T3Window/T3Root.swift` (drop `T3SidebarPlaceholder`)
- Test: `Tests/InfinitusCoreTests/T3/T3RelativeTimeTests.swift`
- Upstream: `components/Sidebar.tsx` (203 k — read the render tree: brand row, search input, "New thread" control, scope/project header, the `SidebarThreadRow`/v2 row, section headers `Pinned`/`Snoozed`/`Settled`, the settled "Show more" paging), `components/Sidebar.logic.ts` (already ported as `T3SidebarList`; use it for `rowStyle`, `hasUnseenCompletion`, markers), `components/ThreadStatusIndicators.tsx` + `Sidebar.logic.ts resolveThreadStatusPill` (status glyph per `T3ThreadStatus`), `components/threadActionMenu.logic.ts` (menu order — port `buildThreadActionMenuItems` into `T3ThreadRowView` as a Swift `Menu`/`contextMenu`, keeping only the items B has a host action for: pin/unpin, settle/unsettle, snooze ▸ presets (`T3ThreadSettled.snoozePresets(now:)`, disabled when `!T3ThreadSettled.canSnooze`), wake, Copy ▸ Path / Thread ID; `rename`, `regenerate-title`, `mark-unread`, `project-settings`, `archive`, `delete`, `new-thread-on-branch` are omitted — say so in a comment citing the plan's deviation table), `components/ProjectFavicon.tsx` (project glyph: first letter on a rounded square unless a favicon exists — no favicons on the Mac: letter only), `components/sidebar/SidebarChrome.tsx` (footer: settings gear, update pill — B shows the gear only, opening `app.showSettings?()`), the relative-time formatter (`grep -rn "formatRelativeTime\|formatTimeAgo\|relativeTime" ~/death/t3code/apps/web/src/lib ~/death/t3code/packages/shared/src | head` — port it to `T3RelativeTime.label(from:now:)` in Core and transcribe its `.test.ts` into `T3RelativeTimeTests` as a data table: every upstream `it` transcribed or explicitly skipped in the report).

**Interfaces:**
- Consumes: `T3WindowModel.state.sidebarSections(now:)`, `.groups`, `.scope`, `.search`, `select(_:)`, `setScope`, `setSearch`, `attention(_:threadId:until:)`, `model.now`; `T3SidebarList.rowStyle(isActive:isSelected:)`, `T3SidebarList.hasUnseenCompletion`, `T3ThreadStatus(_:)`, `T3ThreadSettled.snoozePresets/canSnooze/snoozeWakeLabel`; kit: `T3Input(text:placeholder:leading:)`, `T3SidebarGroup`, `T3SidebarMenuItem`, `T3Button`, `T3Tooltip`, `T3Kbd`, `T3Badge`, `T3ProviderIcon`, `T3Wordmark`, `LucideIcon`; tokens `sidebar`, `sidebarForeground`, `sidebarMutedForeground`, `sidebarRowHover`, `sidebarRowSelected`, `sidebarRowActive`, `sidebarControlSurface`, `sidebarBorder`, `Metrics.sidebarContentInset` (8), `Metrics.sidebarRowContentInset` (10).
- Produces: `T3SidebarView(model:app:)`, `T3ThreadRowView(thread:selected:now:onSelect:onAttention:)`, `T3RelativeTime.label(from: Date, now: Date) -> String` (e.g. "now", "5m", "2h", "3d", "Sep 2" — whatever upstream returns; the test table is the contract), `T3ProjectGlyph(name:)`.

Behaviour: sections render in `sidebarSections(now:)` order with the upstream headers (`Pinned` shows a header only when ≥ 1 pinned; `Snoozed` and `Settled` are collapsible shelves — read `Sidebar.tsx` for the default collapsed state and the "Show N more" paging: `T3ThreadList` already ported the 10/25 paging constants — reuse them), each row: status glyph (`T3ThreadStatus` → approval `hand` amber, input `message-circle-question` info, working `T3Spinner(size: 14)`, failed `circle-x` destructive, ready = project glyph — take the exact icon names and colour classes from `resolveThreadStatusPill` in `Sidebar.logic.ts`), title (`sm`, truncated, medium weight when `rowStyle.medium`), trailing relative time (`xs`, `sidebarMutedForeground`), unseen dot when `hasUnseenCompletion`. Clicking selects; right-click shows the menu. The search field filters through `setSearch` (⌘F while the window is key focuses it — hidden button in this view). The scope picker is a `Menu` over `groups` ("All projects" + one row per group with `displayName`); the "+" opens a new draft in the current scope (Task 15 wires `startNewThread`; until then disabled with T3's tooltip "New thread ⌘N").

- [ ] **Step 1: `T3RelativeTime` failing tests** — transcribe upstream's test file as a table `[(seconds: TimeInterval, expected: String)]` plus the date-fallback cases; run `swift test --filter T3RelativeTimeTests` → fails.
- [ ] **Step 2: Port `T3RelativeTime`** (Foundation only; `Calendar` injected with a `.current` default and tests pinning `TimeZone(identifier: "UTC")`, like `T3ThreadSettledTests`). Run → pass.
- [ ] **Step 3: Views** — write `T3SidebarView` and `T3ThreadRowView` per the interfaces; replace the placeholder in `T3Root`. Every colour/size is a token or a `T3Font.web*` step; when `Sidebar.tsx` uses a literal (`text-[13px]`, `h-7`, `px-2.5`), use `T3Font.webLiteral(13)` / the px value ×1 pt and cite the class in a comment.
- [ ] **Step 4: Smoke + compare** against `refs/mac-sidebar.png` (fixture: one thread "Hi", project `limitless`, status waiting → `input` glyph). Target ≤ 1.5 % over ΔE 6 for the **sidebar column crop** (`compare.py` accepts full frames; crop both to x 0–256 with `sips -c` or Pillow first — document the crop command). Paste numbers into the report. Idle perf ≤ 1 %.
- [ ] **Step 5: Commit**

```bash
git add Sources/Infinitus/T3Window/T3SidebarView.swift Sources/Infinitus/T3Window/T3ThreadRowView.swift Sources/Infinitus/T3Window/T3Root.swift Sources/InfinitusCore/T3/T3RelativeTime.swift Tests/InfinitusCoreTests/T3/T3RelativeTimeTests.swift
git commit -m "workspace: the sidebar — project groups, thread rows, sections, search, scope, attention menu (T3 clone B-7)"
```

---

### Task 8: Top bar — breadcrumb, Open, Add action, Commit & push, panel toggles

**Files:**
- Create: `Sources/Infinitus/T3Window/T3TopBar.swift`
  (When no thread is selected the top bar IS upstream's `WorkspacePageHeader` for `NoActiveThreadState` — the "No active thread" band at `topbarHeight` with the bottom border — and `T3NoActiveThreadState` drops its own label row (Task 6 left it stacked under the placeholder bar; remove that row here). B-3 review.)
- Modify: `Sources/Infinitus/T3Window/T3Root.swift` (drop `T3TopBarPlaceholder`)
- Upstream: `components/WorkspacePageHeader.tsx`, `components/WorkspaceBreadcrumb.tsx` (items `sm` medium; current = `foreground`, others `mutedForeground`; separator "/" in `iconMuted`; gap 2 → 3 at `sm`), `components/chat/ChatHeader.tsx` (the thread header: breadcrumb `project / thread title`, then the action cluster), `components/chat/OpenInPicker.tsx` (menu: Finder, Terminal, VS Code, Cursor, … — B ships the entries whose app is installed: check with `NSWorkspace.shared.urlForApplication(withBundleIdentifier:)` for `com.microsoft.VSCode`, `com.todesktop.230313mzl4w4u92` (Cursor), `com.apple.Terminal`, `com.googlecode.iterm2`; Finder always; each opens the project's cwd), `components/ProjectScriptsControl.tsx` (the "Add action" control — B renders the button and a menu with one disabled row "Project actions arrive with a later release"), `components/GitActionsControl.tsx` (the "Commit & push" split button — disabled, tooltip text from upstream's disabled state), `components/chat/PanelLayoutControls.tsx` (sidebar / right-panel toggles with `T3Kbd("⌘B")`, `T3Kbd("⌘J")` tooltips).

**Interfaces:**
- Consumes: `model.state.selectedThread` (title), the thread's project (`state.projects.first { $0.id == thread.projectId }` → name, cwd), `model.toggleSidebar/toggleRightPanel`, kit `T3Button(variant: .ghost/.outline, size: .sm/.icon)`, `T3Tooltip`, `T3Kbd`, `LucideIcon`, tokens `toolbarBackground`, `toolbarBorder`, `toolbarControl`, `toolbarControlForeground`, `toolbarControlHover`, `toolbarForeground`, `border`.
- Produces: `T3TopBar(model:app:)` — height `Metrics.topbarHeight`, bottom border `border` 1 px (T3 `border-b border-border`), content inset per `WorkspacePageHeader.tsx`, left inset 0 when the sidebar is expanded (lights sit over the sidebar) and 90 pt when collapsed.

- [ ] **Step 1: Transcribe** the header row and the four controls; no thread selected → breadcrumb shows the "No active thread" text from `NoActiveThreadState` (and the actions hide except the two toggles).
- [ ] **Step 2: Smoke + compare** against the top 52 pt band of `refs/mac-thread.png` (crop y 0–52, x 256–1440); numbers in the report; idle perf ≤ 1 %.
- [ ] **Step 3: Commit**

```bash
git add Sources/Infinitus/T3Window/T3TopBar.swift Sources/Infinitus/T3Window/T3Root.swift
git commit -m "workspace: the top bar — breadcrumb, Open in, Add action, Commit & push, panel toggles (T3 clone B-8)"
```

**→ PR B-3 (`t3-clone-b3`)**: Tasks 6–8 + the three Mac reference PNGs. CHANGELOG: `- Workspace: sidebar with project groups, pinned/snoozed/settled shelves, and the thread header bar.`

---

### Task 9: `T3TimelineStore` — the selected thread's rows, long-polled

**Files:**
- Create: `Sources/Infinitus/T3Window/T3TimelineStore.swift`
- Create: `Sources/InfinitusCore/T3/T3TimelineInput.swift` (the pure part), Test: `Tests/InfinitusCoreTests/T3/T3TimelineInputTests.swift`

**Interfaces:**
- Consumes: `SessionChatStore` (`SessionChatWindow.swift:77-160`) as the shape to copy — one `Task.detached(priority: .utility)` loop, `SessionFeedReader.waitForChange(pid:claudeDir:since:wait:decorate:wake:)`, `OwnedFeed.decorate`, `model.ownedBox`; `TimelineCache.timeline(record:claudeDir:)` (`AppModel.timelineCache`), `SessionTimeline.appending(pending:)`, `PendingRequests.derive(_:)`, `T3TimelineEntry.entries(from:pending:)`, `T3TimelineRows.Input` / `.derive` / `.stable`, `T3TimelineRows.LatestTurn`, `SessionFacts`.
- Produces:
  ```swift
  // Core, pure:
  public enum T3TimelineInput {
      /// SessionTimeline (+ owned pending) → the rows reducer's input.
      public static func make(timeline: SessionTimeline, pending: [PendingRequest], facts: SessionFacts?,
                              expandedTurnIds: Set<String>, expandedWorkGroupIds: Set<String>) -> T3TimelineRows.Input
      // latestTurn = timeline.latestTurn mapped to LatestTurn; runningTurnId = latest turn when .running;
      // isWorking = facts?.status == .running || latest turn .running; activeTurnStartedAt = running turn's startedAt ?? requestedAt;
      // turnDiffSummaries = [] (E); supportsConversationRollback = false (E).
  }
  // Infinitus:
  @MainActor final class T3TimelineStore: ObservableObject {
      @Published private(set) var rows: [T3TimelineRows.Row]
      @Published private(set) var timeline: SessionTimeline?
      @Published private(set) var pending: PendingRequests     // approvals + user inputs above the composer (Task 12)
      @Published private(set) var limits: [LimitNote]          // owned usage limits (Task 12)
      @Published private(set) var gone: Bool
      let threadId: String; private(set) var pid: Int32
      init(threadId: String, pid: Int32, model: AppModel, window: T3WindowModel)
      func start(); func stop(); func rebind(pid: Int32)      // resume under a new pid keeps the store
      func rederive()                                          // on expandedTurnIds/groups change (no disk read)
  }
  ```
  `rows` is always `T3TimelineRows.stable(previous: rows, next: derive(input))` so the live slot keeps its id (LazyVStack identity). Images: `image(id:)` like `SessionChatStore.image(id:)`.

- [ ] **Step 1: Failing tests** for `T3TimelineInput.make` (running turn → `isWorking`, `runningTurnId`, `activeTurnStartedAt`; completed turn → none; expanded sets pass through; pending approvals fold into entries — assert one `T3WorkLogEntry` with `requestKind == .approval` appears when `pending` has one `PendingRequest` of tool kind). Build the timeline with `SessionTimeline(turns:messages:activities:)` literals; run `swift test --filter T3TimelineInputTests` → fails.
- [ ] **Step 2: Implement `T3TimelineInput`** (≈ 30 lines; read `T3TimelineEntry.entries(from:pending:)` at `T3TimelineEntry.swift:219` to see how pending is folded — pass `pending` through, do not fold twice). Run → pass.
- [ ] **Step 3: Implement the store** — copy `SessionChatStore.start()` verbatim, then replace the `SessionFeedReader.read` line with `model.timelineCache.timeline(record:claudeDir:)`, compute `pending = PendingRequests.derive(timeline.activities)` merged with `owned?.pending(pid:)`, `limits = owned?.limits(pid:) ?? []`, build `T3TimelineInput.make(...)` with the window model's expanded sets for `threadId`, then `await MainActor.run { rows = stable(...); timeline = …; pending = …; limits = … }`. `rederive()` re-runs `make` + `stable` from the cached `timeline` synchronously on the main actor (no I/O). `rebind(pid:)` cancels and restarts the loop under the new pid. Guard every `record` lookup by `sessionId == threadId` **and** pid, so a pid reuse by an unrelated session shows `gone`, not a foreign transcript.
- [ ] **Step 4: Build; smoke** with the fixture: open the workspace, select "Hi" (Task 7's sidebar — if this task runs before Task 7 merges in your branch, select via a temporary `INFINITUS_WORKSPACE_THREAD=<sessionId>` env seam in `T3WindowModel.start()` and remove it in this same task before commit), confirm in the log (`/tmp/t3fix.log`) or a temporary `print` that `rows.count > 0` — remove prints before committing. Idle perf ≤ 1 % with the store running. Pass `poll: 1.0` to `waitForChange` (its 0.3 s default re-lists `sessions/*.json` three times a second; the chat window tolerates that for one pid — the workspace should not start there). Two `perf` samples must show ≤ 1 %; report the numbers.
- [ ] **Step 5: Commit**

```bash
git add Sources/InfinitusCore/T3/T3TimelineInput.swift Tests/InfinitusCoreTests/T3/T3TimelineInputTests.swift Sources/Infinitus/T3Window/T3TimelineStore.swift
git commit -m "workspace: per-thread timeline store — long-poll to stable T3 rows (T3 clone B-9)"
```

---

### Task 10: Markdown — tables, task lists, fence copy; `T3ChatMarkdown` styling

**Files:**
- Modify: `Sources/InfinitusUI/MarkdownText.swift`
  (STATE OF THE TREE at dispatch, B-4: `MarkdownText.Block` ALREADY has `.task(done:_)`, `.rule`, `.table(header:rows:)` and `.code(language:_)` (phone PR #360, tests in `ios/InfinitusMobileTests/MarkdownBlocksTests.swift`). Remaining parser work is only the nested-list `indent`. The move to Core keeps the phone compiling: `public typealias Block = MarkdownBlock` inside `MarkdownText` and `static func blocks(_:) -> [Block]` forwarding to `MarkdownBlocks.parse`, so the phone keeps compiling; the enum carries `indent:` cleanly (no factory shim — agreed with the phone's owner): update the three positional sites — `MarkdownText.swift` renderer `case .bullet(let text)` / `case .numbered(let number, let text)` (≈:113/:118, add `indent: let indent` and draw `.padding(.leading, CGFloat(indent) * 14)` there too) and `ios/InfinitusMobileTests/MarkdownBlocksTests.swift:14` `.bullet("plain")` → `.bullet(indent: 0, "plain")`; nothing else in `ios/` changes. Lift the phone test's four cases into `Tests/InfinitusCoreTests/MarkdownBlocksTests.swift` alongside the new indent cases. Case labels stay exactly as they are today (`.code(language:_)`, `.numbered(_,_)`, `.task(done:_)`) — do not rename.)
- Create: `Sources/InfinitusUI/T3/Components/T3ChatMarkdown.swift`
- Test: `Tests/InfinitusCoreTests/…` cannot see `InfinitusUI` (Package.swift: the test target depends on Core only). **Put the block parser in Core**: move `MarkdownText.blocks(_:)` and `Block` to a new `Sources/InfinitusCore/MarkdownBlocks.swift` (`public enum MarkdownBlock`, `public enum MarkdownBlocks { public static func parse(_ text: String) -> [MarkdownBlock] }`), have `MarkdownText` call it, and test the parser in `Tests/InfinitusCoreTests/MarkdownBlocksTests.swift`.
- Upstream: `components/ChatMarkdown.tsx:669-760` (`MarkdownTable`: header row, `copy table`, cell expand), `:880-1010` (code block: language label, `Copy code`, monospace, `codeBackground`/`codeForeground`), `:2957-2990` (`MarkdownCode` inline vs fenced), task-list rendering (`grep -n "task-list\|checkbox\|input" components/ChatMarkdown.tsx`), and `ChatMarkdown.test.tsx` for the parser expectations you can transcribe (tables, nested lists, task items).

**Interfaces:**
- Produces: `MarkdownBlock` adds `.table(header: [String], rows: [[String]])`, `.task(done: Bool, text: String)`, `.code(language: String?, code: String)` (language from the fence info string), and `.bullet`/`.numbered` gain an `indent: Int` (0-based, two spaces or a tab per level) so nested lists render; `MarkdownText` renders them with its existing look (the phone keeps using it); `T3ChatMarkdown(text:)` renders the same blocks with T3's styling: paragraph `sm`/`messageForeground`, headings per `ChatMarkdown.tsx` (`h1 text-xl font-semibold`, `h2 text-lg`, `h3 text-base`), code fence = `codeBackground` surface, radius `Metrics.controlRadius`, a header row with the language (`xs`, `mutedForeground`) and a `Copy code` ghost button (`NSPasteboard.general`; label flips to "Copied" for 1.5 s via a `Task.sleep`, not a Timer), table = grid with header `medium`, `border` hairlines, horizontal scroll in `T3ScrollArea`, task item = `LucideIcon(.squareCheck / .square)` + text. Block rendering is memoized per message id by the row view (Task 11) — `T3ChatMarkdown` itself is a plain view.

- [ ] **Step 1: Failing parser tests** (`MarkdownBlocksTests`): a pipe table with a `|---|---|` separator → `.table` with trimmed cells; a table without the separator line → paragraphs (not a table); `- [ ] a` / `- [x] b` → `.task(done: false/true)`; nested `  - child` → `.bullet(indent: 1)`; ```` ```swift ```` → `.code(language: "swift", …)`; the existing behaviours (heading, quote, soft-wrap paragraph) keep passing. Run → fails.
- [ ] **Step 2: Move + extend the parser**; update `MarkdownText` to the new cases (tables render as a simple grid in the phone look; tasks as ☐/☑ + text; indent → leading padding `indent × 14`). Run parser tests → pass; `swift build` for both `InfinitusUI` and the iOS target is CI's job (`ios` check) — but grep `ios/` for `MarkdownText.Block` / `.blocks(` uses and update them (the phone imports `InfinitusUI`, so a renamed static breaks the `ios` check).
- [ ] **Step 3: `T3ChatMarkdown`** per the interface; a `#Preview` with a message that has all block kinds.
- [ ] **Step 4: Commit**

```bash
git add Sources/InfinitusCore/MarkdownBlocks.swift Tests/InfinitusCoreTests/MarkdownBlocksTests.swift Sources/InfinitusUI/MarkdownText.swift Sources/InfinitusUI/T3/Components/T3ChatMarkdown.swift
git commit -m "markdown: tables, task lists, fence languages, nested lists — parser in Core; T3ChatMarkdown styling (T3 clone B-10)"
```

---

### Task 11: Timeline row views and the thread view

**Files:**
- Create: `Sources/Infinitus/T3Window/T3TimelineRowViews.swift`, `Sources/Infinitus/T3Window/T3ThreadView.swift`
- Modify: `Sources/Infinitus/T3Window/T3Root.swift` (drop `T3ThreadPlaceholder`)
- Upstream (`components/chat/MessagesTimeline.tsx`, by function): `TimelineRowContent` :1175 (the switch), `UserTimelineRow` :1296 + `UserMessageBody` :2426 + `shouldCollapseUserMessage` :2347 + `CollapsibleUserMessageBody` :2358 (the user bubble on `messageSurface`, collapse over N lines with "Show more"), `AssistantTimelineRow` :1559, `AssistantMetaTimelineRow` :1603 + `AssistantMessageMeta` :1621 + `AssistantCopyButton` :1665 (time, copy; diff stat slot empty in B), `TurnFoldTimelineRow` :1539 ("Worked for 2m 14s" — label comes from the reducer's `turnFold.label`), `ContextCompactionTimelineRow` :1236, `ProposedPlanTimelineRow` :1687 + `ProposedPlanCard.tsx`, `WorkingTimelineRow` :1707 + `WorkingTimer` :1769 + `formatWorkingTimer` :2677 (**the timer: T3 ticks every second; B must not** — render the elapsed label from `model.now` (60 s tick) formatted like `formatWorkingTimer`, and add the shimmer via `T3LoadingStrip`/`ActivityShimmerOverlay` as a `LayerEffect`; say so in a comment), `ThinkingTimelineRow` :1742, `WorkGroupSection` :1797 + `ExpandedWorkGroupEntries` :1848 (the `work` row: grouped entries with `T3WorkLog.ToolPresentation` icon/label/detail), `LiveActivityRow` :2014 + `LiveWorkEntryTimelineRow` :2106 (`workLive`), `WorkGroupToggleTimelineRow` :2160 + `toolGroupSummaryIconName` :2130 (`workToggle`: chevron, summary text, hidden count, failure tint `toolErrorIcon`), `useStableRows` :2660 (done by the reducer), `timelineScrollAnchoring.ts` (three modes: following-end, anchoring-new-turn, free-scrolling; `CHAT_TIMELINE_ANCHOR_OFFSET = 24`).

**Interfaces:**
- Consumes: `T3TimelineStore.rows` (Task 9), `T3TimelineRows.Row` (all ten cases), `T3WorkLog.ToolPresentation` (icon → `Lucide` case mapping: read `T3WorkLog.ToolPresentation.Icon` and map each to a `Lucide`/`T3Symbol`; `T3ProviderIcon` for the assistant avatar), `T3ChatMarkdown` (Task 10), `model.toggleTurn/toggleWorkGroup` → `store.rederive()`, `model.now`, tokens `messageSurface`, `messageForeground`, `messageAction*`, `foreground`, `mutedForeground`, `iconMuted`, `toolErrorIcon`, `border`, `surfaceRaised`, `Metrics.radius`.
- Produces: `T3TimelineRowView(row:store:model:)` switching on `Row`; `T3ThreadView(model:app:store:)` = `ScrollViewReader` + `ScrollView` + `LazyVStack(spacing: 0)` with `.id(row.id)`, `max-width 48 rem` (768 pt) centred content column, a bottom inset equal to the composer height + 16 (Task 13 publishes the height through a `PreferenceKey`), scroll anchoring: track `atEnd` via a bottom sentinel `onGeometryChange`; on `rows` change, if `atEnd` → `scrollTo(last, anchor: .bottom)`; when a new user turn appears (a `.message` row with `role == .user` whose id was not in the previous rows) → scroll so that row's top sits `24` below the viewport top (`anchoring-new-turn`); on a disclosure toggle → keep the toggled row's `minY` fixed (read it before, `scrollTo(id, anchor: .top)` after with the same offset). Markdown views are cached per `(messageId, text.count, streaming)` in a `@StateObject` `NSCache`-backed store so a live tail re-renders only the streaming message.

- [ ] **Step 1: Row views** — one `private struct` per case, transcribed from the functions above; every visible size from upstream classes (`text-[15px]` → `webLiteral(15)`, `gap-2` → 8, `px-4` → 16, `rounded-2xl` → 16, …) with the class cited in a comment.
- [ ] **Step 2: `T3ThreadView`** with the anchoring rules; the banners/panels slot (Task 12) is a `VStack` above the composer placeholder.
- [ ] **Step 3: Smoke + compare** against `refs/mac-thread.png` (fixture rows: user "Hi", assistant reply, the `AskUserQuestion` → `user-input.requested` work row, the open `Write` → `approval.requested`). Crop x 256–1440, y 52–(bottom − composer). Target ≤ 1.5 %; numbers in the report. Idle perf ≤ 1 % with the thread open and the Write approval pending (a shimmer is running: it must be a CAAnimation).
- [ ] **Step 4: Commit**

```bash
git add Sources/Infinitus/T3Window/T3TimelineRowViews.swift Sources/Infinitus/T3Window/T3ThreadView.swift Sources/Infinitus/T3Window/T3Root.swift
git commit -m "workspace: the thread timeline — ten row kinds, folds, work groups, live row, scroll anchoring (T3 clone B-11)"
```

---

### Task 12: Pending approval / user-input panels, plan card actions, banners

**Files:**
- Create: `Sources/Infinitus/T3Window/T3PendingPanels.swift`
- Modify: `Sources/Infinitus/T3Window/T3ThreadView.swift` (mount the stack above the composer), `Sources/Infinitus/T3Window/T3TimelineRowViews.swift` (plan card buttons)
- Upstream: `components/chat/ComposerPendingApprovalPanel.tsx` + `ComposerPendingApprovalActions.tsx` (Approve / Approve for session / Deny with a reason field; tool name + summary + the command in a code surface), `ComposerPendingUserInputPanel.tsx` (question title, options as radio/checkbox per `question.multiSelect`, free-text "Other", Submit), `ComposerBannerStack.tsx` + `ComposerBanner.tsx` (stacked banners: error, usage limits, plan follow-up), `ThreadErrorBanner.tsx` (dismiss-for-session key), `ComposerUsageLimits.tsx` (`usageLimitsBannerItem`), `ProposedPlanCard.tsx` (Approve → "Implement", Edit → text into composer).

**Interfaces:**
- Consumes: `T3TimelineStore.pending` (`PendingRequests.approvals: [PendingApproval]`, `.userInputs: [PendingUserInput]` — read `PendingRequests.swift:8-25` for field names), `T3TimelineStore.limits: [LimitNote]`, owned in-memory `PendingRequest` (`OwnedWire.swift:90`, with `questions` and `planMarkdown`), `AppModel.deliverSessionInput(pid:_:from:)` with `SessionInput.Request(kind: .approve, text: "", requestId:)`, `.key "n"` / owned `.deny(message:)` via `OwnedSessions.answer(pid:requestId:decision:)`, `.answers` with `[questionId: answer]` JSON in `text` (see how the phone encodes answers: `grep -rn 'kind: .answers' ios Sources | head`), `OwnedWire.supportsOwnedSessions(version:)`, `model.ownedSessions()`.
- Produces: `T3PendingApprovalPanel(approval:onDecision:)`, `T3PendingUserInputPanel(input:onSubmit:)`, `T3BannerStack(items:)` with `T3Banner(kind: .error/.warning/.info, title:, body:, dismiss:)`, `T3UsageLimitsBanner(limits:)`, a `T3ThreadActions` helper (`@MainActor`, wraps `deliverSessionInput` on a detached task, publishes `sending`/`note` like `SessionChatStore.send`). Terminal-hosted sessions: Approve = key `1` (`SessionInput.deliver` rewrites `.approve` itself), Deny = key `esc` — "Approve for session" and the deny reason field are hidden unless the session is owned (capability gate). A user-input panel for a terminal session shows the options but only the numbered keys `1…9` are deliverable — free text answers are owned-only.

- [ ] **Step 1: Transcribe** the four panels/banners with tokens (`warningSurface/warningForeground`, `errorSurface/errorForeground`, `infoForeground`, `surfaceRaised`, `border`).
- [ ] **Step 2: Wire** into `T3ThreadView` above the composer slot; the plan card's Approve sends `.approve` on the matching `approval.requested` (the parked `ExitPlanMode`), Edit puts `planMarkdown` into the composer draft (Task 13's `T3ComposerDraft` binding — until then a `@Published var pendingComposerInsert: String?` on `T3WindowModel`).
- [ ] **Step 3: Smoke** on the fixture: the `Write` approval panel and the two-question input panel render; press Deny → the fixture session is fake (no process), so `deliverSessionInput` returns `outcome != "delivered"` — the note appears under the panel, nothing crashes. Compare the composer band against `refs/mac-composer.png` only for geometry (the reference has no pending panel); numbers in the report.
- [ ] **Step 4: Commit**

```bash
git add Sources/Infinitus/T3Window/T3PendingPanels.swift Sources/Infinitus/T3Window/T3ThreadView.swift Sources/Infinitus/T3Window/T3TimelineRowViews.swift
git commit -m "workspace: approval and user-input panels, banners, plan card actions over SessionInput (T3 clone B-12)"
```

**→ PR B-4 (`t3-clone-b4`)**: Tasks 9–12. Tell Infi3 before opening: `MarkdownText.blocks`/`Block` moved to Core `MarkdownBlocks` (the phone imports `MarkdownText`; API additive except the static's new home). CHANGELOG: `- Workspace: the thread view — timeline, work groups, approvals and questions answered in place, richer markdown.`

---

### Task 13: The composer — prompt, send/stop, queue badge, permission and model controls, attachments

**Files:**
- Create: `Sources/Infinitus/T3Window/T3ComposerView.swift`
- Create: `Sources/InfinitusCore/T3/T3ComposerDraft.swift`, Test: `Tests/InfinitusCoreTests/T3/T3ComposerDraftTests.swift`
- Modify: `Sources/Infinitus/T3Window/T3ThreadView.swift` (mount; publish composer height), `Sources/Infinitus/T3Window/T3WindowModel.swift` (drafts + history persistence)
- Upstream: `components/chat/ChatComposer.tsx` (the surface: `ComposerSurface.tsx` floating card 16 pt inset, radius, `surfaceRaised` + `border`; the textarea; footer row with controls left, primary actions right), `ComposerPrimaryActions.tsx` (Send ⏎ / Stop ■ / queued count badge `ComposerTasksBadge.tsx`), `ComposerControl.tsx` + `CompactComposerControlsMenu.tsx` (pill controls: permission mode, model, attach), `composerSubmission.ts` (send rules: trim, empty → no-op, running → queue), `useComposerMultilinePrompt.ts` (⏎ send, ⇧⏎ newline), `composerPromptHistory.ts` (last N prompts per project — read the constant), `composerAttachmentFiles.ts` (accepted types, size cap), `ComposerPromptLengthValidation.tsx` (length cap message), `ContextWindowMeter.tsx` (out of scope — no usage source; omit and say so).

**Interfaces:**
- Consumes: `SessionInput.Request(kind:text:attachments:requestId:queuedAt:sessionId:commandId:)`, `SessionInput.maxMessageLength` (4000), `maxAttachments` (4), `maxAttachmentBytes`, `allowedAttachmentMimes`; `OwnedWire.imageMediaTypes`; `SessionStart.hookModes` (running-session permission change: supervised / acceptEdits / bypassPermissions) + `SessionStart.modeRank` ("a start mode is a floor"); `OwnedSessions.setPermissionMode(pid:mode:)` via `model.ownedSessions()`; `model.sessionBirths[pid]?.permissionMode` (the floor); `SessionInput.Request(kind: .key, text: "esc")` = Stop; `T3TimelineStore.timeline?.latestTurn?.state == .running` = running; `T3ThreadActions` (Task 12).
- Produces:
  ```swift
  // Core
  public struct T3ComposerDraft: Codable, Sendable, Equatable {
      public var text: String; public var attachments: [T3ComposerAttachmentRef]   // file URLs as paths; data read at send
      public static let historyLimit = 50   // ours: T3 recalls prompts from the thread's own user messages (composerPromptHistory.ts has no cap); we persist a flat list, capped
  }
  public enum T3ComposerDrafts {
      public static func load(from data: Data?) -> [String: T3ComposerDraft]       // by threadId (or "draft:<uuid>")
      public static func save(_ drafts: [String: T3ComposerDraft]) -> Data
      public static func pushHistory(_ history: [String], prompt: String, limit: Int = T3ComposerDraft.historyLimit) -> [String]  // dedup, newest first, capped
      public static func canSend(text: String, running: Bool, maxLength: Int = SessionInput.maxMessageLength) -> SendVerdict  // .send, .queue, .empty, .tooLong(Int)
  }
  ```
  `T3WindowModel` gains `@Published var drafts: [String: T3ComposerDraft]` persisted to `UserDefaults.standard` key `workspace.drafts` on change (debounced 500 ms, through `T3ComposerDrafts.save`), `promptHistory: [String]` key `workspace.promptHistory`, and — same mechanism, key `workspace.lastVisitedAt` — `state.lastVisitedAt` (`[String: Date]`, capped to the 200 most recent), loaded before the first `apply` so ready threads do not all read as unseen after a relaunch. `T3ComposerView(model:store:actions:)`: `TextEditor`-backed multiline field (or an `NSTextView` representable if `TextEditor` cannot intercept ⏎ — try `.onKeyPress(.return)` first; document which), placeholder "Ask anything…" (take the exact string from `ChatComposer.tsx`), ⏎ sends / ⇧⏎ newline, `T3ComposerDrafts.canSend` gates the button; `.queue` sends with `queuedAt: Date()` and shows the queued badge count (the count = requests this store sent while running that have not yet appeared as a user message in `timeline.messages` — match by `commandId` in `payload`? No: match by text equality against new user messages, oldest first; say so), Stop sends `esc`; attachments via drop (`.onDrop(of: [.fileURL, .image])`), paste (`NSPasteboard` images), and an `NSOpenPanel`; images to owned sessions ride `SessionInput.Attachment` (data + mime), everything else and every terminal session gets the file path appended as text (`SessionInput.deliver` does this — just pass attachments; check `SessionInput.swift:290-297`); permission pill shows the current mode (`hookModes` label), menu lists modes ≥ the floor, picking one calls `setPermissionMode` (owned only; hidden otherwise); model pill shows the session's model when known (`grep -rn 'model' Sources/InfinitusCore/SessionProgress.swift SessionFacts.swift` — if no field carries it, the pill is hidden and the report says so). Length cap: at > 4000 chars the send button disables and a `xs` `destructive` line "Message is too long (N / 4000)" appears (upstream wording from `ComposerPromptLengthValidation.tsx`).
  The composer publishes its height via `PreferenceKey` so `T3ThreadView`'s bottom inset tracks it.
  Focus: the prompt field is `@FocusState`-bound; `onAppear` and `onChange(of: model.composerFocusRequested)` set focus when `model.composerFocusRequested` is true and then set it back to false (Task 5's `show workspace composer` consumer). ⌘N/⌘⇧N (Task 15) reuse the same flag.

- [ ] **Step 1: Failing tests** for `T3ComposerDrafts` (round-trip save/load; `pushHistory` dedups and caps; `canSend` table: `"  "` → `.empty`, running → `.queue`, 4001 chars → `.tooLong(4001)`, else `.send`). Run → fails; implement; run → pass.
- [ ] **Step 2: The view** transcribed from the upstream files with tokens; mount in `T3ThreadView`; drafts bound per `state.selectedThreadId`.
- [ ] **Step 3: Smoke + compare** against `refs/mac-composer.png` (composer focused, empty, no menu). Crop the composer card region. Target ≤ 1.5 %; numbers in the report. Type into the field: no perf change (SwiftUI text edits are event-driven); idle perf ≤ 1 % after.
- [ ] **Step 4: Commit**

```bash
git add Sources/InfinitusCore/T3/T3ComposerDraft.swift Tests/InfinitusCoreTests/T3/T3ComposerDraftTests.swift Sources/Infinitus/T3Window/T3ComposerView.swift Sources/Infinitus/T3Window/T3ThreadView.swift Sources/Infinitus/T3Window/T3WindowModel.swift
git commit -m "workspace: the composer — send, stop, queue, permission mode, attachments, persisted drafts (T3 clone B-13)"
```

---

### Task 14: Composer menus — `/` commands and `@` file mentions

**Files:**
- Create: `Sources/Infinitus/T3Window/T3ComposerMenus.swift`
  (`SlashCommands.discover` reads every command/skill file — call it once per cwd when the `/` menu opens and cache the result on the model keyed by cwd; never per keystroke. B-1 review #11.)
- Create: `Sources/InfinitusCore/T3/T3FileMention.swift`, Test: `Tests/InfinitusCoreTests/T3/T3FileMentionTests.swift`
- Modify: `Sources/Infinitus/T3Window/T3ComposerView.swift` (trigger detection, insertion)
- Upstream: `components/chat/ComposerCommandMenu.tsx` (menu look: rows with name + description, keyboard ↑↓⏎⎋, highlight `composerMenuHighlight.ts`), `composerSlashCommandSearch.ts` (ported as `SlashCommands.filter`, Task 3), `ComposerPromptEditor.tsx` (trigger rules: `/` at the start of the prompt or after whitespace opens the command menu; `@` opens the file menu; the query is the run of non-space characters after the trigger; picking inserts `insertion` and closes), `lib/composerPathSearchState.ts` + the fuzzy path search (`grep -rn "fuzzy\|fzf\|pathSearch" ~/death/t3code/apps/web/src/lib ~/death/t3code/packages/shared/src | head`) — port the ranking to `T3FileMention.rank(paths:query:limit:)` with its tests transcribed.

**Interfaces:**
- Consumes: `SlashCommands.discover(cwd:)` (Task 3; run once per selected project on a detached task, cache by cwd, refresh when the menu opens), `T3FileMention.list(cwd:) -> [String]` (Core: `git ls-files` via `Process`, fallback to a bounded `FileManager` walk skipping `.git`, `node_modules`, `.build` — cap 20 000 entries; returns relative paths), `T3FileMention.rank(paths:query:limit: 12)`; kit: `T3Kbd`, `LucideIcon(.slash / .atSign / .file / .folder)`, tokens `popover`, `popoverForeground`, `border`, `accent`, `mutedForeground`.
- Produces: `T3ComposerMenu<Item>(items:selection:onPick:)` anchored above the caret line (a `.overlay(alignment: .bottomLeading)` on the composer; exact caret anchoring is out of scope — anchor to the field's leading edge and say so), `T3ComposerTrigger.detect(text:caret:) -> (kind: .command | .mention, query: String, range: Range<String.Index>)?` (Core, tested: `"/re"` → command "re"; `"fix @Sour"` → mention "Sour"; `"a/b"` → nil; `"email@x"` → nil (no whitespace before `@`)), insertion replaces the trigger range with `command.insertion` or `@<path> `.

- [ ] **Step 1: Failing tests** — `T3ComposerTriggerTests` (the four cases above + caret in the middle of a word) and `T3FileMentionTests` (rank: exact filename first, then prefix, then subsequence; case-insensitive; `limit` respected; empty query → first `limit` paths in order). Run → fails; implement Core; run → pass. `list(cwd:)` gets one test against a temp dir with a `.git`-less tree (fallback path) — assert the skip list.
- [ ] **Step 2: Menus + wiring** in the composer: ↑/↓ move, ⏎ picks (and does NOT send while a menu is open), ⎋ closes.
- [ ] **Step 3: Smoke** on the fixture: type `/` → the menu lists the machine's `~/.claude/commands` (the fixture's `CLAUDE_CONFIG_DIR` is throwaway — `SlashCommands.discover(home:)` reads the real `~/.claude`; pass `home: ClaudeSessions.configHome()` so the fixture shows the fixture's (empty) commands, and report which you chose — the fixture's is right for parity, the real home is right for use; both are one argument), `@` → files of `limitless`. Idle perf ≤ 1 % after closing the menu.
- [ ] **Step 4: Commit**

```bash
git add Sources/InfinitusCore/T3/T3FileMention.swift Sources/InfinitusCore/T3/T3ComposerTrigger.swift Tests/InfinitusCoreTests/T3/T3FileMentionTests.swift Tests/InfinitusCoreTests/T3/T3ComposerTriggerTests.swift Sources/Infinitus/T3Window/T3ComposerMenus.swift Sources/Infinitus/T3Window/T3ComposerView.swift
git commit -m "workspace: slash-command and @-file menus in the composer (T3 clone B-14)"
```

---

### Task 15: New thread (draft → `SessionStart`), keyboard, ⌘K thread switcher

**Files:**
- Create: `Sources/Infinitus/T3Window/T3ThreadSwitcher.swift`
- Modify: `Sources/Infinitus/T3Window/T3WindowModel.swift` (`startNewThread(projectId:)`, drafts as pseudo-threads), `T3Root.swift` (shortcuts), `T3SidebarView.swift` (the "+" and draft rows), `T3EmptyStates.swift` (`T3DraftHeroHeadline`), `T3ThreadView.swift` (draft mode: hero + composer only)
- Upstream: `routes/_chat.draft.$draftId.tsx` (a draft is a sidebar row with no thread until the first send), `components/chat/DraftHeroHeadline.tsx` + `draftHeroTransition.ts` (headline over an empty draft, fades on first send), `packages/shared/src/keybindings.ts` (`mod+shift+n` new thread in project :88, `mod+k` palette :64, `mod+shift+[`/`]` previous/next thread :106 — confirm both; `mod+w` close thread :52 → B: close the window? No: ⌘W is the window's own close; leave it), `components/CommandPalette.tsx` + `CommandPalette.logic.ts` (B ships **only** the thread switcher mode: search threads by title through `T3SidebarList.searchByTitle`, ↑↓⏎, recent-first order via `lib/threadSort.ts` — already `T3ThreadSort`).

**Interfaces:**
- Consumes: `AppModel.startSession(_ request: SessionStart.Request, preferredHost: String) async -> SessionStart.Reply` (`AppModel.swift:2880`; `preferredHost: "owned"` when `model.ownedSessions() != nil`, else `"terminal"` — read the accepted values in `SessionStart.swift` / `SessionLauncher.swift`), `SessionStart.Request(cwd:engine:prompt:resume:permissionMode:model:systemPrompt:profile:fork:headless:commandId:)`, `SessionStart.permissionModes` (start-time picker in the draft composer's permission pill — the four modes), `SessionStart.Reply` (find the field carrying the new pid/sessionId), `T3WorkspaceState` (a draft is `T3Thread(id: "draft:<uuid>", …, session: nil)` kept in `T3WindowModel.drafts` and merged into `state.threads` for the sidebar as the top active row — implement as `T3WorkspaceState.drafts: [T3Thread]` + `apply` preserving them; when the started session's `sessionId` appears in the fleet, the draft is replaced and selection moves to the real thread).
- Produces: `T3WindowModel.startNewThread(projectId: String?)` (creates the draft in the scoped/selected project, selects it, focuses the composer), `T3WindowModel.sendDraft(_ draftId: String, text:, permissionMode:)` → `startSession` on a detached task; on `Reply` failure the note shows in the composer (`T3ThreadActions.note`), the draft stays; `T3ThreadSwitcher(model:)` sheet (`.sheet` on `T3Root`) with `T3Input`, results list, ⏎ selects; shortcuts in `T3Root.keyboard`: ⌘N `startNewThread(nil)`, ⌘⇧N `startNewThread(currentProjectId)`, ⌘K switcher, ⌘⇧[ / ⌘⇧] `selectAdjacent(.previous/.next)` (and ⌘[ / ⌘] if upstream binds them too — report), Esc closes the switcher.

- [ ] **Step 1: Reducer tests** in `T3WorkspaceStateTests`: a draft survives `apply`; a fleet tick containing the draft's `startedSessionId` replaces the draft and moves selection; drafts sort above active threads.
- [ ] **Step 2: Implement** the model + views; `T3DraftHeroHeadline` transcribed (its rotating headline list is data in the tsx — copy the strings; pick by `draftId` hash, not `random`, so parity captures are stable).
- [ ] **Step 3: Smoke**: ⌘N on the fixture → a draft row and the hero; ⌘K → switcher lists "Hi". **Do not send from the fixture**: `AppModel.startSession` resolves the real Claude binary through `ClaudeLocator` regardless of the throwaway config dir and would start a real headless session. Gate `sendDraft` behind `ProcessInfo.processInfo.environment["INFINITUS_WORKSPACE_NO_START"] == nil` (fixture.sh exports it — add that one line to `tools/t3ref/fixture.sh`'s launch env in this task) and, under the gate, log the built `SessionStart.Request` (cwd, prompt, permissionMode, headless) at `.debug` and show the note "Starting sessions is disabled in this instance". Assert that note appears and the draft persists. Idle perf ≤ 1 %.
- [ ] **Step 4: Commit**

```bash
git add Sources/Infinitus/T3Window/T3ThreadSwitcher.swift Sources/Infinitus/T3Window/T3WindowModel.swift Sources/Infinitus/T3Window/T3Root.swift Sources/Infinitus/T3Window/T3SidebarView.swift Sources/Infinitus/T3Window/T3EmptyStates.swift Sources/Infinitus/T3Window/T3ThreadView.swift Sources/InfinitusCore/T3/T3WorkspaceState.swift Tests/InfinitusCoreTests/T3/T3WorkspaceStateTests.swift tools/t3ref/fixture.sh
git commit -m "workspace: new-thread drafts start sessions; ⌘N ⌘⇧N ⌘K ⌘⇧[ ⌘⇧]; the thread switcher (T3 clone B-15)"
```

---

### Task 16: e2e gate, parity numbers, capture hygiene

**Files:**
- Modify: `tools/e2e.sh` (after the wall block, ≈ line 275), `tools/t3ref/capture-mac.sh` (settle sleep 1 → 3), `tools/t3ref/capture-ios.sh` (add `sleep 3` after `simctl openurl`), `tools/t3ref/README.md` (the Mac section: "not yet" → the real flow), `tools/t3ref/refs/PROVENANCE.md` (Mac refs' provenance + the re-captured `ios-thread.png` note), `CHANGELOG.md`

- [ ] **Step 1: e2e** — after `echo "windows: ok (wall over pop-out, restored)"`:

```bash
# --- windows: the workspace opens beside the pop-out and idles ----------
workspace_visible() { "$CTL" windows | expect "any(w['visible'] and w['title']=='Infinitus' and w['size'][0]>=960 and w['size'][1]>=600 for w in d)"; }
"$CTL" show workspace thread | expect "d['shown']=='workspace'" || fail "show workspace"
sleep 3
workspace_visible || fail "workspace window not visible after show workspace"
popout_visible || fail "pop-out closed by the workspace (it is not a mode)"
"$CTL" show workspace bogus 2>/dev/null && fail "show workspace accepted an unknown screen"
WA="$("$CTL" perf | json "d['cpuSeconds']")"
sleep 15
WB="$("$CTL" perf | json "d['cpuSeconds']")"
WPCT="$(python3 -c "print(round(($WB-$WA)/15*100,1))")"
echo "idle CPU with the workspace open: ${WPCT}%"
python3 -c "import sys; sys.exit(0 if $WPCT <= $IDLE_BUDGET_PCT else 1)" || fail "workspace idle CPU ${WPCT}% over budget ${IDLE_BUDGET_PCT}%"
"$CTL" hide workspace | expect "d['hidden']=='workspace'" || fail "hide workspace"
sleep 1
workspace_visible && fail "workspace still visible after hide"
echo "windows: ok (workspace beside pop-out, idle ${WPCT}%, hidden)"
```

  This needs `hide workspace`: extend `ControlProtocol` `hide` args to `["popout|workspace"]`, `ControlServer` `case "workspace": controller.hideWorkspace()` (`T3WindowController.close()`), and the `ControlProtocolTests` args assertion. The `windows` match uses title + class + width because `content` reports `NSHostingView<…>`; if `LockGate` changes the reported type, match on what `infinitusctl windows` prints during the smoke and say so.

- [ ] **Step 2: Parity run** on the fixture for all three screens; put the three `compare.py` lines into the PR body and into `tools/t3ref/README.md` under a "B parity — <date>" heading (numbers only; ≤ 1.5 % is the acceptance; anything over is listed as a follow-up issue with the diff PNG attached to the issue, never to the repo).
- [ ] **Step 3: Re-capture `ios-thread.png`** with the new `sleep 3` (Infi3's phone is mid-C; the ref is A's — coordinate: the metro server must be running; if it is not, leave the old file, note it in PROVENANCE, and file the issue).
- [ ] **Step 4: Run `tools/e2e.sh` locally end-to-end** (≈ 4 min); paste the summary lines. Commit:

```bash
git add tools/e2e.sh tools/t3ref/capture-mac.sh tools/t3ref/capture-ios.sh tools/t3ref/README.md tools/t3ref/refs/PROVENANCE.md Sources/InfinitusCore/ControlProtocol.swift Sources/Infinitus/ControlServer.swift Sources/Infinitus/StatusItemController.swift Tests/InfinitusCoreTests/ControlProtocolTests.swift CHANGELOG.md
git commit -m "workspace: e2e opens and idles the window; parity numbers; capture settle delays (T3 clone B-16)"
```

**→ PR B-5 (`t3-clone-b5`)**: Tasks 13–16. CHANGELOG: `- Workspace: composer with slash commands, @-file mentions, attachments, new-thread drafts and the ⌘K thread switcher.`

---

## Self-review (run after writing; fix inline)

1. **Spec §4 coverage** — §4.1 shell: Task 5 (+ deviation table). §4.2 layout: Task 6; ⌘B: Task 6; right panel frame + tabs: Task 6. §4.3 state: Tasks 4, 5, 9, 13 (drafts persisted; `sessionId` selection; `TimelineCache` direct; `waitForChange` wake; `SessionInput` with `commandId`; `SessionStart` owned-vs-terminal: Task 15; `AttentionStore` via `applyAttention`: Task 5). §4.4 sidebar: Task 7 (archive/rename: deviation table); thread view: Tasks 10–12 (turn diff stat = E, noted); composer: Tasks 13–14 (model manifest / effort: deviation table); top bar: Task 8; empty states: Tasks 6, 15; keyboard: Tasks 6, 15. §4.5 performance: every task's smoke + Task 16 gate; 60 s tick only while key: Task 5; shimmer as `LayerEffect`: Task 11; `LazyVStack` stable ids + anchoring: Task 11; markdown cache: Task 11. §4.6 testing: reducer tests (Tasks 1–4, 9, 10, 13, 14, 15), e2e (Task 16), `compare.py` numbers in the PR (Tasks 7, 8, 11, 13, 16).
2. **Placeholders** — none of "TBD/TODO/later"; every "read X and adapt" names the file and the decision to report.
3. **Type consistency** — `T3WindowModel.select(_:)`, `toggleSidebar()`, `toggleRightPanel()`, `attention(_:threadId:until:)`, `state.sidebarSections(now:)`, `T3TimelineStore.rows/pending/limits/rederive()`, `T3ThreadActions`, `T3ComposerDrafts.canSend`, `startNewThread(projectId:)` — used with the same names in every task that references them.
