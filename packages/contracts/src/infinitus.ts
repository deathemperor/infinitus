import * as Effect from "effect/Effect";
import * as Schema from "effect/Schema";

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

/** The `status` command's reply: app build, the socket it answers on, the menu
    bar badge, and which engines are on. */
export const InfinitusStatus = Schema.Struct({
  version: Schema.String,
  sha: Schema.String,
  socket: Schema.String,
  badge: Schema.String,
  playground: Schema.Boolean,
  signInRunning: Schema.Boolean,
  engines: Schema.Record(Schema.String, InfinitusEngineState),
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

/** One fleet from the `fleets` / `refresh` reply. `key` is what fleet-targeting
    commands take as `<fleet>`; gate UI on `capabilities`, never on `engineID`. */
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
  choices: Schema.optionalKey(Schema.NullOr(Schema.Array(Schema.Unknown))),
});
export type InfinitusPref = typeof InfinitusPref.Type;

/** The `prefs` command's reply: the whole preference catalog with its current
    values. Absent from builds that predate the command. */
export const InfinitusPrefs = Schema.Struct({
  sections: Schema.Array(InfinitusPrefSection),
  prefs: Schema.Array(InfinitusPref),
});
export type InfinitusPrefs = typeof InfinitusPrefs.Type;

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
  commands: Schema.Array(InfinitusManifestCommand),
});
export type InfinitusSnapshot = typeof InfinitusSnapshot.Type;

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
    the phone adopts the card into the right Mac's slot. */
export const InfinitusActivityPushRegistration = Schema.Struct({
  kind: InfinitusActivityPushKind,
  token: Schema.String,
  deviceId: Schema.String,
  deviceName: Schema.String,
  environment: Schema.String,
  themeID: Schema.optionalKey(Schema.NullOr(Schema.String)),
  registeredAt: Schema.String,
  macId: Schema.optionalKey(Schema.NullOr(Schema.String)),
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
    fraction used and the dense reset label ("4h20m·17:49"). */
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
