import type { DesktopBridge } from "@infinitus/contracts";
import type {
  InfinitusOAuthSignInInput,
  InfinitusOAuthSignInResult,
  InfinitusSignInCodeInput,
  InfinitusSignInCodeResult,
  InfinitusSignInRedirectListenInput,
  InfinitusSignInRedirectResult,
  InfinitusSignInWindowInput,
} from "@infinitus/contracts/infinitus";

/**
 * The desktop shell's halves of a fleet's sign-in: its child window and code hand-off (#677), its
 * stand-in for the engine's loopback listener, and its own `add-oauth` (#1213). The flow itself
 * is `@infinitus/client-runtime/state/infinitusSignIn`. Pure.
 */

/** The desktop shell's stand-in for the engine's loopback listener, when this
    is the desktop and it is new enough to carry it; anything else asks for
    the address. */
export interface RedirectSignInBridge {
  readonly listen: (
    input: InfinitusSignInRedirectListenInput,
  ) => Promise<InfinitusSignInRedirectResult>;
  readonly stop: (flowId: string) => Promise<void>;
}

export function redirectSignInBridge(
  bridge: Partial<DesktopBridge> | undefined,
): RedirectSignInBridge | null {
  if (bridge?.listenInfinitusSignInRedirect === undefined) return null;
  if (bridge.stopInfinitusSignInRedirect === undefined) return null;
  return { listen: bridge.listenInfinitusSignInRedirect, stop: bridge.stopInfinitusSignInRedirect };
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
