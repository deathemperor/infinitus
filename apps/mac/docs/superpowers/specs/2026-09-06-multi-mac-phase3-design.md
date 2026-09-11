# Multi-Mac phase 3 — other Macs park, and sessions start on any Mac (#144)

Phase 1 (#188) listed other paired Macs read-only. Phase 2 (#199) opened
their sessions like the primary's: transcript, replies, approvals,
checkpoints and a per-Mac queue flushed on that Mac's reachable edge
(#208 keys the edge on `lastServedFromCache`, not snapshot presence).

Two gaps remain. An other Mac has no disk cache: when it is unreachable
the phone shows the in-memory snapshot until the app relaunches, then
nothing, and its sessions' feeds have no parked tail. And the "+" sheet
and Past sessions only ever start a session on the primary.

## Goals

1. Each other Mac has its own on-disk `ParkedCache`, so its fleets,
   sessions and feed tails survive an app relaunch while it is away, and
   the phone says so ("parked") wherever that Mac appears.
2. The "+" sheet and Past sessions can target any paired Mac: profiles,
   recent folders and past sessions come from that Mac; the new session's
   chat opens on that Mac's route.

## Non-goals

- Live Activities per Mac. One Activity per Mac is its own design
  (`LiveActivities.sync` takes one fleet and one machine).
- Widgets and the share extension: `WidgetBridge` and `ShareBridge`
  publish the primary by construction; unchanged.
- `StartSessionIntent` (Shortcuts) stays primary-only. A Mac parameter
  on the intent is a separate ask.
- Bonjour for other Macs: unchanged from phase 1 (saved routes only).
- Queuing a start-session request for a parked Mac. Starting needs the
  Mac; a parked Mac's sheet shows the transport error and keeps the form.

## 1. Per-Mac disk cache

### Where it lives

`App Support/parked/<parkedKey>/`, where `parkedKey` is
`NetworkFleetMirror.parkedKey(token:)` — the same 12-hex token hash the
outbox already keys on. The primary's directory is unchanged.

`NetworkFleetMirror`:

```swift
/// The cache root for a storage's token — the primary's from
/// UserDefaults, a per-Mac pairing's from its own token.
nonisolated static func parkedCache(key: String) -> ParkedCache
nonisolated static var parkedCache: ParkedCache { parkedCache(key: parkedKey()) }
```

- `init(pairing:)` sets `parked = Self.parkedCache(key: Self.parkedKey(token: pairing.token))`
  and `cached = parked?.loadSnapshot()`. `latest()` already saves every
  successful snapshot and returns `cached` with `lastServedFromCache =
  true` when every route is dead; `sessionTail` already saves every tail
  and `parkedTail(pid:)` loads it. Nothing else in the actor changes.
- `forgetCached()` re-resolves `parked` from `storage`, not from the
  primary's key: `.defaults` → `parkedCache`; `.pairing(p)` →
  `parkedCache(key: parkedKey(token: p.token))`. Today it always points
  at the primary's directory, which would be wrong on a pairing instance.

### Lifecycle

- `forgetOther(id:)` removes the Mac's cache directory
  (`parkedCache(key:).clear()`) and its queued outbox items
  (`OutboxDelivery.outbox.items(macKey:)` → `remove(id:)`). Today a
  forgotten Mac's items are orphaned: `macKey(for:)` falls back to the
  primary's key and `flush` only walks the primary plus current others.
- `makePrimary(id:)`: the chosen Mac's directory is keyed by its token,
  and after the swap the primary's `parkedKey()` hashes that same token,
  so `NetworkFleetMirror.shared.forgetCached()` (already called) clears
  the OLD primary's directory and re-points at the chosen Mac's — the
  new primary starts with its cache intact. The demoted Mac re-enters
  `others` with an empty directory (its old one was just cleared) and
  refills on its next answer. Its outbox items keep their key (the old
  token's hash), which is what the demoted pairing's `macKey(for:)`
  yields — nothing is lost.

### What the phone shows

`OtherMac.parked` (#208) drives a marker beside the Mac's name:

- Sessions tab, the Mac's section header: name, then
  `Label("parked", systemImage: "moon.zzz")` in the secondary style.
- Fleet tab, `otherMacsArea` title: the same label after the name.
- Settings › Devices caption: `"parked — last seen <relative capturedAt>"`
  when parked (before the fleet/session counts), else unchanged.
- Settings › Devices footer becomes: "Scan another Mac's QR to add it;
  widgets and Live Activities follow the primary Mac." (the current text
  still says chats and approvals are primary-only — stale since phase 2).

The feed of an other Mac's session already shows the parked tail through
`mirror.parkedTail(pid:)` once `parked` is set, and its queued replies
already say they wait for the Mac (phase 2).

### Reachable/answered rule

Any logic that decides a Mac is reachable keys on
`lastServedFromCache`/`OtherMac.parked`, never on `snapshot != nil`. A
cached snapshot is present through the whole outage.

## 2. Start a session on any Mac

### Model

`MirrorModel` gains, on the phase 2 accessor pattern (`nil` = primary):

```swift
func profiles(macId: String?) -> [SessionProfile]   // snapshot?.profiles ?? []
func recentCwds(macId: String?) -> [String]         // snapshot?.recentCwds ?? []
func machineName(macId: String?) -> String          // primary: snapshot?.machineName ?? "the Mac"
@Published var requestedMacId: String?              // set BEFORE requestedPid; nil = primary
```

`requestedPid` stays as is (StartSessionIntent and the share extension
set it for the primary). A caller targeting another Mac sets
`requestedMacId` first, then `requestedPid`, both on the main actor in
one synchronous sequence, so the `requestedPid` observer sees both.

### Opening the new chat

`SessionsScreen.openRequestedPid()`:

- `requestedMacId == nil`: unchanged (search `fleetsWithSessions`, push
  the session).
- otherwise: search `model.other(id)?.fleets` for the pid; on a hit clear
  both fields, reset `path`, push `OtherSessionRoute(macId:session:)`.
- A forgotten Mac (`other(id)` nil) clears both fields and opens nothing.

Trigger: besides `requestedPid` and `model.snapshot?.capturedAt`, the
view also observes `model.others.map { $0.snapshot?.capturedAt }` — the
pid appears in the OTHER Mac's next snapshot, which never changes the
primary's `capturedAt`.

### "+" sheet (`StartSessionSheet`)

- `@State private var macId: String?` (nil = primary).
- A "Mac" section at the top, shown only when `!model.others.isEmpty`: a
  menu `Picker` listing `model.machineName(macId: nil)` tagged `nil` and
  each `other.pairing.name` tagged `other.id`. The order is the primary
  first, then `others` in their stored order.
- Changing the Mac resets `profile = nil`, `cwd` to that Mac's first
  recent folder (or "Another folder…"), and clears `error`. Engine,
  prompt and permission mode are kept.
- Profiles and Repository read `model.profiles(macId:)` /
  `model.recentCwds(macId:)`; `apply(_:)` checks that Mac's folders.
- `start()` calls `model.mirror(for: macId).startSession(request)`; on
  "started" sets `requestedMacId = macId`, then `requestedPid = pid`,
  dismisses, then `await model.refresh(macId: macId)`.
- A parked Mac: the transport throws → `error` shows the message, the
  form stays. (The sheet does not know parked; the error is enough.)

### Past sessions (`PastSessionsScreen`)

- `@State private var macId: String?` and the same picker as a toolbar
  `Menu` (label: the chosen Mac's name with a chevron), shown only when
  `!model.others.isEmpty`. Changing it calls `load()`.
- `load()` uses `model.mirror(for: macId).pastSessions(...)`; `resume`
  uses `model.mirror(for: macId).startSession`, then sets
  `requestedMacId`/`requestedPid` and refreshes that Mac exactly as the
  sheet does.
- The navigation title stays "Past sessions"; the Mac shows in the
  toolbar menu label.

## Files

- `ios/InfinitusMobile/NetworkFleetMirror.swift` — `parkedCache(key:)`,
  `init(pairing:)`, `forgetCached()`. Nothing in the `// MARK: team`
  block (Infi2's team-nearby2 owns it).
- `ios/InfinitusMobile/MirrorModel.swift` — `forgetOther` cleanup, the
  three accessors, `requestedMacId`.
- `ios/InfinitusMobile/SessionsScreen.swift` — parked label, requested
  routing + trigger.
- `ios/InfinitusMobile/FleetScreen.swift` — parked label.
- `ios/InfinitusMobile/SettingsScreen.swift` — caption + footer only
  (lands before Infi2's settings-phone stream starts).
- `ios/InfinitusMobile/StartSessionSheet.swift`, `PastSessionsScreen.swift`.
- `CHANGELOG.md` (one line under Phone), `README.md` (one line),
  `site/` if it lists the multi-Mac feature.

## Testing

The phone app has no unit-test target (InfinitusCore's tests cannot see
`NetworkFleetMirror` or `MirrorModel`), so verification is:

- Simulator build of `InfinitusMobile` after every task; `swift test`
  for InfinitusCore stays green (nothing in core changes).
- Signed device build gate (`gate_tp.sh`) before the PR.
- Manual, two Macs: (1) sleep the other Mac, relaunch the phone app — its
  section still lists its sessions with "parked", a session's feed shows
  the last tail; wake it — the label clears. (2) "+" → pick the other
  Mac → its folders and profiles appear → Start → the chat opens under
  that Mac. (3) Past sessions → toolbar menu → the other Mac → resume →
  same. (4) Forget the other Mac in Settings → re-pair it: its section
  starts empty (no cached fleets) and no queued items deliver.

## Decisions

- The Mac picker is a `Picker` in the sheet and a toolbar `Menu` in Past
  sessions because the sheet is a form and the screen already has a
  search field in its title bar.
- `requestedMacId` is a second field, not a struct replacing
  `requestedPid`, so the intent and share extension paths do not change.
- The demoted primary's cache starts empty after "Make primary" rather
  than being copied; the copy would only save one poll.
