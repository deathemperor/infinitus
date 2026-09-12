import type { EnvironmentThreadShell } from "@t3tools/client-runtime/state/models";
import { useNavigation } from "@react-navigation/native";
import { useMemo } from "react";

import type { AndroidHeaderAction } from "../../components/AndroidScreenHeader";
import { withNativeGlassHeaderItem } from "../layout/native-glass-header-items";

export interface ThreadUsageHeaderItem {
  /** The iOS header button, or null while the thread has no recorded turn. */
  readonly item: Record<string, unknown> | null;
  /** The Android in-flow header's button, or null likewise. */
  readonly androidAction: AndroidHeaderAction | null;
  /** Feeds `optionsVersion`: the stabilised header factories re-read the
      item only when this changes. */
  readonly version: string;
}

const NO_ITEM: ThreadUsageHeaderItem = { item: null, androidAction: null, version: "" };
const LABEL = "Thread usage";

/**
 * Fork (#834): the thread header's usage button, opening
 * `ThreadUsageSheet` over the thread. Shown once the shell carries a usage
 * rollup — the server's word that a turn was recorded; a thread with none,
 * or a server without the rollup, has nothing to show and gets no button.
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
      item: withNativeGlassHeaderItem({
        accessibilityLabel: LABEL,
        icon: { name: "chart.bar.xaxis", type: "sfSymbol" as const },
        identifier: "thread-right-usage",
        onPress: open,
        type: "button" as const,
      }),
      androidAction: { accessibilityLabel: LABEL, icon: "chart.bar.xaxis", onPress: open },
      // The ids the button closes over are the route's, so only the gate
      // needs to bump the version.
      version: "usage:recorded",
    };
  }, [environmentId, navigation, recorded, threadId]);
}
