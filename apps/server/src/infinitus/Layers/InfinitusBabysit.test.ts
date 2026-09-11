import {
  BABYSIT_MAX_ROUNDS,
  DEFAULT_PROVIDER_INTERACTION_MODE,
  ThreadId,
  TurnId,
  type OrchestrationCommand,
  type OrchestrationEvent,
  type OrchestrationThreadShell,
  type ThreadPullRequestKey,
  type ThreadPullRequestLink,
  type ThreadPullRequestSnapshot,
} from "@t3tools/contracts";
import { it as effectIt } from "@effect/vitest";
import * as Crypto from "effect/Crypto";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";
import * as PubSub from "effect/PubSub";
import * as Ref from "effect/Ref";
import * as Stream from "effect/Stream";
import { describe, expect } from "vite-plus/test";

import { PullRequestSyncReactor } from "../../orchestration/PullRequestSyncReactor.ts";
import { OrchestrationEngineService } from "../../orchestration/Services/OrchestrationEngine.ts";
import { ProjectionSnapshotQuery } from "../../orchestration/Services/ProjectionSnapshotQuery.ts";
import { InfinitusBabysitLive } from "./InfinitusBabysit.ts";

const one = ThreadId.make("thread-1");
const now = "2026-09-12T10:00:00.000Z";

const snapshot = (
  overrides: Partial<ThreadPullRequestSnapshot> = {},
): ThreadPullRequestSnapshot => ({
  state: "open",
  title: "Fix the thing",
  headBranch: "fix/thing",
  baseBranch: "main",
  isDraft: false,
  updatedAt: "2026-09-12T09:00:00.000Z",
  syncedAt: now,
  checksState: "passing",
  reviewDecision: "review-required",
  mergeability: "mergeable",
  ...overrides,
});

const link = (snap: ThreadPullRequestSnapshot | null): ThreadPullRequestLink => ({
  host: "github.com",
  repository: "acme/app",
  number: 7,
  url: "https://github.com/acme/app/pull/7",
  source: "created",
  linkedAt: now,
  snapshot: snap,
  stack: null,
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
    session: { activeTurnId: null, status: "ready" },
    latestTurn: null,
    latestUserMessageAt: null,
    pullRequests: [],
    babysit: { since: now, rounds: 0 },
    ...overrides,
  }) as unknown as OrchestrationThreadShell;

const event = (
  type: OrchestrationEvent["type"],
  threadId: ThreadId,
  payload: Record<string, unknown> = {},
): OrchestrationEvent =>
  ({
    type,
    aggregateKind: "thread",
    aggregateId: threadId,
    payload: { threadId, ...payload },
  }) as never;

let uuidCounter = 0;
const testCrypto = Crypto.make({
  randomBytes: (size) => {
    uuidCounter += 1;
    return new Uint8Array(size).fill(uuidCounter % 256);
  },
  digest: (_algorithm, data) => Effect.succeed(data),
});

const makeHarness = (initial: ReadonlyArray<OrchestrationThreadShell>) =>
  Effect.gen(function* () {
    const domainEvents = yield* PubSub.unbounded<OrchestrationEvent>();
    const shells = yield* Ref.make<ReadonlyMap<ThreadId, OrchestrationThreadShell>>(
      new Map(initial.map((shell) => [shell.id, shell])),
    );
    const dispatched = yield* Ref.make<ReadonlyArray<OrchestrationCommand>>([]);
    const syncRequests = yield* Ref.make<ReadonlyArray<ThreadPullRequestKey>>([]);

    const layer = InfinitusBabysitLive.pipe(
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
          Layer.mock(PullRequestSyncReactor)({
            requestSync: (key) =>
              Ref.update(syncRequests, (previous) => [...previous, key]).pipe(Effect.asVoid),
          }),
          Layer.succeed(Crypto.Crypto, testCrypto),
        ),
      ),
    );
    yield* Layer.build(layer);
    // The forked stream subscribes on its first step; an event published
    // before that reaches nobody. The boot sweep runs in the same window.
    for (let i = 0; i < 20; i += 1) yield* Effect.yieldNow;

    return {
      emit: (value: OrchestrationEvent) => PubSub.publish(domainEvents, value).pipe(Effect.asVoid),
      setShell: (shell: OrchestrationThreadShell) =>
        Ref.update(shells, (map) => new Map([...map, [shell.id, shell]])),
      commands: Ref.get(dispatched),
      queued: Ref.get(dispatched).pipe(
        Effect.map((commands) =>
          commands.flatMap((command) =>
            command.type === "thread.turn.queue"
              ? [{ threadId: command.threadId, text: command.message.text }]
              : [],
          ),
        ),
      ),
      syncRequests: Ref.get(syncRequests),
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

describe("InfinitusBabysitLive (#269 A)", () => {
  effectIt.effect(
    "queues a round when a synced snapshot goes red, bumps the round, and not again for the same state",
    () =>
      Effect.scoped(
        Effect.gen(function* () {
          const h = yield* makeHarness([shellFor(one, { pullRequests: [link(snapshot())] })]);
          yield* h.emit(event("thread.pull-request-synced", one));
          yield* nothingYet(h.queued);

          const failing = snapshot({ checksState: "failing" });
          yield* h.setShell(shellFor(one, { pullRequests: [link(failing)] }));
          yield* h.emit(event("thread.pull-request-synced", one));
          yield* settle(h.queued, (list) => list.length === 1);
          const queued = yield* h.queued;
          expect(queued[0]?.text.startsWith(`Babysit round 1 of ${BABYSIT_MAX_ROUNDS}.`)).toBe(
            true,
          );
          expect(queued[0]?.text).toContain("gh pr checks 7");
          const rounds = (yield* h.commands).filter(
            (command) => command.type === "thread.meta.update" && command.babysitRounds === 1,
          );
          expect(rounds).toHaveLength(1);

          // The same red state again (the projection now says rounds: 1).
          yield* h.setShell(
            shellFor(one, { pullRequests: [link(failing)], babysit: { since: now, rounds: 1 } }),
          );
          yield* h.emit(event("thread.pull-request-synced", one));
          yield* nothingYet(h.queued.pipe(Effect.map((list) => list.slice(1))));

          // A push moved updatedAt and the checks failed again: round two.
          yield* h.setShell(
            shellFor(one, {
              pullRequests: [
                link(snapshot({ checksState: "failing", updatedAt: "2026-09-12T09:30:00.000Z" })),
              ],
              babysit: { since: now, rounds: 1 },
            }),
          );
          yield* h.emit(event("thread.pull-request-synced", one));
          yield* settle(h.queued, (list) => list.length === 2);
          expect((yield* h.queued)[1]?.text.startsWith("Babysit round 2 of")).toBe(true);
        }),
      ),
  );

  effectIt.effect("waits while the thread runs and re-reads the host when the turn ends", () =>
    Effect.scoped(
      Effect.gen(function* () {
        const failing = link(snapshot({ checksState: "failing" }));
        yield* (yield* makeHarness([])).emit(event("thread.session-set", one));
        const h = yield* makeHarness([
          shellFor(one, {
            pullRequests: [failing],
            session: { activeTurnId: TurnId.make("turn-1"), status: "running" } as never,
          }),
        ]);
        yield* h.emit(event("thread.pull-request-synced", one));
        yield* nothingYet(h.queued);

        yield* h.setShell(shellFor(one, { pullRequests: [failing] }));
        yield* h.emit(event("thread.session-set", one));
        yield* settle(h.syncRequests, (list) => list.length === 1);
        expect((yield* h.syncRequests)[0]?.number).toBe(7);
        // Nothing is queued until the requested read lands as a synced event.
        yield* nothingYet(h.queued);
        yield* h.emit(event("thread.pull-request-synced", one));
        yield* settle(h.queued, (list) => list.length === 1);
      }),
    ),
  );

  effectIt.effect("seeds what is red at boot without acting; turning babysit on acts", () =>
    Effect.scoped(
      Effect.gen(function* () {
        const failing = link(snapshot({ checksState: "failing" }));
        const h = yield* makeHarness([
          shellFor(one, { pullRequests: [failing] }),
          shellFor(ThreadId.make("thread-off"), { pullRequests: [failing], babysit: null }),
        ]);
        yield* h.emit(event("thread.pull-request-synced", one));
        yield* nothingYet(h.queued);

        const two = ThreadId.make("thread-off");
        yield* h.setShell(shellFor(two, { pullRequests: [failing] }));
        yield* h.emit(event("thread.meta-updated", two, { babysit: { since: now, rounds: 0 } }));
        yield* settle(h.queued, (list) => list.length === 1);
        expect((yield* h.queued)[0]?.threadId).toBe(two);
        expect((yield* h.syncRequests).map((key) => key.number)).toEqual([7]);

        // Off forgets the thread: a later synced event does nothing.
        yield* h.setShell(shellFor(two, { pullRequests: [failing], babysit: null }));
        yield* h.emit(event("thread.meta-updated", two, { babysit: null }));
        yield* h.emit(event("thread.pull-request-synced", two));
        yield* nothingYet(h.queued.pipe(Effect.map((list) => list.slice(1))));
      }),
    ),
  );

  effectIt.effect(
    "a thread the sweep missed seeds itself on first sight; a new on-stretch still acts",
    () =>
      Effect.scoped(
        Effect.gen(function* () {
          const h = yield* makeHarness([]);
          const failing = snapshot({ checksState: "failing" });
          yield* h.setShell(shellFor(one, { pullRequests: [link(failing)] }));
          yield* h.emit(event("thread.pull-request-synced", one));
          yield* nothingYet(h.queued);

          yield* h.setShell(
            shellFor(one, {
              pullRequests: [
                link(snapshot({ checksState: "failing", updatedAt: "2026-09-12T09:30:00.000Z" })),
              ],
            }),
          );
          yield* h.emit(event("thread.pull-request-synced", one));
          yield* settle(h.queued, (list) => list.length === 1);

          // The round's bump re-emits the flag: no new read, no forgetting.
          yield* h.setShell(
            shellFor(one, {
              pullRequests: [
                link(snapshot({ checksState: "failing", updatedAt: "2026-09-12T09:30:00.000Z" })),
              ],
              babysit: { since: now, rounds: 1 },
            }),
          );
          yield* h.emit(event("thread.meta-updated", one, { babysit: { since: now, rounds: 1 } }));
          yield* h.emit(event("thread.pull-request-synced", one));
          yield* nothingYet(h.queued.pipe(Effect.map((list) => list.slice(1))));

          // Turned on again (rounds back to 0): the seeded marks are forgotten.
          yield* h.setShell(
            shellFor(one, {
              pullRequests: [
                link(snapshot({ checksState: "failing", updatedAt: "2026-09-12T09:30:00.000Z" })),
              ],
              babysit: { since: "2026-09-12T11:00:00.000Z", rounds: 0 },
            }),
          );
          yield* h.emit(
            event("thread.meta-updated", one, {
              babysit: { since: "2026-09-12T11:00:00.000Z", rounds: 0 },
            }),
          );
          yield* settle(h.queued, (list) => list.length === 2);
          expect(yield* h.syncRequests).toHaveLength(1);
        }),
      ),
  );

  effectIt.effect("stops at the cap with an error activity and on merge with an info one", () =>
    Effect.scoped(
      Effect.gen(function* () {
        const h = yield* makeHarness([
          shellFor(one, {
            pullRequests: [link(snapshot({ checksState: "failing" }))],
            babysit: { since: now, rounds: BABYSIT_MAX_ROUNDS },
          }),
        ]);
        // Seeded at boot: a new red state is needed to reach the cap.
        yield* h.setShell(
          shellFor(one, {
            pullRequests: [
              link(snapshot({ checksState: "failing", updatedAt: "2026-09-12T09:30:00.000Z" })),
            ],
            babysit: { since: now, rounds: BABYSIT_MAX_ROUNDS },
          }),
        );
        yield* h.emit(event("thread.pull-request-synced", one));
        yield* settle(h.commands, (list) => list.length === 2);
        const commands = yield* h.commands;
        expect(commands[0]).toMatchObject({ type: "thread.meta.update", babysit: false });
        expect(commands[1]).toMatchObject({
          type: "thread.activity.append",
          activity: { tone: "error", kind: "babysit.stopped" },
        });
        expect(yield* h.queued).toEqual([]);

        const two = ThreadId.make("thread-merged");
        yield* h.setShell(shellFor(two, { pullRequests: [link(snapshot({ state: "merged" }))] }));
        yield* h.emit(event("thread.meta-updated", two, { babysit: { since: now, rounds: 0 } }));
        yield* settle(h.commands, (list) => list.length === 4);
        expect((yield* h.commands)[3]).toMatchObject({
          type: "thread.activity.append",
          activity: { tone: "info", kind: "babysit.done" },
        });
      }),
    ),
  );
});
