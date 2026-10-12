import { assert, it } from "@effect/vitest";
import {
  CommandId,
  MessageId,
  ProjectId,
  ProviderDriverKind,
  ProviderInstanceId,
  ThreadId,
  type OrchestrationV2Command,
} from "@infinitus/contracts";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";

import * as SqlitePersistence from "../persistence/Sqlite.ts";
import { CodexProviderCapabilitiesV2 } from "./Adapters/CodexAdapterV2.ts";
import * as Orchestrator from "./Orchestrator.ts";
import * as ProjectionStore from "./ProjectionStore.ts";
import type { ProviderAdapterV2Shape } from "@infinitus/provider-core/server/ProviderAdapter";
import * as ProviderAdapterRegistry from "./ProviderAdapterRegistry.ts";
import * as ThreadManagementService from "./ThreadManagementService.ts";
import * as ProviderReplayHarness from "./testkit/ProviderReplayHarness.ts";

const instanceId = ProviderInstanceId.make("codex");
const modelSelection = { instanceId, model: "gpt-5.1-codex" };
const adapter = {
  instanceId,
  driver: ProviderDriverKind.make("codex"),
  getCapabilities: () => Effect.succeed(CodexProviderCapabilitiesV2),
  planSelectionTransition: () => Effect.succeed({ type: "apply_on_next_turn" as const }),
  openSession: () => Effect.die("Runs here never reach a provider"),
} as ProviderAdapterV2Shape;
const layerDatabase = SqlitePersistence.layerMemory;
// No effect worker: the first run stays `starting`, so the thread is busy
// without a provider and every later send meets a running turn.
const layerTest = ThreadManagementService.layer.pipe(
  Layer.provideMerge(
    Layer.mergeAll(
      layerDatabase,
      ProjectionStore.layer.pipe(Layer.provide(layerDatabase)),
      ProviderReplayHarness.layerWithRegistry(
        { name: "steer-at-tool-boundary" },
        ProviderAdapterRegistry.layerFromAdapters([adapter]),
        { databaseLayer: layerDatabase, runEffectWorker: false },
      ),
    ),
  ),
);

const threadId = ThreadId.make("thread:steer-at-tool-boundary");

const createThread = Effect.gen(function* () {
  const orchestrator = yield* Orchestrator.OrchestratorV2;
  yield* orchestrator.dispatch({
    type: "thread.create",
    commandId: CommandId.make(`create:${threadId}`),
    threadId,
    projectId: ProjectId.make("project:steer-at-tool-boundary"),
    title: threadId,
    modelSelection,
    runtimeMode: "full-access",
    interactionMode: "default",
    branch: null,
    worktreePath: null,
    createdBy: "user",
    creationSource: "web",
  });
});

const send = (
  text: string,
  delivery: Partial<Extract<OrchestrationV2Command, { readonly type: "message.dispatch" }>>,
) =>
  Effect.gen(function* () {
    const orchestrator = yield* Orchestrator.OrchestratorV2;
    yield* orchestrator.dispatch({
      type: "message.dispatch",
      commandId: CommandId.make(`send:${text}`),
      threadId,
      messageId: MessageId.make(`message:${text}`),
      text,
      attachments: [],
      dispatchMode: { type: "start_immediately" },
      createdBy: "user",
      creationSource: "web",
      ...delivery,
    });
  });

const projectionOf = Effect.gen(function* () {
  const orchestrator = yield* Orchestrator.OrchestratorV2;
  return yield* orchestrator.getThreadProjection(threadId);
});

it.layer(layerTest)("steer at the tool boundary (#1318, #1627)", (it) => {
  it.effect(
    "a steer while a turn runs is queued to go at the turn's next step, keeping its order and context",
    () =>
      Effect.gen(function* () {
        yield* createThread;
        yield* send("first", {});
        yield* send("queued", { dispatchMode: { type: "queue_after_active" } });
        yield* send("steer-by-intent", { deliveryIntent: "steer" });
        const active = (yield* projectionOf).runs.find((run) => run.status === "starting")!;
        yield* send("steer-by-mode", {
          dispatchMode: { type: "steer_active", targetRunId: active.id },
          context: { version: 1, records: [] },
        });

        const projection = yield* projectionOf;
        const queued = projection.runs
          .filter((run) => run.status === "queued")
          .toSorted((a, b) => (a.queuePosition ?? 0) - (b.queuePosition ?? 0));
        assert.deepStrictEqual(
          queued.map((run) => [
            projection.messages.find((m) => m.id === run.userMessageId)?.text,
            run.sendAt ?? "idle",
          ]),
          [
            ["queued", "idle"],
            ["steer-by-intent", "tool_boundary"],
            ["steer-by-mode", "tool_boundary"],
          ],
        );
        // Nothing was steered into the running turn: it still holds its one message.
        assert.strictEqual(
          projection.messages.filter((message) => message.runId === active.id).length,
          1,
        );
        const steerItem = projection.turnItems.find(
          (item) => item.type === "user_message" && item.messageId === MessageId.make("message:steer-by-mode"),
        );
        assert.strictEqual(steerItem?.type === "user_message" && steerItem.inputIntent, "queued_turn");
        assert.deepStrictEqual(
          projection.messages.find((m) => m.id === MessageId.make("message:steer-by-mode"))?.context,
          { version: 1, records: [] },
        );
      }),
  );

  it.effect("the waiting steer is an ordinary queued row: it can be edited, reordered and removed", () =>
    Effect.gen(function* () {
      const orchestrator = yield* Orchestrator.OrchestratorV2;
      const before = yield* projectionOf;
      const steer = before.runs.find((run) => run.sendAt === "tool_boundary")!;
      yield* orchestrator.dispatch({
        type: "queued-run.edit",
        commandId: CommandId.make("edit:steer"),
        threadId,
        runId: steer.id,
        text: "steer, edited",
      });
      yield* orchestrator.dispatch({
        type: "queued-run.reorder",
        commandId: CommandId.make("reorder:steer"),
        threadId,
        runId: steer.id,
        beforeRunId: before.runs.find((run) => run.status === "queued" && run.sendAt === undefined)!
          .id,
      });
      const edited = yield* projectionOf;
      const row = edited.runs.find((run) => run.id === steer.id)!;
      assert.strictEqual(row.sendAt, "tool_boundary");
      assert.strictEqual(
        edited.messages.find((m) => m.id === row.userMessageId)?.text,
        "steer, edited",
      );
      assert.strictEqual(
        edited.runs
          .filter((run) => run.status === "queued")
          .toSorted((a, b) => (a.queuePosition ?? 0) - (b.queuePosition ?? 0))[0]?.id,
        steer.id,
      );

      yield* orchestrator.dispatch({
        type: "queued-run.cancel",
        commandId: CommandId.make("cancel:steer"),
        threadId,
        runId: steer.id,
      });
      const after = yield* projectionOf;
      assert.strictEqual(after.runs.find((run) => run.id === steer.id)?.status, "cancelled");
      // A boundary that arrives after the row went is refused, not sent twice.
      const refused = yield* orchestrator
        .dispatch({
          type: "queued-message.promote-to-steer",
          commandId: CommandId.make("command:system:tool-boundary-steer:late"),
          threadId,
          queuedRunId: steer.id,
          targetRunId: after.runs.find((run) => run.status === "starting")!.id,
        })
        .pipe(Effect.flip);
      assert.strictEqual(refused._tag, "OrchestratorDispatchError");
    }),
  );
});
