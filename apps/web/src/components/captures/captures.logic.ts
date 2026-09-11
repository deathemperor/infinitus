import type { CaptureItem } from "@t3tools/contracts/captures";

/**
 * The composer's Captures popover (#433), as pure state: which order the
 * list is drawn in, what a selection or a paste becomes, and what to say
 * when the server refuses.
 */

/** Open items first, newest on top; done items below in the same order. */
export function orderCaptures(list: ReadonlyArray<CaptureItem>): ReadonlyArray<CaptureItem> {
  const newestFirst = (a: CaptureItem, b: CaptureItem) =>
    b.createdAt.epochMilliseconds - a.createdAt.epochMilliseconds;
  return [
    ...list.filter((item) => item.doneAt === null).sort(newestFirst),
    ...list.filter((item) => item.doneAt !== null).sort(newestFirst),
  ];
}

export function openCaptureCount(list: ReadonlyArray<CaptureItem>): number {
  return list.filter((item) => item.doneAt === null).length;
}

/** The text a capture is made of: trimmed, kept as one item however many
    lines it has, or null when there is nothing to keep. */
export function captureText(raw: string | null | undefined): string | null {
  const trimmed = (raw ?? "").trim();
  return trimmed === "" ? null : trimmed;
}

/** The one-line preview a row shows. */
export function captureSnippet(text: string, maxChars = 120): string {
  const flat = text.replace(/\s+/g, " ").trim();
  return flat.length > maxChars ? `${flat.slice(0, maxChars)}…` : flat;
}

/** What a refused `apply` tells the user. */
export function captureApplyFailureMessage(error: unknown): string {
  if (error !== null && typeof error === "object" && "_tag" in error) {
    const tagged = error as { _tag: unknown; limit?: unknown; detail?: unknown };
    if (tagged._tag === "CaptureListFull") {
      return `This project already holds ${String(tagged.limit)} captures. Clear the done ones or remove some first.`;
    }
    if (tagged._tag === "CaptureStoreError" && typeof tagged.detail === "string") {
      return `The captures file could not be updated: ${tagged.detail}`;
    }
  }
  return error instanceof Error ? error.message : "The captures could not be updated.";
}
