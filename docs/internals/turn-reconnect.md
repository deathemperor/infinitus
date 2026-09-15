# Reconnect a turn whose transport went away

**Reconnect a turn whose transport went away (#832).** The Claude adapter (`apps/server/src/provider/Layers/ClaudeAdapter.ts`) keeps the turn open when its stream fails with a socket-level error (or a process exit after the CLI reported `api_retry`), when a result reports `api_error` with no cause the turn already knows (login, usage limit), or when the stream ends cleanly with the turn open; `scheduleReconnect` emits `session.state.changed {running, reason: "reconnecting:<n>/5"}` and after the attempt's backoff (`claudeReconnect.logic.ts`: 5 s, 15 s, 1 min, 3 min, 10 min) `reopenForReconnect` closes the old query, carries any queued prompt over, and reopens the CLI on the reported session id (`reconnectQueryOptions`, `context.reopenStream`) with the shared continuation prompt (`apps/server/src/provider/turnContinuation.ts`, the one the post-update boot continuation sends) or, when nothing answered yet, the turn's own message again. An assistant message resets the count; after the last attempt the turn fails with the message in `RECONNECT_EXHAUSTED_MESSAGE`. A clean stream end with an open turn now fails instead of reading as `interrupted`, which the #806 drain treats as idle.

## A server that dies mid-backoff

A server that dies mid-backoff still picks the turn up: every reconnecting state event writes the post-update continuation marker (`continueAfterServerUpdate`, `ProviderService.processRuntimeEvent`), which the boot reads before the `continueThreadsAfterServerUpdate` setting; a left-over marker is inert (a finished turn is not orphaned) and the next send or stop nulls it.

## What the client sees

The reason reaches the client as `OrchestrationSession.statusReason` (`packages/contracts/src/orchestration.ts`; ingestion sets it from a running `session.state.changed`, null on every other lifecycle event; `ProjectionThreadSessions` column `status_reason`, `Migrations/055_ProjectionThreadSessionsStatusReason.ts`, `ProjectionPipeline.ts`, `ProjectionSnapshotQuery.ts`), and the web shows "Waiting for the network. Reconnect attempt n of 5." under the thread's banners (`apps/web/src/components/chat/ThreadReconnectingNotice.tsx`, mounted in `ChatView.tsx`). Codex is out of scope. Tests: `claudeReconnect.logic.test.ts`, `ClaudeAdapter.test.ts` "reconnect (#832)", `ProviderRuntimeIngestion.test.ts`, `ThreadReconnectingNotice.test.ts`.

The phone's notice is in `docs/internals/phone-thread-screen.md`.
