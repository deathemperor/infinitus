import { EnvironmentId } from "@t3tools/contracts";
import * as Cause from "effect/Cause";
import { afterEach, beforeEach, describe, expect, it, vi } from "vite-plus/test";

vi.mock("expo-constants", () => ({ default: { deviceName: "Test iPhone" } }));
vi.mock("../../persistence/imperative", () => ({
  loadOrCreateAgentAwarenessDeviceId: async () => "device-1",
}));
vi.mock("./apnsEnvironment", () => ({ resolveApnsEnvironment: async () => "sandbox" }));

import { tokenSender } from "./pushRegistration";

const environmentId = EnvironmentId.make("mac-1");

describe("tokenSender (#845)", () => {
  const warn = vi.spyOn(console, "warn");
  beforeEach(() => warn.mockImplementation(() => undefined));
  afterEach(() => warn.mockReset());

  it("sends a registration once and stays quiet on success", async () => {
    const commands: string[] = [];
    const run = vi.fn(async (call: { input: { command: string } }) => {
      commands.push(call.input.command);
      return { _tag: "Success" as const };
    });
    const send = tokenSender({ environmentId, run, isCancelled: () => false });
    await send("working", "tok-1");
    await send("working", "tok-1");
    expect(commands).toEqual(["activities-token"]);
    expect(warn).not.toHaveBeenCalled();
  });

  it("names a refused registration and forgets the token so the next chance re-sends", async () => {
    const run = vi
      .fn()
      .mockResolvedValueOnce({
        _tag: "Failure" as const,
        cause: Cause.fail(new Error("forbidden")),
      })
      .mockResolvedValueOnce({ _tag: "Success" as const });
    const send = tokenSender({ environmentId, run, isCancelled: () => false });
    await send("working", "tok-1");
    expect(warn).toHaveBeenCalledWith(
      "[infinitus-push] token registration failed",
      expect.objectContaining({ kind: "working", error: "Error: forbidden" }),
    );
    await send("working", "tok-1");
    expect(run).toHaveBeenCalledTimes(2);
  });
});
