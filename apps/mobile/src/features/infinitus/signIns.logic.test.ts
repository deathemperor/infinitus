import type { InfinitusSnapshot } from "@t3tools/contracts/infinitus";
import { describe, expect, it } from "vite-plus/test";

import {
  isValidSignInCode,
  lapsedSignIns,
  signInCallbackPort,
  signInCallbackSecretArgs,
  signInCodeSecretArgs,
  signInHeadline,
  signInModel,
  signInTakesCode,
  startSignInCommand,
} from "./signIns.logic";

const base: InfinitusSnapshot = { available: true, fleets: [], commands: [] };

describe("signInModel / lapsedSignIns", () => {
  it("reads an idle AWS item and a gcloud item with a device code in flight", () => {
    const models = lapsedSignIns({
      ...base,
      awsLogins: [
        { profile: "papaya", flow: "relay", state: null },
        {
          profile: "me@example.com",
          provider: "gcloud",
          flow: "deviceCode",
          state: {
            profile: "me@example.com",
            flow: "deviceCode",
            phase: "waitingForBrowser",
            url: "https://accounts.example/device",
            userCode: "ABCD-EFGH",
            startedAt: 1,
          },
        },
      ],
    });
    expect(models.map((model) => model.key)).toEqual(["aws:papaya", "gcloud:me@example.com"]);
    expect(models[0]).toMatchObject({
      provider: "aws",
      providerLabel: "AWS",
      phase: "idle",
      flow: "relay",
      url: null,
      account: null,
    });
    expect(models[1]).toMatchObject({
      provider: "gcloud",
      phase: "waiting",
      flow: "deviceCode",
      url: "https://accounts.example/device",
      userCode: "ABCD-EFGH",
    });
  });

  it("reads the running login's flow over the item's, and the page's account", () => {
    // The item says what the Mac would start; a login already running says
    // what it did start — the phone asked for a code over the relay.
    const model = signInModel({
      profile: "papaya",
      flow: "relay",
      account: { accountId: "123456789012", userName: "deathemperor" },
      state: { profile: "papaya", flow: "remote", phase: "waitingForCode", startedAt: 1 },
    });
    expect(model).toMatchObject({
      flow: "remote",
      phase: "waiting",
      account: { accountId: "123456789012", userName: "deathemperor" },
    });
    expect(signInModel({ profile: "p", flow: "sso", account: { accountId: "1" } })).toMatchObject({
      flow: "unknown",
      account: { accountId: "1", userName: null },
    });
  });

  it("folds two entries for one profile into the row whose login is running (#1041)", () => {
    // Two sessions used to tell these apart by pid; with the tracker gone they
    // are the same row, and the one carrying the login is the one to draw.
    const models = lapsedSignIns({
      ...base,
      awsLogins: [
        { profile: "papaya", flow: "relay", state: null },
        {
          profile: "papaya",
          flow: "relay",
          state: { profile: "papaya", flow: "relay", phase: "starting", startedAt: 1 },
        },
      ],
    });

    expect(models).toHaveLength(1);
    expect(models[0]).toMatchObject({ key: "aws:papaya", phase: "starting" });
  });

  it.each([
    ["the finished entry first", true],
    ["the lapsed entry first", false],
  ])("keeps a still-lapsed profile that also carries a finished login, %s", (_label, doneFirst) => {
    // The credentials are still expired, so the row has to stay and stay
    // actionable. Ranking on "has a state" would have let the finished login
    // win and the done filter would then have deleted the profile outright.
    const lapsed = { profile: "papaya", flow: "relay", state: null };
    const done = {
      profile: "papaya",
      flow: "relay",
      state: { profile: "papaya", flow: "relay", phase: "done", startedAt: 1 },
    };
    const models = lapsedSignIns({
      ...base,
      awsLogins: doneFirst ? [done, lapsed] : [lapsed, done],
    });

    expect(models).toHaveLength(1);
    expect(models[0]).toMatchObject({ key: "aws:papaya", phase: "idle" });
  });

  it("drops finished sign-ins and answers nothing without the field or while unavailable", () => {
    const done = {
      profile: "papaya",
      flow: "local",
      state: { profile: "papaya", flow: "local", phase: "done", startedAt: 1 },
    };
    expect(lapsedSignIns({ ...base, awsLogins: [done] })).toEqual([]);
    expect(lapsedSignIns(base)).toEqual([]);
    expect(lapsedSignIns({ ...base, available: false, awsLogins: [done] })).toEqual([]);
    expect(lapsedSignIns(null)).toEqual([]);
  });

  it("reads an unknown phase as waiting rather than dropping the item", () => {
    expect(
      signInModel({
        profile: "p",
        flow: "relay",
        state: { profile: "p", flow: "relay", phase: "levitating", startedAt: 1 },
      }).phase,
    ).toBe("waiting");
  });
});

describe("signInHeadline / startSignInCommand", () => {
  const item = signInModel({ profile: "papaya", flow: "relay" });

  it("names the credentials and the profile, never a session (#1041)", () => {
    expect(signInHeadline(item)).toBe("Expired AWS credentials for papaya.");
    expect(signInHeadline({ ...item, provider: "gcloud", providerLabel: "gcloud" })).toBe(
      "Expired gcloud credentials for papaya.",
    );
  });

  it("asks for the code flow by default: the page ends with a code pasted back here", () => {
    expect(startSignInCommand(item, "code")).toEqual({
      command: "aws-login",
      args: ["papaya"],
      options: { remote: "true" },
    });
    expect(startSignInCommand({ ...item, provider: "gcloud" }, "code")).toEqual({
      command: "gcloud-login",
      args: ["papaya"],
      options: { remote: "true" },
    });
  });

  it("leaves the Mac its own flow — the relay one — when the phone catches the redirect", () => {
    expect(startSignInCommand(item, "catch")).toEqual({
      command: "aws-login",
      args: ["papaya"],
      options: {},
    });
  });

  it("offers the code flow to every row but an SSO profile's", () => {
    expect(signInTakesCode(item)).toBe(true);
    expect(signInTakesCode({ ...item, flow: "local" })).toBe(true);
    expect(signInTakesCode({ ...item, flow: "remote" })).toBe(true);
    expect(signInTakesCode({ ...item, flow: "deviceCode" })).toBe(false);
  });
});

describe("isValidSignInCode / signInCodeSecretArgs", () => {
  const item = signInModel({ profile: "papaya", flow: "relay" });

  it("takes what the Mac's own check takes", () => {
    expect(isValidSignInCode("abc-DEF_123+/=")).toBe(true);
    expect(isValidSignInCode("a".repeat(8192))).toBe(true);
    expect(isValidSignInCode("")).toBe(false);
    expect(isValidSignInCode("a".repeat(8193))).toBe(false);
    expect(isValidSignInCode("abc def")).toBe(false);
    expect(isValidSignInCode("héllo")).toBe(false);
  });

  it("names the CLI's own code verb, with gcloud's positional as the manifest spells it", () => {
    expect(signInCodeSecretArgs(item)).toEqual({
      command: "aws-login-code",
      args: { profile: "papaya" },
    });
    expect(
      signInCodeSecretArgs({ ...item, provider: "gcloud", profile: "me@example.com" }),
    ).toEqual({
      command: "gcloud-login-code",
      args: { account: "me@example.com" },
    });
  });
});

describe("signInCallbackPort / signInCallbackSecretArgs", () => {
  const item = signInModel({ profile: "papaya", flow: "relay" });

  it("takes the port the relay flow reported", () => {
    expect(signInCallbackPort({ ...item, callbackPort: 8085 })).toBe(8085);
    expect(signInCallbackPort({ ...item, callbackPort: 60861 })).toBe(60861);
  });

  it("answers null for a flow with no loopback redirect and for nonsense", () => {
    // A device-code login, a login the Mac has not started, or an app too old
    // to report the port: there is nothing for this phone to bind.
    expect(signInCallbackPort(item)).toBeNull();
    expect(signInCallbackPort({ ...item, callbackPort: 0 })).toBeNull();
    expect(signInCallbackPort({ ...item, callbackPort: 70000 })).toBeNull();
    expect(signInCallbackPort({ ...item, callbackPort: 8085.5 })).toBeNull();
  });

  it("hands the Mac one verb for both CLIs, the URL never an argument", () => {
    expect(signInCallbackSecretArgs(item)).toEqual({
      command: "aws-login-callback",
      args: { profile: "papaya" },
    });
    expect(signInCallbackSecretArgs({ ...item, provider: "gcloud" })).toEqual({
      command: "aws-login-callback",
      args: { profile: "papaya" },
    });
  });
});
