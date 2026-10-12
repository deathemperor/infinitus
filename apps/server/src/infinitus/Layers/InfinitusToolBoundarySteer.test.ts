import { it } from "@effect/vitest";
import {
  RunId,
  ThreadId,
  type OrchestrationV2DomainEvent,
  type OrchestrationV2Run,
} from "@infinitus/contracts";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Queue from "effect/Queue";
import * as Ref from "effect/Ref";
import * as Stream from "effect/Stream";
import { describe, expect } from "vite-plus/test";

import * as Orchestrator from "../../orchestration-v2/Orchestrator.ts";
import * as ProjectionStore from "../../orchestration-v2/ProjectionStore.ts";
import { InfinitusToolBoundarySteerLive } from "./InfinitusToolBoundarySteer.ts";

const thread = ThreadId.make("thread-1");
const running = RunId.make("run-1");
const steerRow = RunId.make("run-2");

const run = (
  id: RunId,
  status: OrchestrationV2Run["status"],
  extra: Partial<OrchestrationV2Run> = {},
): OrchestrationV2Run => ({ id, ordinal: Number(id.slice(-1)), status, ...extra }) as never;

let counter = 0;
const toolItem = (
  status: "running" | "completed",
  runId: RunId | null = running,
  itemId = `item-${(counter += 1)}`,
  threadId: ThreadId = thread,
): OrchestrationV2DomainEvent =>
  ({
    type: "turn-item.updated",
    id: `evt-${(counter += 1)}`,
    threadId,
    occurredAt: "2026-10-11T00:00:00Z",
    payload: { id: itemId, threadId, type: "command_execution", runId, status },
  }) as never;

const runsOf = (entries: ReadonlyArray<readonly [ThreadId, ReadonlyArray<OrchestrationV2Run>]>) =>
  Ref.make<ReadonlyMap<ThreadId, ReadonlyArray<OrchestrationV2Run>>>(new Map(entries));

/** Builds the layer over a stub orchestrator whose dispatches land in a queue the test takes from. */
type DispatchedCommand = Parameters<Orchestrator.OrchestratorV2Shape["dispatch"]>[0];

const makeHarness = (input: {
  /** Each thread's runs; the worker reads them when it reaches that thread's event. */
  readonly runs: Ref.Ref<ReadonlyMap<ThreadId, ReadonlyArray<OrchestrationV2Run>>>;
  readonly refuse?: boolean;
}) =>
  Effect.gen(function* () {
    const events = yield* Queue.unbounded<OrchestrationV2DomainEvent>();
    const dispatched = yield* Queue.unbounded<DispatchedCommand>();
    const layer = InfinitusToolBoundarySteerLive.pipe(
      Layer.provide(
        Layer.mergeAll(
          Layer.mock(Orchestrator.OrchestratorV2)({
            get streamDomainEvents() {
              return Stream.fromQueue(events);
            },
            dispatch: (command) =>
              Queue.offer(dispatched, command).pipe(
                Effect.andThen(
                  input.refuse
                    ? Effect.fail(
                        new Orchestrator.OrchestratorDispatchError({
                          commandId: command.commandId,
                          commandType: command.type,
                          cause: "Queued run is not queued.",
                        }),
                      )
                    : Effect.succeed({ sequence: 1, storedEvents: [] }),
                ),
              ),
          }),
          Layer.mock(ProjectionStore.ProjectionStoreV2)({
            getThreadRecords: (threadId) =>
              Ref.get(input.runs).pipe(
                Effect.map(
                  (runs) => ({ thread: { id: threadId }, runs: runs.get(threadId) ?? [] }) as never,
                ),
              ),
          }),
        ),
      ),
    );
    yield* Layer.build(layer);
    return {
      emit: (event: OrchestrationV2DomainEvent) => Queue.offer(events, event),
      next: Queue.take(dispatched),
    };
  });

describe("InfinitusToolBoundarySteerLive (#1318, #1627)", () => {
  it.effect("a finished tool call promotes the waiting steer row into that run", () =>
    Effect.scoped(
      Effect.gen(function* () {
        const runs = yield* runsOf([
          [
            thread,
            [
              run(running, "running"),
              run(RunId.make("run-3"), "queued", { queuePosition: 1 }),
              run(steerRow, "queued", { queuePosition: 2, sendAt: "tool_boundary" }),
            ],
          ],
        ]);
        const h = yield* makeHarness({ runs });
        // A tool still running, a tool of no run, and an unrelated event send nothing.
        yield* h.emit(toolItem("running"));
        yield* h.emit(toolItem("completed", null));
        yield* h.emit({ type: "run.updated", threadId: thread, payload: {} } as never);
        yield* h.emit(toolItem("completed", running, "tool-7"));
        const command = yield* h.next;
        expect(command).toEqual({
          type: "queued-message.promote-to-steer",
          commandId: "command:system:tool-boundary-steer:tool-7",
          threadId: thread,
          queuedRunId: steerRow,
          targetRunId: running,
        });
      }),
    ),
  );

  it.effect("a boundary of a turn that already ended, or with no steer row, sends nothing", () =>
    Effect.scoped(
      Effect.gen(function* () {
        const ended = ThreadId.make("thread-ended");
        const plain = ThreadId.make("thread-plain");
        const runs = yield* runsOf([
          [
            ended,
            [run(running, "completed"), run(steerRow, "queued", { sendAt: "tool_boundary" })],
          ],
          [plain, [run(running, "running"), run(steerRow, "queued")]],
          [thread, [run(running, "running"), run(steerRow, "queued", { sendAt: "tool_boundary" })]],
        ]);
        const h = yield* makeHarness({ runs });
        yield* h.emit(toolItem("completed", running, "tool-ended", ended));
        yield* h.emit(toolItem("completed", running, "tool-plain", plain));
        // The worker is one fiber in order: a dispatch for the row below proves
        // the two boundaries above produced none.
        yield* h.emit(toolItem("completed", running, "tool-9"));
        const command = yield* h.next;
        expect(command.commandId).toBe("command:system:tool-boundary-steer:tool-9");
        expect(command.type === "queued-message.promote-to-steer" && command.threadId).toBe(thread);
      }),
    ),
  );

  it.effect(
    "a refused promotion (the row went meanwhile) is skipped and the next boundary still runs",
    () =>
      Effect.scoped(
        Effect.gen(function* () {
          const runs = yield* runsOf([
            [
              thread,
              [run(running, "running"), run(steerRow, "queued", { sendAt: "tool_boundary" })],
            ],
          ]);
          const h = yield* makeHarness({ runs, refuse: true });
          yield* h.emit(toolItem("completed", running, "tool-1"));
          yield* h.emit(toolItem("completed", running, "tool-2"));
          expect((yield* h.next).commandId).toBe("command:system:tool-boundary-steer:tool-1");
          expect((yield* h.next).commandId).toBe("command:system:tool-boundary-steer:tool-2");
        }),
      ),
  );
});
