import type { ProviderRuntimeEvent, ThreadId, TurnId } from "@t3tools/contracts";
import type { InfinitusFleet, InfinitusSnapshot } from "@t3tools/contracts/infinitus";

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
/** The engine's word for an account that can take work. */
const ACCOUNT_OK = "ok";

/** Two resumes of one thread are never closer than this; a flapping "ok"
    cannot chain them. Native's ResumeGate spaces its nudges the same way. */
export const RESUME_COOLDOWN_MS = 120_000;

/** The work-log row a resume leaves in the thread. Free-form kind: no
    contract change, and no `.failed` suffix so it never reads as severe. */
export const RESUME_MARKER_KIND = "infinitus.turn.resumed";

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
}

/** The adapter's own two wordings for a limit-ended turn — fixed strings in
    this repo, not the CLI's; matched so the failed variant is caught too. */
const LIMIT_FAILURE = /usage limit/i;

/**
 * The limit stop one runtime event reports, or null. A parked turn arrives as
 * the adapter's `runtime.warning` carrying the SDK's `rate_limit_info` with
 * `status: "rejected"` (never matched on the message text); a failed one as a
 * `turn.completed` whose state is `failed` with the adapter's limit wording.
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
  };
  if (event.type === "runtime.warning") {
    const detail = event.payload.detail;
    if (
      typeof detail === "object" &&
      detail !== null &&
      "status" in detail &&
      detail.status === "rejected"
    ) {
      return { ...base, kind: "parked" };
    }
    return null;
  }
  if (
    event.type === "turn.completed" &&
    event.payload.state === "failed" &&
    event.payload.errorMessage !== undefined &&
    LIMIT_FAILURE.test(event.payload.errorMessage)
  ) {
    return { ...base, kind: "failed" };
  }
  return null;
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
    case "session.exited":
      return true;
    case "turn.completed":
      // A parked turn that completes did so on its own; a failed stop's own
      // completion is the event that recorded it.
      return stop.kind === "parked";
    default:
      return false;
  }
}

function claudeFleets(snapshot: InfinitusSnapshot): ReadonlyArray<InfinitusFleet> {
  return snapshot.fleets.filter((fleet) => fleet.provider === CLAUDE_PROVIDER);
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

/** Who to resume on, or null while nothing has changed. */
export interface ResumeTarget {
  readonly fleetKey: string;
  readonly account: string;
  readonly from: string | null;
}

/**
 * Native's ResumeGate: an active Claude account that reads `ok`, and that
 * reading taken after the stop — a probe from before it would only repeat the
 * account that just ran out. An engine that reports no probe time gets the
 * weaker test, a different account than the one at the stop.
 */
export function resumeTarget(stop: LimitStop, snapshot: InfinitusSnapshot): ResumeTarget | null {
  for (const fleet of claudeFleets(snapshot)) {
    const active = fleet.accounts.find((account) => account.active);
    if (active === undefined || active.usageStatus !== ACCOUNT_OK) continue;
    const from = stop.activeAtStop.get(fleet.key) ?? null;
    const label = accountLabel(active);
    const fetchedAt = active.usageFetchedAt === undefined ? NaN : Date.parse(active.usageFetchedAt);
    const fresh = Number.isFinite(fetchedAt) ? fetchedAt > stop.stoppedAt : label !== from;
    if (fresh) return { fleetKey: fleet.key, account: label, from };
  }
  return null;
}

/** The marker's line. */
export function resumeMarkerSummary(target: ResumeTarget): string {
  return `Turn resumed on ${target.account}`;
}
