import type { CaptureItem } from "@t3tools/contracts/captures";
import * as DateTime from "effect/DateTime";
import { describe, expect, it } from "vite-plus/test";

import {
  captureApplyFailureMessage,
  captureSnippet,
  captureText,
  openCaptureCount,
  orderCaptures,
} from "./captures.logic";

const at = (iso: string) => DateTime.makeUnsafe(iso);
const item = (id: string, createdAt: string, doneAt: string | null = null): CaptureItem => ({
  id: id as CaptureItem["id"],
  text: id,
  createdAt: at(createdAt),
  doneAt: doneAt === null ? null : at(doneAt),
});

describe("orderCaptures", () => {
  it("draws open items newest first, then the done ones", () => {
    const list = [
      item("old-open", "2026-09-11T10:00:00Z"),
      item("done", "2026-09-11T10:03:00Z", "2026-09-11T10:04:00Z"),
      item("new-open", "2026-09-11T10:02:00Z"),
    ];
    expect(orderCaptures(list).map((entry) => entry.id)).toEqual(["new-open", "old-open", "done"]);
    expect(openCaptureCount(list)).toBe(2);
  });
});

describe("captureText", () => {
  it("trims and keeps a multi-line paste as one capture", () => {
    expect(captureText("  a\n  b\n")).toBe("a\n  b");
    expect(captureText("   ")).toBeNull();
    expect(captureText(null)).toBeNull();
  });
});

describe("captureSnippet", () => {
  it("flattens whitespace and cuts long text", () => {
    expect(captureSnippet("a\n\n  b")).toBe("a b");
    expect(captureSnippet("x".repeat(10), 4)).toBe("xxxx…");
  });
});

describe("captureApplyFailureMessage", () => {
  it("names the cap, the store's issue, or the error's own words", () => {
    expect(captureApplyFailureMessage({ _tag: "CaptureListFull", limit: 200 })).toContain("200");
    expect(captureApplyFailureMessage({ _tag: "CaptureStoreError", detail: "EACCES" })).toContain(
      "EACCES",
    );
    expect(captureApplyFailureMessage(new Error("offline"))).toBe("offline");
    expect(captureApplyFailureMessage("?")).toBe("The captures could not be updated.");
  });
});
