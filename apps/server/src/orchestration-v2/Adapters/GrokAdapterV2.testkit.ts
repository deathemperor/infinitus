import * as NodeServices from "@effect/platform-node/NodeServices";
import { GrokSettings } from "@infinitus/provider-grok/settings";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Layer from "effect/Layer";
import * as Path from "effect/Path";
import * as Schema from "effect/Schema";
import { ChildProcessSpawner } from "effect/process";
import { HostProcessPlatform } from "@infinitus/shared/hostProcess";
import { resolveSelfInvocation } from "@infinitus/shared/nodeRuntime";

import { layerTestProviderHost } from "@infinitus/provider-testing/host";
import { GROK_ACP_CANCEL_META, GROK_ACP_INITIALIZE_META } from "@infinitus/provider-grok/testing";
import { makeXAiPromptCompletionRuntime } from "@infinitus/provider-grok/testing";
import * as IdAllocator from "@infinitus/provider-core/server/IdAllocator";
import * as ProviderContinuationRequests from "@infinitus/provider-core/server/continuationRequests";
import * as ProviderAdapterRegistry from "../ProviderAdapterRegistry.ts";
import type { ProviderReplayGate } from "@infinitus/provider-testing/replayGate";
import type { OrchestratorV2ProviderReplayHarness } from "../testkit/ProviderReplayHarness.ts";
import {
  type AcpReplayTranscript,
  AcpReplayTranscriptDecodeError,
  decodeAcpReplayTranscript,
  makeAcpReplayCompletenessAssertion,
  makeAcpReplayRuntime,
} from "./AcpAdapterV2.testkit.ts";
import {
  GROK_DEFAULT_INSTANCE_ID,
  GROK_PROVIDER,
  makeGrokAdapterV2,
} from "@infinitus/provider-grok/testing";

const DEFAULT_GROK_SETTINGS = Schema.decodeUnknownSync(GrokSettings)({});

function layerGrokProviderAdapterRegistryReplay(
  transcript: AcpReplayTranscript,
  options: { readonly replayGate?: ProviderReplayGate } = {},
) {
  const layerHost = layerTestProviderHost().pipe(Layer.provide(NodeServices.layer));

  return ProviderAdapterRegistry.layerFromAdaptersEffect(
    Effect.gen(function* () {
      const fileSystem = yield* FileSystem.FileSystem;
      const path = yield* Path.Path;
      const childProcessSpawner = yield* ChildProcessSpawner.ChildProcessSpawner;
      const hostPlatform = yield* HostProcessPlatform;
      // Same queue the continuation worker drains when the fixture runs it.
      const continuationRequests = yield* ProviderContinuationRequests.ProviderContinuationRequests;
      const replayGate = options.replayGate;
      const replayDir = yield* fileSystem
        .makeTempDirectory({
          prefix: `t3-orchestration-v2-grok-replay-${transcript.scenario}-`,
        })
        .pipe(Effect.orDie);
      const statusPath = path.join(replayDir, "status.json");
      const scriptPath = yield* path
        .fromFileUrl(new URL("../../../scripts/acp-replay-agent.ts", import.meta.url))
        .pipe(Effect.orDie);
      const adapter = yield* makeGrokAdapterV2({
        instanceId: GROK_DEFAULT_INSTANCE_ID,
        settings: DEFAULT_GROK_SETTINGS,
        environment: {},
        hostPlatform,
        selfInvocation: yield* resolveSelfInvocation(),
        // Same wrapping as makeGrokAcpRuntime: client type and Ctrl+C cancel
        // metadata and the x.ai prompt-completion race, so replay sends what
        // production sends.
        makeRuntime: (runtimeInput) =>
          makeAcpReplayRuntime({
            transcript,
            statusPath,
            scriptPath,
            childProcessSpawner,
            fileSystem,
            ...(replayGate === undefined ? {} : { replayGate }),
            cancelMeta: GROK_ACP_CANCEL_META,
            initializeMeta: GROK_ACP_INITIALIZE_META,
          })(runtimeInput).pipe(Effect.flatMap(makeXAiPromptCompletionRuntime)),
        continuationRequests,
        assertComplete: makeAcpReplayCompletenessAssertion(fileSystem, statusPath, transcript),
        ...(replayGate === undefined
          ? {}
          : {
              testHooks: {
                onDeferredFinalizeScheduled: (debounce) =>
                  Effect.sync(() => replayGate.recordFinishArmed(debounce)),
              },
            }),
      });
      return [adapter];
    }),
  ).pipe(
    Layer.provide(Layer.mergeAll(layerHost, NodeServices.layer, IdAllocator.layer)),
    // Held inbound lines must not outlive the scenario and wedge teardown.
    Layer.merge(
      Layer.effectDiscard(
        Effect.addFinalizer(() => Effect.sync(() => options.replayGate?.releaseAll())),
      ),
    ),
  );
}

export const GrokOrchestratorReplayHarness: OrchestratorV2ProviderReplayHarness<
  AcpReplayTranscript,
  AcpReplayTranscriptDecodeError
> = {
  driver: GROK_PROVIDER,
  decodeTranscript: (transcript) => decodeAcpReplayTranscript(transcript, GROK_PROVIDER),
  makeProviderAdapterRegistryLayer: layerGrokProviderAdapterRegistryReplay,
};
