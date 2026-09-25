/** Pure calendar and merge rules shared by the server and clients. */
import * as DateTime from "effect/DateTime";
import type {
  StatsDay,
  StatsRequest,
  StatsSnapshot,
  StatsSummary,
  ActivityTallyPayload,
} from "@infinitus/contracts";

export function statsDayFormatter(timeZone: string) {
  const format = new Intl.DateTimeFormat("en-CA", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  });
  return (ms: number) => format.format(ms);
}

export function shiftStatsDay(day: string, count: number): string {
  const date = DateTime.makeUnsafe(day + "T12:00:00Z");
  return DateTime.formatIsoDateUtc(DateTime.add(date, { days: count }));
}

/** Calendar periods, Monday weeks, identical regardless of the server's zone. */
export function statsWindow(input: StatsRequest) {
  const date = DateTime.makeUnsafe(input.today + "T12:00:00Z");
  if (DateTime.formatIsoDateUtc(date) !== input.today) throw new Error("Invalid reporting day");
  statsDayFormatter(input.timeZone);
  let from = input.today as string;
  let previousFrom: string;
  let to: string;
  switch (input.period) {
    case "day":
      previousFrom = shiftStatsDay(from, -1);
      to = from;
      break;
    case "week":
      from = shiftStatsDay(from, -((DateTime.toPartsUtc(date).weekDay + 6) % 7));
      previousFrom = shiftStatsDay(from, -7);
      to = shiftStatsDay(from, 6);
      break;
    case "month": {
      const first = DateTime.setPartsUtc(date, { day: 1 });
      from = DateTime.formatIsoDateUtc(first);
      to = shiftStatsDay(DateTime.formatIsoDateUtc(DateTime.add(first, { months: 1 })), -1);
      previousFrom = DateTime.formatIsoDateUtc(DateTime.add(first, { months: -1 }));
      break;
    }
    case "year":
      from = `${DateTime.toPartsUtc(date).year}-01-01`;
      to = `${DateTime.toPartsUtc(date).year}-12-31`;
      previousFrom = `${DateTime.toPartsUtc(date).year - 1}-01-01`;
      break;
  }
  return { from, to, previousFrom };
}

const n = (v: number | undefined) => v ?? 0;
function sumTable(
  a: Readonly<Record<string, ActivityTallyPayload>> = {},
  b: Readonly<Record<string, ActivityTallyPayload>> = {},
) {
  const out = { ...a };
  for (const [key, value] of Object.entries(b)) {
    const old = out[key] ?? {};
    out[key] = {
      n: n(old.n) + n(value.n),
      s: n(old.s) + n(value.s),
      in: n(old.in) + n(value.in),
      out: n(old.out) + n(value.out),
      usd: n(old.usd) + n(value.usd),
      cr: n(old.cr) + n(value.cr),
      cw: n(old.cw) + n(value.cw),
      sv: n(old.sv) + n(value.sv),
      unpriced: n(old.unpriced) + n(value.unpriced),
    };
  }
  return out;
}
export function addStatsDays(a: StatsDay, b: StatsDay): StatsDay {
  const tools = { ...a.toolCalls };
  for (const [key, value] of Object.entries(b.toolCalls ?? {}))
    tools[key] = (tools[key] ?? 0) + value;
  return {
    unpricedRecords: n(a.unpricedRecords) + n(b.unpricedRecords),
    pricedRecords: n(a.pricedRecords) + n(b.pricedRecords),
    humanMessages: n(a.humanMessages) + n(b.humanMessages),
    phoneMessages: n(a.phoneMessages) + n(b.phoneMessages),
    agentMessages: n(a.agentMessages) + n(b.agentMessages),
    nudges: n(a.nudges) + n(b.nudges),
    turns: n(a.turns) + n(b.turns),
    toolErrors: n(a.toolErrors) + n(b.toolErrors),
    questions: n(a.questions) + n(b.questions),
    denials: n(a.denials) + n(b.denials),
    waitingSeconds: n(a.waitingSeconds) + n(b.waitingSeconds),
    subagents: n(a.subagents) + n(b.subagents),
    compactions: n(a.compactions) + n(b.compactions),
    retries: n(a.retries) + n(b.retries),
    inputTokens: n(a.inputTokens) + n(b.inputTokens),
    outputTokens: n(a.outputTokens) + n(b.outputTokens),
    usd: n(a.usd) + n(b.usd),
    cacheReadTokens: n(a.cacheReadTokens) + n(b.cacheReadTokens),
    cacheWriteTokens: n(a.cacheWriteTokens) + n(b.cacheWriteTokens),
    cacheSavingsUSD: n(a.cacheSavingsUSD) + n(b.cacheSavingsUSD),
    sessionSeconds: n(a.sessionSeconds) + n(b.sessionSeconds),
    commits: n(a.commits) + n(b.commits),
    linesAdded: n(a.linesAdded) + n(b.linesAdded),
    linesRemoved: n(a.linesRemoved) + n(b.linesRemoved),
    filesTouched: n(a.filesTouched) + n(b.filesTouched),
    coAuthoredByClaude: n(a.coAuthoredByClaude) + n(b.coAuthoredByClaude),
    reverts: n(a.reverts) + n(b.reverts),
    prsOpened: n(a.prsOpened) + n(b.prsOpened),
    prsMerged: n(a.prsMerged) + n(b.prsMerged),
    mergeHoursTotal: n(a.mergeHoursTotal) + n(b.mergeHoursTotal),
    mergeCount: n(a.mergeCount) + n(b.mergeCount),
    switches: n(a.switches) + n(b.switches),
    limitStops: n(a.limitStops) + n(b.limitStops),
    revivals: n(a.revivals) + n(b.revivals),
    minutesLostToLimits: n(a.minutesLostToLimits) + n(b.minutesLostToLimits),
    ignites: n(a.ignites) + n(b.ignites),
    resumes: n(a.resumes) + n(b.resumes),

    longestUnattended: Math.max(n(a.longestUnattended), n(b.longestUnattended)),
    peakTokensPerMinute: Math.max(n(a.peakTokensPerMinute), n(b.peakTokensPerMinute)),
    sessions: [...new Set([...(a.sessions ?? []), ...(b.sessions ?? [])])],
    repos: [...new Set([...(a.repos ?? []), ...(b.repos ?? [])])],
    toolCalls: tools,
    sessionBuckets: Array.from(
      { length: 4 },
      (_, i) => n(a.sessionBuckets?.[i]) + n(b.sessionBuckets?.[i]),
    ),
    activities: sumTable(a.activities, b.activities),
    byModel: sumTable(a.byModel, b.byModel),
    byEngine: sumTable(a.byEngine, b.byEngine),
    byEffort: sumTable(a.byEffort, b.byEffort),
  };
}

/** Latest copy of each session wins; git identities dedupe shared clone history. */
export function mergeStats(
  snapshots: readonly StatsSnapshot[],
  request: StatsRequest,
): StatsSummary {
  const window = statsWindow(request);
  const toDay = statsDayFormatter(request.timeZone);
  const days = new Map<string, StatsDay>();
  const add = (key: string, day: StatsDay) => days.set(key, addStatsDays(days.get(key) ?? {}, day));
  const sessions = new Map<string, StatsSnapshot["sessions"][number]>();
  const sessionReadAt = new Map<string, string>();
  const minutes = new Map<number, number>();
  const commits = new Set<string>();
  const prs = new Set<string>();
  const activeDays = new Set<string>();
  let historyFrom = "";
  for (const snapshot of snapshots) {
    if (
      snapshot.contractVersion !== 1 ||
      snapshot.timeZone !== request.timeZone ||
      snapshot.from !== window.from ||
      snapshot.to !== window.to ||
      snapshot.previousFrom !== window.previousFrom
    )
      continue;
    historyFrom = historyFrom > snapshot.historyFrom ? historyFrom : snapshot.historyFrom;
    for (const key of snapshot.activeDays) activeDays.add(key);
    for (const session of snapshot.sessions) {
      const previous = sessions.get(session.id);
      if (
        !previous ||
        session.updatedAt > previous.updatedAt ||
        (session.updatedAt === previous.updatedAt &&
          snapshot.readAt > (sessionReadAt.get(session.id) ?? ""))
      ) {
        sessions.set(session.id, session);
        sessionReadAt.set(session.id, snapshot.readAt);
      }
    }
    for (const repo of snapshot.repositories) {
      for (const commit of repo.commits) {
        // The object hash identifies the same change even across forks/remotes.
        if (commits.has(commit.id)) continue;
        commits.add(commit.id);
        add(toDay(commit.at), {
          commits: 1,
          linesAdded: commit.added,
          linesRemoved: commit.removed,
          filesTouched: commit.files,
          coAuthoredByClaude: commit.coAuthored ? 1 : 0,
          reverts: commit.revert ? 1 : 0,
          repos: [repo.id],
        });
      }
      for (const pr of repo.pullRequests) {
        if (prs.has(pr.id)) continue;
        prs.add(pr.id);
        add(toDay(pr.openedAt), { prsOpened: 1, repos: [repo.id] });
        if (pr.mergedAt !== null)
          add(toDay(pr.mergedAt), {
            prsMerged: 1,
            mergeCount: 1,
            mergeHoursTotal: Math.max(0, pr.mergedAt - pr.openedAt) / 3600000,
            repos: [repo.id],
          });
      }
    }
  }
  for (const session of sessions.values()) {
    for (const point of session.days) add(point.key, point.day);
    for (const [minute, count] of session.minutes)
      minutes.set(minute, (minutes.get(minute) ?? 0) + count);
  }
  for (const [minute, count] of minutes) add(toDay(minute * 60000), { peakTokensPerMinute: count });
  let total: StatsDay = {},
    previous: StatsDay = {};
  const daily: { key: string; day: StatsDay }[] = [];
  for (let key = window.previousFrom; key <= window.to; key = shiftStatsDay(key, 1)) {
    const day = days.get(key) ?? {};
    if (key < window.from) previous = addStatsDays(previous, day);
    else {
      total = addStatsDays(total, day);
      daily.push({ key, day });
    }
  }
  let streak = 0;
  const active = (key: string) => {
    const d = days.get(key);
    return (
      activeDays.has(key) || (!!d && n(d.commits) + n(d.humanMessages) + n(d.phoneMessages) > 0)
    );
  };
  let day = active(request.today) ? (request.today as string) : shiftStatsDay(request.today, -1);
  while (active(day)) {
    streak++;
    day = shiftStatsDay(day, -1);
  }
  return {
    period: request.period,
    from: window.from,
    to: window.to,
    total,
    previous,
    daily,
    streak,
    streakCapped: streak > 0 && day < historyFrom,
  };
}

/** Keep year-long replies proportional to populated metrics, not the tile catalogue. */
export function compactStatsDay(day: StatsDay): StatsDay {
  return Object.fromEntries(
    Object.entries(day).filter(([, value]) => {
      if (typeof value === "number") return value !== 0;
      if (Array.isArray(value))
        return value.length > 0 && (typeof value[0] !== "number" || value.some((n) => n !== 0));
      return value !== undefined && Object.keys(value).length > 0;
    }),
  );
}
