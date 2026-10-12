import {
  isProviderSendTurnSupportedImageMimeType,
  PROVIDER_SEND_TURN_MAX_IMAGE_BYTES,
} from "@infinitus/contracts";

/**
 * Largest still image sent byte for byte. A full-resolution phone screenshot is a 5-10 MB PNG,
 * which a model reads no better than its 2048px JPEG and which a slow relay cannot finish
 * uploading before it cuts the request.
 */
export const ORIGINAL_STILL_IMAGE_MAX_BYTES = 2 * 1024 * 1024;

/**
 * The mime type to keep when an incoming image (picked, pasted or shared) may pass through
 * unchanged, or null when it must be rendered to a bounded JPEG off the JS thread (HEIC/HEIF,
 * large stills, unmeasurable sources). Small originals pass through so transparency survives.
 * A GIF keeps the provider cap: rendering it would drop its animation.
 */
export function originalImagePassthroughMimeType(input: {
  readonly mimeType: string | undefined;
  readonly sourceBytes: number | null;
}): string | null {
  const { mimeType, sourceBytes } = input;
  if (
    mimeType === undefined ||
    !isProviderSendTurnSupportedImageMimeType(mimeType) ||
    sourceBytes === null ||
    sourceBytes <= 0
  ) {
    return null;
  }
  const maxBytes =
    mimeType === "image/gif" ? PROVIDER_SEND_TURN_MAX_IMAGE_BYTES : ORIGINAL_STILL_IMAGE_MAX_BYTES;
  return sourceBytes <= maxBytes ? mimeType : null;
}

/** The attachment name once a picture has been rendered to JPEG: the stem keeps, the extension says what the bytes are. */
export function jpegAttachmentName(name: string): string {
  return /\.jpe?g$/i.test(name) ? name : `${name.replace(/\.[^.]+$/, "")}.jpg`;
}
