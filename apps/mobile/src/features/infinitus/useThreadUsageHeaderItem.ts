import type { EnvironmentThreadShell } from "@t3tools/client-runtime/state/models";
import { useNavigation } from "@react-navigation/native";
import { useMemo } from "react";

import type { ThreadMenuAction } from "./threadHeaderMenu.logic";

export interface ThreadUsageHeaderItem {
  /** The thread header menu's choice, or null while the thread has no recorded turn. */
  readonly action: ThreadMenuAction | null;
  /** Feeds `optionsVersion`: the stabilised header factories re-read the
      item only when this changes. */
  readonly version: string;
}

const NO_ITEM: ThreadUsageHeaderItem = { action: null, version: "" };
const LABEL = "Thread usage";

/**
 * Fork (#834): the thread header menu's "Thread usage", opening
 * `ThreadUsageSheet` over the thread. Offered once the shell carries a usage
 * rollup — the server's word that a turn was recorded; a thread with none,
 * or a server without the rollup, has nothing to show and gets no choice.
 */
export function useThreadUsageHeaderItem(
  thread: EnvironmentThreadShell | null,
): ThreadUsageHeaderItem {
  const navigation = useNavigation();
  const environmentId = thread?.environmentId ?? null;
  const threadId = thread?.id ?? null;
  const recorded = thread?.usage !== undefined;

  return useMemo<ThreadUsageHeaderItem>(() => {
    if (environmentId === null || threadId === null || !recorded) return NO_ITEM;
    const open = () =>
      navigation.navigate("ThreadUsageSheet", {
        environmentId: String(environmentId),
        threadId: String(threadId),
      });
    return {
      action: { id: "usage", label: LABEL, icon: "chart.bar.xaxis", onPress: open },
      // The ids the choice closes over are the route's, so only the gate
      // needs to bump the version.
      version: "usage:recorded",
    };
  }, [environmentId, navigation, recorded, threadId]);
}
