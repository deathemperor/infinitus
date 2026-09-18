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
    engines that hold a key (cliproxy, 9router); `binaryPath` and `daemon`
    (stopped | running | backingOff | refused | schemaMismatch, kept a string
    so a word a newer build adds costs nothing) only for swapd; `error` is the
    engine's own last error, verbatim (#1235). */
export const InfinitusEngineState = Schema.Struct({
  enabled: Schema.Boolean,
  registered: Schema.Boolean,
  keyPresent: Schema.optionalKey(Schema.Boolean),
  binaryPath: Schema.optionalKey(Schema.String),
  daemon: Schema.optionalKey(Schema.String),
  error: Schema.optionalKey(Schema.NullOr(Schema.String)),
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
  /** Kept warm: the engine's daemon ignites the account whenever its 5h
      window has gone cold (`auto-ignite` writes it). Absent from engines
      without the knob and from a swapd older than 0.3. */
  autoIgnite: Schema.optionalKey(Schema.Boolean),
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

/** One recorded usage window of a sample: percent used, and the reset instant
    (epoch seconds) when the API sent one. */
export const InfinitusUtilizationWindow = Schema.Struct({
  pct: Schema.Finite,
  resetsAt: Schema.optionalKey(Schema.NullOr(Schema.Finite)),
});
export type InfinitusUtilizationWindow = typeof InfinitusUtilizationWindow.Type;

/** One point of the recorded usage history (native's `UsageSample`): the
    engine's fetch instant, the account, and its windows at that moment —
    `scoped` is the per-model weekly windows by display name. */
export const InfinitusUtilizationSample = Schema.Struct({
  t: Schema.Finite,
  email: Schema.String,
  number: Schema.Finite,
  active: Schema.optionalKey(Schema.NullOr(Schema.Boolean)),
  fiveHour: Schema.optionalKey(Schema.NullOr(InfinitusUtilizationWindow)),
  sevenDay: Schema.optionalKey(Schema.NullOr(InfinitusUtilizationWindow)),
  scoped: Schema.optionalKey(
    Schema.NullOr(Schema.Record(Schema.String, InfinitusUtilizationWindow)),
  ),
});
export type InfinitusUtilizationSample = typeof InfinitusUtilizationSample.Type;

/** One closed weekly window generation (native's `WindowGeneration`): what the
    account had used when its 7d — or per-model — window rolled over, and how
    long before the reset that was last observed. The headroom that expired
    with it is `100 - finalPct`. */
export const InfinitusUtilizationGeneration = Schema.Struct({
  email: Schema.String,
  window: Schema.String,
  resetAt: Schema.Finite,
  finalPct: Schema.Finite,
  observationGap: Schema.optionalKey(Schema.Finite),
});
export type InfinitusUtilizationGeneration = typeof InfinitusUtilizationGeneration.Type;

/** One reconstructed 5h window (native's `FiveHourWindow`): a window starts on
    the first request after the previous one expired, so `start` is derived
    (`resetsAt - 18000`) and `peakPct` — not a final percentage — is what was
    used, since a window's headroom idles rather than leaking. */
export const InfinitusUtilizationFiveHourWindow = Schema.Struct({
  email: Schema.String,
  number: Schema.optionalKey(Schema.NullOr(Schema.Finite)),
  start: Schema.Finite,
  resetsAt: Schema.Finite,
  peakPct: Schema.Finite,
  samples: Schema.Finite,
  closed: Schema.Boolean,
});
export type InfinitusUtilizationFiveHourWindow = typeof InfinitusUtilizationFiveHourWindow.Type;

/** What the fleet actually did over the range (native's
    `WindowPlanner.ReplayReport`), read back off the recorded samples.
    `sawActiveFlag` is false for history written before the flag, where no
    switch can be seen at all. */
export const InfinitusUtilizationReplay = Schema.Struct({
  from: Schema.Finite,
  to: Schema.Finite,
  switches: Schema.Finite,
  coldSwitches: Schema.Finite,
  stalledSeconds: Schema.Finite,
  sawActiveFlag: Schema.optionalKey(Schema.Boolean),
});
export type InfinitusUtilizationReplay = typeof InfinitusUtilizationReplay.Type;

/** Token totals of one run-rate period (native's `TokenRates.Totals`). */
export const InfinitusUtilizationTotals = Schema.Struct({
  input: Schema.optionalKey(Schema.Finite),
  output: Schema.optionalKey(Schema.Finite),
  cacheRead: Schema.optionalKey(Schema.Finite),
  cacheWrite: Schema.optionalKey(Schema.Finite),
  usd: Schema.optionalKey(Schema.Finite),
  messages: Schema.optionalKey(Schema.Finite),
});
export type InfinitusUtilizationTotals = typeof InfinitusUtilizationTotals.Type;

/** The `utilization --days n` reply (#747): the recorded usage samples of the
    range, downsampled to `bucketSeconds`, the window names and accounts they
    carry, the window telemetry the Mac reconstructs (the weekly waste
    generations and the five-hour windows, both off the FULL history since a
    reset may predate the range; the replay of what the fleet did over the
    range), the transcript run rate (`rates`, absent until the Mac has scanned)
    and the popup's live output rate. The rows are each decoded on their own
    (`Schema.Unknown` arrays folded by `infinitusUtilization.ts`), so a build
    that words one of them differently loses that row, not the page. The
    planner's dry run travels opaque: it proposes steps only the Mac can take,
    and its action enum carries a Swift-shaped payload.
    Estimates read off the Mac, never billing truth. */
export const InfinitusUtilization = Schema.Struct({
  days: Schema.Finite,
  bucketSeconds: Schema.optionalKey(Schema.Finite),
  samples: Schema.Array(InfinitusUtilizationSample),
  windows: Schema.optionalKey(Schema.Array(Schema.String)),
  emails: Schema.optionalKey(Schema.Array(Schema.String)),
  generations: Schema.optionalKey(Schema.NullOr(Schema.Array(Schema.Unknown))),
  fiveHourWindows: Schema.optionalKey(Schema.NullOr(Schema.Array(Schema.Unknown))),
  replay: Schema.optionalKey(Schema.Unknown),
  dryRunPlan: Schema.optionalKey(Schema.Unknown),
  rates: Schema.optionalKey(
    Schema.NullOr(
      Schema.Struct({
        computedAt: Schema.Finite,
        lastHour: InfinitusUtilizationTotals,
        lastDay: InfinitusUtilizationTotals,
        lastWeek: InfinitusUtilizationTotals,
        files: Schema.optionalKey(Schema.Finite),
        unpricedModels: Schema.optionalKey(Schema.Array(Schema.String)),
      }),
    ),
  ),
  liveRate: Schema.optionalKey(
    Schema.NullOr(
      Schema.Struct({
        perMinute: Schema.Finite,
        peakPerMinute: Schema.optionalKey(Schema.Finite),
      }),
    ),
  ),
});
export type InfinitusUtilization = typeof InfinitusUtilization.Type;

/**
 * Fork (#1127): this server's own live output rate, folded from the turns it
 * recorded (`projection_turn_usage`) rather than read off the Mac. It replaces
 * `InfinitusUtilization.liveRate`, which the Mac tails out of terminal
 * transcripts — a source the session sweep (#1041) retires, after which that
 * field is always null.
 *
 * `turns` counts only the completed turns in the window whose provider
 * reported usage: a `usageUnavailable` row carries zero tokens for "not
 * reported", and counting it would read as a turn that burned nothing. Zero
 * turns means nothing ran and the page draws no line. Estimates, like every
 * usage figure here — never billing truth.
 */
export const InfinitusLiveTokenRate = Schema.Struct({
  windowMinutes: Schema.Finite,
  turns: Schema.Finite,
  outputPerMinute: Schema.Finite,
  /** Input included, and input already counts cache reads and writes. */
  totalPerMinute: Schema.Finite,
});
export type InfinitusLiveTokenRate = typeof InfinitusLiveTokenRate.Type;

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

/** The `prefs` command's reply: the whole preference catalog with its current
    values. Absent from builds that predate the command. */
export const InfinitusPrefs = Schema.Struct({
  sections: Schema.Array(InfinitusPrefSection),
  prefs: Schema.Array(InfinitusPref),
});
export type InfinitusPrefs = typeof InfinitusPrefs.Type;

/*
 * `aws-logins` (#572 task 7): the AWS profiles and gcloud accounts whose
 * sign-in lapsed, each with the flow the phone would start and any login in
 * flight. Structs are open
 * and their enums plain strings, so a flow or phase the app adds later still
 * decodes. Native: `AwsLogin.Item` / `AwsLogin.State`.
 */

/** A login in flight: `flow` is `relay`, `deviceCode`, `remote` or `local`;
    `phase` walks `starting` → `waitingForBrowser` / `waitingForCode` → `done`
    / `failed`; `url` and `userCode` are what a person opens and types on
    another device; `startedAt` is epoch seconds. Its `pid` was the session
    that needed the login, never the login process's own
    (`AwsLogin.State`: "The session that needed it, if the login was started
    for one."), and left with the item's `pid` / `sessionLabel` (#1041). */
export const InfinitusAwsLoginState = Schema.Struct({
  profile: Schema.String,
  flow: Schema.String,
  phase: Schema.String,
  url: Schema.optionalKey(Schema.NullOr(Schema.String)),
  userCode: Schema.optionalKey(Schema.NullOr(Schema.String)),
  callbackPort: Schema.optionalKey(Schema.NullOr(Schema.Number)),
  message: Schema.optionalKey(Schema.NullOr(Schema.String)),
  startedAt: Schema.Number,
  provider: Schema.optionalKey(Schema.NullOr(Schema.String)),
});
export type InfinitusAwsLoginState = typeof InfinitusAwsLoginState.Type;

/** What the AWS sign-in page asks for and nobody remembers across accounts
    (`AwsLogin.Account`): the account id and, for an IAM user, the user name,
    both read off the profile's own `~/.aws/config`. Never a secret. */
export const InfinitusAwsLoginAccount = Schema.Struct({
  accountId: Schema.String,
  userName: Schema.optionalKey(Schema.NullOr(Schema.String)),
});
export type InfinitusAwsLoginAccount = typeof InfinitusAwsLoginAccount.Type;

/** One lapsed sign-in: the profile (an account for gcloud), which CLI
    (`provider` is `gcloud` for gcloud items and absent for AWS), and the login
    running for it, if any. `account` is the page's account id and user name
    when the config names them. The session that hit it — `pid` and
    `sessionLabel` — left with the Mac's session tracker (#1041); the struct is
    open, so an older app still sending them decodes unchanged. */
export const InfinitusAwsLogin = Schema.Struct({
  profile: Schema.String,
  provider: Schema.optionalKey(Schema.NullOr(Schema.String)),
  flow: Schema.String,
  state: Schema.optionalKey(Schema.NullOr(InfinitusAwsLoginState)),
  failedAt: Schema.optionalKey(Schema.NullOr(Schema.String)),
  account: Schema.optionalKey(Schema.NullOr(InfinitusAwsLoginAccount)),
});
export type InfinitusAwsLogin = typeof InfinitusAwsLogin.Type;

/** The `aws-logins` reply. */
export const InfinitusAwsLogins = Schema.Struct({
  logins: Schema.Array(InfinitusAwsLogin),
});
export type InfinitusAwsLogins = typeof InfinitusAwsLogins.Type;

/** One member of the team as `team-status` lists it (#1313): the roster
    row plus what the member last published — absent for one that has not
    published yet. `fleet` is left opaque (the Mac's `fleet.json`). */
export const InfinitusTeamMember = Schema.Struct({
  kid: Schema.String,
  name: Schema.String,
  role: Schema.String,
  isMe: Schema.Boolean,
  founder: Schema.optionalKey(Schema.Boolean),
  since: Schema.optionalKey(Schema.NullOr(Schema.Number)),
  lastPublished: Schema.optionalKey(Schema.NullOr(Schema.Number)),
  kinds: Schema.optionalKey(Schema.Array(Schema.String)),
  threadsNow: Schema.optionalKey(Schema.Number),
  blockers: Schema.optionalKey(Schema.Array(Schema.String)),
  crashes: Schema.optionalKey(Schema.Number),
  todayUSD: Schema.optionalKey(Schema.Number),
  todayMessages: Schema.optionalKey(Schema.Number),
  todayCommits: Schema.optionalKey(Schema.Number),
  fleet: Schema.optionalKey(Schema.Unknown),
  /** What this member lets ME do to their threads (spec §8), sorted; absent when nothing. */
  controls: Schema.optionalKey(Schema.NullOr(Schema.Array(Schema.String))),
});
export type InfinitusTeamMember = typeof InfinitusTeamMember.Type;

/** An audience as the Mac words it: `leaders`, `team`, or the kids named. */
export const InfinitusTeamAudience = Schema.Union([Schema.String, Schema.Array(Schema.String)]);
export type InfinitusTeamAudience = typeof InfinitusTeamAudience.Type;

/** One of this Mac's grants (spec §8): who may do what to which threads
    (`"all"` or the ids). `preauthorized` runs without the Mac's tap. */
export const InfinitusTeamGrant = Schema.Struct({
  id: Schema.String,
  audience: InfinitusTeamAudience,
  threads: Schema.Union([Schema.Literal("all"), Schema.Array(Schema.String)]),
  capabilities: Schema.Array(Schema.String),
  since: Schema.Number,
  preauthorized: Schema.optionalKey(Schema.Array(Schema.String)),
  expires: Schema.optionalKey(Schema.NullOr(Schema.Number)),
});
export type InfinitusTeamGrant = typeof InfinitusTeamGrant.Type;

/** A driver's command waiting for this Mac's tap (`team-allow` / `team-deny`). */
export const InfinitusTeamPending = Schema.Struct({
  id: Schema.String,
  kid: Schema.String,
  name: Schema.String,
  thread: Schema.String,
  action: Schema.String,
  text: Schema.optionalKey(Schema.NullOr(Schema.String)),
  project: Schema.optionalKey(Schema.NullOr(Schema.String)),
  expires: Schema.Number,
});
export type InfinitusTeamPending = typeof InfinitusTeamPending.Type;

/** A pending join request (leaders see them). */
export const InfinitusTeamRequest = Schema.Struct({
  kid: Schema.String,
  name: Schema.String,
  platform: Schema.optionalKey(Schema.String),
  devices: Schema.optionalKey(Schema.Array(Schema.String)),
  at: Schema.optionalKey(Schema.Number),
});
export type InfinitusTeamRequest = typeof InfinitusTeamRequest.Type;

/** The `team-status` reply: the team this Mac is in, or `null` when there is
    none. `remote` is masked by the Mac. `shares` maps a kind (stats, now,
    threads, transcripts, crashes, fleet) to its audience (off, leaders, team);
    `exclusions` are project slugs kept private. */
export const InfinitusTeamSnapshot = Schema.Struct({
  id: Schema.String,
  name: Schema.String,
  remote: Schema.String,
  kid: Schema.String,
  role: Schema.String,
  rev: Schema.optionalKey(Schema.NullOr(Schema.Number)),
  members: Schema.Array(InfinitusTeamMember),
  requests: Schema.optionalKey(Schema.Array(InfinitusTeamRequest)),
  policy: Schema.optionalKey(Schema.NullOr(Schema.Struct({ requests: Schema.String }))),
  shares: Schema.optionalKey(Schema.Record(Schema.String, Schema.String)),
  exclusions: Schema.optionalKey(Schema.Array(Schema.String)),
  lastFetch: Schema.optionalKey(Schema.NullOr(Schema.Number)),
  lastPublish: Schema.optionalKey(Schema.NullOr(Schema.Number)),
  lastError: Schema.optionalKey(Schema.NullOr(Schema.String)),
  /** Delegated control (spec §8): this Mac's grants and the commands waiting
      for its tap. Absent on a build without them. */
  grants: Schema.optionalKey(Schema.NullOr(Schema.Array(InfinitusTeamGrant))),
  pending: Schema.optionalKey(Schema.NullOr(Schema.Array(InfinitusTeamPending))),
});
export type InfinitusTeamSnapshot = typeof InfinitusTeamSnapshot.Type;

/** The `team-code` reply: the code or invite link (shown once, never logged)
    and when it expires (unix seconds). */
export const InfinitusTeamCode = Schema.Struct({
  code: Schema.String,
  expires: Schema.optionalKey(Schema.Number),
});
export type InfinitusTeamCode = typeof InfinitusTeamCode.Type;

/** The `team-insights` reply (leaders): blockers, headroom, who is on. Spend
    figures are estimates. */
export const InfinitusTeamInsights = Schema.Struct({
  period: Schema.String,
  blockers: Schema.Array(
    Schema.Struct({
      kid: Schema.String,
      name: Schema.String,
      kind: Schema.String,
      text: Schema.String,
    }),
  ),
  headroom: Schema.Array(
    Schema.Struct({
      kid: Schema.String,
      name: Schema.String,
      engine: Schema.String,
      active: Schema.optionalKey(Schema.NullOr(Schema.String)),
      headroom: Schema.optionalKey(Schema.NullOr(Schema.Number)),
      spare: Schema.optionalKey(Schema.Number),
      dead: Schema.optionalKey(Schema.Number),
    }),
  ),
  onNow: Schema.Array(Schema.String),
  cost: Schema.optionalKey(Schema.Unknown),
  repos: Schema.optionalKey(Schema.Unknown),
  hours: Schema.optionalKey(Schema.Array(Schema.Number)),
});
export type InfinitusTeamInsights = typeof InfinitusTeamInsights.Type;

/** One row of the `events` reply — the app's event log as the Activity pane
    shows it: `at` ISO 8601, `icon` an SF Symbol name, `text` the line. Since
    native #630 (#615) a row also carries `id`, the app's own UUID for the
    entry (stable per app run), and `kind`, the durable log's vocabulary
    (switch, limit, revival, resume, nudge, team, team-control, hook, pairing,
    alert, notice, other). Both are absent on older builds, where a client
    falls back to the icon and text. `alert` and `notice` are the app's own
    announcements: it logs the line instead of banner-ing it whenever a client
    holds a `fleets` lease, so the row IS the notification. */
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
    `status`, `fleets`, `forecast`, `prefs` and `manifest` commands. `available: false` with an `unavailableReason` means the socket
    never answered — no Infinitus running, or a different machine — and then
    every collected field is absent and both lists are empty. */
export const InfinitusSnapshot = Schema.Struct({
  available: Schema.Boolean,
  unavailableReason: Schema.optionalKey(Schema.String),
  status: Schema.optionalKey(InfinitusStatus),
  fleets: Schema.Array(InfinitusFleet),
  forecast: Schema.optionalKey(InfinitusForecast),
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
  /** `limited` only: when the window that rejected the turn resets (ISO),
      as the SDK reported it; absent when the stop named none. */
  resetsAt: Schema.optionalKey(Schema.String),
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
  /** A checkpoint's turn number; absent, the session's latest completed
      turn (#269 C) — a checkpoint needs a git repository, an anchor only a
      completed turn. */
  turnCount: Schema.optional(Schema.Int),
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
) {
  // The clients show `error.message`; without this the alert has a title and
  // an empty body (#941 walk: "Could not open a side question", nothing under it).
  override get message(): string {
    return this.reason;
  }
}

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

/** Fork (#1213): a sign-in the desktop shell runs itself, through the engine's
    own `add-oauth` verb — swapd is the OAuth client, so its loopback listener
    catches the redirect and there is no code to paste. `provider` is the
    engine's own provider name (`swapd --provider <p>`); the page opens in the
    system browser. No slot and no relogin target: `add-oauth` resolves the
    account from the sign-in itself and lands a known address back in its own
    slot, so signing in again just works. */
export const InfinitusOAuthSignInInput = Schema.Struct({
  flowId: Schema.String,
  provider: Schema.String,
});
export type InfinitusOAuthSignInInput = typeof InfinitusOAuthSignInInput.Type;

/** What `add-oauth` stored, or why it did not. `error` is the engine's own
    message; the shell never invents one. */
export const InfinitusOAuthSignInResult = Schema.Struct({
  ok: Schema.Boolean,
  slot: Schema.optionalKey(Schema.Number),
  email: Schema.optionalKey(Schema.String),
  error: Schema.optionalKey(Schema.String),
});
export type InfinitusOAuthSignInResult = typeof InfinitusOAuthSignInResult.Type;

/**
 * Fork: the proxy engines the desktop shell can run for you. The keys are the
 * Engines page's own (`ProxyEngineKey` in the web's `engines.logic.ts`); the
 * shell knows nothing of the engines beyond how to start them.
 */
export const InfinitusEngineKey = Schema.Literals(["cliproxy", "9router"]);
export type InfinitusEngineKey = typeof InfinitusEngineKey.Type;

/**
 * How an engine is run on this machine, which the shell detects rather than
 * assumes:
 *
 * - `child` — the shell owns the process: it starts it, restarts it when it
 *   exits unexpectedly, and takes it down with the app.
 * - `service` — something else already owns it (CLIProxyAPI under Homebrew's
 *   launchd job). The shell says so and stays out of the way; a second
 *   supervisor on top of launchd would only fight it.
 * - `unknown` — no command was detected and none was typed, so there is
 *   nothing to run.
 */
export const InfinitusEngineMode = Schema.Literals(["child", "service", "unknown"]);
export type InfinitusEngineMode = typeof InfinitusEngineMode.Type;

/** What a `child` engine's process is doing. A `service` engine is always
    `stopped` here: its state belongs to whoever supervises it. */
export const InfinitusEngineRunState = Schema.Literals([
  "running",
  "starting",
  "stopped",
  "backing-off",
  "failed",
]);
export type InfinitusEngineRunState = typeof InfinitusEngineRunState.Type;

export const InfinitusEngineSupervision = Schema.Struct({
  key: InfinitusEngineKey,
  mode: InfinitusEngineMode,
  /** Whether the shell should keep this engine running. Off by default: no
      process starts until it is asked for. */
  managed: Schema.Boolean,
  /** The command in force — what was typed, else what was detected. Null when
      neither found anything to run. */
  command: Schema.NullOr(Schema.String),
  /** What detection found, so the field can show what it would fall back to
      and a typed command can be told apart from a found one. */
  detectedCommand: Schema.NullOr(Schema.String),
  state: InfinitusEngineRunState,
  pid: Schema.NullOr(Schema.Number),
  /** The last failure's own words — a spawn error, or the exit status. */
  error: Schema.NullOr(Schema.String),
});
export type InfinitusEngineSupervision = typeof InfinitusEngineSupervision.Type;

/** Every engine's supervision, the shape the Engines page renders. */
export const InfinitusEngines = Schema.Struct({
  engines: Schema.Array(InfinitusEngineSupervision),
});
export type InfinitusEngines = typeof InfinitusEngines.Type;

/** A change to one engine's settings. An absent field is left alone; a
    `command` of `""` clears the override and falls back to detection. */
export const InfinitusEngineSettingsInput = Schema.Struct({
  key: InfinitusEngineKey,
  managed: Schema.optionalKey(Schema.Boolean),
  command: Schema.optionalKey(Schema.String),
});
export type InfinitusEngineSettingsInput = typeof InfinitusEngineSettingsInput.Type;

export const InfinitusEngineAction = Schema.Literals(["start", "stop", "restart"]);
export type InfinitusEngineAction = typeof InfinitusEngineAction.Type;

/** A button press on the Engines page. `start` on an unmanaged engine runs it
    once without turning management on. */
export const InfinitusEngineControlInput = Schema.Struct({
  key: InfinitusEngineKey,
  action: InfinitusEngineAction,
});
export type InfinitusEngineControlInput = typeof InfinitusEngineControlInput.Type;

/** What the shell remembers about one engine. An array rather than a record so
    an entry for an engine a later build drops still decodes. */
export const InfinitusEngineSettings = Schema.Struct({
  key: InfinitusEngineKey,
  managed: Schema.Boolean,
  /** The typed command, or null to follow detection. */
  command: Schema.NullOr(Schema.String),
});
export type InfinitusEngineSettings = typeof InfinitusEngineSettings.Type;

export const InfinitusDesktopPrefs = Schema.Struct({
  quitInfinitusWithApp: Schema.Boolean,
  /** #433 slice 2: a double tap of Shift in any app captures its selected text
      into the active project. macOS only; off by default. */
  captureGestureEnabled: Schema.Boolean,
  /** Engines the shell runs. Absent for every engine never configured, which
      is the default: nothing is started until it is asked for. */
  engines: Schema.Array(InfinitusEngineSettings),
});
export type InfinitusDesktopPrefs = typeof InfinitusDesktopPrefs.Type;

/*
 * Phone-only writes (#572). The native mirror's `POST /client-activity` and
 * `POST /crashes` bodies, carried unchanged as the `--body` option of the
 * `client-activity` and `crash-report` control commands so a paired phone
 * reaches them through `infinitus.command`. Every schema mirrors the Swift
 * struct the native decoder reads (LeaseTable.swift, CrashReport.swift);
 * dates are ISO 8601 strings because those decoders use `.iso8601`. The
 * `activities-token` registration left with #1375: the phone's alerts and
 * thread card ride Infinitus Connect.
 */

/** What a client is looking at: the fleet, or the stats. The Mac only does
    that work while some client holds a lease on the scope. The two session
    scopes and the `pid` that named one left with the Mac's session tracker
    (#1041); the fork's server never sent either. */
export const InfinitusClientActivityScope = Schema.Struct({
  type: Schema.Literals(["fleets", "stats"]),
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
    it needs is missing), this session asked too often, or the session's scopes
    do not reach the verb (`scope`: a standard client — a phone, a `t3 pair`
    browser — may feed a sign-in code or callback, or a team invite code;
    every other secret verb needs `access:write`). */
export const InfinitusSecretRefusal = Schema.Literals([
  "no_manifest",
  "no_secret",
  "bad_args",
  "too_many_attempts",
  "scope",
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
