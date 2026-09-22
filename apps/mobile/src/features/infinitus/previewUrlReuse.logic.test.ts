import { ThreadId, type AssetResource } from "@infinitus/contracts";
import { describe, expect, it } from "vite-plus/test";

import { PREVIEW_URL_REUSE_MARGIN_MS, reusablePreviewUrl } from "./previewUrlReuse.logic";

const NOW = 1_800_000_000_000;
const attachment: AssetResource = {
  _tag: "attachment",
  attachmentId: "att-1",
  fileName: "pasted-image.png",
  mimeType: "image/png",
};
const url = "https://mac.example/api/assets/token/pasted-image.png";

describe("reusablePreviewUrl", () => {
  it("reuses the thumbnail's URL for an attachment with time left", () => {
    const cached = { url, expiresAt: NOW + 30 * 60_000 };
    expect(reusablePreviewUrl({ resource: attachment, cached, now: NOW })).toBe(url);
  });

  it("asks for a fresh URL once the token is inside the margin", () => {
    const cached = { url, expiresAt: NOW + PREVIEW_URL_REUSE_MARGIN_MS };
    expect(reusablePreviewUrl({ resource: attachment, cached, now: NOW })).toBeNull();
  });

  it("asks for a fresh URL when the thumbnail never resolved one", () => {
    expect(reusablePreviewUrl({ resource: attachment, cached: undefined, now: NOW })).toBeNull();
  });

  it("always reauthorizes a file that can change on disk", () => {
    const cached = { url, expiresAt: NOW + 30 * 60_000 };
    const resource: AssetResource = {
      _tag: "workspace-file",
      threadId: ThreadId.make("thread-1"),
      path: "shots/a.png",
    };
    expect(reusablePreviewUrl({ resource, cached, now: NOW })).toBeNull();
  });
});
