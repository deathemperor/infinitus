import { describe, expect, it } from "vite-plus/test";
import { EnvironmentId, QueueId, ThreadId, type OrchestrationQueuedTurn } from "@t3tools/contracts";
import { pinOrderKeyBetween } from "@t3tools/client-runtime/state/thread-sort";

import { formatInlineContextReference } from "../../lib/composerContextReferences";
import type { PromptStashEntry } from "../../promptStashStore";
import {
  composerSendQueueKey,
  legacyQueuedEntryCommand,
  orderedQueuedTurns,
  parseComposerSendQueueKey,
  queuedTurnEditableText,
  queuedTurnMoveKey,
  queuedTurnSnippet,
  restoredQueuedTurnText,
} from "./composerSendQueue.logic";

function row(id: string, orderKey: string, text = id): OrchestrationQueuedTurn {
  return {
    queueId: QueueId.make(id),
    messageId: `${id}-message` as OrchestrationQueuedTurn["messageId"],
    text,
    attachments: [],
    orderKey,
    createdAt: "2026-09-12T00:00:00.000Z",
    updatedAt: "2026-09-12T00:00:00.000Z",
  };
}

describe("orderedQueuedTurns (#806)", () => {
  it("sorts by order key and leaves the input alone", () => {
    const rows = [row("b", "a1"), row("a", "a0"), row("c", "a2")];
    expect(orderedQueuedTurns(rows).map((entry) => entry.queueId)).toEqual(["a", "b", "c"]);
    expect(rows.map((entry) => entry.queueId)).toEqual(["b", "a", "c"]);
    expect(orderedQueuedTurns(undefined)).toEqual([]);
  });
});

describe("queuedTurnMoveKey (#806)", () => {
  const rows = orderedQueuedTurns([row("a", "a0"), row("b", "a1"), row("c", "a2")]);

  it("lands between the two rows before, or the two after", () => {
    const earlier = queuedTurnMoveKey(rows, QueueId.make("c"), "earlier");
    expect(earlier).toBe(pinOrderKeyBetween("a0", "a1"));
    const later = queuedTurnMoveKey(rows, QueueId.make("a"), "later");
    expect(later).toBe(pinOrderKeyBetween("a1", "a2"));
    expect(queuedTurnMoveKey(rows, QueueId.make("b"), "earlier")).toBe(
      pinOrderKeyBetween(null, "a0"),
    );
    expect(queuedTurnMoveKey(rows, QueueId.make("b"), "later")).toBe(
      pinOrderKeyBetween("a2", null),
    );
  });

  it("is a no-op at either end or for an unknown row", () => {
    expect(queuedTurnMoveKey(rows, QueueId.make("a"), "earlier")).toBeNull();
    expect(queuedTurnMoveKey(rows, QueueId.make("c"), "later")).toBeNull();
    expect(queuedTurnMoveKey(rows, QueueId.make("zzz"), "later")).toBeNull();
  });
});

describe("queuedTurnSnippet", () => {
  it("collapses whitespace, drops the effort prefix, and names attachment-only rows", () => {
    expect(queuedTurnSnippet(row("a", "a0", "  fix\n\nthe   test "))).toBe("fix the test");
    expect(queuedTurnSnippet(row("b", "a0", "Ultrathink:\nfix it"))).toBe("fix it");
    expect(
      queuedTurnSnippet({
        ...row("c", "a0", ""),
        attachments: [
          { type: "image", id: "img", name: "a.png", mimeType: "image/png", sizeBytes: 1 },
        ],
      }),
    ).toBe("1 attachment");
    expect(queuedTurnEditableText("Ultrathink:\nplain")).toBe("plain");
    expect(queuedTurnEditableText("plain")).toBe("plain");
  });
});

describe("legacy stash rows (#270 F → #806)", () => {
  const key = composerSendQueueKey(EnvironmentId.make("env"), ThreadId.make("t1"));

  it("round-trips the stash key", () => {
    expect(parseComposerSendQueueKey(key)).toEqual({ environmentId: "env", threadId: "t1" });
    expect(parseComposerSendQueueKey("nospace")).toBeNull();
    expect(parseComposerSendQueueKey("env ")).toBeNull();
  });

  it("turns an entry into one queue command with ids derived from the entry", () => {
    const entry: PromptStashEntry = {
      id: "entry-1",
      createdAt: "2026-09-11T00:00:00.000Z",
      prompt: "queued text",
      attachments: [
        {
          id: "img-1",
          name: "shot.png",
          mimeType: "image/png",
          sizeBytes: 3,
          dataUrl: "data:image/png;base64,AAA",
        },
      ],
      files: [
        {
          id: "file-1",
          name: "notes.txt",
          mimeType: "text/plain",
          sizeBytes: 5,
          attachmentId: "upload-1",
          environmentId: EnvironmentId.make("env"),
        },
      ],
      droppedImageNames: [],
      queuedFor: key,
    };
    expect(legacyQueuedEntryCommand(entry)).toEqual({
      commandId: "stash-migrate:entry-1",
      queueId: "entry-1",
      message: {
        messageId: "entry-1",
        role: "user",
        text: "queued text",
        attachments: [
          {
            type: "image",
            name: "shot.png",
            mimeType: "image/png",
            sizeBytes: 3,
            dataUrl: "data:image/png;base64,AAA",
          },
          { type: "file", id: "upload-1", name: "notes.txt", mimeType: "text/plain", sizeBytes: 5 },
        ],
      },
    });
    expect(legacyQueuedEntryCommand({ ...entry, pendingImageCount: 1 })).toBeNull();
  });
});

describe("restoredQueuedTurnText (#971)", () => {
  const link = (kind: string, contextId: string, label = contextId) =>
    formatInlineContextReference({ kind, contextId, label });

  it("points a link at the id its record was re-minted under and leaves the rest alone", () => {
    const text = `Look at ${link("terminal", "terminal_t1", "build.log")} and ${link("file", "file_f1", "a.ts")}.`;
    const rewritten = new Map([["terminal_t1", "terminal_t2"]]);
    expect(restoredQueuedTurnText(text, rewritten)).toBe(
      `Look at ${link("terminal", "terminal_t2", "build.log")} and ${link("file", "file_f1", "a.ts")}.`,
    );
  });

  it("brings an element link back as a preview annotation and strips the effort prefix", () => {
    const text = `Ultrathink:\nFix ${link("element", "element_e1", "button")}`;
    const rewritten = new Map([["element_e1", "preview-annotation_p1"]]);
    expect(restoredQueuedTurnText(text, rewritten)).toBe(
      `Fix ${link("preview-annotation", "preview-annotation_p1", "button")}`,
    );
  });

  it("returns plain prose unchanged", () => {
    expect(restoredQueuedTurnText("just words", new Map())).toBe("just words");
  });
});
