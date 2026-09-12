import type { ThreadHold } from "@t3tools/client-runtime/state/infinitusThreadHold";
import type { InfinitusReleaseThreadResult } from "@t3tools/contracts/infinitus";
import * as Cause from "effect/Cause";

/**
 * The held banner's pure half (#742, the phone's copy of the web's
 * `infinitusHoldBanner.logic.ts`, #616): what "Run now" answered and what the
 * banner says for it. The banner itself leaves when the thread's rows say the
 * hold is over; these phases only cover the moments in between. A turn paused
 * by interrupt mode (#743) shares the banner: same RPC, same phases, its own
 * words.
 */
type HoldKind = ThreadHold["kind"];

/** What the card is headed. */
export function holdBannerTitle(kind: HoldKind): string {
  switch (kind) {
    case "paused":
      return "Paused for headroom";
    case "limited":
      return "Stopped on a usage limit";
    case "held":
      return "Waiting for headroom";
  }
}
export type HoldPhase =
  | { readonly kind: "idle" }
  | { readonly kind: "releasing" }
  | { readonly kind: "pinning" }
  /** The server ran the start; the released row and the session follow. */
  | { readonly kind: "released" }
  /** The server holds nothing for the thread: a restart forgot the start. */
  | { readonly kind: "gone"; readonly reason: string }
  | { readonly kind: "failed"; readonly message: string };

const failureMessage = (cause: Cause.Cause<unknown>): string => {
  const error = Cause.squash(cause);
  return error instanceof Error ? error.message : String(error);
};

export function holdPhaseAfterRelease(
  result:
    | { readonly _tag: "Success"; readonly value: InfinitusReleaseThreadResult }
    | { readonly _tag: "Failure"; readonly cause: Cause.Cause<unknown> },
): HoldPhase {
  if (result._tag === "Failure") return { kind: "failed", message: failureMessage(result.cause) };
  if (result.value.released) return { kind: "released" };
  return { kind: "gone", reason: result.value.reason ?? "Nothing is held for this thread." };
}

/** What "Pin" answered: pinning releases the hold on the server, so a success
    goes back to idle and the rows end the banner. */
export function holdPhaseAfterPin(outcome: "pinned" | "unsupported" | "failed"): HoldPhase {
  switch (outcome) {
    case "pinned":
      return { kind: "idle" };
    case "unsupported":
      return { kind: "failed", message: "This server does not support pinning yet." };
    case "failed":
      return { kind: "failed", message: "The thread could not be pinned." };
  }
}

export function runNowLabel(phase: HoldPhase, kind: HoldKind = "held"): string {
  const busy = phase.kind === "releasing" || phase.kind === "released";
  if (kind === "paused") return busy ? "Resuming..." : "Resume now";
  return busy ? "Starting..." : "Run now";
}

export function pinLabel(phase: HoldPhase): string {
  return phase.kind === "pinning" ? "Pinning..." : "Pin";
}

/** Both buttons wait while the server answers either of them. */
export function holdBannerBusy(phase: HoldPhase): boolean {
  return phase.kind === "releasing" || phase.kind === "released" || phase.kind === "pinning";
}

/** The limited line with its reset (#270 I): "Limit hit on x · resets 2:13 PM". */
export function limitedLine(summary: string, resetLabel: string | null): string {
  return resetLabel === null ? summary : `${summary} · resets ${resetLabel}`;
}

const RESET_TIME = new Intl.DateTimeFormat(undefined, { hour: "numeric", minute: "2-digit" });
const RESET_DATE = new Intl.DateTimeFormat(undefined, { month: "numeric", day: "numeric" });

/** The reset's label for {@link limitedLine} in the device's clock format
    (the phone has no timestamp setting): null with no reset, an unreadable
    one, or one already past — resume-on-limit follows a reset within a
    poll, so a past instant is stale, not upcoming. Tomorrow and later days
    say so, like the web's `formatUpcomingTimestamp`. */
export function resetLabelFor(resetsAt: string | null, nowMs: number = Date.now()): string | null {
  if (resetsAt === null) return null;
  const at = Date.parse(resetsAt);
  if (!Number.isFinite(at) || at <= nowMs) return null;
  const time = RESET_TIME.format(at);
  const now = new Date(nowMs);
  const target = new Date(at);
  const startOfToday = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
  const startOfTarget = new Date(
    target.getFullYear(),
    target.getMonth(),
    target.getDate(),
  ).getTime();
  const dayDiff = Math.round((startOfTarget - startOfToday) / 86_400_000);
  if (dayDiff <= 0) return time;
  if (dayDiff === 1) return `tomorrow at ${time}`;
  return `${RESET_DATE.format(at)} ${time}`;
}

export function holdBannerText(
  summary: string,
  phase: HoldPhase,
  kind: HoldKind = "held",
  resetLabel: string | null = null,
): { readonly description: string; readonly actionable: boolean } {
  // A limit stop has no button (#270 I): resume-on-limit continues the turn
  // itself once the account swaps; the row says which account ran out and,
  // when the SDK named it, when its window resets.
  if (kind === "limited")
    return { description: limitedLine(summary, resetLabel), actionable: false };
  switch (phase.kind) {
    case "gone":
      return {
        description:
          kind === "paused"
            ? `Nothing is paused any more (${phase.reason}). Send a message to continue.`
            : `Nothing is held any more (${phase.reason}). Send the message again.`,
        actionable: false,
      };
    case "failed":
      return { description: `${phase.message} The thread is still waiting.`, actionable: true };
    default:
      return { description: summary, actionable: true };
  }
}
