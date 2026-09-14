import type { InfinitusManifestCommand, InfinitusSecretInput } from "@t3tools/contracts/infinitus";
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
  },
  {
    key: "9router",
    label: "9Router",
    readVerb: "9router",
    secretVerb: "9router-password",
    secretLabel: "Dashboard password",
    secretNoun: "Password",
    defaultUrl: "http://127.0.0.1:20128",
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

/** The probe the Mac runs from its own network position; not in any manifest yet (#1177). */
export const TEST_CONNECTION_VERB = "test-connection";

export function testConnectionSupported(
  commands: ReadonlyArray<InfinitusManifestCommand>,
): boolean {
  return commands.some((command) => command.name === TEST_CONNECTION_VERB);
}

/** The `proxy` and `9router` replies share a shape but name the secret differently. */
const ProxyEngineReply = Schema.Struct({
  baseURL: Schema.String,
  keyPresent: Schema.optionalKey(Schema.Boolean),
  passwordPresent: Schema.optionalKey(Schema.Boolean),
  error: Schema.optionalKey(Schema.NullOr(Schema.String)),
});

const decodeReply = Schema.decodeUnknownOption(ProxyEngineReply);

export interface ProxyEngineState {
  readonly baseURL: string;
  readonly secretPresent: boolean;
  /** The engine's own last error, verbatim, or null. */
  readonly error: string | null;
}

/** One engine's read reply, null when the shape is not the one above. */
export function parseProxyEngineState(result: unknown): ProxyEngineState | null {
  const reply = Option.getOrNull(decodeReply(result));
  if (reply === null) return null;
  const present = reply.keyPresent ?? reply.passwordPresent;
  if (present === undefined) return null;
  return { baseURL: reply.baseURL, secretPresent: present, error: reply.error ?? null };
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
