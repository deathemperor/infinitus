import * as NodeServices from "@effect/platform-node/NodeServices";
import { expect, it } from "@effect/vitest";
import { ProviderInstanceId } from "@infinitus/contracts";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import { HttpClient } from "effect/unstable/http";
import * as ChildProcessSpawner from "effect/unstable/process/ChildProcessSpawner";

import * as BackgroundPolicy from "../../background/BackgroundPolicy.ts";
import { ServerConfig } from "../../config.ts";
import { ServerSettingsService } from "../../serverSettings.ts";
import { NoOpProviderEventLoggers, ProviderEventLoggers } from "../Layers/ProviderEventLoggers.ts";
import { OmpDriver } from "./OmpDriver.ts";

const testLayer = ServerConfig.layerTest(process.cwd(), {
  prefix: "t3-omp-driver-",
}).pipe(
  Layer.provideMerge(NodeServices.layer),
  Layer.provideMerge(ServerSettingsService.layerTest()),
  Layer.provideMerge(
    Layer.mock(BackgroundPolicy.BackgroundPolicy)({
      shouldRunScopeWork: () => Effect.succeed(false),
    }),
  ),
  Layer.provideMerge(Layer.succeed(ProviderEventLoggers, NoOpProviderEventLoggers)),
  Layer.provideMerge(
    Layer.succeed(
      HttpClient.HttpClient,
      HttpClient.make(() => Effect.die("Disabled Oh My Pi must not make an HTTP request")),
    ),
  ),
);

it.layer(testLayer)("OmpDriver", (it) => {
  it.effect("defaultConfig decodes enabled false and binaryPath omp", () =>
    Effect.sync(() => {
      expect(OmpDriver.defaultConfig()).toMatchObject({
        enabled: false,
        binaryPath: "omp",
      });
    }),
  );

  it.effect("stays manual-only and never spawns when disabled", () =>
    Effect.gen(function* () {
      const instance = yield* OmpDriver.create({
        instanceId: ProviderInstanceId.make("omp-disabled"),
        displayName: "Oh My Pi test",
        enabled: false,
        environment: [],
        config: OmpDriver.defaultConfig(),
      });
      expect((yield* instance.snapshot.resolveMaintenance()).update).toBeNull();
      expect((yield* instance.snapshot.refresh).status).toBe("disabled");
    }).pipe(
      Effect.provideService(
        ChildProcessSpawner.ChildProcessSpawner,
        ChildProcessSpawner.make(() => Effect.die("Disabled Oh My Pi must not spawn a process")),
      ),
      Effect.scoped,
    ),
  );
});
