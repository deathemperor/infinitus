import { describe, expect, it } from "vite-plus/test";

import {
  fleetRunsShellOAuth,
  oauthSignInBridge,
  redirectSignInBridge,
  signInBridge,
} from "./signIn.logic";

describe("the desktop shell's sign-in bridges", () => {
  it("needs all three shell methods for its window", () => {
    expect(signInBridge(undefined)).toBeNull();
    expect(signInBridge({ openInfinitusSignIn: async () => {} })).toBeNull();
    const full = signInBridge({
      openInfinitusSignIn: async () => {},
      closeInfinitusSignIn: async () => {},
      submitInfinitusSignInCode: async () => ({ ok: true }),
    });
    expect(full).not.toBeNull();
  });

  it("needs both shell methods, and only the loopback engine takes the path (#1213)", () => {
    expect(oauthSignInBridge(undefined)).toBeNull();
    expect(oauthSignInBridge({ beginInfinitusOAuthSignIn: async () => ({ ok: true }) })).toBeNull();
    expect(oauthSignInBridge({ cancelInfinitusOAuthSignIn: async () => {} })).toBeNull();
    expect(
      oauthSignInBridge({
        beginInfinitusOAuthSignIn: async () => ({ ok: true }),
        cancelInfinitusOAuthSignIn: async () => {},
      }),
    ).not.toBeNull();
    expect(fleetRunsShellOAuth("swapd")).toBe(true);
    // The proxy engine declares addOAuth too; its sign-in is not this flow.
    expect(fleetRunsShellOAuth("proxy")).toBe(false);
  });

  it("finds the shell's stand-in only when both of its methods are there", () => {
    expect(redirectSignInBridge(undefined)).toBeNull();
    expect(
      redirectSignInBridge({ listenInfinitusSignInRedirect: async () => ({ ok: true }) }),
    ).toBeNull();
    const listen = async () => ({ ok: true });
    const stop = async () => {};
    expect(
      redirectSignInBridge({
        listenInfinitusSignInRedirect: listen,
        stopInfinitusSignInRedirect: stop,
      }),
    ).toEqual({ listen, stop });
  });
});
