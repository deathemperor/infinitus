import type { EnvironmentId, ThreadId } from "@t3tools/contracts";
import { useCallback } from "react";
import { Alert } from "react-native";

import { resolveOwnedComposerAttachmentFileUri } from "../../lib/composerAttachmentFiles";
import type { DraftComposerImageAttachment } from "../../lib/composerImages";
import { scopedThreadKey } from "../../lib/scopedEntities";
import { uuidv4 } from "../../lib/uuid";
import {
  getComposerDraftSnapshot,
  replaceComposerDraftAttachments,
} from "../../state/use-composer-drafts";
import { markUpImage, markupSupported } from "./markup";
import { markedUpAttachment, markupSourceUri, replaceAttachment } from "./markupAttachment.logic";

/**
 * "Mark up" on a draft image (#269 I): Quick Look's editor over a copy of the bytes;
 * when the person saves, the flattened file replaces the attachment in the thread's
 * draft under a new id, so it uploads again and the row's thumbnail updates. Undefined
 * where the native module is missing (Android, an older build), and the composer
 * shows no pencil.
 */
export function useMarkUpDraftImage(
  environmentId: EnvironmentId,
  threadId: ThreadId,
): ((attachment: DraftComposerImageAttachment) => void) | undefined {
  const markUp = useCallback(
    (attachment: DraftComposerImageAttachment) => {
      void runMarkUp(scopedThreadKey(environmentId, threadId), attachment);
    },
    [environmentId, threadId],
  );
  return markupSupported ? markUp : undefined;
}

async function runMarkUp(threadKey: string, attachment: DraftComposerImageAttachment) {
  const { File, Paths } = await import("expo-file-system");
  const owned =
    attachment.fileUri === undefined
      ? null
      : resolveOwnedComposerAttachmentFileUri(attachment.fileUri, Paths.document.uri);
  const source = markupSourceUri(attachment, owned);
  if (source === null) {
    Alert.alert("Can't mark up this image", "Its bytes are not on this phone any more.");
    return;
  }
  let editedUri: string | null;
  try {
    editedUri = await markUpImage(source, attachment.name);
  } catch (error) {
    Alert.alert("Markup didn't open", error instanceof Error ? error.message : String(error));
    return;
  }
  if (editedUri === null) return;
  const edited = new File(editedUri);
  try {
    const result = markedUpAttachment(
      attachment,
      { uri: editedUri, base64: await edited.base64() },
      uuidv4(),
    );
    if ("error" in result) {
      Alert.alert("Image not replaced", result.error);
      return;
    }
    const current = getComposerDraftSnapshot(threadKey).attachments;
    const swapped = replaceAttachment(current, attachment.id, result.attachment);
    if (swapped.replaced) replaceComposerDraftAttachments(threadKey, swapped.attachments);
  } catch (error) {
    Alert.alert("Image not replaced", error instanceof Error ? error.message : String(error));
  } finally {
    try {
      edited.parentDirectory.delete();
    } catch {
      // Temporary files; iOS purges what is left behind.
    }
  }
}
