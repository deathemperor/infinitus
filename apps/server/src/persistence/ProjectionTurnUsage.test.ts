import { ThreadId, TurnId, type ThreadTurnUsage } from "@t3tools/contracts";
import { assert, it } from "@effect/vitest";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";

import { SqlitePersistenceMemory } from "./Layers/Sqlite.ts";
import { ProjectionTurnUsageRepository, layer as repositoryLayer } from "./ProjectionTurnUsage.ts";

const layer = it.layer(repositoryLayer.pipe(Layer.provideMerge(SqlitePersistenceMemory)));

const turn = (turnId: string, completedAt: string, outputTokens: number): ThreadTurnUsage => ({
  turnId: TurnId.make(turnId),
  model: "claude-opus-4-7",
  inputTokens: 1000,
  outputTokens,
  cachedInputTokens: 900,
  cacheCreationTokens: 10,
  reasoningTokens: 5,
  complete: true,
  hasSubagents: false,
  costUsd: null,
  completedAt,
});

layer("ProjectionTurnUsageRepository.listCompletedSince (#1127)", (it) => {
  it.effect("reads every thread's turns from the instant on, oldest first", () =>
    Effect.gen(function* () {
      const repository = yield* ProjectionTurnUsageRepository;
      const one = ThreadId.make("thread-live-one");
      const two = ThreadId.make("thread-live-two");
      yield* repository.upsert({
        threadId: one,
        turnUsage: turn("turn-old", "2026-09-14T11:50:00.000Z", 9000),
      });
      yield* repository.upsert({
        threadId: one,
        turnUsage: turn("turn-in", "2026-09-14T11:57:00.000Z", 3000),
      });
      yield* repository.upsert({
        threadId: two,
        turnUsage: turn("turn-newest", "2026-09-14T11:59:00.000Z", 1500),
      });

      const rows = yield* repository.listCompletedSince({ since: "2026-09-14T11:55:00.000Z" });

      assert.deepEqual(
        rows.map((row) => [row.threadId, row.turnUsage.turnId, row.turnUsage.outputTokens]),
        [
          [one, "turn-in", 3000],
          [two, "turn-newest", 1500],
        ],
      );
    }),
  );

  it.effect("is empty when nothing completed since", () =>
    Effect.gen(function* () {
      const repository = yield* ProjectionTurnUsageRepository;
      yield* repository.upsert({
        threadId: ThreadId.make("thread-live-quiet"),
        turnUsage: turn("turn-old", "2026-09-14T10:00:00.000Z", 100),
      });

      const rows = yield* repository.listCompletedSince({ since: "2026-09-15T00:00:00.000Z" });

      assert.deepEqual(rows, []);
    }),
  );
});
