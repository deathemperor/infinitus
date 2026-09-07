# T3 Code clone, phases 1–5: timeline, facts, wire, leases — design

Issue #223 (plan), #151 (owned sessions, shipped as slice 1 on 2026-09-07).
Upstream watermark: t3code `223ff44` (`upstream/t3code.json`).

Split by layer (user, 2026-09-07): **Infi4 owns Core and the mirror
server** — phase 1 (timeline model), phase 3's per-session facts and the
settle/snooze/pin store, phase 4 (sequence, receipts, descriptor), phase 5
(leases and Mac-side gating). **Infi3 owns the clients** — phase 2 (the
`deriveThreadFeedPresentation` reducer in InfinitusUI and its rows on the
phone, the Mac window and the browser page) and phase 3's list UI, built
against the types in §1 and §2 after phase 1 merges.

File ownership: Infi4 = `Sources/InfinitusCore/**`,
`Sources/Infinitus/MirrorServer.swift`, new `Sources/Infinitus/Mirror*.swift`,
`Tests/InfinitusCoreTests/**`; Infi3 = `Sources/InfinitusUI/**`, `ios/**`,
`Sources/Infinitus/MirrorWebClient.swift` and the rest of
`Sources/Infinitus/**`. A hook Infi4 needs in `AppModel.swift` is announced
first and landed by Infi3, or Infi3 names a seam.

Every decision below names the T3 source it mirrors. Where we diverge, the
divergence is stated and the reason given.

## 0. Non-goals

- No SQLite event log, no projectors, no persisted sequence (T3
  `orchestration_events`): Claude Code's transcript is the durable store
  (#151 spike). The sequence log is in-memory and restart-invalidates.
- No new socket. The HTTP mirror (`GET /snapshot`, long-poll tail) stays
  the transport; phase 4 adds T3's resume semantics on top of it.
- No auto-settle (T3 `ThreadSettlementReactor`), no archive changes,
  no fork-as-worktree, no thread↔PR link. Logged on #223 if wanted later.
- Legacy `SessionFeedItem` and `GET /sessions/{pid}/tail` are untouched
  through the transition; every new field is additive
  (`decodeIfPresent`), every new route is new.

## 1. Phase 1 — `SessionTimeline` in InfinitusCore

Mirrors T3's read model — `Message` (`packages/contracts/src/orchestration.ts:354-363`),
`OrchestrationThreadActivity` and `latestTurn` (`:485-536`) — and the
ingestion rules in `apps/server/src/orchestration/ProviderRuntimeIngestion`
and `ActivityPayloadProjection.ts`.

### 1.1 Types (new file `Sources/InfinitusCore/SessionTimeline.swift`)

`Turn`, `Message` and `Activity` are nested under `SessionTimeline` (the
phone imports ActivityKit, whose `Activity<Attributes>` collides); the
shapes below are otherwise verbatim.

```swift
public struct SessionTimeline: Codable, Sendable, Equatable {
    public var turns: [Turn]            // oldest → newest
    public var messages: [Message]      // oldest → newest
    public var activities: [Activity]   // ordered by sequence
    public var latestTurn: Turn? { turns.last }
    // per-id lookups, built once (upstream 17490c0a: never rescan to close one pair)
    public func turn(id: String) -> Turn?
    public func message(id: String) -> Message?
    public func activity(id: String) -> Activity?
}

public struct Turn: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case running, interrupted, completed, error }
    public let id: String               // == userMessageId
    public let state: State
    public let requestedAt: Date
    public let startedAt: Date?
    public let completedAt: Date?
    public let userMessageId: String
    public let assistantMessageId: String?
}

public struct Message: Codable, Sendable, Equatable {
    public enum Role: String, Codable, Sendable { case user, assistant }
    public let id: String
    public let role: Role
    public let text: String             // capped at SessionFeedReader.textCap
    public let images: [String]?        // same ids as SessionFeedItem.images
    public let sender: String?          // peer session name, nil for the user
    public let turnId: String
    public let streaming: Bool
    public let createdAt: Date
}

public struct Activity: Codable, Sendable, Equatable {
    public enum Tone: String, Codable, Sendable { case info, tool, approval, error }
    public let id: String
    public let tone: Tone
    public let kind: String             // open — see 1.3; unknown kinds render as a plain line
    public let summary: String
    public let detail: String?          // ≤ 180 chars (T3 ingestion cap)
    public let payload: [String: JSONValue]   // open — Models.swift JSONValue
    public let turnId: String
    public let sequence: Int            // position in the transcript walk
    public let createdAt: Date
}
```

Unknown `kind` strings are kept, never rejected: a newer Mac's timeline
decodes on an older phone (same rule as `SessionFeedItem.Kind.other`).

### 1.2 Identity (the property phase 4 depends on)

Ids are deterministic functions of the transcript, so two reads of the same
file give the same ids and a delta can be computed by diffing two builds.

| entity | id |
|---|---|
| user message | the entry's `uuid` (a `queued_command` attachment: the attachment entry's `uuid`) |
| assistant message | the `uuid` of the FIRST assistant entry of the merged run (streamed blocks merge into one message, as today) |
| turn | its user message id |
| tool activity | one row per lifecycle event: `<toolUseId>` for `tool.started`, `<toolUseId>/completed` for `tool.completed` (T3 `toolCallId = itemId` is the `tool_use` block `id`) |
| approval / user-input | `perm:<toolUseId>` (transcript-derived), or the owned `PendingRequest.requestId` |
| sub-agent task | `task:<toolUseId>` / `task:<toolUseId>/completed` |
| other activities | `<entry uuid>:<block index>` |

Legacy parked-prompt rule (`SessionFeedReader.finalize`: trailing tool +
record `waiting` ⇒ permission) becomes an `approval.requested` activity
with id `perm:<toolUseId>`. The transcript never records that a prompt was
shown, so on the next read the row is simply absent (phase 4 emits a
tombstone); `approval.resolved` rows exist only for owned sessions, whose
adapter knows the answer. `AskUserQuestion` differs: its `tool_result`
carries the answers, so `user-input.resolved` is transcript-derived.
Entries with `isSidechain: true` are skipped (sub-agents are summarized by
`task.*`, and the transcript has no `parent_tool_use_id` to filter on).

### 1.3 Activity kinds and payloads

| kind | tone | summary | payload |
|---|---|---|---|
| `tool.started` | tool | `describeTool` line (today's text) | `toolName, itemType (command_execution\|file_change\|file_read\|search\|dynamic_tool_call), title, detail, agentId?, parentToolUseId?` |
| `tool.completed` | tool / error on failure | same | + `status: completed\|failed, output? (slimmed), changedFiles? [path]` |
| `approval.requested` / `.resolved` | approval | tool name + detail | `requestId, toolName, requestType (file_read_approval\|command_execution_approval\|file_change_approval\|dynamic_tool_call, T3 heuristic :954-964), input (JSON), suggestions?` / `decision` |
| `user-input.requested` / `.resolved` | approval | first question | `requestId, questions [{id (== question text), header, question, options [{label, description}], multiSelect}]` / `answers` |
| `task.started` / `.completed` | info | agent description | `agentId, agentType, toolCalls, lastTool, running` (from `attachAgents`) |
| `turn.plan.updated` | info | "N of M steps" | `steps [{text, status}]` from TodoWrite / TaskList |
| `runtime.warning` | info | limit text / held text | `code: limit\|held\|notification, resetsAt?` |
| `runtime.error` | error | error line | `message` |
| `context-compaction` | info | "Context compacted" | `beforeTokens?, afterTokens?` |

Slimming happens at build time with T3's three-layer rules collapsed into
one: `detail` ≤ 180 chars; tool `output` = first meaningful line ≤ 84 chars
or "N lines"; `changedFiles` to depth 4 and at most 12; a `detail` that
merely echoes the command is dropped; thinking blocks never enter the
timeline; sub-agent traffic (`parent_tool_use_id != nil`) keeps
`tool_use` starts and drops text.

### 1.4 Turn derivation

A real user prompt (today's `realUserText`, including `queued_command`)
opens a turn. The turn's `state` follows T3's projector (`projector.ts:78-93`:
turn end is derived from session status, not a turn event):

- a later user prompt exists ⇒ `completed` (interrupted if the transcript
  shows `[Request interrupted by user]` between them, error if an API error
  entry ends it);
- it is the last turn and the record is `busy` ⇒ `running`;
- last turn, record `idle`/`waiting`, final assistant text present ⇒
  `completed`; `waiting` with an open approval ⇒ still `running`;
- `startedAt` = first assistant entry, `completedAt` = last entry of the turn.

`Message.streaming` is true only for the last assistant message of a
`running` turn.

### 1.5 Builder and reader

`SessionTimelineBuilder.build(entries: [[String: Any]], record:
ClaudeSessionRecord, agents: [String: SessionFeedItem.Agent]) ->
SessionTimeline` is a second walk over the entries `SessionFeedReader.read`
already decodes; the legacy `parse` is not modified. `SessionFeedReader.read`
gains `timeline` on its result: `SessionFeed.timeline: SessionTimeline?`
(additive). The 256 KiB → 4 MiB tail window rule is unchanged; a turn cut by
the window start is kept with what is visible.

`SessionTimeline.appending(pending: [PendingRequest], now:) ->
SessionTimeline` turns an owned session's parked prompts (#278) into
`approval.requested` / `user-input.requested` activities on the latest turn
(id = `requestId`). `OwnedFeed.augment` (Infi3's file) calls it alongside
its legacy item append.

### 1.6 `PendingRequests` (upstream `e63ddb48`, `packages/client-runtime/src/pendingRequests.ts`)

`PendingRequests.derive(_ activities: [Activity]) -> (approvals:
[PendingApproval], userInputs: [PendingUserInput])`, one pass, closed set:
a `.resolved` for an id closes it and a later `.requested` with that id is
ignored; questions with no valid options are dropped; malformed options
filtered, not fatal. Shared by the Mac popup, the phone and the browser so a
resolve on one client closes the sheet on the others.

### 1.7 Tests

Transcript fixtures under `Tests/InfinitusCoreTests/Fixtures/timeline/`
(`plain.jsonl`, `tools.jsonl`, `interrupted.jsonl`, `limit.jsonl`,
`peer.jsonl`, `compact.jsonl`, `todo.jsonl`, `agent.jsonl`), each asserted
field by field in `SessionTimelineTests`; plus identity stability (two builds
of the same lines are `==`, and a build survives an encode/decode round
trip), slimming, turn states per record status, `appending(pending:)`,
`PendingRequests` closed set, and forward decoding of an unknown kind.

## 2. Phase 3 facts — `SessionFacts` and `AttentionStore`

Mirrors T3's shell row (`ws.ts` shell subscription; attention is "not a
server concept" — the client derives `approval > input > working > failed >
ready`, `apps/mobile/src/features/home/threadListV2.ts:30`,
`threadSettled.ts`).

```swift
public struct SessionFacts: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case idle, starting, running, ready, interrupted, stopped, error }
    public let status: Status
    public let hasPendingApprovals: Bool
    public let hasPendingUserInput: Bool
    public let hasPlan: Bool                 // upstream eb8ed803: the boolean, never the body
    public let latestTurn: Turn?
    public let planProgress: PlanProgress?   // {step, completed, total}
    public let latestUserMessageAt: Date?
    public let settledOverride: SettledOverride?  // "settled" | "active" | nil (T3 orchestration.ts ThreadShell)
    public let settledAt: Date?
    public let unsettledAt: Date?            // re-entry stamp for active-list order
    public let snoozedUntil: Date?
    public let snoozedAt: Date?
    public let pinnedAt: Date?
}
```

Facts ride the snapshot as `MirrorSnapshot.factsByPid: [Int: SessionFacts]?`
(additive, `FleetMirror.swift`), the app-owned per-pid sibling of
`progressByPid` — not `SessionDetail`, which is decoded verbatim from the
engine's list output and can't carry app fields (amended 2026-09-07 while
planning P2). `status`
maps the record: `busy → running`, `waiting → running` with a pending
request, `idle → ready` after a completed turn else `idle`, exited → `stopped`.

`AttentionStore` (Core) persists `{sessionId: {settledOverride, settledAt,
unsettledAt, snoozedUntil, snoozedAt, pinnedAt}}` with T3's decider rules
(`apps/server/src/orchestration/decider.ts` @ acc0a219e: settle also unpins
and unsnoozes; unsettle → "active", `unsettledAt` = now unless already
active; snooze needs `until` > now, `snoozedAt` = existing ?? now; pin keeps
the first `pinnedAt` and un-settles / unsnoozes; unpin clears) as JSON in App Support `Infinitus/attention.json`,
keyed by **session id** (not pid) so it survives restarts and resumes.
Route `POST /sessions/{pid}/attention` body `{action: settle | unsettle |
snooze | unsnooze | pin | unpin, until?: Date, commandId?}` mirrors
`thread.settle|unsettle|snooze|unsnooze|pin|unpin`
(`orchestration.ts:1044-1068`); snooze refuses while `hasPendingApprovals ||
hasPendingUserInput` (T3 "snooze refuses while waiting on you"). #199's
"park" is settle; the store replaces its ad-hoc flag when Infi3 wires the UI.

`TimelineCache` (Core actor): per pid, `(stamp, SessionTimeline,
SessionFacts)`; rebuilt only when `SessionFeedReader.stamp` changes. Both
the snapshot facts and the phase 4 log read from it, so an unchanged
transcript is never re-parsed.

## 3. Phase 4 — sequence, receipts, descriptor

Mirrors `orchestration.subscribeThread` (`apps/server/src/ws.ts:1601-1762`:
attach live first, replay iff ≤ 1000 events and ≤ 8 MB else snapshot,
`synchronized` last), `orchestration_command_receipts`, and
`GET /.well-known/t3/environment` (`packages/contracts/src/environmentHttp.ts`).

### 3.1 `SequenceLog` (Core)

One monotonic `Int` per Mac process plus a launch `epoch` (UUID). Every
`TimelineCache` rebuild diffs old vs new timeline by id and appends
`TimelineEvent{sequence, pid, op: upsert | tombstone, entity: turn | message |
activity | facts, body: JSONValue}`. Ring buffer per pid: 1,000 events or
8 MB, whichever first; an ended session's buffer is dropped when it leaves
the roster. Divergence from T3: nothing persists; a client presenting a
different `epoch` gets a snapshot. Same outcome as T3's "recreated thread
forces a snapshot".

### 3.2 `GET /sessions/{pid}/timeline?afterSequence=&epoch=&wait=`

```json
{ "epoch": "…", "sequence": 4812, "synchronized": true,
  "snapshot": { "timeline": {…}, "facts": {…} },      // when resuming is not possible
  "events": [ {…}, … ] }                              // when it is
```

Snapshot when `epoch` differs, `afterSequence` is absent, or the gap
exceeds the buffer; otherwise the events after `afterSequence`. Long-poll
exactly as `/tail` (`waitForChange` on the stamp, `OwnedFeed.ownedWait`
cap for owned pids). Clients apply upserts by id, drop tombstones, and must
accept a snapshot at any time (T3 rule).

### 3.3 Snapshot

`GET /snapshot` gains top-level `epoch` and `sequence`, and every
`SessionDetail` carries `facts` (from the cache; absent when unleased, §4).

### 3.4 Command receipts

`POST /sessions/{pid}/input`, `POST /sessions/start` and the attention route
accept `commandId` (client-minted UUID). `Receipts` (Core, in-memory, cap
1,000, 1 h TTL): same id + same target ⇒ the cached reply (200); same id +
different target ⇒ 409; a tombstone per interrupted/removed input so a
retry cannot resurrect it (T3 outbox doctrine). Absent `commandId` behaves
as today.

### 3.5 `GET /.well-known/infinitus` (unauthenticated)

`{machineId, label, platform: "macos", appVersion, capabilities:
{timeline, sequence, attention, leases, ownedSessions, checkpoints, team,
pastSessions, images}}` — booleans, absent = unsupported, so the phone hides a
feature on skew instead of failing to decode. `machineId` is the existing
per-Mac identity used by the multi-Mac mirror (#144).

## 4. Phase 5 — leases

Mirrors `server.reportClientActivity` (`packages/contracts/src/background.ts`;
phone every 25 s and on foreground/background, `ttlMs: 45000`, scopes
ref-counted from live subscriptions).

`POST /client-activity {clientId, visible, focused, recentlyInteracted,
scopes: [{type: sessions | session | fleets | stats, pid?}], ttlMs}` →
`LeaseTable` (Core actor): `clientId → (scopes, expiresAt)`, swept on
read. `holds(_ scope) -> Bool`. The Mac's own popup/pop-out registers as a
local client while open, so nothing the user sees on the Mac depends on the
phone.

Gated by lease (call sites in AppModel, each an announced hook):

| work | scope |
|---|---|
| `TimelineCache` rebuilds for snapshot facts | `sessions` or `session(pid)` |
| transcript tail reads for the mirror | `session(pid)` (a long-poll in flight is itself a lease) |
| stats scans (`StatsScanner`) | `stats` |
| checkpoint diffs on turn end | `session(pid)` |

Unleased ⇒ `SessionDetail.facts` is omitted (phone falls back to today's
rows), no tail is read, no scan runs. `tools/e2e.sh` adds: with no lease,
idle CPU over 15 s matches today's gate; a `/timeline` resume with
`afterSequence` older than the buffer answers a snapshot.

## 5. Delivery

| PR | contents | unblocks |
|---|---|---|
| P1 | §1 types, builder, `appending(pending:)`, `PendingRequests`, `SessionFeed.timeline`, fixtures | Infi3 phase 2 |
| P2 | §2 facts, `AttentionStore`, `TimelineCache`, attention route, `SessionDetail.facts` | Infi3 phase 3 UI |
| P3 | §3 sequence log, `/timeline`, receipts, descriptor | phone resume |
| P4 | §4 leases, gating hooks, e2e lines | idle-CPU gate |

Each PR: TDD in `Tests/InfinitusCoreTests`, one CHANGELOG line under
`### Sessions`, `gh pr create` → auto-merge → "merged #N at <sha>" to Infi.
Site/README updated in the release commit, not per PR.

## 6. Error handling and performance

- Degrade, never throw: a missing or torn transcript yields an empty
  timeline with the record's facts; malformed entries are skipped.
- Unknown `kind` / unknown payload keys are carried, not rejected.
- The timeline builder runs off the connection queue like `/tail` today;
  `TimelineCache` makes the cost one parse per transcript change.
- Buffers are bounded (1,000 / 8 MB per pid; receipts 1,000; leases swept),
  so idle heap stays flat under the e2e `perf.heapBytes` check.
