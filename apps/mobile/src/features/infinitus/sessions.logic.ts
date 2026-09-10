import type { MenuAction } from "@react-native-menu/menu";
import {
  canSetSessionMode,
  SESSION_PERMISSION_MODES,
  type SessionPermissionMode,
  type SessionRowModel,
  sessionModeCommandArgs,
  sessionRows,
} from "@t3tools/client-runtime/state/infinitusSessions";
import type { InfinitusCommandInput, InfinitusSnapshot } from "@t3tools/contracts/infinitus";

/** What one Mac's Sessions card draws: the shared rows (waiting first), how
    many wait on a person, and whether a row's mode is settable (the manifest
    lists `session-mode`). Null while loading, offline, or with no session. */
export interface MacSessionsView {
  readonly rows: ReadonlyArray<SessionRowModel>;
  readonly waitingCount: number;
  readonly canSetMode: boolean;
}

export function macSessionsView(snapshot: InfinitusSnapshot | null): MacSessionsView | null {
  if (snapshot === null || !snapshot.available) return null;
  const rows = sessionRows(snapshot);
  if (rows.length === 0) return null;
  return {
    rows,
    waitingCount: rows.filter((row) => row.state === "waiting").length,
    canSetMode: canSetSessionMode(snapshot.commands),
  };
}

/** The sessions waiting on a person, for the home chip's badge. */
export function waitingSessionCount(snapshot: InfinitusSnapshot | null): number {
  return macSessionsView(snapshot)?.waitingCount ?? 0;
}

const MODE_SYMBOL: Record<SessionPermissionMode, string> = {
  supervised: "hand.raised",
  acceptEdits: "pencil",
  bypassPermissions: "bolt",
};

/** The row's context menu: one radio entry per permission mode, the current
    one checked. Ids are the modes. */
export function sessionModeMenuActions(row: SessionRowModel): ReadonlyArray<MenuAction> {
  return SESSION_PERMISSION_MODES.map((option) => ({
    id: option.mode,
    title: option.label,
    image: MODE_SYMBOL[option.mode],
    state: option.mode === row.permissionMode ? "on" : "off",
  }));
}

export function isSessionPermissionMode(id: string): id is SessionPermissionMode {
  return SESSION_PERMISSION_MODES.some((option) => option.mode === id);
}

/** `session-mode <pid> <mode>` for a row, or null when it is already there. */
export function sessionModeCommand(
  row: SessionRowModel,
  mode: SessionPermissionMode,
): InfinitusCommandInput | null {
  if (mode === row.permissionMode) return null;
  const { command, args } = sessionModeCommandArgs(row, mode);
  return { command, args: [...args], options: {} };
}
