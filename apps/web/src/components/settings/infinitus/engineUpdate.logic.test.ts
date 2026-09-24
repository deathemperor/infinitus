import { describe, expect, it } from "vite-plus/test";

import {
  engineUpdateCheckInput,
  engineUpdateInput,
  engineUpdateLine,
  engineUpdateSupported,
  parseEngineUpdateCheck,
} from "./engineUpdate.logic";

const command = (name: string) => ({
  name,
  args: [],
  options: [],
  effect: "read" as const,
  summary: "",
  replyShape: "",
});

describe("engineUpdateSupported", () => {
  it("needs the check and the update verb", () => {
    expect(engineUpdateSupported([command("engine-update-check"), command("engine-update")])).toBe(
      true,
    );
    expect(engineUpdateSupported([command("engine-update-check")])).toBe(false);
  });
});

describe("engine update inputs", () => {
  it("name the engine as the verbs take it", () => {
    expect(engineUpdateCheckInput("swapd")).toEqual({
      command: "engine-update-check",
      args: ["swapd"],
      options: {},
    });
    expect(engineUpdateInput("swapd")).toEqual({
      command: "engine-update",
      args: ["swapd"],
      options: {},
    });
  });
});

describe("parseEngineUpdateCheck and engineUpdateLine", () => {
  it("reads the reply and words each state", () => {
    const newer = parseEngineUpdateCheck({
      engine: "swapd",
      current: "0.3.2",
      latest: "0.3.3",
      updatable: true,
    })!;
    expect(engineUpdateLine(newer)).toBe("0.3.3 is available (running 0.3.2).");
    expect(
      engineUpdateLine({ engine: "swapd", current: "0.3.2", latest: "0.3.2", updatable: false }),
    ).toBe("Up to date: 0.3.2 is the newest release.");
    expect(
      engineUpdateLine({
        engine: "swapd",
        current: "0.3.2",
        updatable: false,
        error: "api.github.com answered 403",
      }),
    ).toBe("Could not check for a newer release: api.github.com answered 403");
    expect(
      engineUpdateLine({ engine: "swapd", current: "0.3.2", latest: null, updatable: false }),
    ).toBe("The newest release has no build for this Mac yet.");
    expect(parseEngineUpdateCheck({ engine: "swapd" })).toBeNull();
  });
});
