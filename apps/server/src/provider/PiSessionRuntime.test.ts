import { describe, expect, it } from "@effect/vitest";
import { piRpcArgs } from "./PiSessionRuntime.ts";

describe("piRpcArgs", () => {
  it("always speaks the RPC protocol, and omits a model when none was resolved", () => {
    expect(piRpcArgs({})).toEqual(["--mode", "rpc"]);
  });

  it("passes a resolved model and session id through", () => {
    expect(piRpcArgs({ model: "zai/glm-5.3", sessionId: "t3-abc" })).toEqual([
      "--mode",
      "rpc",
      "--model",
      "zai/glm-5.3",
      "--session-id",
      "t3-abc",
    ]);
  });
});
