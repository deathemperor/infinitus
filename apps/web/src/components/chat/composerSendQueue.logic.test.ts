import { describe, expect, it } from "vite-plus/test";
import { EnvironmentId, ThreadId } from "@t3tools/contracts";

import type { PromptStashEntry } from "../../promptStashStore";
import {
  composerSendQueueKey,
  queuedEntriesForThread,
  queuedEntrySnippet,
  shouldDrainSendQueue,
} from "./composerSendQueue.logic";

const key = composerSendQueueKey(EnvironmentId.make("env"), ThreadId.make("t1"));

function entry(id: string, queuedFor?: string, prompt = id): PromptStashEntry {
  return {
    id,
    createdAt: "2026-09-11T00:00:00.000Z",
    prompt,
    attachments: [],
    droppedImageNames: [],
    ...(queuedFor === undefined ? {} : { queuedFor }),
  };
}

describe("queuedEntriesForThread (#270 F)", () => {
  it("returns this thread's queued entries oldest first and leaves the stash alone", () => {
    const entries = [
      entry("newest", key),
      entry("stash"),
      entry("other", "elsewhere"),
      entry("oldest", key),
    ];
    expect(queuedEntriesForThread(entries, key).map((candidate) => candidate.id)).toEqual([
      "oldest",
      "newest",
    ]);
    expect(queuedEntriesForThread(entries, null)).toEqual([]);
  });
});

describe("shouldDrainSendQueue (#270 F)", () => {
  const idle = {
    phase: "ready" as const,
    isHeld: false,
    isSendBusy: false,
    isSendDisabled: false,
    composerEmpty: true,
    isServerThread: true,
    pendingImageCount: 0,
  };

  it("drains only an idle, unheld, empty composer on a server thread", () => {
    expect(shouldDrainSendQueue(idle)).toBe(true);
    expect(shouldDrainSendQueue({ ...idle, phase: "running" })).toBe(false);
    expect(shouldDrainSendQueue({ ...idle, phase: "disconnected" })).toBe(false);
    expect(shouldDrainSendQueue({ ...idle, phase: "connecting" })).toBe(false);
    expect(shouldDrainSendQueue({ ...idle, isHeld: true })).toBe(false);
    expect(shouldDrainSendQueue({ ...idle, isSendBusy: true })).toBe(false);
    expect(shouldDrainSendQueue({ ...idle, isSendDisabled: true })).toBe(false);
    expect(shouldDrainSendQueue({ ...idle, composerEmpty: false })).toBe(false);
    expect(shouldDrainSendQueue({ ...idle, isServerThread: false })).toBe(false);
    expect(shouldDrainSendQueue({ ...idle, pendingImageCount: 1 })).toBe(false);
  });
});

describe("queuedEntrySnippet", () => {
  it("collapses whitespace and names attachment-only entries", () => {
    expect(queuedEntrySnippet(entry("a", key, "  fix\n\nthe   test "))).toBe("fix the test");
    expect(queuedEntrySnippet({ ...entry("b", key, ""), pendingImageCount: 1 })).toBe(
      "1 attachment",
    );
  });
});
