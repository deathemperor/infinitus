# Parked sessions — design (#168)

**Goal.** When the Mac is unreachable (asleep, off Wi-Fi, rebooting), the
phone keeps working from what it last saw: the sessions list and each
session's transcript tail stay readable ("Parked"), a message typed into a
session is queued instead of lost, and it is delivered — once — when the
Mac is back, with a notification when that happens.

**Scope.** Phase 1, primary Mac only (the #144 "other Macs" rows stay
read-only, as today). Text and attachments both queue. Dedup is the
hardest requirement and comes first.

## What exists (from the map, 2026-09-06)

- `NetworkFleetMirror.latest()` keeps an in-actor `cached` snapshot that
  dies with the process; the Documents `mirror-snapshot.json` fallback has
  no iOS writer. `sessionTail(pid:…)` results live only in
  `SessionFeedScreen.feed`.
- `sessionInput(pid:request:)` is non-idempotent by design and never
  retries; on failure the composer shows "couldn't reach the Mac" and the
  draft stays. `PendingSent` is the optimistic echo shape.
- `CrashReporter` already spools JSON files under Application Support and
  flushes them on the next Mac contact — the persist → retry → delete
  pattern to copy.
- `BackgroundRefresh` (BGAppRefreshTask `run.infinitus.mobile.refresh`)
  already calls `MirrorModel.refresh()` in the background, so a flush that
  hangs off `refresh()` also runs there.
- The Mac pushes plain alerts through `LiveActivityPusher.pushAlert` to
  `.alert` registrations (`AppModel.swift:656`).
- `MirrorSnapshot.liveSessions?.sessions` rows (`SessionDetail`) come from
  the engine's `listJSON` and carry `pid`, `cwd`, `status`, `kind` — no
  `sessionId`; the session tail (`SessionFeed.sessionId`) does. Pids do
  not survive a Mac reboot, sessionIds do, and the Mac can map one to the
  other (`ClaudeSessions.list` records carry both).
- There is no iOS unit-test target; testable logic goes in InfinitusCore.

## Components

### 1. `ParkedCache` (InfinitusCore/ParkedCache.swift)

Pure file store, `Sendable` struct over a root directory.

```
root/
  snapshot.json          MirrorSnapshot, last successful fetch
  tails/<pid>.json       SessionFeed, last successful tail fetch
```

- `init(root: URL)`; the phone passes
  `Application Support/parked/<macKey>/`.
- `saveSnapshot(_ s: MirrorSnapshot) throws` — writes atomically; a
  no-op when `s.capturedAt == lastSavedCapturedAt` (kept in memory), so a
  10-second poll that returns the same snapshot never touches disk.
- `loadSnapshot() -> MirrorSnapshot?`
- `saveTail(_ feed: SessionFeed, pid: Int32) throws` /
  `loadTail(pid: Int32) -> SessionFeed?` — the tail is stored as fetched
  (the fetch `limit` already bounds it); `saveTail` is a no-op when the
  feed's last line id equals the stored one.
- `clear()` — removes the directory (used when the primary Mac changes).

### 2. `Outbox` (InfinitusCore/Outbox.swift)

One queued request per session, persisted one file per item.

```swift
public struct OutboxItem: Codable, Sendable, Equatable {
    public let id: UUID
    public let macKey: String          // primary Mac's pairing identity
    public var pid: Int32              // last known pid, re-resolved on flush
    public let sessionId: String?      // survives a Mac reboot
    public let sessionName: String     // for the card and the notification
    public var request: SessionInput.Request
    public let createdAt: Date
    public var updatedAt: Date
    public var attempts: Int
    public var state: State
    public enum State: Codable, Sendable, Equatable {
        case queued
        case inFlight                  // persisted BEFORE the send
        case refused(String)           // the Mac answered and said no
        case ended                     // session gone from the fresh snapshot
    }
}
```

`Outbox` (struct over `root: URL`, files `<macKey>-<pid>.json`):

- `items(macKey:) -> [OutboxItem]` sorted by `createdAt`.
- `enqueue(macKey:pid:sessionId:sessionName:request:now:) -> OutboxItem` —
  the one-per-session rule: if an item exists for `(macKey, pid)` its
  `request.text` becomes `old + "\n\n" + new`, attachments are appended,
  `updatedAt = now`, state resets to `.queued`; the `requestId` is
  regenerated (the old one was never sent, or was sent and refused).
- `replace(id:request:now:)` — the Edit path.
- `remove(id:)`.
- `flush(macKey:now:deliver:) async -> [FlushResult]` where
  `deliver: (OutboxItem) async -> Delivery`,
  `enum Delivery { case delivered, transport, refused(String), ended }`.
  The Mac resolves a stale pid by the request's `sessionId` (see §3), so
  the phone never has to. Per item, in order:
  1. skip `.ended` and `.refused` items (they wait for the user);
  2. state `.inFlight` saved to disk, then `deliver`;
  3. `.delivered` ⇒ file removed; `.transport` ⇒ state `.queued`,
     `attempts += 1`, stop flushing (the Mac is gone again);
     `.refused(r)` ⇒ state `.refused(r)`, continue; `.ended` ⇒ state
     `.ended`, continue.
  A `.inFlight` item found at load time (phone died mid-send) is flushed
  again with the SAME `requestId` — the Mac's dedup makes that safe.

### 3. Wire and dedup

- `SessionInput.Request` gains `requestId: String?` (UUID string),
  `queuedAt: Date?` and `sessionId: String?`; all optional so old JSON
  decodes. The Mac's input closure looks the pid up first and falls back
  to a record with the same `sessionId` (the session survived a reboot
  under a new pid); when neither matches it replies `rejected` with detail
  `"session ended"` instead of today's 404. `init` keeps its
  defaults; the phone sets `requestId` on every send (queued or not — a
  plain send that times out and is retried by hand benefits too) and
  `queuedAt` only on outbox deliveries.
- `InputDedup` (InfinitusCore/InputDedup.swift): `mutating func
  firstSight(pid: Int32, requestId: String) -> Bool`, a per-pid ring of
  the last 64 ids. Tests cover ring eviction and per-pid isolation.
- `MirrorServer` `POST /sessions/<pid>/input`: when `requestId` is present
  and `firstSight` is false, reply `outcome: "delivered", detail:
  "duplicate"` without touching the session. When `queuedAt != nil` and the
  outcome is `delivered`/`running`/`captured`, call
  `pushAlert(title: "Delivered to <session name>", body: first 80 chars of
  the text)` — the phone that queued it may be in the background; every
  other paired phone learns too.

### 4. Phone wiring

- `macKey`: first 12 hex of SHA-256 of the primary pairing token; `"local"`
  when there is none. Changing the primary (`makePrimary`) clears the
  cache and leaves the old Mac's outbox files in place (they are keyed by
  the old `macKey` and shown again if that Mac becomes primary later).
- `NetworkFleetMirror`: at init seeds `cached` from
  `ParkedCache.loadSnapshot()`; on every successful fetch calls
  `saveSnapshot`; a new actor var `lastServedFromCache: Bool` is set on
  the fallback path and cleared on success.
- `MirrorModel`: `@Published var parked: Bool` = `lastServedFromCache`
  after `latest()`; `parkedSince: Date?` = the cached snapshot's
  `capturedAt`. On the transition parked → reachable (or `snapshotLoaded`
  turning true on launch) it calls `OutboxDelivery.flush(model:)`.
- Banners: `FleetScreen` and `NativeFleetScreen` show "Parked — last seen
  <relative time>" from `model.parked` (connectivity), and keep the
  existing 180 s `StalenessBanner` for the reachable-but-old case; both
  read the same two model flags, no third copy.
- `SessionFeedScreen.load`: on failure with `feed == nil` seed from
  `ParkedCache.loadTail(pid)` and set `errorText = "parked — showing the
  last transcript"`; on success `saveTail`. Sessions in a parked snapshot
  stay tappable.
- Sending (`send(...)`): a thrown `URLError` (transport) ⇒
  `Outbox.enqueue`, the composer clears, the queued text shows as a
  `PendingSent` echo marked queued. Any `SessionInput.Reply` outcome is
  the Mac's answer and stays as today. A queued item shows as a card above
  the composer: "Queued for when the Mac is back · <relative time>" with
  **Edit** (moves the text and attachments into the composer, removes the
  item) and **Discard**; `.refused(r)` shows r; `.ended` shows "That
  session has ended" with Discard (resume-and-deliver is phase 2, #164's
  resume route).
- `OutboxDelivery` (ios): `flush()` builds `deliver` from
  `NetworkFleetMirror.shared.sessionInput` with `queuedAt = item.updatedAt`
  and the item's `sessionId`; a thrown transport error → `.transport`,
  `outcome ∈ {delivered, running, captured}` → `.delivered`,
  `rejected` + detail `"session ended"` → `.ended`, anything else →
  `.refused(detail ?? outcome)`. After a `.delivered` while the app is not active it
  posts a local notification "Delivered to <session name>" (the Mac's
  push covers the closed-app case; the local one covers "reachable again
  while I'm on another screen").

### 5. Error handling

- Nothing is dropped silently: transport failures leave the item queued
  with `attempts` (shown after 3), Mac refusals are shown verbatim, ended
  sessions are kept until the user discards.
- A corrupt cache or outbox file is skipped and logged, never fatal.
- All disk writes are atomic (`Data.write(options: .atomic)`), the same
  idiom as `HookKillSwitch`.

### 6. Testing

InfinitusCore (`swift test`):
- `ParkedCacheTests`: snapshot round trip; same `capturedAt` does not
  rewrite (mtime unchanged); tail round trip; `clear`.
- `OutboxTests`: enqueue merges into one item per session and regenerates
  `requestId`; replace; flush order and state machine — `inFlight` is on
  disk before `deliver` runs (deliver closure reads the file), delivered
  removes, transport stops the pass and keeps the rest queued, refused
  continues, `.ended` ends the item; a leftover `inFlight` item
  flushes again with the same id.
- `InputDedupTests`: second sight false, 65th id evicts the first, pids
  isolated.
- `SessionInputTests`: JSON without `requestId`/`queuedAt` decodes.

Phone: `xcodebuild` in CI (ios job); manual: airplane-mode the phone with
the app open → sessions and a feed stay readable with the Parked banner;
send a message → queued card; leave airplane mode → delivered, card gone,
notification shown; kill the app mid-flush → no duplicate on the Mac.

### 7. Decisions

- Primary Mac only (#144 phase 2 decides whether other Macs get outboxes).
- The phone delivers; the Mac only dedups and pushes. No server-side
  queue — the Mac is unreachable when the queue is needed.
- One item per session, edit-by-append; never two.
- `requestId` on every send, not only queued ones.
