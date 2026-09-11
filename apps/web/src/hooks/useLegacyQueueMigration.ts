import {
  isAtomCommandInterrupted,
  squashAtomCommandFailure,
} from "@t3tools/client-runtime/state/runtime";
import { useEffect, useRef } from "react";

import {
  legacyQueuedEntryCommand,
  parseComposerSendQueueKey,
} from "../components/chat/composerSendQueue.logic";
import { usePromptStashStore } from "../promptStashStore";
import { usePrimaryEnvironmentId } from "../state/environments";
import { readPreparedConnection, usePreparedConnection } from "../state/session";
import { threadEnvironment } from "../state/threads";
import { useAtomCommand } from "../state/use-atom-command";

/** The environment is not reachable right now; nothing definitive was said about the row. */
function isEnvironmentUnavailable(error: unknown): boolean {
  return (
    typeof error === "object" &&
    error !== null &&
    (error as { _tag?: unknown })._tag === "EnvironmentRpcUnavailableError"
  );
}

/**
 * Fork (#806): moves messages queued in the prompt stash before the queue
 * lived on the server (#270 F) into `thread.turn.queue`, once. Runs when the
 * stash or the primary environment's connection changes; each entry is tried
 * once per session against its own environment (the stash key names it) and
 * only once that environment is connected. A migrated row drains as soon as
 * its thread is idle, whether or not the thread is open.
 *
 * Success takes the entry out of the stash. A definitive refusal (the thread
 * is gone or archived, the payload no longer decodes) turns the entry into a
 * plain stash entry so the prompt stays reachable; an unreachable
 * environment leaves it for the next pass.
 */
export function useLegacyQueueMigration(): void {
  const entries = usePromptStashStore((state) => state.entries);
  const primaryEnvironmentId = usePrimaryEnvironmentId();
  // A pass waits for the primary environment to connect; each entry's own
  // environment is checked again below (the stash key names it).
  const primaryConnected = usePreparedConnection(primaryEnvironmentId)._tag === "Some";
  const queueTurn = useAtomCommand(threadEnvironment.queueTurn, { reportFailure: false });
  const attemptedRef = useRef(new Set<string>());

  useEffect(() => {
    const pending = entries.filter(
      (entry) =>
        entry.queuedFor !== undefined &&
        !entry.pendingImageCount &&
        !attemptedRef.current.has(entry.id),
    );
    if (pending.length === 0 || !primaryConnected) return;
    void (async () => {
      for (const entry of pending) {
        const key =
          entry.queuedFor === undefined ? null : parseComposerSendQueueKey(entry.queuedFor);
        const command = legacyQueuedEntryCommand(entry);
        if (key === null || command === null) {
          usePromptStashStore.getState().unqueueEntry(entry.id);
          continue;
        }
        if (readPreparedConnection(key.environmentId) === null) continue;
        attemptedRef.current.add(entry.id);
        const result = await queueTurn({
          environmentId: key.environmentId,
          input: { threadId: key.threadId, ...command },
        });
        const store = usePromptStashStore.getState();
        if (result._tag === "Success") {
          store.takeEntry(entry.id);
          continue;
        }
        if (isAtomCommandInterrupted(result)) {
          attemptedRef.current.delete(entry.id);
          continue;
        }
        const error = squashAtomCommandFailure(result);
        if (isEnvironmentUnavailable(error)) {
          attemptedRef.current.delete(entry.id);
          continue;
        }
        console.warn(
          "[PROMPT-STASH] A queued message could not move to the server; it is a stash entry now.",
          error,
        );
        store.unqueueEntry(entry.id);
      }
    })();
  }, [entries, primaryConnected, queueTurn]);
}
