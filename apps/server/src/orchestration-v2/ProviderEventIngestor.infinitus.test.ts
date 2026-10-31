// The fork's ProviderEventIngestor cases (#834, #927: the tool-call count on the
// terminal provider turn), beside upstream's `ProviderEventIngestor.test.ts` so that
// file stays theirs. The fixture helpers are copies of that file's.
import * as NodeServices from "@effect/platform-node/NodeServices";
import { assert, it } from "@effect/vitest";
import {
  type ModelSelection,
  NodeId,
  type OrchestrationV2AppThread,
  type OrchestrationV2DomainEvent,
  type OrchestrationV2TurnItem,
  ProviderDriverKind,
  ProviderInstanceId,
  RunId,
  TurnItemId,
} from "@infinitus/contracts";
import * as DateTime from "effect/DateTime";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";

import * as ServerConfig from "../config.ts";
import * as SqlitePersistence from "../persistence/Sqlite.ts";
import * as GitVcsDriver from "../vcs/GitVcsDriver.ts";
import * as EventSink from "./EventSink.ts";
import * as EventStore from "./EventStore.ts";
import * as IdAllocator from "@infinitus/provider-core/server/IdAllocator";
import * as ProviderInstanceRegistry from "../provider/ProviderInstanceRegistry.ts";
import * as ProjectionStore from "./ProjectionStore.ts";
import * as ProviderEventIngestor from "./ProviderEventIngestor.ts";
import * as ThreadCommandExecutor from "./ThreadCommandExecutor.ts";

const layerTestDatabase = SqlitePersistence.layerMemory;
const layerTestStores = Layer.merge(EventStore.layer, ProjectionStore.layer).pipe(
  Layer.provide(layerTestDatabase),
);

const layerTestEventSink = EventSink.layer.pipe(
  Layer.provide(Layer.mergeAll(layerTestStores, layerTestDatabase)),
);

const layerGit = GitVcsDriver.layer.pipe(
  Layer.provide(ServerConfig.layerTest(process.cwd(), { prefix: "ingestor-infinitus-git-" })),
  Layer.provideMerge(NodeServices.layer),
);

const layerTest = Layer.mergeAll(
  layerTestStores,
  layerTestEventSink,
  IdAllocator.layer,
  ThreadCommandExecutor.layer,
  ProviderEventIngestor.layer.pipe(
    Layer.provide(
      Layer.mergeAll(
        layerTestStores,
        layerTestEventSink,
        IdAllocator.layer,
        ThreadCommandExecutor.layer,
        layerGit,
        Layer.mock(ProviderInstanceRegistry.ProviderInstanceRegistry)({
          // @effect-diagnostics-next-line effectSucceedWithVoid:off - Optional instances require undefined rather than void.
          getInstance: () => Effect.succeed(undefined),
        }),
      ),
    ),
  ),
);
const modelSelection = {
  instanceId: ProviderInstanceId.make("codex"),
  model: "gpt-5.4",
} satisfies ModelSelection;
const CODEX_DRIVER = ProviderDriverKind.make("codex");

function threadCreatedEvent(
  now: DateTime.Utc,
): Effect.Effect<
  OrchestrationV2DomainEvent,
  IdAllocator.IdAllocatorV2Error,
  IdAllocator.IdAllocatorV2
> {
  return Effect.gen(function* () {
    const idAllocator = yield* IdAllocator.IdAllocatorV2;
    const projectId = yield* idAllocator.allocate.project({
      fixtureName: "provider-event-ingestor",
    });
    const threadId = yield* idAllocator.allocate.thread({
      fixtureName: "provider-event-ingestor",
      projectId,
    });
    const providerThreadId = idAllocator.derive.providerThread({
      driver: CODEX_DRIVER,
      nativeThreadId: "native-thread",
    });
    const thread: OrchestrationV2AppThread = {
      createdBy: "user",
      creationSource: "web",
      id: threadId,
      projectId,
      title: "Provider event ingestor",
      providerInstanceId: modelSelection.instanceId,
      modelSelection: modelSelection,
      runtimeMode: "full-access",
      interactionMode: "default",
      branch: null,
      worktreePath: null,
      branchPullRequest: null,
      activeOrderKey: null,
      activeProviderThreadId: providerThreadId,
      lineage: {
        parentThreadId: null,
        relationshipToParent: null,
        rootThreadId: threadId,
      },
      forkedFrom: null,
      createdAt: now,
      updatedAt: now,
      archivedAt: null,
      settledOverride: null,
      settledAt: null,
      lastVisitedAt: null,
      deletedAt: null,
    };

    return {
      id: yield* idAllocator.allocate.event({ threadId }),
      type: "thread.created",
      threadId,
      occurredAt: now,
      payload: thread,
    };
  });
}

const layer = it.layer(layerTest);

layer("ProviderEventIngestorV2 tool calls", (it) => {
  it.effect("stamps the distinct tool items of the turn on its terminal update only", () =>
    Effect.gen(function* () {
      const now = yield* DateTime.now;
      const eventSink = yield* EventSink.EventSinkV2;
      const ingestor = yield* ProviderEventIngestor.ProviderEventIngestorV2;
      const idAllocator = yield* IdAllocator.IdAllocatorV2;
      const threadEvent = yield* threadCreatedEvent(now);
      yield* eventSink.write({ events: [threadEvent] });
      const providerSessionId = yield* idAllocator.allocate.providerSession({
        providerInstanceId: modelSelection.instanceId,
        threadId: threadEvent.threadId,
      });
      const providerThreadId = idAllocator.derive.providerThread({
        driver: CODEX_DRIVER,
        nativeThreadId: "tool-calls-thread",
      });
      const providerTurnId = idAllocator.derive.providerTurn({
        driver: CODEX_DRIVER,
        nativeTurnId: "tool-calls-turn",
      });
      const runId = RunId.make("run:tool-calls");
      const base = {
        threadId: threadEvent.threadId,
        runId,
        nodeId: NodeId.make("node:tool-calls"),
        providerThreadId,
        providerTurnId,
        nativeItemRef: null,
        parentItemId: null,
        startedAt: now,
        completedAt: null,
        updatedAt: now,
        title: "ls",
        type: "command_execution",
        input: "ls",
      } as const;
      const first = {
        ...base,
        id: TurnItemId.make("item:tool-calls-1"),
        ordinal: 1,
        status: "running",
      } satisfies OrchestrationV2TurnItem;
      const second = {
        ...base,
        id: TurnItemId.make("item:tool-calls-2"),
        ordinal: 2,
        status: "completed",
        completedAt: now,
      } satisfies OrchestrationV2TurnItem;
      const ingest = (event: Parameters<typeof ingestor.ingestNormalized>[0]["event"]) =>
        ingestor.ingestNormalized({
          providerSessionId,
          providerInstanceId: modelSelection.instanceId,
          threadId: threadEvent.threadId,
          runId,
          event,
        });
      // The first item is updated twice: one id, one call.
      yield* ingest({ type: "turn_item.updated", driver: CODEX_DRIVER, turnItem: first });
      yield* ingest({
        type: "turn_item.updated",
        driver: CODEX_DRIVER,
        turnItem: { ...first, status: "completed", completedAt: now },
      });
      yield* ingest({ type: "turn_item.updated", driver: CODEX_DRIVER, turnItem: second });

      const providerTurn = {
        id: providerTurnId,
        providerThreadId,
        nodeId: base.nodeId,
        runAttemptId: null,
        nativeTurnRef: null,
        ordinal: 1,
        status: "running" as const,
        startedAt: now,
        completedAt: null,
      };
      const [running] = yield* ingest({
        type: "provider_turn.updated",
        driver: CODEX_DRIVER,
        providerTurn,
      });
      assert.equal(running?.event.type, "provider-turn.updated");
      if (running?.event.type === "provider-turn.updated") {
        assert.isUndefined(running.event.payload.toolCalls);
      }
      const [completed] = yield* ingest({
        type: "provider_turn.updated",
        driver: CODEX_DRIVER,
        providerTurn: { ...providerTurn, status: "completed" as const, completedAt: now },
      });
      assert.equal(completed?.event.type, "provider-turn.updated");
      if (completed?.event.type === "provider-turn.updated") {
        assert.equal(completed.event.payload.toolCalls, 2);
      }
      // An adapter that counted for itself is not second-guessed.
      const [counted] = yield* ingest({
        type: "provider_turn.updated",
        driver: CODEX_DRIVER,
        providerTurn: {
          ...providerTurn,
          status: "completed" as const,
          completedAt: now,
          toolCalls: 9,
        },
      });
      if (counted?.event.type === "provider-turn.updated") {
        assert.equal(counted.event.payload.toolCalls, 9);
      }
    }),
  );
});
