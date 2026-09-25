import type {
  InfinitusAccount,
  InfinitusAwsLogin,
  InfinitusFleet,
  InfinitusSnapshot,
} from "@infinitus/contracts/infinitus";
import type {
  OrchestrationMessage,
  OrchestrationShellSnapshot,
  OrchestrationThreadShell,
  ThreadId,
} from "@infinitus/contracts";
import type {
  TeamCapability,
  TeamCommandOutcome,
  TeamGrant,
  TeamQueuedCommand,
} from "@infinitus/contracts/relayInfinitusTeam";
import { teamCommandNeedsTap } from "@infinitus/contracts/relayInfinitusTeam";
import { stableStringify } from "@infinitus/shared/relaySigning";
import * as DateTime from "effect/DateTime";
import * as Option from "effect/Option";
import * as Schema from "effect/Schema";

/**
 * The pure half of the desktop's Team publisher (#1592): what the relay's
 * documents look like, built from the thread shells and the Mac's snapshot.
 * The shapes are the Mac's old `TeamDocs` (`now`, `fleet`, the threads
 * index, transcript rows), so a teammate's view reads either. Times are
 * unix seconds, as they were; a project is its workspace basename, never
 * the path; an account is its alias or `#n`, never the email.
 */

/** Newest threads the index carries; older ones fall off it. */
const THREADS_INDEX_CAP = 500;
/** A transcript chunk never passes this many bytes of lines. */
const TRANSCRIPT_CHUNK_MAX_BYTES = 1 << 20;
/** Threads updated within this window publish transcripts. */
export const TRANSCRIPT_HISTORY_DAYS = 30;
/** A `view` answer is cut here. */
const VIEW_MAX_CHARS = 4096;
/** A window at or past this is "limited". */
const LIMITED_PCT = 90;
const EXPIRED_STATUSES = new Set(["relogin_required", "token_expired", "no_credentials"]);

export interface TeamWindow {
  readonly label: string;
  readonly pct: number;
  readonly resetsAt?: number;
}

export interface TeamLiveThread {
  readonly id: string;
  readonly title: string;
  readonly project: string;
  readonly startedAt?: number;
  readonly activityLine?: string;
}

export interface TeamThreadRow {
  readonly id: string;
  readonly title: string;
  readonly project: string;
  readonly status: string;
  readonly createdAt: number;
  readonly updatedAt: number;
  readonly turns: number;
  readonly usage?: {
    readonly inputTokens: number;
    readonly outputTokens: number;
    readonly costUsd: number | null;
    readonly models: ReadonlyArray<string>;
  };
}

export interface TeamTranscriptRow {
  readonly role: string;
  readonly text: string;
  readonly at?: number;
}

export const unixSeconds = (iso: string | null | undefined): number | undefined => {
  if (!iso) return undefined;
  const parsed = DateTime.make(iso);
  return Option.isSome(parsed) ? Math.floor(DateTime.toEpochMillis(parsed.value) / 1000) : undefined;
};

export const basename = (path: string): string => {
  const parts = path.split("/").filter((part) => part.length > 0);
  return parts[parts.length - 1] ?? "";
};

/** archived | failed | starting | waiting | running | idle: the Mac's
    `TeamThreadSources.status`, the two states a teammate wants to see over
    the desktop verbs' word. */
function threadStatus(thread: OrchestrationThreadShell): string {
  if (thread.archivedAt !== null) return "archived";
  if (thread.latestTurn?.state === "error") return "failed";
  if (thread.session?.status === "starting") return "starting";
  if (thread.hasPendingApprovals || thread.hasPendingUserInput) return "waiting";
  if (thread.latestTurn?.state === "running" || thread.session?.status === "running") {
    return "running";
  }
  return "idle";
}

/** A private project keeps its threads, live rows and transcripts home:
    the Mac's exclusions are project basenames and Claude project slugs
    (the basename with every non-alphanumeric run as `-`). */
export function isExcluded(project: string, exclusions: ReadonlyArray<string>): boolean {
  if (exclusions.length === 0) return false;
  const slug = project.replace(/[^A-Za-z0-9]+/g, "-");
  return exclusions.some((entry) => entry === project || entry === slug || entry === `-${slug}`);
}

/** The threads index (newest change first, capped) and the live rows for
    `now`, from one shell snapshot. */
export function buildThreadsDocument(
  shell: OrchestrationShellSnapshot,
  input: { readonly now: number; readonly exclusions: ReadonlyArray<string> },
): {
  readonly document: { readonly at: number; readonly threads: ReadonlyArray<TeamThreadRow> };
  readonly live: ReadonlyArray<TeamLiveThread>;
  readonly projectOf: ReadonlyMap<string, string>;
} {
  const projects = new Map(shell.projects.map((project) => [project.id, project]));
  const rows: Array<TeamThreadRow> = [];
  const live: Array<TeamLiveThread> = [];
  const projectOf = new Map<string, string>();
  for (const thread of shell.threads) {
    const workspaceRoot = projects.get(thread.projectId)?.workspaceRoot;
    const project = workspaceRoot === undefined ? thread.projectId : basename(workspaceRoot);
    if (isExcluded(project, input.exclusions)) continue;
    projectOf.set(thread.id, project);
    const updatedAt = unixSeconds(thread.updatedAt) ?? input.now;
    const status = threadStatus(thread);
    rows.push({
      id: thread.id,
      title: thread.title,
      project,
      status,
      createdAt: unixSeconds(thread.createdAt) ?? updatedAt,
      updatedAt,
      turns: thread.usage?.turns ?? 0,
      ...(thread.usage === undefined
        ? {}
        : {
            usage: {
              inputTokens: thread.usage.inputTokens,
              outputTokens: thread.usage.outputTokens,
              costUsd: thread.usage.costUsd,
              models: thread.usage.models,
            },
          }),
    });
    if (status === "starting" || status === "running" || status === "waiting") {
      const startedAt = unixSeconds(thread.latestTurn?.startedAt);
      live.push({
        id: thread.id,
        title: thread.title,
        project,
        ...(startedAt === undefined ? {} : { startedAt }),
        ...(status === "waiting"
          ? { activityLine: thread.hasPendingApprovals ? "Waiting for approval" : "Waiting for input" }
          : {}),
      });
    }
  }
  rows.sort((a, b) => (a.updatedAt === b.updatedAt ? (a.id < b.id ? -1 : 1) : b.updatedAt - a.updatedAt));
  return { document: { at: input.now, threads: rows.slice(0, THREADS_INDEX_CAP) }, live, projectOf };
}

const UsageWindow = Schema.Struct({
  pct: Schema.Finite,
  resetsAt: Schema.optionalKey(Schema.NullOr(Schema.String)),
  name: Schema.optionalKey(Schema.NullOr(Schema.String)),
});
/** The engine's usage block is `Unknown` on the contract: the three window
    fields are read defensively and anything missing is skipped. */
const AccountUsage = Schema.Struct({
  fiveHour: Schema.optionalKey(Schema.NullOr(UsageWindow)),
  sevenDay: Schema.optionalKey(Schema.NullOr(UsageWindow)),
  scoped: Schema.optionalKey(Schema.NullOr(Schema.Array(UsageWindow))),
});
const decodeUsage = Schema.decodeUnknownOption(AccountUsage);

const window = (label: string, w: typeof UsageWindow.Type): TeamWindow => {
  const resetsAt = unixSeconds(w.resetsAt);
  return { label, pct: Math.round(w.pct), ...(resetsAt === undefined ? {} : { resetsAt }) };
};

const accountLabel = (account: InfinitusAccount): string =>
  account.alias !== undefined && account.alias.length > 0 ? account.alias : `#${account.number}`;

function accountWindows(account: InfinitusAccount): {
  readonly windows: ReadonlyArray<TeamWindow>;
  readonly models: ReadonlyArray<TeamWindow>;
  readonly pcts: ReadonlyArray<number>;
} {
  const usage = Option.getOrUndefined(decodeUsage(account.usage));
  const windows: Array<TeamWindow> = [];
  if (usage?.fiveHour) windows.push(window("5h", usage.fiveHour));
  if (usage?.sevenDay) windows.push(window("7d", usage.sevenDay));
  const models = (usage?.scoped ?? []).map((w) => window(w.name ?? "?", w));
  return { windows, models, pcts: [...windows, ...models].map((w) => w.pct) };
}

/** `held` | `expiredLogin` | `dead` (a window maxed) | `limited` (one in
    the 90s) | `ok`, the old `FleetDoc.status`. */
function accountStatus(account: InfinitusAccount): string {
  if (account.disabled === true) return "held";
  if (EXPIRED_STATUSES.has(account.usageStatus)) return "expiredLogin";
  const { pcts } = accountWindows(account);
  if (pcts.some((pct) => pct >= 100)) return "dead";
  return pcts.some((pct) => pct >= LIMITED_PCT) ? "limited" : "ok";
}

export function buildFleetDocument(fleets: ReadonlyArray<InfinitusFleet>, at: number) {
  return {
    schema: 1,
    at,
    fleets: fleets.map((fleet) => {
      const name = (number: number | undefined) => {
        const account = fleet.accounts.find((candidate) => candidate.number === number);
        return account === undefined ? null : accountLabel(account);
      };
      return {
        engine: fleet.engineID,
        active: name(fleet.activeNumber),
        next: name(fleet.nextCandidate),
        accounts: fleet.accounts.map((account) => {
          const { windows, models } = accountWindows(account);
          return {
            label: accountLabel(account),
            tier: account.plan ?? null,
            status: accountStatus(account),
            active: account.number === fleet.activeNumber,
            windows,
            models,
          };
        }),
      };
    }),
  };
}

/** `now.fleets`: each engine's active account with its two windows. */
function nowFleets(fleets: ReadonlyArray<InfinitusFleet>) {
  return fleets.map((fleet) => {
    const active = fleet.accounts.find((account) => account.number === fleet.activeNumber);
    return {
      engine: fleet.engineID,
      account: active === undefined ? null : accountLabel(active),
      windows: active === undefined ? [] : accountWindows(active).windows,
    };
  });
}

/** The blockers the Mac's pop-out shows: lapsed logins and an engine with
    every account limited. */
function blockers(snapshot: InfinitusSnapshot): ReadonlyArray<string> {
  const logins = (snapshot.awsLogins ?? []).map(
    (login: InfinitusAwsLogin) =>
      `${login.provider === "gcloud" ? "gcloud login" : "AWS login"}: ${login.profile}`,
  );
  const limited = snapshot.fleets
    .filter(
      (fleet) =>
        fleet.accounts.length > 0 &&
        fleet.activeNumber === undefined &&
        fleet.nextCandidate === undefined,
    )
    .map((fleet) => `${fleet.engineID}: every account limited`);
  return [...logins, ...limited];
}

export function buildNowDocument(input: {
  readonly at: number;
  readonly machine: string;
  readonly live: ReadonlyArray<TeamLiveThread>;
  readonly snapshot: InfinitusSnapshot | null;
}) {
  return {
    schema: 1,
    at: input.at,
    machine: input.machine,
    desktop: true,
    live: input.live,
    fleets: input.snapshot === null ? [] : nowFleets(input.snapshot.fleets),
    blockers: input.snapshot === null ? [] : blockers(input.snapshot),
  };
}

/** A thread's messages as transcript rows, oldest first, as the Mac read
    them off the desktop: every finished message with text. */
export function transcriptRows(messages: ReadonlyArray<OrchestrationMessage>): ReadonlyArray<TeamTranscriptRow> {
  const rows: Array<TeamTranscriptRow> = [];
  for (const message of messages) {
    if (message.streaming || message.text.length === 0) continue;
    const at = unixSeconds(message.createdAt);
    rows.push({ role: message.role, text: message.text, ...(at === undefined ? {} : { at }) });
  }
  return rows;
}

const TranscriptLine = Schema.Struct({
  role: Schema.String,
  text: Schema.String,
  at: Schema.optional(Schema.Number),
});
const encodeLine = Schema.encodeUnknownSync(Schema.fromJsonString(TranscriptLine));
const utf8 = new TextEncoder();

/** One JSON line per row, redacted, gathered into chunks of at most
    `maxBytes`: a line is never split, and a line above the cap is its own
    chunk. */
export function chunkLines(
  rows: ReadonlyArray<TeamTranscriptRow>,
  redact: (line: string) => string,
  maxBytes: number = TRANSCRIPT_CHUNK_MAX_BYTES,
): ReadonlyArray<{ readonly lines: string; readonly rows: number }> {
  const chunks: Array<{ lines: string; rows: number }> = [];
  let current = "";
  let currentRows = 0;
  let currentBytes = 0;
  for (const row of rows) {
    const line = `${redact(encodeLine(row))}\n`;
    const bytes = utf8.encode(line).byteLength;
    if (currentRows > 0 && currentBytes + bytes > maxBytes) {
      chunks.push({ lines: current, rows: currentRows });
      current = "";
      currentRows = 0;
      currentBytes = 0;
    }
    current += line;
    currentRows += 1;
    currentBytes += bytes;
  }
  if (currentRows > 0) chunks.push({ lines: current, rows: currentRows });
  return chunks;
}

/** A stats day is resent only when this changes: FNV-1a over the stable
    JSON, so key order is nothing. */
export function dayDigest(body: unknown): string {
  const text = stableStringify(body);
  let hash = 0x811c9dc5;
  for (let i = 0; i < text.length; i += 1) {
    hash ^= text.charCodeAt(i);
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return hash.toString(16);
}

/** The `view` answer: the last messages as `role: text` lines through the
    redactor, cut at the cap. */
export function viewText(
  messages: ReadonlyArray<OrchestrationMessage>,
  redact: (line: string) => string,
): string {
  const joined = transcriptRows(messages)
    .map((row) => redact(`${row.role}: ${row.text}`))
    .join("\n");
  return joined.length > VIEW_MAX_CHARS ? joined.slice(joined.length - VIEW_MAX_CHARS) : joined;
}

export type CommandDecision =
  | { readonly run: true }
  | { readonly run: false; readonly outcome: TeamCommandOutcome; readonly detail: string };

/** The local re-check before a queued command runs: its grant must still
    be in the last memberships reply, unexpired, and cover the action and
    the thread (the relay checked the audience when it queued it); a `send`
    or `interrupt` needs a live thread; `interrupt` and `new` outside the
    grant's preauthorized set wait for the grantor's tap. */
export function decideCommand(
  command: TeamQueuedCommand,
  input: {
    readonly grants: ReadonlyArray<TeamGrant>;
    readonly liveThreadIds: ReadonlySet<string>;
    readonly nowIso: string;
  },
): CommandDecision {
  const grant = input.grants.find((candidate) => candidate.grantId === command.grant.grantId);
  if (grant === undefined) return { run: false, outcome: "refused", detail: "That grant was revoked." };
  const action: TeamCapability = command.action;
  const covers =
    (grant.expiresAt === null || grant.expiresAt > input.nowIso) &&
    grant.capabilities.includes(action) &&
    (action === "new"
      ? command.threadId === "-"
      : command.threadId !== "-" &&
        (grant.threads === "all" || grant.threads.includes(command.threadId as ThreadId)));
  if (!covers) return { run: false, outcome: "noGrant", detail: "They have not let you do that." };
  if ((action === "send" || action === "interrupt") && !input.liveThreadIds.has(command.threadId)) {
    return { run: false, outcome: "notLive", detail: "That thread is not live." };
  }
  if ((action === "send" || action === "new") && (command.text === undefined || command.text.trim().length === 0)) {
    return { run: false, outcome: "badRequest", detail: "Nothing to send." };
  }
  if (teamCommandNeedsTap(grant, action)) {
    return { run: false, outcome: "pending", detail: "Waiting for their tap." };
  }
  return { run: true };
}
