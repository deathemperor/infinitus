/**
 * The user agent the browser preview shows a sign-in provider.
 *
 * Google answers Electron's native agent (`Infinitus/… Electron/…`) with its
 * embedded-browser flow (`flowName=WebLiteSignIn` instead of `GlifWebSignIn`),
 * and a "Sign in with Google" pop-up opened from a preview page ends on
 * "400. That's an error… malformed". The flow is chosen by the first request's
 * header, so the fix has to be on the wire before the pop-up exists.
 *
 * It cannot be the session's agent: any session-wide rewrite makes Cloudflare
 * Turnstile loop with error 600010 (#5002, pinned in `BrowserSession.test.ts`).
 * So only requests to the provider's own host are rewritten — every other host,
 * and `navigator.userAgent` everywhere, keep the native agent. A pop-up opened
 * with `action: "allow"` stays in the guest's session, so this reaches it.
 *
 * Electron keeps ONE `onBeforeSendHeaders` listener per session: a second
 * registration on a preview session silently replaces this one.
 */
import type { Session } from "electron";

import { signInUserAgent } from "./signInUserAgent.ts";

/** Hosts known to refuse the native agent. Add one only with evidence it fails. */
export const PREVIEW_OAUTH_URLS = ["https://accounts.google.com/*"];

export const withSignInUserAgent = (
  requestHeaders: Record<string, string>,
  nativeUserAgent: string,
): Record<string, string> => ({
  ...Object.fromEntries(
    Object.entries(requestHeaders).filter(([name]) => name.toLowerCase() !== "user-agent"),
  ),
  "User-Agent": signInUserAgent(nativeUserAgent),
});

export const installPreviewOAuthUserAgent = (browserSession: Session): void => {
  const nativeUserAgent = browserSession.getUserAgent();
  browserSession.webRequest.onBeforeSendHeaders(
    { urls: PREVIEW_OAUTH_URLS },
    (details, callback) => {
      callback({ requestHeaders: withSignInUserAgent(details.requestHeaders, nativeUserAgent) });
    },
  );
};
