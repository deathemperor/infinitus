import {
  ThreadId,
  TurnId,
  type OrchestrationEvent,
  type ThreadTurnUsage,
} from "@t3tools/contracts";
import { it as effectIt } from "@effect/vitest";
import * as Context from "effect/Context";
import * as DateTime from "effect/DateTime";
import * as Duration from "effect/Duration";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as PubSub from "effect/PubSub";
import * as Stream from "effect/Stream";
import * as TestClock from "effect/testing/TestClock";
import { describe, expect } from "vite-plus/test";

import { OrchestrationEngineService } from "../../orchestration/Services/OrchestrationEngine.ts";
import { InfinitusRunRate } from "../Services/InfinitusRunRate.ts";
import { InfinitusRunRateLive } from "./InfinitusRunRate.ts";
import { RUN_RATE_WINDOW_MS } from "./infinitusRunRate.logic.ts";

const thread = ThreadId.make("thread-1");

/** The test clock starts at the epoch; the harness moves it an hour on so a
    turn can be stamped before "now" without a negative instant. */
const NOW = 3_600_000;
const ago = (ms: number) => DateTime.formatIso(DateTime.makeUnsafe(NOW - ms));

const usage = (overrides: Partial<ThreadTurnUsage> = {}): ThreadTurnUsage => ({
  turnId: TurnId.make("turn-1"),
  model: "claude-opus-5",
  inputTokens: 100,
  outputTokens: 400,
  cachedInputTokens: 0,
  cacheCreationTokens: 0,
  reasoningTokens: null,
  complete: true,
  hasSubagents: false,
  costUsd: 0.1,
  completedAt: ago(0),
  ...overrides,
});

const recorded = (turnUsage: ThreadTurnUsage): OrchestrationEvent =>
  ({
    type: "thread.turn-usage-recorded",
    aggregateKind: "thread",
    aggregateId: thread,
    payload: { threadId: thread, turnUsage, usage: {} },
  }) as never;

const sessionSet = (): OrchestrationEvent =>
  ({
    type: "thread.session-set",
    aggregateKind: "thread",
    aggregateId: thread,
    payload: { threadId: thread },
  }) as never;

const makeHarness = Effect.gen(function* () {
  const domainEvents = yield* PubSub.unbounded<OrchestrationEvent>();
  const context = yield* Layer.build(
    InfinitusRunRateLive.pipe(
      Layer.provide(
        Layer.mock(OrchestrationEngineService)({
          get streamDomainEvents() {
            return Stream.fromPubSub(domainEvents);
          },
        }),
      ),
    ),
  );
  yield* TestClock.adjust(Duration.millis(NOW));
  // The forked stream subscribes on its first step; an event published
  // before that reaches nobody.
  for (let i = 0; i < 20; i += 1) yield* Effect.yieldNow;
  return {
    emit: (event: OrchestrationEvent) => PubSub.publish(domainEvents, event).pipe(Effect.asVoid),
    read: Context.get(context, InfinitusRunRate).read,
  };
});

/** Lets the layer's stream fiber take the published events. */
const settle = <A>(read: Effect.Effect<A>, check: (value: A) => boolean) =>
  Effect.gen(function* () {
    for (let i = 0; i < 500; i += 1) {
      const value = yield* read;
      if (check(value)) return value;
      yield* Effect.yieldNow;
    }
    return yield* read;
  });

describe("InfinitusRunRateLive (#1127)", () => {
  effectIt.effect("sums the turns this server finished inside the window", () =>
    Effect.scoped(
      Effect.gen(function* () {
        const h = yield* makeHarness;
        expect(yield* h.read).toEqual({
          windowMinutes: 5,
          turns: 0,
          outputTokens: 0,
          totalTokens: 0,
        });

        yield* h.emit(recorded(usage({ completedAt: ago(120_000) })));
        yield* h.emit(
          recorded(usage({ turnId: TurnId.make("turn-2"), outputTokens: 600, inputTokens: 200 })),
        );
        const rate = yield* settle(h.read, (value) => value.turns === 2);
        expect(rate.outputTokens).toBe(1_000);
        expect(rate.totalTokens).toBe(1_300);
      }),
    ),
  );

  effectIt.effect("forgets a turn the window has passed, and ignores other events", () =>
    Effect.scoped(
      Effect.gen(function* () {
        const h = yield* makeHarness;
        yield* h.emit(recorded(usage({ completedAt: ago(RUN_RATE_WINDOW_MS + 1_000) })));
        yield* h.emit(sessionSet());
        // Nothing this server can still call live, so nothing to draw.
        for (let i = 0; i < 50; i += 1) yield* Effect.yieldNow;
        expect((yield* h.read).turns).toBe(0);
      }),
    ),
  );

  effectIt.effect("drops a turn out of the window as the clock moves past it", () =>
    Effect.scoped(
      Effect.gen(function* () {
        const h = yield* makeHarness;
        yield* h.emit(recorded(usage()));
        yield* settle(h.read, (value) => value.turns === 1);
        yield* TestClock.adjust(Duration.millis(RUN_RATE_WINDOW_MS + 1));
        expect((yield* h.read).turns).toBe(0);
      }),
    ),
  );
});
