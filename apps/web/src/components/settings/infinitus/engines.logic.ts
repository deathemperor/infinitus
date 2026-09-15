import type {
  InfinitusCommandInput,
  InfinitusManifestCommand,
  InfinitusSecretInput,
} from "@t3tools/contracts/infinitus";
import * as Option from "effect/Option";
import * as Schema from "effect/Schema";

/**
 * Settings › Infinitus › Engines (#1177): the two proxy engines' base URL and
 * secret, read over `infinitus.command` (`proxy` / `9router`) and written over
 * `infinitus.secret` (`proxy-key` / `9router-password`, whose only argument
 * besides the stdin secret is `--url`). Pure so the pane only renders; the
 * secret itself never enters this module — the pane hands it to the atom as a
 * `Redacted` value and this module only names the verb and its url.
 */

export type ProxyEngineKey = "cliproxy" | "9router";

export interface ProxyEngine {
  readonly key: ProxyEngineKey;
  readonly label: string;
  /** The read verb: `{baseURL, keyPresent|passwordPresent, error?}`. */
  readonly readVerb: "proxy" | "9router";
  /** The `stdin: "secret"` write verb; an empty secret clears it. Restarts the app. */
  readonly secretVerb: "proxy-key" | "9router-password";
  readonly secretLabel: string;
  /** The word the status sentence uses: "Key set." / "Password not set.". */
  readonly secretNoun: "Key" | "Password";
  /** What the Mac uses when no url is stored (the verb's own default). */
  readonly defaultUrl: string;
  /** The line under the Dashboard row, drawn when the read answered a URL. */
  readonly dashboardNote: string;
}

export const PROXY_ENGINES: ReadonlyArray<ProxyEngine> = [
  {
    key: "cliproxy",
    label: "CLIProxyAPI",
    readVerb: "proxy",
    secretVerb: "proxy-key",
    secretLabel: "Management key",
    secretNoun: "Key",
    defaultUrl: "http://127.0.0.1:8317",
    dashboardNote: "The proxy's own management panel: credentials, config and logs.",
  },
  {
    key: "9router",
    label: "9Router",
    readVerb: "9router",
    secretVerb: "9router-password",
    secretLabel: "Dashboard password",
    secretNoun: "Password",
    defaultUrl: "http://127.0.0.1:20128",
    dashboardNote: "Providers → Connect Claude Code adds an account there.",
  },
];

/**
 * A build whose manifest lists both read verbs and marks both write verbs as
 * taking their secret on stdin (native #766): the server refuses
 * `infinitus.secret` for a verb without that marker, so the name alone is not
 * enough.
 */
export function engineSecretsSupported(commands: ReadonlyArray<InfinitusManifestCommand>): boolean {
  const byName = new Map(commands.map((command) => [command.name, command]));
  return PROXY_ENGINES.every(
    (engine) => byName.has(engine.readVerb) && byName.get(engine.secretVerb)?.stdin === "secret",
  );
}

/** The `proxy` and `9router` replies share a shape but name the secret differently. */
const ProxyEngineReply = Schema.Struct({
  baseURL: Schema.String,
  keyPresent: Schema.optionalKey(Schema.Boolean),
  passwordPresent: Schema.optionalKey(Schema.Boolean),
  error: Schema.optionalKey(Schema.NullOr(Schema.String)),
  // The proxy's routing (#1235): absent on a build before the fields, and
  // `sessionAffinity` absent on a proxy without the management route.
  routingStrategy: Schema.optionalKey(Schema.NullOr(Schema.String)),
  sessionAffinity: Schema.optionalKey(Schema.NullOr(Schema.Boolean)),
  caveat: Schema.optionalKey(Schema.NullOr(Schema.String)),
  dashboardURL: Schema.optionalKey(Schema.String),
});

const decodeReply = Schema.decodeUnknownOption(ProxyEngineReply);

export interface ProxyEngineState {
  readonly baseURL: string;
  readonly secretPresent: boolean;
  /** The engine's own last error, verbatim, or null. */
  readonly error: string | null;
  /** CLIProxyAPI's routing strategy; null until the proxy answered it. */
  readonly routingStrategy: string | null;
  /** CLIProxyAPI's session affinity; null when the proxy has no route for it (YAML only). */
  readonly sessionAffinity: boolean | null;
  /** The Mac's routing caveat for the proxy's credentials, or null. */
  readonly caveat: string | null;
  /** The engine's own web UI, or null on a build that answers none. */
  readonly dashboardURL: string | null;
}

/** One engine's read reply, null when the shape is not the one above. */
export function parseProxyEngineState(result: unknown): ProxyEngineState | null {
  const reply = Option.getOrNull(decodeReply(result));
  if (reply === null) return null;
  const present = reply.keyPresent ?? reply.passwordPresent;
  if (present === undefined) return null;
  return {
    baseURL: reply.baseURL,
    secretPresent: present,
    error: reply.error ?? null,
    routingStrategy: reply.routingStrategy ?? null,
    sessionAffinity: reply.sessionAffinity ?? null,
    caveat: reply.caveat ?? null,
    dashboardURL: reply.dashboardURL ?? null,
  };
}

/** The proxy's routing knobs (#1235): `proxy-routing <strategy>` and
    `proxy-affinity on|off`, each gated on its own verb — a Mac that has the
    first may predate the second. */
const ROUTING_VERB = "proxy-routing";
const AFFINITY_VERB = "proxy-affinity";

export const ROUTING_STRATEGIES: ReadonlyArray<{ readonly value: string; readonly label: string }> =
  [
    { value: "fill-first", label: "Fill first" },
    { value: "round-robin", label: "Round robin" },
    { value: "weighted-round-robin", label: "Weighted round robin" },
  ];

export function routingSupported(commands: ReadonlyArray<InfinitusManifestCommand>): boolean {
  return commands.some((command) => command.name === ROUTING_VERB);
}

export function affinitySupported(commands: ReadonlyArray<InfinitusManifestCommand>): boolean {
  return commands.some((command) => command.name === AFFINITY_VERB);
}

export function routingInput(strategy: string): InfinitusCommandInput {
  return { command: ROUTING_VERB, args: [strategy], options: {} };
}

export function affinityInput(on: boolean): InfinitusCommandInput {
  return { command: AFFINITY_VERB, args: [on ? "on" : "off"], options: {} };
}

interface RoutingNotes {
  /** What the strategy does, one sentence. */
  readonly explainer: string;
  /** The affinity note under a rotating strategy: a warning while off (naming
      the YAML when the proxy has no route), a reminder while on. */
  readonly note: { readonly tone: "warn" | "muted"; readonly text: string } | null;
}

const AFFINITY_YAML =
  "Turn on session-affinity in the proxy's config (this proxy has no management route for it yet) so a conversation stays on one credential: without it every request lands on a different account and the prompt cache misses. Under affinity, Switch only steers new sessions.";
const AFFINITY_OFF =
  "Turn on session affinity so a conversation stays on one credential: without it every request lands on a different account and the prompt cache misses.";
const AFFINITY_ON =
  "Under affinity, Switch only steers new sessions; bound ones keep their credential until the TTL lapses.";

/** The Mac's `RoutingNotes` (EnginesPane.swift), word for word. */
export function routingNotes(strategy: string | null, affinity: boolean | null): RoutingNotes {
  const explainer =
    strategy === "round-robin"
      ? "Each request goes to the next credential in turn."
      : strategy === "weighted-round-robin"
        ? "Requests rotate in proportion to each credential's priority."
        : strategy === null
          ? "Read from the proxy on the next refresh."
          : "Highest priority wins until it is rate-limited — consume-first. Switch on the Accounts page raises a credential to the top.";
  if (strategy === null || strategy === "fill-first") return { explainer, note: null };
  const note =
    affinity === null
      ? { tone: "warn" as const, text: AFFINITY_YAML }
      : affinity
        ? { tone: "muted" as const, text: AFFINITY_ON }
        : { tone: "warn" as const, text: AFFINITY_OFF };
  return { explainer, note };
}

/**
 * The `infinitus.secret` input for one engine, minus the secret: the verb and,
 * when the field holds one, the url under the manifest's bare option name. A
 * blank url is left out so the Mac stores its default.
 */
export function engineSecretInput(
  key: ProxyEngineKey,
  url: string,
): Omit<InfinitusSecretInput, "secret"> {
  const engine = PROXY_ENGINES.find((candidate) => candidate.key === key);
  if (engine === undefined) throw new Error(`unknown proxy engine ${key}`);
  const trimmed = url.trim();
  return { command: engine.secretVerb, args: trimmed === "" ? {} : { url: trimmed } };
}

/** The probe verb (native #1216): `test-connection cliproxy|9router [--url]`,
    read effect, answered within 5 s with the engine's own words on failure. */
const TEST_CONNECTION_VERB = "test-connection";

/** A build whose manifest lists the probe verb; older builds keep the button off. */
export function testConnectionSupported(
  commands: ReadonlyArray<InfinitusManifestCommand>,
): boolean {
  return commands.some((command) => command.name === TEST_CONNECTION_VERB);
}

/**
 * The `infinitus.command` input that probes one engine at the typed url —
 * before it is saved, which is the point — or at the stored one when the
 * field is blank. The credential stays in the Mac's keychain either way.
 */
export function connectionTestInput(key: ProxyEngineKey, url: string): InfinitusCommandInput {
  const trimmed = url.trim();
  return {
    command: TEST_CONNECTION_VERB,
    args: [key],
    options: trimmed === "" ? {} : { url: trimmed },
  };
}

const ConnectionTestReply = Schema.Struct({
  ok: Schema.Boolean,
  latencyMs: Schema.optionalKey(Schema.Number),
  version: Schema.optionalKey(Schema.String),
  error: Schema.optionalKey(Schema.String),
});

const decodeConnectionTest = Schema.decodeUnknownOption(ConnectionTestReply);

export type ConnectionTestResult =
  | { readonly ok: true; readonly latencyMs: number; readonly version: string | null }
  | { readonly ok: false; readonly error: string };

/** The probe's reply, null when the shape is not `{ok, latencyMs?, version?, error?}`. */
export function parseConnectionTest(result: unknown): ConnectionTestResult | null {
  const reply = Option.getOrNull(decodeConnectionTest(result));
  if (reply === null) return null;
  if (reply.ok) {
    return { ok: true, latencyMs: reply.latencyMs ?? 0, version: reply.version ?? null };
  }
  return { ok: false, error: reply.error ?? "The engine did not say why." };
}

/** One line under the button: the round trip, or the engine's sentence verbatim. */
export function connectionTestLine(result: ConnectionTestResult): string {
  if (!result.ok) return result.error;
  return result.version === null
    ? `Reachable in ${result.latencyMs} ms.`
    : `Reachable in ${result.latencyMs} ms, version ${result.version}.`;
}
