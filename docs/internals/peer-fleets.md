# Other machines' accounts in the menu bar popup

The popup on one Mac shows the accounts of every other machine the desktop app is paired with, and its rows act on them (#1545). The Accounts page already did this per environment; the popup could not, because the menu bar app knows only its own engines and the connection catalog lives in the desktop's renderer, not in any server.

## The one channel is the desktop

The desktop renderer is the only process that holds every paired environment, so it feeds the Mac app: `apps/web/src/components/InfinitusPeerFleets.tsx` (mounted in `__root.tsx`, Electron only, on the primary environment when it runs Infinitus) subscribes to each remote Infinitus environment's snapshot and pushes them to the primary's app as the `peer-sync` control verb (`--body <json>`, `InfinitusPeerSyncBody` in `packages/contracts/src/infinitus.ts`; the Mac's `PeerFleets.Body`). The Mac never pairs with another machine itself — it keeps "One API" (INFINITUS.md): the phone reaches the Mac through the desktop, and so do the Mac's peers.

A push happens when a row-visible field of any remote fleet changes (`fleetFingerprint` in `peerFleets.logic.ts`: active, held, starred, warm, alias, plan, the bar percentages rounded to a whole point), when the machine set or a connection changes, when the primary's `status.peerCommandsPending` is above zero, and on a 30 s heartbeat. Not on every snapshot: a remote snapshot re-emits every few seconds with only `usageAgeSeconds` and `usageFetchedAt` moving, and every push re-renders the popup, which the Mac app's near-zero idle rule forbids.

## Peers are engines, but never `fleets`

On the Mac each (machine, remote engine) pair is a `PeerEngine` (`apps/mac/Sources/InfinitusCore/Engines/PeerEngine.swift`) registered in `EngineRegistry` under `peer:<environment>:<engine>`, so a peer fleet is an ordinary `FleetState` — the same rows, animations, stale marking — and the popup's `FleetHeader` names the machine through the engine's display name ("Claude · HyperNovae swapd"). `PeerFleetsModel` (app target) applies each push straight to the fleet states, drops engines the desktop stopped listing, marks peers unreachable after 90 s of silence and removes them after 180 s, so a closed desktop leaves no dead rows.

The trap: `AppModel.fleets` and `EngineRegistry.localFleets` exclude peers on purpose. The `fleets` verb is what the desktop reads as _this_ machine's accounts and pushes to the other machines; a peer in that list would echo around the ring. The launch cache, the team publish sources, the shared-usage donation loop and `primary` (title, notifications, the switch alert's default) read local fleets only. Only `MenuContent.populatedFleets` stacks `fleets + peerFleets`, local first.

## Actions round-trip through the desktop

A peer row's action does not run anywhere on this Mac. `PeerEngine` queues one control command in the other machine's own words (`switch swapd/claude 2`, `remove … --yes`) on the shared `PeerCommandQueue` and awaits its outcome; `status` reports the queue's size as `peerCommandsPending`, the desktop's next status poll sees it and pushes at once; the `peer-sync` reply carries the drained commands; the desktop forwards each verbatim as `infinitus.command` on that environment (`forwardable` allowlists the row verbs — never a secret-carrying one, never add or sign-in) and pushes the outcomes straight back in `results`. The row's spinner covers the round trip (about one status poll); a command nobody answers in 20 s fails as unreachable, and a late result is dropped. Adding an account and igniting stay off peer rows: both need the other machine's own screen or a verb this path does not carry.
