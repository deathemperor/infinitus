import { useAtomValue } from "@effect/atom-react";
import type { EnvironmentThreadShell } from "@t3tools/client-runtime/state/models";
import {
  isAtomCommandInterrupted,
  squashAtomCommandFailure,
} from "@t3tools/client-runtime/state/runtime";
import type { MessageId, OrchestrationThread } from "@t3tools/contracts";
import { CommonActions, useNavigation } from "@react-navigation/native";
import type { MenuAction } from "@react-native-menu/menu";
import { useCallback, useMemo, useRef } from "react";
import { Alert } from "react-native";

import { infinitusEnvironment } from "../../state/infinitus";
import { environmentServerConfigsAtom } from "../../state/server";
import { threadEnvironment } from "../../state/threads";
import { useAtomCommand } from "../../state/use-atom-command";
import { resolveThreadProviderInstance } from "../threads/thread-provider-instance";
import {
  REVERT_WHILE_RUNNING,
  restoreFilesConfirmText,
  revertTurnCountByUserMessageId,
} from "./revertMessage.logic";

/** What the feed draws on a user message's long-press: the menu's rows and their handler. */
export interface InfinitusMessageMenu {
  readonly actions: ReadonlyArray<MenuAction>;
  readonly onPressAction: (event: { readonly nativeEvent: { readonly event: string } }) => void;
}

const RESTORE_FILES: MenuAction = {
  id: "restore-files",
  title: "Restore files only",
  image: "arrow.uturn.backward",
};
const FORK: MenuAction = {
  id: "fork",
  title: "Fork a new thread from here",
  image: "arrow.branch",
};

/**
 * Fork (#269 item 13, #270 item 5): revert to a message the user sent — the
 * phone's half of the web's revert menu on a user message. Two of its modes:
 * "Restore files only" (`thread.checkpoint.revert` with `keepChat`, #269 E;
 * a confirm first, since it rewrites the worktree) and "Fork a new thread
 * from here" (`infinitus.forkThread` at the same `turnCount` the web sends,
 * #270 E2; opens the new thread). The composer hand-back modes ("Edit from
 * here", "Rewind chat only") stay on the desktop. Offered on an `infinitus`
 * server for every user message whose turn has a checkpoint; the fork on a
 * Claude Agent or Codex thread, the drivers with a fork point.
 */
export function useRevertMessageMenu(
  thread: EnvironmentThreadShell | null,
  detail: Pick<OrchestrationThread, "messages" | "checkpoints"> | null,
): (messageId: MessageId) => InfinitusMessageMenu | null {
  const navigation = useNavigation();
  const configs = useAtomValue(environmentServerConfigsAtom);
  const supported =
    thread !== null &&
    configs.get(thread.environmentId)?.environment.capabilities.infinitus === true;
  const driver =
    thread === null ? null : resolveThreadProviderInstance(configs, thread)?.driverKind;
  const canFork = driver === "claudeAgent" || driver === "codex";
  const running = thread?.session?.status === "running" || thread?.session?.status === "starting";
  const environmentId = thread?.environmentId ?? null;
  const threadId = thread?.id ?? null;
  const revert = useAtomCommand(threadEnvironment.revertCheckpoint, { reportFailure: false });
  const fork = useAtomCommand(infinitusEnvironment.forkThread, { reportFailure: false });
  const inFlight = useRef(false);

  // A turn mid-flight hands the route a new detail every tick; like
  // `useTurnFooters`, the map travels through one string key so the callback
  // below — and with it every feed row — moves only when a mapping changes.
  const messages = detail?.messages;
  const checkpoints = detail?.checkpoints;
  const turnCountsKey = useMemo(
    () =>
      supported && messages !== undefined && checkpoints !== undefined
        ? JSON.stringify([...revertTurnCountByUserMessageId({ messages, checkpoints })])
        : null,
    [checkpoints, messages, supported],
  );
  const turnCounts = useMemo(
    () =>
      turnCountsKey === null
        ? null
        : new Map(JSON.parse(turnCountsKey) as Array<[MessageId, number]>),
    [turnCountsKey],
  );

  const restoreFiles = useCallback(
    async (turnCount: number) => {
      if (environmentId === null || threadId === null || inFlight.current) return;
      inFlight.current = true;
      const result = await revert({
        environmentId,
        input: { threadId, turnCount, keepChat: true },
      });
      inFlight.current = false;
      if (result._tag === "Failure" && !isAtomCommandInterrupted(result)) {
        const error = squashAtomCommandFailure(result);
        Alert.alert(
          "Could not restore the files",
          error instanceof Error ? error.message : "Failed to revert thread state.",
        );
      }
    },
    [environmentId, revert, threadId],
  );

  const forkAt = useCallback(
    async (turnCount: number) => {
      if (environmentId === null || threadId === null || inFlight.current) return;
      inFlight.current = true;
      const result = await fork({ environmentId, input: { threadId, turnCount } });
      inFlight.current = false;
      if (result._tag === "Failure") {
        if (isAtomCommandInterrupted(result)) return;
        const error = squashAtomCommandFailure(result);
        Alert.alert(
          "Could not fork the thread",
          error instanceof Error ? error.message : String(error),
        );
        return;
      }
      navigation.dispatch(
        CommonActions.navigate("Thread", { environmentId, threadId: result.value.threadId }),
      );
    },
    [environmentId, fork, navigation, threadId],
  );

  return useCallback(
    (messageId: MessageId) => {
      const turnCount = turnCounts?.get(messageId);
      if (turnCount === undefined) return null;
      return {
        actions: canFork ? [RESTORE_FILES, FORK] : [RESTORE_FILES],
        onPressAction: ({ nativeEvent }) => {
          if (nativeEvent.event !== "restore-files" && nativeEvent.event !== "fork") return;
          if (running) {
            Alert.alert("Turn in progress", REVERT_WHILE_RUNNING);
            return;
          }
          if (nativeEvent.event === "fork") {
            void forkAt(turnCount);
            return;
          }
          Alert.alert("Restore files", restoreFilesConfirmText(turnCount), [
            { text: "Cancel", style: "cancel" },
            { text: "Restore", style: "destructive", onPress: () => void restoreFiles(turnCount) },
          ]);
        },
      };
    },
    [canFork, forkAt, restoreFiles, running, turnCounts],
  );
}
