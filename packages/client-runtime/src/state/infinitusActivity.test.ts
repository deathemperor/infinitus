import { describe, expect, it } from "vite-plus/test";

import {
  ACTIVITY_KIND_LABELS,
  activityRows,
  decodeEventRows,
  isPollRow,
} from "./infinitusActivity.ts";

describe("ACTIVITY_KIND_LABELS", () => {
  /** Every kind the Mac writes to `events.jsonl` today: the literals
      `AppModel.logEvent` is called with — `alert` / `notice` among them, the
      app's own announcements (`AppModel.announce`) — plus the three
      `AppModel.eventKind` folds the engine's own events into. `other` is the
      deliberate no-chip default. Kept in step by hand with
      `apps/mac/Sources/Infinitus/AppModel.swift`. */
  const MAC_KINDS = [
    "death",
    "desktop",
    "ignite",
    "pairing",
    "revival",
    "switch",
    "limit",
    "resume",
    "alert",
    "notice",
  ];

  it("chips every kind the Mac logs", () => {
    for (const kind of MAC_KINDS) {
      expect(ACTIVITY_KIND_LABELS[kind], kind).toBeDefined();
    }
  });

  it("keeps `other` unchipped and tells the two limit kinds apart", () => {
    expect(ACTIVITY_KIND_LABELS["other"]).toBeUndefined();
    // One account out vs the whole fleet out: Stats counts them as separate
    // tiles, so the chips must not both read "limit".
    expect(ACTIVITY_KIND_LABELS["death"]).toBe("limit");
    expect(ACTIVITY_KIND_LABELS["limit"]).toBe("all out");
  });
});

describe("decodeEventRows", () => {
  it("reads the verb's array and rejects anything else", () => {
    expect(
      decodeEventRows([{ at: "2026-09-11T02:44:12Z", icon: "play.circle", text: "resumed" }]),
    ).toHaveLength(1);
    expect(decodeEventRows({ events: [] })).toBeNull();
    expect(decodeEventRows([{ at: 1 }])).toBeNull();
  });
});

describe("isPollRow", () => {
  it("names the poller's two lines by text, never by icon or a real kind", () => {
    expect(isPollRow({ kind: "other", text: "poll" })).toBe(true);
    expect(isPollRow({ kind: "other", text: "no switch — already consuming soonest" })).toBe(true);
    expect(isPollRow({ kind: "other", text: "headless session 42 is waiting for an answer" })).toBe(
      false,
    );
    expect(isPollRow({ kind: "other", text: "fork server: poll" })).toBe(false);
    expect(isPollRow({ kind: "switch", text: "poll" })).toBe(false);
  });
});

describe("activityRows", () => {
  const initial = [
    { at: "2026-09-11T02:00:00Z", icon: "a", text: "first", kind: "switch", id: "A" },
    { at: "2026-09-11T02:44:12Z", icon: "b", text: "no id yet" },
    { at: "2026-09-11T02:44:12Z", icon: "c", text: "same second, logged later", id: "C" },
  ];

  it("orders newest first, later-logged on top of a tie, and names id-less rows like the server", () => {
    expect(activityRows(initial, []).map((row) => [row.id, row.text, row.kind])).toEqual([
      ["C", "same second, logged later", "other"],
      ["2026-09-11T02:44:12Z#1", "no id yet", "other"],
      ["A", "first", "switch"],
    ]);
  });

  it("folds in deltas once each, by id", () => {
    const deltas = [
      { at: "2026-09-11T02:44:12Z", icon: "c", text: "same second, logged later", id: "C" },
      { at: "2026-09-11T03:00:00Z", icon: "d", text: "newest", id: "D", kind: "limit" },
    ];
    const rows = activityRows(initial, [...deltas, ...deltas]);
    expect(rows.map((row) => row.id)).toEqual(["D", "C", "2026-09-11T02:44:12Z#1", "A"]);
  });
});
