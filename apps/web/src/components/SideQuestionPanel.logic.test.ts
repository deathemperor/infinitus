import { describe, expect, it } from "vite-plus/test";
import { ThreadId } from "@t3tools/contracts";

import { isSideQuestionMessage } from "./SideQuestionPanel.logic";

describe("isSideQuestionMessage (#269 C)", () => {
  const threadId = ThreadId.make("side-1");

  it("hides the fork's imported history and keeps what was asked here", () => {
    expect(
      isSideQuestionMessage(threadId, { id: "side-1:000000", role: "assistant", text: "Forked" }),
    ).toBe(false);
    expect(
      isSideQuestionMessage(threadId, { id: "side-1:000003", role: "user", text: "earlier" }),
    ).toBe(false);
    expect(isSideQuestionMessage(threadId, { id: "m-1", role: "user", text: "why?" })).toBe(true);
    expect(
      isSideQuestionMessage(threadId, { id: "m-2", role: "assistant", text: "Because." }),
    ).toBe(true);
  });

  it("skips blank and non-chat messages", () => {
    expect(isSideQuestionMessage(threadId, { id: "m-3", role: "user", text: "  \n" })).toBe(false);
    expect(isSideQuestionMessage(threadId, { id: "m-4", role: "system", text: "note" })).toBe(
      false,
    );
  });
});
