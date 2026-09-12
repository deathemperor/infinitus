import { describe, expect, it } from "vite-plus/test";
import { ThreadId, TurnId } from "@t3tools/contracts";

import {
  appendAnswerToDraft,
  hasCompletedTurn,
  isSideQuestionGone,
  isSideQuestionMessage,
  sideQuestionFailure,
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

describe("sideQuestionFailure (#269 C follow-up)", () => {
  const threadId = ThreadId.make("side-9");
  const user = (id: string, createdAt: string, text = "why?") =>
    ({ id, role: "user", text, streaming: false, createdAt }) as const;
  const assistant = (id: string, createdAt: string, text = "Because.") =>
    ({ id, role: "assistant", text, streaming: false, createdAt }) as const;
  const errorRow = (createdAt: string, payload: unknown, summary = "Runtime error") =>
    ({ tone: "error", summary, payload, createdAt }) as const;
  const session = (status: string, lastError: string | null = null) => ({
    status,
    activeTurnId: null,
    lastError,
  });
  const imported = assistant("side-9:000000", "2026-09-12T10:00:00.000Z", "Forked");

  it("is nothing before a question was asked here, or while a turn runs", () => {
    expect(
      sideQuestionFailure(threadId, {
        messages: [imported],
        activities: [],
        session: session("error", "x"),
      }),
    ).toBeNull();
    expect(
      sideQuestionFailure(threadId, {
        messages: [imported, user("q1", "2026-09-12T10:01:00.000Z")],
        activities: [errorRow("2026-09-12T10:01:01.000Z", { message: "boom" })],
        session: { status: "running", activeTurnId: TurnId.make("t-1"), lastError: null },
      }),
    ).toBeNull();
  });

  it("names the turn's error row after the question, message over summary, with the question to re-ask", () => {
    expect(
      sideQuestionFailure(threadId, {
        messages: [imported, user("q1", "2026-09-12T10:01:00.000Z", "what broke?")],
        activities: [
          errorRow("2026-09-12T09:59:00.000Z", { message: "older failure" }),
          errorRow("2026-09-12T10:01:02.000Z", {
            message: "Fork point not found: the session has no message at that anchor.",
          }),
        ],
        session: session("error", "Claude runtime stream failed."),
      }),
    ).toEqual({
      text: "Fork point not found: the session has no message at that anchor.",
      question: "what broke?",
    });
    expect(
      sideQuestionFailure(threadId, {
        messages: [imported, user("q1", "2026-09-12T10:01:00.000Z")],
        activities: [
          errorRow(
            "2026-09-12T10:01:02.000Z",
            { detail: "the start was refused" },
            "Turn start failed",
          ),
        ],
        session: session("idle"),
      })?.text,
    ).toBe("the start was refused");
    expect(
      sideQuestionFailure(threadId, {
        messages: [imported, user("q1", "2026-09-12T10:01:00.000Z")],
        activities: [errorRow("2026-09-12T10:01:02.000Z", null, "Turn start failed")],
        session: session("idle"),
      })?.text,
    ).toBe("Turn start failed");
  });

  it("falls back to the session's error state, and clears once an answer lands", () => {
    expect(
      sideQuestionFailure(threadId, {
        messages: [imported, user("q1", "2026-09-12T10:01:00.000Z")],
        activities: [],
        session: session("error", "Claude runtime stream failed."),
      }),
    ).toEqual({ text: "Claude runtime stream failed.", question: "why?" });
    expect(
      sideQuestionFailure(threadId, {
        messages: [imported, user("q1", "2026-09-12T10:01:00.000Z")],
        activities: [],
        session: session("error"),
      })?.text,
    ).toBe("The side question failed.");
    expect(
      sideQuestionFailure(threadId, {
        messages: [
          imported,
          user("q1", "2026-09-12T10:01:00.000Z"),
          assistant("a1", "2026-09-12T10:01:05.000Z"),
        ],
        activities: [errorRow("2026-09-12T10:01:02.000Z", { message: "transient" })],
        session: session("ready"),
      }),
    ).toBeNull();
    expect(
      sideQuestionFailure(threadId, {
        messages: [
          imported,
          user("q1", "2026-09-12T10:01:00.000Z"),
          assistant("a1", "2026-09-12T10:01:05.000Z"),
        ],
        activities: [],
        session: session("error", "later"),
      }),
    ).toBeNull();
  });
});
