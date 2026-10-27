import * as Dialog from "./ui/Dialog";
<<<<<<< HEAD
import { useNavigation } from "@react-navigation/native";
import {
  useCallback,
  useContext,
  useEffect,
  useEffectEvent,
  useRef,
  useState,
  useSyncExternalStore,
  useMemo,
} from "react";
import { Keyboard, Platform } from "react-native";
=======
import { useContext, useEffect, useEffectEvent, useState } from "react";
>>>>>>> upstream-sync-0b02b21e5-upstream-renamed

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

<<<<<<< HEAD
function PreviewItemResolver(props: {
  readonly source: FilePreviewItem;
  /** Fork: whether an attachment may open on the URL its thumbnail is showing. */
  readonly reuseCachedUrl: boolean;
  readonly onResolved: (source: ResolvedFilePreviewSource, reusedUrl: boolean) => void;
  readonly onRequestClose: () => void;
  readonly onOpenError?: (error: unknown) => void;
}) {
  const { source } = props;
  const environmentId = "environmentId" in source ? source.environmentId : null;
  const refreshAssetUrl = useRefreshAssetUrl(
    environmentId,
    "resource" in source ? source.resource : null,
  );
  // Resolve once per presentation; background URL refreshes must not reopen the native viewer.
  const [uri, setUri] = useState<string | null>(() => {
    if ("uri" in source) return source.uri;
    // iOS only: its native preview reports a refused download, which the retry below needs.
    // Android's in-app viewer has no such signal, so it keeps minting a fresh URL.
    if (!props.reuseCachedUrl || !("resource" in source) || Platform.OS !== "ios") return null;
    const reused = reusablePreviewUrl({
      resource: source.resource,
      cached: source.cachedUrl,
      now: Date.now(),
    });
    return reused === null ? null : reused + (source.srcFragment ?? "");
  });
  // Whether the first `uri` was the thumbnail's; a later refresh never counts as reuse.
  const [reusedUrl] = useState(uri !== null && "resource" in source);
  const onRequestClose = useEffectEvent(props.onRequestClose);
  const onResolutionError = useEffectEvent((error: unknown, fallbackMessage: string) => {
    if (props.onOpenError) props.onOpenError(error);
    else Dialog.alert("Could not open preview", fallbackMessage);
    onRequestClose();
  });
  useEffect(() => Keyboard.dismiss(), []);
  useEffect(() => {
    if (environmentId === null || uri !== null) return;
    let cancelled = false;
    // Refresh expired URLs before handing them to Quick Look or ACTION_VIEW, which retain them.
    void refreshAssetUrl()
      .then((url) => {
        if (cancelled) return;
        if (!url) throw new Error("Reconnect to this environment and try again.");
        setUri(url + (source.srcFragment ?? ""));
      })
      .catch((error: unknown) => {
        if (cancelled) return;
        onResolutionError(
          error,
          "Reconnect to this environment and try again. The file may have been moved or deleted.",
        );
      });
    return () => {
      cancelled = true;
    };
  }, [environmentId, uri, refreshAssetUrl, source.srcFragment]);
  useEffect(() => {
    if (!("attachment" in source)) return;
    const controller = new AbortController();
    let release: (() => void) | undefined;
    void loadLocalAttachmentPreview(source.attachment, controller.signal)
      .then((file) => {
        if (!file) return;
        if (controller.signal.aborted) {
          file.dispose();
          return;
        }
        release = file.dispose;
        setUri(file.uri);
      })
      .catch((error: unknown) => {
        if (controller.signal.aborted) return;
        onResolutionError(error, "Attach the file again and retry.");
      });
    return () => {
      controller.abort();
      release?.();
    };
  }, [source]);

  const onResolved = useEffectEvent(props.onResolved);
  useEffect(() => {
    if (uri !== null) onResolved({ ...source, name: filePreviewName(source), uri }, reusedUrl);
  }, [uri, source, reusedUrl]);
  return null;
=======
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
}

async function resolvePreviewItem(
  item: FilePreviewItem,
  signal: AbortSignal,
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
>>>>>>> upstream-sync-0b02b21e5-upstream-renamed
}

function ResolvedFilePreview(props: {
  readonly source: FilePreviewSource;
  readonly onRequestClose: () => void;
  readonly onOpenError?: (error: unknown) => void;
}) {
  // Freeze the group at opening; streaming messages and URL refreshes must not reopen the viewer.
  const [items] = useState(() => filePreviewGallery(props.source, []));
<<<<<<< HEAD
  const [resolved, setResolved] = useState<Record<string, ResolvedFilePreviewSource>>({});
  const selectedKey = filePreviewKey(props.source);
  // Fork: the tapped item may open on its thumbnail's URL (`previewUrlReuse.logic.ts`). A reused
  // URL can still be refused (the phone's clock runs behind the server's); the first failure
  // resolves that item again with a fresh one instead of reporting the file as broken.
  const [reusedSelectedUrl, setReusedSelectedUrl] = useState(false);
  const [freshUrlAttempt, setFreshUrlAttempt] = useState(0);
  const retrying = useRef(false);
  const onResolved = useCallback(
    (item: ResolvedFilePreviewSource, key: string, reusedUrl: boolean) => {
      setResolved((current) => ({ ...current, [key]: item }));
      if (key === selectedKey) setReusedSelectedUrl(reusedUrl);
    },
    [selectedKey],
  );
  const retryWithFreshUrl = () => {
    retrying.current = true;
    setReusedSelectedUrl(false);
    setResolved((current) =>
      Object.fromEntries(Object.entries(current).filter(([key]) => key !== selectedKey)),
    );
    setFreshUrlAttempt((attempt) => attempt + 1);
  };
  const selected = resolved[selectedKey];
  const gallery = useMemo(
    () =>
      items.flatMap((item) => {
        const value = resolved[filePreviewKey(item)];
        return value ? [value] : [];
      }),
    [items, resolved],
=======
  const selectedKey = filePreviewKey(props.source);
  const [gallery, setGallery] = useState<readonly ResolvedFilePreviewSource[] | null>(() =>
    items.every((item) => "uri" in item)
      ? items.map((item) => ({ ...item, name: filePreviewName(item) }))
      : null,
>>>>>>> upstream-sync-0b02b21e5-upstream-renamed
  );
  const onResolutionError = useEffectEvent((error: PreviewResolutionError) => {
    if (props.onOpenError) props.onOpenError(error.cause);
    else Dialog.alert("Could not open preview", error.fallbackMessage);
    props.onRequestClose();
  });
  // Resolves once per presentation and holds local file leases until it closes.
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
      items.map((item) =>
        resolvePreviewItem(item, controller.signal).catch((error: unknown) => {
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
      if (sources.length === items.length) setGallery(sources);
    });
    return () => {
      controller.abort();
      void resolving.then((settled) => {
        for (const item of settled) if (item.status === "fulfilled") item.value?.dispose?.();
      });
    };
  }, [items]);
  const selected = gallery?.[items.findIndex((item) => filePreviewKey(item) === selectedKey)];
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
<<<<<<< HEAD
    <>
      {items.map((item) => {
        const key = filePreviewKey(item);
        const isSelected = key === selectedKey;
        return (
          <PreviewItemResolver
            key={isSelected ? `${key}:${freshUrlAttempt}` : key}
            source={item}
            reuseCachedUrl={!isSelected || freshUrlAttempt === 0}
            onResolved={(value, reusedUrl) => onResolved(value, key, reusedUrl)}
            onRequestClose={props.onRequestClose}
            onOpenError={props.onOpenError}
          />
        );
      })}
      {ready ? (
        <FilePreview
          source={{ ...selected, gallery }}
          onRequestClose={() => {
            // The failed open closes itself right after reporting; the retry owns the preview now.
            if (retrying.current) retrying.current = false;
            else props.onRequestClose();
          }}
          onOpenError={reusedSelectedUrl ? retryWithFreshUrl : onOpenError}
        />
      ) : null}
    </>
=======
    <FilePreview
      source={{ ...selected, gallery }}
      onRequestClose={props.onRequestClose}
      onOpenError={onOpenError}
    />
>>>>>>> upstream-sync-0b02b21e5-upstream-renamed
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
