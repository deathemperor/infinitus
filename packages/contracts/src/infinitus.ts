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
    has no alias, plan, preferred knob or fresh usage omits the key. */
export const InfinitusAccount = Schema.Struct({
  number: Schema.Number,
  alias: Schema.optionalKey(Schema.String),
  email: Schema.String,
  plan: Schema.optionalKey(Schema.String),
  active: Schema.Boolean,
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

/** Everything one poll of the socket collects, assembled client-side from the
    `status`, `fleets`, `forecast`, `sessions` and `manifest` commands.
    `available: false` with an `unavailableReason` means the socket never
    answered — no Infinitus running, or a different machine. */
export const InfinitusSnapshot = Schema.Struct({
  available: Schema.Boolean,
  unavailableReason: Schema.optionalKey(Schema.String),
  status: Schema.optionalKey(InfinitusStatus),
  fleets: Schema.Array(InfinitusFleet),
  forecast: Schema.optionalKey(InfinitusForecast),
  sessions: Schema.Array(InfinitusSession),
  commands: Schema.Array(InfinitusManifestCommand),
});
export type InfinitusSnapshot = typeof InfinitusSnapshot.Type;

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
