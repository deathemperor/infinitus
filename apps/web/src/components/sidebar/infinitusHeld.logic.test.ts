import { ThreadId } from "@t3tools/contracts";
import { describe, expect, it } from "vite-plus/test";

import { heldEntryFor } from "./infinitusHeld.logic";

const one = ThreadId.make("thread-1");
const two = ThreadId.make("thread-2");
const three = ThreadId.make("thread-3");

describe("heldEntryFor", () => {
  it("is the row's kind and line for a held or limited thread and null for any other", () => {
    const holds = [
      { threadId: one, since: "2026-09-11T10:00:00.000Z", summary: "Held on claude" },
      {
        threadId: three,
        since: "2026-09-11T10:01:00.000Z",
        summary: "Limit hit on one@example.com",
        kind: "limited" as const,
      },
    ];
    // No kind: a server before limits joined the stream, so held.
    expect(heldEntryFor(holds, one)).toEqual({ kind: "held", summary: "Held on claude" });
    expect(heldEntryFor(holds, three)).toEqual({
      kind: "limited",
      summary: "Limit hit on one@example.com",
    });
    expect(heldEntryFor(holds, two)).toBeNull();
  });

  it("is null while the list has not arrived (older server, stream not up yet)", () => {
    expect(heldEntryFor(undefined, one)).toBeNull();
    expect(heldEntryFor(null, one)).toBeNull();
  });
});
