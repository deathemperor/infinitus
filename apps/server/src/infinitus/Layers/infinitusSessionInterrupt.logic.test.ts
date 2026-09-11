import type {
  InfinitusFleet,
  InfinitusPrefs,
  InfinitusSnapshot,
} from "@t3tools/contracts/infinitus";
import { describe, expect, it } from "vite-plus/test";

import {
  interruptModeOn,
  interruptVerdict,
  pauseMarkerSummary,
  resumeMarkerSummary,
} from "./infinitusSessionInterrupt.logic.ts";

const fleet = (overrides: Partial<InfinitusFleet> = {}): InfinitusFleet => ({
  key: "swapd/claude",
  engineID: "swapd",
  provider: "claude",
  capabilities: [],
  accounts: [
    { number: 1, email: "one@example.com", active: true, isOrganization: false, usageStatus: "ok" },
  ],
  ...overrides,
});

const snapshotWith = (
  fleets: ReadonlyArray<InfinitusFleet>,
  prefs?: InfinitusPrefs,
): InfinitusSnapshot => ({
  available: true,
  fleets,
  sessions: [],
  commands: [],
  ...(prefs === undefined ? {} : { prefs }),
});

const critical = fleet({ headroom: { state: "critical", window: "5h", pct: 92 } });
const low = fleet({ headroom: { state: "low", window: "5h", pct: 84 } });
const abundant = fleet({ headroom: { state: "abundant" } });

describe("interruptVerdict", () => {
  it("interrupts when every active fleet reads low or critical and one reads critical", () => {
    expect(interruptVerdict(snapshotWith([critical]), "claude")).toEqual({
      verdict: "interrupt",
      fleet: critical,
    });
    expect(interruptVerdict(snapshotWith([low, { ...critical, key: "b" }]), "claude")).toEqual({
      verdict: "interrupt",
      fleet: { ...critical, key: "b" },
    });
  });

  it("keeps running turns while every fleet reads low (hold mode)", () => {
    expect(interruptVerdict(snapshotWith([low]), "claude")).toEqual({ verdict: "keep" });
  });

  it("resumes on any abundant fleet", () => {
    expect(interruptVerdict(snapshotWith([critical, { ...abundant, key: "b" }]), "claude")).toEqual(
      { verdict: "resume", fleet: { ...abundant, key: "b" } },
    );
  });

  it("knows nothing without a fleet, an active account, or a verdict", () => {
    expect(interruptVerdict(snapshotWith([critical]), "codex")).toEqual({ verdict: "unknown" });
    expect(
      interruptVerdict(
        snapshotWith([{ ...critical, accounts: [{ ...critical.accounts[0]!, active: false }] }]),
        "claude",
      ),
    ).toEqual({ verdict: "unknown" });
    expect(interruptVerdict(snapshotWith([fleet()]), "claude")).toEqual({ verdict: "unknown" });
    expect(interruptVerdict(snapshotWith([critical, fleet({ key: "b" })]), "claude")).toEqual({
      verdict: "unknown",
    });
  });
});

describe("interruptModeOn", () => {
  const prefs = (value: unknown): InfinitusPrefs => ({
    sections: [],
    prefs: [
      {
        key: "priority_mode",
        type: "string",
        default: "off",
        value,
        section: "sessions",
        effect: "live",
      },
    ],
  });

  it("reads the priority_mode pref", () => {
    expect(interruptModeOn(snapshotWith([low], prefs("interrupt")))).toBe(true);
    expect(interruptModeOn(snapshotWith([low], prefs("hold")))).toBe(false);
    expect(interruptModeOn(snapshotWith([low]))).toBe(false);
  });

  it("takes a critical fleet as proof without the pref", () => {
    expect(interruptModeOn(snapshotWith([critical]))).toBe(true);
    expect(interruptModeOn(snapshotWith([critical], prefs("hold")))).toBe(true);
  });
});

describe("marker summaries", () => {
  it("name the fleet and its binding window", () => {
    expect(pauseMarkerSummary(critical)).toBe("Paused for headroom on claude, 5h window 92 %");
    expect(pauseMarkerSummary(fleet({ headroom: { state: "critical" } }))).toBe(
      "Paused for headroom on claude",
    );
    expect(resumeMarkerSummary("abundant", "claude")).toBe("Resumed: headroom abundant on claude");
    expect(resumeMarkerSummary("pinned", "claude")).toBe("Resumed: pinned");
    expect(resumeMarkerSummary("user", "claude")).toBe("Resumed: resume now");
    expect(resumeMarkerSummary("off", "claude")).toBe("Resumed: no headroom verdict on claude");
  });
});
