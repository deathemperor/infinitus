import { describe, expect, it } from "vite-plus/test";
import { MessageId, ThreadId, TurnId } from "@t3tools/contracts";

import {
  claudeForkAnchor,
  forkCreateFields,
  forkMarkerText,
  forkSeedMessages,
  forkSeedMessagesByTurns,
  latestClaudeForkAnchor,
} from "./ThreadFork.ts";

const threadId = ThreadId.make("thread-1");

describe("claudeForkAnchor (#270 E2)", () => {
  it("finds the turn's anchor in a Claude resume cursor by turn id", () => {
    const cursor = {
      threadId,
      resume: "sess-1",
      anchors: [
        { turnId: "turn-1", at: "uuid-1" },
        { turnId: "turn-2", at: "uuid-2" },
      ],
    };
    const turn = (id: string) => TurnId.make(id);
    expect(claudeForkAnchor(cursor, turn("turn-2"))).toEqual({ sessionId: "sess-1", at: "uuid-2" });
    expect(claudeForkAnchor(cursor, turn("turn-3"))).toBeNull();
    expect(claudeForkAnchor({ resume: "sess-1" }, turn("turn-1"))).toBeNull();
    expect(
      claudeForkAnchor({ anchors: [{ turnId: "turn-1", at: "uuid-1" }] }, turn("turn-1")),
    ).toBeNull();
    expect(claudeForkAnchor(null, turn("turn-1"))).toBeNull();
  });
});

describe("latestClaudeForkAnchor (#269 C)", () => {
  it("takes the last anchor and knows every completed turn", () => {
    const latest = latestClaudeForkAnchor({
      threadId,
      resume: "sess-1",
      anchors: [
        { turnId: "turn-1", at: "uuid-1" },
        { turnId: "", at: "dropped" },
        { turnId: "turn-2", at: "uuid-2" },
      ],
    });
    expect(latest?.sessionId).toBe("sess-1");
    expect(latest?.at).toBe("uuid-2");
    expect(latest?.turnCount).toBe(2);
    expect([...(latest?.turnIds ?? [])]).toEqual(["turn-1", "turn-2"]);
  });

  it("is null before any turn completed, or without a session", () => {
    expect(latestClaudeForkAnchor({ resume: "sess-1", anchors: [] })).toBeNull();
    expect(latestClaudeForkAnchor({ resume: "sess-1" })).toBeNull();
    expect(latestClaudeForkAnchor({ anchors: [{ turnId: "turn-1", at: "uuid-1" }] })).toBeNull();
    expect(latestClaudeForkAnchor(undefined)).toBeNull();
  });
});

describe("forkSeedMessagesByTurns (#269 C)", () => {
  it("keeps the completed turns' text and imported history, not the running turn", () => {
    const message = (
      id: string,
      role: "user" | "assistant" | "system",
      text: string,
      turnId: string | null,
    ) => ({
      id: MessageId.make(id),
      role,
      text,
      turnId: turnId === null ? null : TurnId.make(turnId),
      createdAt: "2026-09-12T00:00:00.000Z",
      updatedAt: "2026-09-12T00:00:00.000Z",
      streaming: false,
    });
    const seed = forkSeedMessagesByTurns(
      {
        messages: [
          message("m0", "assistant", "imported", null),
          message("m1", "user", "first", null),
          message("m2", "assistant", "answer one", "turn-1"),
          message("m3", "system", "noise", "turn-1"),
          message("m4", "assistant", "   ", "turn-1"),
          message("m5", "user", "second", null),
          message("m6", "assistant", "partial", "turn-2"),
        ],
      },
      new Set([TurnId.make("turn-1")]),
    );
    expect(seed.map((entry) => [entry.role, entry.text])).toEqual([
      ["assistant", "imported"],
      ["user", "first"],
      ["assistant", "answer one"],
      ["user", "second"],
    ]);
  });
});

describe("forkSeedMessages (#270 E2)", () => {
  const message = (
    id: string,
    role: "user" | "assistant" | "system",
    text: string,
    turnId: string | null,
    createdAt: string,
  ) => ({
    id: MessageId.make(id),
    role,
    text,
    turnId: turnId === null ? null : TurnId.make(turnId),
    createdAt,
    updatedAt: createdAt,
    streaming: false,
  });
  const checkpoint = (turn: number, turnId: string, completedAt: string) => ({
    turnId: TurnId.make(turnId),
    checkpointTurnCount: turn,
    checkpointRef: `refs/t3/${turn}`,
    status: "ready" as const,
    files: [],
    assistantMessageId: null,
    completedAt,
  });
  const thread = {
    messages: [
      message("m0", "user", "imported earlier", null, "2026-01-01T00:00:00.000Z"),
      message("m1", "user", "first ask", "turn-1", "2026-01-01T00:01:00.000Z"),
      message("m2", "assistant", "first answer", "turn-1", "2026-01-01T00:02:00.000Z"),
      message("m3", "system", "not carried", "turn-1", "2026-01-01T00:02:30.000Z"),
      message("m4", "user", "second ask", "turn-2", "2026-01-01T00:03:00.000Z"),
      message("m5", "assistant", "", "turn-2", "2026-01-01T00:04:00.000Z"),
      message("m6", "user", "late unattributed", null, "2026-01-01T00:09:00.000Z"),
    ],
    checkpoints: [
      checkpoint(1, "turn-1", "2026-01-01T00:02:30.000Z"),
      checkpoint(2, "turn-2", "2026-01-01T00:05:00.000Z"),
    ],
  };

  it("keeps user and assistant text up to the turn, by turn or by time", () => {
    expect(forkSeedMessages(thread, 1).map((entry) => entry.text)).toEqual([
      "imported earlier",
      "first ask",
      "first answer",
    ]);
    expect(forkSeedMessages(thread, 2).map((entry) => entry.text)).toEqual([
      "imported earlier",
      "first ask",
      "first answer",
      "second ask",
    ]);
    expect(forkSeedMessages(thread, 3)).toEqual([]);
  });
});

describe("forkMarkerText", () => {
  it("names the source and the turn", () => {
    expect(forkMarkerText({ title: "Fix login", id: threadId }, 2)).toBe(
      "Forked from **Fix login** at turn 2 (thread `thread-1`).",
    );
  });
});

describe("forkCreateFields (#269 C)", () => {
  const source = { id: ThreadId.make("t-main"), title: "Main work", interactionMode: "default" };

  it("keeps a plain fork in the source's mode with the turn in the title", () => {
    expect(forkCreateFields(source, { turnCount: 3 })).toEqual({
      title: "Main work (fork at turn 3)",
      interactionMode: "default",
    });
  });

  it("makes a side question read-only and marks it sideOf the source", () => {
    expect(forkCreateFields(source, { turnCount: 3, side: true })).toEqual({
      title: "Side question: Main work",
      interactionMode: "plan",
      sideOf: "t-main",
    });
  });
});
