import { resolveAssetUrl } from "@t3tools/client-runtime/state/assets";
import {
  isAtomCommandInterrupted,
  squashAtomCommandFailure,
  type AtomCommandResult,
} from "@t3tools/client-runtime/state/runtime";
import type {
  EnvironmentId,
  OrchestrationQueuedTurn,
  OrchestrationThreadShell,
} from "@t3tools/contracts";
import * as Option from "effect/Option";
import { useCallback, useEffect, useMemo, useRef } from "react";
import { Alert } from "react-native";

import { downloadAttachmentForPreview } from "../../lib/attachmentDownload";
import {
  persistComposerAttachmentFile,
  type DraftComposerAttachment,
} from "../../lib/composerImages";
import { scopedThreadKey } from "../../lib/scopedEntities";
import { uuidv4 } from "../../lib/uuid";
import { assetEnvironment } from "../../state/assets";
import { usePreparedConnection } from "../../state/session";
import { threadEnvironment } from "../../state/threads";
import { useAtomCommand } from "../../state/use-atom-command";
import { useAtomQueryRunner } from "../../state/use-atom-query-runner";
import {
  appendComposerDraftAttachments,
  appendComposerDraftText,
  insertComposerDraftContext,
} from "../../state/use-composer-drafts";
import {
  orderedQueuedTurns,
  queuedTurnEditableText,
  queuedTurnMoveKey,
  restoredQueuedTurn,
} from "./queuedTurns.logic";

export interface QueuedTurnActions {
  /** The thread's queued messages in send order. */
  readonly rows: ReadonlyArray<OrchestrationQueuedTurn>;
  readonly sendNow: (row: OrchestrationQueuedTurn) => void;
  readonly edit: (row: OrchestrationQueuedTurn) => void;
  readonly move: (row: OrchestrationQueuedTurn, direction: "earlier" | "later") => void;
  readonly remove: (row: OrchestrationQueuedTurn) => void;
}

function alertFailure(title: string, result: AtomCommandResult<unknown, unknown>): void {
  if (result._tag !== "Failure" || isAtomCommandInterrupted(result)) return;
  const error = squashAtomCommandFailure(result);
  Alert.alert(
    title,
    error instanceof Error && error.message.length > 0 ? error.message : undefined,
  );
}

/**
 * Fork (#806): the phone's actions on a thread's server-side queue, the
 * web's `useQueuedTurnActions` over the composer draft store. "Send now" is
 * a plain turn start naming the row (`queuedFrom`), so the server drops the
 * row in the same batch. "Edit" brings the message back into the composer:
 * each attachment is downloaded from the thread's store into the app-owned
 * attachment directory (a fresh composer file, uploaded again on the next
 * send), then the row is removed, then the text and files land in the
 * thread's draft. Moves compute the new order key from the neighbours the
 * phone sees.
 */
export function useQueuedTurnActions(input: {
  readonly environmentId: EnvironmentId;
  readonly thread: OrchestrationThreadShell;
}): QueuedTurnActions {
  const { environmentId, thread } = input;
  const startTurn = useAtomCommand(threadEnvironment.startTurn, { reportFailure: false });
  const removeQueuedTurn = useAtomCommand(threadEnvironment.removeQueuedTurn, {
    reportFailure: false,
  });
  const moveQueuedTurn = useAtomCommand(threadEnvironment.moveQueuedTurn, {
    reportFailure: false,
  });
  const createAssetUrl = useAtomQueryRunner(assetEnvironment.createUrl, {
    reportFailure: false,
    refresh: true,
  });
  const connection = usePreparedConnection(environmentId);
  const httpBaseUrl = Option.isSome(connection) ? connection.value.httpBaseUrl : null;

  const queuedTurns = thread.queuedTurns;
  const rows = useMemo(() => orderedQueuedTurns(queuedTurns), [queuedTurns]);
  // The actions run after awaits; they read the rows the phone holds then,
  // not the ones it held when the tap happened.
  const rowsRef = useRef(rows);
  const httpBaseUrlRef = useRef(httpBaseUrl);
  useEffect(() => {
    rowsRef.current = rows;
    httpBaseUrlRef.current = httpBaseUrl;
  }, [httpBaseUrl, rows]);
  const editingRef = useRef(false);
  const abortRef = useRef(new AbortController());
  useEffect(() => {
    const controller = abortRef.current;
    return () => controller.abort();
  }, []);

  const sendNow = useCallback(
    (row: OrchestrationQueuedTurn) => {
      void startTurn({
        environmentId,
        input: {
          threadId: thread.id,
          message: {
            messageId: row.messageId,
            role: "user",
            text: row.text,
            attachments: row.attachments,
            ...(row.context !== undefined ? { context: row.context } : {}),
          },
          modelSelection: row.modelSelection ?? thread.modelSelection,
          runtimeMode: thread.runtimeMode,
          interactionMode: thread.interactionMode,
          queuedFrom: row.queueId,
        },
      }).then((result) => alertFailure("Could not send the queued message", result));
    },
    [
      environmentId,
      startTurn,
      thread.id,
      thread.interactionMode,
      thread.modelSelection,
      thread.runtimeMode,
    ],
  );

  const edit = useCallback(
    async (row: OrchestrationQueuedTurn) => {
      if (editingRef.current) return;
      editingRef.current = true;
      try {
        const attachments: DraftComposerAttachment[] = [];
        for (const attachment of row.attachments) {
          if (attachment.type !== "image" && attachment.type !== "file") continue;
          const baseUrl = httpBaseUrlRef.current;
          if (baseUrl === null) {
            Alert.alert("The environment is not connected.");
            return;
          }
          const urlResult = await createAssetUrl({
            environmentId,
            input: {
              resource: {
                _tag: "attachment",
                attachmentId: attachment.id,
                fileName: attachment.name,
                mimeType: attachment.mimeType,
              },
            },
          });
          if (urlResult._tag === "Failure") {
            alertFailure(`Could not load ${attachment.name}`, urlResult);
            return;
          }
          const url = resolveAssetUrl(baseUrl, urlResult.value.relativeUrl);
          if (url === null) {
            Alert.alert(`Could not load ${attachment.name}`);
            return;
          }
          let fileUri: string;
          try {
            const downloaded = await downloadAttachmentForPreview({
              url,
              attachment,
              signal: abortRef.current.signal,
            });
            if (downloaded === null) return;
            try {
              fileUri = await persistComposerAttachmentFile(downloaded.uri, attachment.name);
            } finally {
              downloaded.dispose();
            }
          } catch (error) {
            Alert.alert(
              `Could not load ${attachment.name}`,
              error instanceof Error ? error.message : undefined,
            );
            return;
          }
          const common = {
            id: uuidv4(),
            name: attachment.name,
            mimeType: attachment.mimeType,
            sizeBytes: attachment.sizeBytes,
            fileUri,
          };
          if (attachment.type === "image") {
            const source = "source" in attachment ? attachment.source : undefined;
            attachments.push({
              ...common,
              type: "image",
              previewUri: fileUri,
              ...(source ? { source } : {}),
            });
          } else {
            attachments.push({ ...common, type: "file" });
          }
        }
        // The server may have sent the row while its attachments were loading.
        if (!rowsRef.current.some((candidate) => candidate.queueId === row.queueId)) {
          Alert.alert("That message was already sent.");
          return;
        }
        const removed = await removeQueuedTurn({
          environmentId,
          input: { threadId: thread.id, queueId: row.queueId },
        });
        if (removed._tag === "Failure") {
          alertFailure("Could not take the message out of the queue", removed);
          return;
        }
        const draftKey = scopedThreadKey(environmentId, thread.id);
        // Its own attachments always come back, like a restored failed send.
        appendComposerDraftAttachments(draftKey, attachments, { allowOverflow: true });
        // Its context records come back too (#971); over the draft's record cap
        // the text alone does, as the terminal sheet refuses.
        const restored = restoredQueuedTurn(row, attachments, uuidv4);
        if (restored === null) {
          appendComposerDraftText(draftKey, queuedTurnEditableText(row.text));
        } else if (!insertComposerDraftContext(draftKey, restored)) {
          appendComposerDraftText(draftKey, queuedTurnEditableText(row.text));
          Alert.alert(
            "Too many context items",
            "The message is back without its context. Remove some context from the draft to add it again.",
          );
        }
      } finally {
        editingRef.current = false;
      }
    },
    [createAssetUrl, environmentId, removeQueuedTurn, thread.id],
  );

  const move = useCallback(
    (row: OrchestrationQueuedTurn, direction: "earlier" | "later") => {
      const orderKey = queuedTurnMoveKey(rowsRef.current, row.queueId, direction);
      if (orderKey === null) return;
      void moveQueuedTurn({
        environmentId,
        input: { threadId: thread.id, queueId: row.queueId, orderKey },
      }).then((result) => alertFailure("Could not move the queued message", result));
    },
    [environmentId, moveQueuedTurn, thread.id],
  );

  const remove = useCallback(
    (row: OrchestrationQueuedTurn) => {
      void removeQueuedTurn({
        environmentId,
        input: { threadId: thread.id, queueId: row.queueId },
      }).then((result) => alertFailure("Could not remove the queued message", result));
    },
    [environmentId, removeQueuedTurn, thread.id],
  );

  return useMemo(
    () => ({
      rows,
      sendNow,
      edit: (row: OrchestrationQueuedTurn) => void edit(row),
      move,
      remove,
    }),
    [edit, move, remove, rows, sendNow],
  );
}
