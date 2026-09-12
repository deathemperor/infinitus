import type { ThreadId, TurnId } from "@t3tools/contracts";
import { describe, expect, it } from "vite-plus/test";

import {
  bringToMainText,
  hasCompletedTurn,
  isSideQuestion,
  isSideQuestionMessage,
  latestSideAnswer,
  withoutSideQuestionSnapshots,
  withoutSideQuestions,
} from "./sideQuestions";

const main = { id: "t1" as ThreadId, sideOf: null };
const legacy: { id: ThreadId; sideOf?: ThreadId | null } = { id: "t2" as ThreadId };
const side = { id: "t3" as ThreadId, sideOf: "t1" as ThreadId };

describe("isSideQuestion", () => {
  it("is true only when sideOf names another thread", () => {
    expect(isSideQuestion(main)).toBe(false);
    expect(isSideQuestion(legacy)).toBe(false);
    expect(isSideQuestion(side)).toBe(true);
  });
});

describe("withoutSideQuestions", () => {
  it("drops side questions and keeps threads without the field", () => {
    expect(withoutSideQuestions([main, side, legacy])).toEqual([main, legacy]);
  });

  it("returns the same array when nothing is filtered", () => {
    const threads = [main, legacy];
    expect(withoutSideQuestions(threads)).toBe(threads);
  });
});

describe("withoutSideQuestionSnapshots", () => {
  it("drops side questions per snapshot and keeps untouched entries", () => {
    const clean = { environmentId: "e1", snapshot: { threads: [main] } };
    const mixed = { environmentId: "e2", snapshot: { threads: [side, legacy] } };
    const result = withoutSideQuestionSnapshots([clean, mixed]);
    expect(result[0]).toBe(clean);
    expect(result[1]).toEqual({ environmentId: "e2", snapshot: { threads: [legacy] } });
  });
});

describe("isSideQuestionMessage", () => {
  const threadId = "side" as ThreadId;
  it("keeps the sheet's own question and answer", () => {
    expect(isSideQuestionMessage(threadId, { id: "m1", role: "user", text: "why?" })).toBe(true);
    expect(isSideQuestionMessage(threadId, { id: "m2", role: "assistant", text: "because" })).toBe(
      true,
    );
  });
  it("drops the imported history, other roles and blank text", () => {
    expect(isSideQuestionMessage(threadId, { id: "side:000001", role: "user", text: "hi" })).toBe(
      false,
    );
    expect(isSideQuestionMessage(threadId, { id: "m3", role: "system", text: "x" })).toBe(false);
    expect(isSideQuestionMessage(threadId, { id: "m4", role: "assistant", text: "  " })).toBe(
      false,
    );
  });
});

describe("hasCompletedTurn", () => {
  const t1 = "t1" as TurnId;
  const t2 = "t2" as TurnId;
  it("is true once an assistant message finished under a turn that is not running", () => {
    expect(
      hasCompletedTurn({
        messages: [{ role: "assistant", turnId: t1, streaming: false }],
        session: { activeTurnId: t2 },
      }),
    ).toBe(true);
  });
  it("ignores the running turn, streaming rows, imported history and users", () => {
    expect(
      hasCompletedTurn({
        messages: [
          { role: "assistant", turnId: t1, streaming: false },
          { role: "assistant", turnId: t2, streaming: true },
          { role: "assistant", turnId: null, streaming: false },
          { role: "user", turnId: t2, streaming: false },
        ],
        session: { activeTurnId: t1 },
      }),
    ).toBe(false);
    expect(hasCompletedTurn({ messages: [], session: null })).toBe(false);
  });
});

describe("latestSideAnswer / bringToMainText", () => {
  it("takes the last finished assistant text", () => {
    expect(
      latestSideAnswer([
        { role: "assistant", text: "first", streaming: false },
        { role: "user", text: "more?", streaming: false },
        { role: "assistant", text: "second", streaming: false },
        { role: "assistant", text: "partial", streaming: true },
      ]),
    ).toBe("second");
    expect(latestSideAnswer([{ role: "user", text: "q", streaming: false }])).toBeNull();
  });
  it("appends after a blank line, or stands alone on a blank draft", () => {
    expect(bringToMainText("draft  \n", "answer")).toBe("draft\n\nanswer");
    expect(bringToMainText("   ", "answer")).toBe("answer");
  });
});
