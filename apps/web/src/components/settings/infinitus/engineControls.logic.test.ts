import type { InfinitusEngineSupervision } from "@infinitus/contracts/infinitus";
import { describe, expect, it } from "vite-plus/test";

import {
  engineBadge,
  engineControlsEnabled,
  engineErrorLine,
  engineStateLine,
  infinitusEngineBridge,
} from "./engineControls.logic";

const engine = (
  overrides: Partial<InfinitusEngineSupervision> = {},
): InfinitusEngineSupervision => ({
  key: "9router",
  mode: "child",
  managed: true,
  command: "/opt/homebrew/bin/9router -n",
  detectedCommand: "/opt/homebrew/bin/9router -n",
  state: "running",
  pid: 4242,
  error: null,
  ...overrides,
});

describe("engineControls.logic", () => {
  it("takes the bridge only when every method is there", () => {
    expect(infinitusEngineBridge(undefined)).toBeNull();
    expect(
      infinitusEngineBridge({ getInfinitusEngines: async () => ({ engines: [] }) }),
    ).toBeNull();
    const whole = {
      getInfinitusEngines: async () => ({ engines: [] }),
      setInfinitusEngineSettings: async () => ({ engines: [] }),
      controlInfinitusEngine: async () => ({ engines: [] }),
    };
    expect(infinitusEngineBridge(whole)).not.toBeNull();
  });

  it("names the process when one is running", () => {
    expect(engineStateLine(engine())).toBe("Running (pid 4242).");
  });

  it("says who owns a service-managed engine, and offers no controls for it", () => {
    const managed = engine({ mode: "service", state: "stopped" });
    expect(engineStateLine(managed)).toContain("Homebrew");
    expect(engineControlsEnabled(managed)).toBe(false);
    expect(engineBadge(managed)).toEqual({ label: "Homebrew", tone: "up" });
  });

  it("tells a machine without the engine what to do", () => {
    const missing = engine({ mode: "unknown", command: null, detectedCommand: null });
    expect(engineStateLine(missing)).toContain("Type the command");
    expect(engineControlsEnabled(missing)).toBe(false);
  });

  it("carries the failure's own words", () => {
    const failed = engine({ state: "failed", error: "spawn ENOENT" });
    expect(engineStateLine(failed)).toBe("spawn ENOENT");
    expect(engineBadge(failed).tone).toBe("down");
  });

  it("says a restart is coming while backing off", () => {
    const dying = engine({ state: "backing-off", error: "The engine exited with code 1." });
    expect(engineStateLine(dying)).toBe("The engine exited with code 1. Trying again shortly.");
    expect(engineBadge(dying)).toEqual({ label: "Restarting", tone: "warn" });
  });

  describe("the engine's own error, reworded", () => {
    const unreachable = "engine unreachable: Could not connect to the server";

    it("says the engine is not running when this shell knows it is not", () => {
      expect(engineErrorLine(unreachable, engine({ state: "stopped" }), "9Router")).toBe(
        "9Router is not running.",
      );
    });

    it("leaves it alone when the process is up — then it is a real connection fault", () => {
      expect(engineErrorLine(unreachable, engine(), "9Router")).toBe(unreachable);
    });

    it("leaves any other error, and anything with no supervision behind it, alone", () => {
      expect(engineErrorLine("401 unauthorized", engine({ state: "stopped" }), "9Router")).toBe(
        "401 unauthorized",
      );
      expect(engineErrorLine(unreachable, null, "9Router")).toBe(unreachable);
      expect(engineErrorLine(null, engine(), "9Router")).toBeNull();
    });
  });
});
