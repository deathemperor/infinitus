import type { ThreadId } from "@t3tools/contracts";
import { describe, expect, it } from "vite-plus/test";

import {
  isSideQuestion,
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
