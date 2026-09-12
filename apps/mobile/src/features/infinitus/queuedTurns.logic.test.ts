import type { OrchestrationQueuedTurn } from "@t3tools/contracts";
import { ComposerContextId, MessageId, QueueId } from "@t3tools/contracts";
import {
  collectComposerContextReferences,
  formatComposerContextReference,
} from "@t3tools/shared/composerContextReferences";
import { describe, expect, it } from "vite-plus/test";

import {
  orderedQueuedTurns,
  queuedTurnEditableText,
  queuedTurnMoveKey,
  queuedTurnSnippet,
  queuedTurnsTitle,
  restoredQueuedTurn,
} from "./queuedTurns.logic";

function row(queueId: string, orderKey: string, text = "hello"): OrchestrationQueuedTurn {
  return {
    queueId: QueueId.make(queueId),
    messageId: MessageId.make(`m-${queueId}`),
    text,
    attachments: [],
    orderKey,
    createdAt: "2026-09-12T00:00:00.000Z",
    updatedAt: "2026-09-12T00:00:00.000Z",
  };
}

describe("orderedQueuedTurns", () => {
  it("sorts by order key and answers an empty list for a thread without rows", () => {
    expect(orderedQueuedTurns(undefined)).toEqual([]);
    expect(orderedQueuedTurns([row("b", "n"), row("a", "h")]).map((r) => r.queueId)).toEqual([
      "a",
      "b",
    ]);
  });
});

describe("queuedTurnEditableText / queuedTurnSnippet", () => {
  it("strips the effort prefix and collapses whitespace; attachments alone count", () => {
    expect(queuedTurnEditableText("Ultrathink:\nfix it")).toBe("fix it");
    expect(queuedTurnSnippet(row("a", "h", "Ultrathink:\n  fix\n\nit "))).toBe("fix it");
    expect(
      queuedTurnSnippet({
        ...row("a", "h", ""),
        attachments: [
          { type: "file", id: "f1", name: "a.txt", mimeType: "text/plain", sizeBytes: 1 },
        ],
      }),
    ).toBe("1 attachment");
    expect(queuedTurnSnippet(row("a", "h", "   "))).toBe("0 attachments");
  });
});

describe("queuedTurnMoveKey", () => {
  const rows = orderedQueuedTurns([row("a", "h"), row("b", "n"), row("c", "t")]);

  it("lands between the neighbours and answers null at the ends", () => {
    const earlier = queuedTurnMoveKey(rows, QueueId.make("c"), "earlier");
    expect(earlier !== null && earlier > "h" && earlier < "n").toBe(true);
    const later = queuedTurnMoveKey(rows, QueueId.make("a"), "later");
    expect(later !== null && later > "n" && later < "t").toBe(true);
    expect(queuedTurnMoveKey(rows, QueueId.make("a"), "earlier")).toBeNull();
    expect(queuedTurnMoveKey(rows, QueueId.make("c"), "later")).toBeNull();
    expect(queuedTurnMoveKey(rows, QueueId.make("zz"), "later")).toBeNull();
  });
});

describe("queuedTurnsTitle", () => {
  it("counts the rows and names what they wait on", () => {
    expect(queuedTurnsTitle(1, true)).toBe("1 queued message · sends when this turn finishes");
    expect(queuedTurnsTitle(2, false)).toBe("2 queued messages · sending when idle");
  });
});

describe("restoredQueuedTurn", () => {
  const terminal = {
    version: 1 as const,
    kind: "terminal" as const,
    contextId: ComposerContextId.make("terminal-1"),
    label: "Build output",
    terminalId: "main",
    terminalLabel: "Terminal",
    lineStart: 4,
    lineEnd: 5,
    text: "build failed",
  };
  const image = {
    version: 1 as const,
    kind: "image" as const,
    contextId: ComposerContextId.make("image-1"),
    label: "Screenshot",
    attachmentId: "wire-image",
    name: "shot.png",
    mimeType: "image/png",
    sizeBytes: 123,
  };
  const annotation = {
    version: 1 as const,
    kind: "preview-annotation" as const,
    contextId: ComposerContextId.make("preview-1"),
    label: "Button",
    annotationId: "button-1",
    pageUrl: "https://example.com",
    pageTitle: null,
    comment: "Keep the cart",
    targetSummary: "Button",
    styleChanges: [],
    screenshotContextId: image.contextId,
  };
  const queued: OrchestrationQueuedTurn = {
    ...row(
      "q",
      "h",
      `Ultrathink:\nsee ${formatComposerContextReference(terminal)} and ${formatComposerContextReference(annotation)}`,
    ),
    attachments: [
      {
        type: "image",
        id: "wire-image",
        name: "shot.png",
        mimeType: "image/png",
        sizeBytes: 123,
      },
    ],
    context: { version: 1, records: [terminal, image, annotation] },
  };

  it("answers null for a row without context", () => {
    expect(restoredQueuedTurn(row("q", "h"), [], () => "never")).toBeNull();
  });

  it("re-ids the records and the text's references, binds files to their downloaded ids", () => {
    let next = 0;
    const restored = restoredQueuedTurn(queued, [{ id: "local-image" }], () => `fresh-${++next}`);
    expect(restored?.text.startsWith("see ")).toBe(true);
    expect(collectComposerContextReferences(restored!.text).map((ref) => ref.contextId)).toEqual([
      "fresh-1",
      "fresh-3",
    ]);
    expect(restored?.context.records).toEqual([
      { ...terminal, contextId: "fresh-1" },
      { ...image, contextId: "fresh-2", attachmentId: "local-image" },
      { ...annotation, contextId: "fresh-3", screenshotContextId: "fresh-2" },
    ]);
    expect(queued.context?.records[0]?.contextId).toBe("terminal-1");
  });
});
