# Multi-Mac phase 2 — chat and actions through the session's own Mac (#144)

**Goal.** A session that belongs to another paired Mac opens like any
other: its transcript, replies, keys, approvals, checkpoints and images
go to THAT Mac, not the primary. Queued messages (#168) deliver to the
right Mac too.

**Non-goals (phase 3).** Starting a session on another Mac, Siri intents,
the share extension and widgets (primary only), a disk cache for other
Macs' snapshots and tails, Live Activities per Mac.

## What exists (map, 2026-09-06)

- `MirrorModel.others: [OtherMac]` (`pairing: MacPairing`, `snapshot`,
  `fleets`, `status`); one `NetworkFleetMirror(pairing:onLastGood:)` per
  other Mac in the private `otherMirrors` dictionary (`otherMirror(for:)`),
  used only for `latest()`.
- Every action call site hardcodes `NetworkFleetMirror.shared`:
  SessionFeedScreen (sessionTail, parkedTail, sessionInput, checkpoints),
  SessionDetailScreen (sessionInput), CheckpointsScreen (checkpoints,
  restoreCheckpoint, checkpointDiff, sessionInput), FeedThumbnail
  (sessionImage), OutboxDelivery (sessionInput), PastSessionsScreen /
  StartSessionSheet / StartSessionIntent (pastSessions, startSession),
  AwsLoginScreen, Team screens, Settings, CrashReporter, LiveActivities.
- Navigation: `NavigationLink(value: SessionDetail)` →
  `SessionFeedScreen(model:session:)`; `SessionDetailRoute { session }` →
  `SessionDetailScreen`. Other Macs' rows (`SessionsScreen.otherMacSections`)
  are plain, non-tappable, with a "Make this Mac primary…" footer.
- `MobileSessionProgress.byPid` is fed from the primary snapshot only;
  `others[i].snapshot.progressByPid` carries the same shape per Mac.
- `OutboxDelivery` keys items by `macKey = NetworkFleetMirror.parkedKey()`
  (hash of the primary token) and delivers through `.shared`.
- A `.pairing` instance skips Bonjour and rendezvous and has no
  `ParkedCache` — it needs at least one working endpoint.

## Design

### 1. The session's Mac travels with every pushed route

`SessionDetail` stays the primary's navigation value (every existing push
site unchanged). Every route that can be reached from another Mac's
session carries that Mac's id, because a pushed destination gets the
environment of the place its `.navigationDestination(for:)` is declared
(SessionsScreen), NOT of the feed that pushed it:

```swift
struct OtherSessionRoute: Hashable {
    let macId: String          // MacPairing.id
    let session: SessionDetail
}
```

- `SessionsScreen.otherMacSections` rows become `NavigationLink(value:
  OtherSessionRoute(macId: other.id, session: row))`; the footer text goes.
  `.navigationDestination(for: OtherSessionRoute.self)` pushes
  `SessionFeedScreen(model: model, session: route.session, macId: route.macId)`.
- `SessionDetailRoute` and `CheckpointsRoute` gain `macId: String?`
  (default nil). The feed builds them with its own `macId`; their
  destinations pass `macId` into `SessionDetailScreen` / `CheckpointsScreen`.
- Each of those three screens resolves `model.mirror(for: macId)` itself
  and sets `.environment(\.sessionMirror, mirror)` on its root. The
  environment is inherited only by views in the SAME body (FeedThumbnail,
  sheets, the composer) — never across a push.

Reachable-from-other-Mac audit (2026-09-06): SessionsScreen declares
`PastSessionsRoute`, `SessionDetail`, `SessionDetailRoute`,
`CheckpointsRoute`. From an other-Mac feed only `SessionDetailRoute` and
`CheckpointsRoute` are pushed; both carry `macId`. `PastSessionsRoute` and
the primary `SessionDetail` push are unreachable from it.

### 2. One environment value carries the mirror

```swift
private struct SessionMirrorKey: EnvironmentKey { static let defaultValue = NetworkFleetMirror.shared }
extension EnvironmentValues { var sessionMirror: NetworkFleetMirror { get set } }
```

Every `NetworkFleetMirror.shared.` inside SessionFeedScreen,
SessionDetailScreen, CheckpointsScreen and FeedThumbnail becomes `mirror.`
from `@Environment(\.sessionMirror)`. Screens reached from a primary
session keep the default (`.shared`), so nothing changes for the primary
path. `parkedTail` on a `.pairing` instance returns nil (no cache) — the
existing "couldn't reach the Mac" text stands.

### 3. `MirrorModel` exposes the per-Mac pieces

Every `model.` read in those screens that is per-Mac data goes through a
`macId`-aware accessor; `nil` means the primary and returns exactly what
the screens read today.

- `func mirror(for macId: String?) -> NetworkFleetMirror` — `.shared`
  when nil or unknown, else `otherMirror(for: pairing)`.
- `func other(_ macId: String) -> OtherMac?` — lookup in `others`.
- `func progress(macId: String?, pid: Int) -> SessionProgress?` —
  `sessionProgress.byPid[pid]` when nil, else
  `other(macId)?.snapshot?.progressByPid?[pid]` (already the same
  `SessionProgress` type; no re-decoding).
- `func accountSummary(macId: String?, pid: Int) -> SessionAccountSummary?`
  — today's `accountSummary(forSessionPid:)` when nil, else
  `SessionAccountLookup.summarize(pid:, fleets: Self.engineFleets(from:
  other.snapshot) ?? [])`.
- `func fleets(macId: String?) -> [MirrorFleetModel]` — `fleets` when nil,
  else `other(macId)?.fleets ?? []`.
- `func awsLogin(macId: String?, pid: Int) -> AwsLogin.Item?` — today's
  `awsLogin(for:)` when nil, else the match in
  `other(macId)?.snapshot?.awsLogins`.
- `func births(macId: String?) -> [Int: Date]?` (or the snapshot's own
  births type) — `snapshot?.births` when nil, else the other's.
- `func transportStatus(macId: String?) -> String` — `transportStatus`
  when nil, else `other(macId)?.status ?? ""`.
- `func refresh(macId: String?) async` — `refresh()` when nil, else
  `refreshOthers()` (made callable from here; the `refreshingOthers`
  guard stays).
- `func macName(_ macId: String?) -> String?` — `other(macId)?.pairing.name`.

Per-field rulings for the two screens' `model.` reads:

| read | ruling |
|---|---|
| SessionFeedScreen `awsLogin(for:)` | `awsLogin(macId:pid:)` |
| SessionFeedScreen `accountSummary(forSessionPid:)` + `fleets.first` | `accountSummary(macId:pid:)` + `fleets(macId:)` |
| SessionFeedScreen `sessionProgress.byPid[...]` (branch, model words) | `progress(macId:pid:)` |
| SessionFeedScreen `stagedCapture` | primary only: `takeStagedCapture()` returns early when `macId != nil` (the share extension stages for the primary; a same-pid other-Mac feed must not swallow it) |
| SessionFeedScreen `rowTheme` | phone-local, unchanged |
| SessionDetailScreen `accountSummary(forSessionPid:)` | `accountSummary(macId:pid:)` |
| SessionDetailScreen `transportStatus` | `transportStatus(macId:)` |
| SessionDetailScreen `snapshot?.births` | `births(macId:)` |
| SessionDetailScreen `refresh()` | `refresh(macId:)` |
| SessionDetailScreen `rowTheme` | unchanged |
| SessionsScreen `row(session)` for other Macs (`progress.byPid`) | `progress(macId: other.id, pid:)` so other Macs' rows stop wearing the primary's names |

The chat header shows the Mac's name as a caption when `macId != nil`.

### 4. Outbox per Mac

- `NetworkFleetMirror.parkedKey(token:)` — the same 12-hex hash for any
  token, normalized exactly as `pairToken()` normalizes the primary's;
  `parkedKey()` calls it with the primary's.
- `OutboxDelivery.macKey(for macId: String?, model:)` → primary key or
  `parkedKey(token: pairing.token)`.
- `SessionFeedScreen` enqueues with that key.
- `OutboxDelivery.flush(macKeys: [String], model:)` walks only the given
  keys, delivering each key's items through the mirror that owns it
  (`model.mirror(for:)`); `Outbox.flush` is per key, so a transport error
  on one Mac stops that Mac's pass only, the others continue.
- Reachable edges, per Mac, not per round: the primary keeps
  `reachableAgain` (parked → live, and first load). `refreshOthers` keeps
  a private `othersReachable: Set<String>` of Mac ids whose last poll
  returned a snapshot; a Mac whose id was absent and now answered (or any
  Mac on the first completed round) fires `otherReachable?(macId)` once.
  A Mac that stays down never triggers a flush, so its queued items keep
  their attempt count and the poll loop never waits on its dead
  endpoints outside its own `latest()`.
- `OutboxItem` is unchanged (it already stores `macKey`).

### 5. Error handling

- A `.pairing` mirror with every endpoint dead throws the same transport
  errors; the feed shows "couldn't reach <Mac name>" (name from
  `macName`), the composer queues as today.
- `makePrimary`/`forgetOther` while an other-Mac feed is open: the
  environment mirror instance stays valid for that screen (the actor is
  retained by the view); on pop, the list is rebuilt from `others`.
- pid collisions across Macs: every per-pid cache in these screens is
  view-local, and `progress(macId:pid:)` is keyed by Mac first, so two
  Macs sharing a pid never mix.

### 6. Testing

No phone unit target: `xcodebuild` (simulator) in CI plus the signed
device build here. Manual: pair two Macs, open a session under the
second Mac's section, read the tail, send a message (lands on that Mac's
terminal), allow a tool, open Checkpoints; put that Mac to sleep, send —
queued under its key; wake it — delivered, primary untouched. InfinitusCore
is untouched, so `swift test` is a no-op gate here. Second-Mac test bed
on this machine: Infi3's debug instance (mirror on port 47825, token in
a file) paired to Titan as an other Mac.

### 7. Decisions

- Navigation value, not a global "current Mac": two feeds from two Macs
  can sit on the stack at once.
- Environment key for same-body children only (FeedThumbnail, sheets);
  pushed screens carry `macId` in their route because a destination's
  environment comes from where `.navigationDestination` is declared.
- Flush per Mac on that Mac's own reachable edge, never per poll round:
  a dead Mac must not cost every other Mac's queue a timeout every 10 s.
- Other Macs stay Bonjour-less and cache-less in phase 2.
