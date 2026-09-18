import type { DesktopBridge } from "@infinitus/contracts";
import type {
  InfinitusCommandInput,
  InfinitusOAuthSignInInput,
  InfinitusOAuthSignInResult,
  InfinitusSecretInput,
  InfinitusSignInCodeInput,
  InfinitusSignInCodeResult,
  InfinitusSignInWindowInput,
  InfinitusSnapshot,
} from "@infinitus/contracts/infinitus";
import * as Schema from "effect/Schema";

/**
 * A fleet's sign-in inside this app (#677): the menu-bar app runs the flow
 * with no window (`signin-begin`), the provider's page opens in the desktop
 * shell's child window or, on any other client, from a link in a new tab
 * (#747), and this page shows where it stands, takes the code from the
 * success page, and says how it ended. The code reaches the app through the
 * shell where there is one, else through `infinitus.secret` as `signin-code
 * <flowId>` with the code on the secret channel. Pure — the page keeps one
 * `SignInFlow` and renders these words.
 */

const BEGIN_COMMAND = "signin-begin";
const STATUS_COMMAND = "signin-status";
const CANCEL_COMMAND = "signin-cancel";
const CODE_COMMAND = "signin-code";

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

/** Which half runs a flow: the menu-bar app's (#677, `signin-begin` polled
    over the socket) or this shell's own, through the engine's `add-oauth`
    (#1213). They start, cancel and end differently, so a flow says which. */
export type SignInKind = "app" | "shell";

/** One sign-in this page started: which fleet, who to sign in again as (or
    null for a new account), the app's flow and where it stands. */
export interface SignInFlow {
  readonly kind: SignInKind;
  readonly fleetKey: string;
  readonly target: string | null;
  readonly flowId: string | null;
  /** The provider's page for this device to open, when no shell window shows
      it; null while the shell has it or before the app answered. */
  readonly url: string | null;
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

/** The engine whose own `add-oauth` the desktop shell can run (#1213). The
    proxy engine declares `addOAuth` too, but its sign-in is not a loopback
    OAuth flow the shell could catch, so only this one takes the path. */
const SHELL_OAUTH_ENGINE_ID = "swapd";

export function fleetRunsShellOAuth(engineID: string): boolean {
  return engineID === SHELL_OAUTH_ENGINE_ID;
}

/** The desktop shell's own sign-in, when this is the desktop and it is new
    enough to carry it (#1213); anything else has no shell path. */
export interface OAuthSignInBridge {
  readonly begin: (input: InfinitusOAuthSignInInput) => Promise<InfinitusOAuthSignInResult>;
  readonly cancel: (flowId: string) => Promise<void>;
}

export function oauthSignInBridge(
  bridge: Partial<DesktopBridge> | undefined,
): OAuthSignInBridge | null {
  if (bridge?.beginInfinitusOAuthSignIn === undefined) return null;
  if (bridge.cancelInfinitusOAuthSignIn === undefined) return null;
  return { begin: bridge.beginInfinitusOAuthSignIn, cancel: bridge.cancelInfinitusOAuthSignIn };
}

/** Which sign-in a fleet's section draws. `inApp` is a flow this client runs —
    the shell's own `add-oauth` (#1213) or the app's in-app sign-in (#677) —
    and `canAdd` the older hand-off to the Mac (#672). The shell's path asks the
    app for nothing, so the `addOAuth` capability does not gate it: a fleet that
    never advertised it is the case #1213 exists for. */
export function fleetSignInGate(input: {
  /** This shell can run this fleet's own `add-oauth`. */
  readonly shellOAuth: boolean;
  /** The running build lists `signin-begin`. */
  readonly offers: boolean;
  /** This client can show the app's flow itself. */
  readonly inApp: boolean;
  /** The running build lists `add`. */
  readonly offersAdd: boolean;
  /** The fleet advertises `addOAuth`. */
  readonly canAdd: boolean;
}): { readonly inApp: boolean; readonly canAdd: boolean } {
  return {
    inApp: input.shellOAuth || (input.offers && input.inApp && input.canAdd),
    canAdd: !input.offers && !input.shellOAuth && input.offersAdd && input.canAdd,
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

/** `signin-code <flowId>` for `infinitus.secret`; the page adds the code as
    `secret` (#747). `flowId` is the manifest's bare name for `<flowId>`. */
export function signInCodeSecretArgs(flowId: string): Omit<InfinitusSecretInput, "secret"> {
  return { command: CODE_COMMAND, args: { flowId } };
}

const CodeReply = Schema.Struct({
  ok: Schema.Boolean,
  error: Schema.optionalKey(Schema.String),
});
const decodeCode = Schema.decodeUnknownOption(CodeReply);

/** `signin-code`'s answer, or null for anything else. The error is the
    CLI's own wording; the code itself never comes back. */
export function signInCodeReply(result: unknown): InfinitusSignInCodeResult | null {
  const decoded = decodeCode(result);
  if (decoded._tag === "None") return null;
  return {
    ok: decoded.value.ok,
    ...(decoded.value.error === undefined ? {} : { error: decoded.value.error }),
  };
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
  // A shell flow (#1213) runs in the system browser, so passkeys work; the
  // app's own (#677) is the desktop's child window or a link on this page.
  const where =
    flow.kind === "shell"
      ? "in your browser"
      : flow.url === null
        ? "in the window"
        : "on the sign-in page";
  switch (flow.phase) {
    case "starting":
      return "Starting the sign-in…";
    case "waitingForCode":
      return `Sign in${who} ${where}, then paste the code from the success page here.`;
    case "waitingForToken":
      return flow.pasteCode ? "Checking the code…" : `Sign in${who} ${where}.`;
    case "registering":
      return "Adding the account…";
    case "done":
      return flow.account === null ? "Signed in." : `Signed in as ${flow.account}.`;
    case "failed":
      return `Sign-in failed: ${flow.error ?? "the app gave no reason"}`;
  }
}
