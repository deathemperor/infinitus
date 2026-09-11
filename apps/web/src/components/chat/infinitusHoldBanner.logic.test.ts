import * as Cause from "effect/Cause";
import { describe, expect, it } from "vite-plus/test";

import {
  holdBannerText,
  holdBannerTitle,
  holdPhaseAfterRelease,
  runNowLabel,
} from "./infinitusHoldBanner.logic";

describe("infinitusHoldBanner.logic", () => {
  it("reads the release result into a phase", () => {
    expect(holdPhaseAfterRelease({ _tag: "Success", value: { released: true } })).toEqual({
      kind: "released",
    });
    expect(
      holdPhaseAfterRelease({
        _tag: "Success",
        value: { released: false, reason: "nothing is held" },
      }),
    ).toEqual({ kind: "gone", reason: "nothing is held" });
    expect(holdPhaseAfterRelease({ _tag: "Success", value: { released: false } })).toEqual({
      kind: "gone",
      reason: "Nothing is held for this thread.",
    });
    expect(
      holdPhaseAfterRelease({ _tag: "Failure", cause: Cause.fail(new Error("socket closed")) }),
    ).toEqual({ kind: "failed", message: "socket closed" });
  });

  it("labels the button by phase", () => {
    expect(runNowLabel({ kind: "idle" })).toBe("Run now");
    expect(runNowLabel({ kind: "releasing" })).toBe("Starting...");
    expect(runNowLabel({ kind: "released" })).toBe("Starting...");
  });

  it("describes the hold, then what Run now found", () => {
    const summary = "Held for headroom on claude, 5h window 84 %";
    expect(holdBannerText(summary, { kind: "idle" })).toEqual({
      description: summary,
      actionable: true,
    });
    expect(holdBannerText(summary, { kind: "gone", reason: "nothing is held" })).toEqual({
      description: "Nothing is held any more (nothing is held). Send the message again.",
      actionable: false,
    });
    expect(holdBannerText(summary, { kind: "failed", message: "socket closed" })).toEqual({
      description: "Run now failed: socket closed",
      actionable: true,
    });
  });

  it("speaks of resuming for a paused turn (#743)", () => {
    expect(holdBannerTitle("held")).toBe("Waiting for headroom");
    expect(holdBannerTitle("paused")).toBe("Paused for headroom");
    expect(runNowLabel({ kind: "idle" }, "paused")).toBe("Resume now");
    expect(runNowLabel({ kind: "releasing" }, "paused")).toBe("Resuming...");
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
    expect(holdBannerText(summary, { kind: "failed", message: "socket closed" }, "paused")).toEqual(
      {
        description: "Resume now failed: socket closed",
        actionable: true,
      },
    );
  });

  it("names a limit stop and offers no button (#270 I)", () => {
    expect(holdBannerTitle("limited")).toBe("Stopped on a usage limit");
    expect(holdBannerText("Limit hit on one@example.com", { kind: "idle" }, "limited")).toEqual({
      description: "Limit hit on one@example.com",
      actionable: false,
    });
  });
});
