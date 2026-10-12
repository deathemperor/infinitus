# Turn usage

Fork (#834, #927, #1026; on orchestrator v2 since #1627). A thread's usage —
tokens, cost, models, tool calls and time working per completed turn, rolled
up over the thread — with no event, table or wire payload of its own.

## What v2 already had

Every adapter normalizes a per-turn `turnTokenUsage` (`TurnTokenUsage`:
status, scope, the four token counts) onto its `OrchestrationV2ProviderTurn`,
and the projection persists the turn with its `startedAt` / `completedAt`.
A client's thread projection (the detail and the bounded snapshot alike)
carries every provider turn, run, attempt and provider thread in full; only
the turn items are windowed. That is enough to fold a rollup on the client.

## The fork's additions

- `OrchestrationV2ProviderTurn` carries three optional fork fields
  (`packages/contracts/src/orchestrationV2.ts`): `turnCostUsd`, `turnModels`
  (the Claude adapter's, from `claudeTurnUsage.logic.ts`: the SDK's
  `total_cost_usd` / `modelUsage` are cumulative per query() process, so each
  result is differenced from the previous one on the live query context; a
  total that went down means the process started over) and `toolCalls` (the
  ingestor's, `providerTurnToolCalls.ts`: on a terminal `provider_turn.updated`
  that carries none it counts the distinct tool-shaped turn items of that
  turn, so the rollup never needs the items a bounded snapshot windows).
  `TurnTokenUsage.cacheTtlSeconds` (#1557) is filled by
  `ClaudeTurnTokenUsage.ts` from the result's `usage.cache_creation`.
- The fold is `packages/shared/src/threadUsage.ts`:
  `turnUsageFromProviderTurn` (terminal turns only; a turn whose provider
  reported no usage — Cursor, Grok — is a `usageUnavailable` row that keeps
  its tool calls and duration and counts in `unreportedTurns`) and
  `threadUsageFromProjection` (root provider threads only, so a subagent's
  turns never double-count; a rolled-back run's turns are left out; oldest
  first; folded onto the thread's `usageBaseline`). Web (`ComposerThreadUsage`
  in the composer footer) and the phone (`InfinitusThreadUsageRows` in the
  thread settings sheet) each fold from the projection they already hold.
  Absent until a turn is recorded: never zero for "not recorded".
- The one server-stored figure is `OrchestrationV2AppThread.usageBaseline`,
  set through `thread.metadata.update` by `ThreadUsageBackfill.ts` for
  threads whose turns predate recording: the v1 rollup the import left in
  `projection_threads.usage_json` (exact, under the same thread id), else the
  Claude transcript's total (`UsageService.readSessionUsage`, the session
  named by the root provider thread's native ref or the v1 session binding)
  for a legacy thread — every run before boot, no provider turn with usage.
  A thread is attempted once per process. Transcripts do not delimit turns,
  so that estimate is thread-level with `source: "transcript"`; it counts
  turns a rollback removed, reads only the configured Claude homes, and
  Codex is not estimated.

## Traps

- The rollup is derived on the client; nothing refolds it on the server.
  A revert that rolls a run back drops its turns from the fold at once.
- `turnModels[0]` is the turn's model when the adapter named one; otherwise
  the run's selected model stands in, so a Codex turn still names its model.
- Live rate (#1142) and the prompt-cache timer (#1557) are not here yet.
