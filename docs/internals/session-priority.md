# Session priority mode

On orchestrator v2 (#1627) the feature lands in two parts. This page
describes what is in `main`; the engine half follows the queue lane's gate.

## What the clients see (#741, #743)

`subscribeInfinitusHolds` streams the threads the server holds for headroom
(`kind: "held"`) or paused for it (`kind: "paused"`), the whole list on
subscribe and again on every change; `infinitus.releaseThread` is "Run now" /
"Resume now", never an error. Both are answered by `InfinitusSessionHolds`
(`apps/server/src/infinitus/Services/InfinitusSessionHolds.ts`). A turn
parked on a usage limit is not here: it rides `subscribeInfinitusLimitStops`
(#648). `heldEntryFor` (client-runtime) reads one thread out of the stream;
the web sidebar (`useInfinitusHeldSummary`) and the phone's list
(`useThreadHeldEntry`) resolve `held` / `paused` above working and below
approval, input and a limit stop, one subscription per environment through
the atom family, none where the environment lacks the Infinitus capability.
The Priority settings page is `InfinitusPrefsPanel` over the catalog's
`priority` section.

No HTTP twin: the Mac's `release-thread` caller and `infinitusctl desktop
release` left with #1654, and a route nothing calls is not re-added. They
come back together with the policies if the Mac wants them.

## What holds (the engine half, pending)

The policies live on the queue lane's `TurnStartGate`
(`docs/internals/turn-start-gate.md`): a held start is a run left `starting`
— that status is the lease, nothing else starts on the thread while it
stands, which is what closes #1513's window on v2 — and a release is a fresh
`provider-turn.start` effect (`releaseTurnStart`). The hold policy judges a
start by the fleet its driver spends on (`headroomVerdict` off the Mac's
snapshot; pinned, archived or unreadable runs now) and releases on abundant,
no verdict, a pin or "Run now"; the interrupt policy pauses running
background runs on a critical fleet with `run.interrupt` and continues them
with a `message.dispatch` of the continuation prompt. Until that lands,
`InfinitusSessionHoldsIdle` answers the empty list.
