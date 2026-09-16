import { TurnId, type OrchestrationThread } from "@infinitus/contracts";
import { turnFooter } from "@infinitus/client-runtime/turnFooter";
import { act, StrictMode } from "react";
import { create, type ReactTestRenderer } from "react-test-renderer";
import { afterEach, beforeEach, describe, expect, it, vi } from "vite-plus/test";

import { useTurnFooters, type TurnFooters } from "./useTurnFooters";

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

type Thread = Pick<OrchestrationThread, "messages" | "activities" | "latestTurn" | "session">;

const thread = (input: {
  messages?: ReadonlyArray<ReturnType<typeof message>>;
  activities?: ReadonlyArray<ReturnType<typeof activity>>;
  latestTurn?: Record<string, unknown> | null;
}): Thread =>
  ({
    messages: input.messages ?? [],
    activities: input.activities ?? [],
    latestTurn: input.latestTurn ?? null,
    session: { status: "running" },
  }) as unknown as Thread;

const MESSAGES = [
  message("u1", "user", turn1, "2026-09-12T12:00:00Z"),
  message("a1", "assistant", turn1, "2026-09-12T12:00:05Z", "2026-09-12T12:00:49Z"),
  message("u2", "user", turn2, "2026-09-12T12:05:00Z"),
  message("a2", "assistant", turn2, "2026-09-12T12:05:01Z", "2026-09-12T12:05:20Z"),
];

/** turn 2 is running: the latest turn has no completion. */
const RUNNING_LATEST = {
  turnId: turn2,
  state: "running",
  startedAt: "2026-09-12T12:05:00Z",
  completedAt: null,
};

const seen: TurnFooters[] = [];
function Probe({ thread: t }: { readonly thread: Thread }) {
  seen.push(useTurnFooters(t));
  return null;
}

let renderer: ReactTestRenderer | undefined;

beforeEach(() => {
  vi.stubGlobal("IS_REACT_ACT_ENVIRONMENT", true);
  seen.length = 0;
});

afterEach(async () => {
  await act(() => renderer?.unmount());
  renderer = undefined;
  vi.unstubAllGlobals();
});

async function render(t: Thread) {
  await act(async () => {
    if (renderer === undefined) {
      renderer = create(
        <StrictMode>
          <Probe thread={t} />
        </StrictMode>,
      );
    } else {
      renderer.update(
        <StrictMode>
          <Probe thread={t} />
        </StrictMode>,
      );
    }
  });
  return seen.at(-1)!;
}

describe("useTurnFooters (#952, one pass since #1279)", () => {
  it("answers what turnFooter answers per completed turn", async () => {
    const t = thread({ messages: MESSAGES, latestTurn: RUNNING_LATEST });
    const footers = await render(t);
    expect([...footers.keys()]).toEqual([turn1]);
    expect(footers.get(turn1)).toEqual(turnFooter(t as OrchestrationThread, turn1));
  });

  it("keeps the map's identity across a streaming activity delta", async () => {
    const base = thread({ messages: MESSAGES, latestTurn: RUNNING_LATEST });
    const first = await render(base);
    // The running turn's next tick: one more activity on turn 2, nothing on turn 1.
    const ticked = thread({
      messages: MESSAGES,
      latestTurn: RUNNING_LATEST,
      activities: [activity("x1", "item.updated", turn2, { text: "…" })],
    });
    const second = await render(ticked);
    expect(second).toBe(first);
  });

  it("rebuilds the map when a footer's entry changes", async () => {
    const base = thread({ messages: MESSAGES, latestTurn: RUNNING_LATEST });
    const first = await render(base);
    const withShell = thread({
      messages: MESSAGES,
      latestTurn: RUNNING_LATEST,
      activities: [
        activity("s-1", "task.started", turn1, { taskId: "sh-1", taskType: "local_bash" }),
        activity("b-1", "task.updated", turn1, { taskId: "sh-1", isBackgrounded: true }),
      ],
    });
    const second = await render(withShell);
    expect(second).not.toBe(first);
    expect(second.get(turn1)?.runningShells).toBe(1);
  });
});
