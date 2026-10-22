import { it } from "@effect/vitest";
import { RunId, ThreadId } from "@infinitus/contracts";
import * as FileSystem from "effect/FileSystem";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Path from "effect/Path";
import * as Ref from "effect/Ref";
import { describe, expect } from "vite-plus/test";

import * as ServerConfig from "../config.ts";
import * as GitWorkflow from "../git/GitWorkflowService.ts";
import * as ProjectService from "../project/ProjectService.ts";
import * as ProviderAuthService from "../provider/ProviderAuthService.ts";
import * as ServerSettings from "../serverSettings.ts";
import * as ContextHandoffService from "./ContextHandoffService.ts";
import * as EffectOutbox from "./EffectOutbox.ts";
import * as EventSink from "./EventSink.ts";
import * as IdAllocator from "@infinitus/provider-core/server/IdAllocator";
import * as ProjectionStore from "./ProjectionStore.ts";
import * as ProviderSessionManager from "./ProviderSessionManager.ts";
import * as ProviderTurnStart from "./ProviderTurnStartService.ts";
import * as RunExecutionService from "./RunExecutionService.ts";
import * as RuntimePolicy from "./RuntimePolicy.ts";
import * as TurnStartGate from "./TurnStartGate.ts";

const threadId = ThreadId.make("thread-turn-start-gate");
const runId = RunId.make("run-turn-start-gate");

describe("TurnStartGate (#720, #1627)", () => {
  it.effect("the passthrough runs the start once and answers started", () =>
    Effect.gen(function* () {
      const starts = yield* Ref.make(0);
      const gate = yield* TurnStartGate.TurnStartGate;
      const verdict = yield* gate.start({
        threadId,
        runId,
        start: Ref.update(starts, (n) => n + 1),
      });
      expect(verdict).toBe("started");
      expect(yield* Ref.get(starts)).toBe(1);
    }).pipe(Effect.provide(TurnStartGate.TurnStartGatePassthrough)),
  );

  it.effect("a held start reaches no projection read and no provider", () =>
    Effect.gen(function* () {
      const held = yield* Ref.make<ReadonlyArray<RunId>>([]);
      const holdingGate = Layer.succeed(TurnStartGate.TurnStartGate)({
        start: (input) =>
          Ref.update(held, (list) => [...list, input.runId]).pipe(Effect.as("held")),
      });
      // Every dependency is an empty mock: a start the gate keeps must touch none of them.
      const layer = ProviderTurnStart.layer.pipe(
        Layer.provide(
          Layer.mergeAll(
            holdingGate,
            Layer.mock(ContextHandoffService.ContextHandoffServiceV2)({}),
            Layer.mock(EventSink.EventSinkV2)({}),
            IdAllocator.layer,
            Layer.succeed(FileSystem.FileSystem, {} as never),
            Layer.mock(GitWorkflow.GitWorkflowService)({}),
            Layer.mock(ProjectService.ProjectService)({}),
            Layer.mock(ProjectionStore.ProjectionStoreV2)({}),
            Layer.mock(ProviderSessionManager.ProviderSessionManagerV2)({}),
            Layer.mock(ProviderAuthService.ProviderAuthService)({}),
            Layer.mock(RunExecutionService.RunExecutionServiceV2)({}),
            Layer.mock(RuntimePolicy.RuntimePolicyV2)({}),
            Path.layer,
            Layer.mock(ServerConfig.ServerConfig)({} as never),
            Layer.mock(ServerSettings.ServerSettingsService)({}),
          ),
        ),
      );
      const service = yield* ProviderTurnStart.ProviderTurnStartServiceV2.pipe(
        Effect.provide(layer),
      );
      yield* service.start({ threadId, runId });
      expect(yield* Ref.get(held)).toEqual([runId]);
    }),
  );

  it.effect("releasing a held run enqueues a fresh provider-turn.start and wakes the workers", () =>
    Effect.gen(function* () {
      const enqueued = yield* Ref.make<ReadonlyArray<EffectOutbox.PendingOrchestrationEffectV2>>(
        [],
      );
      const notified = yield* Ref.make(0);
      yield* TurnStartGate.releaseTurnStart({ threadId, runId, releaseId: "headroom-1" }).pipe(
        Effect.provide(
          Layer.mock(EffectOutbox.EffectOutboxV2)({
            enqueue: (effects) => Ref.update(enqueued, (list) => [...list, ...effects]),
            notifyAvailable: () => Ref.update(notified, (n) => n + 1),
          }),
        ),
      );
      expect(yield* Ref.get(enqueued)).toEqual([
        {
          id: `effect:turn-start-gate:${runId}:headroom-1`,
          commandId: `command:system:turn-start-gate:${runId}`,
          threadId,
          request: { type: "provider-turn.start", runId },
        },
      ]);
      expect(yield* Ref.get(notified)).toBe(1);
    }),
  );
});
