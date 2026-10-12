import type {
  OrchestrationV2DomainEvent,
  OrchestrationV2Run,
  OrchestrationV2TurnItem,
} from "@infinitus/contracts";
import { RunId } from "@infinitus/contracts";
import { describe, expect, it } from "vite-plus/test";

import { toolBoundaryOf, toolBoundarySteerCandidate } from "./infinitusToolBoundarySteer.logic.ts";

const run = (
  id: string,
  status: OrchestrationV2Run["status"],
  extra: Partial<OrchestrationV2Run> = {},
): OrchestrationV2Run =>
  ({ id: RunId.make(id), ordinal: Number(id.replace(/\D/g, "")), status, ...extra }) as never;

const item = (
  type: OrchestrationV2TurnItem["type"],
  status: OrchestrationV2TurnItem["status"],
  runId: string | null = "run-1",
): OrchestrationV2TurnItem =>
  ({ id: `item-${type}-${status}`, type, status, runId, threadId: "thread-1" }) as never;

const event = (payload: OrchestrationV2TurnItem): OrchestrationV2DomainEvent =>
  ({ type: "turn-item.updated", payload }) as never;

describe("toolBoundaryOf (#1318)", () => {
  it("a finished or failed tool call of a run is a boundary", () => {
    expect(toolBoundaryOf(event(item("command_execution", "completed")))).not.toBeNull();
    expect(toolBoundaryOf(event(item("file_change", "failed")))).not.toBeNull();
    expect(toolBoundaryOf(event(item("subagent", "completed")))).not.toBeNull();
    expect(toolBoundaryOf(event(item("dynamic_tool", "completed")))).not.toBeNull();
  });

  it("a running tool, a message, a plan, or an item with no run is not", () => {
    expect(toolBoundaryOf(event(item("command_execution", "running")))).toBeNull();
    expect(toolBoundaryOf(event(item("assistant_message", "completed")))).toBeNull();
    expect(toolBoundaryOf(event(item("proposed_plan", "completed")))).toBeNull();
    expect(toolBoundaryOf(event(item("command_execution", "completed", null)))).toBeNull();
    expect(toolBoundaryOf({ type: "run.updated", payload: {} } as never)).toBeNull();
  });
});

describe("toolBoundarySteerCandidate (#1318)", () => {
  const target = RunId.make("run-1");

  it("picks the first tool_boundary row in queue order, past idle rows ahead of it", () => {
    const runs = [
      run("run-1", "running"),
      run("run-2", "queued", { queuePosition: 1 }),
      run("run-3", "queued", { queuePosition: 3, sendAt: "tool_boundary" }),
      run("run-4", "queued", { queuePosition: 2, sendAt: "tool_boundary" }),
    ];
    expect(toolBoundarySteerCandidate(runs, target)).toBe("run-4");
  });

  it("sends nothing while the queue is held, or when no steer row waits", () => {
    expect(
      toolBoundarySteerCandidate(
        [run("run-1", "running"), run("run-2", "queued", { sendAt: "tool_boundary", queueHeld: true })],
        target,
      ),
    ).toBeUndefined();
    expect(
      toolBoundarySteerCandidate([run("run-1", "running"), run("run-2", "queued")], target),
    ).toBeUndefined();
  });

  it("ignores a boundary of a turn that is not running: stale, or the next turn's", () => {
    const queued = run("run-2", "queued", { sendAt: "tool_boundary" });
    expect(toolBoundarySteerCandidate([run("run-1", "completed"), queued], target)).toBeUndefined();
    expect(toolBoundarySteerCandidate([queued], target)).toBeUndefined();
    expect(toolBoundarySteerCandidate([run("run-1", "waiting"), queued], target)).toBe("run-2");
  });
});
