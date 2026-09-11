import { EnvironmentId } from "@t3tools/contracts";
import { describe, expect, it } from "vite-plus/test";

import { forgetCommand, LIVE_ACTIVITY_TOKEN_KINDS } from "./liveActivity.logic";
import { forgetTokens, macToForget } from "./pushForget.logic";

const mac = EnvironmentId.make("mac-1");

describe("forgetCommand", () => {
  it("names the slot the Mac keys registrations by", () => {
    expect(forgetCommand("dev-1", "alert")).toEqual({
      command: "activities-token",
      args: [],
      options: { forget: "dev-1/alert" },
    });
  });
});

describe("macToForget", () => {
  const on = { enabled: true, environmentId: mac };
  const off = { enabled: false, environmentId: mac };

  it("fires only on an on → off with a Mac that was driving the phone", () => {
    expect(macToForget(on, off)).toBe(mac);
    expect(macToForget(on, { enabled: false, environmentId: null })).toBe(mac);
  });

  it("stays quiet on the first loaded state, while off, while on, and with no prior Mac", () => {
    expect(macToForget(null, on)).toBeNull();
    expect(macToForget(null, off)).toBeNull();
    expect(macToForget(off, off)).toBeNull();
    expect(macToForget(on, on)).toBeNull();
    expect(macToForget(off, on)).toBeNull();
    expect(macToForget({ enabled: true, environmentId: null }, off)).toBeNull();
  });

  it("treats unloaded preferences as no state", () => {
    expect(macToForget(on, null)).toBeNull();
  });
});

describe("forgetTokens", () => {
  it("withdraws every kind under the phone's device id", async () => {
    const sent: string[] = [];
    await forgetTokens({
      environmentId: mac,
      kinds: LIVE_ACTIVITY_TOKEN_KINDS,
      run: async (input) => {
        sent.push(`${input.environmentId}:${input.input.options.forget}`);
        return { _tag: "Success" };
      },
      loadDeviceId: async () => "dev-1",
    });
    expect(sent.sort()).toEqual([
      "mac-1:dev-1/revival",
      "mac-1:dev-1/revival-start",
      "mac-1:dev-1/working",
      "mac-1:dev-1/working-start",
    ]);
  });

  it("swallows a refusing Mac and a missing device id", async () => {
    await expect(
      forgetTokens({
        environmentId: mac,
        kinds: ["alert"],
        run: async () => {
          throw new Error("refused");
        },
        loadDeviceId: async () => "dev-1",
      }),
    ).resolves.toBeUndefined();
    let ran = 0;
    await forgetTokens({
      environmentId: mac,
      kinds: ["alert"],
      run: async () => {
        ran += 1;
        return {};
      },
      loadDeviceId: async () => {
        throw new Error("no storage");
      },
    });
    expect(ran).toBe(0);
  });
});
