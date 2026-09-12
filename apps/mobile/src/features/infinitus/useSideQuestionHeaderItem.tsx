import { useAtomValue } from "@effect/atom-react";
import type { EnvironmentThreadShell } from "@t3tools/client-runtime/state/models";
import {
  isAtomCommandInterrupted,
  squashAtomCommandFailure,
} from "@t3tools/client-runtime/state/runtime";
import type { OrchestrationThread } from "@t3tools/contracts";
import { useNavigation } from "@react-navigation/native";
import { useCallback, useMemo, useRef } from "react";
import { Alert } from "react-native";

import type { AndroidHeaderAction } from "../../components/AndroidScreenHeader";
import { withNativeGlassHeaderItem } from "../layout/native-glass-header-items";
import { infinitusEnvironment } from "../../state/infinitus";
import { environmentServerConfigsAtom } from "../../state/server";
import { useAtomCommand } from "../../state/use-atom-command";
import { resolveThreadProviderInstance } from "../threads/thread-provider-instance";
import { hasCompletedTurn, SIDE_QUESTION_NEEDS_TURN } from "./sideQuestions";

export interface SideQuestionHeaderItem {
  /** The iOS header button, or null when this thread cannot take a side question. */
  readonly item: Record<string, unknown> | null;
  /** The Android in-flow header's button, or null likewise. */
  readonly androidAction: AndroidHeaderAction | null;
  /** Feeds `optionsVersion`: the stabilised header factories re-read the
      item only when this changes. */
  readonly version: string;
}

const NO_ITEM: SideQuestionHeaderItem = { item: null, androidAction: null, version: "" };
const LABEL = "Ask a side question";

/**
 * Fork (#269 C, #881): the thread header's side-question button — the web's
 * Aside. It forks the session's latest completed turn into a hidden
 * read-only sibling (`infinitus.forkThread` with `side: true`, no
 * `turnCount`, #887) and opens it as a sheet over this thread. Shown on a
 * Claude Agent thread of a server with the `infinitus` capability; a tap
 * before any turn has completed says so instead of forking.
 */
export function useSideQuestionHeaderItem(
  thread: EnvironmentThreadShell | null,
  detail: OrchestrationThread | null,
): SideQuestionHeaderItem {
  const navigation = useNavigation();
  const configs = useAtomValue(environmentServerConfigsAtom);
  const supported =
    thread !== null &&
    configs.get(thread.environmentId)?.environment.capabilities.infinitus === true &&
    resolveThreadProviderInstance(configs, thread)?.driverKind === "claudeAgent";
  const fork = useAtomCommand(infinitusEnvironment.forkThread, { reportFailure: false });
  const environmentId = thread?.environmentId ?? null;
  const threadId = thread?.id ?? null;
  const canAsk = detail !== null && hasCompletedTurn(detail);
  const forking = useRef(false);

  const ask = useCallback(async () => {
    if (environmentId === null || threadId === null || forking.current) return;
    if (!canAsk) {
      Alert.alert("Not yet", SIDE_QUESTION_NEEDS_TURN);
      return;
    }
    forking.current = true;
    const result = await fork({ environmentId, input: { threadId, side: true } });
    forking.current = false;
    if (result._tag === "Failure") {
      if (isAtomCommandInterrupted(result)) return;
      const error = squashAtomCommandFailure(result);
      Alert.alert(
        "Could not open a side question",
        error instanceof Error ? error.message : String(error),
      );
      return;
    }
    navigation.navigate("SideQuestionSheet", {
      environmentId: String(environmentId),
      threadId: String(threadId),
      sideThreadId: String(result.value.threadId),
    });
  }, [canAsk, environmentId, fork, navigation, threadId]);

  return useMemo<SideQuestionHeaderItem>(() => {
    if (!supported) return NO_ITEM;
    return {
      item: withNativeGlassHeaderItem({
        accessibilityLabel: LABEL,
        icon: { name: "questionmark.bubble", type: "sfSymbol" as const },
        identifier: "thread-right-side-question",
        onPress: () => void ask(),
        type: "button" as const,
      }),
      androidAction: { accessibilityLabel: LABEL, icon: "text.bubble", onPress: () => void ask() },
      // The header keeps the item it was handed until this changes; the ids
      // it closes over are the route's, so only the gate needs to bump it.
      version: canAsk ? "side-question:ready" : "side-question:waiting",
    };
  }, [ask, canAsk, supported]);
}
