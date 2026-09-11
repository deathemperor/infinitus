import { describe, expect, it } from "vite-plus/test";

import type { DraftComposerImageAttachment } from "../../lib/composerImages";
import {
  markedUpAttachment,
  markupMimeType,
  markupSourceUri,
  replaceAttachment,
} from "./markupAttachment.logic";

const original: DraftComposerImageAttachment = {
  id: "a1",
  type: "image",
  name: "Screenshot.png",
  mimeType: "image/png",
  sizeBytes: 4,
  dataUrl: "data:image/png;base64,AAAA",
  previewUri: "ph://asset",
};

describe("markupSourceUri", () => {
  it("prefers the rebased file, then the file, then inline bytes, then a readable preview", () => {
    expect(
      markupSourceUri({ ...original, fileUri: "file:///old/a.png" }, "file:///new/a.png"),
    ).toBe("file:///new/a.png");
    expect(markupSourceUri({ ...original, fileUri: "file:///old/a.png" }, null)).toBe(
      "file:///old/a.png",
    );
    expect(markupSourceUri(original, null)).toBe("data:image/png;base64,AAAA");
    expect(
      markupSourceUri({ ...original, dataUrl: undefined, previewUri: "file:///p.png" }, null),
    ).toBe("file:///p.png");
    expect(markupSourceUri({ ...original, dataUrl: undefined }, null)).toBeNull();
  });
});

describe("markupMimeType", () => {
  it("reads the edited file's extension and falls back to the original kind", () => {
    expect(markupMimeType("file:///tmp/x/Screenshot.png", "image/jpeg")).toBe("image/png");
    expect(markupMimeType("file:///tmp/x/edited.jpeg", "image/png")).toBe("image/jpeg");
    expect(markupMimeType("file:///tmp/x/edited", "image/webp")).toBe("image/webp");
    expect(markupMimeType("file:///tmp/x/edited.heic", "image/png")).toBe("image/png");
  });
});

describe("markedUpAttachment", () => {
  it("builds a fresh inline attachment named after the original with the new extension", () => {
    const result = markedUpAttachment(
      original,
      { uri: "file:///tmp/x/Screenshot.jpeg", base64: "QUJD" },
      "a2",
    );
    expect(result).toEqual({
      attachment: {
        id: "a2",
        type: "image",
        name: "Screenshot.jpg",
        mimeType: "image/jpeg",
        sizeBytes: 3,
        dataUrl: "data:image/jpeg;base64,QUJD",
        previewUri: "data:image/jpeg;base64,QUJD",
      },
    });
  });

  it("refuses empty and oversized results", () => {
    expect(markedUpAttachment(original, { uri: "file:///x.png", base64: "" }, "a2")).toEqual({
      error: "Markup saved an empty image.",
    });
    const huge = "A".repeat(15 * 1024 * 1024);
    expect(markedUpAttachment(original, { uri: "file:///x.png", base64: huge }, "a2")).toEqual({
      error: "The marked-up image exceeds the 10 MB attachment limit.",
    });
  });
});

describe("replaceAttachment", () => {
  const other = { ...original, id: "b1", name: "other.png" };
  const next = { ...original, id: "a2" };

  it("swaps the attachment in place and keeps the rest", () => {
    expect(replaceAttachment([other, original], "a1", next)).toEqual({
      attachments: [other, next],
      replaced: true,
    });
  });

  it("leaves the list alone when the original is gone", () => {
    expect(replaceAttachment([other], "a1", next)).toEqual({
      attachments: [other],
      replaced: false,
    });
  });
});
