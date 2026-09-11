import type { InfinitusReleaseThreadResult } from "@t3tools/contracts/infinitus";
import * as Cause from "effect/Cause";

/**
 * The held banner's pure half (#616): what "Run now" answered and what the
 * banner says for it. The banner itself leaves when the thread's rows say
 * the hold is over; these phases only cover the moments in between.
 */
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

export function runNowLabel(phase: HoldPhase): string {
  return phase.kind === "releasing" || phase.kind === "released" ? "Starting..." : "Run now";
}

export function holdBannerText(
  summary: string,
  phase: HoldPhase,
): { readonly description: string; readonly actionable: boolean } {
  switch (phase.kind) {
    case "gone":
      return {
        description: `Nothing is held any more (${phase.reason}). Send the message again.`,
        actionable: false,
      };
    case "failed":
      return { description: `Run now failed: ${phase.message}`, actionable: true };
    default:
      return { description: summary, actionable: true };
  }
}
