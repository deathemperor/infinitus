/**
 * piProxyHome — the `models.json` a Pi instance routed through a proxy needs.
 *
 * Fork: the add-instance wizard's "Route through a proxy" stores the proxy on
 * the ordinary instance, as it does for Claude: `PI_PROXY_BASE_URL` and the
 * sensitive `PI_PROXY_API_KEY` in the instance environment, a dedicated
 * `homePath`, and the picked models as `proxy/<id>` custom models. Pi reads
 * none of those itself; it reads `<home>/models.json`, so the driver writes
 * that file from them before anything spawns. The key goes in as `$VAR`,
 * which Pi resolves from the environment at request time, so the secret
 * stays in the settings store and never on disk.
 *
 * @module provider/Layers/piProxyHome
 */
import { readCustomModelEntries } from "@infinitus/shared/model";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Path from "effect/Path";

import { expandHomePath } from "../../pathExpansion.ts";

export const PI_PROXY_BASE_URL_VAR = "PI_PROXY_BASE_URL";
export const PI_PROXY_API_KEY_VAR = "PI_PROXY_API_KEY";
/** Pi provider id the proxy's models live under, so a slug reads `proxy/<id>`. */
export const PI_PROXY_PROVIDER = "proxy";

/**
 * The file's content, or nothing when the instance has no proxy. Only custom
 * models under the `proxy/` prefix belong to it: a hand-typed
 * `anthropic/<id>` would otherwise be declared as a proxy model and, worse,
 * shadow Pi's built-in provider of that name.
 */
export function piProxyModelsJson(
  environment: NodeJS.ProcessEnv,
  customModels: unknown,
): string | undefined {
  const baseUrl = environment[PI_PROXY_BASE_URL_VAR]?.trim().replace(/\/+$/, "");
  if (!baseUrl) return undefined;
  const prefix = `${PI_PROXY_PROVIDER}/`;
  const models = readCustomModelEntries(customModels)
    .filter((entry) => entry.slug.startsWith(prefix))
    .map((entry) => ({ id: entry.slug.slice(prefix.length) }));
  return JSON.stringify(
    {
      providers: {
        [PI_PROXY_PROVIDER]: {
          baseUrl: baseUrl.endsWith("/v1") ? baseUrl : `${baseUrl}/v1`,
          api: "openai-completions",
          apiKey: `$${PI_PROXY_API_KEY_VAR}`,
          models,
        },
      },
    },
    null,
    2,
  );
}

/**
 * Materialise the file in the instance's own home. An instance whose home is
 * Pi's default is left alone: that is the user's real config directory.
 */
export const writePiProxyModelsFile = Effect.fn("writePiProxyModelsFile")(function* (
  settings: { readonly homePath: string; readonly customModels: unknown },
  environment: NodeJS.ProcessEnv,
) {
  const content = piProxyModelsJson(environment, settings.customModels);
  if (content === undefined) return;
  const homePath = settings.homePath.trim();
  if (homePath.length === 0) {
    yield* Effect.logWarning(
      "Pi proxy instance has no config directory of its own; models.json not written.",
    );
    return;
  }
  const fileSystem = yield* FileSystem.FileSystem;
  const path = yield* Path.Path;
  const directory = expandHomePath(homePath);
  yield* fileSystem.makeDirectory(directory, { recursive: true });
  yield* fileSystem.writeFileString(path.join(directory, "models.json"), content);
});
