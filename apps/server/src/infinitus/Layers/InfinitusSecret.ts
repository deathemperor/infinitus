import {
  type InfinitusManifestCommand,
  InfinitusSecretRefused,
  InfinitusUnavailable,
} from "@t3tools/contracts/infinitus";
import * as Clock from "effect/Clock";
import * as Effect from "effect/Effect";
import * as FiberHandle from "effect/FiberHandle";
import * as Layer from "effect/Layer";
import * as Redacted from "effect/Redacted";
import * as Ref from "effect/Ref";

import { InfinitusService } from "../Services/Infinitus.ts";
import { InfinitusControlClient } from "../Services/InfinitusControlClient.ts";
import {
  InfinitusSecret,
  type InfinitusSecretForwardInput,
  type InfinitusSecretShape,
} from "../Services/InfinitusSecret.ts";
import { isNotPolled } from "./Infinitus.ts";

/** How often one auth session may send a secret to one verb (#747): enough
    for a mistyped code or two, not for guessing. Counts, not a queue: a
    refused call holds nothing. */
export const SECRET_ATTEMPTS_PER_MINUTE = 5;
const ATTEMPT_WINDOW_MS = 60_000;

/** The manifest spells a positional `<flowId>` and an option as its usage
    line, `--url <base URL, …>`; the caller's `args` keys are the bare names,
    `flowId` and `url`, which is also how the request line names an option. */
const argName = (spec: string): string => spec.replace(/^<(.*)>$/, "$1");
const optionName = (spec: string): string => spec.replace(/^-+/, "").split(/\s+/, 1)[0] ?? spec;

/** The request-line pair for the verb, from `args` keyed by the manifest's
    argument and option names. The offending key instead when a key is not
    one the verb names or a positional it names is missing. */
const requestFor = (
  entry: InfinitusManifestCommand,
  args: Readonly<Record<string, string>>,
):
  | { readonly args: ReadonlyArray<string>; readonly options: Readonly<Record<string, string>> }
  | { readonly badKey: string } => {
  const positionals = entry.args.map(argName);
  const optionNames = entry.options.map(optionName);
  const named = new Set([...positionals, ...optionNames]);
  for (const key of Object.keys(args)) {
    if (!named.has(key)) return { badKey: key };
  }
  const positional: string[] = [];
  for (const name of positionals) {
    const value = args[name];
    if (value === undefined) return { badKey: name };
    positional.push(value);
  }
  const options: Record<string, string> = {};
  for (const name of optionNames) {
    const value = args[name];
    if (value !== undefined) options[name] = value;
  }
  return { args: positional, options };
};

/**
 * The fork's one secret-carrying path (#747). `forward` puts the value on the
 * request line's `secret` field — where stdin material always travels — for a
 * verb whose manifest entry says `stdin: "secret"`, and nothing else: no
 * manifest yet, another verb, an argument the verb does not name, or a sixth
 * attempt inside a minute is refused before the socket is touched. The value
 * is a `Redacted` until the request is built (so a log line, a span or a
 * pretty-printed cause shows `<redacted>`), lives in that one request, and is
 * kept nowhere. The reply passes through opaque; that it never echoes the
 * secret is the verb's own contract.
 */
export const InfinitusSecretLive = Layer.effect(
  InfinitusSecret,
  Effect.gen(function* () {
    const infinitus = yield* InfinitusService;
    const client = yield* InfinitusControlClient;
    /** `${sessionId}\0${command}` → the attempts inside the last minute. */
    const attempts = yield* Ref.make<ReadonlyMap<string, ReadonlyArray<number>>>(new Map());
    const refreshHandle = yield* FiberHandle.make<void, never>();

    const manifestEntry = (command: string) =>
      Effect.gen(function* () {
        // On a server nobody watches, `snapshot` is the pre-poll placeholder
        // until something polls; one refresh reads the manifest for real.
        let snapshot = yield* infinitus.snapshot;
        if (isNotPolled(snapshot)) {
          yield* infinitus.refresh;
          snapshot = yield* infinitus.snapshot;
        }
        if (!snapshot.available) {
          return yield* new InfinitusUnavailable({
            path: client.socketPath ?? "",
            cause: snapshot.unavailableReason ?? "the app is not reachable",
          });
        }
        if (snapshot.commands.length === 0) {
          return yield* new InfinitusSecretRefused({
            command,
            reason: "no_manifest",
            detail: "the app's command table has not been read",
          });
        }
        const entry = snapshot.commands.find((candidate) => candidate.name === command);
        if (entry === undefined || entry.stdin !== "secret") {
          return yield* new InfinitusSecretRefused({
            command,
            reason: "no_secret",
            detail: `${command} does not take a secret`,
          });
        }
        return entry;
      });

    const countAttempt = (input: InfinitusSecretForwardInput) =>
      Effect.gen(function* () {
        const now = yield* Clock.currentTimeMillis;
        const key = `${input.sessionId}\0${input.command}`;
        const recent = ((yield* Ref.get(attempts)).get(key) ?? []).filter(
          (at) => now - at < ATTEMPT_WINDOW_MS,
        );
        if (recent.length >= SECRET_ATTEMPTS_PER_MINUTE) {
          return yield* new InfinitusSecretRefused({
            command: input.command,
            reason: "too_many_attempts",
            detail: "try again in a minute",
          });
        }
        // Keep only the keys still inside the window, so a server that runs
        // for weeks does not remember every session that ever tried.
        yield* Ref.update(
          attempts,
          (map) =>
            new Map(
              [...map, [key, [...recent, now]] as const].filter(
                ([, at]) => (at.at(-1) ?? 0) > now - ATTEMPT_WINDOW_MS,
              ),
            ),
        );
      });

    const forward: InfinitusSecretShape["forward"] = (input) =>
      Effect.gen(function* () {
        // The verb only: never the args, never the value.
        yield* Effect.annotateCurrentSpan({ "infinitus.command": input.command });
        const entry = yield* manifestEntry(input.command);
        const request = requestFor(entry, input.args);
        if ("badKey" in request) {
          return yield* new InfinitusSecretRefused({
            command: input.command,
            reason: "bad_args",
            detail: request.badKey,
          });
        }
        yield* countAttempt(input);
        const result = yield* client.request({
          command: input.command,
          args: request.args,
          options: request.options,
          secret: Redacted.value(input.secret),
        });
        // A secret verb is a write (a key stored, a sign-in finished): read
        // the app again, detached, like `command` does.
        yield* FiberHandle.run(refreshHandle, infinitus.refresh, { startImmediately: true });
        return result === undefined ? {} : { result };
      }).pipe(Effect.withSpan("InfinitusSecret.forward"));

    return InfinitusSecret.of({ forward });
  }),
);
