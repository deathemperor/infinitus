import {
  WAIT_ADD_STILL_RUNNING,
  waitAddOutcome,
} from "@t3tools/client-runtime/state/infinitusAccounts";

/**
 * Add account / re-login as the page runs it: `add <fleet>` puts the app's own
 * sign-in on the Mac's screen, then the page polls `wait-add` in short steps
 * until the app says the flow ended. Pure, so the page only keeps the flow
 * record and renders these words.
 */

/** How long one `wait-add` poll may hold the socket — under the server's
    ten-second command timeout with room for the round trip. */
export const WAIT_ADD_STEP_SECONDS = 5;

/** How long the page keeps polling before it gives up on the sign-in. Native's
    own `wait-add` default is the same five minutes. */
export const ADD_ACCOUNT_LIMIT_MS = 300_000;

export type AddAccountPhase =
  | { readonly kind: "starting" }
  | { readonly kind: "waiting" }
  | { readonly kind: "done" }
  | { readonly kind: "failed"; readonly message: string };

/** One sign-in the page started: which fleet, who to sign in as (a re-login)
    or null for a new account, and where it stands. */
export interface AddAccountFlow {
  readonly fleetKey: string;
  readonly target: string | null;
  readonly phase: AddAccountPhase;
}

/** A new account is added; a lapsed one is signed in again. */
export function addAccountButtonLabel(target: string | null): string {
  return target === null ? "Add account" : "Sign in again";
}

/** What one `wait-add` answer means for the loop: keep polling, stop on a
    finished sign-in, or stop on its failure. A refusal that only says the
    window closed ("timed out after 5s") is the app still waiting, until the
    page's own limit passes. */
export type WaitAddStep =
  | { readonly kind: "poll" }
  | { readonly kind: "done" }
  | { readonly kind: "failed"; readonly message: string };

export function waitAddStep(
  answer: { readonly result: unknown } | { readonly failure: string },
  elapsedMs: number,
): WaitAddStep {
  if ("failure" in answer) {
    if (!WAIT_ADD_STILL_RUNNING.test(answer.failure)) {
      return { kind: "failed", message: answer.failure };
    }
    return elapsedMs >= ADD_ACCOUNT_LIMIT_MS
      ? { kind: "failed", message: "The sign-in did not finish within five minutes." }
      : { kind: "poll" };
  }
  const outcome = waitAddOutcome(answer.result);
  if (outcome === null) return { kind: "failed", message: "Infinitus answered unexpectedly." };
  if (outcome.error !== null) return { kind: "failed", message: outcome.error };
  return outcome.done ? { kind: "done" } : { kind: "poll" };
}

/** The line under a fleet's title while something is happening to it: the
    page's own flow first, then the app's word that a sign-in runs elsewhere. */
export function addAccountStatus(
  flow: AddAccountFlow | null,
  signInRunning: boolean,
): string | null {
  if (flow === null) {
    return signInRunning ? "A sign-in is already running in Infinitus." : null;
  }
  switch (flow.phase.kind) {
    case "starting":
      return "Opening the sign-in on the Mac…";
    case "waiting":
      return flow.target === null
        ? "Sign-in running on the Mac…"
        : `Sign-in running on the Mac — sign in as ${flow.target}.`;
    case "done":
      return "Sign-in finished.";
    case "failed":
      return `Sign-in failed: ${flow.phase.message}`;
  }
}

/** Whether a fleet's add and re-login buttons take a click right now. */
export function addAccountBusy(flow: AddAccountFlow | null, signInRunning: boolean): boolean {
  if (signInRunning) return true;
  return flow !== null && (flow.phase.kind === "starting" || flow.phase.kind === "waiting");
}
