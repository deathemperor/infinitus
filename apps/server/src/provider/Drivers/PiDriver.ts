/**
<<<<<<< HEAD
 * PiDriver — the Pi CLI as a provider driver.
 *
 * Pi speaks its own JSONL RPC rather than ACP, so the instance bundles the
 * hand-written {@link ../Layers/PiAdapter} instead of an ACP runtime. Rules
 * and traps: `docs/internals/pi-driver.md`.
 *
 * @module provider/Drivers/PiDriver
 */
import { PiSettings, ProviderDriverKind } from "@infinitus/contracts";
import * as Crypto from "effect/Crypto";
=======
 * PiDriver — v1 `ProviderDriver` for the Pi coding agent, composing the
 * orchestrator-v2 adapter (`PiAdapterV2`), the snapshot/probe layer
 * (`PiProvider`), and Pi-backed text generation.
 *
 * Pi state (sessions, settings, extensions, auth) lives in the user's own
 * `~/.pi/agent`, so continuation identity uses the default instance grouping.
 */
import { PiSettings, ProviderDriverKind, type ServerProvider } from "@infinitus/contracts";
>>>>>>> upstream-sync-e8545b293-upstream-renamed
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Path from "effect/Path";
import * as Schema from "effect/Schema";
import { HttpClient } from "effect/unstable/http";
import { ChildProcessSpawner } from "effect/unstable/process";

import * as BackgroundPolicy from "../../background/BackgroundPolicy.ts";
<<<<<<< HEAD
import { ServerConfig } from "../../config.ts";
import { expandHomePath } from "../../pathExpansion.ts";
import { ServerSettingsService } from "../../serverSettings.ts";
import { ProviderDriverError } from "../Errors.ts";
import { makePiAdapter } from "../Layers/PiAdapter.ts";
import { writePiProxyModelsFile } from "../Layers/piProxyHome.ts";
=======
import * as ServerConfig from "../../config.ts";
import * as ServerSettings from "../../serverSettings.ts";
import { makePiTextGeneration } from "../../textGeneration/PiTextGeneration.ts";
import {
  PiAdapterV2Driver,
  type PiAdapterV2DriverEnv,
} from "../../orchestration-v2/Adapters/PiAdapterV2.ts";
import { ProviderDriverError } from "../Errors.ts";
>>>>>>> upstream-sync-e8545b293-upstream-renamed
import {
  buildInitialPiProviderSnapshot,
  checkPiProviderStatus,
  enrichPiSnapshot,
} from "../Layers/PiProvider.ts";
<<<<<<< HEAD
import { makePiTextGeneration } from "../../textGeneration/PiTextGeneration.ts";
import { ProviderEventLoggers } from "../Layers/ProviderEventLoggers.ts";
=======
>>>>>>> upstream-sync-e8545b293-upstream-renamed
import { makeManagedServerProvider } from "../makeManagedServerProvider.ts";
import {
  defaultProviderContinuationIdentity,
  type ProviderDriver,
  type ProviderInstance,
} from "../ProviderDriver.ts";
<<<<<<< HEAD
import { withInstanceIdentity } from "./instanceIdentity.ts";
import { mergeProviderInstanceEnvironment } from "../ProviderInstanceEnvironment.ts";
import { makeManualOnlyProviderMaintenanceCapabilities } from "../providerMaintenance.ts";
=======
import type { ServerProviderDraft } from "../providerSnapshot.ts";
import { mergeProviderInstanceEnvironment } from "../ProviderInstanceEnvironment.ts";
import {
  makeCachedProviderMaintenanceResolution,
  makePackageManagedProviderMaintenanceResolver,
  resolveProviderMaintenanceCapabilitiesEffect,
} from "../providerMaintenance.ts";
>>>>>>> upstream-sync-e8545b293-upstream-renamed
import {
  haveProviderSnapshotSettingsChanged,
  makeProviderSnapshotSettingsSource,
  type ProviderSnapshotSettings,
} from "../providerUpdateSettings.ts";
<<<<<<< HEAD
const decodePiSettings = Schema.decodeSync(PiSettings);

const DRIVER_KIND = ProviderDriverKind.make("pi");
const MAINTENANCE_CAPABILITIES = makeManualOnlyProviderMaintenanceCapabilities({
  provider: DRIVER_KIND,
  packageName: "@earendil-works/pi-coding-agent",
});

export type PiDriverEnv =
  | BackgroundPolicy.BackgroundPolicy
  | ChildProcessSpawner.ChildProcessSpawner
  | Crypto.Crypto
  | FileSystem.FileSystem
  | HttpClient.HttpClient
  | Path.Path
  | ProviderEventLoggers
  | ServerConfig
  | ServerSettingsService;
=======

const decodePiSettings = Schema.decodeSync(PiSettings);

const DRIVER_KIND = ProviderDriverKind.make("pi");
const UPDATE = makePackageManagedProviderMaintenanceResolver({
  provider: DRIVER_KIND,
  npmPackageName: "@earendil-works/pi-coding-agent",
  nativeUpdate: null,
});

export type PiDriverEnv =
  | PiAdapterV2DriverEnv
  | BackgroundPolicy.BackgroundPolicy
  | ChildProcessSpawner.ChildProcessSpawner
  | FileSystem.FileSystem
  | HttpClient.HttpClient
  | Path.Path
  | ServerConfig.ServerConfig
  | ServerSettings.ServerSettingsService;

const withInstanceIdentity =
  (input: {
    readonly instanceId: ProviderInstance["instanceId"];
    readonly displayName: string | undefined;
    readonly accentColor: string | undefined;
    readonly continuationGroupKey: string;
  }) =>
  (snapshot: ServerProviderDraft): ServerProvider => ({
    ...snapshot,
    instanceId: input.instanceId,
    driver: DRIVER_KIND,
    ...(input.displayName ? { displayName: input.displayName } : {}),
    ...(input.accentColor ? { accentColor: input.accentColor } : {}),
    continuation: { groupKey: input.continuationGroupKey },
  });
>>>>>>> upstream-sync-e8545b293-upstream-renamed

export const PiDriver: ProviderDriver<PiSettings, PiDriverEnv> = {
  driverKind: DRIVER_KIND,
  metadata: {
    displayName: "Pi",
    supportsMultipleInstances: true,
  },
  configSchema: PiSettings,
  defaultConfig: (): PiSettings => decodePiSettings({}),
  create: ({ instanceId, displayName, accentColor, environment, enabled, config }) =>
    Effect.gen(function* () {
      const spawner = yield* ChildProcessSpawner.ChildProcessSpawner;
<<<<<<< HEAD
      const httpClient = yield* HttpClient.HttpClient;
      const serverSettings = yield* ServerSettingsService;
      const eventLoggers = yield* ProviderEventLoggers;
      const serverConfig = yield* ServerConfig;
=======
      const fileSystem = yield* FileSystem.FileSystem;
      const pathService = yield* Path.Path;
      const httpClient = yield* HttpClient.HttpClient;
      const { cwd } = yield* ServerConfig.ServerConfig;
      const serverSettings = yield* ServerSettings.ServerSettingsService;
>>>>>>> upstream-sync-e8545b293-upstream-renamed
      const processEnv = mergeProviderInstanceEnvironment(environment);
      const continuationIdentity = defaultProviderContinuationIdentity({
        driverKind: DRIVER_KIND,
        instanceId,
      });
      const stampIdentity = withInstanceIdentity({
        instanceId,
<<<<<<< HEAD
        driverKind: DRIVER_KIND,
=======
>>>>>>> upstream-sync-e8545b293-upstream-renamed
        displayName,
        accentColor,
        continuationGroupKey: continuationIdentity.continuationKey,
      });
<<<<<<< HEAD
      const effectiveConfig = {
        ...config,
        enabled,
        binaryPath: expandHomePath(config.binaryPath),
      } satisfies PiSettings;

      // A proxied instance's models.json is derived from its settings, so it
      // is rewritten here, where every settings change passes through.
      yield* writePiProxyModelsFile(effectiveConfig, processEnv).pipe(
=======
      const effectiveConfig = { ...config, enabled } satisfies PiSettings;
      const resolveMaintenance = yield* makeCachedProviderMaintenanceResolution(
        resolveProviderMaintenanceCapabilitiesEffect(UPDATE, {
          binaryPath: effectiveConfig.binaryPath,
          env: processEnv,
        }).pipe(
          Effect.provideService(ChildProcessSpawner.ChildProcessSpawner, spawner),
          Effect.provideService(FileSystem.FileSystem, fileSystem),
          Effect.provideService(Path.Path, pathService),
        ),
      );

      const orchestrationAdapter = yield* PiAdapterV2Driver.create({
        instanceId,
        displayName,
        accentColor,
        environment,
        enabled,
        config,
      }).pipe(
>>>>>>> upstream-sync-e8545b293-upstream-renamed
        Effect.mapError(
          (cause) =>
            new ProviderDriverError({
              driver: DRIVER_KIND,
              instanceId,
<<<<<<< HEAD
              detail: `Failed to write Pi's models.json: ${cause.message}`,
=======
              detail: "Failed to build Pi orchestration adapter.",
>>>>>>> upstream-sync-e8545b293-upstream-renamed
              cause,
            }),
        ),
      );
<<<<<<< HEAD

      const adapter = yield* makePiAdapter(effectiveConfig, {
        instanceId,
        environment: processEnv,
        attachmentsDir: serverConfig.attachmentsDir,
        ...(eventLoggers.native ? { nativeEventLogger: eventLoggers.native } : {}),
      });

      const checkProvider = checkPiProviderStatus(effectiveConfig, processEnv).pipe(
=======
      const textGeneration = yield* makePiTextGeneration(effectiveConfig, processEnv);

      const checkProvider = checkPiProviderStatus(effectiveConfig, processEnv, cwd).pipe(
>>>>>>> upstream-sync-e8545b293-upstream-renamed
        Effect.map(stampIdentity),
        Effect.provideService(ChildProcessSpawner.ChildProcessSpawner, spawner),
      );

      const snapshotSettings = makeProviderSnapshotSettingsSource(effectiveConfig, serverSettings);
      const snapshot = yield* makeManagedServerProvider<ProviderSnapshotSettings<PiSettings>>({
<<<<<<< HEAD
        resolveMaintenance: () => Effect.succeed(MAINTENANCE_CAPABILITIES),
=======
        resolveMaintenance,
>>>>>>> upstream-sync-e8545b293-upstream-renamed
        getSettings: snapshotSettings.getSettings,
        streamSettings: snapshotSettings.streamSettings,
        haveSettingsChanged: haveProviderSnapshotSettingsChanged,
        initialSnapshot: (settings) =>
          buildInitialPiProviderSnapshot(settings.provider).pipe(Effect.map(stampIdentity)),
        checkProvider,
        enrichSnapshot: ({ settings, snapshot: currentSnapshot, publishSnapshot }) =>
<<<<<<< HEAD
          enrichPiSnapshot({
            snapshot: currentSnapshot,
            maintenanceCapabilities: MAINTENANCE_CAPABILITIES,
            enableProviderUpdateChecks: settings.enableProviderUpdateChecks,
            publishSnapshot,
            httpClient,
          }),
=======
          resolveMaintenance().pipe(
            Effect.flatMap((maintenanceCapabilities) =>
              enrichPiSnapshot({
                snapshot: currentSnapshot,
                maintenanceCapabilities,
                enableProviderUpdateChecks: settings.enableProviderUpdateChecks,
                publishSnapshot,
                httpClient,
              }),
            ),
          ),
>>>>>>> upstream-sync-e8545b293-upstream-renamed
      }).pipe(
        Effect.mapError(
          (cause) =>
            new ProviderDriverError({
              driver: DRIVER_KIND,
              instanceId,
<<<<<<< HEAD
              detail: `Failed to build Pi snapshot: ${cause.message ?? String(cause)}`,
=======
              detail: "Failed to build Pi snapshot.",
>>>>>>> upstream-sync-e8545b293-upstream-renamed
              cause,
            }),
        ),
      );

<<<<<<< HEAD
      const textGeneration = yield* makePiTextGeneration(effectiveConfig, processEnv);

=======
>>>>>>> upstream-sync-e8545b293-upstream-renamed
      return {
        instanceId,
        driverKind: DRIVER_KIND,
        continuationIdentity,
        displayName,
        accentColor,
        enabled,
        snapshot,
<<<<<<< HEAD
        adapter,
=======
        orchestrationAdapter,
>>>>>>> upstream-sync-e8545b293-upstream-renamed
        textGeneration,
      } satisfies ProviderInstance;
    }),
};
