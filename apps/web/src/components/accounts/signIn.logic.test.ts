import { describe, expect, it } from "vite-plus/test";

import {
  fleetRunsShellOAuth,
  fleetSignInGate,
  oauthSignInBridge,
  signInBeginCommandArgs,
  signInBeginReply,
  signInBridge,
  signInBusy,
  signInCancelCommandArgs,
  signInCodeReply,
  signInCodeSecretArgs,
  signInStatusCommandArgs,
  signInStatusReply,
  signInStatusText,
  snapshotOffersSignIn,
  type SignInFlow,
} from "./signIn.logic";

const flow = (over: Partial<SignInFlow>): SignInFlow => ({
  kind: "app",
  fleetKey: "swapd/claude",
  target: null,
  flowId: "f1",
  url: null,
  pasteCode: true,
  phase: "starting",
  error: null,
  account: null,
  codeError: null,
  codeBusy: false,
  ...over,
});

describe("snapshotOffersSignIn / signInBridge", () => {
  it("needs signin-begin in the manifest and all three shell methods", () => {
    expect(snapshotOffersSignIn({ commands: [] })).toBe(false);
    expect(snapshotOffersSignIn({ commands: [{ name: "signin-begin" }] as never })).toBe(true);
    expect(signInBridge(undefined)).toBeNull();
    expect(signInBridge({ openInfinitusSignIn: async () => {} })).toBeNull();
    const full = signInBridge({
      openInfinitusSignIn: async () => {},
      closeInfinitusSignIn: async () => {},
      submitInfinitusSignInCode: async () => ({ ok: true }),
    });
    expect(full).not.toBeNull();
  });
});

describe("the shell's own sign-in (#1213)", () => {
  it("needs both shell methods, and only the loopback engine takes the path", () => {
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

  it("runs whatever the fleet advertises, since it asks the app for nothing", () => {
    const gate = (over: Parameters<typeof fleetSignInGate>[0]) => fleetSignInGate(over);
    // The bug this feature is for: the fleet advertises no `addOAuth`, so both
    // of the app's paths are shut and the page drew no button at all.
    const shut = { shellOAuth: false, offers: true, inApp: true, offersAdd: true, canAdd: false };
    expect(gate(shut)).toEqual({ inApp: false, canAdd: false });
    expect(gate({ ...shut, shellOAuth: true })).toEqual({ inApp: true, canAdd: false });
    // With the capability the app's own flow runs, and the shell's still wins.
    expect(gate({ ...shut, canAdd: true })).toEqual({ inApp: true, canAdd: false });
    // No `signin-begin` in the manifest: the hand-off to the Mac (#672).
    expect(gate({ ...shut, offers: false, canAdd: true })).toEqual({
      inApp: false,
      canAdd: true,
    });
    expect(gate({ ...shut, offers: false, canAdd: true, shellOAuth: true })).toEqual({
      inApp: true,
      canAdd: false,
    });
  });

  it("sends the user to the browser, since there is no page link and no code", () => {
    const shell = flow({ kind: "shell", url: null, pasteCode: false, phase: "waitingForToken" });
    expect(signInStatusText(shell)).toBe("Sign in in the private window that opened.");
    expect(signInStatusText({ ...shell, target: "two@example.com" })).toBe(
      "Sign in as two@example.com in the private window that opened.",
    );
  });
});

describe("command args and replies", () => {
  it("begins with the fleet and the re-login email as an option", () => {
    expect(signInBeginCommandArgs("swapd/claude", null)).toEqual({
      command: "signin-begin",
      args: ["swapd/claude"],
      options: {},
    });
    expect(signInBeginCommandArgs("swapd/claude", "two@example.com").options).toEqual({
      relogin: "two@example.com",
    });
    expect(signInStatusCommandArgs("f1")).toEqual({
      command: "signin-status",
      args: ["f1"],
      options: {},
    });
    expect(signInCancelCommandArgs("f1")).toEqual({
      command: "signin-cancel",
      args: ["f1"],
      options: {},
    });
  });

  it("reads the app's begin and status replies, null for anything else", () => {
    expect(
      signInBeginReply({ flowId: "f1", url: "https://x", pasteCode: true, label: "Add account" }),
    ).toEqual({ flowId: "f1", url: "https://x", pasteCode: true, label: "Add account" });
    expect(signInBeginReply({ started: true })).toBeNull();
    expect(signInStatusReply({ flowId: "f1", phase: "waitingForCode", pasteCode: true })).toEqual({
      phase: "waitingForCode",
      error: null,
      account: null,
    });
    expect(
      signInStatusReply({ phase: "done", account: "two@example.com", pasteCode: true }),
    ).toEqual({ phase: "done", error: null, account: "two@example.com" });
    expect(signInStatusReply({ phase: "failed", error: "cancelled" })?.error).toBe("cancelled");
    expect(signInStatusReply({ phase: "sideways" })).toBeNull();
    expect(signInStatusReply("nope")).toBeNull();
  });
});

describe("signInStatusText / signInBusy", () => {
  it("names each phase, the re-login target and the outcome", () => {
    expect(signInStatusText(flow({ phase: "starting" }))).toBe("Starting the sign-in…");
    expect(signInStatusText(flow({ phase: "waitingForCode", target: "golf" }))).toBe(
      "Sign in as golf in the window, then paste the code from the success page here.",
    );
    expect(signInStatusText(flow({ phase: "waitingForToken" }))).toBe("Checking the code…");
    expect(signInStatusText(flow({ phase: "waitingForToken", pasteCode: false }))).toBe(
      "Sign in in the window.",
    );
    expect(signInStatusText(flow({ phase: "registering" }))).toBe("Adding the account…");
    expect(signInStatusText(flow({ phase: "done", account: "two@example.com" }))).toBe(
      "Signed in as two@example.com.",
    );
    expect(signInStatusText(flow({ phase: "failed", error: "Invalid code" }))).toBe(
      "Sign-in failed: Invalid code",
    );
  });

  it("is busy until the flow ends", () => {
    expect(signInBusy(null)).toBe(false);
    expect(signInBusy(flow({ phase: "waitingForCode" }))).toBe(true);
    expect(signInBusy(flow({ phase: "done" }))).toBe(false);
    expect(signInBusy(flow({ phase: "failed" }))).toBe(false);
  });

  it("hands the code to infinitus.secret as signin-code and reads the CLI's answer (#747)", () => {
    expect(signInCodeSecretArgs("f1")).toEqual({ command: "signin-code", args: { flowId: "f1" } });
    expect(signInCodeReply({ ok: true })).toEqual({ ok: true });
    expect(signInCodeReply({ ok: false, error: "Invalid code" })).toEqual({
      ok: false,
      error: "Invalid code",
    });
    expect(signInCodeReply({ state: "done" })).toBeNull();
    expect(signInCodeReply(undefined)).toBeNull();
  });

  it("says where to sign in: the shell's window, or the page this device opened", () => {
    const flow = {
      kind: "app" as const,
      fleetKey: "claude",
      target: null,
      flowId: "f1",
      url: null,
      pasteCode: true,
      phase: "waitingForCode" as const,
      error: null,
      account: null,
      codeError: null,
      codeBusy: false,
    };
    expect(signInStatusText(flow)).toBe(
      "Sign in in the window, then paste the code from the success page here.",
    );
    expect(signInStatusText({ ...flow, url: "https://claude.ai/oauth" })).toBe(
      "Sign in on the sign-in page, then paste the code from the success page here.",
    );
    expect(
      signInStatusText({
        ...flow,
        url: "https://claude.ai/oauth",
        pasteCode: false,
        phase: "waitingForToken",
      }),
    ).toBe("Sign in on the sign-in page.");
  });
});
