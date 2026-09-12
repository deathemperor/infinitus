import { TurnId, type OrchestrationThread } from "@t3tools/contracts";
import { describe, expect, it } from "vite-plus/test";

import { turnFooter, turnFooterLabel, type TurnFooter } from "./turnFooter.ts";

const turn1 = TurnId.make("turn-1");
const turn2 = TurnId.make("turn-2");

const message = (
  id: string,
  role: "user" | "assistant",
  turnId: TurnId,
  createdAt: string,
  updatedAt = createdAt,
) => ({ id, role, turnId, createdAt, updatedAt, streaming: false });

const activity = (
  id: string,
  kind: string,
  turnId: TurnId | null,
  payload: Record<string, unknown>,
) => ({
  id,
  kind,
  turnId,
  payload,
  tone: "info",
  summary: kind,
  createdAt: "2026-09-12T12:00:00Z",
});

const thread = (input: {
  messages?: ReadonlyArray<ReturnType<typeof message>>;
  activities?: ReadonlyArray<ReturnType<typeof activity>>;
  latestTurn?: Record<string, unknown> | null;
  session?: { status: string } | null;
}): OrchestrationThread =>
  ({
    messages: input.messages ?? [],
    activities: input.activities ?? [],
    latestTurn: input.latestTurn ?? null,
    session: input.session === undefined ? { status: "idle" } : input.session,
  }) as unknown as OrchestrationThread;

const shellStarted = (taskId: string, turnId: TurnId) =>
  activity(`s-${taskId}`, "task.started", turnId, { taskId, taskType: "local_bash" });
const backgrounded = (taskId: string, turnId: TurnId | null) =>
  activity(`b-${taskId}`, "task.updated", turnId, { taskId, isBackgrounded: true });

describe("turnFooter (#952)", () => {
  it("times the latest turn by its start and completion, older turns by their messages", () => {
    const messages = [
      message("u1", "user", turn1, "2026-09-12T12:00:00Z"),
      message("a1", "assistant", turn1, "2026-09-12T12:00:05Z", "2026-09-12T12:00:49Z"),
      message("u2", "user", turn2, "2026-09-12T12:05:00Z"),
      message("a2", "assistant", turn2, "2026-09-12T12:05:01Z", "2026-09-12T12:05:20Z"),
    ];
    const latestTurn = {
      turnId: turn2,
      state: "completed",
      requestedAt: "2026-09-12T12:05:00Z",
      startedAt: "2026-09-12T12:05:02Z",
      completedAt: "2026-09-12T12:05:21Z",
    };
    const t = thread({ messages, latestTurn });
    expect(turnFooter(t, turn2)).toEqual({
      durationMs: 19_000,
      completedAt: "2026-09-12T12:05:21Z",
      runningShells: 0,
      runningAgents: 0,
    });
    expect(turnFooter(t, turn1)).toEqual({
      durationMs: 49_000,
      completedAt: "2026-09-12T12:00:49Z",
      runningShells: 0,
      runningAgents: 0,
    });
  });

  it("is null while the turn runs or when the thread has no such turn", () => {
    const running = thread({
      messages: [message("u1", "user", turn1, "2026-09-12T12:00:00Z")],
      latestTurn: {
        turnId: turn1,
        state: "running",
        requestedAt: "2026-09-12T12:00:00Z",
        startedAt: "2026-09-12T12:00:01Z",
        completedAt: null,
      },
    });
    expect(turnFooter(running, turn1)).toBeNull();
    expect(turnFooter(thread({}), turn2)).toBeNull();
  });

  it("counts a backgrounded shell of the turn until it ends, wherever the end lands", () => {
    const messages = [
      message("u1", "user", turn1, "2026-09-12T12:00:00Z"),
      message("a1", "assistant", turn1, "2026-09-12T12:00:01Z", "2026-09-12T12:00:30Z"),
    ];
    const openActivities = [
      shellStarted("t-1", turn1),
      backgrounded("t-1", turn1),
      shellStarted("t-2", turn1),
      backgrounded("t-2", turn1),
      activity("s-agent", "task.started", turn1, { taskId: "t-3", taskType: "local_agent" }),
      backgrounded("t-3", turn1),
      // A foreground shell that never went to the background.
      shellStarted("t-4", turn1),
    ];
    const open = thread({ messages, activities: openActivities });
    expect(turnFooter(open, turn1)?.runningShells).toBe(2);
    // The agent is not a shell; it is counted on its own (#974).
    expect(turnFooter(open, turn1)?.runningAgents).toBe(1);

    // The end arrives under the next turn, or no turn at all.
    const ended = thread({
      messages,
      activities: [
        ...openActivities,
        activity("e-1", "task.completed", turn2, { taskId: "t-1", status: "completed" }),
        activity("e-2", "task.updated", null, { taskId: "t-2", endedAt: "2026-09-12T12:01:00Z" }),
      ],
    });
    expect(turnFooter(ended, turn1)?.runningShells).toBe(0);

    // A killed shell is not running either.
    const killed = thread({
      messages,
      activities: [
        ...openActivities,
        activity("k-1", "task.updated", null, { taskId: "t-1", status: "cancelled" }),
      ],
    });
    expect(turnFooter(killed, turn1)?.runningShells).toBe(1);

    // The session that owned the shells is gone.
    const gone = (session: { status: string } | null) =>
      thread({ messages, activities: openActivities, session });
    expect(turnFooter(gone({ status: "stopped" }), turn1)?.runningShells).toBe(0);
    expect(turnFooter(gone(null), turn1)?.runningShells).toBe(0);
  });

  it("counts the turn's background agents until they end (#974)", () => {
    const messages = [
      message("u1", "user", turn1, "2026-09-12T12:00:00Z"),
      message("a1", "assistant", turn1, "2026-09-12T12:00:01Z", "2026-09-12T12:00:30Z"),
    ];
    const agent = (id: string, payload: Record<string, unknown>) =>
      activity(`s-${id}`, "task.started", turn1, {
        taskId: id,
        taskType: "local_agent",
        agentKind: "agent",
        ...payload,
      });
    const openActivities = [
      // Registered in the background from the start.
      agent("a-1", { isBackgrounded: true }),
      // Moved to the background later.
      agent("a-2", {}),
      backgrounded("a-2", turn1),
      // A foreground agent finished inside the turn.
      agent("a-3", {}),
      // A monitor is never counted, backgrounded or not.
      activity("s-m", "task.started", turn1, {
        taskId: "m-1",
        taskType: "local_monitor",
        agentKind: "background",
        isBackgrounded: true,
      }),
      // A backgrounded shell is a shell.
      shellStarted("t-1", turn1),
      backgrounded("t-1", turn1),
    ];
    const open = thread({ messages, activities: openActivities });
    expect(turnFooter(open, turn1)).toMatchObject({ runningShells: 1, runningAgents: 2 });

    // An unstamped row (older activity) is classified from its task type.
    const legacy = thread({
      messages,
      activities: [
        activity("s-l", "task.started", turn1, {
          taskId: "l-1",
          taskType: "local_agent",
          isBackgrounded: true,
        }),
      ],
    });
    expect(turnFooter(legacy, turn1)?.runningAgents).toBe(1);

    const ended = thread({
      messages,
      activities: [
        ...openActivities,
        activity("e-1", "task.completed", null, { taskId: "a-1", status: "completed" }),
        activity("e-2", "task.updated", null, { taskId: "a-2", status: "failed" }),
      ],
    });
    expect(turnFooter(ended, turn1)?.runningAgents).toBe(0);

    // The session that ran the agents is gone: its exit row said so.
    const gone = thread({ messages, activities: openActivities, session: { status: "error" } });
    expect(turnFooter(gone, turn1)?.runningAgents).toBe(0);
  });

  it("words the label", () => {
    const footer = (parts: Partial<TurnFooter>): TurnFooter => ({
      durationMs: 49_000,
      completedAt: "x",
      runningShells: 0,
      runningAgents: 0,
      ...parts,
    });
    expect(turnFooterLabel(footer({}), "12:59 PM")).toBe("Done in 49s · 12:59 PM");
    expect(turnFooterLabel(footer({ durationMs: 125_000, runningShells: 1 }), "12:59 PM")).toBe(
      "Done in 2m 5s · 12:59 PM · 1 shell still running",
    );
    expect(turnFooterLabel(footer({ durationMs: null, runningShells: 2 }), "12:59 PM")).toBe(
      "Done · 12:59 PM · 2 shells still running",
    );
    expect(turnFooterLabel(footer({ runningAgents: 1 }), "12:59 PM")).toBe(
      "Done in 49s · 12:59 PM · 1 agent still running",
    );
    expect(turnFooterLabel(footer({ runningShells: 1, runningAgents: 3 }), "12:59 PM")).toBe(
      "Done in 49s · 12:59 PM · 1 shell still running · 3 agents still running",
    );
  });
});
