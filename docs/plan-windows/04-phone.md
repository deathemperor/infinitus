# 04 — Phone: multi-host fleet merge, per-host tokens, target host UX

Scope: `ios/InfinitusMobile` (Swift, iOS 17). The Mac app is untouched.
Wire format unchanged; only client state and routing grow.

## Today (verified in code)

- `NetworkFleetMirror` (`ios/InfinitusMobile/NetworkFleetMirror.swift`):
  `tokenKey = "mirror_pair_token"` (one String), `manualKey = "mirror_manual_endpoints"`
  (`[String]`, failover order for ONE host), `lastGoodKey` (last endpoint
  that answered). `latest()` tries stored endpoints in last-good-first
  order, then Bonjour; stops on 401. `sessionTail` long-poll →
  `candidateEndpoints().first` only; `sessionImage`/`fetchFromStored` walk
  the list; `sessionInput` → `candidateEndpoints().first` only (POST is not
  idempotent).
- `MirrorModel.applyPairing` REPLACES `manualEndpoints` and `pairToken`
  (`MirrorModel.swift:114-120`).
- `SessionsScreen` lists `fleet.liveSessions?.sessions` per fleet section,
  `id: \.pid`; `NavigationLink(value: session)` with `SessionDetail`
  (`Hashable`, all fields); `SessionFeedScreen` calls
  `NetworkFleetMirror.shared.sessionTail/sessionInput(pid:…)` with no host.
- `FeedThumbnail` caches by `"pid/id"`.
- `MirrorModel.reconcile` keys fleets by `EngineFleet.key` = `engineID/provider`.

Scanning a second QR today unpairs the first host; two hosts with the same
pid would collide in the sessions list and the thumbnail cache.

## Target model

```swift
struct MirrorHost: Codable, Identifiable, Equatable {
    var id: String            // UUID minted on pairing
    var label: String         // from snapshot.machineName, editable
    var emoji: String         // user-picked; default "🍎" for a Mac snapshot, "🪟" when fleets[0].engineID hasPrefix "claude-code-windows", "🖥️" otherwise
    var endpoints: [String]   // this host's failover list (LAN, tailnet, tunnel)
    var token: String         // normalised 24×base32
    var lastGood: String?     // per-host last-good endpoint
}
```

Storage: `UserDefaults` key `mirror_hosts` (JSON-encoded `[MirrorHost]`).
Migration on first launch: if `mirror_hosts` is absent and either
`mirror_pair_token` or `mirror_manual_endpoints` is non-empty, create host
#0 `{label: "Mac", emoji: "🍎", endpoints: <old list>, token: <old token>,
lastGood: <old lastGoodKey>}`; leave the old keys in place (rollback), stop
reading them.

Per-host tokens (README decision): each host mints its own; the phone
stores one per host. Pairing UI: "Scan QR" adds or updates a host —
matching rule: same token → update endpoints; else new host. Never replaces
another host.

## Transport changes (`NetworkFleetMirror`)

- `latest()` → `latestAll()`: fetch `/snapshot` from every host
  concurrently (`withTaskGroup`), 3 s per candidate as today; return
  `[(host, MirrorSnapshot?)]`. Bonjour results are matched to a host by
  answering `/snapshot` with each stored token until one is accepted
  (a 401 from host A's token is expected on host B — do NOT stop on 401 in
  the discovery loop; the per-host stored-endpoint loop keeps its 401 stop).
- `sessionTail(host:pid:…)`, `sessionImage(host:pid:id:)`,
  `sessionInput(host:pid:request:)`, `awsLogin*(host:…)`: take a `MirrorHost`
  and use its endpoints/token. Long-poll and POST go to the host's
  `lastGood` first endpoint, as today.
- `statusText` becomes per-host (`[hostID: String]`).
- Device headers (`x-infinitus-device-id`, `x-infinitus-device`) unchanged.

## Model changes (`MirrorModel`)

- `hosts: [MirrorHost]` published; `snapshots: [hostID: MirrorSnapshot]`.
- `reconcile`: fleet key becomes `"\(hostID)/\(engineFleet.key)"` so two
  hosts' `cswap` fleets do not merge. `MirrorFleetModel` gains `hostID`
  and `host: MirrorHost` accessor.
- Facade (`primary`, `accounts`, Live Activities): the first host that has
  a `.claude` fleet with non-empty accounts — the Mac — keeps the Fleet tab
  behaviour; a Windows host contributes no accounts (`accounts: []`) and is
  hidden from the Fleet tab when its `engineID` has prefix `claude-code-`.
- `awsLogins`: per host; a Windows host reports none.
- `sessionProgress.apply` keyed by `(hostID, pid)` — `MobileSessionProgress.byPid`
  becomes `byKey: [SessionKey: SessionProgress]` with
  `struct SessionKey: Hashable { let hostID: String; let pid: Int }`.

## Sessions screen

- One merged list; section per host (header `"\(emoji) \(label) — \(SessionSummary.tooltip(live))"`),
  hosts in stored order, waiting-first sort inside each. With one host the
  header stays as today.
- Row `id`: `SessionKey`. Navigation value: a new `HostSession { host: MirrorHost; session: SessionDetail }`
  (Hashable) replacing bare `SessionDetail` in `navigationDestination`.
- `INFINITUS_FEED_PID` dev seam: keep; matches the first host with that pid.
- Empty states: "No live sessions" when every host answered with none;
  "Waiting for the fleet" only when no host is paired.

## Feed screen

- `SessionFeedScreen(model:hostSession:)`; every transport call passes
  `hostSession.host`. Title prefix with the host emoji when `hosts.count > 1`.
- Composer: disabled with "this host can't receive messages for this
  session" when `feed.canMessage == false` (W9's additive field). Key row
  hidden when `feed.keys == false`. Permission card copy on key-less hosts:
  "approve in the session's terminal".
- Outcome text: `describe(outcome)` unchanged; when `feed.permissionMode == "default"`
  and the reply is `delivered/socket`, append " — the session may hold it
  for approval in its terminal".
- `FeedThumbnail` cache key: `"\(hostID)/\(pid)/\(id)"`.

## Settings screen

Section "Hosts" replaces "Mac connection":

- List of hosts: emoji + label + status line (`transportStatus[hostID]`),
  swipe-to-delete (removes the host and its token), tap → host detail:
  editable label, emoji picker (a short fixed palette: 🍎 🪟 🐧 🖥️ 💻 🏠 🏢),
  endpoints list with add/remove (today's per-endpoint UI, scoped), token
  field (masked display, `MirrorPairing.mask`, editable).
- "Scan a QR code" / "Add by address + token": both create-or-update a host
  per the matching rule above. The "Paired" alert names
  `snapshot.machineName` of that host.
- `infinitus://pair?url=…&token=…` deep link (`InfinitusMobileApp.onOpenURL`)
  → same create-or-update path. `infinitus://sessions` unchanged.

## Choosing the target host for input

There is no cross-host ambiguity: input always goes to the host that owns
the session the user is looking at (`HostSession.host`). No host picker on
the composer. The only host-level choice is which QR to scan; the sessions
list shows every host at once.

## Live Activities / background refresh

`LiveActivities.shared.sync(fleet:machine:tokenRate:)` keeps reading the
primary (Mac) fleet. `BackgroundRefresh` calls `MirrorModel.shared.refresh()`
— which now fans out to every host; keep the 3 s per-candidate timeout so
the budget holds. Windows hosts add a session count to the activity later
(not in this plan).

## project.yml

No new keys: `NSBonjourServices: [_infinitus._tcp]` and the `infinitus`
URL scheme cover Windows daemons. Bump `MARKETING_VERSION` to `0.5.0` with
the multi-host release (W17).
