import type { ThreadHold } from "@t3tools/client-runtime/state/infinitusThreadHold";
import type { InfinitusReleaseThreadResult } from "@t3tools/contracts/infinitus";
import type { TimestampFormat } from "@t3tools/contracts/settings";
import * as Cause from "effect/Cause";

import { formatUpcomingTimestamp } from "../../timestampFormat";

/**
 * The held banner's pure half (#616): what "Run now" answered and what the
 * banner says for it. The banner itself leaves when the thread's rows say
 * the hold is over; these phases only cover the moments in between. A turn
 * paused by interrupt mode (#743) shares the banner: same RPC, same phases,
 * its own words.
 */
type HoldKind = ThreadHold["kind"];

/** What the banner is headed. */
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

export function runNowLabel(phase: HoldPhase, kind: HoldKind = "held"): string {
  const busy = phase.kind === "releasing" || phase.kind === "released";
  if (kind === "paused") return busy ? "Resuming..." : "Resume now";
  return busy ? "Starting..." : "Run now";
}

/** The limited line with its reset (#270 I): "Limit hit on x · resets 2:13 PM".
    The label is the caller's, in the user's timestamp format. */
export function limitedLine(summary: string, resetLabel: string | null): string {
  return resetLabel === null ? summary : `${summary} · resets ${resetLabel}`;
}

/** The reset's label for {@link limitedLine}: null with no reset, an
    unreadable one, or one already past — resume-on-limit follows a reset
    within a poll, so a past instant is stale, not upcoming. */
export function resetLabelFor(
  resetsAt: string | null,
  timestampFormat: TimestampFormat,
  nowMs: number = Date.now(),
): string | null {
  if (resetsAt === null) return null;
  const at = Date.parse(resetsAt);
  if (!Number.isFinite(at) || at <= nowMs) return null;
  return formatUpcomingTimestamp(resetsAt, timestampFormat, nowMs);
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
      return {
        description: `${kind === "paused" ? "Resume now" : "Run now"} failed: ${phase.message}`,
        actionable: true,
      };
    default:
      return { description: summary, actionable: true };
  }
}
