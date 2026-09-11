import * as Effect from "effect/Effect";
import * as Schema from "effect/Schema";

import { ForwardCompatibleOptional, ThreadId, TrimmedNonEmptyString } from "./baseSchemas.ts";

/**
 * Wire contracts for the Infinitus control socket: one JSON line per request,
 * one per reply, one request per connection. The native app's command table is
 * a runtime manifest whose `replyShape` is prose, so every reply schema here is
 * hand-written and validated at the boundary. Structs are left open on purpose
 * — Effect's default `onExcessProperty` drops unknown keys instead of failing,
 * so a field added on the native side never breaks decoding here.
 */

/** One request line: `infinitusctl <command> <args…>`, options keyed without
    dashes, `secret` carrying stdin-read material such as the proxy key. */
export const InfinitusControlRequest = Schema.Struct({
  command: Schema.String,
  args: Schema.Array(Schema.String),
  options: Schema.Record(Schema.String, Schema.String),
  secret: Schema.optionalKey(Schema.String),
});
export type InfinitusControlRequest = typeof InfinitusControlRequest.Type;

/** One reply line, the envelope every control command answers with. `result`
    holds the command's own shape; `restarting` is absent on older builds and
    on every reply that does not relaunch the app. */
export const InfinitusControlReply = Schema.Struct({
  schemaVersion: Schema.Number,
  ok: Schema.Boolean,
  result: Schema.optionalKey(Schema.Unknown),
  error: Schema.optionalKey(Schema.String),
  restarting: Schema.Boolean.pipe(Schema.withDecodingDefault(Effect.succeed(false))),
});
export type InfinitusControlReply = typeof InfinitusControlReply.Type;

/** What calling a command does. `destructive` deletes a credential and needs
    `--yes`; `human` starts a flow a person finishes in the app window. */
export const InfinitusCommandEffect = Schema.Literals([
  "read",
  "write",
  "destructive",
  "restart",
  "human",
]);
export type InfinitusCommandEffect = typeof InfinitusCommandEffect.Type;

/** One row of the `manifest` command's table: enough to call a command without
    reading the native source. `replyShape` is prose, not a schema. */
export const InfinitusManifestCommand = Schema.Struct({
  name: Schema.String,
  args: Schema.Array(Schema.String),
  options: Schema.Array(Schema.String),
  effect: InfinitusCommandEffect,
  requires: Schema.optionalKey(Schema.String),
  summary: Schema.String,
  replyShape: Schema.String,
  /** What the request line's `secret` field carries for this verb (#747):
      `"secret"` (stdin material: a code, a token, a key), `"payload"` (a
      message or hook body), absent or null for none. A string rather than
      literals so a value a newer app adds decodes; only `"secret"` opens
      `infinitus.secret`. */
  stdin: Schema.optionalKey(Schema.NullOr(Schema.String)),
});
export type InfinitusManifestCommand = typeof InfinitusManifestCommand.Type;

/** The `manifest` command's reply: the whole command table plus the protocol's
    schema version. */
export const InfinitusManifest = Schema.Struct({
  schemaVersion: Schema.Number,
  commands: Schema.Array(InfinitusManifestCommand),
});
export type InfinitusManifest = typeof InfinitusManifest.Type;

/** One engine's line in the `status` reply. `keyPresent` only exists for the
    engines that hold a key (cliproxy, 9router). */
export const InfinitusEngineState = Schema.Struct({
  enabled: Schema.Boolean,
  registered: Schema.Boolean,
  keyPresent: Schema.optionalKey(Schema.Boolean),
});
export type InfinitusEngineState = typeof InfinitusEngineState.Type;

/** The Cloudflare quick tunnel the Mac app can run in front of this server's
    port, for pairing a phone off the LAN (#572). `state` is one of off,
    invalidPort, blocked, unavailable, starting, up, stopped — kept a string so
    a state a newer build adds does not cost the whole status; `url` only
    while up. Absent from builds before the tunnel and from the Linux tray. */
export const InfinitusForkTunnel = Schema.Struct({
  enabled: Schema.Boolean,
  port: Schema.Number,
  state: Schema.String,
  url: Schema.optionalKey(Schema.String),
  hostname: Schema.optionalKey(Schema.String),
});
export type InfinitusForkTunnel = typeof InfinitusForkTunnel.Type;

/** The `status` command's reply: app build, the socket it answers on, the menu
    bar badge, which engines are on, and the fork tunnel where the build has one. */
export const InfinitusStatus = Schema.Struct({
  version: Schema.String,
  sha: Schema.String,
  socket: Schema.String,
  badge: Schema.String,
  playground: Schema.Boolean,
  signInRunning: Schema.Boolean,
  engines: Schema.Record(Schema.String, InfinitusEngineState),
  forkTunnel: Schema.optionalKey(InfinitusForkTunnel),
  /** The running app's own bundle path (#777): the fork's startup reconcile
      quits and reopens a stale helper only when this is its nested bundle.
      Absent from helpers that predate it; the struct drops unknown keys, so
      the two versions tolerate each other. */
  bundlePath: Schema.optionalKey(Schema.String),
});
export type InfinitusStatus = typeof InfinitusStatus.Type;

/** One account inside a fleet from the `fleets` / `refresh` reply. `usage` is
    the engine's own usage payload, left opaque at this layer. Everything the
    native `Account` models as optional is optional here too: an engine that
    has no alias, plan, hold or preferred knob or fresh usage omits the key. */
export const InfinitusAccount = Schema.Struct({
  number: Schema.Number,
  alias: Schema.optionalKey(Schema.String),
  email: Schema.String,
  plan: Schema.optionalKey(Schema.String),
  active: Schema.Boolean,
  /** Held: the engine is skipping this account until it is unheld (`hold` /
      `unhold` write it). Absent from engines that have no hold knob. */
  disabled: Schema.optionalKey(Schema.Boolean),
  preferred: Schema.optionalKey(Schema.Boolean),
  isOrganization: Schema.Boolean,
  organizationName: Schema.optionalKey(Schema.String),
  organizationUuid: Schema.optionalKey(Schema.String),
  usage: Schema.optionalKey(Schema.Unknown),
  usageStatus: Schema.String,
  usageAgeSeconds: Schema.optionalKey(Schema.Number),
  usageFetchedAt: Schema.optionalKey(Schema.String),
});
export type InfinitusAccount = typeof InfinitusAccount.Type;

/** The app's headroom verdict for one fleet (#616, session priority mode):
    `low` and `critical` both hold background threads, `abundant` releases
    them. Native computes it with its own hysteresis and forecast; the fork
    never recomputes. `window` names the binding usage window, `pct` its used
    percent, `reason` a line for people. Omitted while the mode is off. */
export const InfinitusHeadroomState = Schema.Literals(["abundant", "low", "critical"]);
export type InfinitusHeadroomState = typeof InfinitusHeadroomState.Type;

export const InfinitusHeadroom = Schema.Struct({
  state: InfinitusHeadroomState,
  window: Schema.optionalKey(Schema.String),
  pct: Schema.optionalKey(Schema.Number),
  reason: Schema.optionalKey(Schema.String),
});
export type InfinitusHeadroom = typeof InfinitusHeadroom.Type;

/** One fleet from the `fleets` / `refresh` reply. `key` is what fleet-targeting
    commands take as `<fleet>`; gate UI on `capabilities`, never on `engineID`.
    `headroom` is forward-compatible: a state a newer app adds decodes as
    absent rather than costing the snapshot. */
export const InfinitusFleet = Schema.Struct({
  key: Schema.String,
  engineID: Schema.String,
  provider: Schema.String,
  capabilities: Schema.Array(Schema.String),
  caveat: Schema.optionalKey(Schema.String),
  activeNumber: Schema.optionalKey(Schema.Number),
  nextCandidate: Schema.optionalKey(Schema.Number),
  candidateOrder: Schema.optionalKey(Schema.Array(Schema.Number)),
  nextRecovery: Schema.optionalKey(Schema.Struct({ number: Schema.Number, at: Schema.String })),
  headroom: ForwardCompatibleOptional(InfinitusHeadroom),
  accounts: Schema.Array(InfinitusAccount),
});
export type InfinitusFleet = typeof InfinitusFleet.Type;

/** The `forecast` command's reply: a run-rate projection, `null` when the app
    has nothing to project. The inner lines stay opaque for v1 — only the
    top-level keys are pinned, and all but `computedAt` and `basis` are absent
    when there is no active account or no measurable pace. Estimates, never
    billing truth. */
export const InfinitusForecast = Schema.Struct({
  forecast: Schema.NullOr(
    Schema.Struct({
      accounts: Schema.optionalKey(Schema.Unknown),
      active: Schema.optionalKey(Schema.Unknown),
      allDeadAt: Schema.optionalKey(Schema.Unknown),
      basis: Schema.Unknown,
      computedAt: Schema.Unknown,
      drainOrder: Schema.optionalKey(Schema.Unknown),
    }),
  ),
});
export type InfinitusForecast = typeof InfinitusForecast.Type;

/** One live Claude Code session from the `sessions` reply. That reply is built
    by hand rather than encoded from a struct, so a session with no name,
    status, permission mode or profile carries an explicit null there. */
export const InfinitusSession = Schema.Struct({
  pid: Schema.Number,
  name: Schema.optionalKey(Schema.NullOr(Schema.String)),
  cwd: Schema.String,
  status: Schema.optionalKey(Schema.NullOr(Schema.String)),
  kind: Schema.String,
  permissionMode: Schema.optionalKey(Schema.NullOr(Schema.String)),
  profile: Schema.optionalKey(Schema.NullOr(Schema.String)),
  /** Claude Code's session id (#612); absent on a build before it. */
  sessionId: Schema.optionalKey(Schema.String),
  /** The alias the session runs on — the fleet's active account stamped on
      every row (one active account per engine), not a per-session fact. */
  account: Schema.optionalKey(Schema.NullOr(Schema.String)),
  /** When the session started, ISO 8601; null from records that predate it. */
  startedAt: Schema.optionalKey(Schema.NullOr(Schema.String)),
  /** Pending sign-in needs: `aws-login:<profile>`, `gcloud-login:<account>`. */
  needs: Schema.optionalKey(Schema.Array(Schema.String)),
});
export type InfinitusSession = typeof InfinitusSession.Type;

/** The value type a preference holds, which is what `default` and `value`
    carry: `bool` a boolean, `int`/`double` a number, `string` a string. */
export const InfinitusPrefKind = Schema.Literals(["bool", "int", "double", "string"]);
export type InfinitusPrefKind = typeof InfinitusPrefKind.Type;

/** When a write takes hold: `live` right away, `restart` on the next launch. */
export const InfinitusPrefEffect = Schema.Literals(["live", "restart"]);
export type InfinitusPrefEffect = typeof InfinitusPrefEffect.Type;

/** One group in the preference catalog; `slug` is what a pref's `section`
    names, `name` is the heading a settings pane shows. */
export const InfinitusPrefSection = Schema.Struct({
  slug: Schema.String,
  name: Schema.String,
});
export type InfinitusPrefSection = typeof InfinitusPrefSection.Type;

/** One row of the `prefs` command's catalog. `default` and `value` are JSON
    scalars whose runtime type is the one `type` names, so they stay unknown
    here; `choices` is the closed set a string pref accepts, absent or null on
    a pref that takes any value. */
export const InfinitusPref = Schema.Struct({
  key: Schema.String,
  type: InfinitusPrefKind,
  default: Schema.Unknown,
  value: Schema.Unknown,
  section: Schema.String,
  effect: InfinitusPrefEffect,
  /** Bare values (`"rpg"`, `30`) or `{id, name}` objects (#747: the theme
      picker's dynamic list, the animation styles); the web writes the id and
      shows the name. */
  choices: Schema.optionalKey(Schema.NullOr(Schema.Array(Schema.Unknown))),
  /** A numeric row's range when the native side bounds it (#747: `intro_speed`
      0.4–2); absent when unbounded. */
  min: Schema.optionalKey(Schema.NullOr(Schema.Number)),
  max: Schema.optionalKey(Schema.NullOr(Schema.Number)),
});
export type InfinitusPref = typeof InfinitusPref.Type;

/** One saved session profile from the `profiles` reply (native
    `Sources/InfinitusCore/SessionProfiles.swift`): a named way to start a
    session. Every field but the name is optional — the reply is a Swift
    `Codable` encode, so a field the profile does not fill is simply absent —
    and `profile-set` clears whatever it omits. */
export const InfinitusProfile = Schema.Struct({
  name: Schema.String,
  cwd: Schema.optionalKey(Schema.NullOr(Schema.String)),
  engine: Schema.optionalKey(Schema.NullOr(Schema.String)),
  permissionMode: Schema.optionalKey(Schema.NullOr(Schema.String)),
  model: Schema.optionalKey(Schema.NullOr(Schema.String)),
  systemPrompt: Schema.optionalKey(Schema.NullOr(Schema.String)),
  prompt: Schema.optionalKey(Schema.NullOr(Schema.String)),
  allowTools: Schema.optionalKey(Schema.NullOr(Schema.Array(Schema.String))),
});
export type InfinitusProfile = typeof InfinitusProfile.Type;

/** The `profiles` command's reply. */
export const InfinitusProfiles = Schema.Struct({
  profiles: Schema.Array(InfinitusProfile),
});
export type InfinitusProfiles = typeof InfinitusProfiles.Type;

/** The `prefs` command's reply: the whole preference catalog with its current
    values. Absent from builds that predate the command. */
export const InfinitusPrefs = Schema.Struct({
  sections: Schema.Array(InfinitusPrefSection),
  prefs: Schema.Array(InfinitusPref),
});
export type InfinitusPrefs = typeof InfinitusPrefs.Type;

/*
 * `aws-logins` (#572 task 7): sessions whose AWS or gcloud sign-in lapsed, each
 * with the flow the phone would start and any login in flight. Structs are open
 * and their enums plain strings, so a flow or phase the app adds later still
 * decodes. Native: `AwsLogin.Item` / `AwsLogin.State`.
 */

/** A login in flight: `flow` is `relay`, `deviceCode`, `remote` or `local`;
    `phase` walks `starting` → `waitingForBrowser` / `waitingForCode` → `done`
    / `failed`; `url` and `userCode` are what a person opens and types on
    another device; `startedAt` is epoch seconds. */
export const InfinitusAwsLoginState = Schema.Struct({
  profile: Schema.String,
  flow: Schema.String,
  phase: Schema.String,
  url: Schema.optionalKey(Schema.NullOr(Schema.String)),
  userCode: Schema.optionalKey(Schema.NullOr(Schema.String)),
  callbackPort: Schema.optionalKey(Schema.NullOr(Schema.Number)),
  message: Schema.optionalKey(Schema.NullOr(Schema.String)),
  startedAt: Schema.Number,
  pid: Schema.optionalKey(Schema.NullOr(Schema.Number)),
  provider: Schema.optionalKey(Schema.NullOr(Schema.String)),
});
export type InfinitusAwsLoginState = typeof InfinitusAwsLoginState.Type;

/** One lapsed sign-in: the profile (an account for gcloud), which CLI
    (`provider` is `gcloud` for gcloud items and absent for AWS), the session
    that hit it, and the login running for it, if any. `account` is the
    engine's account record, opaque here. */
export const InfinitusAwsLogin = Schema.Struct({
  profile: Schema.String,
  provider: Schema.optionalKey(Schema.NullOr(Schema.String)),
  flow: Schema.String,
  pid: Schema.optionalKey(Schema.NullOr(Schema.Number)),
  sessionLabel: Schema.optionalKey(Schema.NullOr(Schema.String)),
  state: Schema.optionalKey(Schema.NullOr(InfinitusAwsLoginState)),
  failedAt: Schema.optionalKey(Schema.NullOr(Schema.String)),
  account: Schema.optionalKey(Schema.Unknown),
});
export type InfinitusAwsLogin = typeof InfinitusAwsLogin.Type;

/** The `aws-logins` reply. */
export const InfinitusAwsLogins = Schema.Struct({
  logins: Schema.Array(InfinitusAwsLogin),
});
export type InfinitusAwsLogins = typeof InfinitusAwsLogins.Type;

/** One row of the `events` reply — the app's event log as the Activity pane
    shows it: `at` ISO 8601, `icon` an SF Symbol name, `text` the line. Since
    native #630 (#615) a row also carries `id`, the app's own UUID for the
    entry (stable per app run), and `kind`, the durable log's vocabulary
    (switch, limit, revival, resume, nudge, team, team-control, hook, pairing,
    other). Both are absent on older builds, where a client falls back to the
    icon and text. */
export const InfinitusEventRow = Schema.Struct({
  id: Schema.optionalKey(Schema.String),
  at: Schema.String,
  kind: Schema.optionalKey(Schema.String),
  icon: Schema.String,
  text: Schema.String,
});
export type InfinitusEventRow = typeof InfinitusEventRow.Type;

/** One event as the snapshot carries it: the row with an id a client can
    dedupe on — the app's own when the row carries one, else one the server
    assigns (`<at>#<sequence>`), stable for as long as that server runs. */
export const InfinitusEvent = Schema.Struct({
  ...InfinitusEventRow.fields,
  id: Schema.String,
});
export type InfinitusEvent = typeof InfinitusEvent.Type;

/** Everything one poll of the socket collects, assembled client-side from the
    `status`, `fleets`, `forecast`, `sessions`, `prefs` and `manifest`
    commands. `available: false` with an `unavailableReason` means the socket
    never answered — no Infinitus running, or a different machine — and then
    every collected field is absent and both lists are empty. */
export const InfinitusSnapshot = Schema.Struct({
  available: Schema.Boolean,
  unavailableReason: Schema.optionalKey(Schema.String),
  status: Schema.optionalKey(InfinitusStatus),
  fleets: Schema.Array(InfinitusFleet),
  forecast: Schema.optionalKey(InfinitusForecast),
  sessions: Schema.Array(InfinitusSession),
  prefs: Schema.optionalKey(InfinitusPrefs),
  awsLogins: Schema.optionalKey(Schema.Array(InfinitusAwsLogin)),
  /** A message, not state: the events new since the previous poll, `[]` when
      none. Absent on a build without the `events` command and on a cycle
      whose reply did not decode. The first poll after the app is sighted only
      seeds the cursor, so history is never replayed. */
  events: Schema.optionalKey(Schema.Array(InfinitusEvent)),
  commands: Schema.Array(InfinitusManifestCommand),
});
export type InfinitusSnapshot = typeof InfinitusSnapshot.Type;

/** What `infinitus.launch` did: `launched` when it asked LaunchServices to
    open the menu-bar app, otherwise the one-line reason it did not — the app
    was already answering, the server is not on macOS, or `open` failed. The
    app coming up is the snapshot flipping to `available`, never this. */
export const InfinitusLaunchResult = Schema.Struct({
  launched: Schema.Boolean,
  reason: Schema.optionalKey(Schema.String),
  /** `false` when LaunchServices knows no app by the menu-bar app's bundle id
      (#731): the button then points at the download instead of "open exited 1". */
  installed: Schema.optionalKey(Schema.Boolean),
});
export type InfinitusLaunchResult = typeof InfinitusLaunchResult.Type;

/** Fork (#616): "Run now" for a thread whose start session priority mode is
    holding. `released` when a held start ran; otherwise the one-line reason
    (nothing was held for that thread). Never an error. */
/** One thread whose turn start the server holds for headroom (#616, #741):
    when the hold began and the held row's line, for the sidebar. */
export const InfinitusHeldThread = Schema.Struct({
  threadId: ThreadId,
  since: Schema.String,
  summary: Schema.String,
  /** `held` (absent on older servers): a start waits for headroom. `limited`
      (#270 I): the thread's turn stopped on its account's usage limit and
      resume-on-limit waits for a swap; the summary names the account. */
  kind: Schema.optionalKey(Schema.Literals(["held", "limited"])),
});
export type InfinitusHeldThread = typeof InfinitusHeldThread.Type;

export const InfinitusReleaseThreadInput = Schema.Struct({ threadId: ThreadId });
export type InfinitusReleaseThreadInput = typeof InfinitusReleaseThreadInput.Type;
export const InfinitusReleaseThreadResult = Schema.Struct({
  released: Schema.Boolean,
  reason: Schema.optionalKey(Schema.String),
});
export type InfinitusReleaseThreadResult = typeof InfinitusReleaseThreadResult.Type;

/** Fork a thread at a turn (#270 E2): a new thread on the same branch and
    worktree whose Claude session continues from that turn; the source is not
    touched. `turnCount` is the checkpoint turn count shown on the message. */
export const InfinitusThreadForkInput = Schema.Struct({
  threadId: ThreadId,
  turnCount: Schema.Int,
  /** Fork (#269 C): a side question — read-only (plan mode), marked `sideOf`
      the source, so it opens in a drawer instead of the thread list. */
  side: Schema.optional(Schema.Literal(true)),
});
export type InfinitusThreadForkInput = typeof InfinitusThreadForkInput.Type;
export const InfinitusThreadForkResult = Schema.Struct({ threadId: ThreadId });
export type InfinitusThreadForkResult = typeof InfinitusThreadForkResult.Type;
/** Why a fork did not happen: not a Claude session, no anchor for that turn,
    nothing to fork. The reason is shown to the user as is. */
export class InfinitusThreadForkRefused extends Schema.TaggedError<InfinitusThreadForkRefused>()(
  "InfinitusThreadForkRefused",
  { reason: Schema.String },
) {}

/** The desktop shell's own Infinitus knobs (one-app feel, #654), kept by the
    shell rather than the server because they describe this window.
    `quitInfinitusWithApp`: quitting the desktop app also sends the menu-bar
    app its `quit` verb. Off by default. */
/** Fork (#677): what the web asks the desktop shell to show for one sign-in
    the app started with `signin-begin` — the provider's page in a child window
    of its own. `label` is the app's own ("Add account", "Sign in again — x"). */
export const InfinitusSignInWindowInput = Schema.Struct({
  flowId: Schema.String,
  url: Schema.String,
  label: Schema.String,
});
export type InfinitusSignInWindowInput = typeof InfinitusSignInWindowInput.Type;

/** The code from the OAuth success page, for `signin-code`. It goes from the
    shell's main process to the control socket's `secret`, never over an RPC. */
export const InfinitusSignInCodeInput = Schema.Struct({
  flowId: Schema.String,
  code: Schema.String,
});
export type InfinitusSignInCodeInput = typeof InfinitusSignInCodeInput.Type;

/** `signin-code`'s answer: accepted, or the CLI's own rejection wording. */
export const InfinitusSignInCodeResult = Schema.Struct({
  ok: Schema.Boolean,
  error: Schema.optionalKey(Schema.String),
});
export type InfinitusSignInCodeResult = typeof InfinitusSignInCodeResult.Type;

export const InfinitusDesktopPrefs = Schema.Struct({
  quitInfinitusWithApp: Schema.Boolean,
  /** #433 slice 2: a double tap of Shift in any app captures its selected text
      into the active project. macOS only; off by default. */
  captureGestureEnabled: Schema.Boolean,
});
export type InfinitusDesktopPrefs = typeof InfinitusDesktopPrefs.Type;

/*
 * Phone-only writes (#572). The native mirror's `POST /activities/token`,
 * `POST /client-activity` and `POST /crashes` bodies, carried unchanged as the
 * `--body` option of the `activities-token`, `client-activity` and
 * `crash-report` control commands so a paired phone reaches them through
 * `infinitus.command`. Every schema mirrors the Swift struct the native decoder
 * reads (LiveActivityPush.swift, LeaseTable.swift, CrashReport.swift); dates are
 * ISO 8601 strings because those decoders use `.iso8601`.
 */

/** Which Live Activity a token drives: a `*-start` token lets the Mac start
    the activity while the app is closed (iOS 17.2 push-to-start), a plain one
    belongs to a running activity, `alert` is an ordinary notification token. */
export const InfinitusActivityPushKind = Schema.Literals([
  "working-start",
  "working",
  "revival-start",
  "revival",
  "alert",
]);
export type InfinitusActivityPushKind = typeof InfinitusActivityPushKind.Type;

/** One token registration: the Mac keeps one slot per device and kind, a new
    token for the same pair replaces it. `environment` is `sandbox` for
    development-signed builds, `production` otherwise (Apple routes them to
    different gateways). `macId` is the key the phone files this Mac under — the
    fork uses the environment id — echoed into a push-to-start's attributes so
    the phone adopts the card into the right Mac's slot. `registeredAt` may be
    left to the Mac, which stamps it. `layout` names the push envelope the
    phone's activity host expects: absent or `native` for the SwiftUI phone,
    `expo` for this app (expo-widgets' `{name, props}` content state). */
export const InfinitusActivityPushRegistration = Schema.Struct({
  kind: InfinitusActivityPushKind,
  token: Schema.String,
  deviceId: Schema.String,
  deviceName: Schema.String,
  environment: Schema.String,
  themeID: Schema.optionalKey(Schema.NullOr(Schema.String)),
  registeredAt: Schema.optionalKey(Schema.String),
  macId: Schema.optionalKey(Schema.NullOr(Schema.String)),
  layout: Schema.optionalKey(Schema.NullOr(Schema.String)),
});
export type InfinitusActivityPushRegistration = typeof InfinitusActivityPushRegistration.Type;

/** What a client is looking at: every session, one session by pid, the fleet,
    or the stats. The Mac only does per-session work while some client holds a
    lease on that scope. */
export const InfinitusClientActivityScope = Schema.Struct({
  type: Schema.Literals(["sessions", "session", "fleets", "stats"]),
  pid: Schema.optionalKey(Schema.NullOr(Schema.Number)),
});
export type InfinitusClientActivityScope = typeof InfinitusClientActivityScope.Type;

/** A lease report: the client's scopes with a TTL in milliseconds (the Mac caps
    it at five minutes; zero releases). Sent on every scope change and while a
    scope is held, so a crashed client never pins work for long. */
export const InfinitusClientActivityReport = Schema.Struct({
  clientId: Schema.String,
  visible: Schema.Boolean,
  focused: Schema.Boolean,
  recentlyInteracted: Schema.Boolean,
  scopes: Schema.Array(InfinitusClientActivityScope),
  ttlMs: Schema.Number,
});
export type InfinitusClientActivityReport = typeof InfinitusClientActivityReport.Type;

/** A crash or hang of the phone app as the Mac stores it: `platform` is `ios`
    or `mac`, `kind` is `crash` or `hang`, `frames` are the faulting thread's
    top frames, `raw` the diagnostic body (the Mac caps it at 512 KiB). */
export const InfinitusCrashReport = Schema.Struct({
  id: Schema.String,
  platform: Schema.String,
  device: Schema.String,
  appVersion: Schema.String,
  osVersion: Schema.String,
  at: Schema.String,
  kind: Schema.String,
  reason: Schema.String,
  frames: Schema.Array(Schema.String),
  raw: Schema.optionalKey(Schema.NullOr(Schema.String)),
});
export type InfinitusCrashReport = typeof InfinitusCrashReport.Type;

/*
 * Live Activity content (LiveActivityState.swift). The Mac pushes these as the
 * APNs `content-state` and the phone renders them; they arrive pre-themed
 * (labels, glyphs, colour names, dense reset labels), the widget only draws.
 * Encoded with Swift's default JSONEncoder, so the one date, `revivesAt`, is a
 * number of seconds since 2001-01-01 UTC, not a string.
 */

/** One usage window, themed: its label ("MP", "× Dragon"), colour name, the
    percentage used (0–100) and the dense reset label ("4h20m·17:49"). */
export const InfinitusActivityWindow = Schema.Struct({
  label: Schema.String,
  color: Schema.String,
  pct: Schema.Number,
  reset: Schema.optionalKey(Schema.NullOr(Schema.String)),
});
export type InfinitusActivityWindow = typeof InfinitusActivityWindow.Type;

/** The working-sessions card: the active account as its themed row, session
    counts, the tokens-per-minute gauge, the next candidate as a hint. `binding`
    indexes the window closest to its limit. `rateIcon`/`rateLabel` are absent
    on older Macs, which keep the bolt and "tok/min". */
export const InfinitusWorkingActivityState = Schema.Struct({
  active: Schema.String,
  icon: Schema.optionalKey(Schema.NullOr(Schema.String)),
  slot: Schema.String,
  plan: Schema.optionalKey(Schema.NullOr(Schema.String)),
  cash: Schema.optionalKey(Schema.NullOr(Schema.String)),
  windows: Schema.Array(InfinitusActivityWindow),
  binding: Schema.optionalKey(Schema.NullOr(Schema.Number)),
  busy: Schema.Number,
  total: Schema.Number,
  waiting: Schema.Number,
  next: Schema.optionalKey(Schema.NullOr(Schema.String)),
  tokensPerMinute: Schema.optionalKey(Schema.NullOr(Schema.Number)),
  tokenFraction: Schema.Number,
  accent: Schema.String,
  plain: Schema.Boolean,
  rateIcon: Schema.optionalKey(Schema.NullOr(Schema.String)),
  rateLabel: Schema.optionalKey(Schema.NullOr(Schema.String)),
});
export type InfinitusWorkingActivityState = typeof InfinitusWorkingActivityState.Type;

/** The all-dead revival countdown: who revives when (`revivesAt`, seconds since
    2001), the live and waiting session counts, the accounts after the reviver
    in recovery order, the theme's words and flash colour; `revived` is the
    final state once the fleet came back. */
export const InfinitusRevivalActivityState = Schema.Struct({
  reviver: Schema.String,
  icon: Schema.optionalKey(Schema.NullOr(Schema.String)),
  revivesAt: Schema.Number,
  sessions: Schema.Number,
  waiting: Schema.Number,
  later: Schema.Array(Schema.String),
  reviveWord: Schema.String,
  deadWord: Schema.String,
  accent: Schema.String,
  revived: Schema.Boolean,
});
export type InfinitusRevivalActivityState = typeof InfinitusRevivalActivityState.Type;

/** What a snapshot subscriber needs beyond the fast set (#587 step 2, #659):
    `stats` puts the `stats` scope in the server's lease while at least one
    subscriber asks for it, which moves the Mac's transcript rescan from every
    30 min to every 5 — the one heavy job over there (#625), so it runs only
    while a Stats page is actually mounted. */
export const InfinitusNeed = Schema.Literals(["stats"]);
export type InfinitusNeed = typeof InfinitusNeed.Type;

export const InfinitusSubscribeInput = Schema.Struct({
  needs: Schema.optional(Schema.Array(InfinitusNeed)),
});
export type InfinitusSubscribeInput = typeof InfinitusSubscribeInput.Type;

/** One command call a client asks the server to forward. The same triple the
    control request carries, minus `secret`: material read from stdin never
    crosses the RPC boundary. */
export const InfinitusCommandInput = Schema.Struct({
  command: Schema.String,
  args: Schema.Array(Schema.String),
  options: Schema.Record(Schema.String, Schema.String),
});
export type InfinitusCommandInput = typeof InfinitusCommandInput.Type;

/** What a forwarded command answered with: the reply's own `result`, opaque
    at this layer. Absent for the commands that answer with no payload. */
export const InfinitusCommandResult = Schema.Struct({
  result: Schema.optionalKey(Schema.Unknown),
});
export type InfinitusCommandResult = typeof InfinitusCommandResult.Type;

/** One argument of a secret-carrying call (#747): an identifier, never the
    material itself — a flow id, a profile, a base URL, a name. Short, no
    control characters, no surrounding whitespace. */
export const InfinitusSecretArg = TrimmedNonEmptyString.check(
  Schema.isMaxLength(128),
  Schema.isPattern(/^\P{Cc}*$/u),
);

/** The fork's one secret-carrying path (#747): `secret` rides the request
    line's `secret` field to `command`, and only to a verb whose manifest entry
    says `stdin: "secret"`. `args` is keyed by the manifest's argument and
    option names for that verb (a positional by its name, an option by its
    bare name); the server orders them. The value decodes into a `Redacted`
    the moment it arrives, so nothing that prints the input can show it. */
export const InfinitusSecretInput = Schema.Struct({
  command: Schema.String,
  args: Schema.Record(Schema.String, InfinitusSecretArg),
  secret: Schema.RedactedFromValue(Schema.String),
});
export type InfinitusSecretInput = typeof InfinitusSecretInput.Type;

/** The verb's reply, opaque like `InfinitusCommandResult`: that it never
    echoes the secret is the verb's own contract. */
export const InfinitusSecretResult = Schema.Struct({
  result: Schema.optionalKey(Schema.Unknown),
});
export type InfinitusSecretResult = typeof InfinitusSecretResult.Type;

/** Why a secret call never reached the socket: the manifest has not been
    read, the verb takes no secret, an argument the verb does not name (or one
    it needs is missing), or this session asked too often. */
export const InfinitusSecretRefusal = Schema.Literals([
  "no_manifest",
  "no_secret",
  "bad_args",
  "too_many_attempts",
]);
export class InfinitusSecretRefused extends Schema.TaggedError<InfinitusSecretRefused>()(
  "InfinitusSecretRefused",
  {
    command: Schema.String,
    reason: InfinitusSecretRefusal,
    detail: Schema.String,
  },
) {}

/** The control socket could not be reached at `path`. */
export class InfinitusUnavailable extends Schema.TaggedError<InfinitusUnavailable>()(
  "InfinitusUnavailable",
  {
    path: Schema.String,
    cause: Schema.String,
  },
) {}

/** The socket answered, but not with a decodable reply line. */
export class InfinitusProtocolError extends Schema.TaggedError<InfinitusProtocolError>()(
  "InfinitusProtocolError",
  {
    detail: Schema.String,
  },
) {}

/** A well-formed reply that reported `ok: false`. `restarting` says the app is
    relaunching, so the caller should wait for the socket rather than retry. */
export class InfinitusCommandFailed extends Schema.TaggedError<InfinitusCommandFailed>()(
  "InfinitusCommandFailed",
  {
    command: Schema.String,
    error: Schema.String,
    restarting: Schema.Boolean,
  },
) {}
