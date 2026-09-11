import { describe, expect, it } from "vite-plus/test";

import {
  type SeenTurn,
  completionSoundLabel,
  isCompletionSound,
  turnsJustCompleted,
  windowInBackground,
} from "./infinitusCompletionSound.logic";

const shell = (
  id: string,
  turn: { turnId: string; state: "running" | "completed" | "error" } | null,
) => ({
  environmentId: "env",
  id,
  latestTurn: turn,
});

describe("turnsJustCompleted", () => {
  it("rings for a known thread whose running turn completed, and records the rest", () => {
    const first = turnsJustCompleted(new Map(), [
      shell("a", { turnId: "t1", state: "running" }),
      shell("b", { turnId: "t2", state: "completed" }),
      shell("c", null),
    ]);
    // First render: everything seeds, nothing rings, however it looks.
    expect(first.completed).toEqual([]);
    expect([...first.next.entries()]).toEqual([
      ["env:a", "t1:running"],
      ["env:b", "t2:completed"],
      ["env:c", null],
    ]);

    const second = turnsJustCompleted(first.next, [
      shell("a", { turnId: "t1", state: "completed" }),
      shell("b", { turnId: "t2", state: "completed" }),
      shell("c", { turnId: "t3", state: "completed" }),
    ]);
    // a: running → completed. b: unchanged. c: a whole turn between renders.
    expect(second.completed).toEqual(["env:a", "env:c"]);
  });

  it("stays quiet for an error or interruption, a new thread, and a re-render", () => {
    const previous = new Map<string, SeenTurn | null>([
      ["env:a", "t1:running"],
      ["env:b", "t2:running"],
    ]);
    const result = turnsJustCompleted(previous, [
      shell("a", { turnId: "t1", state: "error" }),
      shell("b", { turnId: "t2", state: "running" }),
      shell("new", { turnId: "t9", state: "completed" }),
    ]);
    expect(result.completed).toEqual([]);
    expect(
      turnsJustCompleted(result.next, [shell("new", { turnId: "t9", state: "completed" })])
        .completed,
    ).toEqual([]);
  });
});

describe("windowInBackground", () => {
  it("is hidden, or visible without focus", () => {
    expect(windowInBackground({ visibilityState: "hidden", hasFocus: () => true })).toBe(true);
    expect(windowInBackground({ visibilityState: "visible", hasFocus: () => false })).toBe(true);
    expect(windowInBackground({ visibilityState: "visible", hasFocus: () => true })).toBe(false);
  });
});

describe("sounds", () => {
  it("names each bundled sound and refuses anything else", () => {
    expect(completionSoundLabel("chime")).toBe("Chime");
    expect(isCompletionSound("whoosh")).toBe(true);
    expect(isCompletionSound("off")).toBe(false);
    expect(isCompletionSound(3)).toBe(false);
  });
});
