/**
 * Fork (#832): the line shown while the Claude adapter waits to reopen a
 * turn whose transport went away. The server keeps the turn `running` and
 * puts `reconnecting:<attempt>/<max>` in the session's status reason; any
 * other reason (an API retry heartbeat, a CLI status) shows nothing. The
 * phone's copy of the web's `ThreadReconnectingNotice.tsx` helper, kept
 * local so neither app edits the other's file.
 */
export interface ReconnectingSession {
  readonly status: string;
  readonly statusReason?: string | null | undefined;
}

/** The attempt and the cap, or null when the session is not reconnecting. */
function reconnectingAttempt(
  session: ReconnectingSession | null | undefined,
): { readonly attempt: number; readonly max: number } | null {
  if (!session || session.status !== "running") return null;
  const match = /^reconnecting:(\d+)\/(\d+)$/.exec(session.statusReason ?? "");
  if (!match) return null;
  return { attempt: Number(match[1]), max: Number(match[2]) };
}

/** The thread screen's notice, the web's wording. */
export function reconnectingNotice(session: ReconnectingSession | null | undefined): string | null {
  const found = reconnectingAttempt(session);
  return found === null
    ? null
    : `Waiting for the network. Reconnect attempt ${found.attempt} of ${found.max}.`;
}

/** The list row's word in place of "Working": short, with the attempt. */
export function reconnectingRowLabel(
  session: ReconnectingSession | null | undefined,
): string | null {
  const found = reconnectingAttempt(session);
  return found === null ? null : `Reconnecting ${found.attempt}/${found.max}`;
}
