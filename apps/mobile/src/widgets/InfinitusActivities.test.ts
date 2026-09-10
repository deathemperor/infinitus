import { describe, expect, it, vi } from "vite-plus/test";

vi.mock("@expo/ui/swift-ui", () => ({
  HStack: "HStack",
  Image: "Image",
  ProgressView: "ProgressView",
  Spacer: "Spacer",
  Text: "Text",
  VStack: "VStack",
}));

vi.mock("@expo/ui/swift-ui/modifiers", () => ({
  font: (value: unknown) => value,
  foregroundStyle: (value: unknown) => ({ foregroundStyle: value }),
  frame: (value: unknown) => value,
  lineLimit: (value: unknown) => value,
  monospacedDigit: () => "monospacedDigit",
  padding: (value: unknown) => value,
  tint: (value: unknown) => ({ tint: value }),
}));

vi.mock("expo-widgets", () => ({
  createLiveActivity: vi.fn((name: string, layout: unknown) => ({ layout, name })),
}));

import type {
  InfinitusRevivalActivityState,
  InfinitusWorkingActivityState,
} from "@t3tools/contracts/infinitus";

import InfinitusRevivalFactory, {
  INFINITUS_REVIVAL_ACTIVITY_NAME,
  InfinitusRevival,
} from "./InfinitusRevival";
import InfinitusWorkingFactory, {
  INFINITUS_WORKING_ACTIVITY_NAME,
  InfinitusWorking,
} from "./InfinitusWorking";

const dark = { colorScheme: "dark", isLuminanceReduced: false } as const;
const light = { colorScheme: "light", isLuminanceReduced: false } as const;

const working: InfinitusWorkingActivityState = {
  active: "death2",
  icon: "bolt",
  slot: "P1",
  plan: "Max 20×",
  cash: null,
  windows: [
    { label: "5h", color: "green", pct: 42, reset: "1h10m·13:00" },
    { label: "7d", color: "amber", pct: 93, reset: null },
  ],
  binding: 1,
  busy: 2,
  total: 3,
  waiting: 1,
  next: "death4",
  tokensPerMinute: 1200,
  tokenFraction: 0.6,
  accent: "teal",
  plain: false,
};

const revival: InfinitusRevivalActivityState = {
  reviver: "death3",
  icon: null,
  revivesAt: 810_000_000,
  sessions: 4,
  waiting: 2,
  later: ["loc 2:50 PM"],
  reviveWord: "revives",
  deadWord: "is dead",
  accent: "red",
  revived: false,
};

describe("InfinitusWorking layout", () => {
  it("registers under the name the Mac pushes to", () => {
    expect(InfinitusWorkingFactory).toMatchObject({ name: INFINITUS_WORKING_ACTIVITY_NAME });
    expect(INFINITUS_WORKING_ACTIVITY_NAME).toBe("InfinitusWorking");
  });

  it("draws every window as a bar toned by how full it is, red past 90 %", () => {
    const banner = JSON.stringify(InfinitusWorking(working, dark as never).banner);
    expect(banner).toContain('"value":0.42');
    expect(banner).toContain('"value":0.93');
    expect(banner).toContain("#7dd3fc"); // sky-300: the 42 % window
    expect(banner).toContain("#fca5a5"); // red-300: the 93 % window
    expect(banner).toContain("death2");
    expect(banner).toContain("2/3 busy · 1 waiting");
    expect(banner).toContain("next: death4");
    expect(banner).toContain("1200 tok/min");
  });

  it("leads the compact presentations with the binding window", () => {
    const layout = InfinitusWorking(working, light as never);
    expect(JSON.stringify(layout.compactTrailing)).toContain("93%");
    expect(JSON.stringify(layout.minimal)).toContain("93%");
    expect(JSON.stringify(layout.compactLeading)).toContain("#dc2626"); // red-600 in light
  });

  it("falls back to the slot and the infinity glyph with no windows", () => {
    const layout = InfinitusWorking(
      { ...working, windows: [], binding: null, total: 0 },
      dark as never,
    );
    expect(JSON.stringify(layout.compactTrailing)).toContain("P1");
    expect(JSON.stringify(layout.minimal)).toContain("∞");
    expect(JSON.stringify(layout.banner)).toContain("no sessions");
  });
});

describe("InfinitusRevival layout", () => {
  it("registers under the name the Mac pushes to", () => {
    expect(InfinitusRevivalFactory).toMatchObject({ name: INFINITUS_REVIVAL_ACTIVITY_NAME });
  });

  it("says who revives when, in the theme's words, and what comes after", () => {
    const banner = JSON.stringify(InfinitusRevival(revival, dark as never).banner);
    expect(banner).toContain("Every account is dead");
    expect(banner).toMatch(/death3 revives at \d/);
    expect(banner).toContain("then loc 2:50 PM");
    expect(banner).toContain("4 sessions · 2 waiting");
    expect(banner).toContain("#fca5a5");
  });

  it("turns green and final once revived", () => {
    const layout = InfinitusRevival({ ...revival, revived: true }, light as never);
    const banner = JSON.stringify(layout.banner);
    expect(banner).toContain("death3 revives");
    expect(banner).toContain("The fleet is back.");
    expect(banner).toContain("#059669");
    expect(JSON.stringify(layout.compactTrailing)).toContain("back");
  });
});
