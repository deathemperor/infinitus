# Babysit

Babysit (#269 A, on the #806 queue): `packages/contracts/src/orchestration.ts` — `ThreadBabysit` (`since`, `rounds`), `BABYSIT_MAX_ROUNDS` (10), `babysit?` on `OrchestrationThread` and `OrchestrationThreadShell` (optional, so pre-babysit payloads still decode), `thread.meta.update` gains `babysit?: boolean` (on is idempotent) and `babysitRounds?` (the layer's bump, ignored while off), `thread.meta-updated` carries `babysit?` (null when turned off); `apps/server/src/orchestration/decider.ts` `babysitPatch`, `projector.ts`, `packages/client-runtime/src/state/threadReducer.ts` apply it; persisted as `projection_threads.babysit_json` (`Migrations/052_ProjectionThreadsBabysit.ts`, `Layers/ProjectionThreads.ts`, `ProjectionPipeline.ts`, `ProjectionSnapshotQuery.ts`).

## The pure half

`apps/server/src/infinitus/Layers/infinitusBabysit.logic.ts` — the pure half: `babysitVerdict` (off / archived / no open PR — a merged one stops it / trigger order conflicts > checks > review / seen / cap / own row still queued / busy / pending start / queue), signatures (`conflicts@updatedAt`, `checks@updatedAt`, one review per changes-requested stretch — `settleBabysitMarks`), `seedBabysitMarks`, `babysitPrompt` (sends the agent to `gh`; host strings are bounded identifiers);

## The layer

`InfinitusBabysit.ts` — `InfinitusBabysitLive`: watches `thread.pull-request-synced`, `-turn-queue-removed`, `-session-set` (idle → `requestSync`), `-meta-updated`; queues a round via `thread.turn.queue` and bumps `babysitRounds`; at the cap sends `babysitStopped` — the record keeps its rounds and gains `stoppedAt`, the verdict reads it as off, the toggle reads "Babysit stopped" and the sidebar's Needs attention section lists the thread as "Babysit" until the user sends again (`collectNeedsAttention`, on `latestUserMessageAt`) — with an `error` activity `babysit.stopped`; on merge clears the record with an `info` `babysit.done`; the boot sweep (parked until activation) seeds what is red without acting, a thread the sweep missed seeds itself on first sight. `PullRequestSyncReactor.ts` — babysat threads' open PRs are due like unsettled ones, and a requested sync writes `thread.pull-request-synced` even when nothing changed (`requestedSync`).

## Web

`apps/web/src/components/ThreadBabysitToggle.tsx` — the composer toggle ("Babysit" / "Babysit r/10"), shown by `BranchToolbarBranchSelector.tsx` next to the PR badge on fork servers with an open linked PR (or while on). Tests: `infinitusBabysit.logic.test.ts`, `InfinitusBabysit.test.ts`, `ProjectionPipeline.babysit.test.ts`, `threadReducer.test.ts`.
