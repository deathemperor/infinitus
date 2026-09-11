import * as Schema from "effect/Schema";

import { TrimmedNonEmptyString } from "./baseSchemas.ts";

/**
 * Fork: the add-instance wizard asks the server to list the models an
 * Anthropic-compatible proxy (9Router, CLIProxyAPI, …) serves, so the
 * ANTHROPIC_DEFAULT_*_MODEL slots can be picked instead of typed. The key
 * travels once, in this payload, and is never stored server-side by this call.
 */
export const ProviderProxyModelsInput = Schema.Struct({
  /** Anthropic-compatible base URL, e.g. `http://127.0.0.1:20128/v1`. */
  baseUrl: TrimmedNonEmptyString,
  apiKey: Schema.String,
});
export type ProviderProxyModelsInput = typeof ProviderProxyModelsInput.Type;

export const ProviderProxyModelsResult = Schema.Struct({
  models: Schema.Array(Schema.String),
});
export type ProviderProxyModelsResult = typeof ProviderProxyModelsResult.Type;

export class ProviderProxyModelsError extends Schema.TaggedError<ProviderProxyModelsError>()(
  "ProviderProxyModelsError",
  { detail: Schema.String },
) {}
