import {
  RelayAgentActivityPublishProofExpiredError,
  RelayAgentActivityPublishProofInvalidError,
  RelayApi,
  RelayAuthInvalidError,
  RelayEnvironmentPrincipal,
  RelayInternalError,
} from "@infinitus/contracts/relay";
import * as Effect from "effect/Effect";
import * as HttpApiBuilder from "effect/unstable/httpapi/HttpApiBuilder";

import * as InfinitusAlertPublisher from "./InfinitusAlertPublisher.ts";

const currentTraceId = Effect.currentParentSpan.pipe(
  Effect.map((span) => span.traceId),
  Effect.orElseSucceed(() => "unavailable"),
);

const failWithTrace = <E>(make: (traceId: string) => E) =>
  currentTraceId.pipe(Effect.flatMap((traceId) => Effect.fail(make(traceId))));

/**
 * `POST /v1/environments/:environmentId/alerts` (#1375): the handler half of
 * `InfinitusAlertPublisher`, wired beside upstream's `serverApi`. Answers on
 * the wire with the agent-activity publish errors so the server's generated
 * relay client already understands every status.
 */
export const infinitusAlertApi = HttpApiBuilder.group(
  RelayApi,
  "infinitusAlert",
  Effect.fnUntraced(function* (handlers) {
    const publisher = yield* InfinitusAlertPublisher.InfinitusAlertPublisher;
    return handlers.handle(
      "publishInfinitusAlert",
      Effect.fn("relay.api.infinitus_alert.publish")(function* ({ params, payload }) {
        const principal = yield* RelayEnvironmentPrincipal;
        if (principal.environmentId !== params.environmentId) {
          return yield* failWithTrace(
            (traceId) =>
              new RelayAuthInvalidError({
                code: "auth_invalid",
                reason: "not_authorized",
                traceId,
              }),
          );
        }
        return yield* publisher
          .publish({
            environmentId: params.environmentId,
            environmentPublicKey: principal.environmentPublicKey,
            request: payload,
          })
          .pipe(
            Effect.catchTags({
              InfinitusAlertProofExpired: () =>
                failWithTrace(
                  (traceId) =>
                    new RelayAgentActivityPublishProofExpiredError({
                      code: "agent_activity_publish_proof_expired",
                      traceId,
                    }),
                ),
              InfinitusAlertProofInvalid: (error) =>
                failWithTrace(
                  (traceId) =>
                    new RelayAgentActivityPublishProofInvalidError({
                      code: "agent_activity_publish_proof_invalid",
                      reason:
                        error.stage === "consume_nonce"
                          ? "replayed_nonce"
                          : "invalid_signature_or_payload",
                      traceId,
                    }),
                ),
              InfinitusAlertPublishFailed: (error) =>
                failWithTrace(
                  (traceId) =>
                    new RelayInternalError({
                      code: "internal_error",
                      reason: error.stage === "enqueue" ? "internal_error" : "persistence_failed",
                      traceId,
                    }),
                ),
            }),
          );
      }),
    );
  }),
);
