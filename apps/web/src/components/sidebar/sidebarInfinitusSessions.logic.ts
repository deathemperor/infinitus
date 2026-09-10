import {
  canSetSessionMode,
  sessionRows,
  type SessionRowModel,
} from "@t3tools/client-runtime/state/infinitusSessions";
import type { InfinitusSnapshot } from "@t3tools/contracts/infinitus";

/**
 * What the sidebar's Sessions group shows, derived from one snapshot so the
 * component only draws it: the rows, how many want a person, and whether a row
 * can change its permission mode (the manifest lists `session-mode`).
 */
export interface SidebarSessionsView {
  readonly rows: ReadonlyArray<SessionRowModel>;
  readonly waitingCount: number;
  readonly canSetMode: boolean;
}

/**
 * The group's content, or null when there is no group to draw: no Infinitus on
 * this environment, a snapshot still loading or offline, or no live session.
 */
export function sidebarSessionsView(input: {
  capability: boolean | undefined;
  snapshot: InfinitusSnapshot | null;
}): SidebarSessionsView | null {
  if (input.capability !== true || input.snapshot === null || !input.snapshot.available) {
    return null;
  }
  const rows = sessionRows(input.snapshot);
  if (rows.length === 0) return null;
  return {
    rows,
    waitingCount: rows.filter((row) => row.state === "waiting").length,
    canSetMode: canSetSessionMode(input.snapshot.commands),
  };
}

/** What the socket said went wrong, in the words the error carries. */
export function sessionCommandErrorMessage(error: unknown): string {
  if (typeof error === "object" && error !== null) {
    const tagged = error as { readonly _tag?: unknown; readonly error?: unknown };
    if (tagged._tag === "InfinitusCommandFailed" && typeof tagged.error === "string") {
      return tagged.error;
    }
    if (tagged._tag === "InfinitusUnavailable") {
      const unavailable = error as { readonly cause?: unknown };
      if (typeof unavailable.cause === "string") return unavailable.cause;
    }
    if (error instanceof Error && error.message.trim() !== "") return error.message;
  }
  return "The command failed.";
}
