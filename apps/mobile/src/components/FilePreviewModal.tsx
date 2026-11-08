import * as Schema from "effect/Schema";
import * as Dialog from "./ui/Dialog";
import { useContext, useEffect, useEffectEvent, useRef, useState } from "react";
import { Platform } from "react-native";

import { loadLocalAttachmentPreview } from "../lib/localAttachmentPreview";
import { reusablePreviewUrl } from "../features/infinitus/previewUrlReuse.logic";
import {
  downloadAndShareAttachment,
  nativeViewerErrorMessage,
  shareLocalAttachment,
} from "../lib/attachmentDownload";
import { usePreviewPresentation } from "../lib/previewPresentation";
import { refreshAssetUrl } from "../state/assets";
import { filePreviewGallery, filePreviewKey, filePreviewName } from "../lib/filePreviewGallery";
import { FilePreviewGallery } from "./FilePreviewGallery";
import { FilePreview } from "./FilePreview";
import type { MediaActionsSource } from "../lib/mediaActionsSource";
import type { FilePreviewItem, FilePreviewSource } from "./FilePreviewModal.types";

export type {
  FilePreviewItem,
  FilePreviewSource,
  ResolvedFilePreviewSource,
} from "./FilePreviewModal.types";

class PreviewResolutionError extends Schema.TaggedError<PreviewResolutionError>()(
  "PreviewResolutionError",
  { cause: Schema.Defect(), fallbackMessage: Schema.String },
) {
  override get message(): string {
    return this.fallbackMessage;
  }
}

const isPreviewResolutionError = Schema.is(PreviewResolutionError);

interface ResolvedPreviewUri {
  readonly uri: string;
  readonly dispose?: () => void;
  /** Fork: opened on the thumbnail's URL rather than a fresh one. */
  readonly reusedUrl?: boolean;
}

async function resolvePreviewUri(
  item: FilePreviewItem,
  signal: AbortSignal,
  reuseCachedUrl: boolean,
): Promise<ResolvedPreviewUri | null> {
  if ("uri" in item) return { uri: item.uri };
  if ("attachment" in item) {
    return loadLocalAttachmentPreview(item.attachment, signal).catch((error: unknown) => {
      throw new PreviewResolutionError({
        cause: error,
        fallbackMessage: "Attach the file again and retry.",
      });
    });
  }
  // Fork: iOS only, since its native preview reports a refused download, which the retry
  // needs; Android's in-app viewer has no such signal, so it keeps minting a fresh URL.
  const reused =
    reuseCachedUrl && Platform.OS === "ios"
      ? reusablePreviewUrl({ resource: item.resource, cached: item.cachedUrl, now: Date.now() })
      : null;
  if (reused !== null) return { uri: reused + (item.srcFragment ?? ""), reusedUrl: true };
  // Refresh expired URLs before handing them to Quick Look or ACTION_VIEW, which retain them.
  const url = await refreshAssetUrl(item.environmentId, item.resource, signal)
    .then((value) => {
      if (!value) throw new Error("Reconnect to this environment and try again.");
      return value;
    })
    .catch((error: unknown) => {
      throw new PreviewResolutionError({
        cause: error,
        fallbackMessage:
          "Reconnect to this environment and try again. The file may have been moved or deleted.",
      });
    });
  return { uri: url + (item.srcFragment ?? "") };
}

// Shares from the unresolved item so remote URLs refresh and draft files take their own lease.
function pdfActionsSource(item: FilePreviewItem): MediaActionsSource {
  const metadata = {
    name: filePreviewName(item),
    mimeType: item.mimeType ?? "application/pdf",
    ...(item.sourceIdentifier ? { sourceIdentifier: item.sourceIdentifier } : {}),
  };
  if ("uri" in item) return { ...metadata, uri: item.uri };
  if ("attachment" in item) return { ...metadata, attachment: item.attachment };
  return { ...metadata, environmentId: item.environmentId, resource: item.resource };
}

function ResolvedFilePreview(props: {
  readonly source: FilePreviewSource;
  readonly onRequestClose: () => void;
  readonly onOpenError?: (error: unknown) => void;
}) {
  // Freeze the group at opening; streaming messages and URL refreshes must not reopen the viewer.
  const [items] = useState(() => filePreviewGallery(props.source, []));
  const selectedKey = filePreviewKey(props.source);
  const selectedIndex = items.findIndex((item) => filePreviewKey(item) === selectedKey);
  const progressiveGallery = Platform.OS === "ios";
  const initialUris = () => items.map((item) => ("uri" in item ? item.uri : undefined));
  // Undefined while resolving, null once it cannot be.
  const [uris, setUris] = useState<readonly (string | null | undefined)[]>(initialUris);
  // Fork: the tapped item may open on its thumbnail's URL (`previewUrlReuse.logic.ts`). A reused
  // URL can still be refused (the phone's clock runs behind the server's); the first failure
  // resolves the gallery again, the tapped item with a fresh URL, instead of reporting it broken.
  const [reusedSelectedUrl, setReusedSelectedUrl] = useState(false);
  const [freshUrlAttempt, setFreshUrlAttempt] = useState(0);
  const retrying = useRef(false);
  const onResolutionError = useEffectEvent((error: PreviewResolutionError) => {
    if (props.onOpenError) props.onOpenError(error.cause);
    else Dialog.alert("Could not open preview", error.fallbackMessage);
    props.onRequestClose();
  });
  // Resolves once per presentation and holds local file leases until it closes.
  // oxlint-disable-next-line t3code/no-unreasoned-state-sync -- resolves preview files and holds their local file leases until the preview closes
  useEffect(() => {
    const controller = new AbortController();
    const leases: (() => void)[] = [];
    const settle = (index: number, uri: string | null) =>
      setUris((current) => current.map((value, at) => (at === index ? uri : value)));
    items.forEach((item, index) => {
      if ("uri" in item) return;
      const reuseCachedUrl = index !== selectedIndex || freshUrlAttempt === 0;
      void resolvePreviewUri(item, controller.signal, reuseCachedUrl).then(
        (resolved) => {
          if (controller.signal.aborted) return resolved?.dispose?.();
          if (resolved?.dispose) leases.push(resolved.dispose);
          if (index === selectedIndex) setReusedSelectedUrl(resolved?.reusedUrl === true);
          settle(index, resolved?.uri ?? null);
        },
        (error: unknown) => {
          if (controller.signal.aborted) return;
          if (progressiveGallery && index !== selectedIndex) return settle(index, null);
          controller.abort();
          onResolutionError(
            isPreviewResolutionError(error)
              ? error
              : new PreviewResolutionError({ cause: error, fallbackMessage: "Try again." }),
          );
        },
      );
    });
    return () => {
      controller.abort();
      for (const dispose of leases) dispose();
    };
  }, [items, selectedIndex, progressiveGallery, freshUrlAttempt]);
  const retryWithFreshUrl = () => {
    retrying.current = true;
    setReusedSelectedUrl(false);
    setUris(initialUris());
    setFreshUrlAttempt((attempt) => attempt + 1);
  };
  const onRequestClose = () => {
    // The failed open closes itself right after reporting; the retry owns the preview now.
    if (retrying.current) retrying.current = false;
    else props.onRequestClose();
  };
  const selected = { ...items[selectedIndex]!, name: filePreviewName(items[selectedIndex]!) };
  if (selected.kind === "image") {
    // Android's viewer resets image gestures when its sources change during a presentation.
    if (!progressiveGallery && uris.some((uri) => uri === undefined)) return null;
    const images = items.map((item, index) => {
      const uri = uris[index];
      return {
        ...item,
        name: filePreviewName(item),
        ...(uri ? { uri } : uri === null ? { failed: true } : {}),
      };
    });
    return (
      <FilePreview
        key={freshUrlAttempt}
        source={{ kind: "image", images, selectedIndex }}
        onRequestClose={onRequestClose}
        {...(reusedSelectedUrl
          ? { onOpenError: retryWithFreshUrl }
          : props.onOpenError
            ? { onOpenError: props.onOpenError }
            : {})}
      />
    );
  }
  const uri = uris[selectedIndex];
  if (!uri) return null;
  const onOpenError = (error: unknown) => {
    if (props.onOpenError) return props.onOpenError(error);
    Dialog.alert("Could not open preview", nativeViewerErrorMessage(error), [
      { text: "Cancel", style: "cancel" },
      ...(selected.kind === "document"
        ? [
            {
              text: "Save or share",
              onPress: () => {
                const input = {
                  attachment: {
                    name: selected.name,
                    mimeType: selected.mimeType ?? "application/octet-stream",
                  },
                  signal: new AbortController().signal,
                };
                const sharing = /^(file|content):/.test(uri)
                  ? shareLocalAttachment({ ...input, uri })
                  : downloadAndShareAttachment({ ...input, url: uri });
                void sharing.catch(() => Dialog.alert("Could not share file", "Please try again."));
              },
            },
          ]
        : []),
    ]);
  };
  const actionsSource =
    selected.kind === "pdf" ? (selected.actionsSource ?? pdfActionsSource(selected)) : undefined;
  return (
    <FilePreview
<<<<<<< HEAD
      key={freshUrlAttempt}
      source={{ ...selected, kind: selected.kind, uri }}
      onRequestClose={onRequestClose}
      onOpenError={reusedSelectedUrl ? retryWithFreshUrl : onOpenError}
=======
      source={{
        ...selected,
        kind: selected.kind,
        uri,
        ...(actionsSource ? { actionsSource } : {}),
      }}
      onRequestClose={props.onRequestClose}
      onOpenError={onOpenError}
>>>>>>> upstream-sync-8e6a732305-upstream-renamed
    />
  );
}

export function FilePreviewModal(props: {
  readonly source: FilePreviewSource | null;
  readonly onRequestClose: () => void;

  readonly onOpenError?: (error: unknown) => void;
}) {
  const group = useContext(FilePreviewGallery);
  const source =
    props.source === null
      ? null
      : { ...props.source, gallery: filePreviewGallery(props.source, group) };
  usePreviewPresentation(source && filePreviewKey(source), props.onRequestClose);

  if (!source) return null;
  return (
    <ResolvedFilePreview
      key={filePreviewKey(source)}
      source={source}
      onRequestClose={props.onRequestClose}
      {...(props.onOpenError ? { onOpenError: props.onOpenError } : {})}
    />
  );
}
