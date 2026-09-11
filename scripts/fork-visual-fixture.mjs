#!/usr/bin/env node
/**
 * An Infinitus control socket for the fork's visual pass in CI: one Node net
 * server that speaks the control protocol (one JSON line in, one JSON line
 * out, then the connection closes) and answers the read verbs the web pages
 * poll with canned data, so every fork route can render its populated state
 * on a runner that has no menu-bar app.
 *
 *   node scripts/fork-visual-fixture.mjs --socket /tmp/inf-vp.sock
 *
 * The manifest and the preference catalog in `fork-visual-fixture.data.json`
 * are `infinitusctl manifest --json` / `prefs --json` captures with every
 * pref value reset to its default; accounts, sessions, the team, the profiles,
 * the forecast and the stats are made up. Secrets: none — every write verb
 * and every unknown verb is refused with `ok: false`, and only verb names are
 * logged. No dependencies; node ≥ 22.
 */
import * as NodeFS from "node:fs";
import * as NodeNet from "node:net";
import * as NodePath from "node:path";

const data = JSON.parse(
  NodeFS.readFileSync(NodePath.join(import.meta.dirname, "fork-visual-fixture.data.json"), "utf8"),
);

function parseArgs(argv) {
  let socket;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--socket") socket = argv[++i];
  }
  if (!socket) throw new Error("usage: fork-visual-fixture.mjs --socket <path>");
  return { socket };
}

const nowSeconds = () => Math.floor(Date.now() / 1000);
const isoIn = (seconds) => new Date(Date.now() + seconds * 1000).toISOString();
const dayKey = (daysAgo) => new Date(Date.now() - daysAgo * 86_400_000).toISOString().slice(0, 10);

/** A usage window as the swapd engine reports it (percent, countdown, reset). */
const usageWindow = (name, pct, resetsIn) => ({
  name,
  pct,
  countdown: `${Math.floor(resetsIn / 3600)}h ${Math.floor((resetsIn % 3600) / 60)}m`,
  clock: isoIn(resetsIn),
  resetsAt: isoIn(resetsIn),
  aheadOfPace: pct < 50,
  expectedPct: 50,
  willLastToReset: pct < 80,
});

const ACCOUNTS = [
  { number: 1, alias: "ada-fixture", email: "ada@example.com", active: true, five: 34, seven: 40 },
  {
    number: 2,
    alias: "grace-fixture",
    email: "grace@example.com",
    active: false,
    five: 0,
    seven: 66,
  },
  {
    number: 3,
    alias: "linus-fixture",
    email: "linus@example.com",
    active: false,
    five: 12,
    seven: 8,
  },
];

const fleets = () => [
  {
    key: "claude",
    engineID: "swapd",
    provider: "claude",
    capabilities: ["switch", "rotate", "hold", "unhold", "rename", "prefer", "reorder", "ignite"],
    activeNumber: 1,
    nextCandidate: 3,
    candidateOrder: [1, 3, 2],
    accounts: ACCOUNTS.map((account) => ({
      number: account.number,
      alias: account.alias,
      email: account.email,
      plan: "max",
      active: account.active,
      disabled: false,
      preferred: account.number === 1,
      isOrganization: false,
      usage: {
        fiveHour: usageWindow("5h", account.five, 2 * 3600 + 600),
        sevenDay: usageWindow("7d", account.seven, 3 * 86_400 + 5 * 3600),
        scoped: [],
      },
      usageStatus: "ok",
      usageAgeSeconds: 42,
      usageFetchedAt: isoIn(-42),
    })),
  },
];

const forecastLine = (account) => ({
  number: account.number,
  email: account.email,
  alias: account.alias,
  active: account.active,
  disabled: false,
  windows: [
    {
      name: "5h",
      pct: account.five,
      ratePctPerHour: account.active ? 12.5 : 0,
      resetsAt: nowSeconds() + 2 * 3600 + 600,
      hitsAt: account.active ? nowSeconds() + 5 * 3600 : null,
    },
    {
      name: "7d",
      pct: account.seven,
      ratePctPerHour: account.active ? 0.8 : 0,
      resetsAt: nowSeconds() + 3 * 86_400 + 5 * 3600,
      hitsAt: null,
    },
  ],
});

const forecast = () => ({
  forecast: {
    computedAt: nowSeconds(),
    basis: "Fixture rates: the last hour of polls, straight-line.",
    active: forecastLine(ACCOUNTS[0]),
    accounts: ACCOUNTS.map(forecastLine),
    allDeadAt: nowSeconds() + 6 * 86_400,
    drainOrder: [1, 3, 2],
  },
});

const sessions = () => [
  {
    pid: 4242,
    name: "visual pass",
    cwd: "/home/runner/work/app",
    status: "idle",
    kind: "interactive",
    permissionMode: null,
    profile: null,
    sessionId: "00000000-0000-4000-8000-000000004242",
    account: "ada-fixture",
    startedAt: isoIn(-1800),
    needs: [],
  },
];

const profiles = () => ({
  profiles: [
    {
      name: "nightly-review",
      cwd: "~/code/app",
      engine: "claude",
      permissionMode: "acceptEdits",
      model: "opus",
      allowTools: ["Edit", "Bash git"],
    },
    { name: "docs-sweep", engine: "codex", prompt: "Read the docs folder and list what is stale." },
  ],
});

const teamStatus = () => {
  const now = nowSeconds();
  return {
    id: "team-fixture",
    name: "Lighthouse",
    remote: "github.com/example/••••••",
    kid: "kid-fixture-me",
    role: "leader",
    rev: 3,
    members: [
      {
        kid: "kid-fixture-me",
        name: "Ada's Mac",
        role: "leader",
        isMe: true,
        founder: true,
        lastPublished: now - 120,
        kinds: ["fleet", "sessions"],
        sessionsNow: 1,
        blockers: [],
        crashes: 0,
        todayUSD: 12.5,
        todayMessages: 40,
        todayCommits: 3,
      },
      {
        kid: "kid-fixture-grace",
        name: "Grace's Mac",
        role: "member",
        isMe: false,
        founder: false,
        lastPublished: now - 900,
        kinds: ["fleet"],
        sessionsNow: 2,
        blockers: ["waiting on a review"],
        crashes: 0,
        todayUSD: 4.25,
        todayMessages: 12,
        todayCommits: 1,
      },
    ],
    requests: [
      {
        kid: "kid-fixture-linus",
        name: "Linus's Mac",
        platform: "macOS",
        devices: ["iPhone"],
        at: now - 600,
      },
    ],
    lastFetch: now - 60,
    lastPublish: now - 30,
    lastError: null,
  };
};

const tally = (n, usd) => ({
  n,
  s: n * 90,
  in: n * 4000,
  out: n * 900,
  usd,
  cr: n * 30_000,
  cw: n * 2000,
  sv: usd,
});

const statsDay = (scale) => ({
  humanMessages: 40 * scale,
  phoneMessages: 6 * scale,
  agentMessages: 120 * scale,
  turns: 90 * scale,
  toolCalls: { Edit: 55 * scale, Bash: 70 * scale, Read: 140 * scale },
  waitingSeconds: 1800 * scale,
  compactions: 2 * scale,
  inputTokens: 900_000 * scale,
  outputTokens: 120_000 * scale,
  usd: 18.4 * scale,
  cacheReadTokens: 6_000_000 * scale,
  cacheWriteTokens: 400_000 * scale,
  cacheSavingsUSD: 9.1 * scale,
  peakTokensPerMinute: 42_000,
  activities: {
    code: tally(30 * scale, 9.2 * scale),
    review: tally(8 * scale, 3.1 * scale),
    debug: tally(6 * scale, 2.4 * scale),
  },
  byModel: {
    "claude-opus-5": tally(30 * scale, 12.4 * scale),
    "claude-sonnet-5": tally(14 * scale, 3.2 * scale),
  },
  byEngine: { claude: tally(40 * scale, 15.1 * scale), codex: tally(4 * scale, 0.9 * scale) },
  byEffort: { high: tally(20 * scale, 10.5 * scale), medium: tally(24 * scale, 4.6 * scale) },
  sessionTally: 6 * scale,
  sessionSeconds: 5 * 3600 * scale,
  sessionBuckets: [2 * scale, 2 * scale, 1 * scale, 1 * scale],
  commits: 9 * scale,
  linesAdded: 640 * scale,
  linesRemoved: 210 * scale,
  filesTouched: 31 * scale,
  coAuthoredByClaude: 9 * scale,
  prsOpened: 3 * scale,
  prsMerged: 2 * scale,
  switches: 1 * scale,
  limitStops: 0,
  minutesLostToLimits: 0,
});

const stats = (period) => {
  const days = period === "day" ? 1 : period === "month" ? 30 : period === "year" ? 365 : 7;
  const shown = Math.min(days, 7);
  return {
    period,
    from: dayKey(days - 1),
    to: dayKey(0),
    total: statsDay(days),
    previous: statsDay(Math.max(1, days - 1)),
    daily: Array.from({ length: shown }, (_, index) => ({
      key: dayKey(shown - 1 - index),
      day: statsDay(1),
    })),
    streak: 5,
  };
};

const events = () => [
  {
    id: "evt-1",
    at: isoIn(-3600),
    kind: "switch",
    icon: "arrow.triangle.2.circlepath",
    text: "Switched to ada-fixture",
  },
  { id: "evt-2", at: isoIn(-1200), kind: "team", icon: "person.3", text: "Grace's Mac published" },
  {
    id: "evt-3",
    at: isoIn(-300),
    kind: "other",
    icon: "sparkles",
    text: "Visual pass fixture is answering",
  },
];

/** The reply `result` for one request, or undefined for a verb the fixture refuses. */
function answer(request, socketPath) {
  const { command, args = [], options = {} } = request;
  switch (command) {
    case "manifest":
      return data.manifest;
    case "status":
      return {
        version: "0.0.0-fixture",
        sha: "fixture",
        socket: socketPath,
        badge: "",
        playground: false,
        signInRunning: false,
        engines: {
          swapd: { enabled: true, registered: true },
          cliproxy: { enabled: false, registered: false, keyPresent: false },
          "9router": { enabled: false, registered: false, keyPresent: false },
        },
        forkTunnel: { enabled: false, port: 3773, state: "off" },
      };
    case "fleets":
    case "refresh":
      return fleets();
    case "forecast":
      return forecast();
    case "sessions":
      return sessions();
    case "prefs":
      // One verb for reads and writes; the fixture holds no state to write.
      return args[0] === "set" ? undefined : data.prefs;
    case "profiles":
      return profiles();
    case "stats":
      return stats(typeof options.period === "string" ? options.period : "week");
    case "events":
      return options.after === undefined
        ? events()
        : { after: options.after, known: true, rows: [] };
    case "aws-logins":
      return { logins: [] };
    case "client-activity":
      return { clientId: "fixture" };
    case "lock-status":
      return { enabled: true, locked: false, relock: "5 min" };
    case "team-status":
      return teamStatus();
    default:
      return undefined;
  }
}

const options = parseArgs(process.argv.slice(2));
const schemaVersion = data.manifest.schemaVersion;
NodeFS.rmSync(options.socket, { force: true });

const server = NodeNet.createServer((socket) => {
  let buffer = "";
  socket.setEncoding("utf8");
  socket.on("data", (chunk) => {
    buffer += chunk;
    const newline = buffer.indexOf("\n");
    if (newline === -1) return;
    let reply;
    let verb = "?";
    try {
      const request = JSON.parse(buffer.slice(0, newline));
      verb = typeof request.command === "string" ? request.command : "?";
      const result = answer(request, options.socket);
      reply =
        result === undefined
          ? { schemaVersion, ok: false, error: `fixture: no answer for ${verb}` }
          : { schemaVersion, ok: true, result };
    } catch {
      reply = { schemaVersion, ok: false, error: "fixture: request was not one JSON line" };
    }
    // Verb names only: a request may carry material the fixture must not keep.
    console.error(`fixture: ${verb} -> ${reply.ok ? "ok" : "refused"}`);
    socket.end(`${JSON.stringify(reply)}\n`);
  });
  socket.on("error", () => socket.destroy());
});

const stop = () => {
  server.close();
  NodeFS.rmSync(options.socket, { force: true });
  process.exit(0);
};
process.on("SIGINT", stop);
process.on("SIGTERM", stop);

server.listen(options.socket, () => {
  console.log(`fixture listening on ${options.socket}`);
});
