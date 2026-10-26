import * as Schema from "effect/Schema";

import { EnvironmentId, TrimmedNonEmptyString } from "./baseSchemas.ts";

/**
 * An account alert an Infinitus environment asks the relay to push to every phone
 * linked to it (#1375). Thread-less, so its own route beside
 * `publishAgentActivity`; the proof is the same environment-signed JWT shape.
 */
export const RELAY_INFINITUS_ALERT_TYP = "infinitus-env-alert+jwt";

export const RelayInfinitusAlert = Schema.Struct({
  title: TrimmedNonEmptyString,
  body: TrimmedNonEmptyString,
  /** An app path the tap opens; the phone validates it against its routes. */
  deepLink: TrimmedNonEmptyString,
});
export type RelayInfinitusAlert = typeof RelayInfinitusAlert.Type;

export const RelayInfinitusAlertProofPayload = Schema.Struct({
  iss: TrimmedNonEmptyString,
  aud: TrimmedNonEmptyString,
  sub: TrimmedNonEmptyString,
  jti: TrimmedNonEmptyString,
  iat: Schema.Int,
  exp: Schema.Int,
  environmentId: EnvironmentId,
  alert: RelayInfinitusAlert,
});
export type RelayInfinitusAlertProofPayload = typeof RelayInfinitusAlertProofPayload.Type;

export const RelayInfinitusAlertRequest = Schema.Struct({
  alert: RelayInfinitusAlert,
  proof: TrimmedNonEmptyString.annotate({
    description: "Environment-signed JWT covering this alert.",
  }),
}).annotate({ description: "Publishes a signed account alert from an Infinitus environment." });
export type RelayInfinitusAlertRequest = typeof RelayInfinitusAlertRequest.Type;
