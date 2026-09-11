import { PROVIDER_SEND_TURN_MAX_IMAGE_BYTES } from "@t3tools/contracts";

import { estimateBase64ByteSize } from "../../lib/base64";
import type {
  DraftComposerAttachment,
  DraftComposerImageAttachment,
} from "../../lib/composerImages";

/** The bytes markup starts from: the draft's own file when it has one (rebased into
    the current container by the caller), else the inline data URL current writers
    keep, else a preview the native side can read. A photo-library or remote preview
    alone is not enough: the native copy reads only `file:` and `data:`. */
export function markupSourceUri(
  attachment: DraftComposerImageAttachment,
  ownedFileUri: string | null,
): string | null {
  if (ownedFileUri !== null) return ownedFileUri;
  if (attachment.fileUri !== undefined) return attachment.fileUri;
  if (attachment.dataUrl !== undefined) return attachment.dataUrl;
  return /^(file|data):/i.test(attachment.previewUri) ? attachment.previewUri : null;
}

const MIME_BY_EXTENSION: Readonly<Record<string, string>> = {
  png: "image/png",
  jpg: "image/jpeg",
  jpeg: "image/jpeg",
  gif: "image/gif",
  webp: "image/webp",
};

/** Quick Look keeps the file's format when it can and says so by extension; a name it
    could not type falls back to the original's kind. */
export function markupMimeType(editedUri: string, fallback: string): string {
  const extension = /\.([a-z0-9]+)(?:[?#]|$)/i.exec(editedUri)?.[1]?.toLowerCase();
  return (extension !== undefined ? MIME_BY_EXTENSION[extension] : undefined) ?? fallback;
}

export type MarkedUpAttachment =
  | { readonly attachment: DraftComposerImageAttachment }
  | { readonly error: string };

/** The attachment that replaces the original once markup saved: fresh id (so the
    upload runs again), the original's name with the extension the bytes now have,
    inline bytes like a freshly picked image. Refused past the provider's image limit. */
export function markedUpAttachment(
  original: DraftComposerImageAttachment,
  edited: { readonly uri: string; readonly base64: string },
  id: string,
): MarkedUpAttachment {
  const sizeBytes = estimateBase64ByteSize(edited.base64);
  if (sizeBytes <= 0) return { error: "Markup saved an empty image." };
  if (sizeBytes > PROVIDER_SEND_TURN_MAX_IMAGE_BYTES) {
    return { error: "The marked-up image exceeds the 10 MB attachment limit." };
  }
  const mimeType = markupMimeType(edited.uri, original.mimeType);
  const extension = mimeType.split("/")[1] === "jpeg" ? "jpg" : (mimeType.split("/")[1] ?? "png");
  const stem = original.name.replace(/\.[^.]+$/, "") || "image";
  const dataUrl = `data:${mimeType};base64,${edited.base64}`;
  return {
    attachment: {
      id,
      type: "image",
      name: `${stem}.${extension}`,
      mimeType,
      sizeBytes,
      dataUrl,
      previewUri: dataUrl,
    },
  };
}

/** The draft's list with one attachment swapped in place; unchanged (and `replaced`
    false) when the original left the draft while markup was open. */
export function replaceAttachment(
  attachments: ReadonlyArray<DraftComposerAttachment>,
  originalId: string,
  next: DraftComposerImageAttachment,
): { readonly attachments: ReadonlyArray<DraftComposerAttachment>; readonly replaced: boolean } {
  const index = attachments.findIndex((attachment) => attachment.id === originalId);
  if (index === -1) return { attachments, replaced: false };
  return { attachments: attachments.with(index, next), replaced: true };
}
