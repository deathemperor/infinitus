import { EventId, TurnId, type OrchestrationThreadActivity } from "@t3tools/contracts";
import { describe, expect, it } from "vite-plus/test";

import {
  HOLD_MARKER_KIND,
  LIMIT_MARKER_KIND,
  LIMIT_RESUME_MARKER_KIND,
  PAUSE_MARKER_KIND,
  RELEASE_MARKER_KIND,
  RESUME_MARKER_KIND,
  threadHold,
} from "./infinitusThreadHold.ts";

const marker = (
  kind: string,
  createdAt: string,
  id: string = `${kind}@${createdAt}`,
): OrchestrationThreadActivity => ({
  id: EventId.make(id),
  tone: "info",
  kind,
  summary:
    kind === HOLD_MARKER_KIND
      ? "Held for headroom on claude, 5h window 84 %"
      : kind === PAUSE_MARKER_KIND
        ? "Paused for headroom on claude, 5h window 92 %"
        : kind === LIMIT_MARKER_KIND
          ? "Limit hit on one@example.com"
          : "Released",
  payload: {},
  turnId: null,
  createdAt,
});

const turn = (startedAt: string | null) => ({
  turnId: TurnId.make("turn-1"),
  state: "completed" as const,
  requestedAt: "2026-09-11T09:00:00.000Z",
  startedAt,
  completedAt: null,
  assistantMessageId: null,
});

describe("threadHold", () => {
  it("is null with no held marker", () => {
    expect(threadHold({ activities: [], latestTurn: null })).toBeNull();
    expect(
      threadHold({
        activities: [marker("provider.turn.failed", "2026-09-11T10:00:00Z")],
        latestTurn: null,
      }),
    ).toBeNull();
  });

  it("names the newest held marker while no release or turn start follows it", () => {
    expect(
      threadHold({
        activities: [marker(HOLD_MARKER_KIND, "2026-09-11T10:00:00Z", "h1")],
        latestTurn: turn("2026-09-11T09:30:00Z"),
      }),
    ).toEqual({
      kind: "held",
      markerId: "h1",
      since: "2026-09-11T10:00:00Z",
      summary: "Held for headroom on claude, 5h window 84 %",
    });
  });

  it("is over once a released marker follows the hold", () => {
    expect(
      threadHold({
        activities: [
          marker(HOLD_MARKER_KIND, "2026-09-11T10:00:00Z"),
          marker(RELEASE_MARKER_KIND, "2026-09-11T10:05:00Z"),
        ],
        latestTurn: null,
      }),
    ).toBeNull();
  });

  it("holds again after a release when a newer held marker lands", () => {
    expect(
      threadHold({
        activities: [
          marker(HOLD_MARKER_KIND, "2026-09-11T10:00:00Z", "h1"),
          marker(RELEASE_MARKER_KIND, "2026-09-11T10:05:00Z"),
          marker(HOLD_MARKER_KIND, "2026-09-11T11:00:00Z", "h2"),
        ],
        latestTurn: turn("2026-09-11T10:05:01Z"),
      })?.markerId,
    ).toBe("h2");
  });

  it("is over once a turn started after the hold (a restart forgot it, the user sent again)", () => {
    expect(
      threadHold({
        activities: [marker(HOLD_MARKER_KIND, "2026-09-11T10:00:00Z")],
        latestTurn: turn("2026-09-11T10:20:00Z"),
      }),
    ).toBeNull();
  });

  it("names a paused turn while no resumed row or later turn start follows it (#743)", () => {
    // The paused turn itself started before the row: it does not end the pause.
    expect(
      threadHold({
        activities: [marker(PAUSE_MARKER_KIND, "2026-09-11T10:00:00Z", "p1")],
        latestTurn: turn("2026-09-11T09:30:00Z"),
      }),
    ).toEqual({
      kind: "paused",
      markerId: "p1",
      since: "2026-09-11T10:00:00Z",
      summary: "Paused for headroom on claude, 5h window 92 %",
    });
    expect(
      threadHold({
        activities: [
          marker(PAUSE_MARKER_KIND, "2026-09-11T10:00:00Z"),
          marker(RESUME_MARKER_KIND, "2026-09-11T10:05:00Z"),
        ],
        latestTurn: null,
      }),
    ).toBeNull();
    expect(
      threadHold({
        activities: [marker(PAUSE_MARKER_KIND, "2026-09-11T10:00:00Z")],
        latestTurn: turn("2026-09-11T10:20:00Z"),
      }),
    ).toBeNull();
  });

  it("lets a held start close a pause and a resume close a hold: one state per thread", () => {
    // Paused, then the continuation was held by the gate: the newest row rules.
    expect(
      threadHold({
        activities: [
          marker(PAUSE_MARKER_KIND, "2026-09-11T10:00:00Z", "p1"),
          marker(HOLD_MARKER_KIND, "2026-09-11T10:05:00Z", "h1"),
        ],
        latestTurn: turn("2026-09-11T09:30:00Z"),
      })?.kind,
    ).toBe("held");
    expect(
      threadHold({
        activities: [
          marker(HOLD_MARKER_KIND, "2026-09-11T10:00:00Z", "h1"),
          marker(RESUME_MARKER_KIND, "2026-09-11T10:05:00Z"),
        ],
        latestTurn: null,
      }),
    ).toBeNull();
  });

  it("names a limit stop until the turn resumes on another account or a new turn starts (#270 I)", () => {
    expect(
      threadHold({
        activities: [marker(LIMIT_MARKER_KIND, "2026-09-11T10:00:00Z", "l1")],
        latestTurn: turn("2026-09-11T09:30:00Z"),
      }),
    ).toEqual({
      kind: "limited",
      markerId: "l1",
      since: "2026-09-11T10:00:00Z",
      summary: "Limit hit on one@example.com",
    });
    expect(
      threadHold({
        activities: [
          marker(LIMIT_MARKER_KIND, "2026-09-11T10:00:00Z"),
          marker(LIMIT_RESUME_MARKER_KIND, "2026-09-11T10:05:00Z"),
        ],
        latestTurn: null,
      }),
    ).toBeNull();
    expect(
      threadHold({
        activities: [marker(LIMIT_MARKER_KIND, "2026-09-11T10:00:00Z")],
        latestTurn: turn("2026-09-11T10:20:00Z"),
      }),
    ).toBeNull();
  });

  it("breaks a same-instant tie by row order", () => {
    expect(
      threadHold({
        activities: [
          marker(HOLD_MARKER_KIND, "2026-09-11T10:00:00Z", "h1"),
          marker(RELEASE_MARKER_KIND, "2026-09-11T10:00:00Z", "r1"),
        ],
        latestTurn: null,
      }),
    ).toBeNull();
  });
});
