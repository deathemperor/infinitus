import { ThreadId, type OrchestrationCommand, type OrchestrationEvent } from "@t3tools/contracts";
import { it as effectIt } from "@effect/vitest";
import * as Crypto from "effect/Crypto";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as PubSub from "effect/PubSub";
import * as Ref from "effect/Ref";
import * as Stream from "effect/Stream";
import { describe, expect } from "vite-plus/test";

import {
  ProjectionTurnUsageRepository,
  type ThreadUsageBackfillCandidate,
} from "../../persistence/ProjectionTurnUsage.ts";
import { UsageService, type SessionUsage } from "../../usage/UsageService.ts";
import { OrchestrationEngineService } from "../Services/OrchestrationEngine.ts";
import { ThreadUsageBackfillLive } from "./ThreadUsageBackfill.ts";

const legacy = ThreadId.make("thread-legacy");
const recent = ThreadId.make("thread-recent");
const silent = ThreadId.make("thread-silent");
const imported = ThreadId.make("thread-imported");

const candidate = (
  threadId: ThreadId,
  providerSessionId: string,
  overrides: Partial<ThreadUsageBackfillCandidate> = {},
): ThreadUsageBackfillCandidate => ({
  threadId,
  providerSessionId,
  turns: 4,
  lastTurnAt: "2020-01-01T00:00:00.000Z",
  ...overrides,
});

const session: SessionUsage = {
  totals: {
    uncachedInputTokens: 10,
    cachedInputTokens: 90,
    cacheCreationTokens: 5,
    outputTokens: 20,
    reasoningTokens: 0,
  },
  costUsd: 0.05,
  models: ["claude-opus-4-7"],
  lastAt: "2020-01-01T00:00:00.000Z",
};

let uuidCounter = 0;
const testCrypto = Crypto.make({
  randomBytes: (size) => {
    uuidCounter += 1;
    return new Uint8Array(size).fill(uuidCounter % 256);
  },
  digest: (_algorithm, data) => Effect.succeed(data),
});

const makeHarness = (
  candidates: ReadonlyArray<ThreadUsageBackfillCandidate>,
  sessions: ReadonlyMap<string, SessionUsage>,
) =>
  Effect.gen(function* () {
    const domainEvents = yield* PubSub.unbounded<OrchestrationEvent>();
    const rows = yield* Ref.make(candidates);
    const dispatched = yield* Ref.make<ReadonlyArray<OrchestrationCommand>>([]);
    const reads = yield* Ref.make<ReadonlyArray<ReadonlyArray<string>>>([]);

    const layer = ThreadUsageBackfillLive.pipe(
      Layer.provide(
        Layer.mergeAll(
          Layer.mock(OrchestrationEngineService)({
            dispatch: (command) =>
              Ref.update(dispatched, (previous) => [...previous, command]).pipe(
                Effect.as({ sequence: 1 }),
              ),
            get streamDomainEvents() {
              return Stream.fromPubSub(domainEvents);
            },
          }),
          Layer.mock(ProjectionTurnUsageRepository)({
            listBackfillCandidates: ({ threadId, limit }) =>
              Ref.get(rows).pipe(
                Effect.map((list) =>
                  list
                    .filter((row) => threadId === undefined || row.threadId === threadId)
                    .slice(0, limit),
                ),
              ),
          }),
          Layer.mock(UsageService)({
            readSessionUsage: ({ sessionIds }) =>
              Ref.update(reads, (previous) => [...previous, sessionIds]).pipe(
                Effect.as(
                  new Map(
                    sessionIds.flatMap((id) => {
                      const found = sessions.get(id);
                      return found === undefined ? [] : [[id, found] as const];
                    }),
                  ),
                ),
              ),
          }),
          Layer.succeed(Crypto.Crypto, testCrypto),
        ),
      ),
    );
    yield* Layer.build(layer);
    for (let i = 0; i < 20; i += 1) yield* Effect.yieldNow;

    return {
      emit: (value: OrchestrationEvent) => PubSub.publish(domainEvents, value).pipe(Effect.asVoid),
      setRows: (list: ReadonlyArray<ThreadUsageBackfillCandidate>) => Ref.set(rows, list),
      backfills: Ref.get(dispatched).pipe(
        Effect.map((commands) =>
          commands.flatMap((command) =>
            command.type === "thread.usage.backfill"
              ? [{ threadId: command.threadId, usage: command.usage }]
              : [],
          ),
        ),
      ),
      reads: Ref.get(reads),
    };
  });

const settle = <A>(read: Effect.Effect<A>, check: (value: A) => boolean) =>
  Effect.gen(function* () {
    for (let i = 0; i < 2_000; i += 1) {
      const value = yield* read;
      if (check(value)) return value;
      yield* Effect.yieldNow;
    }
    return yield* read;
  });

describe("ThreadUsageBackfillLive (#834)", () => {
  // Live: `bootAt` is the real clock, which the fixture dates straddle.
  effectIt.live(
    "the boot sweep estimates legacy threads once, skipping post-boot turns and silent sessions",
    () =>
      Effect.scoped(
        Effect.gen(function* () {
          const h = yield* makeHarness(
            [
              candidate(legacy, "session-legacy"),
              candidate(recent, "session-recent", { lastTurnAt: "2999-01-01T00:00:00.000Z" }),
              candidate(silent, "session-silent"),
            ],
            new Map([
              ["session-legacy", session],
              ["session-recent", session],
            ]),
          );
          yield* settle(h.backfills, (list) => list.length === 1);
          const [only] = yield* h.backfills;
          expect(only?.threadId).toBe(legacy);
          expect(only?.usage).toEqual({
            source: "transcript",
            turns: 4,
            inputTokens: 105,
            outputTokens: 20,
            cachedInputTokens: 90,
            cacheCreationTokens: 5,
            reasoningTokens: 0,
            subagentTurns: 0,
            costUsd: 0.05,
            models: ["claude-opus-4-7"],
            lastTurnAt: "2020-01-01T00:00:00.000Z",
          });
          // One read for the sweep, naming only the legacy sessions.
          expect(yield* h.reads).toEqual([["session-legacy", "session-silent"]]);

          // The silent one going idle again is not re-read; a thread already
          // estimated is not either.
          yield* h.emit({
            type: "thread.session-set",
            aggregateKind: "thread",
            aggregateId: silent,
            payload: { threadId: silent, session: { activeTurnId: null } },
          } as never);
          yield* h.emit({
            type: "thread.session-set",
            aggregateKind: "thread",
            aggregateId: legacy,
            payload: { threadId: legacy, session: { activeTurnId: null } },
          } as never);
          for (let i = 0; i < 50; i += 1) yield* Effect.yieldNow;
          expect((yield* h.reads).length).toBe(1);
          expect((yield* h.backfills).length).toBe(1);
        }),
      ),
  );

  effectIt.effect("a history import re-checks that thread", () =>
    Effect.scoped(
      Effect.gen(function* () {
        const h = yield* makeHarness([], new Map([["session-imported", session]]));
        yield* h.setRows([candidate(imported, "session-imported", { turns: 0, lastTurnAt: null })]);
        yield* h.emit({
          type: "thread.created",
          aggregateKind: "thread",
          aggregateId: imported,
          metadata: { historyImport: true },
          payload: { threadId: imported },
        } as never);
        yield* settle(h.backfills, (list) => list.length === 1);
        expect((yield* h.backfills)[0]?.usage.turns).toBe(0);
        expect(yield* h.reads).toEqual([["session-imported"]]);
      }),
    ),
  );
});
