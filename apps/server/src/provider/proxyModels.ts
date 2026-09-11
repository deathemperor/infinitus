import {
  ProviderProxyModelsError,
  type ProviderProxyModelsInput,
  type ProviderProxyModelsResult,
} from "@t3tools/contracts";
import * as Effect from "effect/Effect";
import * as Schema from "effect/Schema";
import { HttpClient, HttpClientRequest } from "effect/unstable/http";

/** OpenAI-style listing, which 9Router, CLIProxyAPI and Anthropic's own `/v1/models` all speak. */
const ModelsReply = Schema.Struct({
  data: Schema.Array(Schema.Struct({ id: Schema.String })),
});
const decodeModelsReply = Schema.decodeUnknownEffect(ModelsReply);

/**
 * Fork: list the models an Anthropic-compatible proxy serves at
 * `<baseUrl>/models`, so the add-instance wizard offers pickers for the
 * ANTHROPIC_DEFAULT_*_MODEL slots. The key goes out as both header spellings
 * proxies accept; error details never echo it.
 */
export const fetchProxyModels = Effect.fn("fetchProxyModels")(function* (
  input: ProviderProxyModelsInput,
): Effect.fn.Return<ProviderProxyModelsResult, ProviderProxyModelsError, HttpClient.HttpClient> {
  const client = yield* HttpClient.HttpClient;
  const url = yield* Effect.try({
    try: () => new URL(`${input.baseUrl.replace(/\/+$/, "")}/models`).toString(),
    catch: () => new ProviderProxyModelsError({ detail: "The base URL is not valid." }),
  });
  const request = HttpClientRequest.get(url).pipe(
    HttpClientRequest.setHeader("Authorization", `Bearer ${input.apiKey}`),
    HttpClientRequest.setHeader("x-api-key", input.apiKey),
  );
  const response = yield* client.execute(request).pipe(
    Effect.timeout("15 seconds"),
    Effect.mapError(() => new ProviderProxyModelsError({ detail: "The proxy did not answer." })),
  );
  if (response.status < 200 || response.status >= 300) {
    return yield* new ProviderProxyModelsError({
      detail: `The proxy answered ${response.status}.`,
    });
  }
  const body = yield* response.json.pipe(
    Effect.mapError(() => new ProviderProxyModelsError({ detail: "The proxy did not send JSON." })),
  );
  const reply = yield* decodeModelsReply(body).pipe(
    Effect.mapError(
      () =>
        new ProviderProxyModelsError({ detail: "The proxy's model list has an unexpected shape." }),
    ),
  );
  return { models: reply.data.map((model) => model.id) };
});
