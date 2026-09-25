/**
<<<<<<< HEAD
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

=======
 * Claude banked resets (the CLI's `cedar_ember` program). The CLI reads the
 * grants from the OAuth usage endpoint and claims one against the
 * organization; this module does the same with the credentials the CLI keeps
 * in its config directory. macOS keeps them in the keychain, so there the
 * feature is not offered.
 *
 * @module provider/Layers/claudeResetCredits
 */
import * as NodeOS from "node:os";
>>>>>>> upstream-sync-c13f7d93f-upstream-renamed
import type {
  ProviderConsumeResetCreditOutcome,
  ServerProviderResetCredits,
} from "@infinitus/contracts";
import { HostProcessPlatform } from "@infinitus/shared/hostProcess";
import * as DateTime from "effect/DateTime";
<<<<<<< HEAD
import * as Duration from "effect/Duration";
=======
>>>>>>> upstream-sync-c13f7d93f-upstream-renamed
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Option from "effect/Option";
import * as Path from "effect/Path";
import * as Schema from "effect/Schema";
<<<<<<< HEAD
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
=======
import { HttpClient, HttpClientRequest, HttpClientResponse } from "effect/unstable/http";

const API_BASE = "https://api.anthropic.com";
const PROGRAM = "cedar_ember";
const GRANT_ID = /^[a-z0-9_-]{1,40}$/;
const REQUEST_ID = /^[A-Za-z0-9_-]{1,64}$/;
const COMPLETE_TIMESTAMP = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/;

const Credentials = Schema.Struct({
  claudeAiOauth: Schema.optional(Schema.Struct({ accessToken: Schema.optional(Schema.String) })),
});
const Config = Schema.Struct({
  oauthAccount: Schema.optional(
    Schema.Struct({ organizationUuid: Schema.optional(Schema.String) }),
  ),
});
const Grant = Schema.Struct({
  id: Schema.String.check(Schema.isPattern(GRANT_ID)),
  resets_left: Schema.Int.check(Schema.isGreaterThanOrEqualTo(0)),
  ends_at: Schema.optional(Schema.NullOr(Schema.String)),
  paused: Schema.optional(Schema.Boolean),
  usable_now: Schema.optional(Schema.Boolean),
>>>>>>> upstream-sync-c13f7d93f-upstream-renamed
});
const decodeGrant = Schema.decodeUnknownOption(Grant);
const CedarEmber = Schema.Struct({
  eligible: Schema.Boolean,
<<<<<<< HEAD
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
=======
  grants: Schema.optional(Schema.Array(Schema.Unknown)),
  next_grant_id: Schema.optional(Schema.NullOr(Schema.String)),
});
const UsageResponse = Schema.Struct({
  cedar_ember: Schema.optional(Schema.NullOr(Schema.Unknown)),
});
const decodeCedarEmber = Schema.decodeUnknownOption(CedarEmber);
>>>>>>> upstream-sync-c13f7d93f-upstream-renamed
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
<<<<<<< HEAD
  signedOut: "Sign in to Claude again to redeem resets.",
  rateLimited: "Claude is rate limiting resets. Try again soon.",
  coolingDown: "Claude resets are cooling down. Try again later.",
  requestFailed: "Claude could not redeem the reset.",
} as const;

export class ClaudeResetCreditError extends Schema.TaggedError<ClaudeResetCreditError>()(
=======
  accountUnreadable: "Claude could not read its account.",
  signedOut: "Sign in to Claude again to redeem resets.",
  rateLimited: "Claude is rate limiting resets. Try again soon.",
  coolingDown: "Claude resets are cooling down. Try again later.",
  unconfirmed:
    "Claude could not confirm the reset. If you are still limited in a moment, try again.",
  requestFailed: "Claude could not redeem the reset.",
} as const;

class ClaudeResetCreditError extends Schema.TaggedError<ClaudeResetCreditError>()(
>>>>>>> upstream-sync-c13f7d93f-upstream-renamed
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

<<<<<<< HEAD
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
=======
const isClaudeResetCreditError = Schema.is(ClaudeResetCreditError);

/**
 * Every reset failure except `requestFailed` and `unconfirmed` is final:
 * Claude answered, or nothing was sent. An unanswered or unconfirmed claim
 * retries with the same request id.
 */
export const isSettledClaudeResetCreditFailure = (error: unknown) =>
  isClaudeResetCreditError(error) &&
  error.reason !== "requestFailed" &&
  error.reason !== "unconfirmed";

/** Rejects unparseable and calendar-invalid timestamps such as February 30. */
const isFutureTimestamp = (value: string, nowMs: number) => {
  if (!COMPLETE_TIMESTAMP.test(value)) return false;
  const [year, month, day] = value.slice(0, 10).split("-").map(Number);
  return (
    Date.parse(value) > nowMs && Date.UTC(year!, month! - 1, day!) <= Date.UTC(year!, month!, 0)
  );
};

/** Grants that are paused or past `ends_at` cannot be claimed and do not count. */
>>>>>>> upstream-sync-c13f7d93f-upstream-renamed
export function claudeResetCreditsToContract(
  block: unknown,
  nowMs: number,
): ServerProviderResetCredits | undefined {
  const parsed = decodeCedarEmber(block);
  if (Option.isNone(parsed) || !parsed.value.eligible) return undefined;
<<<<<<< HEAD
  const status = parsed.value;
  const live = (status.grants ?? [])
    .flatMap((raw) => Option.toArray(decodeGrant(raw)))
    .filter((grant) => !grant.paused && !isPast(grant.ends_at, nowMs));
  const next = live.find((grant) => grant.id === status.next_grant_id);
  const cooldownUntil = isoFuture(status.cooldown_until, nowMs);
  const nextExpiresAt = next ? isoFuture(next.ends_at, nowMs) : undefined;
  const label = next?.label?.trim();
  const availableCount = live.reduce((sum, grant) => sum + grant.resets_left, 0);
  // Credits with no claimable grant (the named one paused or ended) hold too.
  const hold: ServerProviderResetCredits["nextHold"] = !next
    ? availableCount > 0
      ? { reason: "blocked" }
      : undefined
    : cooldownUntil
      ? { reason: "cooldown", until: cooldownUntil }
      : next.usable_now
        ? undefined
        : next.use_requires_limit && !status.at_limit
          ? { reason: "notAtLimit" }
          : { reason: "blocked" };
  return {
    availableCount,
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
=======
  const live = (parsed.value.grants ?? [])
    .flatMap((raw) => Option.toArray(decodeGrant(raw)))
    .filter(
      (grant) =>
        !grant.paused &&
        grant.usable_now &&
        (grant.ends_at == null || isFutureTimestamp(grant.ends_at, nowMs)),
    );
  const next = live.find((grant) => grant.id === parsed.value.next_grant_id);
  const nextExpiresAt = next?.ends_at ? DateTime.make(next.ends_at) : Option.none();
  return {
    availableCount: next ? live.reduce((sum, grant) => sum + grant.resets_left, 0) : 0,
    ...(Option.isSome(nextExpiresAt)
      ? { nextExpiresAt: DateTime.formatIso(nextExpiresAt.value) }
      : {}),
    ...(next ? { nextCreditId: next.id } : {}),
  };
}

const readJson = <S extends Schema.Top>(schema: S, file: string) =>
  Effect.gen(function* () {
    const fs = yield* FileSystem.FileSystem;
    return yield* fs.readFileString(file).pipe(
      Effect.catchTags({
        PlatformError: (error) =>
          error.reason._tag === "NotFound" ? Effect.succeed("{}") : Effect.fail(error),
      }),
      Effect.flatMap(Schema.decodeEffect(Schema.fromJsonString(schema))),
    );
  });

const readAccessToken = (configDir: string) =>
  Effect.gen(function* () {
    if ((yield* HostProcessPlatform) === "darwin") return undefined;
    const path = yield* Path.Path;
    const credentials = yield* readJson(Credentials, path.join(configDir, ".credentials.json"));
    return credentials.claudeAiOauth?.accessToken?.trim() || undefined;
  });

>>>>>>> upstream-sync-c13f7d93f-upstream-renamed
const withClaudeHeaders = (token: string, version: string) =>
  HttpClientRequest.setHeaders({
    authorization: `Bearer ${token}`,
    "anthropic-beta": "oauth-2025-04-20",
<<<<<<< HEAD
    "content-type": "application/json",
=======
>>>>>>> upstream-sync-c13f7d93f-upstream-renamed
    "user-agent": `claude-cli/${version} (external, cli)`,
  });

/**
<<<<<<< HEAD
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
=======
 * Reads the banked resets for the login in `configDir`. Any failure reads as
 * "no resets" so the usage bars never break on this optional extra.
 */
export const readClaudeResetCredits = Effect.fn("readClaudeResetCredits")(
  function* (configDir: string, version: string) {
    const token = yield* readAccessToken(configDir);
    if (!token) return undefined;
    const client = yield* HttpClient.HttpClient;
    const response = yield* client.execute(
      HttpClientRequest.get(`${API_BASE}/api/oauth/usage`, {
        urlParams: { cedar_ember: "1", skip_spend: "1" },
      }).pipe(withClaudeHeaders(token, version)),
>>>>>>> upstream-sync-c13f7d93f-upstream-renamed
    );
    const body = yield* HttpClientResponse.schemaBodyJson(UsageResponse)(
      yield* HttpClientResponse.filterStatusOk(response),
    );
    return claudeResetCreditsToContract(
      body.cedar_ember,
      DateTime.toEpochMillis(yield* DateTime.now),
    );
  },
<<<<<<< HEAD
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
=======
  Effect.timeout("10 seconds"),
  Effect.orElseSucceed(() => undefined),
);

/** The CLI keeps the account record beside its settings, or in the home directory by default. */
export const claudeAccountConfigPath = (configDir: string | undefined) =>
  Effect.map(Path.Path, (path) =>
    configDir ? path.join(configDir, ".claude.json") : path.join(NodeOS.homedir(), ".claude.json"),
  );
>>>>>>> upstream-sync-c13f7d93f-upstream-renamed

const CLAIM_OUTCOMES = {
  reset: "reset",
  not_limited: "nothingToReset",
  already_used: "alreadyRedeemed",
  ineligible: "noCredit",
<<<<<<< HEAD
  unavailable: "noCredit",
=======
>>>>>>> upstream-sync-c13f7d93f-upstream-renamed
} as const satisfies Record<string, ProviderConsumeResetCreditOutcome>;

/**
 * Claims `grantId`. `requestId` is the idempotency key: a retry with the same
<<<<<<< HEAD
 * id is the same claim, which is why the coordinator keeps it until Claude
 * answers. Ids are checked before anything is sent.
 */
export const consumeClaudeResetCredit = Effect.fn("consumeClaudeResetCredit")(function* (input: {
  readonly login: ClaudeLoginLocation;
=======
 * id is the same claim. Ids are checked before anything is sent.
 */
export const consumeClaudeResetCredit = Effect.fn("consumeClaudeResetCredit")(function* (input: {
  readonly configDir: string;
  readonly accountConfigPath: string;
>>>>>>> upstream-sync-c13f7d93f-upstream-renamed
  readonly version: string;
  readonly grantId: string;
  readonly requestId: string;
}) {
  if (!GRANT_ID.test(input.grantId) || !REQUEST_ID.test(input.requestId)) {
    return yield* new ClaudeResetCreditError({ reason: "malformedCredit" });
  }
<<<<<<< HEAD
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
=======
  const token = yield* readAccessToken(input.configDir).pipe(
    Effect.mapError((cause) => new ClaudeResetCreditError({ reason: "loginUnreadable", cause })),
  );
  const config = yield* readJson(Config, input.accountConfigPath).pipe(
    Effect.mapError((cause) => new ClaudeResetCreditError({ reason: "accountUnreadable", cause })),
  );
  const organization = config.oauthAccount?.organizationUuid?.trim();
  if (!token || !organization) {
    return yield* new ClaudeResetCreditError({ reason: "signedOut" });
  }
>>>>>>> upstream-sync-c13f7d93f-upstream-renamed
  const client = yield* HttpClient.HttpClient;
  const response = yield* client
    .execute(
      HttpClientRequest.post(
<<<<<<< HEAD
        `${API_BASE}/api/organizations/${encodeURIComponent(organization)}/reset_rate_limits`,
=======
        new URL(
          `/api/organizations/${encodeURIComponent(organization)}/reset_rate_limits`,
          API_BASE,
        ),
>>>>>>> upstream-sync-c13f7d93f-upstream-renamed
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
<<<<<<< HEAD
      Effect.timeout(CLAIM_TIMEOUT),
=======
      Effect.timeout("25 seconds"),
>>>>>>> upstream-sync-c13f7d93f-upstream-renamed
      Effect.mapError((cause) => new ClaudeResetCreditError({ reason: "requestFailed", cause })),
    );
  if (response.status === 429) {
    return yield* new ClaudeResetCreditError({ reason: "rateLimited" });
  }
  if (response.status === 401 || response.status === 403) {
    return yield* new ClaudeResetCreditError({ reason: "signedOut" });
  }
<<<<<<< HEAD
  const body = yield* HttpClientResponse.schemaBodyJson(ClaimResponse)(
    yield* HttpClientResponse.filterStatusOk(response).pipe(
      Effect.mapError((cause) => new ClaudeResetCreditError({ reason: "requestFailed", cause })),
    ),
  ).pipe(
=======
  const body = yield* HttpClientResponse.filterStatusOk(response).pipe(
    Effect.flatMap(HttpClientResponse.schemaBodyJson(ClaimResponse)),
    Effect.timeout("25 seconds"),
>>>>>>> upstream-sync-c13f7d93f-upstream-renamed
    Effect.mapError((cause) => new ClaudeResetCreditError({ reason: "requestFailed", cause })),
  );
  if (body.result === "cooldown") {
    return yield* new ClaudeResetCreditError({ reason: "coolingDown" });
  }
<<<<<<< HEAD
=======
  // Claude could not say whether the claim landed, so, like the CLI, keep the
  // request id and let the retry ask about the same claim.
  if (body.result === "unavailable") {
    return yield* new ClaudeResetCreditError({ reason: "unconfirmed" });
  }
>>>>>>> upstream-sync-c13f7d93f-upstream-renamed
  return CLAIM_OUTCOMES[body.result];
});
