import { describe, expect, it } from "vite-plus/test";
import { ThreadId, TurnId } from "@t3tools/contracts";

import {
  appendAnswerToDraft,
  hasCompletedTurn,
  isSideQuestionGone,
  isSideQuestionMessage,
} from "./SideQuestionPanel.logic";

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

describe("hasCompletedTurn (#269 C)", () => {
  const turn = (id: string) => TurnId.make(id);
  const assistant = (turnId: string | null, streaming = false) => ({
    role: "assistant",
    turnId: turnId === null ? null : turn(turnId),
    streaming,
  });

  it("needs an assistant message finished under a turn that is not the running one", () => {
    expect(hasCompletedTurn({ messages: [], session: null })).toBe(false);
    expect(
      hasCompletedTurn({
        messages: [{ role: "user", turnId: null, streaming: false }, assistant(null)],
        session: null,
      }),
    ).toBe(false);
    expect(
      hasCompletedTurn({
        messages: [assistant("turn-1", true)],
        session: { activeTurnId: turn("turn-1") },
      }),
    ).toBe(false);
    expect(
      hasCompletedTurn({
        messages: [assistant("turn-1")],
        session: { activeTurnId: turn("turn-1") },
      }),
    ).toBe(false);
    expect(
      hasCompletedTurn({
        messages: [assistant("turn-1"), assistant("turn-2", true)],
        session: { activeTurnId: turn("turn-2") },
      }),
    ).toBe(true);
    expect(hasCompletedTurn({ messages: [assistant("turn-1")], session: null })).toBe(true);
  });
});

describe("isSideQuestionGone (#269 C)", () => {
  it("needs a bootstrapped shell index and a settled drawer before a missing thread counts", () => {
    expect(isSideQuestionGone({ hasThread: false, bootstrapped: true, settled: true })).toBe(true);
    expect(isSideQuestionGone({ hasThread: true, bootstrapped: true, settled: true })).toBe(false);
    expect(isSideQuestionGone({ hasThread: false, bootstrapped: false, settled: true })).toBe(
      false,
    );
    expect(isSideQuestionGone({ hasThread: false, bootstrapped: true, settled: false })).toBe(
      false,
    );
  });
});

describe("appendAnswerToDraft (#269 C)", () => {
  it("appends after a blank line, or stands alone", () => {
    expect(appendAnswerToDraft("", "Answer")).toBe("Answer");
    expect(appendAnswerToDraft("  \n", "Answer")).toBe("Answer");
    expect(appendAnswerToDraft("Draft  \n", "Answer")).toBe("Draft\n\nAnswer");
  });
});
