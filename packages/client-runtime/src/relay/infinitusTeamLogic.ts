import type {
  TeamGrant,
  TeamMachine,
  TeamMemberRow,
  TeamPendingCommand,
} from "@infinitus/contracts/relayInfinitusTeam";
import * as Option from "effect/Option";
import * as Schema from "effect/Schema";

/**
 * The pure half of Settings › Team on Infinitus Connect (#1592), shared by
 * the web pane and the phone: the join link's shapes, what a member row
 * says, and how the machines' `now` documents, the threads index and a
 * transcript chunk are read — every one defensively, since the relay keeps
 * them opaque.
 */

const JOIN_LINK_ORIGIN = "https://infinitus.run/join";
/** A machine whose `now` is older than this is offline. */
const MACHINE_ONLINE_MS = 10 * 60_000;

const TOKEN = /^[A-Za-z0-9_-]{16,}$/;

/** The bare token, `infinitus://join/<token>` (the `-dev` scheme too) or
    `https://infinitus.run/join#<token>`, URI-decoded and trimmed; null for
    anything else. */
export function parseJoinInput(text: string): string | null {
  let candidate = text.trim();
  const scheme = /^infinitus(?:-dev)?:\/\/join\/(.+)$/.exec(candidate);
  if (scheme?.[1] !== undefined) candidate = scheme[1];
  else if (/^https?:\/\//i.test(candidate)) {
    const hash = candidate.indexOf("#");
    if (hash === -1) return null;
    candidate = candidate.slice(hash + 1);
  }
  try {
    candidate = decodeURIComponent(candidate).trim();
  } catch {
    return null;
  }
  return TOKEN.test(candidate) ? candidate : null;
}

export function buildJoinLink(token: string): string {
  return `${JOIN_LINK_ORIGIN}#${encodeURIComponent(token)}`;
}

export function relativeTime(iso: string | null | undefined, nowMs: number): string {
  if (!iso) return "never";
  const at = Date.parse(iso);
  if (Number.isNaN(at)) return "never";
  const seconds = Math.max(0, Math.round((nowMs - at) / 1000));
  if (seconds < 60) return "just now";
  if (seconds < 3600) return `${Math.floor(seconds / 60)} min ago`;
  if (seconds < 86_400) return `${Math.floor(seconds / 3600)} h ago`;
  return `${Math.floor(seconds / 86_400)} d ago`;
}

/** A moment ahead: "in 6 d"; one already passed: "expired". */
export function untilTime(iso: string, nowMs: number): string {
  const at = Date.parse(iso);
  if (Number.isNaN(at)) return "never";
  const seconds = Math.round((at - nowMs) / 1000);
  if (seconds <= 0) return "expired";
  if (seconds < 3600) return `in ${Math.max(1, Math.floor(seconds / 60))} min`;
  if (seconds < 86_400) return `in ${Math.floor(seconds / 3600)} h`;
  return `in ${Math.floor(seconds / 86_400)} d`;
}

export function machineIsOnline(machine: TeamMachine, nowMs: number): boolean {
  if (machine.lastPublished === null) return false;
  const at = Date.parse(machine.lastPublished);
  return !Number.isNaN(at) && nowMs - at < MACHINE_ONLINE_MS;
}

const LiveThread = Schema.Struct({
  id: Schema.String,
  title: Schema.String,
  project: Schema.String,
  startedAt: Schema.optional(Schema.NullOr(Schema.Number)),
  activityLine: Schema.optional(Schema.NullOr(Schema.String)),
});
export type TeamLiveThread = typeof LiveThread.Type;
const NowDocument = Schema.Struct({
  live: Schema.optional(Schema.Array(LiveThread)),
  blockers: Schema.optional(Schema.Array(Schema.String)),
});
const decodeNow = Schema.decodeUnknownOption(NowDocument);

/** The live threads and blockers a machine's `now` names; empty when the
    document is missing or not one this build reads. */
export function machineNow(machine: TeamMachine): {
  readonly live: ReadonlyArray<TeamLiveThread>;
  readonly blockers: ReadonlyArray<string>;
} {
  const now = Option.getOrUndefined(decodeNow(machine.now));
  return { live: now?.live ?? [], blockers: now?.blockers ?? [] };
}

/** "leader · 2 machines · 3 live · published 4 min ago". */
export function memberSummary(member: TeamMemberRow, nowMs: number): string {
  const machines = member.machines.length;
  const live = member.machines.reduce((sum, machine) => sum + machineNow(machine).live.length, 0);
  const latest = member.machines
    .map((machine) => machine.lastPublished)
    .filter((at): at is string => at !== null)
    .sort()
    .at(-1);
  const parts = [
    member.role === "leader" ? (member.founder ? "founder" : "leader") : "member",
    `${machines} ${machines === 1 ? "machine" : "machines"}`,
  ];
  if (live > 0) parts.push(`${live} live`);
  parts.push(`published ${relativeTime(latest ?? null, nowMs)}`);
  return parts.join(" · ");
}

export function audienceLabel(
  audience: TeamGrant["audience"],
  members: ReadonlyArray<TeamMemberRow>,
): string {
  if (audience === "team") return "Whole team";
  if (audience === "leaders") return "Leaders";
  return audience
    .map((userId) => members.find((member) => member.userId === userId)?.name ?? userId)
    .join(", ");
}

export function grantSummary(grant: TeamGrant, nowMs: number): string {
  const threads = grant.threads === "all" ? "every thread" : `${grant.threads.length} threads`;
  const caps = grant.capabilities.join(", ");
  const pre =
    grant.preauthorized.length === 0 ? "" : ` · ${grant.preauthorized.join(", ")} without asking`;
  const expires = grant.expiresAt === null ? "" : ` · expires ${untilTime(grant.expiresAt, nowMs)}`;
  return `${caps} on ${threads}${pre}${expires}`;
}

export function pendingSummary(pending: TeamPendingCommand, nowMs: number): string {
  const target = pending.action === "new" ? (pending.project ?? "a project") : pending.threadId;
  const text =
    pending.text === undefined || pending.text.length === 0
      ? ""
      : ` — “${pending.text.slice(0, 80)}”`;
  const left = Math.max(0, Math.round((Date.parse(pending.expiresAt) - nowMs) / 1000));
  return `${pending.action} on ${target}${text} · ${left}s left`;
}

const ThreadRow = Schema.Struct({
  id: Schema.String,
  title: Schema.String,
  project: Schema.String,
  status: Schema.String,
  updatedAt: Schema.Number,
});
export type TeamThreadRow = typeof ThreadRow.Type;
const ThreadsDocument = Schema.Struct({ threads: Schema.Array(ThreadRow) });
const decodeThreads = Schema.decodeUnknownOption(ThreadsDocument);

/** A `threads` document's rows; empty when the shape is not this build's. */
export function threadsIndex(body: unknown): ReadonlyArray<TeamThreadRow> {
  return Option.getOrUndefined(decodeThreads(body))?.threads ?? [];
}

const TranscriptRow = Schema.Struct({
  role: Schema.String,
  text: Schema.String,
  at: Schema.optional(Schema.Number),
});
export type TeamTranscriptRow = typeof TranscriptRow.Type;
const decodeTranscriptRow = Schema.decodeUnknownOption(Schema.fromJsonString(TranscriptRow));

/** A chunk's JSON lines as rows; a line this build cannot read is skipped. */
export function transcriptRows(lines: string): ReadonlyArray<TeamTranscriptRow> {
  const rows: Array<TeamTranscriptRow> = [];
  for (const line of lines.split("\n")) {
    if (line.length === 0) continue;
    const row = decodeTranscriptRow(line);
    if (Option.isSome(row)) rows.push(row.value);
  }
  return rows;
}
