import type { InfinitusManifestCommand } from "@t3tools/contracts/infinitus";

/**
 * Permission prompts answered from the sidebar (#79 item 3): the Mac's
 * `permission-pending` rows for the sessions with `session-remote on`, each
 * drawn under its Sessions row with Allow / Deny (`permission-decide`). The
 * Mac's window is 60 s and the snapshot's idle cadence is 30 s, so the card
 * reads `permission-pending` on its own timer (`PERMISSION_POLL_MS`) while any
 * row is remote and not at all otherwise.
 */
export interface PermissionAsk {
  readonly id: string;
  readonly pid: number | null;
  readonly sessionId: string;
  readonly tool: string;
  /** The Mac's bounded rendering of `tool_input`: a command, a path, or the
      input's keys. Shown, never logged. */
  readonly input: string;
  readonly expiresAt: number | null;
}

export type PermissionDecision = "allow" | "deny";

export const PERMISSION_POLL_MS = 5_000;

export const PERMISSION_PENDING_COMMAND = "permission-pending";

/** The two verbs the card needs, each only when the manifest lists it. */
export function permissionAskActions(commands: ReadonlyArray<InfinitusManifestCommand>): {
  readonly pending: boolean;
  readonly decide: boolean;
} {
  return {
    pending: commands.some((command) => command.name === PERMISSION_PENDING_COMMAND),
    decide: commands.some((command) => command.name === "permission-decide"),
  };
}

/** The `permission-pending` reply read defensively: a row missing its id,
    session or tool is dropped alone; junk is no rows. */
export function parsePermissionAsks(result: unknown): PermissionAsk[] {
  if (!Array.isArray(result)) return [];
  const asks: PermissionAsk[] = [];
  for (const row of result) {
    if (typeof row !== "object" || row === null) continue;
    const r = row as Record<string, unknown>;
    if (typeof r.id !== "string" || typeof r.sessionId !== "string" || typeof r.tool !== "string") {
      continue;
    }
    const expiresAt = typeof r.expiresAt === "string" ? Date.parse(r.expiresAt) : Number.NaN;
    asks.push({
      id: r.id,
      pid: typeof r.pid === "number" ? r.pid : null,
      sessionId: r.sessionId,
      tool: r.tool,
      input: typeof r.input === "string" ? r.input : "",
      expiresAt: Number.isNaN(expiresAt) ? null : expiresAt,
    });
  }
  return asks;
}

/** The asks for one row: by pid, else by session id for a row the Mac could
    not map to a pid when the ask arrived. */
export function asksForSession(
  asks: ReadonlyArray<PermissionAsk>,
  row: { readonly pid: number; readonly sessionId: string | null },
): PermissionAsk[] {
  return asks.filter(
    (ask) => ask.pid === row.pid || (ask.pid === null && ask.sessionId === row.sessionId),
  );
}

/** `permission-decide <id> allow|deny`. */
export function permissionDecideCommandArgs(
  ask: PermissionAsk,
  decision: PermissionDecision,
): { readonly command: string; readonly args: ReadonlyArray<string> } {
  return { command: "permission-decide", args: [ask.id, decision] };
}

/** The card's one line: the tool, then its rendered input when there is one. */
export function permissionAskLabel(ask: PermissionAsk): string {
  return ask.input === "" ? ask.tool : `${ask.tool} · ${ask.input}`;
}
