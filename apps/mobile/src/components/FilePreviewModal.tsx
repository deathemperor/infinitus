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
import type {
  FilePreviewItem,
  FilePreviewSource,
  ResolvedFilePreviewSource,
} from "./FilePreviewModal.types";

export type {
  FilePreviewItem,
  FilePreviewSource,
  ResolvedFilePreviewSource,
} from "./FilePreviewModal.types";

class PreviewResolutionError extends Error {
  constructor(
    override readonly cause: unknown,
    readonly fallbackMessage: string,
  ) {
    super(fallbackMessage, { cause });
  }
}

interface ResolvedPreviewItem {
  readonly source: ResolvedFilePreviewSource;
  readonly dispose?: () => void;
  /** Fork: opened on the thumbnail's URL rather than a fresh one. */
  readonly reusedUrl?: boolean;
}

async function resolvePreviewItem(
  item: FilePreviewItem,
  signal: AbortSignal,
  reuseCachedUrl: boolean,
): Promise<ResolvedPreviewItem | null> {
  const name = filePreviewName(item);
  if ("attachment" in item) {
    const file = await loadLocalAttachmentPreview(item.attachment, signal).catch(
      (error: unknown) => {
        throw new PreviewResolutionError(error, "Attach the file again and retry.");
      },
    );
    return file && { source: { ...item, name, uri: file.uri }, dispose: file.dispose };
  }
  if (!("environmentId" in item)) return { source: { ...item, name } };
  // Fork: iOS only, since its native preview reports a refused download, which the retry
  // needs; Android's in-app viewer has no such signal, so it keeps minting a fresh URL.
  const reused =
    reuseCachedUrl && Platform.OS === "ios"
      ? reusablePreviewUrl({ resource: item.resource, cached: item.cachedUrl, now: Date.now() })
      : null;
  if (reused !== null) {
    return { source: { ...item, name, uri: reused + (item.srcFragment ?? "") }, reusedUrl: true };
  }
  // Refresh expired URLs before handing them to Quick Look or ACTION_VIEW, which retain them.
  const url = await refreshAssetUrl(item.environmentId, item.resource, signal)
    .then((value) => {
      if (!value) throw new Error("Reconnect to this environment and try again.");
      return value;
    })
    .catch((error: unknown) => {
      throw new PreviewResolutionError(
        error,
        "Reconnect to this environment and try again. The file may have been moved or deleted.",
      );
    });
  return { source: { ...item, name, uri: url + (item.srcFragment ?? "") } };
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
  // Fork: the tapped item may open on its thumbnail's URL (`previewUrlReuse.logic.ts`). A reused
  // URL can still be refused (the phone's clock runs behind the server's); the first failure
  // resolves the gallery again, the tapped item with a fresh URL, instead of reporting it broken.
  const [reusedSelectedUrl, setReusedSelectedUrl] = useState(false);
  const [freshUrlAttempt, setFreshUrlAttempt] = useState(0);
  const retrying = useRef(false);
  const [gallery, setGallery] = useState<readonly ResolvedFilePreviewSource[] | null>(() =>
    items.every((item) => "uri" in item)
      ? items.map((item) => ({ ...item, name: filePreviewName(item) }))
      : null,
  );
  const onResolutionError = useEffectEvent((error: PreviewResolutionError) => {
    if (props.onOpenError) props.onOpenError(error.cause);
    else Dialog.alert("Could not open preview", error.fallbackMessage);
    props.onRequestClose();
  });
  // Resolves once per presentation and holds local file leases until it closes.
  // oxlint-disable-next-line t3code/no-unreasoned-state-sync -- resolves preview files and holds their local file leases until the preview closes
  useEffect(() => {
    if (items.every((item) => "uri" in item)) return;
    const controller = new AbortController();
    // The first failure closes the preview at once and cancels the rest of the gallery.
    const fail = (error: unknown) => {
      if (controller.signal.aborted) return;
      controller.abort();
      onResolutionError(
        error instanceof PreviewResolutionError
          ? error
          : new PreviewResolutionError(error, "Try again."),
      );
    };
    const resolving = Promise.allSettled(
      items.map((item, index) =>
        resolvePreviewItem(
          item,
          controller.signal,
          index !== selectedIndex || freshUrlAttempt === 0,
        ).catch((error: unknown) => {
          fail(error);
          throw error;
        }),
      ),
    );
    void resolving.then((settled) => {
      if (controller.signal.aborted) return;
      const sources = settled.flatMap((item) =>
        item.status === "fulfilled" && item.value ? [item.value.source] : [],
      );
      if (sources.length !== items.length) return;
      const selectedResult = settled[selectedIndex];
      setReusedSelectedUrl(
        selectedResult?.status === "fulfilled" && selectedResult.value?.reusedUrl === true,
      );
      setGallery(sources);
    });
    return () => {
      controller.abort();
      void resolving.then((settled) => {
        for (const item of settled) if (item.status === "fulfilled") item.value?.dispose?.();
      });
    };
  }, [items, selectedIndex, freshUrlAttempt]);
  const retryWithFreshUrl = () => {
    retrying.current = true;
    setReusedSelectedUrl(false);
    setGallery(null);
    setFreshUrlAttempt((attempt) => attempt + 1);
  };
  const selected = gallery?.[selectedIndex];
  if (!gallery || !selected) return null;
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
                    name: filePreviewName(selected),
                    mimeType: selected.mimeType ?? "application/octet-stream",
                  },
                  signal: new AbortController().signal,
                };
                const sharing = /^(file|content):/.test(selected.uri)
                  ? shareLocalAttachment({ ...input, uri: selected.uri })
                  : downloadAndShareAttachment({ ...input, url: selected.uri });
                void sharing.catch(() => Dialog.alert("Could not share file", "Please try again."));
              },
            },
          ]
        : []),
    ]);
  };
  return (
    <FilePreview
      source={{ ...selected, gallery }}
      onRequestClose={() => {
        // The failed open closes itself right after reporting; the retry owns the preview now.
        if (retrying.current) retrying.current = false;
        else props.onRequestClose();
      }}
      onOpenError={reusedSelectedUrl ? retryWithFreshUrl : onOpenError}
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
