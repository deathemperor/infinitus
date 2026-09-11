import { describe, expect, it } from "vite-plus/test";

import {
  ADD_ACCOUNT_LIMIT_MS,
  addAccountBusy,
  addAccountButtonLabel,
  addAccountStatus,
  waitAddStep,
  type AddAccountFlow,
} from "./addAccount.logic";

const flow = (phase: AddAccountFlow["phase"], target: string | null = null): AddAccountFlow => ({
  fleetKey: "cswap/claude",
  target,
  phase,
});

describe("addAccountButtonLabel", () => {
  it("adds a new account and signs a lapsed one in again", () => {
    expect(addAccountButtonLabel(null)).toBe("Add account");
    expect(addAccountButtonLabel("golf")).toBe("Sign in again");
  });
});

describe("waitAddStep", () => {
  it("keeps polling on the app's timed-out refusal until the page's limit", () => {
    expect(waitAddStep({ failure: "timed out after 5s" }, 10_000)).toEqual({ kind: "poll" });
    expect(waitAddStep({ failure: "timed out after 5s" }, ADD_ACCOUNT_LIMIT_MS)).toEqual({
      kind: "failed",
      message: "The sign-in did not finish within five minutes.",
    });
  });

  it("stops on any other refusal with the app's own words", () => {
    expect(waitAddStep({ failure: "The sign-in was cancelled." }, 0)).toEqual({
      kind: "failed",
      message: "The sign-in was cancelled.",
    });
  });

  it("reads a finished, a failed and a still-running reply", () => {
    expect(waitAddStep({ result: { done: true, error: null, fleets: [] } }, 0)).toEqual({
      kind: "done",
    });
    expect(waitAddStep({ result: { done: true, error: "Login cancelled." } }, 0)).toEqual({
      kind: "failed",
      message: "Login cancelled.",
    });
    expect(waitAddStep({ result: { done: false } }, 0)).toEqual({ kind: "poll" });
  });

  it("fails on a reply that is not a wait-add answer", () => {
    expect(waitAddStep({ result: "nope" }, 0)).toEqual({
      kind: "failed",
      message: "Infinitus answered unexpectedly.",
    });
  });
});

describe("addAccountStatus", () => {
  it("says nothing when idle and names a sign-in running elsewhere", () => {
    expect(addAccountStatus(null, false)).toBeNull();
    expect(addAccountStatus(null, true)).toBe("A sign-in is already running in Infinitus.");
  });

  it("follows the page's own flow, naming the re-login target while waiting", () => {
    expect(addAccountStatus(flow({ kind: "starting" }), false)).toBe(
      "Opening the sign-in on the Mac…",
    );
    expect(addAccountStatus(flow({ kind: "waiting" }), true)).toBe("Sign-in running on the Mac…");
    expect(addAccountStatus(flow({ kind: "waiting" }, "golf"), true)).toBe(
      "Sign-in running on the Mac — sign in as golf.",
    );
    expect(addAccountStatus(flow({ kind: "done" }), false)).toBe("Sign-in finished.");
    expect(addAccountStatus(flow({ kind: "failed", message: "Login cancelled." }), false)).toBe(
      "Sign-in failed: Login cancelled.",
    );
  });
});

describe("addAccountBusy", () => {
  it("is busy while the app runs a sign-in or the page waits on one", () => {
    expect(addAccountBusy(null, false)).toBe(false);
    expect(addAccountBusy(null, true)).toBe(true);
    expect(addAccountBusy(flow({ kind: "starting" }), false)).toBe(true);
    expect(addAccountBusy(flow({ kind: "waiting" }), false)).toBe(true);
    expect(addAccountBusy(flow({ kind: "done" }), false)).toBe(false);
    expect(addAccountBusy(flow({ kind: "failed", message: "x" }), false)).toBe(false);
  });
});
