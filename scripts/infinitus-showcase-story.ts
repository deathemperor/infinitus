// Fork: the Infinitus screenshot story. `mobile-showcase-environment.ts`
// seeds this instead of upstream's fixture when `SHOWCASE_APP_VARIANT=infinitus`,
// so the store screenshots show the fork's own work (account fleet, holds,
// pairing approval) rather than upstream's fixture with the name swapped
// (App Review, Guideline 4.3(a), 2026-09-28). Ids stay upstream's: the
// agent-activity scene and the capture coordinator key on them.

export const INFINITUS_STORY_BRANCH = "feat/fleet-rotation";

export const INFINITUS_PROJECT_TITLES = {
  react: {
    title: "Lumen",
    directory: "lumen",
    repositoryUrl: "https://github.com/lumen-labs/lumen.git",
  },
  linux: {
    title: "Atlas API",
    directory: "atlas-api",
    repositoryUrl: "https://github.com/atlas-hq/atlas-api.git",
  },
} as const;

export const INFINITUS_PROJECT_FAVICONS = {
  react: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
  <rect width="64" height="64" rx="15" fill="#f6b73c"/>
  <circle cx="32" cy="32" r="13" fill="none" stroke="#1f1a0a" stroke-width="5"/>
  <path d="M32 8v10M32 46v10M8 32h10M46 32h10" stroke="#1f1a0a" stroke-width="5" stroke-linecap="round"/>
</svg>`,
  linux: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
  <rect width="64" height="64" rx="15" fill="#0f766e"/>
  <path d="M14 44L32 14l18 30H14z" fill="none" stroke="#ecfdf5" stroke-width="5" stroke-linejoin="round"/>
  <path d="M24 44l8-14 8 14" fill="none" stroke="#ecfdf5" stroke-width="5" stroke-linejoin="round"/>
</svg>`,
} as const;

export const INFINITUS_ENVIRONMENT_LABELS = {
  "moonbase-terminal": "Mac Studio",
  "suspense-station": "Work MacBook",
  "kernel-cabin": "Home Mini",
} as const;

/** The flagship workspace's files: the base commit, then the branch's edit and its new file. */
export const INFINITUS_WORKSPACE_FILES = {
  base: {
    "apps/mobile/src/features/accounts/forecast.ts": `export function forecastLabel(usedPct: number): string {
  return \`\${usedPct}% of window used\`;
}
`,
  },
  updated: {
    "apps/mobile/src/features/accounts/forecast.ts": `const HOLD_AT = 85;

export function forecastLabel(usedPct: number, resetsAt: string): string {
  const verdict = usedPct >= HOLD_AT ? "hold" : "run";
  return \`\${usedPct}% used · resets \${resetsAt} · \${verdict}\`;
}
`,
    "apps/mobile/src/features/accounts/AccountRotationCard.tsx": `import { View, Text } from "react-native";

export function AccountRotationCard(props: { from: string; to: string; headroomPct: number }) {
  return (
    <View className="rounded-2xl bg-surface-2 p-4">
      <Text className="font-semibold">Rotated {props.from} → {props.to}</Text>
      <Text className="text-success">{props.headroomPct}% headroom left</Text>
    </View>
  );
}
`,
  },
} as const;

const PROMPT = `\u001b[1;32m→\u001b[0m \u001b[1;36minfinitus\u001b[0m \u001b[1;34mgit:(\u001b[1;31m${INFINITUS_STORY_BRANCH}\u001b[1;34m)\u001b[0m \u001b[1;33m✗\u001b[0m `;

// `infinitusctl fleet`: the account fleet as the Mac's CLI prints it, so the
// terminal scene shows the fork's own tool and exercises the same colors.
export const INFINITUS_TERMINAL_BUFFER = [
  `${PROMPT}infinitusctl fleet`,
  "",
  "  \u001b[1;35mCLAUDE\u001b[0m   \u001b[2mpriority mode:\u001b[0m hold at low headroom",
  "  \u001b[2mACCOUNT      5H WINDOW   RESETS     STATE\u001b[0m",
  "  work         \u001b[31m91 %\u001b[0m        2:10 PM    \u001b[1mactive\u001b[0m",
  "  personal     \u001b[33m78 %\u001b[0m        3:40 PM    ready",
  "",
  "  \u001b[1;36mCODEX\u001b[0m",
  "  team         \u001b[32m23 %\u001b[0m        6:00 PM    \u001b[1mactive\u001b[0m",
  "",
  "  \u001b[43;30m HELD \u001b[0m \u001b[2m1 thread waits for headroom — \u001b[0m\u001b[4;36mrun now\u001b[0m\u001b[2m or pin it\u001b[0m",
  "",
  PROMPT,
].join("\r\n");

export const INFINITUS_THREADS = [
  {
    id: "remote-command-center",
    projectId: "t3code",
    title: "Keep the fleet ahead of the window ✦",
    branch: INFINITUS_STORY_BRANCH,
    minutesAgo: 3,
    request:
      "Watch the Claude fleet while I'm out. When the active account's 5-hour window passes 85 %, hold background starts and move new work to the account with the most headroom.",
    response:
      "Priority mode is on and the fleet reads low. ✦\n\n- Work: 5h window at 91 %, resets 2:10 PM\n- Personal: 5h window at 78 %, resets 3:40 PM\n- Background starts wait for headroom and resume on the account with the most left\n- Pinned threads run regardless; Run now releases one by hand\n\nI also ran the changed workspace: **148 tests passed**.",
  },
  {
    id: "pocket-command-center",
    projectId: "t3code",
    title: "Alert every phone when an account runs dry",
    branch: "feat/account-alerts",
    minutesAgo: 21,
    state: "approval" as const,
    request:
      "When any account in the fleet hits its limit, push one alert to every phone on the team and name the Mac it came from.",
    response:
      "The relay fans the alert out to every linked phone with the machine name in the title. The copy and the sound are ready for approval.",
  },
  {
    id: "buttery-suspense",
    projectId: "react",
    title: "Stream the dashboard shell first",
    branch: "perf/shell-first",
    minutesAgo: 12,
    state: "working" as const,
    request:
      "Paint the dashboard shell before any query resolves, and keep the charts from popping in.",
    response: null,
  },
  {
    id: "hydration-haikus",
    projectId: "react",
    title: "Explain slow queries in plain words",
    branch: "dev/query-explain",
    minutesAgo: 44,
    request:
      "Keep the query plan exact, but open the explanation with one sentence a designer can read.",
    response:
      "Each slow query now leads with a one-line cause and keeps the full plan underneath. Nothing about the thresholds changed.",
    snoozeMinutes: 90,
  },
  {
    id: "beautiful-boot",
    projectId: "linux",
    title: "Rate-limit by tenant, not by IP",
    branch: "feat/tenant-limits",
    minutesAgo: 34,
    state: "plan" as const,
    request:
      "Design tenant-level rate limits that survive a proxy and never punish a whole office for one client.",
    response:
      "The plan keys limits on the tenant claim, keeps the IP limit as a fallback, and adds nothing to the hot path.",
  },
  {
    id: "patient-penguins",
    projectId: "linux",
    title: "Retry webhooks with a reason",
    branch: "feat/webhook-retries",
    minutesAgo: 52,
    request: "Make webhook retries easy to follow without adding noise to the delivery log.",
    response:
      "Each retry now carries the previous attempt's status and a short reason, so a stuck delivery reads at a glance.",
    snoozeMinutes: 8 * 60,
  },
  {
    id: "handoff-haptics",
    projectId: "t3code",
    title: "Approve pairing from the Mac's menu bar",
    branch: "feat/pairing-approval",
    minutesAgo: 5 * 60,
    settled: true,
    request:
      "A phone that finds this Mac on the network should ask, and the Mac should answer from its menu bar.",
    response:
      "The request lands in the menu bar with the phone's name; Allow pairs it, Deny forgets it, and nothing pairs without the answer.",
  },
  {
    id: "streaming-shell",
    projectId: "react",
    title: "Cache the avatar endpoint",
    branch: "feat/avatar-cache",
    minutesAgo: 28 * 60,
    settled: true,
    request:
      "Avatars are fetched on every render. Cache them without serving a stale one after an upload.",
    response:
      "Avatars now cache by content hash and an upload busts its own entry, so the first paint reuses the image and a new one shows at once.",
  },
  {
    id: "quieter-oom",
    projectId: "linux",
    title: "Trim the migration log noise",
    branch: "chore/quiet-migrations",
    minutesAgo: 2 * 24 * 60,
    settled: true,
    request:
      "Migrations log every statement. Keep the failures loud and make the rest one line each.",
    response:
      "A migration now logs one line on success and the full statement only on failure, assembled from data the runner already had.",
  },
] as const;

/** The flagship thread's tool rows, oldest first. */
export const INFINITUS_ACTIVITIES = [
  {
    id: "read-fleet",
    title: "Read the account fleet",
    detail: "2 Claude accounts, 1 Codex · priority mode on",
    itemType: "command_execution",
    minutesAgo: 8,
  },
  {
    id: "hold-at-low",
    title: "Set the hold threshold",
    detail: "2 files changed · hold at 85 % · resume on the freest account",
    itemType: "file_change",
    minutesAgo: 6,
  },
  {
    id: "run-changed-suite",
    title: "Ran the changed workspace",
    detail: "148 tests passed · 3 Macs online",
    itemType: "command_execution",
    minutesAgo: 4,
  },
] as const;

/** The held row the session-priority layer leaves when it keeps a start
    (`InfinitusSessionHold.ts`), so the thread scene shows the hold card. */
export const INFINITUS_HOLD_MARKER = {
  id: "held-for-headroom",
  kind: "infinitus.thread.held",
  summary: "Held for headroom on claude, 5h window 91 %",
  minutesAgo: 1,
} as const;
