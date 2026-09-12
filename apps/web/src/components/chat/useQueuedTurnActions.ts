import {
  type EnvironmentId,
  type OrchestrationQueuedTurn,
  QUEUED_TURN_GONE,
} from "@t3tools/contracts";
import {
  isAtomCommandInterrupted,
  squashAtomCommandFailure,
  type AtomCommandResult,
} from "@t3tools/client-runtime/state/runtime";
import { useCallback, useEffect, useMemo, useRef } from "react";

import { resolveAssetUrl } from "../../assets/assetUrls";
import { assetEnvironment } from "../../state/assets";
import { readPreparedConnection } from "../../state/session";
import { threadEnvironment } from "../../state/threads";
import { useAtomCommand } from "../../state/use-atom-command";
import { useAtomQueryRunner } from "../../state/use-atom-query-runner";
import type { Thread } from "../../types";
import { toastManager } from "../ui/toast";
import {
  orderedQueuedTurns,
  queuedTurnEditableText,
  queuedTurnMoveKey,
} from "./composerSendQueue.logic";

export interface QueuedTurnActions {
  /** The thread's queued messages in send order. */
  readonly rows: ReadonlyArray<OrchestrationQueuedTurn>;
  readonly sendNow: (row: OrchestrationQueuedTurn) => void;
  readonly edit: (row: OrchestrationQueuedTurn) => void;
  readonly move: (row: OrchestrationQueuedTurn, direction: "earlier" | "later") => void;
  readonly remove: (row: OrchestrationQueuedTurn) => void;
}

function failureDescription(result: {
  readonly cause: Parameters<typeof squashAtomCommandFailure>[0]["cause"];
}): string | undefined {
  const error = squashAtomCommandFailure(result);
  return error instanceof Error && error.message.length > 0 ? error.message : undefined;
}

function reportFailure(title: string, result: AtomCommandResult<unknown, unknown>): void {
  if (result._tag !== "Failure" || isAtomCommandInterrupted(result)) return;
  const description = failureDescription(result);
  toastManager.add({ type: "error", title, ...(description ? { description } : {}) });
}

/**
 * Fork (#806): the actions on a thread's server-side queue. "Send now" is a
 * plain turn start naming the row (`queuedFrom`), so the server drops the
 * row in the same batch. "Edit" brings the message back into the composer:
 * its attachments are fetched from the thread's store first (they become
 * fresh composer files, uploaded again on the next send), then the row is
 * removed, then the text and files land. Moves compute the new order key
 * from the neighbours the client sees.
 */
export function useQueuedTurnActions(input: {
  readonly environmentId: EnvironmentId;
  /** The open server thread; undefined on a draft, which has no queue. */
  readonly thread: Thread | undefined;
  readonly appendPrompt: (text: string) => void;
  readonly addAttachments: (files: File[]) => Promise<void>;
}): QueuedTurnActions {
  const { environmentId, thread, appendPrompt, addAttachments } = input;
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

  const queuedTurns = thread?.queuedTurns;
  const rows = useMemo(() => orderedQueuedTurns(queuedTurns), [queuedTurns]);
  // The actions run after awaits; they read the rows the client holds then,
  // not the ones it held when the click happened.
  const rowsRef = useRef(rows);
  useEffect(() => {
    rowsRef.current = rows;
  }, [rows]);

  const sendNow = useCallback(
    (row: OrchestrationQueuedTurn) => {
      if (!thread) return;
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
      }).then((result) => {
        if (
          result._tag === "Failure" &&
          !isAtomCommandInterrupted(result) &&
          failureDescription(result)?.includes(QUEUED_TURN_GONE)
        ) {
          // The drain (or another client) sent the row first: not an error.
          toastManager.add({ type: "info", title: "Already sent" });
          return;
        }
        reportFailure("Could not send the queued message", result);
      });
    },
    [environmentId, startTurn, thread],
  );

  const edit = useCallback(
    async (row: OrchestrationQueuedTurn) => {
      if (!thread) return;
      const files: File[] = [];
      for (const attachment of row.attachments) {
        if (attachment.type !== "image" && attachment.type !== "file") continue;
        const connection = readPreparedConnection(environmentId);
        if (!connection) {
          toastManager.add({ type: "error", title: "The environment is not connected." });
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
          reportFailure(`Could not load ${attachment.name}`, urlResult);
          return;
        }
        const url = resolveAssetUrl(connection.httpBaseUrl, urlResult.value.relativeUrl);
        if (url === null) {
          toastManager.add({ type: "error", title: `Could not load ${attachment.name}` });
          return;
        }
        try {
          const response = await fetch(url);
          if (!response.ok) throw new Error(`The server answered ${response.status}.`);
          const blob = await response.blob();
          files.push(new File([blob], attachment.name, { type: attachment.mimeType }));
        } catch (error) {
          toastManager.add({
            type: "error",
            title: `Could not load ${attachment.name}`,
            description: error instanceof Error ? error.message : undefined,
          });
          return;
        }
      }
      // The server may have sent the row while its attachments were loading.
      if (!rowsRef.current.some((candidate) => candidate.queueId === row.queueId)) {
        toastManager.add({ type: "info", title: "That message was already sent." });
        return;
      }
      const removed = await removeQueuedTurn({
        environmentId,
        input: { threadId: thread.id, queueId: row.queueId },
      });
      if (removed._tag === "Failure") {
        reportFailure("Could not take the message out of the queue", removed);
        return;
      }
      appendPrompt(queuedTurnEditableText(row.text));
      if (files.length > 0) await addAttachments(files);
    },
    [addAttachments, appendPrompt, createAssetUrl, environmentId, removeQueuedTurn, thread],
  );

  const move = useCallback(
    (row: OrchestrationQueuedTurn, direction: "earlier" | "later") => {
      if (!thread) return;
      const orderKey = queuedTurnMoveKey(rowsRef.current, row.queueId, direction);
      if (orderKey === null) return;
      void moveQueuedTurn({
        environmentId,
        input: { threadId: thread.id, queueId: row.queueId, orderKey },
      }).then((result) => reportFailure("Could not move the queued message", result));
    },
    [environmentId, moveQueuedTurn, thread],
  );

  const remove = useCallback(
    (row: OrchestrationQueuedTurn) => {
      if (!thread) return;
      void removeQueuedTurn({
        environmentId,
        input: { threadId: thread.id, queueId: row.queueId },
      }).then((result) => reportFailure("Could not remove the queued message", result));
    },
    [environmentId, removeQueuedTurn, thread],
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
