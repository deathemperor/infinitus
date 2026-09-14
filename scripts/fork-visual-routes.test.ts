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
      for (const phrase of [route.marker, ...(route.shows ?? [])]) {
        for (const shown of ALWAYS_ON_SCREEN) {
          expect(shown.includes(phrase), `${route.route}: "${phrase}"`).toBe(false);
        }
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

  it("names each `shows` phrase the capture is missing, beside the marker", () => {
    const activity = FORK_VISUAL_ROUTES.find((route) => route.route === "/activity")!;
    expect(
      routeFailures(activity, "Activity 8:46 PM ignite ignited linus-fixture — window"),
    ).toEqual([
      'missing "all out all exhausted"',
      'missing "limit grace-fixture hit a limit"',
      'missing "revival grace-fixture is back"',
      'missing "desktop desktop credential stored"',
      'missing "pairing phone pairing token"',
      'missing "switch Switched to ada-fixture"',
    ]);
  });

  it("fails a Stats tile that lost its figure and reads zero again (#1115)", () => {
    const stats = FORK_VISUAL_ROUTES.find((route) => route.route === "/stats")!;
    const capture = [stats.marker, ...stats.shows!].join(" ");
    expect(routeFailures(stats, capture)).toEqual([]);
    expect(routeFailures(stats, capture.replace("Nudges 21", "Nudges 0"))).toEqual([
      'missing "Nudges 21"',
    ]);
  });

  it("fails a row humanised from a fork_ pref key the web has no copy for", () => {
    expect(routeFailures(lock, "Re-lock Fork tunnel enabled")).toEqual(['shows "Fork "']);
    expect(routeFailures(lock, "Re-lock Tunnel hostname")).toEqual([]);
  });

  it("fails a field whose label rendered but whose value did not", () => {
    const devices = FORK_VISUAL_ROUTES.find(
      (route) => route.route === "/settings/infinitus/devices",
    )!;
    const port = "[Server port: 3773]";
    const missing = 'missing "[Sync settings via iCloud Drive: on]"';
    // The label alone is what `innerText` captured, and what a switch that
    // never took its pref still draws.
    expect(routeFailures(devices, `Sync settings via iCloud Drive ${port}`)).toEqual([missing]);
    expect(routeFailures(devices, `[Sync settings via iCloud Drive: off] ${port}`)).toEqual([
      missing,
    ]);
    expect(routeFailures(devices, `[Sync settings via iCloud Drive: on] ${port}`)).toEqual([]);
  });

  it("fails the port #1110 grouped into 3,773", () => {
    const devices = FORK_VISUAL_ROUTES.find(
      (route) => route.route === "/settings/infinitus/devices",
    )!;
    const on = "[Sync settings via iCloud Drive: on]";
    expect(routeFailures(devices, `${on} [Server port: 3,773]`)).toEqual([
      'missing "[Server port: 3773]"',
    ]);
    expect(routeFailures(devices, `${on} [Server port: 3773]`)).toEqual([]);
  });
});

describe("checkVisualPass", () => {
  const stats = FORK_VISUAL_ROUTES.find((route) => route.route === "/stats")!;

  it("reads one capture per route and reports every failure", () => {
    const captures = new Map<string, string>([
      ["settings-infinitus-lock", "Unlocking Re-lock Locked"],
      ["stats", `Stats ${[stats.marker, ...stats.shows!].join(" ")}`],
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
