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
      "/settings/menu-bar",
      "/settings/animations",
      "/settings/priority",
      "/settings/team",
      "/settings/notifications",
      "/settings/devices",
      "/settings/engines",
      "/accounts",
      "/settings/engines/activity",
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
    expect(captureName("/settings/menu-bar")).toBe("settings-menu-bar");
    expect(captureName("/settings/priority")).toBe("settings-priority");
    expect(captureName("/utilization")).toBe("utilization");
    expect(captureName("/")).toBe("home");
  });
});

describe("routeFailures", () => {
  const priority = FORK_VISUAL_ROUTES.find((route) => route.route === "/settings/priority")!;

  it("passes text that shows the marker and none of the empty states", () => {
    expect(routeFailures(priority, "Settings Priority Thread priority first")).toEqual([]);
  });

  it("fails a missing capture, a missing marker, and each forbidden phrase", () => {
    expect(routeFailures(priority, null)).toEqual(["no text capture"]);
    expect(routeFailures(priority, "Settings Priority Still connecting")).toEqual([
      'missing "Thread priority"',
      'shows "Still connecting"',
    ]);
    expect(routeFailures(priority, `Thread priority ${ALWAYS_ABSENT[0]}`)).toEqual([
      `shows "${ALWAYS_ABSENT[0]}"`,
    ]);
    expect(routeFailures(priority, "Thread priority · T3 Code (Alpha)")).toEqual([
      'shows "T3 Code"',
    ]);
  });

  it("names each `shows` phrase the capture is missing, beside the marker", () => {
    const activity = FORK_VISUAL_ROUTES.find(
      (route) => route.route === "/settings/engines/activity",
    )!;
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
    expect(routeFailures(priority, "Thread priority Fork tunnel enabled")).toEqual([
      'shows "Fork "',
    ]);
    expect(routeFailures(priority, "Thread priority Tunnel hostname")).toEqual([]);
  });

  it("fails a field whose label rendered but whose value did not", () => {
    const devices = FORK_VISUAL_ROUTES.find((route) => route.route === "/settings/devices")!;
    const port = "[Server port: 3773]";
    const missing = 'missing "[Sync settings across machines: on]"';
    // The label alone is what `innerText` captured, and what a switch that
    // never took its pref still draws.
    expect(routeFailures(devices, `Sync settings across machines ${port}`)).toEqual([missing]);
    expect(routeFailures(devices, `[Sync settings across machines: off] ${port}`)).toEqual([
      missing,
    ]);
    expect(routeFailures(devices, `[Sync settings across machines: on] ${port}`)).toEqual([]);
  });

  it("fails the port #1110 grouped into 3,773", () => {
    const devices = FORK_VISUAL_ROUTES.find((route) => route.route === "/settings/devices")!;
    const on = "[Sync settings across machines: on] No phones registered.";
    expect(routeFailures(devices, `${on} [Server port: 3,773]`)).toEqual([
      'missing "[Server port: 3773]"',
    ]);
    expect(routeFailures(devices, `${on} [Server port: 3773]`)).toEqual([]);
  });
});

describe("checkVisualPass", () => {
  const byRoute = (path: string) => FORK_VISUAL_ROUTES.find((route) => route.route === path)!;
  const stats = byRoute("/stats");

  it("reads one capture per route and reports every failure", () => {
    const captures = new Map<string, string>([
      ["settings-priority", "Priority Thread priority"],
      ["stats", `Stats ${[stats.marker, ...stats.shows!].join(" ")}`],
    ]);
    const results = checkVisualPass(
      (name) => captures.get(name) ?? null,
      [byRoute("/settings/priority"), stats, byRoute("/utilization")],
    );
    expect(results.map((result) => [result.route.label, result.failures])).toEqual([
      ["Priority", []],
      ["Stats", []],
      ["Utilization", ["no text capture"]],
    ]);
  });
});
