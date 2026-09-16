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
  /** Text only the populated page shows. A field's value counts, written the
      way the harness captures one: `[<accessible name>: <what the user reads>]`. */
  readonly marker: string;
  /** Further text the populated page must show, for a page whose render is
      worth proving in more than one place; each is checked like `marker`. */
  readonly shows?: ReadonlyArray<string>;
  /** Empty-state copy this page must not show, on top of `ALWAYS_ABSENT`. */
  readonly absent?: ReadonlyArray<string>;
}

/** Copy every Infinitus page prints when the app is not answering, still
    loading, or reports a build without the page's verb. */
export const ALWAYS_ABSENT: ReadonlyArray<string> = [
  "not answering",
  // #823: the product is Infinitus on every screen; the upstream name never shows.
  "T3 Code",
  // #1368: the relay feature is Infinitus Connect on every screen.
  "T3 Connect",
  // #823 too: a Mac pref key starting `fork_` humanises to "Fork …" when the
  // web has no copy for it, which puts the contributor's word on screen.
  "Fork ",
  "Still connecting",
  "This Infinitus build has no",
  "could not be read",
];

export const FORK_VISUAL_ROUTES: ReadonlyArray<ForkVisualRoute> = [
  { route: "/settings/infinitus", label: "Menu bar", marker: "Show the account name" },
  { route: "/settings/infinitus/themes", label: "Themes", marker: "Off — plain numbers" },
  {
    route: "/settings/infinitus/animations",
    label: "Animations",
    // A select's value, not its label: a label renders whether or not the
    // choice names arrived, so the value is the part that proves they did.
    marker: "[Popup entrance: Slide down from the top]",
    shows: ["[Title flourish: Zoom in]", "[Pace fire: Ember]"],
    // Each one is a key of this page humanised for want of web copy, the same
    // failure `Fork ` guards above.
    absent: ["Intro style", "Intro title", "Intro speed", "Burn style"],
  },
  { route: "/settings/infinitus/sessions", label: "Priority", marker: "Thread priority" },
  { route: "/settings/infinitus/lock", label: "Lock", marker: "Re-lock" },
  { route: "/settings/infinitus/team", label: "Team", marker: "Whole team" },
  {
    route: "/settings/infinitus/notifications",
    label: "Notifications",
    marker: "All accounts are exhausted",
  },
  {
    route: "/settings/infinitus/devices",
    label: "Devices",
    // A switch's state, which the fixture sets on where the page's other
    // switch is off. A label renders whether or not its control took the pref,
    // so the value is the only part of this page that proves one arrived — and
    // a switch state is the same string whatever the number formatting.
    marker: "[Sync settings via iCloud Drive: on]",
    // The port the fixture sets, unformatted. #1110 shipped a port that read
    // "3,773" — the label and the description were on screen, so nothing here
    // saw it. It is a number field's value, so this is the check that would.
    shows: ["[Server port: 3773]"],
  },
  {
    route: "/settings/infinitus/engines",
    label: "Engines",
    marker: "swapd engine on",
    shows: [
      "Management key",
      "Dashboard password",
      "[CLIProxyAPI base URL: http://127.0.0.1:8317]",
      "nothing is saved",
      // The routing rows (#1235): the fixture's proxy rotates with affinity on.
      "Routing strategy",
      "Round robin",
      "Session affinity",
      "Open CLIProxyAPI dashboard",
      "Open 9Router dashboard",
      "Daemon running",
      // The About section's version line, drawn once `status` answered.
      "Menu bar app 0.0.0-fixture",
    ],
  },
  {
    route: "/accounts",
    label: "Accounts",
    marker: "claude (swapd)",
    absent: ["no engine reports accounts"],
  },
  {
    // The fixture's log carries one row of every kind the Mac logs, so every
    // chip is on screen. Each phrase here is a chip followed by the start of
    // its own row's text — the capture joins a row's spans with a space — so
    // a kind that lost its chip fails here, on the exact row, instead of
    // reaching a screen unlabelled (#1111).
    route: "/activity",
    label: "Activity",
    marker: "all out all exhausted",
    shows: [
      "limit grace-fixture hit a limit",
      "revival grace-fixture is back",
      "ignite ignited linus-fixture",
      "desktop desktop credential stored",
      "pairing phone pairing token",
      "switch Switched to ada-fixture",
    ],
    absent: ["Nothing logged yet.", "Only polls so far"],
  },
  {
    // The Run rate row pins its own figures: the page's counts are the one
    // place in the fork a raw number reached the screen ungrouped, so the
    // week's turn count is asserted the way it reads, "1,620" (#1110's
    // lesson, applied to the column a label alone would not have caught).
    route: "/utilization",
    label: "Utilization",
    marker: "ada-fixture",
    shows: ["Last week 13.8M 58.20 1,620"],
    absent: ["No projection yet"],
  },
  {
    route: "/stats",
    label: "Stats",
    marker: "Session lengths",
    // The tiles whose figure the fixture used to leave out, so each read zero
    // and a tile that stopped reading its field looked the same as one that
    // worked (#1115). Each phrase is a tile's name and the figure beside it —
    // the capture joins a tile's spans with a space.
    shows: [
      "Reverts 7",
      "Repos 3",
      "Nudges 21",
      "Sub-agents 28",
      "Longest unattended 34 tool calls",
      "Questions 49",
      "Denied tools 7",
      "Tool errors 35",
      "API retries 14",
      "Accounts hit a limit 14",
      "Revivals 14",
      "Minutes lost, all out 77",
      "Ignites 7",
      "Resumes 21",
      // The Cost group's four ratio tiles, which the web left out until it was
      // diffed against the Mac's own catalogue. Each divides two figures, so a
      // tile that stopped reading one of them reads "—" rather than a number.
      "Per commit $2.04",
      "Per PR $9.20",
      "Tokens / line 141.2",
      "Mean hours to merge 4.5",
    ],
  },
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
  for (const phrase of [route.marker, ...(route.shows ?? [])]) {
    if (!text.includes(phrase)) failures.push(`missing "${phrase}"`);
  }
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
