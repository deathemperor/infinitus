import * as Dialog from "./ui/Dialog";
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
<<<<<<< HEAD
import { Alert, Keyboard, Platform } from "react-native";
=======
import { Keyboard } from "react-native";
>>>>>>> upstream-sync-4f651cb10-upstream-renamed

import { loadLocalAttachmentPreview } from "../lib/localAttachmentPreview";
import { reusablePreviewUrl } from "../features/infinitus/previewUrlReuse.logic";
import { useRefreshAssetUrl } from "../state/assets";
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
    // A cached URL may have expired while the app was suspended. Await reauthorization
    // before handing a URL to Quick Look or ACTION_VIEW, which retain that URL.
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
}

function ResolvedFilePreview(props: {
  readonly source: FilePreviewSource;
  readonly onRequestClose: () => void;
  readonly onOpenError?: (error: unknown) => void;
}) {
  // Freeze the group at opening; streaming messages and URL refreshes must not reopen the viewer.
  const [items] = useState(() => filePreviewGallery(props.source, []));
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
    setResolved(({ [selectedKey]: _stale, ...rest }) => rest);
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
  );
  const ready = selected && gallery.length === items.length;
  return (
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
          onOpenError={reusedSelectedUrl ? retryWithFreshUrl : props.onOpenError}
        />
      ) : null}
    </>
  );
}

export function FilePreviewModal(props: {
  readonly source: FilePreviewSource | null;
  readonly onRequestClose: () => void;

  readonly onOpenError?: (error: unknown) => void;
}) {
  const group = useContext(FilePreviewGallery);
  const source = useMemo(
    () =>
      props.source === null
        ? null
        : {
            ...props.source,
            gallery: filePreviewGallery(props.source, group),
          },
    [props.source, group],
  );
  const navigation = useNavigation();
  const subscribeToFocus = useCallback(
    (listener: () => void) => {
      const offFocus = navigation.addListener("focus", listener);
      const offBlur = navigation.addListener("blur", listener);
      return () => {
        offFocus();
        offBlur();
      };
    },
    [navigation],
  );
  // The v5 card host sits inside a legacy presentation envelope whose focus context
  // can describe a different route. The preview belongs to this navigation route.
  const isFocused = useSyncExternalStore(
    subscribeToFocus,
    navigation.isFocused,
    navigation.isFocused,
  );
  const hasSource = props.source !== null;
  const onRequestClose = useEffectEvent(props.onRequestClose);
  useEffect(() => {
    if (!isFocused && hasSource) onRequestClose();
  }, [isFocused, hasSource]);

  if (!source || !isFocused) return null;
  return (
    <ResolvedFilePreview
      key={filePreviewKey(source)}
      source={source}
      onRequestClose={props.onRequestClose}
      {...(props.onOpenError ? { onOpenError: props.onOpenError } : {})}
    />
  );
}
