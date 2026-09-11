import type { ThreadHold } from "@t3tools/client-runtime/state/infinitusThreadHold";
import type { InfinitusReleaseThreadResult } from "@t3tools/contracts/infinitus";
import * as Cause from "effect/Cause";

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
  return kind === "paused" ? "Paused for headroom" : "Waiting for headroom";
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

export function holdBannerText(
  summary: string,
  phase: HoldPhase,
  kind: HoldKind = "held",
): { readonly description: string; readonly actionable: boolean } {
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
