import { describe, expect, it } from "vite-plus/test";

import {
  jpegAttachmentName,
  ORIGINAL_STILL_IMAGE_MAX_BYTES,
  originalImagePassthroughMimeType,
} from "./image-passthrough";

describe("incoming image pass-through", () => {
  it("keeps a small still byte for byte so transparency survives", () => {
    expect(
      originalImagePassthroughMimeType({
        mimeType: "image/png",
        sourceBytes: ORIGINAL_STILL_IMAGE_MAX_BYTES,
      }),
    ).toBe("image/png");
  });

  it("re-encodes a full-resolution screenshot a slow relay could not finish uploading", () => {
    expect(
      originalImagePassthroughMimeType({ mimeType: "image/png", sourceBytes: 7_708_008 }),
    ).toBeNull();
  });

  it("keeps a large GIF, because rendering it would drop the animation", () => {
    expect(
      originalImagePassthroughMimeType({ mimeType: "image/gif", sourceBytes: 7_708_008 }),
    ).toBe("image/gif");
  });

  it("re-encodes what a provider cannot read or what could not be measured", () => {
    expect(
      originalImagePassthroughMimeType({ mimeType: "image/heic", sourceBytes: 10 }),
    ).toBeNull();
    expect(
      originalImagePassthroughMimeType({ mimeType: "image/png", sourceBytes: null }),
    ).toBeNull();
    expect(originalImagePassthroughMimeType({ mimeType: undefined, sourceBytes: 10 })).toBeNull();
  });

  it("renames a rendered picture after its new bytes", () => {
    expect(jpegAttachmentName("Screenshot.png")).toBe("Screenshot.jpg");
    expect(jpegAttachmentName("photo.JPEG")).toBe("photo.JPEG");
    expect(jpegAttachmentName("image")).toBe("image.jpg");
  });
});
