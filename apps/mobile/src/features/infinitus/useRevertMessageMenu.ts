import { useAtomValue } from "@effect/atom-react";
import type { EnvironmentThreadShell } from "@infinitus/client-runtime/state/models";
import {
  isAtomCommandInterrupted,
  squashAtomCommandFailure,
} from "@infinitus/client-runtime/state/runtime";
import type { MessageId, OrchestrationThread } from "@infinitus/contracts";
import { CommonActions, useNavigation } from "@react-navigation/native";
import type { MenuAction } from "@react-native-menu/menu";
import * as Option from "effect/Option";
import { useCallback, useEffect, useMemo, useRef } from "react";
import { Alert } from "react-native";

import { scopedThreadKey } from "../../lib/scopedEntities";
import { uuidv4 } from "../../lib/uuid";
import { assetEnvironment } from "../../state/assets";
import { infinitusEnvironment } from "../../state/infinitus";
import { serverEnvironment } from "../../state/server";
import { threadProviderSnapshot } from "./threadProvider.logic";
import { usePreparedConnection } from "../../state/session";
import { threadEnvironment } from "../../state/threads";
import { useAtomCommand } from "../../state/use-atom-command";
import { useAtomQueryRunner } from "../../state/use-atom-query-runner";
import {
  appendComposerDraftAttachments,
  appendComposerDraftText,
  insertComposerDraftContext,
} from "../../state/use-composer-drafts";
import { downloadDraftAttachments } from "./restoreAttachments";
import {
  EDIT_FROM_HERE_CONFIRM,
  REVERT_WHILE_RUNNING,
  REWIND_CHAT_CONFIRM,
  restoreFilesConfirmText,
  restoredRevertedMessage,
  revertMenuActions,
  revertTurnCountByUserMessageId,
  revertedMessageEditableText,
  type RevertMenuAction,
} from "./revertMessage.logic";

/** What the feed draws on a user message's long-press: the menu's rows and their handler. */
export interface InfinitusMessageMenu {
  readonly actions: ReadonlyArray<MenuAction>;
  readonly onPressAction: (event: { readonly nativeEvent: { readonly event: string } }) => void;
}

const MENU_ACTIONS: Record<RevertMenuAction, MenuAction> = {
  files: { id: "files", title: "Edit from here", image: "pencil" },
  "restore-files": {
    id: "restore-files",
    title: "Restore files only",
    image: "arrow.uturn.backward",
  },
  chat: { id: "chat", title: "Rewind chat only", image: "text.bubble" },
  fork: { id: "fork", title: "Fork a new thread from here", image: "arrow.branch" },
};

function isRevertMenuAction(event: string): event is RevertMenuAction {
  return event in MENU_ACTIONS;
}

/**
 * Fork (#269 item 13, #270 item 5): revert to a message the user sent — the
 * phone's half of the web's revert menu on a user message, all four of its
 * modes. "Edit from here" (`thread.checkpoint.revert`, files and chat) and
 * "Rewind chat only" (the same with `restoreFiles: false`, #270 E1) hand the
 * message back to the thread's composer draft: text as typed, attachments
 * downloaded again, context records under fresh ids. "Restore files only"
 * (`keepChat`, #269 E) leaves the chat, and "Fork a new thread from here"
 * (`infinitus.forkThread`, #270 E2) opens the new thread. Each rewrite asks
 * first, in the web's words. Offered on an `infinitus` server for every user
 * message whose turn has a checkpoint; the two rollback modes only where the
 * provider snapshot does not refuse conversation rollback, the fork on a
 * Claude Agent or Codex thread, the drivers with a fork point.
 */
export function useRevertMessageMenu(
  thread: EnvironmentThreadShell | null,
  detail: Pick<OrchestrationThread, "messages" | "checkpoints"> | null,
): (messageId: MessageId) => InfinitusMessageMenu | null {
  const navigation = useNavigation();
  // Its environment's own config atom with selectors (#1278 finding 5), each
  // answering one primitive so the hook wakes only when a gate flips.
  const configAtom = serverEnvironment.configValueAtom(thread?.environmentId ?? null);
  const supported = useAtomValue(
    configAtom,
    (config) => thread !== null && config?.environment.capabilities.infinitus === true,
  );
  const driver = useAtomValue(configAtom, (config) =>
    thread === null ? null : (threadProviderSnapshot(config, thread)?.driver ?? null),
  );
  const canFork = driver === "claudeAgent" || driver === "codex";
  // The web's gate: a snapshot that says nothing supports rollback.
  const canRollback = useAtomValue(
    configAtom,
    (config) =>
      thread === null ||
      threadProviderSnapshot(config, thread)?.supportsConversationRollback !== false,
  );
  const running = thread?.session?.status === "running" || thread?.session?.status === "starting";
  const environmentId = thread?.environmentId ?? null;
  const threadId = thread?.id ?? null;
  const revert = useAtomCommand(threadEnvironment.revertCheckpoint, { reportFailure: false });
  const fork = useAtomCommand(infinitusEnvironment.forkThread, { reportFailure: false });
  const createAssetUrl = useAtomQueryRunner(assetEnvironment.createUrl, {
    reportFailure: false,
    refresh: true,
  });
  const connection = usePreparedConnection(environmentId);
  const httpBaseUrl = Option.isSome(connection) ? connection.value.httpBaseUrl : null;
  const inFlight = useRef(false);

  // A turn mid-flight hands the route a new detail every tick; like
  // `useTurnFooters`, the map travels through one string key so the callback
  // below — and with it every feed row — moves only when a mapping changes.
  // The hand-back reads the message and the connection at the tap, off refs.
  const messages = detail?.messages;
  const checkpoints = detail?.checkpoints;
  const messagesRef = useRef(messages);
  const httpBaseUrlRef = useRef(httpBaseUrl);
  useEffect(() => {
    messagesRef.current = messages;
    httpBaseUrlRef.current = httpBaseUrl;
  }, [httpBaseUrl, messages]);
  const abortRef = useRef(new AbortController());
  useEffect(() => {
    const controller = abortRef.current;
    return () => controller.abort();
  }, []);
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

  // "Edit from here" / "Rewind chat only": the attachments come down first —
  // the server prunes a reverted message's uploads (#847) — then the revert,
  // then text, files and context land in the thread's draft.
  const rewind = useCallback(
    async (mode: "files" | "chat", turnCount: number, messageId: MessageId) => {
      if (environmentId === null || threadId === null || inFlight.current) return;
      const message = messagesRef.current?.find((candidate) => candidate.id === messageId);
      if (message === undefined || message.role !== "user") return;
      inFlight.current = true;
      try {
        const attachments = await downloadDraftAttachments({
          environmentId,
          attachments: message.attachments ?? [],
          httpBaseUrl: httpBaseUrlRef.current,
          createAssetUrl,
          signal: abortRef.current.signal,
        });
        if (attachments === null) return;
        const result = await revert({
          environmentId,
          input: { threadId, turnCount, ...(mode === "chat" ? { restoreFiles: false } : {}) },
        });
        if (result._tag === "Failure") {
          if (isAtomCommandInterrupted(result)) return;
          const error = squashAtomCommandFailure(result);
          Alert.alert(
            mode === "chat" ? "Could not rewind the chat" : "Could not revert the thread",
            error instanceof Error ? error.message : "Failed to revert thread state.",
          );
          return;
        }
        const draftKey = scopedThreadKey(environmentId, threadId);
        appendComposerDraftAttachments(draftKey, attachments, { allowOverflow: true });
        const restored = restoredRevertedMessage(message, attachments, uuidv4);
        if (restored === null) {
          appendComposerDraftText(draftKey, revertedMessageEditableText(message.text));
        } else if (!insertComposerDraftContext(draftKey, restored)) {
          appendComposerDraftText(draftKey, revertedMessageEditableText(message.text));
          Alert.alert(
            "Too many context items",
            "The message is back without its context. Remove some context from the draft to add it again.",
          );
        }
      } finally {
        inFlight.current = false;
      }
    },
    [createAssetUrl, environmentId, revert, threadId],
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

  const actions = useMemo(
    () => revertMenuActions({ canRollback, canFork }).map((action) => MENU_ACTIONS[action]),
    [canFork, canRollback],
  );

  return useCallback(
    (messageId: MessageId) => {
      const turnCount = turnCounts?.get(messageId);
      if (turnCount === undefined) return null;
      return {
        actions,
        onPressAction: ({ nativeEvent }) => {
          const action = nativeEvent.event;
          if (!isRevertMenuAction(action)) return;
          if (running) {
            Alert.alert("Turn in progress", REVERT_WHILE_RUNNING);
            return;
          }
          switch (action) {
            case "fork":
              void forkAt(turnCount);
              return;
            case "restore-files":
              Alert.alert("Restore files", restoreFilesConfirmText(turnCount), [
                { text: "Cancel", style: "cancel" },
                {
                  text: "Restore",
                  style: "destructive",
                  onPress: () => void restoreFiles(turnCount),
                },
              ]);
              return;
            case "files":
            case "chat": {
              const confirm = action === "chat" ? REWIND_CHAT_CONFIRM : EDIT_FROM_HERE_CONFIRM;
              Alert.alert(confirm.title, confirm.body, [
                { text: "Cancel", style: "cancel" },
                {
                  text: confirm.button,
                  style: "destructive",
                  onPress: () => void rewind(action, turnCount, messageId),
                },
              ]);
              return;
            }
          }
        },
      };
    },
    [actions, forkAt, restoreFiles, rewind, running, turnCounts],
  );
}
