import type { MenuAction } from "@react-native-menu/menu";
import {
  nudgeCommandArgs,
  SESSION_PERMISSION_MODES,
  type SessionActions,
  sessionActions,
  type SessionCommandArgs,
  sessionModeCommandArgs,
  type SessionPermissionMode,
  type SessionRowModel,
  sessionRows,
  showSessionCommandArgs,
} from "@t3tools/client-runtime/state/infinitusSessions";
import type { InfinitusCommandInput, InfinitusSnapshot } from "@t3tools/contracts/infinitus";

/** What one Mac's Sessions card draws: the shared rows (the ones needing a
    person first), how many need one, and which per-row verbs this build's
    manifest offers. Null while loading, offline, or with no session. */
export interface MacSessionsView {
  readonly rows: ReadonlyArray<SessionRowModel>;
  readonly attentionCount: number;
  readonly actions: SessionActions;
}

export function macSessionsView(
  snapshot: InfinitusSnapshot | null,
  now: number,
): MacSessionsView | null {
  if (snapshot === null || !snapshot.available) return null;
  const rows = sessionRows(snapshot, now);
  if (rows.length === 0) return null;
  return {
    rows,
    attentionCount: rows.filter((row) => row.needsAttention).length,
    actions: sessionActions(snapshot.commands),
  };
}

/** The sessions needing a person (waiting, or a sign-in pending), for the home
    chip's badge. */
export function attentionSessionCount(snapshot: InfinitusSnapshot | null): number {
  if (snapshot === null || !snapshot.available) return 0;
  return sessionRows(snapshot, 0).filter((row) => row.needsAttention).length;
}

/** The row's second line: state, then folder when the title is a name, then
    account and age when the build sends them. */
export function sessionRowDetail(row: SessionRowModel): string {
  const parts = [row.stateLabel];
  if (row.title !== row.folder) parts.push(row.folder);
  if (row.account !== null) parts.push(row.account);
  if (row.age !== null) parts.push(row.age);
  return parts.join(" · ");
}

const MODE_SYMBOL: Record<SessionPermissionMode, string> = {
  supervised: "hand.raised",
  acceptEdits: "pencil",
  bypassPermissions: "bolt",
};

/** The row's context menu: "Open on the Mac" and "Nudge" when the manifest has
    the verbs, then a submenu of permission modes with the current one checked.
    Ids: `show`, `nudge`, `mode:<mode>`. Empty when the build offers nothing. */
export function sessionMenuActions(
  row: SessionRowModel,
  actions: SessionActions,
): ReadonlyArray<MenuAction> {
  const items: MenuAction[] = [];
  if (actions.show) items.push({ id: "show", title: "Open on the Mac", image: "macwindow" });
  if (actions.nudge) items.push({ id: "nudge", title: "Nudge", image: "play.circle" });
  if (actions.setMode) {
    items.push({
      id: "mode",
      title: "Permission mode",
      subactions: SESSION_PERMISSION_MODES.map((option) => ({
        id: `mode:${option.mode}`,
        title: option.label,
        image: MODE_SYMBOL[option.mode],
        state: option.mode === row.permissionMode ? "on" : "off",
      })),
    });
  }
  return items;
}

export type SessionMenuChoice =
  | { readonly kind: "show" }
  | { readonly kind: "nudge" }
  | { readonly kind: "mode"; readonly mode: SessionPermissionMode };

/** A menu id back to the action it names; null for the submenu's own row and
    anything unknown. */
export function sessionMenuChoice(id: string): SessionMenuChoice | null {
  if (id === "show" || id === "nudge") return { kind: id };
  if (!id.startsWith("mode:")) return null;
  const mode = id.slice("mode:".length);
  const option = SESSION_PERMISSION_MODES.find((candidate) => candidate.mode === mode);
  return option === undefined ? null : { kind: "mode", mode: option.mode };
}

/** The command a choice sends for a row, or null when there is nothing to send
    (the mode already set). */
export function sessionChoiceCommand(
  row: SessionRowModel,
  choice: SessionMenuChoice,
): InfinitusCommandInput | null {
  let args: SessionCommandArgs;
  switch (choice.kind) {
    case "show":
      args = showSessionCommandArgs(row);
      break;
    case "nudge":
      args = nudgeCommandArgs(row);
      break;
    case "mode":
      if (choice.mode === row.permissionMode) return null;
      args = sessionModeCommandArgs(row, choice.mode);
      break;
  }
  return { command: args.command, args: [...args.args], options: {} };
}
