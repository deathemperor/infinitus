import type {
  ModelSelection,
  OrchestrationThreadActivity,
  OrchestrationThreadShell,
  ProviderInstanceConfigMap,
  ProviderRuntimeEvent,
  ThreadId,
  TurnId,
} from "@infinitus/contracts";
import type { InfinitusFleet, InfinitusSnapshot } from "@infinitus/contracts/infinitus";
import * as Schema from "effect/Schema";
import * as DateTime from "effect/DateTime";

/**
 * Resume-on-limit for the threads this server runs (#648): the pure half.
 * When the Claude account behind a thread's turn hits its usage limit and the
 * engine swaps (or the account comes back), the turn is re-issued on whatever
 * account is live now. These are the same rules native's terminal nudge
 * applies (ResumeService / ResumeGate): once per stop, alive only as fresh as
 * the probe, spaced by a cooldown.
 */

/** The Claude Code driver, the only one this covers. */
const CLAUDE_DRIVER = "claudeAgent";
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

/** The work-log row a resume leaves in the thread. Free-form kind: no
    contract change, and no `.failed` suffix so it never reads as severe. */
export const RESUME_MARKER_KIND = "infinitus.turn.resumed";
/** The row a limit stop leaves the moment it lands (#270 I): the sidebar pill
    and the banner read "Limit hit" from it until the resumed row or a new
    turn follows. */
export const LIMIT_MARKER_KIND = "infinitus.thread.limited";

/** What the resumed turn is told — upstream's own continuation prompt (the one
    a server update sends), so the thread reads the same after either. */
export const CONTINUATION_PROMPT = "Continue where you left off.";

/** A turn a usage limit stopped, as this server saw it. `parked`: the SDK
    holds the turn open with nothing arriving (the common case); `failed`: the
    CLI ended the turn with the limit as its error. */
export interface LimitStop {
  readonly threadId: ThreadId;
  readonly turnId: TurnId | null;
  readonly kind: "parked" | "failed";
  readonly stoppedAt: number;
  /** Who each Claude fleet ran on when the stop landed, by fleet key; the
      marker names the change. */
  readonly activeAtStop: ReadonlyMap<string, string>;
  /** When the window that rejected the turn resets (epoch ms), from the SDK's
      `rate_limit_info`; null for a failed turn, whose error names no reset. */
  readonly resetsAt: number | null;
  /** The SDK's name for that window (`five_hour`, `seven_day`, `seven_day_opus`
      …); null when the stop named none. */
  readonly limitType: string | null;
  /** The proxied instance the thread runs on (#1088), else null: its limit
      belongs to the proxy's upstream, so no swapd account is named and no
      rotation resumes it. */
  readonly proxy: string | null;
}

const decodeLimitMarker = Schema.decodeUnknownOption(
  Schema.Struct({
    stop: Schema.Literals(["parked", "failed"]),
    accounts: Schema.Array(Schema.String),
    resetsAt: Schema.optionalKey(Schema.NullOr(Schema.DateTimeUtcFromString)),
    limitType: Schema.optionalKey(Schema.NullOr(Schema.String)),
    proxy: Schema.optionalKey(Schema.NullOr(Schema.String)),
  }),
);

/** Recover only unresolved failures of the thread's current turn. A saved
 * parked marker may describe a turn that subsequently failed before exit. */
export function restoreLimitStops(
  threads: ReadonlyArray<OrchestrationThreadShell>,
  limits: ReadonlyArray<OrchestrationThreadActivity>,
  resumes: ReadonlyArray<OrchestrationThreadActivity>,
): ReadonlyArray<LimitStop> {
  const resumed = new Set(resumes.map((activity) => activity.turnId));
  const byTurn = new Map<TurnId, OrchestrationThreadActivity>();
  for (const activity of limits) {
    if (activity.turnId === null || activity.kind !== LIMIT_MARKER_KIND) continue;
    const previous = byTurn.get(activity.turnId);
    if (previous === undefined || activity.createdAt > previous.createdAt) {
      byTurn.set(activity.turnId, activity);
    }
  }
  const stops: LimitStop[] = [];
  for (const thread of threads) {
    const turn = thread.latestTurn;
    if (
      thread.archivedAt !== null ||
      turn === null ||
      turn.state !== "error" ||
      // `stopped` is the same stop after the idle reaper took its session.
      (thread.session?.status !== "error" && thread.session?.status !== "stopped") ||
      thread.session.activeTurnId !== null ||
      resumed.has(turn.turnId)
    )
      continue;
    const marker = byTurn.get(turn.turnId);
    if (marker === undefined) continue;
    const stoppedAt = Date.parse(marker.createdAt);
    if (thread.latestUserMessageAt !== null && Date.parse(thread.latestUserMessageAt) > stoppedAt)
      continue;
    const decoded = decodeLimitMarker(marker.payload);
    if (decoded._tag !== "Some" || decoded.value.proxy != null) continue;
    const payload = decoded.value;
    // This feature has always tracked just the CLI credential fleet. Older
    // markers saved its label as an array without the fleet key.
    const account = payload.accounts[0];
    if (account === undefined) continue;
    stops.push({
      threadId: thread.id,
      turnId: turn.turnId,
      kind: "failed",
      stoppedAt,
      activeAtStop: new Map([["swapd/claude", account]]),
      resetsAt: payload.resetsAt == null ? null : DateTime.toEpochMillis(payload.resetsAt),
      limitType: payload.limitType ?? null,
      proxy: null,
    });
  }
  return stops;
}

/**
 * The limit stop one runtime event reports, or null. Both arms read structured
 * evidence, never the adapter's prose: a parked turn arrives as the adapter's
 * `runtime.warning` carrying the SDK's `rate_limit_info` with
 * `status: "rejected"`; a failed one as a `turn.completed` whose state is
 * `failed` and whose payload carries `usageLimited`. Matching the error text
 * instead read every wording with "usage limit" in it as a stop — including
 * the CLI's context-window gate, whose message said so until it was reworded.
 */
export function limitStopFromEvent(
  event: ProviderRuntimeEvent,
  now: number,
  snapshot: InfinitusSnapshot,
): LimitStop | null {
  if (event.provider !== CLAUDE_DRIVER) return null;
  const base = {
    threadId: event.threadId,
    turnId: event.turnId ?? null,
    stoppedAt: now,
    activeAtStop: activeClaudeAccounts(snapshot),
    proxy: null,
  };
  if (event.type === "runtime.warning") {
    const detail = event.payload.detail;
    if (
      typeof detail === "object" &&
      detail !== null &&
      "status" in detail &&
      detail.status === "rejected"
    ) {
      const resetsAt = "resetsAt" in detail ? detail.resetsAt : undefined;
      const limitType = "rateLimitType" in detail ? detail.rateLimitType : undefined;
      return {
        ...base,
        activeAtStop: refusedClaudeAccounts(detail, snapshot),
        kind: "parked",
        // Epoch seconds on the wire, as the adapter reads it.
        resetsAt:
          typeof resetsAt === "number" && Number.isFinite(resetsAt) ? resetsAt * 1000 : null,
        limitType: typeof limitType === "string" && limitType !== "" ? limitType : null,
      };
    }
    return null;
  }
  if (
    event.type === "turn.completed" &&
    event.payload.state === "failed" &&
    event.payload.usageLimited === true
  ) {
    return { ...base, kind: "failed", resetsAt: null, limitType: null };
  }
  return null;
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
    (variable) => variable.name === PROXY_BASE_URL_VARIABLE && variable.value.trim() !== "",
  );
  return proxied ? (instance.displayName ?? selection.instanceId) : null;
}

/** The stop as a proxied instance's: no account named, never resumed. */
export function proxyStop(stop: LimitStop, proxy: string): LimitStop {
  return { ...stop, proxy, activeAtStop: new Map() };
}

/**
 * Whether one runtime event means the stop is no longer ours to resume: the
 * turn moved on (the user interrupted or re-sent, the CLI recovered) or the
 * session went away. Our own interrupt lands after the record is gone, so it
 * never reaches here for the stop it ends.
 */
export function eventCancelsStop(event: ProviderRuntimeEvent, stop: LimitStop): boolean {
  if (event.threadId !== stop.threadId) return false;
  switch (event.type) {
    case "turn.started":
      return true;
    case "turn.aborted":
      return true;
    case "session.exited":
      // A parked turn goes with its session. A failed one already ended: the
      // idle reaper stops its session long before the window resets, and the
      // resume's send starts a new one from the resume cursor.
      return stop.kind === "parked";
    case "turn.completed":
      // A parked turn that completes did so on its own; a failed stop's own
      // completion is the event that recorded it.
      return stop.kind === "parked";
    default:
      return false;
  }
}

/** The fleets a plain Claude instance can run on: the CLI-credentials engine's. */
function claudeFleets(snapshot: InfinitusSnapshot): ReadonlyArray<InfinitusFleet> {
  return snapshot.fleets.filter(
    (fleet) => fleet.provider === CLAUDE_PROVIDER && fleet.engineID === CLI_CREDENTIALS_ENGINE,
  );
}

/** The engine's usage payload, opaque in the contract; read leniently, as the
    Accounts page does, so an odd shape is "no reading" rather than a throw. */
const UsageWindow = Schema.Struct({
  name: Schema.optionalKey(Schema.String),
  pct: Schema.Finite,
});
const UsagePayload = Schema.Struct({
  fiveHour: Schema.optionalKey(UsageWindow),
  sevenDay: Schema.optionalKey(UsageWindow),
  scoped: Schema.optionalKey(Schema.Array(UsageWindow)),
});
const decodeUsage = Schema.decodeUnknownOption(UsagePayload);

/** The scoped (per-model) window an SDK limit type names, by the word in it. */
const SCOPED_WINDOW_WORDS: Readonly<Record<string, string>> = {
  seven_day_opus: "opus",
  seven_day_sonnet: "sonnet",
};

/**
 * What the account's latest reading says of the window that stopped the
 * turn, in percent used; null when the reading has no such window (or no
 * reading at all), which is no evidence either way.
 */
function stopWindowPct(
  limitType: string | null,
  account: InfinitusFleet["accounts"][number],
): number | null {
  if (limitType === null || account.usage === undefined) return null;
  const decoded = decodeUsage(account.usage);
  if (decoded._tag !== "Some") return null;
  const usage = decoded.value;
  if (limitType === "five_hour") return usage.fiveHour?.pct ?? null;
  if (limitType === "seven_day") return usage.sevenDay?.pct ?? null;
  const word = SCOPED_WINDOW_WORDS[limitType];
  if (word === undefined) return null;
  const window = (usage.scoped ?? []).find((scoped) =>
    (scoped.name ?? "").toLowerCase().includes(word),
  );
  return window?.pct ?? null;
}

function accountLabel(account: InfinitusFleet["accounts"][number]): string {
  return account.alias ?? account.email;
}

/** The active account of every Claude fleet, by fleet key. */
export function activeClaudeAccounts(snapshot: InfinitusSnapshot): ReadonlyMap<string, string> {
  const out = new Map<string, string>();
  for (const fleet of claudeFleets(snapshot)) {
    const active = fleet.accounts.find((account) => account.active);
    if (active !== undefined) out.set(fleet.key, accountLabel(active));
  }
  return out;
}

/** How far a refusal's window figure may sit from an account's reading and
    still be that account's: readings trail the refusal by a poll or two. */
const REFUSAL_MATCH_PCT = 10;

/** The 0–1 utilization the SDK's refusal carries for one window, in percent. */
function refusalWindowPct(detail: object, window: string): number | null {
  const windows = "unifiedWindows" in detail ? detail.unifiedWindows : undefined;
  if (typeof windows !== "object" || windows === null || !(window in windows)) return null;
  const entry = (windows as Record<string, unknown>)[window];
  if (typeof entry !== "object" || entry === null || !("utilization" in entry)) return null;
  const utilization = entry.utilization;
  return typeof utilization === "number" && Number.isFinite(utilization) ? utilization * 100 : null;
}

/** The widest gap between the refusal's figures and the account's reading over
    the windows both carry; null when they share none. */
function refusalDistance(
  detail: object,
  account: InfinitusFleet["accounts"][number],
): number | null {
  const decoded = account.usage === undefined ? undefined : decodeUsage(account.usage);
  if (decoded === undefined || decoded._tag !== "Some") return null;
  const pairs: ReadonlyArray<readonly [number | null, number | undefined]> = [
    [refusalWindowPct(detail, "five_hour"), decoded.value.fiveHour?.pct],
    [refusalWindowPct(detail, "seven_day"), decoded.value.sevenDay?.pct],
  ];
  let widest: number | null = null;
  for (const [refused, read] of pairs) {
    if (refused === null || read === undefined) continue;
    widest = Math.max(widest ?? 0, Math.abs(refused - read));
  }
  return widest;
}

/**
 * Whose limit a parked turn's refusal is, by fleet key. Normally the active
 * account's. A CLI keeps the login it started on for a while after a swap, so
 * a refusal seconds after one can still be the previous account's: blaming the
 * live account reported a healthy one to the engine as spent until a weekly
 * reset five days off, and the engine benched it 70 s after swapping to it.
 * The refusal names its own window figures, so they decide: the active account
 * when its reading agrees (or nothing can be compared), else the one other
 * account whose reading does, else nobody — an unnamed stop reports nothing.
 */
export function refusedClaudeAccounts(
  detail: object,
  snapshot: InfinitusSnapshot,
): ReadonlyMap<string, string> {
  const out = new Map<string, string>();
  for (const fleet of claudeFleets(snapshot)) {
    const active = fleet.accounts.find((account) => account.active);
    if (active === undefined) continue;
    const ofActive = refusalDistance(detail, active);
    if (ofActive === null || ofActive <= REFUSAL_MATCH_PCT) {
      out.set(fleet.key, accountLabel(active));
      continue;
    }
    const others = fleet.accounts.filter((account) => {
      if (account === active) return false;
      const distance = refusalDistance(detail, account);
      return distance !== null && distance <= REFUSAL_MATCH_PCT;
    });
    if (others.length === 1) out.set(fleet.key, accountLabel(others[0]!));
  }
  return out;
}

/** Who to resume on, or null while nothing has changed. */
export interface ResumeTarget {
  readonly fleetKey: string;
  readonly account: string;
  readonly from: string | null;
}

/**
 * Native's ResumeGate, with headroom read where the engine reports it: an
 * active account of the CLI-credentials fleet whose credentials read `ok`
 * from a probe taken after the stop — a probe from before it would only
 * repeat the account that just ran out. A different account than the one at
 * the stop needs no newer probe: its reading says nothing of the account that
 * ran out, and the engine rations the usage endpoint, so an idle account the
 * swap lands on is next read minutes later (a thread stopped a second after
 * the engine's sweep sat six minutes beside four that resumed). `ok` alone is
 * not headroom (the
 * account that hit the limit reads `ok` on the very next poll, which is how a
 * turn was resumed on it every cooldown until its window reset), so:
 * a reading that carries the stop's window decides — under 100 % counts,
 * full does not, whichever account it is; without one, a different account
 * counts, and the same account only once the stop's reset has passed. An
 * engine that reports no probe time gets the weaker test, a different account
 * than the one at the stop.
 */
export function resumeTarget(
  stop: LimitStop,
  snapshot: InfinitusSnapshot,
  now: number,
): ResumeTarget | null {
  // A proxy's limit: no account on this Mac can lift it (#1088).
  if (stop.proxy !== null) return null;
  for (const fleet of claudeFleets(snapshot)) {
    const active = fleet.accounts.find((account) => account.active);
    if (active === undefined || active.usageStatus !== ACCOUNT_OK) continue;
    const from = stop.activeAtStop.get(fleet.key) ?? null;
    const label = accountLabel(active);
    const fetchedAt = active.usageFetchedAt === undefined ? NaN : Date.parse(active.usageFetchedAt);
    const swapped = from !== null && label !== from;
    const fresh = Number.isFinite(fetchedAt)
      ? swapped || fetchedAt > stop.stoppedAt
      : label !== from;
    if (!fresh) continue;
    const target = { fleetKey: fleet.key, account: label, from };
    const pct = stopWindowPct(stop.limitType, active);
    if (pct !== null) {
      if (pct < 100) return target;
      continue;
    }
    if (label !== from) return target;
    if (stop.resetsAt !== null && now >= stop.resetsAt) return target;
  }
  return null;
}

/** The marker's line. */
/** The limited row's line: the account whose limit stopped the turn, when
    the snapshot named one. */
export function limitMarkerSummary(stop: LimitStop): string {
  if (stop.proxy !== null) return `Limit hit on the proxy instance ${stop.proxy}`;
  const accounts = [...new Set(stop.activeAtStop.values())];
  return accounts.length === 0 ? "Limit hit" : `Limit hit on ${accounts.join(", ")}`;
}

export function resumeMarkerSummary(target: ResumeTarget): string {
  return `Turn resumed on ${target.account}`;
}
