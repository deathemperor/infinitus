import * as Cause from "effect/Cause";
import { describe, expect, it } from "vite-plus/test";

import {
  holdBannerBusy,
  holdBannerText,
  holdBannerTitle,
  holdPhaseAfterPin,
  holdPhaseAfterRelease,
  pinLabel,
  runNowLabel,
} from "./holdBanner.logic";

describe("holdPhaseAfterRelease", () => {
  it("reads a released start, a forgotten hold and a failure", () => {
    expect(holdPhaseAfterRelease({ _tag: "Success", value: { released: true } })).toEqual({
      kind: "released",
    });
    expect(
      holdPhaseAfterRelease({
        _tag: "Success",
        value: { released: false, reason: "the server restarted" },
      }),
    ).toEqual({ kind: "gone", reason: "the server restarted" });
    expect(holdPhaseAfterRelease({ _tag: "Success", value: { released: false } })).toEqual({
      kind: "gone",
      reason: "Nothing is held for this thread.",
    });
    expect(
      holdPhaseAfterRelease({ _tag: "Failure", cause: Cause.fail(new Error("socket closed")) }),
    ).toEqual({ kind: "failed", message: "socket closed" });
  });
});

describe("holdPhaseAfterPin", () => {
  it("goes idle on a pin and explains the two ways it did not happen", () => {
    expect(holdPhaseAfterPin("pinned")).toEqual({ kind: "idle" });
    expect(holdPhaseAfterPin("unsupported").kind).toBe("failed");
    expect(holdPhaseAfterPin("failed").kind).toBe("failed");
  });
});

describe("banner copy", () => {
  it("labels the buttons by phase and keeps both quiet while one is answering", () => {
    expect(runNowLabel({ kind: "idle" })).toBe("Run now");
    expect(runNowLabel({ kind: "releasing" })).toBe("Starting...");
    expect(runNowLabel({ kind: "released" })).toBe("Starting...");
    expect(pinLabel({ kind: "pinning" })).toBe("Pinning...");
    expect(pinLabel({ kind: "idle" })).toBe("Pin");
    expect(holdBannerBusy({ kind: "releasing" })).toBe(true);
    expect(holdBannerBusy({ kind: "pinning" })).toBe(true);
    expect(holdBannerBusy({ kind: "failed", message: "x" })).toBe(false);
  });

  it("shows the hold's line, a failure with the thread still waiting, and a gone hold without actions", () => {
    const summary = "Held for headroom on claude, 5h window 84 %";
    expect(holdBannerText(summary, { kind: "idle" })).toEqual({
      description: summary,
      actionable: true,
    });
    expect(holdBannerText(summary, { kind: "failed", message: "Run now failed." })).toEqual({
      description: "Run now failed. The thread is still waiting.",
      actionable: true,
    });
    expect(holdBannerText(summary, { kind: "gone", reason: "restart" })).toEqual({
      description: "Nothing is held any more (restart). Send the message again.",
      actionable: false,
    });
  });

  it("speaks of resuming for a paused turn (#743)", () => {
    expect(holdBannerTitle("held")).toBe("Waiting for headroom");
    expect(holdBannerTitle("paused")).toBe("Paused for headroom");
    expect(runNowLabel({ kind: "idle" }, "paused")).toBe("Resume now");
    expect(runNowLabel({ kind: "released" }, "paused")).toBe("Resuming...");
    const summary = "Paused for headroom on claude, 5h window 92 %";
    expect(holdBannerText(summary, { kind: "idle" }, "paused")).toEqual({
      description: summary,
      actionable: true,
    });
    expect(
      holdBannerText(summary, { kind: "gone", reason: "nothing is paused" }, "paused"),
    ).toEqual({
      description: "Nothing is paused any more (nothing is paused). Send a message to continue.",
      actionable: false,
    });
  });
});
