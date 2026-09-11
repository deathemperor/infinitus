import {
  DEFAULT_PROVIDER_INTERACTION_MODE,
  MessageId,
  QueueId,
  ThreadId,
  TurnId,
  type OrchestrationCommand,
  type OrchestrationEvent,
  type OrchestrationQueuedTurn,
  type OrchestrationThreadShell,
} from "@t3tools/contracts";
import type { InfinitusHeldThread } from "@t3tools/contracts/infinitus";
import { it as effectIt } from "@effect/vitest";
import * as Crypto from "effect/Crypto";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";
import * as PubSub from "effect/PubSub";
import * as Queue from "effect/Queue";
import * as Ref from "effect/Ref";
import * as Stream from "effect/Stream";
import { describe, expect } from "vite-plus/test";

import { OrchestrationEngineService } from "../../orchestration/Services/OrchestrationEngine.ts";
import { ProjectionSnapshotQuery } from "../../orchestration/Services/ProjectionSnapshotQuery.ts";
import { InfinitusSessionHold } from "../Services/InfinitusSessionHold.ts";
import { InfinitusSessionInterrupt } from "../Services/InfinitusSessionInterrupt.ts";
import { InfinitusTurnQueueLive } from "./InfinitusTurnQueue.ts";

const one = ThreadId.make("thread-1");
const two = ThreadId.make("thread-2");
const now = "2026-09-12T10:00:00.000Z";

const row = (queueId: string, orderKey: string): OrchestrationQueuedTurn => ({
  queueId: QueueId.make(queueId),
  messageId: MessageId.make(`${queueId}-message`),
  text: `queued ${queueId}`,
  attachments: [],
  orderKey,
  createdAt: now,
  updatedAt: now,
});

const shellFor = (
  threadId: ThreadId,
  overrides: Partial<OrchestrationThreadShell> = {},
): OrchestrationThreadShell =>
  ({
    id: threadId,
    archivedAt: null,
    pinnedAt: null,
    runtimeMode: "full-access",
    interactionMode: DEFAULT_PROVIDER_INTERACTION_MODE,
    session: null,
    latestTurn: null,
    latestUserMessageAt: null,
    queuedTurns: [row("q1", "m"), row("q2", "t")],
    ...overrides,
  }) as unknown as OrchestrationThreadShell;

const running = (threadId: ThreadId) =>
  shellFor(threadId, {
    session: { activeTurnId: TurnId.make("turn-1"), status: "running" } as never,
  });
const idle = (threadId: ThreadId, overrides: Partial<OrchestrationThreadShell> = {}) =>
  shellFor(threadId, { session: { activeTurnId: null, status: "ready" } as never, ...overrides });

const domainEvent = (type: OrchestrationEvent["type"], threadId: ThreadId): OrchestrationEvent =>
  ({ type, aggregateKind: "thread", aggregateId: threadId, payload: { threadId } }) as never;

const testCrypto = Crypto.make({
  randomBytes: (size) => new Uint8Array(size).fill(1),
  digest: (_algorithm, data) => Effect.succeed(data),
});

const makeHarness = (initial: ReadonlyArray<OrchestrationThreadShell>) =>
  Effect.gen(function* () {
    const domainEvents = yield* PubSub.unbounded<OrchestrationEvent>();
    const held = yield* Queue.unbounded<ReadonlyArray<InfinitusHeldThread>>();
    const paused = yield* Queue.unbounded<ReadonlyArray<ThreadId>>();
    const shells = yield* Ref.make<ReadonlyMap<ThreadId, OrchestrationThreadShell>>(
      new Map(initial.map((shell) => [shell.id, shell])),
    );
    const dispatched = yield* Ref.make<ReadonlyArray<OrchestrationCommand>>([]);

    const layer = InfinitusTurnQueueLive.pipe(
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
          Layer.mock(ProjectionSnapshotQuery)({
            getThreadShellById: (threadId) =>
              Ref.get(shells).pipe(Effect.map((map) => Option.fromNullishOr(map.get(threadId)))),
            getShellSnapshot: () =>
              Ref.get(shells).pipe(Effect.map((map) => ({ threads: [...map.values()] }) as never)),
          }),
          Layer.mock(InfinitusSessionHold)({
            get held() {
              return Stream.fromQueue(held);
            },
          }),
          Layer.mock(InfinitusSessionInterrupt)({
            get pausedThreads() {
              return Stream.fromQueue(paused);
            },
          }),
          Layer.succeed(Crypto.Crypto, testCrypto),
        ),
      ),
    );
    yield* Layer.build(layer);
    // The forked streams subscribe on their first step; an event published
    // before that reaches nobody.
    for (let i = 0; i < 20; i += 1) yield* Effect.yieldNow;

    return {
      emit: (event: OrchestrationEvent) => PubSub.publish(domainEvents, event).pipe(Effect.asVoid),
      setHeld: (threadIds: ReadonlyArray<ThreadId>) =>
        Queue.offer(
          held,
          threadIds.map((threadId) => ({ threadId, since: now, summary: "held" })),
        ).pipe(Effect.asVoid),
      setPaused: (threadIds: ReadonlyArray<ThreadId>) =>
        Queue.offer(paused, threadIds).pipe(Effect.asVoid),
      setShell: (shell: OrchestrationThreadShell) =>
        Ref.update(shells, (map) => new Map([...map, [shell.id, shell]])),
      starts: Ref.get(dispatched).pipe(
        Effect.map((commands) =>
          commands.flatMap((command) =>
            command.type === "thread.turn.start"
              ? [
                  {
                    threadId: command.threadId,
                    queuedFrom: command.queuedFrom,
                    text: command.message.text,
                  },
                ]
              : [],
          ),
        ),
      ),
    };
  });

/** Lets the layer's fibers run until `check` holds. */
const settle = <A>(read: Effect.Effect<A>, check: (value: A) => boolean) =>
  Effect.gen(function* () {
    for (let i = 0; i < 2_000; i += 1) {
      const value = yield* read;
      if (check(value)) return value;
      yield* Effect.yieldNow;
    }
    return yield* read;
  });

const nothingYet = <A>(read: Effect.Effect<ReadonlyArray<A>>) =>
  Effect.gen(function* () {
    for (let i = 0; i < 50; i += 1) yield* Effect.yieldNow;
    expect(yield* read).toEqual([]);
  });

describe("InfinitusTurnQueueLive (#806)", () => {
  effectIt.effect("sends the first row once the session is idle, one row per settle", () =>
    Effect.scoped(
      Effect.gen(function* () {
        const h = yield* makeHarness([running(one)]);
        yield* h.emit(domainEvent("thread.session-set", one));
        yield* nothingYet(h.starts);

        yield* h.setShell(idle(one));
        yield* h.emit(domainEvent("thread.session-set", one));
        yield* settle(h.starts, (list) => list.length === 1);
        expect(yield* h.starts).toEqual([{ threadId: one, queuedFrom: "q1", text: "queued q1" }]);

        // The projection removed the row and the turn is running: the next
        // row waits for the session to settle again.
        yield* h.setShell(shellFor(one, { ...running(one), queuedTurns: [row("q2", "t")] }));
        yield* h.emit(domainEvent("thread.turn-queue-removed", one));
        yield* nothingYet(h.starts.pipe(Effect.map((list) => list.slice(1))));

        yield* h.setShell(idle(one, { queuedTurns: [row("q2", "t")] }));
        yield* h.emit(domainEvent("thread.session-set", one));
        yield* settle(h.starts, (list) => list.length === 2);
        expect((yield* h.starts)[1]).toEqual({
          threadId: one,
          queuedFrom: "q2",
          text: "queued q2",
        });
      }),
    ),
  );

  effectIt.effect("waits while the thread is held or paused, and sends when it is let go", () =>
    Effect.scoped(
      Effect.gen(function* () {
        const h = yield* makeHarness([idle(one), idle(two)]);
        yield* h.setHeld([one]);
        yield* h.setPaused([two]);
        for (let i = 0; i < 20; i += 1) yield* Effect.yieldNow;
        yield* h.emit(domainEvent("thread.turn-queued", one));
        yield* h.emit(domainEvent("thread.turn-queued", two));
        yield* nothingYet(h.starts);

        yield* h.setHeld([]);
        yield* settle(h.starts, (list) => list.length === 1);
        expect((yield* h.starts)[0]?.threadId).toBe(one);

        yield* h.setPaused([]);
        yield* settle(h.starts, (list) => list.length === 2);
        expect((yield* h.starts)[1]?.threadId).toBe(two);
      }),
    ),
  );

  effectIt.effect("sweeps every idle thread's queue at boot, after the first lists arrive", () =>
    Effect.scoped(
      Effect.gen(function* () {
        const h = yield* makeHarness([
          idle(one),
          running(two),
          idle(ThreadId.make("thread-3"), { archivedAt: now }),
          idle(ThreadId.make("thread-4"), { queuedTurns: [] }),
        ]);
        yield* h.setHeld([]);
        yield* nothingYet(h.starts);
        yield* h.setPaused([]);
        yield* settle(h.starts, (list) => list.length === 1);
        expect(yield* h.starts).toEqual([{ threadId: one, queuedFrom: "q1", text: "queued q1" }]);
      }),
    ),
  );
});
