import type {
  InfinitusManifestCommand,
  InfinitusSession,
  InfinitusSnapshot,
} from "@t3tools/contracts/infinitus";

/**
 * The Sessions list's read model — the live Claude Code sessions the Mac
 * tracks (`sessions` reply: pid, name?, cwd, status?, kind, permissionMode?,
 * profile?, and since #612 sessionId?, account?, startedAt?, needs?), kept pure
 * so web and mobile draw the same rows from one snapshot.
 */

/** The record's `status` ("busy", "idle", "waiting", "shell" —
    `Sources/InfinitusCore/ClaudeSessions.swift`) as the chip it becomes. */
export type SessionState = "working" | "waiting" | "idle" | "shell" | "unknown";

/** What `session-mode` accepts (its `<supervised|acceptEdits|bypassPermissions>` arg). */
export type SessionPermissionMode = "supervised" | "acceptEdits" | "bypassPermissions";

export const SESSION_PERMISSION_MODES: ReadonlyArray<{
  readonly mode: SessionPermissionMode;
  readonly label: string;
}> = [
  { mode: "supervised", label: "Supervised" },
  { mode: "acceptEdits", label: "Auto-accept edits" },
  { mode: "bypassPermissions", label: "Full access" },
];

export interface SessionRowModel {
  readonly pid: number;
  /** Claude Code's session id; null on a build before #612. */
  readonly sessionId: string | null;
  /** The session's name when it has one, else its folder. */
  readonly title: string;
  /** The last path component of `cwd`. */
  readonly folder: string;
  readonly cwd: string;
  readonly state: SessionState;
  readonly stateLabel: string;
  /** True when a person is needed: waiting on an answer, or a sign-in pending.
      These rows sort first and are what the badges count. */
  readonly needsAttention: boolean;
  /** The alias the session runs on. The app stamps the fleet's active account
      on every row (one active account per engine), so it is the same for all. */
  readonly account: string | null;
  /** When it started, epoch ms; null when the record or the build lacks it. */
  readonly startedAt: number | null;
  /** "3m", "2h", "5d" since `startedAt`, or null without one. */
  readonly age: string | null;
  /** Pending sign-ins as chip labels ("needs AWS sign-in (prod)"). */
  readonly needs: ReadonlyArray<string>;
  readonly kind: string;
  /** The mode the row's radio shows: a null mode reads as supervised, which
      is what `session-mode supervised` sets. */
  readonly permissionMode: SessionPermissionMode;
}

const STATE_LABELS: Record<SessionState, string> = {
  waiting: "waiting on you",
  working: "working",
  idle: "idle",
  shell: "in a shell",
  unknown: "unknown",
};

/** Waiting first — it wants a person — then the rest by how alive they are. */
const STATE_ORDER: Record<SessionState, number> = {
  waiting: 0,
  working: 1,
  idle: 2,
  shell: 3,
  unknown: 4,
};

export function sessionState(status: string | null | undefined): SessionState {
  switch (status) {
    case "busy":
      return "working";
    case "waiting":
      return "waiting";
    case "idle":
      return "idle";
    case "shell":
      return "shell";
    default:
      return "unknown";
  }
}

function folderName(cwd: string): string {
  const parts = cwd.split(/[\\/]+/).filter((part) => part !== "");
  return parts[parts.length - 1] ?? cwd;
}

function permissionMode(mode: string | null | undefined): SessionPermissionMode {
  return mode === "acceptEdits" || mode === "bypassPermissions" ? mode : "supervised";
}

function startedAtMs(iso: string | null | undefined): number | null {
  if (iso === null || iso === undefined) return null;
  const ms = Date.parse(iso);
  return Number.isNaN(ms) ? null : ms;
}

/** A coarse age: under an hour in minutes, under two days in hours, else days. */
export function formatAge(startedAt: number, now: number): string {
  const minutes = Math.max(0, Math.floor((now - startedAt) / 60_000));
  if (minutes < 60) return `${minutes}m`;
  const hours = Math.floor(minutes / 60);
  if (hours < 48) return `${hours}h`;
  return `${Math.floor(hours / 24)}d`;
}

/** `aws-login:<profile>` → "needs AWS sign-in (profile)"; anything the reply
    adds later that this does not know reads as a plain "needs sign-in". */
export function needLabel(need: string): string {
  const colon = need.indexOf(":");
  const verb = colon === -1 ? need : need.slice(0, colon);
  const target = colon === -1 ? "" : need.slice(colon + 1);
  const provider = verb === "aws-login" ? "AWS" : verb === "gcloud-login" ? "gcloud" : null;
  if (provider === null) return "needs sign-in";
  return target === "" ? `needs ${provider} sign-in` : `needs ${provider} sign-in (${target})`;
}

export function sessionRow(session: InfinitusSession, now: number): SessionRowModel {
  const state = sessionState(session.status);
  const folder = folderName(session.cwd);
  const startedAt = startedAtMs(session.startedAt);
  const needs = (session.needs ?? []).map(needLabel);
  return {
    pid: session.pid,
    sessionId: session.sessionId ?? null,
    title: session.name ?? folder,
    folder,
    cwd: session.cwd,
    state,
    stateLabel: STATE_LABELS[state],
    needsAttention: state === "waiting" || needs.length > 0,
    account: session.account ?? null,
    startedAt,
    age: startedAt === null ? null : formatAge(startedAt, now),
    needs,
    kind: session.kind,
    permissionMode: permissionMode(session.permissionMode),
  };
}

/** Every live session as a row: the ones needing a person first, then by
    state, then by title. `now` is the clock the ages are read against. */
export function sessionRows(snapshot: InfinitusSnapshot, now: number): SessionRowModel[] {
  return snapshot.sessions
    .map((session) => sessionRow(session, now))
    .sort(
      (a, b) =>
        Number(b.needsAttention) - Number(a.needsAttention) ||
        STATE_ORDER[a.state] - STATE_ORDER[b.state] ||
        a.title.localeCompare(b.title) ||
        a.pid - b.pid,
    );
}

/** The per-row verbs this manifest offers. `show` is the app's window verb and
    only reaches a session on a build whose arg list names `session` (#612);
    `nudge` and `session-mode` are their own entries. */
export interface SessionActions {
  readonly setMode: boolean;
  readonly show: boolean;
  readonly nudge: boolean;
}

export function sessionActions(commands: ReadonlyArray<InfinitusManifestCommand>): SessionActions {
  const show = commands.find((command) => command.name === "show");
  return {
    setMode: commands.some((command) => command.name === "session-mode"),
    show: show !== undefined && show.args.some((arg) => arg.includes("session")),
    nudge: commands.some((command) => command.name === "nudge"),
  };
}

export interface SessionCommandArgs {
  readonly command: string;
  readonly args: ReadonlyArray<string>;
}

/** `session-mode <pid> <mode>` for a row. Rows are addressed by pid, never by
    name: names are not unique. */
export function sessionModeCommandArgs(
  row: SessionRowModel,
  mode: SessionPermissionMode,
): SessionCommandArgs {
  return { command: "session-mode", args: [String(row.pid), mode] };
}

/** `show session <pid>`: opens the session's chat window on the Mac. */
export function showSessionCommandArgs(row: SessionRowModel): SessionCommandArgs {
  return { command: "show", args: ["session", String(row.pid)] };
}

/** `nudge <pid>`: the resume nudge by hand; the reply says whether it landed. */
export function nudgeCommandArgs(row: SessionRowModel): SessionCommandArgs {
  return { command: "nudge", args: [String(row.pid)] };
}

/** The `nudge` reply (`{pid, nudged, channel?, reason?}`) read defensively from
    the command result's untyped payload: not nudged, with the reply's reason
    when it gives one. */
export function nudgeOutcome(result: unknown): {
  readonly nudged: boolean;
  readonly reason: string | null;
} {
  if (typeof result !== "object" || result === null) return { nudged: false, reason: null };
  const reply = result as { readonly nudged?: unknown; readonly reason?: unknown };
  return {
    nudged: reply.nudged === true,
    reason: typeof reply.reason === "string" && reply.reason !== "" ? reply.reason : null,
  };
}
