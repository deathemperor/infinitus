import {
  AuthOrchestrationOperateScope,
  AuthOrchestrationReadScope,
  EnvironmentHttpApi,
} from "@infinitus/contracts";
import * as Effect from "effect/Effect";
import * as Option from "effect/Option";
import * as HttpApiBuilder from "effect/http-api/HttpApiBuilder";

import { resolveProjectSettings } from "@infinitus/shared/projectSettings";

import {
  annotateEnvironmentRequest,
  failEnvironmentInternal,
  requireEnvironmentScope,
} from "../../auth/http.ts";
import * as ProjectStore from "../../orchestration-v2/ProjectStore.ts";
import { ServerSettingsService } from "../../serverSettings.ts";
import { InfinitusAlertRelay } from "../Services/InfinitusAlertRelay.ts";

/**
 * Fork: `infinitusctl`'s reads over plain HTTP. `threadDefaults` (#1315) is
 * the composer's own model resolution; `alert` (#1375) is the Mac's account
 * alert on its way to the phones. The holds, running-turns and release reads
 * left with the engine-bound session gates (#1627).
 */
export const infinitusHttpApiLayer = HttpApiBuilder.group(
  EnvironmentHttpApi,
  "infinitus",
  Effect.fnUntraced(function* (handlers) {
    const settings = yield* ServerSettingsService;
    const projects = yield* ProjectStore.ProjectStoreV2;
    const alerts = yield* InfinitusAlertRelay;
    return handlers
      .handle(
        "threadDefaults",
        Effect.fn("environment.infinitus.threadDefaults")(function* (args) {
          yield* annotateEnvironmentRequest(args.endpoint.name);
          yield* requireEnvironmentScope(AuthOrchestrationReadScope);
          // #1315: the composer's own resolution — the project's override,
          // the row's default until the fold, then the environment's. A
          // settings or projection read that fails is the server's own state
          // gone wrong, not a request the CLI can fix — die, don't 500.
          const current = yield* settings.getSettings.pipe(Effect.orDie);
          const projectId = args.query.projectId ?? null;
          const project =
            projectId === null
              ? null
              : Option.getOrNull(yield* projects.getShell(projectId).pipe(Effect.orDie));
          const resolved = resolveProjectSettings(current, projectId, project).settings;
          return { defaultModelSelection: resolved.defaultModelSelection ?? null };
        }),
      )
      .handle(
        "alert",
        // #1375: the Mac's account alert, on the desktop credential's operate
        // scope. Unlinked is the Mac's to handle (503); a relay that refused
        // is this server's link gone wrong — logged with its cause, 500.
        Effect.fn("environment.infinitus.alert")(function* (args) {
          yield* annotateEnvironmentRequest(args.endpoint.name);
          yield* requireEnvironmentScope(AuthOrchestrationOperateScope);
          return yield* alerts
            .publish(args.payload)
            .pipe(
              Effect.catchTag("InfinitusAlertRelayFailed", (error) =>
                failEnvironmentInternal("internal_error", error),
              ),
            );
        }),
      );
  }),
);
