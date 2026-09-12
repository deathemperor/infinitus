import {
  CommandId,
  ProjectId,
  ProviderInstanceId,
  ThreadId,
  TurnId,
  type OrchestrationReadModel,
  type ThreadTurnUsage,
  type ThreadUsageRollup,
} from "@t3tools/contracts";
import * as NodeServices from "@effect/platform-node/NodeServices";
import { expect, it } from "@effect/vitest";
import * as Effect from "effect/Effect";

import { decideOrchestrationCommand } from "./decider.ts";

const NOW = "2026-01-01T00:00:00.000Z";
const threadId = ThreadId.make("thread-1");

const turn = (id: string, costUsd: number | null): ThreadTurnUsage => ({
  turnId: TurnId.make(id),
  model: "claude-opus-4-7",
  inputTokens: 100,
  outputTokens: 10,
  cachedInputTokens: 80,
  cacheCreationTokens: 5,
  reasoningTokens: null,
  complete: true,
  hasSubagents: false,
  costUsd,
  completedAt: NOW,
});

function makeReadModel(usage?: ThreadUsageRollup): OrchestrationReadModel {
  return {
    snapshotSequence: 0,
    projects: [],
    threads: [
      {
        id: threadId,
        projectId: ProjectId.make("project-1"),
        title: "Thread",
        modelSelection: { instanceId: ProviderInstanceId.make("claude"), model: "opus" },
        runtimeMode: "full-access",
        interactionMode: "default",
        branch: null,
        worktreePath: null,
        pullRequests: [],
        latestTurn: null,
        createdAt: NOW,
        updatedAt: NOW,
        archivedAt: null,
        settledOverride: null,
        settledAt: null,
        deletedAt: null,
        messages: [],
        proposedPlans: [],
        activities: [],
        checkpoints: [],
        session: null,
        ...(usage === undefined ? {} : { usage }),
      },
    ],
    updatedAt: NOW,
  };
}

it.layer(NodeServices.layer)("turn usage decider (#834)", (it) => {
  it.effect("records the turn with the thread's rollup folded", () =>
    Effect.gen(function* () {
      const first = yield* decideOrchestrationCommand({
        command: {
          type: "thread.turn.usage.record",
          commandId: CommandId.make("cmd-usage-1"),
          threadId,
          turnUsage: turn("turn-1", 0.2),
          createdAt: NOW,
        },
        readModel: makeReadModel(),
      });
      expect(Array.isArray(first)).toBe(false);
      const event = first as { type: string; payload: { usage: ThreadUsageRollup } };
      expect(event.type).toBe("thread.turn-usage-recorded");
      expect(event.payload.usage).toMatchObject({
        source: "runtime",
        turns: 1,
        inputTokens: 100,
        costUsd: 0.2,
        models: ["claude-opus-4-7"],
      });

      const second = (yield* decideOrchestrationCommand({
        command: {
          type: "thread.turn.usage.record",
          commandId: CommandId.make("cmd-usage-2"),
          threadId,
          turnUsage: turn("turn-2", null),
          createdAt: NOW,
        },
        readModel: makeReadModel(event.payload.usage),
      })) as { payload: { usage: ThreadUsageRollup } };
      expect(second.payload.usage.turns).toBe(2);
      expect(second.payload.usage.inputTokens).toBe(200);
      expect(second.payload.usage.costUsd).toBe(0.2);
    }),
  );

  it.effect("backfills a transcript rollup once, and not over an existing one", () =>
    Effect.gen(function* () {
      const transcript: ThreadUsageRollup = {
        source: "transcript",
        turns: 3,
        inputTokens: 500,
        outputTokens: 50,
        cachedInputTokens: 400,
        cacheCreationTokens: 20,
        reasoningTokens: 0,
        subagentTurns: 0,
        costUsd: null,
        models: ["claude-opus-4-7"],
        lastTurnAt: NOW,
      };
      const event = (yield* decideOrchestrationCommand({
        command: {
          type: "thread.usage.backfill",
          commandId: CommandId.make("cmd-backfill-1"),
          threadId,
          usage: transcript,
          createdAt: NOW,
        },
        readModel: makeReadModel(),
      })) as { type: string; payload: { usage: ThreadUsageRollup } };
      expect(event.type).toBe("thread.usage-backfilled");
      expect(event.payload.usage).toEqual(transcript);

      const refused = yield* decideOrchestrationCommand({
        command: {
          type: "thread.usage.backfill",
          commandId: CommandId.make("cmd-backfill-2"),
          threadId,
          usage: transcript,
          createdAt: NOW,
        },
        readModel: makeReadModel(event.payload.usage),
      }).pipe(Effect.flip);
      expect(String(refused)).toContain("already has a usage rollup");
    }),
  );

  it.effect("refuses a thread it does not know", () =>
    Effect.gen(function* () {
      const failure = yield* decideOrchestrationCommand({
        command: {
          type: "thread.turn.usage.record",
          commandId: CommandId.make("cmd-usage-missing"),
          threadId: ThreadId.make("thread-missing"),
          turnUsage: turn("turn-1", null),
          createdAt: NOW,
        },
        readModel: makeReadModel(),
      }).pipe(Effect.flip);
      expect(String(failure)).toContain("thread-missing");
    }),
  );
});
