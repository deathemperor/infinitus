import type {
  ModelSelection,
  OrchestrationV2ThreadShell,
  ProviderInstanceConfigMap,
  RunId,
  ThreadId,
} from "@infinitus/contracts";
import type {
  InfinitusFleet,
  InfinitusLimitStop,
  InfinitusSnapshot,
} from "@infinitus/contracts/infinitus";
import * as DateTime from "effect/DateTime";
import * as Schema from "effect/Schema";

import type { ClaudeUsageLimitRefusal } from "../../orchestration-v2/Adapters/ClaudeAdapterV2.ts";

/**
 * Resume-on-limit (#648, #1627): the pure half. When the account behind a thread's turn hits its
 * limit and the engine swaps (or the account returns), the turn is re-issued on the live account,
 * by native's ResumeService / ResumeGate rules: once per stop, as fresh as the probe, spaced by a
 * cooldown.
 */

/** Fleets whose accounts are Claude ones, whatever engine runs them. */
const CLAUDE_PROVIDER = "claude";
/** The engine that writes the CLI's own credentials. A plain instance spends
    that fleet's active account and no other: the proxy engines (cliproxy,
    9router) are reached over `ANTHROPIC_BASE_URL`, which makes the instance a
    proxied one (#1088) with a stop of its own kind. */
const CLI_CREDENTIALS_ENGINE = "swapd";
/** The engine's word for an account whose credentials work. It says nothing
    about headroom: an account with a window at 100 % still reads `ok`. */
const ACCOUNT_OK = "ok";
/** The variable a proxied instance carries (`applyProxyDraft`, #1088): its
    requests never spend a swapd account, so its limit is the proxy's own. */
const PROXY_BASE_URL_VARIABLE = "ANTHROPIC_BASE_URL";

/** Two resumes of one thread are never closer than this; a flapping "ok"
    cannot chain them. Native's ResumeGate spaces its nudges the same way. */
export const RESUME_COOLDOWN_MS = 120_000;

/** How far a refusal's reset may sit from an account's reading of the same window and still be that
    account's (#1486). The API states both to the second: this is slack for engine rounding, not for
    accounts whose windows end near each other (a 5h reset moves with its first request). */
export const RESET_MATCH_MS = 5 * 60_000;

/** What the resumed turn is told — upstream's own continuation prompt (the one
    its reset-time recovery sends), so the thread reads the same after either. */
export const CONTINUATION_PROMPT = "Continue where you left off.";

/** A turn a usage limit stopped, as this server saw it. `parked`: the SDK
    holds the turn open and retries it as the window resets (the common case);
    `failed`: the CLI ended the turn with the limit as its error, and the
    orchestrator's run failed with class `usage_limit`. */
export interface LimitStop {
  readonly threadId: ThreadId;
  readonly runId: RunId;
  readonly kind: "parked" | "failed";
  readonly stoppedAt: number;
  /** The CLI-credentials fleet the thread spends, by key; null when the
      snapshot showed none (nothing to resume on, nothing to report to). */
  readonly fleetKey: string | null;
  /** The account whose window refused the turn: the one live at the stop
      when its reading of that window agrees with the refusal, else the one
      other account whose reading does, else nobody (#1486). */
  readonly account: string | null;
  /** When the window that rejected the turn resets (epoch ms), from the SDK's
      `rate_limit_info`; null when the stop named none. */
  readonly resetsAt: number | null;
  /** The SDK's name for that window (`five_hour`, `seven_day`, `seven_day_opus`
      …); null when the stop named none. */
  readonly limitType: string | null;
  /** The proxied instance the thread runs on (#1088), else null: its limit
      belongs to the proxy's upstream, so no swapd account is named and no
      rotation resumes it. */
  readonly proxy: string | null;
}

/** The fleets a plain Claude instance can run on: the CLI-credentials engine's. */
function claudeFleets(snapshot: InfinitusSnapshot): ReadonlyArray<InfinitusFleet> {
  return snapshot.fleets.filter(
    (fleet) => fleet.provider === CLAUDE_PROVIDER && fleet.engineID === CLI_CREDENTIALS_ENGINE,
  );
}

/** The engine's usage payload, opaque in the contract; read leniently so an odd shape is "no
    reading", not a throw. `resetsAt` is an ISO string from the Mac and swapd's list, epoch seconds
    in a recorded sample. */
const UsageWindow = Schema.Struct({
  name: Schema.optionalKey(Schema.String),
  pct: Schema.Finite,
  resetsAt: Schema.optionalKey(Schema.NullOr(Schema.Union([Schema.String, Schema.Finite]))),
});
const UsagePayload = Schema.Struct({
  fiveHour: Schema.optionalKey(Schema.NullOr(UsageWindow)),
  sevenDay: Schema.optionalKey(Schema.NullOr(UsageWindow)),
  scoped: Schema.optionalKey(Schema.NullOr(Schema.Array(UsageWindow))),
});
type UsageWindow = typeof UsageWindow.Type;
const decodeUsage = Schema.decodeUnknownOption(UsagePayload);

/** The scoped (per-model) window an SDK limit type names, by the word in it. */
const SCOPED_WINDOW_WORDS: Readonly<Record<string, string>> = {
  seven_day_opus: "opus",
  seven_day_sonnet: "sonnet",
};

type Account = InfinitusFleet["accounts"][number];

function accountLabel(account: Account): string {
  return account.alias ?? account.email;
}

/** A window's reset as epoch ms, whichever way the engine wrote it. */
function windowResetMs(window: UsageWindow): number | null {
  const value = window.resetsAt;
  if (value === undefined || value === null) return null;
  if (typeof value === "number") return value < 1e12 ? value * 1000 : value;
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function usageWindows(account: Account): ReadonlyArray<UsageWindow> {
  if (account.usage === undefined) return [];
  const decoded = decodeUsage(account.usage);
  if (decoded._tag !== "Some") return [];
  const usage = decoded.value;
  return [usage.fiveHour, usage.sevenDay, ...(usage.scoped ?? [])].filter(
    (window) => window !== undefined && window !== null,
  );
}

/**
 * What the account's latest reading says of the window that stopped the
 * turn; null when the reading has no such window (or no reading at all),
 * which is no evidence either way.
 */
function stopWindow(limitType: string | null, account: Account): UsageWindow | null {
  if (limitType === null || account.usage === undefined) return null;
  const decoded = decodeUsage(account.usage);
  if (decoded._tag !== "Some") return null;
  const usage = decoded.value;
  if (limitType === "five_hour") return usage.fiveHour ?? null;
  if (limitType === "seven_day") return usage.sevenDay ?? null;
  const word = SCOPED_WINDOW_WORDS[limitType];
  if (word === undefined) return null;
  return (
    (usage.scoped ?? []).find((scoped) => (scoped.name ?? "").toLowerCase().includes(word)) ?? null
  );
}

/**
 * Whether a reading shows the account with room in every window it carries; false for one with no
 * windows, which is no evidence. The test for a failed stop without a window (the CLI ended the
 * turn with its synthetic rate-limit error and no window event).
 */
function everyWindowUnderFull(account: Account): boolean {
  const windows = usageWindows(account);
  return windows.length > 0 && windows.every((window) => window.pct < 100);
}

/** Whose limit a refusal is, by fleet; null when the snapshot has no fleet
    the CLI spends. `account` is null when nobody's reading fits. */
export interface RefusedAccount {
  readonly fleetKey: string;
  readonly account: string | null;
}

/**
 * Whose limit a refusal is (#1486). A CLI keeps the login it started on after a swap, so a refusal
 * seconds later is the previous account's; blaming the live one reported a healthy account as
 * spent. The refusal's window and reset are compared to each account's reading: the active account
 * when it agrees (or nothing is comparable), else the one other account that does, else nobody.
 */
export function refusedAccount(
  refusal: Pick<ClaudeUsageLimitRefusal, "rateLimitType" | "resetsAt">,
  snapshot: InfinitusSnapshot,
): RefusedAccount | null {
  const fleet = claudeFleets(snapshot)[0];
  if (fleet === undefined) return null;
  const active = fleet.accounts.find((account) => account.active);
  if (active === undefined) return { fleetKey: fleet.key, account: null };
  const matches = (account: Account): boolean | null => {
    const window = stopWindow(refusal.rateLimitType, account);
    const reading = window === null ? null : windowResetMs(window);
    if (reading === null || refusal.resetsAt === null) return null;
    return Math.abs(reading - refusal.resetsAt) <= RESET_MATCH_MS;
  };
  if (matches(active) !== false) return { fleetKey: fleet.key, account: accountLabel(active) };
  const others = fleet.accounts.filter(
    (account) => account !== active && matches(account) === true,
  );
  return { fleetKey: fleet.key, account: others.length === 1 ? accountLabel(others[0]!) : null };
}

/**
 * The proxied instance's label when the thread's instance routes through one
 * (`ANTHROPIC_BASE_URL` on its environment), else null. The display name,
 * falling back to the instance id.
 */
export function proxyInstanceLabel(
  instances: ProviderInstanceConfigMap,
  selection: Pick<ModelSelection, "instanceId">,
): string | null {
  const instance = instances[selection.instanceId];
  if (instance === undefined) return null;
  const proxied = (instance.environment ?? []).some(
    (variable) =>
      variable.name === PROXY_BASE_URL_VARIABLE &&
      (typeof variable.value !== "string" || variable.value.trim() !== ""),
  );
  return proxied ? (instance.displayName ?? selection.instanceId) : null;
}

/** The stop a thread shell records once its run failed on a usage limit: the adapter classes the
    failure `usage_limit` and the shell carries the window's reset; the window's name comes from the
    refusal reported for the same run, if the turn was parked first. Null otherwise. */
export function failedStopFromShell(
  shell: Pick<
    OrchestrationV2ThreadShell,
    | "id"
    | "status"
    | "lastErrorClass"
    | "usageLimitResetAt"
    | "latestRunId"
    | "latestRunCompletedAt"
    | "archivedAt"
    | "settledOverride"
  >,
  now: number,
  refusal: Pick<ClaudeUsageLimitRefusal, "runId" | "rateLimitType"> | null,
): Omit<LimitStop, "fleetKey" | "account" | "proxy"> | null {
  if (
    shell.status !== "failed" ||
    shell.lastErrorClass !== "usage_limit" ||
    shell.latestRunId === null ||
    shell.archivedAt !== null ||
    shell.settledOverride === "settled"
  )
    return null;
  const reset = shell.usageLimitResetAt == null ? NaN : Date.parse(shell.usageLimitResetAt);
  return {
    threadId: shell.id,
    runId: shell.latestRunId,
    kind: "failed",
    stoppedAt:
      shell.latestRunCompletedAt == null ? now : DateTime.toEpochMillis(shell.latestRunCompletedAt),
    resetsAt: Number.isFinite(reset) ? reset : null,
    limitType:
      refusal !== null && refusal.runId === shell.latestRunId ? refusal.rateLimitType : null,
  };
}

/** Who to resume on, or null while nothing has changed. */
export interface ResumeTarget {
  readonly fleetKey: string;
  readonly account: string;
  readonly from: string | null;
}

/**
 * Native's ResumeGate with headroom read where the engine reports it. `ok` alone is not headroom
 * (the account that just hit the limit reads `ok` on the next poll, which resumed a turn on it
 * every cooldown), so a reading carrying the stop's window decides (under 100 %). Without one, a
 * different account counts, the same one only after the stop's reset.
 */
export function resumeTarget(
  stop: LimitStop,
  snapshot: InfinitusSnapshot,
  now: number,
): ResumeTarget | null {
  // A proxy's limit: no account on this Mac can lift it (#1088).
  if (stop.proxy !== null) return null;
  for (const fleet of claudeFleets(snapshot)) {
    if (stop.fleetKey !== null && fleet.key !== stop.fleetKey) continue;
    const active = fleet.accounts.find((account) => account.active);
    if (active === undefined || active.usageStatus !== ACCOUNT_OK) continue;
    const from = stop.account;
    const label = accountLabel(active);
    const fetchedAt = active.usageFetchedAt === undefined ? NaN : Date.parse(active.usageFetchedAt);
    const swapped = from !== null && label !== from;
    const fresh = Number.isFinite(fetchedAt)
      ? swapped || fetchedAt > stop.stoppedAt
      : label !== from;
    if (!fresh) continue;
    const target = { fleetKey: fleet.key, account: label, from };
    const window = stopWindow(stop.limitType, active);
    if (window !== null) {
      if (window.pct < 100) return target;
      continue;
    }
    if (from !== null && label !== from) return target;
    if (stop.resetsAt !== null && now >= stop.resetsAt) return target;
    // The same account, or a stop naming nobody (restored at boot): only a
    // reading with every window under full says it has room.
    if (stop.limitType === null && everyWindowUnderFull(active)) return target;
  }
  return null;
}

/** The stop's line, as the sidebar's tooltip and the log read it. */
export function limitStopSummary(stop: Pick<LimitStop, "account" | "proxy">): string {
  if (stop.proxy !== null) return `Limit hit on the proxy instance ${stop.proxy}`;
  return stop.account === null ? "Limit hit" : `Limit hit on ${stop.account}`;
}

/** The stop as the clients see it (`subscribeInfinitusLimitStops`). */
export function toWireStop(stop: LimitStop): InfinitusLimitStop {
  return {
    threadId: stop.threadId,
    kind: stop.kind,
    since: DateTime.formatIso(DateTime.makeUnsafe(stop.stoppedAt)),
    account: stop.account,
    resetsAt:
      stop.resetsAt === null ? null : DateTime.formatIso(DateTime.makeUnsafe(stop.resetsAt)),
    ...(stop.proxy === null ? {} : { proxy: stop.proxy }),
  };
}
