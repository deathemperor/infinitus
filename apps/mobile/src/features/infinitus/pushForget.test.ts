import { EnvironmentId } from "@t3tools/contracts";
import * as Cause from "effect/Cause";
import { describe, expect, it } from "vite-plus/test";

import { forgetCommand } from "./liveActivity.logic";
import { forgetTokensOutcome, macToForget } from "./pushForget.logic";

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

describe("forgetTokensOutcome", () => {
  it("withdraws every kind under the phone's device id", async () => {
    const sent: string[] = [];
    const outcome = await forgetTokensOutcome({
      environmentId: mac,
      kinds: ["agent-activity-start", "agent-activity"],
      run: async (input) => {
        sent.push(`${input.environmentId}:${input.input.options.forget}`);
        return { _tag: "Success" };
      },
      loadDeviceId: async () => "dev-1",
    });
    expect(sent).toEqual(["mac-1:dev-1/agent-activity-start", "mac-1:dev-1/agent-activity"]);
    expect(outcome).toEqual({ outcome: "withdrawn", detail: null });
  });

  it("tells a Mac that refused from one the phone could not reach", async () => {
    const refused = await forgetTokensOutcome({
      environmentId: mac,
      kinds: ["alert"],
      run: async () => ({ _tag: "Failure", cause: Cause.fail(new Error("no such device")) }),
      loadDeviceId: async () => "dev-1",
    });
    expect(refused.outcome).toBe("refused");
    expect(refused.detail).toContain("no such device");
    const unreachable = await forgetTokensOutcome({
      environmentId: mac,
      kinds: ["alert"],
      run: async () => {
        throw Object.assign(new Error("mac-1 is not connected"), {
          _tag: "EnvironmentRpcUnavailableError",
        });
      },
      loadDeviceId: async () => "dev-1",
    });
    expect(unreachable).toEqual({ outcome: "unreachable", detail: "mac-1 is not connected" });
  });

  it("never throws on a missing device id", async () => {
    let ran = 0;
    const outcome = await forgetTokensOutcome({
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
    expect(outcome.outcome).toBe("refused");
  });
});
