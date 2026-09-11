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
  "Sessions",
  "Lock",
  "Team",
  "Notifications",
  "Devices",
  "Engines",
  "Profiles",
  "Unlocking",
  "Session profiles",
  "Engine status",
  "Pairing requests",
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
      "/settings/infinitus/team",
      "/settings/infinitus/notifications",
      "/settings/infinitus/devices",
      "/settings/infinitus/engines",
      "/settings/infinitus/profiles",
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
  const team = FORK_VISUAL_ROUTES.find((route) => route.route === "/settings/infinitus/team")!;

  it("passes text that shows the marker and none of the empty states", () => {
    expect(routeFailures(team, "Settings Team Lighthouse Leader · fetched 1 min ago")).toEqual([]);
  });

  it("fails a missing capture, a missing marker, and each forbidden phrase", () => {
    expect(routeFailures(team, null)).toEqual(["no text capture"]);
    expect(routeFailures(team, "Settings Team Reading the team…")).toEqual([
      'missing "Lighthouse"',
      'shows "Reading the team"',
    ]);
    expect(routeFailures(team, `Lighthouse ${ALWAYS_ABSENT[0]}`)).toEqual([
      `shows "${ALWAYS_ABSENT[0]}"`,
    ]);
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
