import type { InfinitusLaunchResult } from "@t3tools/contracts/infinitus";
import type * as Cause from "effect/Cause";

import { infinitusCommandFailure } from "./panel.logic";

/** Where the "Launch Infinitus" button is: idle, waiting on the RPC, told the
    app was asked to open, told why it was not, or the RPC itself failed. */
export type LaunchPhase =
  | { readonly kind: "idle" }
  | { readonly kind: "launching" }
  | { readonly kind: "launched" }
  | { readonly kind: "declined"; readonly reason: string }
  | { readonly kind: "failed"; readonly message: string };

export function launchPhaseAfter(
  result:
    | { readonly _tag: "Success"; readonly value: InfinitusLaunchResult }
    | { readonly _tag: "Failure"; readonly cause: Cause.Cause<unknown> },
): LaunchPhase {
  if (result._tag === "Failure") {
    return { kind: "failed", message: infinitusCommandFailure(result.cause).message };
  }
  if (result.value.launched) return { kind: "launched" };
  return { kind: "declined", reason: result.value.reason ?? "Infinitus was not launched." };
}

export function launchButtonLabel(phase: LaunchPhase): string {
  return phase.kind === "launching" ? "Launching…" : "Launch Infinitus";
}

/** What to say under the button, or nothing while idle or launching. The
    launched line hedges on purpose: the page only learns the app is up when
    the snapshot flips, a few seconds later. */
export function launchNotice(phase: LaunchPhase): string | null {
  switch (phase.kind) {
    case "launched":
      return "Infinitus is starting. This page updates once it answers.";
    case "declined":
      return phase.reason;
    case "failed":
      return phase.message;
    default:
      return null;
  }
}
