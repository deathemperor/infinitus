import { memo } from "react";
import { Alert, AlertDescription } from "../ui/alert";
import { WifiOffIcon } from "lucide-react";

import type { ThreadSession } from "../../types";

/**
 * Fork (#832): the line shown while the Claude adapter waits to reopen a
 * turn whose transport went away. The server keeps the turn `running` and
 * puts `reconnecting:<attempt>/<max>` in the session's status reason; any
 * other reason (an API retry heartbeat, a CLI status) shows nothing.
 */
export function reconnectingNotice(
  session: Pick<ThreadSession, "status" | "statusReason"> | null | undefined,
): string | null {
  if (!session || session.status !== "running") return null;
  const match = /^reconnecting:(\d+)\/(\d+)$/.exec(session.statusReason ?? "");
  if (!match) return null;
  return `Waiting for the network. Reconnect attempt ${match[1]} of ${match[2]}.`;
}

export const ThreadReconnectingNotice = memo(function ThreadReconnectingNotice({
  notice,
}: {
  notice: string | null;
}) {
  if (!notice) return null;
  return (
    <div className="pointer-events-auto mx-auto w-fit max-w-[min(48rem,calc(100%-2rem))] pt-3">
      <Alert variant="warning" className="alert-glass" data-variant="warning" role="status">
        <WifiOffIcon />
        <AlertDescription>{notice}</AlertDescription>
      </Alert>
    </div>
  );
});
