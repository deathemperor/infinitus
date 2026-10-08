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
import * as Option from "effect/Option";
import * as Path from "effect/Path";
import * as Schema from "effect/Schema";

import { expandHomePath } from "../../pathExpansion.ts";

const PI_PROXY_BASE_URL_VAR = "PI_PROXY_BASE_URL";
const PI_PROXY_API_KEY_VAR = "PI_PROXY_API_KEY";
/** Pi provider id the proxy's models live under, so a slug reads `proxy/<id>`. */
const PI_PROXY_PROVIDER = "proxy";

const decodeModelsFile = Schema.decodeUnknownOption(
  Schema.fromJsonString(Schema.Record(Schema.String, Schema.Unknown)),
);

/**
 * The `proxy` provider entry, or nothing when the instance has no proxy. Only
 * custom models under the `proxy/` prefix belong to it: a hand-typed
 * `anthropic/<id>` would otherwise be declared as a proxy model.
 */
export function piProxyProvider(environment: NodeJS.ProcessEnv, customModels: unknown) {
  const baseUrl = environment[PI_PROXY_BASE_URL_VAR]?.trim().replace(/\/+$/, "");
  if (!baseUrl) return undefined;
  const prefix = `${PI_PROXY_PROVIDER}/`;
  return {
    baseUrl: baseUrl.endsWith("/v1") ? baseUrl : `${baseUrl}/v1`,
    api: "openai-completions",
    apiKey: `$${PI_PROXY_API_KEY_VAR}`,
    models: readCustomModelEntries(customModels)
      .filter((entry) => entry.slug.startsWith(prefix))
      .map((entry) => ({ id: entry.slug.slice(prefix.length) })),
  };
}

/**
 * The file's next content. Only the `proxy` key is ours: a home the user
 * typed may already hold a models.json with providers of their own, which
 * stay. Nothing when the existing file is not a JSON object, so a file we
 * cannot read is never replaced.
 */
export function mergePiProxyModelsJson(
  existing: string | undefined,
  provider: NonNullable<ReturnType<typeof piProxyProvider>>,
): string | undefined {
  const file =
    existing === undefined ? Option.some<Record<string, unknown>>({}) : decodeModelsFile(existing);
  if (Option.isNone(file)) return undefined;
  const providers = file.value.providers;
  if (providers !== undefined && (providers === null || typeof providers !== "object")) {
    return undefined;
  }
  return JSON.stringify(
    { ...file.value, providers: { ...providers, [PI_PROXY_PROVIDER]: provider } },
    null,
    2,
  );
}

/**
 * Materialise the file in the instance's own home and answer its path. An
 * instance on Pi's default home is left alone: that directory is the user's.
 */
export const writePiProxyModelsFile = Effect.fn("writePiProxyModelsFile")(function* (
  settings: { readonly homePath: string; readonly customModels: unknown },
  environment: NodeJS.ProcessEnv,
) {
  const provider = piProxyProvider(environment, settings.customModels);
  if (provider === undefined) return undefined;
  const homePath = settings.homePath.trim();
  if (homePath.length === 0) {
    yield* Effect.logWarning(
      "Pi proxy instance has no config directory of its own; models.json not written.",
    );
    return undefined;
  }
  const fileSystem = yield* FileSystem.FileSystem;
  const path = yield* Path.Path;
  const directory = expandHomePath(homePath);
  const filePath = path.join(directory, "models.json");
  const existing = (yield* fileSystem.exists(filePath))
    ? yield* fileSystem.readFileString(filePath)
    : undefined;
  const content = mergePiProxyModelsJson(existing, provider);
  if (content === undefined) {
    yield* Effect.logWarning("Pi's models.json is not a JSON object; proxy provider not added.", {
      filePath,
    });
    return undefined;
  }
  yield* fileSystem.makeDirectory(directory, { recursive: true });
  yield* fileSystem.writeFileString(filePath, content);
  return filePath;
});
