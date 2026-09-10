import type { InfinitusSnapshot } from "@t3tools/contracts/infinitus";
import { describe, expect, it } from "vite-plus/test";

import { lapsedSignIns, signInHeadline, signInModel, startSignInCommand } from "./signIns.logic";

const base: InfinitusSnapshot = { available: true, fleets: [], sessions: [], commands: [] };

describe("signInModel / lapsedSignIns", () => {
  it("reads an idle AWS item and a gcloud item with a device code in flight", () => {
    const models = lapsedSignIns({
      ...base,
      awsLogins: [
        { profile: "papaya", flow: "relay", pid: 4243, sessionLabel: "limitless", state: null },
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
    expect(models.map((model) => model.key)).toEqual([
      "aws:papaya|4243",
      "gcloud:me@example.com|0",
    ]);
    expect(models[0]).toMatchObject({
      provider: "aws",
      providerLabel: "AWS",
      phase: "idle",
      url: null,
    });
    expect(models[1]).toMatchObject({
      provider: "gcloud",
      phase: "waiting",
      url: "https://accounts.example/device",
      userCode: "ABCD-EFGH",
    });
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
  const item = signInModel({
    profile: "papaya",
    flow: "relay",
    pid: 4243,
    sessionLabel: "limitless",
  });

  it("names the session and the profile", () => {
    expect(signInHeadline(item)).toBe("limitless is stuck on expired AWS credentials for papaya.");
    expect(signInHeadline({ ...item, sessionLabel: null })).toBe(
      "Expired AWS credentials for papaya.",
    );
  });

  it("starts the Mac's local flow for the session that hit it, gcloud through its own verb", () => {
    expect(startSignInCommand(item)).toEqual({
      command: "aws-login",
      args: ["papaya"],
      options: { local: "true", pid: "4243" },
    });
    expect(startSignInCommand({ ...item, provider: "gcloud", pid: null })).toEqual({
      command: "gcloud-login",
      args: ["papaya"],
      options: { local: "true" },
    });
  });
});
