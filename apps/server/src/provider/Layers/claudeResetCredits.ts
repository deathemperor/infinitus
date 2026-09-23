/**
 * Claude banked resets (the CLI's `cedar_ember` program, Claude Code 2.1.280).
 * The CLI reads the grants from the OAuth usage endpoint and claims one
 * against the organization; this module sends the same two requests with the
 * login the CLI keeps — the macOS login keychain, or `.credentials.json` in
 * its config directory elsewhere — and never refreshes a token itself: the
 * status probe's `get_usage` runs first and leaves a fresh one behind.
 *
 * Request shapes, id patterns, the claim timeout and the keychain service
 * name are read off the CLI binary, not documented anywhere; a read failure
 * only hides the control.
 *
 * @module provider/Layers/claudeResetCredits
 */
import * as NodeCrypto from "node:crypto";

import type {
  ProviderConsumeResetCreditOutcome,
  ServerProviderResetCredits,
} from "@infinitus/contracts";
import { HostProcessPlatform } from "@infinitus/shared/hostProcess";
import * as DateTime from "effect/DateTime";
import * as Duration from "effect/Duration";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Option from "effect/Option";
import * as Path from "effect/Path";
import * as Schema from "effect/Schema";
import * as Stream from "effect/Stream";
import { HttpClient, HttpClientRequest, HttpClientResponse } from "effect/unstable/http";
import { ChildProcess, ChildProcessSpawner } from "effect/unstable/process";

import { collectUint8StreamText } from "../../stream/collectUint8StreamText.ts";

const API_BASE = "https://api.anthropic.com";
const PROGRAM = "cedar_ember";
/** The CLI's own checks before it sends a claim. */
const GRANT_ID = /^[a-z0-9_-]{1,40}$/;
const REQUEST_ID = /^[A-Za-z0-9_-]{1,64}$/;
/** The CLI's claim timeout; the read shares its usage fetch budget, doubled for a cold socket. */
const CLAIM_TIMEOUT = Duration.seconds(25);
const READ_TIMEOUT = Duration.seconds(10);
const KEYCHAIN_TIMEOUT = Duration.seconds(5);
const KEYCHAIN_MAX_BYTES = 64 * 1024;

/** Where one Claude login lives: the CLI's config directory and its keychain item. */
export interface ClaudeLoginLocation {
  readonly configDir: string;
  readonly keychainService: string;
}

/**
 * The keychain item the CLI stores its OAuth login under: `Claude
 * Code-credentials`, suffixed with the first eight hex digits of the config
 * directory's sha256 when `CLAUDE_CONFIG_DIR` is set, so two config
 * directories never share a login. `configDirEnv` is the exact value the CLI
 * sees, since the hash is over that string.
 */
export function claudeKeychainService(configDirEnv: string | undefined): string {
  const base = "Claude Code-credentials";
  if (!configDirEnv) return base;
  const digest = NodeCrypto.createHash("sha256")
    .update(configDirEnv.normalize("NFC"))
    .digest("hex")
    .slice(0, 8);
  return `${base}-${digest}`;
}

const Credentials = Schema.Struct({
  claudeAiOauth: Schema.optional(
    Schema.NullOr(
      Schema.Struct({
        accessToken: Schema.optional(Schema.String),
        expiresAt: Schema.optional(Schema.NullOr(Schema.Number)),
      }),
    ),
  ),
});
const decodeCredentials = Schema.decodeUnknownOption(Schema.fromJsonString(Credentials));

const Grant = Schema.Struct({
  id: Schema.String.check(Schema.isPattern(GRANT_ID)),
  label: Schema.optional(Schema.NullOr(Schema.String)),
  resets_left: Schema.Int.check(Schema.isGreaterThanOrEqualTo(0)),
  starts_at: Schema.optional(Schema.NullOr(Schema.String)),
  ends_at: Schema.optional(Schema.NullOr(Schema.String)),
  paused: Schema.optional(Schema.Boolean),
  usable_now: Schema.optional(Schema.Boolean),
  use_requires_limit: Schema.optional(Schema.Boolean),
});
const decodeGrant = Schema.decodeUnknownOption(Grant);
const CedarEmber = Schema.Struct({
  eligible: Schema.Boolean,
  at_limit: Schema.optional(Schema.NullOr(Schema.Boolean)),
  grants: Schema.optional(Schema.NullOr(Schema.Array(Schema.Unknown))),
  next_grant_id: Schema.optional(Schema.NullOr(Schema.String)),
  cooldown_until: Schema.optional(Schema.NullOr(Schema.String)),
});
const decodeCedarEmber = Schema.decodeUnknownOption(CedarEmber);
const UsageResponse = Schema.Struct({
  cedar_ember: Schema.optional(Schema.NullOr(Schema.Unknown)),
});
const Profile = Schema.Struct({
  organization: Schema.optional(
    Schema.NullOr(Schema.Struct({ uuid: Schema.optional(Schema.NullOr(Schema.String)) })),
  ),
});
const ClaimResponse = Schema.Struct({
  result: Schema.Literals([
    "reset",
    "already_used",
    "not_limited",
    "cooldown",
    "ineligible",
    "unavailable",
  ]),
});

const RESET_CREDIT_FAILURES = {
  malformedCredit: "Claude returned a malformed reset credit.",
  loginUnreadable: "Claude could not read its login.",
  signedOut: "Sign in to Claude again to redeem resets.",
  rateLimited: "Claude is rate limiting resets. Try again soon.",
  coolingDown: "Claude resets are cooling down. Try again later.",
  requestFailed: "Claude could not redeem the reset.",
} as const;

export class ClaudeResetCreditError extends Schema.TaggedError<ClaudeResetCreditError>()(
  "ClaudeResetCreditError",
  {
    reason: Schema.Literals(
      Object.keys(RESET_CREDIT_FAILURES) as Array<keyof typeof RESET_CREDIT_FAILURES>,
    ),
    cause: Schema.optional(Schema.Defect()),
  },
) {
  override get message(): string {
    return RESET_CREDIT_FAILURES[this.reason];
  }
}

const isoFuture = (value: string | null | undefined, nowMs: number): string | undefined => {
  if (!value) return undefined;
  const dt = DateTime.make(value);
  if (Option.isNone(dt) || DateTime.toEpochMillis(dt.value) <= nowMs) return undefined;
  return DateTime.formatIso(dt.value);
};

const isPast = (value: string | null | undefined, nowMs: number): boolean => {
  if (!value) return false;
  const dt = DateTime.make(value);
  return Option.isSome(dt) && DateTime.toEpochMillis(dt.value) <= nowMs;
};

/**
 * The `cedar_ember` block as the contract. Paused, ended and malformed
 * grants do not count. The grant the server names as next is the one a
 * claim targets; when it cannot be used this moment the hold says why, so a
 * client shows the balance and waits the button instead of spending a click
 * on a `not_limited` answer.
 */
export function claudeResetCreditsToContract(
  block: unknown,
  nowMs: number,
): ServerProviderResetCredits | undefined {
  const parsed = decodeCedarEmber(block);
  if (Option.isNone(parsed) || !parsed.value.eligible) return undefined;
  const status = parsed.value;
  const live = (status.grants ?? [])
    .flatMap((raw) => Option.toArray(decodeGrant(raw)))
    .filter((grant) => !grant.paused && !isPast(grant.ends_at, nowMs));
  const next = live.find((grant) => grant.id === status.next_grant_id);
  const cooldownUntil = isoFuture(status.cooldown_until, nowMs);
  const nextExpiresAt = next ? isoFuture(next.ends_at, nowMs) : undefined;
  const label = next?.label?.trim();
  const hold: ServerProviderResetCredits["nextHold"] = !next
    ? undefined
    : cooldownUntil
      ? { reason: "cooldown", until: cooldownUntil }
      : next.usable_now
        ? undefined
        : next.use_requires_limit && !status.at_limit
          ? { reason: "notAtLimit" }
          : { reason: "blocked" };
  return {
    availableCount: live.reduce((sum, grant) => sum + grant.resets_left, 0),
    ...(nextExpiresAt ? { nextExpiresAt } : {}),
    ...(next ? { nextCreditId: next.id } : {}),
    ...(label ? { label } : {}),
    ...(hold ? { nextHold: hold } : {}),
  };
}

/** `security find-generic-password -w`: the item's payload, or nothing. Stdout is never logged. */
const readKeychainItem = Effect.fn("readKeychainItem")(function* (service: string) {
  const spawner = yield* ChildProcessSpawner.ChildProcessSpawner;
  const collect = Effect.gen(function* () {
    const child = yield* spawner.spawn(
      ChildProcess.make("security", ["find-generic-password", "-s", service, "-w"]),
    );
    yield* Effect.addFinalizer(() => child.kill().pipe(Effect.ignore));
    const [stdout, exitCode] = yield* Effect.all(
      [
        collectUint8StreamText({ stream: child.stdout, maxBytes: KEYCHAIN_MAX_BYTES }),
        child.exitCode,
        Stream.runDrain(child.stderr),
      ],
      { concurrency: "unbounded" },
    );
    return Number(exitCode) !== 0 || stdout.truncated ? undefined : stdout.text;
  });
  return yield* collect.pipe(
    Effect.scoped,
    Effect.timeoutOption(KEYCHAIN_TIMEOUT),
    Effect.map(Option.getOrUndefined),
  );
});

/**
 * The login's access token, or nothing when there is no login, it is not an
 * OAuth one (API key, Bedrock) or its token has lapsed — refreshing is the
 * CLI's job, and the next probe leaves a fresh token behind.
 */
const readAccessToken = Effect.fn("readClaudeAccessToken")(function* (login: ClaudeLoginLocation) {
  const raw =
    (yield* HostProcessPlatform) === "darwin"
      ? yield* readKeychainItem(login.keychainService)
      : yield* Effect.gen(function* () {
          const fs = yield* FileSystem.FileSystem;
          const path = yield* Path.Path;
          return yield* fs.readFileString(path.join(login.configDir, ".credentials.json")).pipe(
            Effect.catchTags({
              PlatformError: (error) =>
                error.reason._tag === "NotFound" ? Effect.succeed(undefined) : Effect.fail(error),
            }),
          );
        });
  if (!raw) return undefined;
  const credentials = decodeCredentials(raw);
  if (Option.isNone(credentials)) return undefined;
  const oauth = credentials.value.claudeAiOauth;
  const token = oauth?.accessToken?.trim();
  if (!token) return undefined;
  const nowMs = DateTime.toEpochMillis(yield* DateTime.now);
  if (typeof oauth?.expiresAt === "number" && oauth.expiresAt <= nowMs) return undefined;
  return token;
});

/** The headers the CLI sends: its bearer, the OAuth beta and its own user agent. */
const withClaudeHeaders = (token: string, version: string) =>
  HttpClientRequest.setHeaders({
    authorization: `Bearer ${token}`,
    "anthropic-beta": "oauth-2025-04-20",
    "content-type": "application/json",
    "user-agent": `claude-cli/${version} (external, cli)`,
  });

/**
 * Reads the banked resets for `login`. Any failure — no OAuth login, a
 * throttled endpoint, a shape the CLI would also reject — reads as "no
 * resets", so the usage bars never break on this optional extra.
 */
export const readClaudeResetCredits = Effect.fn("readClaudeResetCredits")(
  function* (login: ClaudeLoginLocation, version: string) {
    const token = yield* readAccessToken(login);
    if (!token) return undefined;
    const client = yield* HttpClient.HttpClient;
    const response = yield* client.execute(
      HttpClientRequest.get(`${API_BASE}/api/oauth/usage?cedar_ember=1&skip_spend=1`).pipe(
        withClaudeHeaders(token, version),
      ),
    );
    const body = yield* HttpClientResponse.schemaBodyJson(UsageResponse)(
      yield* HttpClientResponse.filterStatusOk(response),
    );
    return claudeResetCreditsToContract(
      body.cedar_ember,
      DateTime.toEpochMillis(yield* DateTime.now),
    );
  },
  Effect.timeout(READ_TIMEOUT),
  Effect.catch(() => Effect.succeed(undefined)),
);

/**
 * The organization the claim is posted to, from the token's own profile
 * rather than `.claude.json`: an account engine that swaps the live login
 * rewrites the file too, but the token is what the claim is made with, so it
 * is the one that must agree.
 */
const readOrganization = Effect.fn("readClaudeOrganization")(function* (
  token: string,
  version: string,
) {
  const client = yield* HttpClient.HttpClient;
  const response = yield* client.execute(
    HttpClientRequest.get(`${API_BASE}/api/oauth/profile`).pipe(withClaudeHeaders(token, version)),
  );
  if (response.status === 401 || response.status === 403) {
    return yield* new ClaudeResetCreditError({ reason: "signedOut" });
  }
  const profile = yield* HttpClientResponse.schemaBodyJson(Profile)(
    yield* HttpClientResponse.filterStatusOk(response),
  ).pipe(
    Effect.mapError((cause) => new ClaudeResetCreditError({ reason: "requestFailed", cause })),
  );
  return profile.organization?.uuid?.trim() || undefined;
});

const CLAIM_OUTCOMES = {
  reset: "reset",
  not_limited: "nothingToReset",
  already_used: "alreadyRedeemed",
  ineligible: "noCredit",
  unavailable: "noCredit",
} as const satisfies Record<string, ProviderConsumeResetCreditOutcome>;

/**
 * Claims `grantId`. `requestId` is the idempotency key: a retry with the same
 * id is the same claim, which is why the coordinator keeps it until Claude
 * answers. Ids are checked before anything is sent.
 */
export const consumeClaudeResetCredit = Effect.fn("consumeClaudeResetCredit")(function* (input: {
  readonly login: ClaudeLoginLocation;
  readonly version: string;
  readonly grantId: string;
  readonly requestId: string;
}) {
  if (!GRANT_ID.test(input.grantId) || !REQUEST_ID.test(input.requestId)) {
    return yield* new ClaudeResetCreditError({ reason: "malformedCredit" });
  }
  const token = yield* readAccessToken(input.login).pipe(
    Effect.mapError((cause) => new ClaudeResetCreditError({ reason: "loginUnreadable", cause })),
  );
  if (!token) return yield* new ClaudeResetCreditError({ reason: "signedOut" });
  const organization = yield* readOrganization(token, input.version).pipe(
    Effect.timeout(READ_TIMEOUT),
    Effect.catchTag("TimeoutError", (cause) =>
      Effect.fail(new ClaudeResetCreditError({ reason: "requestFailed", cause })),
    ),
  );
  if (!organization) return yield* new ClaudeResetCreditError({ reason: "signedOut" });
  const client = yield* HttpClient.HttpClient;
  const response = yield* client
    .execute(
      HttpClientRequest.post(
        `${API_BASE}/api/organizations/${encodeURIComponent(organization)}/reset_rate_limits`,
      ).pipe(
        withClaudeHeaders(token, input.version),
        HttpClientRequest.bodyJsonUnsafe({
          program: PROGRAM,
          grant_id: input.grantId,
          request_id: input.requestId,
        }),
      ),
    )
    .pipe(
      Effect.timeout(CLAIM_TIMEOUT),
      Effect.mapError((cause) => new ClaudeResetCreditError({ reason: "requestFailed", cause })),
    );
  if (response.status === 429) {
    return yield* new ClaudeResetCreditError({ reason: "rateLimited" });
  }
  if (response.status === 401 || response.status === 403) {
    return yield* new ClaudeResetCreditError({ reason: "signedOut" });
  }
  const body = yield* HttpClientResponse.schemaBodyJson(ClaimResponse)(
    yield* HttpClientResponse.filterStatusOk(response).pipe(
      Effect.mapError((cause) => new ClaudeResetCreditError({ reason: "requestFailed", cause })),
    ),
  ).pipe(
    Effect.mapError((cause) => new ClaudeResetCreditError({ reason: "requestFailed", cause })),
  );
  if (body.result === "cooldown") {
    return yield* new ClaudeResetCreditError({ reason: "coolingDown" });
  }
  return CLAIM_OUTCOMES[body.result];
});
