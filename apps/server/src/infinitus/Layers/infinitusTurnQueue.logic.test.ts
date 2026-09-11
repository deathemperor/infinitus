import { MessageId, QueueId, ThreadId } from "@t3tools/contracts";
import { describe, expect, it } from "vite-plus/test";

import {
  orderedQueuedTurns,
  queueDrainVerdict,
  releasedThreads,
  type QueueDrainThread,
} from "./infinitusTurnQueue.logic.ts";

const threadId = ThreadId.make("thread-1");
const row = (queueId: string, orderKey: string, createdAt = "2026-01-01T00:00:00.000Z") => ({
  queueId: QueueId.make(queueId),
  messageId: MessageId.make(`${queueId}-message`),
  text: `queued ${queueId}`,
  attachments: [],
  orderKey,
  createdAt,
  updatedAt: createdAt,
});
const thread = (input: Partial<QueueDrainThread> = {}): QueueDrainThread => ({
  id: threadId,
  archivedAt: null,
  session: null,
  queuedTurns: [row("q1", "m")],
  ...input,
});
const open = { held: false, paused: false, inFlight: false, pendingStart: false };

describe("queueDrainVerdict (#806)", () => {
  it("sends the first row of an idle thread, by key then by age", () => {
    const verdict = queueDrainVerdict(
      thread({
        queuedTurns: [
          row("late", "t"),
          row("early-b", "f", "2026-01-01T00:01:00.000Z"),
          row("early-a", "f", "2026-01-01T00:00:00.000Z"),
        ],
      }),
      open,
    );
    expect(verdict).toEqual({ kind: "send", row: row("early-a", "f") });
    expect(orderedQueuedTurns(thread().queuedTurns).map((entry) => entry.queueId)).toEqual(["q1"]);
  });

  it("waits while the thread is busy, starting, pending a start, or in error", () => {
    const session = (status: string, activeTurnId: string | null = null) => ({
      status,
      activeTurnId,
    });
    expect(queueDrainVerdict(thread({ session: session("running", "turn-1") }), open)).toEqual({
      kind: "wait",
      reason: "busy",
    });
    expect(queueDrainVerdict(thread({ session: session("starting") }), open)).toEqual({
      kind: "wait",
      reason: "busy",
    });
    expect(queueDrainVerdict(thread({ session: session("error") }), open)).toEqual({
      kind: "wait",
      reason: "error",
    });
    expect(
      queueDrainVerdict(thread({ session: session("ready") }), { ...open, pendingStart: true }),
    ).toEqual({ kind: "wait", reason: "pending-start" });
    for (const status of ["idle", "ready", "stopped", "interrupted"]) {
      expect(queueDrainVerdict(thread({ session: session(status) }), open).kind).toBe("send");
    }
  });

  it("waits on the fork's gates and on its own send in flight, in that order", () => {
    expect(queueDrainVerdict(thread(), { ...open, inFlight: true })).toEqual({
      kind: "wait",
      reason: "in-flight",
    });
    expect(queueDrainVerdict(thread(), { ...open, held: true })).toEqual({
      kind: "wait",
      reason: "held",
    });
    expect(queueDrainVerdict(thread(), { ...open, paused: true })).toEqual({
      kind: "wait",
      reason: "paused",
    });
  });

  it("never sends into an archived thread or an empty queue", () => {
    expect(queueDrainVerdict(thread({ archivedAt: "2026-01-01T00:00:00.000Z" }), open)).toEqual({
      kind: "wait",
      reason: "archived",
    });
    expect(queueDrainVerdict(thread({ queuedTurns: [] }), open)).toEqual({
      kind: "wait",
      reason: "empty",
    });
    expect(queueDrainVerdict(thread({ queuedTurns: undefined }), open).kind).toBe("wait");
  });
});

describe("releasedThreads", () => {
  it("names the threads a hold or pause let go", () => {
    const a = ThreadId.make("a");
    const b = ThreadId.make("b");
    expect(releasedThreads(new Set([a, b]), new Set([b]))).toEqual([a]);
    expect(releasedThreads(new Set([a]), new Set([a, b]))).toEqual([]);
  });
});
