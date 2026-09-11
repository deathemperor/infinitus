import * as Cause from "effect/Cause";
import { describe, expect, it } from "vite-plus/test";

import { launchButtonLabel, launchNotice, launchPhaseAfter } from "./launch.logic";

describe("launch.logic", () => {
  it("reads the RPC result into a phase", () => {
    expect(launchPhaseAfter({ _tag: "Success", value: { launched: true } })).toEqual({
      kind: "launched",
    });
    expect(
      launchPhaseAfter({
        _tag: "Success",
        value: { launched: false, reason: "Infinitus is already running" },
      }),
    ).toEqual({ kind: "declined", reason: "Infinitus is already running" });
    expect(launchPhaseAfter({ _tag: "Success", value: { launched: false } })).toEqual({
      kind: "declined",
      reason: "Infinitus was not launched.",
    });
    expect(
      launchPhaseAfter({
        _tag: "Success",
        value: {
          launched: false,
          installed: false,
          reason: "No Infinitus app is installed on this Mac.",
        },
      }),
    ).toEqual({ kind: "not-installed", reason: "No Infinitus app is installed on this Mac." });
    expect(launchPhaseAfter({ _tag: "Failure", cause: Cause.fail(new Error("boom")) })).toEqual({
      kind: "failed",
      message: "boom",
    });
  });

  it("labels the button and speaks only once there is something to say", () => {
    expect(launchButtonLabel({ kind: "idle" })).toBe("Launch Infinitus");
    expect(launchButtonLabel({ kind: "launching" })).toBe("Launching…");
    expect(launchNotice({ kind: "idle" })).toBeNull();
    expect(launchNotice({ kind: "launching" })).toBeNull();
    expect(launchNotice({ kind: "launched" })).toMatch(/starting/);
    expect(launchNotice({ kind: "declined", reason: "macOS only" })).toBe("macOS only");
    expect(launchNotice({ kind: "not-installed", reason: "not here" })).toBe("not here");
    expect(launchNotice({ kind: "failed", message: "boom" })).toBe("boom");
  });
});
