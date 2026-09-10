import {
  type SessionActions,
  sessionActions,
  type SessionRowModel,
  sessionRows,
} from "@t3tools/client-runtime/state/infinitusSessions";
import type { InfinitusSnapshot } from "@t3tools/contracts/infinitus";

/**
 * What the sidebar's Sessions group shows, derived from one snapshot so the
 * component only draws it: the rows, how many need a person (waiting on an
 * answer or on a sign-in), and which per-row verbs this build's manifest offers.
 */
export interface SidebarSessionsView {
  readonly rows: ReadonlyArray<SessionRowModel>;
  readonly attentionCount: number;
  readonly actions: SessionActions;
}

/**
 * The group's content, or null when there is no group to draw: no Infinitus on
 * this environment, a snapshot still loading or offline, or no live session.
 * `now` is the clock the row ages are read against.
 */
export function sidebarSessionsView(input: {
  capability: boolean | undefined;
  snapshot: InfinitusSnapshot | null;
  now: number;
}): SidebarSessionsView | null {
  if (input.capability !== true || input.snapshot === null || !input.snapshot.available) {
    return null;
  }
  const rows = sessionRows(input.snapshot, input.now);
  if (rows.length === 0) return null;
  return {
    rows,
    attentionCount: rows.filter((row) => row.needsAttention).length,
    actions: sessionActions(input.snapshot.commands),
  };
}

/** The row's truncating middle column: its folder when the title is a name,
    else its state; the account trails when the build sends it. The age is not
    here — it gets its own fixed column so truncation never eats it. */
export function sessionRowDetail(row: SessionRowModel): string {
  const parts = [row.title === row.folder ? row.stateLabel : row.folder];
  if (row.account !== null) parts.push(row.account);
  return parts.join(" · ");
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
