import type { DesktopBridge } from "@t3tools/contracts";
import type {
  InfinitusCommandInput,
  InfinitusSignInCodeInput,
  InfinitusSignInCodeResult,
  InfinitusSignInWindowInput,
  InfinitusSnapshot,
} from "@t3tools/contracts/infinitus";
import * as Schema from "effect/Schema";

/**
 * A fleet's sign-in inside this app (#677): the menu-bar app runs the flow
 * with no window (`signin-begin`), the desktop shell shows the provider's page
 * in a child window, and this page shows where it stands, takes the code from
 * the success page, and says how it ended. Pure — the page keeps one
 * `SignInFlow` and renders these words.
 */

const BEGIN_COMMAND = "signin-begin";
const STATUS_COMMAND = "signin-status";
const CANCEL_COMMAND = "signin-cancel";

/** How often the page asks `signin-status` while a flow runs. */
export const SIGN_IN_POLL_MS = 2_000;

export const SignInPhase = Schema.Literals([
  "starting",
  "waitingForCode",
  "waitingForToken",
  "registering",
  "done",
  "failed",
]);
export type SignInPhase = typeof SignInPhase.Type;

/** One sign-in this page started: which fleet, who to sign in again as (or
    null for a new account), the app's flow and where it stands. */
export interface SignInFlow {
  readonly fleetKey: string;
  readonly target: string | null;
  readonly flowId: string | null;
  readonly pasteCode: boolean;
  readonly phase: SignInPhase;
  readonly error: string | null;
  readonly account: string | null;
  /** The last `signin-code` refusal, shown under the code field. */
  readonly codeError: string | null;
  readonly codeBusy: boolean;
}

/** The in-app path exists on a build whose manifest lists `signin-begin`. */
export function snapshotOffersSignIn(snapshot: Pick<InfinitusSnapshot, "commands">): boolean {
  return snapshot.commands.some((command) => command.name === BEGIN_COMMAND);
}

/** The desktop shell's three sign-in methods, when this is the desktop and it
    is new enough to carry them; anything else has no in-app path. */
export interface SignInBridge {
  readonly open: (input: InfinitusSignInWindowInput) => Promise<void>;
  readonly close: (flowId: string) => Promise<void>;
  readonly submitCode: (input: InfinitusSignInCodeInput) => Promise<InfinitusSignInCodeResult>;
}

export function signInBridge(bridge: Partial<DesktopBridge> | undefined): SignInBridge | null {
  if (bridge?.openInfinitusSignIn === undefined) return null;
  if (bridge.closeInfinitusSignIn === undefined) return null;
  if (bridge.submitInfinitusSignInCode === undefined) return null;
  return {
    open: bridge.openInfinitusSignIn,
    close: bridge.closeInfinitusSignIn,
    submitCode: bridge.submitInfinitusSignInCode,
  };
}

/** `signin-begin <fleet> [--relogin <email>]`. */
export function signInBeginCommandArgs(
  fleetKey: string,
  reloginEmail: string | null,
): InfinitusCommandInput {
  return {
    command: BEGIN_COMMAND,
    args: [fleetKey],
    options: reloginEmail === null ? {} : { relogin: reloginEmail },
  };
}

export function signInStatusCommandArgs(flowId: string): InfinitusCommandInput {
  return { command: STATUS_COMMAND, args: [flowId], options: {} };
}

export function signInCancelCommandArgs(flowId: string): InfinitusCommandInput {
  return { command: CANCEL_COMMAND, args: [flowId], options: {} };
}

const BeginReply = Schema.Struct({
  flowId: Schema.String,
  url: Schema.String,
  pasteCode: Schema.Boolean,
  label: Schema.String,
});
export type SignInBeginReply = typeof BeginReply.Type;
const decodeBegin = Schema.decodeUnknownOption(BeginReply);

/** `signin-begin`'s answer, or null for anything else. */
export function signInBeginReply(result: unknown): SignInBeginReply | null {
  const decoded = decodeBegin(result);
  return decoded._tag === "Some" ? decoded.value : null;
}

const StatusReply = Schema.Struct({
  phase: SignInPhase,
  error: Schema.optionalKey(Schema.String),
  account: Schema.optionalKey(Schema.String),
});
const decodeStatus = Schema.decodeUnknownOption(StatusReply);

/** `signin-status`'s answer as the flow's next state, or null for anything
    else. */
export function signInStatusReply(
  result: unknown,
): { phase: SignInPhase; error: string | null; account: string | null } | null {
  const decoded = decodeStatus(result);
  if (decoded._tag === "None") return null;
  return {
    phase: decoded.value.phase,
    error: decoded.value.error ?? null,
    account: decoded.value.account ?? null,
  };
}

export function signInEnded(phase: SignInPhase): boolean {
  return phase === "done" || phase === "failed";
}

/** Whether the fleet's buttons take a click right now. */
export function signInBusy(flow: SignInFlow | null): boolean {
  return flow !== null && !signInEnded(flow.phase);
}

/** The line under the fleet's title while a flow runs or just ended. */
export function signInStatusText(flow: SignInFlow): string {
  const who = flow.target === null ? "" : ` as ${flow.target}`;
  switch (flow.phase) {
    case "starting":
      return "Starting the sign-in…";
    case "waitingForCode":
      return `Sign in${who} in the window, then paste the code from the success page here.`;
    case "waitingForToken":
      return flow.pasteCode ? "Checking the code…" : `Sign in${who} in the window.`;
    case "registering":
      return "Adding the account…";
    case "done":
      return flow.account === null ? "Signed in." : `Signed in as ${flow.account}.`;
    case "failed":
      return `Sign-in failed: ${flow.error ?? "the app gave no reason"}`;
  }
}

/** What a client without the in-app path says next to a fleet that has it. */
export const SIGN_IN_FROM_MAC = "Sign in from the Mac.";
