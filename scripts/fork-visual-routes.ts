/**
 * The fork visual pass's route table: every fork page, the one text marker
 * that proves it rendered its populated state against the CI fixture
 * (`fork-visual-fixture.mjs`), and the phrases that must not appear. A marker
 * is a string only the ready render shows — never a nav label or a card title,
 * which the not-answering and loading branches print too.
 *
 * `fork-visual-check.ts` reads the `text-<route>.txt` files
 * `fork-visual-pass.mjs` writes and applies this table; the workflow fails on
 * the first route that misses.
 */

export interface ForkVisualRoute {
  /** The path the harness opens. */
  readonly route: string;
  /** The page's name in the report. */
  readonly label: string;
  /** Text only the populated page shows. */
  readonly marker: string;
  /** Empty-state copy this page must not show, on top of `ALWAYS_ABSENT`. */
  readonly absent?: ReadonlyArray<string>;
}

/** Copy every Infinitus page prints when the app is not answering, still
    loading, or reports a build without the page's verb. */
export const ALWAYS_ABSENT: ReadonlyArray<string> = [
  "not answering",
  // #823: the product is Infinitus on every screen; the upstream name never shows.
  "T3 Code",
  "Still connecting",
  "This Infinitus build has no",
  "could not be read",
];

export const FORK_VISUAL_ROUTES: ReadonlyArray<ForkVisualRoute> = [
  { route: "/settings/infinitus", label: "Menu bar", marker: "Show the account name" },
  { route: "/settings/infinitus/themes", label: "Themes", marker: "Off — plain numbers" },
  { route: "/settings/infinitus/animations", label: "Animations", marker: "Intro style" },
  { route: "/settings/infinitus/sessions", label: "Sessions", marker: "Session priority" },
  { route: "/settings/infinitus/lock", label: "Lock", marker: "Re-lock" },
  {
    route: "/settings/infinitus/team",
    label: "Team",
    marker: "Lighthouse",
    absent: ["Reading the team", "This Mac is not in a team"],
  },
  {
    route: "/settings/infinitus/notifications",
    label: "Notifications",
    marker: "All sessions finish working",
  },
  { route: "/settings/infinitus/devices", label: "Devices", marker: "Serve the fleet to my phone" },
  { route: "/settings/infinitus/engines", label: "Engines", marker: "swapd engine on" },
  { route: "/settings/infinitus/profiles", label: "Profiles", marker: "nightly-review" },
  {
    route: "/utilization",
    label: "Utilization",
    marker: "ada-fixture",
    absent: ["No projection yet"],
  },
  { route: "/stats", label: "Stats", marker: "Session lengths" },
];

/** The file stem `fork-visual-pass.mjs` gives a route: `/settings/infinitus`
    → `settings-infinitus`, `/` → `home`. Kept in step with the harness. */
export function captureName(route: string): string {
  return route.replace(/^\//, "").replace(/\//g, "-") || "home";
}

/** Why one route's captured text fails the table; empty when it passes. */
export function routeFailures(route: ForkVisualRoute, text: string | null): ReadonlyArray<string> {
  if (text === null) return ["no text capture"];
  const failures: string[] = [];
  if (!text.includes(route.marker)) failures.push(`missing "${route.marker}"`);
  for (const phrase of [...ALWAYS_ABSENT, ...(route.absent ?? [])]) {
    if (text.includes(phrase)) failures.push(`shows "${phrase}"`);
  }
  return failures;
}

export interface ForkVisualResult {
  readonly route: ForkVisualRoute;
  readonly failures: ReadonlyArray<string>;
}

/** Every route against its capture; `read` answers null for a missing file. */
export function checkVisualPass(
  read: (name: string) => string | null,
  routes: ReadonlyArray<ForkVisualRoute> = FORK_VISUAL_ROUTES,
): ReadonlyArray<ForkVisualResult> {
  return routes.map((route) => ({
    route,
    failures: routeFailures(route, read(captureName(route.route))),
  }));
}
