import type { SettingsSearchItem, SettingsSearchScope } from "../settingsSearch";

/** The pages that only exist where a connected server drives an Infinitus app. */
export type InfinitusSettingsPath =
  | "/settings/menu-bar"
  | "/settings/animations"
  | "/settings/priority"
  | "/settings/team"
  | "/settings/notifications"
  | "/settings/devices"
  | "/settings/engines";

// The app is Infinitus, so its pages carry no prefix (user 2026-09-11); the
// catalog page is named for what it holds, the menu bar and popup prefs.
export const INFINITUS_SECTION_LABELS: Readonly<Record<InfinitusSettingsPath, string>> = {
  "/settings/menu-bar": "Menu bar",
  "/settings/animations": "Animations",
  "/settings/priority": "Priority",
  "/settings/team": "Team",
  "/settings/notifications": "Notifications",
  "/settings/devices": "Devices",
  "/settings/engines": "Engines",
};

// The menu bar app's pages read the primary environment and need no
// selection scope to render.
export const INFINITUS_CATEGORY_SCOPES: Readonly<
  Record<InfinitusSettingsPath, SettingsSearchScope | null>
> = {
  "/settings/menu-bar": null,
  "/settings/animations": null,
  "/settings/priority": null,
  "/settings/team": null,
  "/settings/notifications": null,
  "/settings/devices": null,
  "/settings/engines": null,
};

/**
 * The fork's searchable settings, spread into upstream's `SETTINGS_SEARCH_ITEMS`
 * in this order: the rows the fork adds to General (resume on limit #648,
 * send mode, worktree limit, keep awake #1075) and the Infinitus pages, each
 * indexed once by its destination (the panes are drawn from the native app's
 * own preference catalog) with `targetId` the first section it renders.
 */
export const INFINITUS_SETTINGS_SEARCH_ITEMS = [
  {
    id: "infinitus-resume-on-limit",
    title: "Resume limited threads on another account",
    to: "/settings/general",
    searchTerms: ["usage quota rate limit swap another account resume continue"],
  },
  {
    id: "composer-send-mode",
    title: "Sending while a turn runs",
    to: "/settings/general",
    searchTerms: ["queue steer send next step tool running turn enter composer follow-up"],
  },
  {
    id: "worktree-limit",
    title: "Worktree limit",
    to: "/settings/general",
    searchTerms: ["max worktrees count cap archived threads delete"],
  },
  {
    id: "desktop-keep-awake",
    title: "Keep awake",
    to: "/settings/general",
    searchTerms: ["sleep power nap idle running turn thread mac caffeinate"],
    desktopOnly: true,
  },
  {
    // The Infinitus panes are drawn from the native app's own preference
    // catalog, so each page is indexed once by its destination rather than
    // row by row; `targetId` is the first section the page renders.
    id: "infinitus-preferences",
    title: "Infinitus preferences",
    to: "/settings/menu-bar",
    targetId: "infinitus-display",
    infinitusOnly: true,
    searchTerms: ["menu bar popup startup about threads hide icon"],
  },
  {
    // Fork (#574): the Slack bridge sits on the Menu bar page under Threads.
    id: "infinitus-slack",
    title: "Start threads from Slack",
    to: "/settings/menu-bar",
    targetId: "infinitus-slack",
    searchTerms: ["slack bot mention token socket mode bridge channel"],
    infinitusOnly: true,
  },
  {
    // The theme picker sits on the Menu bar page, under its own section.
    id: "infinitus-themes",
    title: "Infinitus themes",
    to: "/settings/menu-bar",
    targetId: "infinitus-themes",
    infinitusOnly: true,
    searchTerms: ["theme gamification style rpg movie hades picker look"],
  },
  {
    id: "infinitus-animations",
    title: "Infinitus animations",
    to: "/settings/animations",
    targetId: "infinitus-animations",
    infinitusOnly: true,
    searchTerms: ["animation intro slide fade zoom burn ember flame speed motion"],
  },
  {
    id: "infinitus-sessions",
    title: "Infinitus priority",
    to: "/settings/priority",
    // The Mac files these keys under `priority` since #1069; a build older than
    // that still answers `sessions`, and the anchor then only loses its scroll.
    targetId: "infinitus-priority",
    infinitusOnly: true,
    // "session" stays as a search term for anyone who knew the row by its old
    // name; the row itself reads "Thread priority" (#1069).
    searchTerms: [
      "thread session priority mode hold interrupt headroom low abundant pct background",
    ],
  },
  {
    id: "desktop-badge",
    title: "Dock badge",
    to: "/settings/notifications",
    targetId: "desktop-notifications",
    infinitusOnly: true,
    searchTerms: ["dock icon badge count unread attention"],
  },
  {
    id: "infinitus-team",
    title: "Infinitus team",
    to: "/settings/team",
    targetId: "infinitus-team",
    infinitusOnly: true,
    searchTerms: [
      "team members invite token join create share transcripts leader grants private projects connect",
    ],
  },
  {
    id: "infinitus-push",
    title: "Infinitus notifications",
    to: "/settings/notifications",
    targetId: "infinitus-push",
    infinitusOnly: true,
    // The four rows left are account events (#1041 took `push_waiting` and
    // `push_aws_login` with the Mac's session tracker), so the terms name
    // those and nothing else.
    searchTerms: ["push phone notification account exhausted limit revived revive countdown lead"],
  },
  {
    id: "infinitus-devices",
    title: "Infinitus devices",
    to: "/settings/devices",
    targetId: "infinitus-devices",
    infinitusOnly: true,
    // "live activity" went with the Mac's cards and the phone mirror with its
    // server (#1041), the push key with #1375, the Cloudflare tunnel with
    // Infinitus Connect, the "Pair a phone" QR with Connections' own pairing
    // link; the page is this Mac's name, the server's port, the settings
    // sync switches, the pairing requests a phone sends and the Mac's crash
    // reports.
    searchTerms: ["phone pair port name", "machine sync crash hang report"],
  },
  {
    id: "infinitus-engines",
    title: "Infinitus engines",
    to: "/settings/engines",
    targetId: "infinitus-engines",
    infinitusOnly: true,
    searchTerms: [
      "swapd cliproxy 9router proxy accounts registered key policy strategy threshold model switching",
      "management key dashboard password base url test connection",
      "routing strategy session affinity daemon",
      "about version build release",
      "activity events switches log",
    ],
  },
] as const satisfies ReadonlyArray<SettingsSearchItem>;
