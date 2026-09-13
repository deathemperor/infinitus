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
 * The listing URL for a base URL that is what `ANTHROPIC_BASE_URL` takes: the
 * SDK appends `/v1/messages` to it, so the models live at `<base>/v1/models`.
 * A base URL a user typed with `/v1` already on it means the same proxy, so
 * the version segment is added only when it is not there.
 */
function proxyModelsUrl(baseUrl: string): string {
  const base = baseUrl.trim().replace(/\/+$/, "");
  return new URL(base.endsWith("/v1") ? `${base}/models` : `${base}/v1/models`).toString();
}

/**
 * Fork: list the models an Anthropic-compatible proxy serves at
 * `<baseUrl>/v1/models`, so the add-instance wizard offers pickers for the
 * ANTHROPIC_DEFAULT_*_MODEL slots. The key goes out as both header spellings
 * proxies accept; error details never echo it.
 */
export const fetchProxyModels = Effect.fn("fetchProxyModels")(function* (
  input: ProviderProxyModelsInput,
): Effect.fn.Return<ProviderProxyModelsResult, ProviderProxyModelsError, HttpClient.HttpClient> {
  const client = yield* HttpClient.HttpClient;
  const url = yield* Effect.try({
    try: () => proxyModelsUrl(input.baseUrl),
    catch: () => new ProviderProxyModelsError({ detail: "The base URL is not valid." }),
  });
  const request = HttpClientRequest.get(url).pipe(
    HttpClientRequest.setHeader("Authorization", `Bearer ${input.apiKey}`),
    HttpClientRequest.setHeader("x-api-key", input.apiKey),
  );
  const body = yield* client.execute(request).pipe(
    Effect.flatMap((response) =>
      response.status >= 200 && response.status < 300
        ? response.json.pipe(
            Effect.mapError(
              () => new ProviderProxyModelsError({ detail: "The proxy did not send JSON." }),
            ),
          )
        : Effect.fail(
            new ProviderProxyModelsError({ detail: `The proxy answered ${response.status}.` }),
          ),
    ),
    Effect.timeout("15 seconds"),
    Effect.catchTag("TimeoutError", () =>
      Effect.fail(new ProviderProxyModelsError({ detail: "The proxy did not answer in time." })),
    ),
    Effect.catchTag("HttpClientError", () =>
      Effect.fail(new ProviderProxyModelsError({ detail: "The proxy did not answer." })),
    ),
  );
  const reply = yield* decodeModelsReply(body).pipe(
    Effect.mapError(
      () =>
        new ProviderProxyModelsError({ detail: "The proxy's model list has an unexpected shape." }),
    ),
  );
  return { models: reply.data.map((model) => model.id) };
});
