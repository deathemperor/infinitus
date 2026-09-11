# Mobile companion — brainstorm (2026-09-01)

Asked for as "a mobile app companion of Infinitus". Nothing is decided;
this maps the space and marks the decisions that are the user's.
No code until a direction is picked.

## What "companion" plausibly means

The desk app already covers the desk. The phone's job is the away
case, which today is only `cswap notify slack` (webhook push, one-way,
no state). Candidate jobs, roughly in value order:

1. **Fleet at a glance** — the popup's content: per-account 5h/7d/
   per-model gauges, active + next candidate, recovery countdowns,
   all-limited banner with sessions-waiting count.
2. **Push that matters** — switch happened, all accounts exhausted,
   first account recovered, session resumed. Today these die on the
   Mac's Notification Center (and the Slack webhook).
3. **Remote actions** — switch to N, disable/enable rotation, send the
   resume nudge. This is what turns "glance" into "don't walk back to
   the desk".
4. **Live Activity / widgets** — recovery countdown in the Dynamic
   Island; a lock-screen gauge widget. High polish-to-effort ratio on
   iOS; nothing equivalent on the Mac side to build.

## Hard constraints carried over

- **Engine isolation**: the phone must never hold OAuth credentials or
  read engine internals. Everything the phone sees is a snapshot the
  Mac app already derived via `cswap … --json`. (A "standalone" app
  that copies credentials onto the phone is rejected on this rule
  alone.)
- **Secrets over stdin, masked display** — same posture: whatever
  transport is picked must not put tokens in URLs or argv.
- **The Mac may be asleep.** A companion that only relays a live Mac is
  honest about it: state goes stale, actions queue. Push must carry
  enough payload to render without a fetch.

## Architecture options

### A. Read-only mirror (CloudKit)
Mac app writes the fleet snapshot (the same `AccountList` we already
decode) to the user's private CloudKit database on every refresh;
phone subscribes (CKQuerySubscription → APNs push, silent + alert).
- No server to run, no accounts beyond the user's iCloud, transport
  encrypted and scoped to the Apple ID. The app already has an iCloud
  sync pane (SettingsSyncModel) — same mental model.
- InfinitusCore is pure Swift: Models/DisplayLogic/GaugeMath/AutoOrder/
  RecoveryCountdown compile for iOS as-is. The phone app is mostly
  SwiftUI over code we already ship. GaugeBar & friends are macOS-
  flavored but small.
- Cost: requires a paid Apple Developer membership for CloudKit +
  push entitlements — the same membership that unlocks the
  long-standing Developer ID / notarization todo. One purchase, two
  todos.

### B. Two-way remote (CloudKit command queue)
A on top of a `commands` record type: phone writes
`{switch|disable|enable|nudge, target}`, Mac app subscribes, validates,
executes via the existing CLI verbs, writes the result back. No inbound
port on the Mac, works from anywhere, offline-queues naturally.
- The dangerous verbs stay on the Mac: the phone only ever asks.
- Needs idempotency + a confirm step in the phone UI for switch (it
  kills the desk session's account mid-turn otherwise).

### C. Direct connection (Tailscale/WireGuard + local HTTP)
Infinitus serves a small localhost API; the phone reaches it over the
user's tailnet. Real-time, no Apple membership, Android-capable.
- Cost: we now maintain an HTTP server + auth inside the menu bar app,
  and it only works while the Mac is awake and on the tailnet. More
  moving parts on the trusted side, which is the wrong side to grow.

### D. Push-only, no app (ntfy.sh / Pushover)
Extend `cswap notify` with a second channel. Cheapest possible away
signal, no fleet view, no actions. Worth doing anyway as a stopgap;
does not satisfy "companion app".

## Recommendation

**A first, B second, same transport.** CloudKit mirror ships a real
read-only companion (fleet view + push + countdown Live Activity) with
the least new trust surface, and B is an additive record type on the
same rails when remote actions are wanted. C only wins if Android is a
requirement — CloudKit is Apple-only.

MVP cut for A:
1. Mac: `CloudKitMirror` service — snapshot upsert on refresh + event
   records on switch/all-exhausted/recovery (reuses the event feed).
2. iOS app: single fleet screen (rows ≈ popup rows), pull-to-refresh
   reads CloudKit, push renders from payload. InfinitusCore via SPM.
3. Live Activity: recovery countdown when all accounts are limited.
4. TestFlight distribution (personal use; no App Store review fight).

## Teams (asked 2026-09-01)

CloudKit shares user-to-user: a private-database custom zone can be
shared whole (CKShare zone sharing, macOS 12.3+/iOS 15.4+) to invited
Apple IDs, read-only or read-write, surfacing in the invitee's shared
database with live sync. Team shape: each member publishes their fleet
snapshot into their own zone and shares it read-only; every member's
app merges own + shared zones into a team dashboard (limits, headroom,
waste across the team). Read-write participants would even allow
cross-user rotation requests — wants explicit confirm UX on the
receiving Mac. Constraints: iCloud + Apple platforms only, one CloudKit
container = one dev team for all builds, and shared zones expose
account emails/usage — opt-in per zone with a "what they'll see" note.

## Effects parity (asked 2026-09-01)

Full parity in-app under the CloudKit mirror: the macOS popup is
itself poll-driven, and every effect is rendered locally from state —
HP drops animate the diff between consecutive snapshots, chill/burn/
celebration are local TimelineView loops keyed off snapshot state,
countdowns tick from `resetsAt`. GaugeMath/DisplayLogic compile for
iOS unchanged. Caveats are cadence, not capability: drops land per
Mac refresh (~60s, same as desktop); a stale reopen should suppress
the one giant catch-up drop (or play the playground cascade); a
sleeping Mac freezes state (badge staleness). Platform rule regardless
of transport: WidgetKit renders are static/budgeted and Live Activity
pushes are budgeted — lock-screen countdowns tick natively, but
continuous ambient effects are in-app only.

## Live Activities (issues #1, #2 — designed 2026-09-01)

Two activities, one ActivityAttributes each, both fed by the CloudKit
mirror's push pipeline. iOS budgets Live Activity pushes — the designs
lean on `Text(timerInterval:)` / `ProgressView(timerInterval:)`, which
tick natively with ZERO pushes, and reserve pushes for state changes.

### Working sessions (#2)
Runs while the Mac reports busy sessions.

- Lock screen / banner: leading — active account (icon/alias) over a
  small binding-window gauge; center — "3 working · 12 sessions";
  trailing — the next candidate, deliberately subtle (dimmed "→ loc",
  no gauge: it's a hint, not a second protagonist).
- Dynamic Island: compact leading ∞ glyph (or the account's one-emoji
  icon), compact trailing binding % (tabular digits); expanded — alias
  + plan, 5h/7d mini-bars, footer "next: loc"; minimal — %.
- Updates (pushed): switch happened (new alias), binding % moved ≥5pts,
  session counts changed. Everything else waits — budget discipline.
  `NSSupportsLiveActivitiesFrequentUpdates` if the budget bites.
- Lifecycle: start when busy > 0 arrives, end after busy == 0 holds
  ~10 min (or 8h max runtime — re-arm on next event).

### All-dead revival countdown (#1)
Starts when the fleet snapshot says every account is limited.

- Lock screen: "All accounts limited" (urgent accent) — first-reviver
  alias — `Text(timerInterval:)` countdown to its recovery instant —
  "N sessions waiting to resume". Ticks without pushes.
- Dynamic Island: expanded — countdown center-stage inside a
  progress ring (stop → reset); compact — ⏳ + mm:ss; minimal ⏳.
- End: the recovery/switch push flips it to a brief "revived — loc is
  back" final state, then dismisses. If the reviver changes (an
  earlier reset appears), one push rewrites the timer.
- macOS equivalent: the menu bar countdown exists today; the designed
  extra is a small floating always-on-top panel (countdown + reviver,
  click opens the popup) — plus the free win that macOS 15+ surfaces
  iPhone Live Activities in the menu bar via iPhone Mirroring once the
  iOS side ships.

## The user's decisions (blocking)

1. **Platform**: iOS only, or Android too? (Android kills option A/B
   as-is → C or a self-hosted relay.)
2. **Read-only first, or is remote control the whole point?**
3. **Apple Developer membership** ($99/yr): required for A/B push +
   CloudKit — and it would also unlock Developer ID signing for the
   Mac app (docs/RELEASING.md pipeline is already built for it).
4. Where the phone UI should sit on the theme spectrum: plain gauges
   or the full themed treatment (RPG/MGS/…)?
