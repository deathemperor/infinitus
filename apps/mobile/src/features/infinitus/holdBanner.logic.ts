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
      return { description: `${phase.message} The thread is still waiting.`, actionable: true };
    default:
      return { description: summary, actionable: true };
  }
}
