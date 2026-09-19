import type { AssetResource } from "@infinitus/contracts";

/** Time the native download needs to start before the token it carries runs out. */
export const PREVIEW_URL_REUSE_MARGIN_MS = 60_000;

/**
 * The signed URL a thumbnail already resolved, when the full-screen preview can open
 * with it instead of waiting on a fresh one. Only attachments qualify: their bytes never
 * change under an id, while a workspace or host file can be replaced on disk and has to
 * be reauthorized for every explicit open.
 */
export function reusablePreviewUrl(input: {
  readonly resource: AssetResource;
  readonly cached: { readonly url: string; readonly expiresAt: number } | undefined;
  readonly now: number;
}): string | null {
  if (input.resource._tag !== "attachment" || input.cached === undefined) return null;
  return input.cached.expiresAt - input.now > PREVIEW_URL_REUSE_MARGIN_MS ? input.cached.url : null;
}
