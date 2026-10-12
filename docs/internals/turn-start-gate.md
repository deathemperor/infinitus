# Turn-start gate and the message queue on orchestrator v2

Fork (#1627, the queue lane). Upstream's orchestrator v2 already owns the
message queue the fork built on v1 (#806): a queued message is a run with
`status: "queued"`, ordered by `queuePosition`, drained by `startNextQueuedRun`
under the thread's dispatch lock whenever a run of that thread ends, held by
`queueHeld` after a restart, with `queued-run.edit` / `.cancel` / `.reorder`,
`queued-message.promote-to-steer`, the `t3_queue_*` MCP tools and both clients'
queue controls. The row keeps its message's `context` records (#972). A
promote or a drain of a run that is no longer `queued` is refused under the
lock, and the `provider-turn.start` effect is committed in the same transaction
as the run's move to `starting`, so one row is sent once (#903). What the fork
adds on top is below.

## The gate

`apps/server/src/orchestration-v2/TurnStartGate.ts`. Every provider turn start
on v2 is a `provider-turn.start` (or the start half of `provider-turn.restart`)
outbox effect, run by the effect worker through
`ProviderTurnStartService.start`. That `start` hands the whole send to
`TurnStartGate.start({ threadId, runId, start })`, which answers `started`
(ran it) or `held` (kept it). The server runs the passthrough; the session
holds (#616) and the worktree cap (#269) lanes provide a holding gate in its
place in `server.ts` (`layerOrchestrationV2Runtime`). `runtimeLayer.ts` leaves
the gate a requirement of `layerProduction` for that reason; its plain `layer`
carries the passthrough for tests and live probes.

Three facts of v2 shape what a holding gate may do; none of them is visible
from the gate's signature:

- **The call runs inside the effect worker's per-thread lane.** The outbox
  claims one effect per thread at a time and the daemon has four workers in
  all. A gate that blocks inside `start` therefore blocks the thread's own
  interrupt and every other effect behind it, and four held threads stall the
  server. A holding gate answers `held` at once and keeps nothing but its own
  bookkeeping.
- **The run's `starting` status is the lease.** By the time the gate sees a
  start, the orchestrator has committed the run as `starting`; a `starting`
  run blocks the queue drain and makes every later send queue behind it. So
  a held start needs no claim of its own, and the "replace a CLI then send"
  race the v1 layers had (#1513) cannot come back here: nothing starts on a
  thread while a start is pending, held or not. A held run looks like a
  starting one to clients; a gate that wants to say more writes its own
  marker.
- **Release is a fresh effect, not the kept closure.** `releaseTurnStart`
  enqueues a new `provider-turn.start` for the run so it runs in the lane
  again. The start re-reads the run and does nothing unless it is still
  `starting`, so a run the user stopped or restarted while held is dropped
  there. Running the kept `start` directly from the gate's own fiber would
  race the lane's interrupts. After a server restart a held run is an
  ordinary `starting` run with no live session to the runtime recovery; a
  gate that must survive restarts re-derives its holds from the projection.

## Steer at the tool boundary (#1318)

A steer sent while a turn runs lands at that turn's next step, not mid-tool,
and the wait lives on the server so web, phone and MCP agree (option 3 of the
ruling on #1318; upstream's own client-side parking from #11673 is gone in
v2). Two halves:

- `Orchestrator.ts`, `message.dispatch`: a dispatch that resolves to
  `steer_active` and is not a mailbox delivery (no `delegatedCompletion`, no
  `notification`) is queued instead, as a run with `sendAt: "tool_boundary"`.
  An explicit `queued-message.promote-to-steer` — the row's Steer button, the
  `thread.steerQueuedMessage` key, `t3_queue_promote_to_steer` — still steers
  at once, and `restart_active` stays a restart.
- `InfinitusToolBoundarySteer` tails the orchestrator's domain events. A
  `turn-item.updated` that ends a tool call (`command_execution`,
  `file_change`, `file_search`, `web_search`, `dynamic_tool`, `subagent`;
  `completed` or `failed`) of a run that is still running promotes the first
  `tool_boundary` row in queue order — past idle rows ahead of it — through
  the same promote command, with the item id as the command id, so a
  completion projected twice is one boundary and a row that went meanwhile is
  refused under the lock rather than sent twice. If the turn ends first, the
  idle drain takes the row as an ordinary queued message, whatever its
  `sendAt`.

The row is a queued run throughout, so edit, reorder, cancel and the queue
hold apply to it unchanged, and `sendAt` survives an edit (the edit rewrites
the message, not the run).
