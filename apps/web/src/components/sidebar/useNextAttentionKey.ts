import type { ResolvedKeybindingsConfig, ScopedThreadRef } from "@infinitus/contracts";
import { scopeThreadRef, scopedThreadKey } from "@infinitus/client-runtime/environment";
import { limitStopKey } from "@infinitus/client-runtime/state/infinitusLimitStops";
import { useAtomValue } from "@effect/atom-react";
import { useCallback, useEffect } from "react";

import { isCommandPaletteOpen } from "../../commandPaletteBus";
import { isElectron } from "../../env";
import { resolveShortcutCommand } from "../../keybindings";
import { isTerminalFocused } from "../../lib/terminalFocus";
import { isModelPickerOpen } from "../../modelPickerVisibility";
import { infinitusLimitStopsAtom } from "../../state/infinitus";
import type { SidebarThreadSummary } from "../../types";
import { useUiStateStore } from "../../uiStateStore";
import {
  hasUnseenCompletion,
  resolveSidebarThreadStatus,
  resolveThreadLastVisitedAt,
} from "../Sidebar.logic";
import { onNextAttentionThreadRequest } from "./nextAttentionBus";
import { resolveAttentionRank, resolveNextAttentionThreadId } from "./sidebarNeedsAttention.logic";

/**
 * Fork (#270 C): the `thread.nextAttention` key and the palette's "Jump to
 * next waiting thread" action. Both rank the rendered list at press time
 * (approval, input, limit, failure, then an unseen completion, ties in
 * sidebar order after the current thread) and navigate to the winner; a
 * press with nothing waiting is a no-op. The sidebar mounts this once beside
 * its own key handling and hands over what only it holds.
 */
export function useNextAttentionKey(input: {
  readonly orderedThreads: ReadonlyArray<SidebarThreadSummary>;
  readonly routeThreadKey: string | null;
  readonly routeTerminalOpen: boolean;
  readonly keybindings: ResolvedKeybindingsConfig;
  readonly navigateToThread: (threadRef: ScopedThreadRef) => void;
}): void {
  const { keybindings, navigateToThread, orderedThreads, routeTerminalOpen, routeThreadKey } =
    input;
  const limitStops = useAtomValue(infinitusLimitStopsAtom);
  const jumpToNextAttentionThread = useCallback((): boolean => {
    const lastVisitedAtById = useUiStateStore.getState().threadLastVisitedAtById;
    const entries = orderedThreads.map((thread) => {
      const key = scopedThreadKey(scopeThreadRef(thread.environmentId, thread.id));
      const status = resolveSidebarThreadStatus(thread, {
        limitStopped: limitStops.has(limitStopKey(thread.environmentId, thread.id)),
      });
      // Same merge as the row: the server's visit wins where it tracks one.
      const isUnread = hasUnseenCompletion({
        ...thread,
        lastVisitedAt: resolveThreadLastVisitedAt(thread.lastVisitedAt, lastVisitedAtById[key]),
      });
      return { id: key, rank: resolveAttentionRank({ status, isUnread }) };
    });
    const targetKey = resolveNextAttentionThreadId({ entries, currentThreadId: routeThreadKey });
    const target =
      targetKey === null
        ? undefined
        : orderedThreads.find(
            (thread) =>
              scopedThreadKey(scopeThreadRef(thread.environmentId, thread.id)) === targetKey,
          );
    if (target === undefined) return false;
    navigateToThread(scopeThreadRef(target.environmentId, target.id));
    return true;
  }, [limitStops, navigateToThread, orderedThreads, routeThreadKey]);

  useEffect(() => {
    const onWindowKeyDown = (event: KeyboardEvent) => {
      if (event.defaultPrevented || event.repeat || isCommandPaletteOpen() || isModelPickerOpen()) {
        return;
      }
      const command = resolveShortcutCommand(event, keybindings, {
        platform: navigator.platform,
        context: {
          terminalFocus: isTerminalFocused(),
          terminalOpen: routeTerminalOpen,
          modelPickerOpen: isModelPickerOpen(),
          isWeb: !isElectron,
          isDesktop: isElectron,
        },
      });
      if (command !== "thread.nextAttention") return;
      event.preventDefault();
      event.stopPropagation();
      jumpToNextAttentionThread();
    };
    window.addEventListener("keydown", onWindowKeyDown);
    return () => window.removeEventListener("keydown", onWindowKeyDown);
  }, [jumpToNextAttentionThread, keybindings, routeTerminalOpen]);

  useEffect(
    () => onNextAttentionThreadRequest(jumpToNextAttentionThread),
    [jumpToNextAttentionThread],
  );
}
