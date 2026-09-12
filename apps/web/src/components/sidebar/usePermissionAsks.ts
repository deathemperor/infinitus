import type { EnvironmentId } from "@t3tools/contracts";
import { useCallback, useEffect, useState } from "react";

import { infinitusEnvironment } from "../../state/infinitus";
import { useAtomCommand } from "../../state/use-atom-command";
import {
  PERMISSION_PENDING_COMMAND,
  PERMISSION_POLL_MS,
  parsePermissionAsks,
  type PermissionAsk,
} from "./permissionAsks.logic";

/**
 * The Mac's open permission asks (#79 item 3), read on the card's own timer
 * while `enabled` (a remote row exists and the build has the verb) and
 * dropped the moment it is not. `refresh` re-reads right after a decision so
 * the card clears without waiting a tick.
 */
const EMPTY: ReadonlyArray<PermissionAsk> = [];

export function usePermissionAsks(
  environmentId: EnvironmentId | null,
  enabled: boolean,
): { readonly asks: ReadonlyArray<PermissionAsk>; readonly refresh: () => Promise<void> } {
  const runCommand = useAtomCommand(infinitusEnvironment.command, { reportFailure: false });
  const [asks, setAsks] = useState<ReadonlyArray<PermissionAsk>>([]);

  const refresh = useCallback(async () => {
    if (environmentId === null || !enabled) return;
    const result = await runCommand({
      environmentId,
      input: { command: PERMISSION_PENDING_COMMAND, args: [], options: {} },
    });
    // A refused read (the app gone, busy) keeps the last list: the next tick
    // or the snapshot's own unavailable state clears it.
    if (result._tag === "Success") setAsks(parsePermissionAsks(result.value.result));
  }, [environmentId, enabled, runCommand]);

  useEffect(() => {
    if (environmentId === null || !enabled) return;
    const tick = () => void refresh();
    // The first read on the next tick, the rest on the timer.
    const first = setTimeout(tick, 0);
    const timer = setInterval(tick, PERMISSION_POLL_MS);
    return () => {
      clearTimeout(first);
      clearInterval(timer);
    };
  }, [environmentId, enabled, refresh]);

  // Off, the last list is not shown; back on, the first read replaces it.
  return { asks: enabled ? asks : EMPTY, refresh };
}
