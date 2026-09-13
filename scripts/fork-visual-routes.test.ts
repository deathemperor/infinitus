import { describe, expect, it } from "vite-plus/test";

import {
  ALWAYS_ABSENT,
  FORK_VISUAL_ROUTES,
  captureName,
  checkVisualPass,
  routeFailures,
} from "./fork-visual-routes.ts";

/** What every settings page prints regardless of the socket: the sidebar nav
    and the card titles the not-answering branches keep. A marker that is a
    substring of one of these would pass on a dead page. */
const ALWAYS_ON_SCREEN = [
  "Menu bar",
  "Themes",
  "Animations",
  "Priority",
  "Lock",
  "Team",
  "Notifications",
  "Devices",
  "Engines",
  "Unlocking",
  "Engine status",
  "Pairing requests",
  "Accounts",
  "Activity",
  "Utilization",
  "Stats",
  "Infinitus is not answering — it may be closed, or running on another machine.",
];

describe("FORK_VISUAL_ROUTES", () => {
  it("covers every fork page once", () => {
    expect(FORK_VISUAL_ROUTES.map((route) => route.route)).toEqual([
      "/settings/infinitus",
      "/settings/infinitus/themes",
      "/settings/infinitus/animations",
      "/settings/infinitus/sessions",
      "/settings/infinitus/lock",
      "/settings/infinitus/notifications",
      "/settings/infinitus/devices",
      "/settings/infinitus/engines",
      "/accounts",
      "/activity",
      "/utilization",
      "/stats",
    ]);
  });

  it("uses markers a not-answering page cannot show", () => {
    for (const route of FORK_VISUAL_ROUTES) {
      for (const shown of ALWAYS_ON_SCREEN) {
        expect(shown.includes(route.marker), `${route.route}: "${route.marker}"`).toBe(false);
      }
    }
  });

  it("names the capture files the way the harness does", () => {
    expect(captureName("/settings/infinitus")).toBe("settings-infinitus");
    expect(captureName("/settings/infinitus/themes")).toBe("settings-infinitus-themes");
    expect(captureName("/utilization")).toBe("utilization");
    expect(captureName("/")).toBe("home");
  });
});

describe("routeFailures", () => {
  const lock = FORK_VISUAL_ROUTES.find((route) => route.route === "/settings/infinitus/lock")!;

  it("passes text that shows the marker and none of the empty states", () => {
    expect(routeFailures(lock, "Settings Lock Re-lock after 5 min")).toEqual([]);
  });

  it("fails a missing capture, a missing marker, and each forbidden phrase", () => {
    expect(routeFailures(lock, null)).toEqual(["no text capture"]);
    expect(routeFailures(lock, "Settings Lock Still connecting")).toEqual([
      'missing "Re-lock"',
      'shows "Still connecting"',
    ]);
    expect(routeFailures(lock, `Re-lock ${ALWAYS_ABSENT[0]}`)).toEqual([
      `shows "${ALWAYS_ABSENT[0]}"`,
    ]);
    expect(routeFailures(lock, "Re-lock · T3 Code (Alpha)")).toEqual(['shows "T3 Code"']);
  });
});

describe("checkVisualPass", () => {
  it("reads one capture per route and reports every failure", () => {
    const captures = new Map<string, string>([
      ["settings-infinitus-lock", "Unlocking Re-lock Locked"],
      ["stats", "Stats Session lengths"],
    ]);
    const results = checkVisualPass(
      (name) => captures.get(name) ?? null,
      [FORK_VISUAL_ROUTES[4]!, FORK_VISUAL_ROUTES[11]!, FORK_VISUAL_ROUTES[10]!],
    );
    expect(results.map((result) => [result.route.label, result.failures])).toEqual([
      ["Lock", []],
      ["Stats", []],
      ["Utilization", ["no text capture"]],
    ]);
  });
});
