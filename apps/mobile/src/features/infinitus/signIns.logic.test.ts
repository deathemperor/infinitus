import type { InfinitusSnapshot } from "@t3tools/contracts/infinitus";
import { describe, expect, it } from "vite-plus/test";

import { lapsedSignIns, signInHeadline, signInModel, startSignInCommand } from "./signIns.logic";

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
      url: null,
    });
    expect(models[1]).toMatchObject({
      provider: "gcloud",
      phase: "waiting",
      url: "https://accounts.example/device",
      userCode: "ABCD-EFGH",
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

  it("starts the Mac's local flow, gcloud through its own verb, with no session scope", () => {
    expect(startSignInCommand(item)).toEqual({
      command: "aws-login",
      args: ["papaya"],
      options: { local: "true" },
    });
    expect(startSignInCommand({ ...item, provider: "gcloud" })).toEqual({
      command: "gcloud-login",
      args: ["papaya"],
      options: { local: "true" },
    });
  });
});
