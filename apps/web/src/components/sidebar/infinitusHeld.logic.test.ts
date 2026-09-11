import { ThreadId } from "@t3tools/contracts";
import { describe, expect, it } from "vite-plus/test";

import { heldSummaryFor } from "./infinitusHeld.logic";

const one = ThreadId.make("thread-1");
const two = ThreadId.make("thread-2");

describe("heldSummaryFor", () => {
  it("is the held row's line for a held thread and null for any other", () => {
    const holds = [{ threadId: one, since: "2026-09-11T10:00:00.000Z", summary: "Held on claude" }];
    expect(heldSummaryFor(holds, one)).toBe("Held on claude");
    expect(heldSummaryFor(holds, two)).toBeNull();
  });

  it("is null while the list has not arrived (older server, stream not up yet)", () => {
    expect(heldSummaryFor(undefined, one)).toBeNull();
    expect(heldSummaryFor(null, one)).toBeNull();
  });
});
