import type {
  InfinitusManifestCommand,
  InfinitusSession,
  InfinitusSnapshot,
} from "@t3tools/contracts/infinitus";

/**
 * The sidebar's Sessions group read model — the live Claude Code sessions the
 * Mac tracks (`sessions` reply: pid, name?, cwd, status?, kind, permissionMode?,
 * profile?), kept pure so web and mobile draw the same rows from one snapshot.
 * The reply carries no account, timestamp or sign-in flag, so a row has none.
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
  /** The session's name when it has one, else its folder. */
  readonly title: string;
  /** The last path component of `cwd`. */
  readonly folder: string;
  readonly cwd: string;
  readonly state: SessionState;
  readonly stateLabel: string;
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

export function sessionRow(session: InfinitusSession): SessionRowModel {
  const state = sessionState(session.status);
  const folder = folderName(session.cwd);
  return {
    pid: session.pid,
    title: session.name ?? folder,
    folder,
    cwd: session.cwd,
    state,
    stateLabel: STATE_LABELS[state],
    kind: session.kind,
    permissionMode: permissionMode(session.permissionMode),
  };
}

/** Every live session as a row, waiting ones first, then by title. */
export function sessionRows(snapshot: InfinitusSnapshot): SessionRowModel[] {
  return snapshot.sessions
    .map(sessionRow)
    .sort(
      (a, b) =>
        STATE_ORDER[a.state] - STATE_ORDER[b.state] ||
        a.title.localeCompare(b.title) ||
        a.pid - b.pid,
    );
}

/** Whether the manifest offers `session-mode`; without it a row has no action. */
export function canSetSessionMode(commands: ReadonlyArray<InfinitusManifestCommand>): boolean {
  return commands.some((command) => command.name === "session-mode");
}

/** The `session-mode <pid> <mode>` call for a row. */
export function sessionModeCommandArgs(
  row: SessionRowModel,
  mode: SessionPermissionMode,
): { readonly command: "session-mode"; readonly args: ReadonlyArray<string> } {
  return { command: "session-mode", args: [String(row.pid), mode] };
}
