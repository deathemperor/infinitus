import type { EnvironmentId } from "@t3tools/contracts";
import { useEffect, useRef } from "react";

import { stackedThreadToast, toastManager } from "../components/ui/toast";
import { usePrimaryEnvironment } from "../state/environments";
import { infinitusEnvironment } from "../state/infinitus";
import { useEnvironmentQuery } from "../state/query";
import { useAtomCommand } from "../state/use-atom-command";
import { eventRepeatKey, eventToast } from "./infinitusEventToasts.logic";

/** Ids remembered before the oldest are forgotten; the snapshot only ever
    carries a poll's worth, so this is far more than a page will meet. */
const SEEN_LIMIT = 1_000;

interface Watched {
  environmentId: EnvironmentId;
  /** Set once the first snapshot has been read: everything in it is history. */
  primed: boolean;
  seen: Set<string>;
  /** The news last toasted, so the same line re-emitted stays one toast. */
  lastToasted: string | null;
}

/**
 * Turns the Infinitus host's new events into the app's toasts: an account
 * switch, every account exhausted, a session waiting for an answer. Nothing
 * from the first snapshot after mount (no replay on reload), nothing twice
 * (by the server's id), and a line the app re-emits unchanged only once. The
 * primary environment's snapshot is the sidebar pill's, so this adds no poll.
 */
export function useInfinitusEventToasts(): void {
  const environment = usePrimaryEnvironment();
  const environmentId = environment?.environmentId ?? null;
  const supported = environment?.serverConfig?.environment.capabilities.infinitus === true;
  const query = useEnvironmentQuery(
    environmentId === null || !supported
      ? null
      : infinitusEnvironment.snapshot({ environmentId, input: {} }),
  );
  const snapshot = query.data;
  const runCommand = useAtomCommand(infinitusEnvironment.command, { reportFailure: false });
  const watched = useRef<Watched | null>(null);

  useEffect(() => {
    if (environmentId === null || !supported || snapshot === null) return;
    if (watched.current === null || watched.current.environmentId !== environmentId) {
      watched.current = { environmentId, primed: false, seen: new Set(), lastToasted: null };
    }
    const state = watched.current;
    const events = snapshot.events ?? [];
    if (!state.primed) {
      state.primed = true;
      for (const event of events) state.seen.add(event.id);
      return;
    }
    for (const event of events) {
      if (state.seen.has(event.id)) continue;
      state.seen.add(event.id);
      if (state.seen.size > SEEN_LIMIT) {
        const oldest = state.seen.values().next().value;
        if (oldest !== undefined) state.seen.delete(oldest);
      }
      const toast = eventToast(event);
      if (toast === null) continue;
      const key = eventRepeatKey(event);
      if (key === state.lastToasted) continue;
      state.lastToasted = key;
      toastManager.add(
        stackedThreadToast({
          type: toast.type,
          title: toast.title,
          ...(toast.description === undefined ? {} : { description: toast.description }),
          ...(toast.action === "show-popout"
            ? {
                actionProps: {
                  children: "Show",
                  onClick: () => {
                    void runCommand({
                      environmentId,
                      input: { command: "show", args: ["popout"], options: {} },
                    });
                  },
                },
              }
            : {}),
        }),
      );
    }
  }, [snapshot, environmentId, supported, runCommand]);
}
