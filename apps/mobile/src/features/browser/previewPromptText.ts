import type { PreviewStreamControl } from "@infinitus/client-runtime/preview/server-browser-stream";

type Dialog = PreviewStreamControl["dialog"];

/** Updates the native response draft when a browser control message arrives. */
export function previewPromptText(previous: Dialog, next: Dialog, draft: string) {
  if (
    next?.type !== previous?.type ||
    next?.message !== previous?.message ||
    next?.defaultValue !== previous?.defaultValue
  ) {
    return next?.defaultValue ?? "";
  }
  return draft;
}
