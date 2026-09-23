import type { AssetResource, EnvironmentId } from "@infinitus/contracts";

import type { FileBackedComposerAttachment } from "../lib/composerImages";
import type { MediaActionsSource } from "../lib/mediaActions";

export interface ResolvedFilePreviewSource {
  readonly kind: "image" | "pdf" | "document";
  readonly mimeType?: string;
  readonly uri: string;
  readonly name?: string;
  readonly sourceIdentifier?: string;
  readonly srcFragment?: string;
  readonly actionsSource?: MediaActionsSource;
}

export type FilePreviewSource = Omit<ResolvedFilePreviewSource, "uri"> &
  (
    | { readonly uri: string }
    | { readonly attachment: FileBackedComposerAttachment }
    | {
        readonly environmentId: EnvironmentId;
        readonly resource: AssetResource;
        /** The URL the thumbnail is showing, so an attachment opens without a round trip. */
        readonly cachedUrl?: { readonly url: string; readonly expiresAt: number };
      }
  );
