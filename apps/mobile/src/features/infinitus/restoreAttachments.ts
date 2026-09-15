import { resolveAssetUrl } from "@t3tools/client-runtime/state/assets";
import {
  isAtomCommandInterrupted,
  squashAtomCommandFailure,
  type AtomCommandResult,
} from "@t3tools/client-runtime/state/runtime";
import type { AssetCreateUrlInput, ChatAttachment, EnvironmentId } from "@t3tools/contracts";
import { Alert } from "react-native";

import { downloadAttachmentForPreview } from "../../lib/attachmentDownload";
import {
  persistComposerAttachmentFile,
  type DraftComposerAttachment,
} from "../../lib/composerImages";
import { uuidv4 } from "../../lib/uuid";

/** The `assetEnvironment.createUrl` runner (`useAtomQueryRunner`), as the callers hold it. */
export type CreateAssetUrl = (target: {
  readonly environmentId: EnvironmentId;
  readonly input: AssetCreateUrlInput;
}) => Promise<AtomCommandResult<{ readonly relativeUrl: string }, unknown>>;

/**
 * Fork (#806, #269 item 13): a sent or queued message's attachments back as
 * composer files — each one downloaded from the thread's store into the
 * app-owned attachment directory under a fresh id, so the next send uploads
 * it again. Shared by the queue's "Edit" and the revert menu's hand-back,
 * which must download BEFORE the revert: the server prunes a reverted
 * message's uploads (#847). Alerts on its own failure and answers null, and
 * null without a word when the download was aborted (the screen left).
 */
export async function downloadDraftAttachments(input: {
  readonly environmentId: EnvironmentId;
  readonly attachments: ReadonlyArray<ChatAttachment>;
  readonly httpBaseUrl: string | null;
  readonly createAssetUrl: CreateAssetUrl;
  readonly signal: AbortSignal;
}): Promise<DraftComposerAttachment[] | null> {
  const attachments: DraftComposerAttachment[] = [];
  for (const attachment of input.attachments) {
    if (attachment.type !== "image" && attachment.type !== "file") continue;
    if (input.httpBaseUrl === null) {
      Alert.alert("The environment is not connected.");
      return null;
    }
    const urlResult = await input.createAssetUrl({
      environmentId: input.environmentId,
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
      if (!isAtomCommandInterrupted(urlResult)) {
        const error = squashAtomCommandFailure(urlResult);
        Alert.alert(
          `Could not load ${attachment.name}`,
          error instanceof Error && error.message.length > 0 ? error.message : undefined,
        );
      }
      return null;
    }
    const url = resolveAssetUrl(input.httpBaseUrl, urlResult.value.relativeUrl);
    if (url === null) {
      Alert.alert(`Could not load ${attachment.name}`);
      return null;
    }
    let fileUri: string;
    try {
      const downloaded = await downloadAttachmentForPreview({
        url,
        attachment,
        signal: input.signal,
      });
      if (downloaded === null) return null;
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
      return null;
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
  return attachments;
}
