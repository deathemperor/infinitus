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
 * The fork's server layers, composed once from `server.ts` with the two
 * upstream compositions they depend on (generic in those layers' types, so
 * the requirements resolve at the call site exactly as inline code would):
 *
 * - `infinitus`: `InfinitusLive` with the control client private to it (the
 *   only thing that polls the socket), the port layer (writes one pref once
 *   the server listens and again when a watched app comes back; it also
 *   mints infinitusctl's session, #822, hence `layerAuth`, and names this
 *   environment to the app, #1487, hence `layerServerEnvironment`), the companion
 *   (opens the app when the socket stays quiet and on `infinitus.launch`),
 *   `InfinitusSecretLive` (#747, the one secret-carrying path) and
 *   `InfinitusUsageAttributionLive` (#779, the `history` verb per usage
 *   scan). Provided to `UsageService` and merged into the runtime.
 * - `reactors`: the sign-in lapse watcher (#1076, #1627: a lapsed AWS /
 *   gcloud sign-in in a tool's output starts the Mac's login and rings the
 *   phones; its own control client, `ps` / `kill` through `ProcessRunner`)
 *   and resume-on-limit (#648, #1627: failed limit runs and the Claude
 *   adapter's rejected windows, the swapd probe for the accounts while the
 *   menu bar app is away), the idle session-holds layer (#616, #743) and
 *   the tool-boundary steer (#1318, #1627: a queued steer goes into the
 *   running turn at its next finished tool call; reads the projection store).
 *   Merged beside upstream's reactors, where the
 *   chain hands them `OrchestratorV2` and `ServerEnvironment`.
 * - `runtime`: `infinitus`, the limit-stop list (#648: one instance for the
 *   resume layer, the Claude driver's refusal hook and the `ws.ts` stream)
 *   and the pairing-approval store (#710, minting through the same auth
 *   service as the QR flow). Merged into `layerRuntimeDependencies`.
 * - `httpApi`: the phone's pairing routes and the Mac's alert (#1375) and
 *   running-turns (#829) routes, for the `EnvironmentHttpApi` builder.
 * - `runningTurns`: for the update idle gate (#829).
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
