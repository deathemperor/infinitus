import { RelayApi } from "@infinitus/contracts/relay";
import {
  RELAY_INFINITUS_ALERT_TYP,
  type RelayInfinitusAlertProofPayload,
} from "@infinitus/contracts/relayInfinitusAlert";
import { normalizeRelayIssuer, signRelayJwt } from "@infinitus/shared/relayJwt";
import * as Crypto from "effect/Crypto";
import * as DateTime from "effect/DateTime";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";
import * as HttpApiClient from "effect/unstable/httpapi/HttpApiClient";
import { HttpClient, HttpClientRequest } from "effect/unstable/http";

import * as ServerSecretStore from "../../auth/ServerSecretStore.ts";
import {
  RELAY_ENVIRONMENT_CREDENTIAL_SECRET,
  RELAY_ISSUER_SECRET,
  RELAY_URL_SECRET,
} from "../../cloud/config.ts";
import { getOrCreateEnvironmentKeyPairFromSecretStore } from "../../cloud/environmentKeys.ts";
import { ServerEnvironment } from "../../environment/ServerEnvironment.ts";
import {
  InfinitusAlertRelay,
  InfinitusAlertRelayFailed,
  InfinitusAlertRelayUnlinked,
} from "../Services/InfinitusAlertRelay.ts";

/** Where a tapped alert lands on the phone: Settings › Accounts. The relay
    forwards the path; the phone validates it against its own routes. */
export const INFINITUS_ALERT_DEEP_LINK = "/settings/accounts";

/**
 * The server half of an account alert (#1375): the Mac posts one line to
 * `POST /api/infinitus/alert`, this layer signs it with the environment's
 * link key — the same key and claims `AgentAwarenessRelay` publishes thread
 * activity with, the alert in place of the state — and hands it to the
 * relay's alert route, which pushes it with the relay's own APNs key. The
 * link is read on every call, as the activity publisher reads it, so
 * linking or unlinking takes effect at the next alert; unlinked answers
 * `InfinitusAlertRelayUnlinked` and the Mac keeps the notice local.
 */
export const InfinitusAlertRelayLive = Layer.effect(
  InfinitusAlertRelay,
  Effect.gen(function* () {
    const secrets = yield* ServerSecretStore.ServerSecretStore;
    const serverEnvironment = yield* ServerEnvironment;
    const crypto = yield* Crypto.Crypto;
    const httpClient = yield* HttpClient.HttpClient;

    const readSecretString = (name: string) =>
      secrets.get(name).pipe(
        Effect.map((bytes) =>
          Option.isSome(bytes) ? new TextDecoder().decode(bytes.value) : null,
        ),
        Effect.orElseSucceed(() => null),
      );

    const readRelayLink = Effect.gen(function* () {
      const [url, issuer, credential] = yield* Effect.all([
        readSecretString(RELAY_URL_SECRET),
        readSecretString(RELAY_ISSUER_SECRET),
        readSecretString(RELAY_ENVIRONMENT_CREDENTIAL_SECRET),
      ]);
      return url && credential ? { url, issuer: issuer ?? url, credential } : null;
    });

    return InfinitusAlertRelay.of({
      publish: Effect.fn("InfinitusAlertRelay.publish")(function* (input) {
        const link = yield* readRelayLink;
        if (link === null) return yield* new InfinitusAlertRelayUnlinked();
        const keyPair = yield* getOrCreateEnvironmentKeyPairFromSecretStore(secrets).pipe(
          Effect.mapError((cause) => new InfinitusAlertRelayFailed({ stage: "key_pair", cause })),
        );
        const environmentId = yield* serverEnvironment.getEnvironmentId;
        const alert = { title: input.title, body: input.body, deepLink: INFINITUS_ALERT_DEEP_LINK };
        const now = yield* DateTime.now;
        const jti = yield* crypto.randomUUIDv4.pipe(
          Effect.mapError((cause) => new InfinitusAlertRelayFailed({ stage: "sign", cause })),
        );
        const payload = {
          iss: `t3-env:${environmentId}`,
          aud: normalizeRelayIssuer(link.issuer),
          sub: environmentId,
          jti,
          iat: Math.floor(now.epochMilliseconds / 1_000),
          exp: Math.floor(DateTime.add(now, { minutes: 5 }).epochMilliseconds / 1_000),
          environmentId,
          alert,
        } satisfies RelayInfinitusAlertProofPayload;
        const proof = yield* signRelayJwt({
          privateKey: keyPair.privateKey,
          typ: RELAY_INFINITUS_ALERT_TYP,
          payload,
        }).pipe(
          Effect.mapError((cause) => new InfinitusAlertRelayFailed({ stage: "sign", cause })),
        );
        const client = yield* HttpApiClient.make(RelayApi, {
          baseUrl: link.url,
          transformClient: HttpClient.mapRequest(
            HttpClientRequest.setHeader("authorization", `Bearer ${link.credential}`),
          ),
        }).pipe(Effect.provideService(HttpClient.HttpClient, httpClient));
        const response = yield* client.infinitusAlert
          .publishInfinitusAlert({ params: { environmentId }, payload: { alert, proof } })
          .pipe(
            Effect.mapError((cause) => new InfinitusAlertRelayFailed({ stage: "publish", cause })),
          );
        yield* Effect.logInfo("infinitus.alert.published", {
          deliveries: response.deliveries.length,
          ok: response.ok,
        });
        return { deliveries: response.deliveries.length };
      }),
    });
  }),
);
