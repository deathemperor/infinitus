import { FetchHttpClient } from "effect/http";
import * as Layer from "effect/Layer";

import * as ServerSecretStore from "../../auth/ServerSecretStore.ts";
import * as ProjectionStoreV2 from "../../orchestration-v2/ProjectionStore.ts";
import * as ProcessRunner from "../../processRunner.ts";
import { InfinitusLimitStopsLive } from "../Services/InfinitusLimitStops.ts";
import { InfinitusSessionHoldsIdle } from "../Services/InfinitusSessionHolds.ts";
import { InfinitusSwapdProbeLive } from "../Services/InfinitusSwapdProbe.ts";
import { InfinitusLive } from "./Infinitus.ts";
import { InfinitusAlertRelayLive } from "./InfinitusAlertRelay.ts";
import { InfinitusCompanionLive } from "./InfinitusCompanion.ts";
import {
  InfinitusControlClientConfigLive,
  InfinitusControlClientLive,
} from "./InfinitusControlClient.ts";
import { infinitusHttpApiLayer } from "./InfinitusHttp.ts";
import { InfinitusPairingLive } from "./InfinitusPairing.ts";
import { infinitusPairingHttpApiLayer } from "./InfinitusPairingHttp.ts";
import { InfinitusResumeOnLimitLive } from "./InfinitusResumeOnLimit.ts";
import { InfinitusRunningTurnsLive } from "./InfinitusRunningTurns.ts";
import { InfinitusSecretLive } from "./InfinitusSecret.ts";
import { InfinitusServerPortLive } from "./InfinitusServerPort.ts";
import { InfinitusSignInLapseLive } from "./InfinitusSignInLapse.ts";
import { InfinitusToolBoundarySteerLive } from "./InfinitusToolBoundarySteer.ts";
import { InfinitusUsageAttributionLive } from "./InfinitusUsageAttribution.ts";
import { ThreadUsageBackfillLive } from "./ThreadUsageBackfill.ts";

// Each caller gets its own instance: the control client is private to the
// Infinitus block, the alert relay and the running-turns reader are read by
// two unrelated consumers, and a shared const would memoize them into one.
const controlClient = () =>
  InfinitusControlClientLive.pipe(Layer.provide(InfinitusControlClientConfigLive));
const alertRelay = () =>
  InfinitusAlertRelayLive.pipe(
    Layer.provide(ServerSecretStore.layer),
    Layer.provide(FetchHttpClient.layer),
  );
const runningTurns = () => InfinitusRunningTurnsLive.pipe(Layer.provide(ProjectionStoreV2.layer));

/**
 * The fork's server layers, composed once from `server.ts` with the upstream compositions they
 * depend on (generic in their types, so requirements resolve at the call site). `reactors` merge
 * beside upstream's, where the chain hands them `OrchestratorV2` and `ServerEnvironment`; the usage
 * backfill needs `UsageService`, to which `infinitus` is provided.
 */
export function makeInfinitusServerLayers<
  ROutAuth,
  EAuth,
  RInAuth,
  ROutEnv,
  EEnv,
  RInEnv,
  ROutSettings,
  ESettings,
  RInSettings,
>(input: {
  readonly layerAuth: Layer.Layer<ROutAuth, EAuth, RInAuth>;
  readonly layerServerEnvironment: Layer.Layer<ROutEnv, EEnv, RInEnv>;
  readonly layerServerSettings: Layer.Layer<ROutSettings, ESettings, RInSettings>;
}) {
  const infinitus = Layer.mergeAll(
    InfinitusServerPortLive.pipe(
      Layer.provide(input.layerAuth),
      Layer.provide(input.layerServerEnvironment),
    ),
    InfinitusCompanionLive,
    InfinitusSecretLive,
    InfinitusUsageAttributionLive,
  ).pipe(Layer.provideMerge(InfinitusLive), Layer.provide(controlClient()));
  const reactors = Layer.mergeAll(
    InfinitusSignInLapseLive.pipe(
      Layer.provide(infinitus),
      Layer.provide(controlClient()),
      Layer.provide(ProcessRunner.layer),
      Layer.provide(alertRelay()),
    ),
    // Session priority mode's holds stream and "Run now" (#616, #743, #1627):
    // nothing is held until the hold and interrupt policies land on the queue
    // lane's turn-start gate; this answers the empty list.
    InfinitusSessionHoldsIdle,
    // Threads whose turns predate usage recording get a baseline (#834, #1627):
    // the v1 rollup the import left, or the Claude transcript's total, through
    // `thread.metadata.update`. `UsageService` comes from the chain (`layerUsage`
    // is merged above the reactors), like `OrchestratorV2`.
    ThreadUsageBackfillLive,
    InfinitusResumeOnLimitLive.pipe(
      Layer.provide(infinitus),
      Layer.provide(InfinitusSwapdProbeLive.pipe(Layer.provide(ProcessRunner.layer))),
      Layer.provide(ProjectionStoreV2.layer),
      Layer.provide(input.layerServerSettings),
    ),
    InfinitusToolBoundarySteerLive.pipe(Layer.provide(ProjectionStoreV2.layer)),
  );
  const runtime = Layer.mergeAll(
    infinitus,
    InfinitusLimitStopsLive,
    InfinitusPairingLive.pipe(Layer.provide(input.layerAuth)),
  );
  const httpApi = Layer.mergeAll(
    infinitusPairingHttpApiLayer,
    infinitusHttpApiLayer.pipe(Layer.provide(runningTurns()), Layer.provide(alertRelay())),
  );
  return { infinitus, reactors, runtime, httpApi, runningTurns: runningTurns() };
}
