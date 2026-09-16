import * as NodeServices from "@effect/platform-node/NodeServices";
import { EnvironmentId } from "@t3tools/contracts";
import {
  RELAY_INFINITUS_ALERT_TYP,
  RelayInfinitusAlertProofPayload,
} from "@t3tools/contracts/relayInfinitusAlert";
import { verifyRelayJwt } from "@t3tools/shared/relayJwt";
import { describe, expect, it } from "@effect/vitest";
import * as DateTime from "effect/DateTime";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";
import * as Schema from "effect/Schema";
import { HttpClient, HttpClientResponse } from "effect/unstable/http";

import * as ServerSecretStore from "../../auth/ServerSecretStore.ts";
import {
  RELAY_ENVIRONMENT_CREDENTIAL_SECRET,
  RELAY_ISSUER_SECRET,
  RELAY_URL_SECRET,
} from "../../cloud/config.ts";
import { getOrCreateEnvironmentKeyPairFromSecretStore } from "../../cloud/environmentKeys.ts";
import { ServerEnvironment } from "../../environment/ServerEnvironment.ts";
import { InfinitusAlertRelay } from "../Services/InfinitusAlertRelay.ts";
import { INFINITUS_ALERT_DEEP_LINK, InfinitusAlertRelayLive } from "./InfinitusAlertRelay.ts";

const environmentId = EnvironmentId.make("env-1");
const decodeProof = Schema.decodeUnknownEffect(RelayInfinitusAlertProofPayload);
const decodeBody = Schema.decodeUnknownSync(Schema.fromJsonString(Schema.Unknown));

function memorySecretStore(seed: Record<string, string>) {
  const values = new Map<string, Uint8Array>(
    Object.entries(seed).map(([name, value]) => [name, new TextEncoder().encode(value)]),
  );
  const store: ServerSecretStore.ServerSecretStore["Service"] = {
    get: (name) => Effect.sync(() => Option.fromNullishOr(values.get(name))),
    set: (name, value) => Effect.sync(() => void values.set(name, Uint8Array.from(value))),
    create: (name, value) => Effect.sync(() => void values.set(name, Uint8Array.from(value))),
    getOrCreateRandom: (name, bytes) =>
      Effect.sync(() => {
        const existing = values.get(name);
        if (existing) return existing;
        const generated = new Uint8Array(bytes);
        values.set(name, generated);
        return generated;
      }),
    remove: (name) => Effect.sync(() => void values.delete(name)),
  };
  return store;
}

function harness(input: { readonly linked: boolean; readonly status?: number }) {
  const requests: Array<{ url: string; authorization: string | undefined; body: unknown }> = [];
  const secrets = memorySecretStore(
    input.linked
      ? {
          [RELAY_URL_SECRET]: "https://relay.example.test",
          [RELAY_ISSUER_SECRET]: "https://relay.example.test/",
          [RELAY_ENVIRONMENT_CREDENTIAL_SECRET]: "env-credential",
        }
      : {},
  );
  const http = HttpClient.make((request) =>
    Effect.gen(function* () {
      const body =
        request.body._tag === "Uint8Array"
          ? decodeBody(new TextDecoder().decode(request.body.body))
          : null;
      requests.push({
        url: request.url,
        authorization: request.headers["authorization"],
        body,
      });
      return HttpClientResponse.fromWeb(
        request,
        input.status === undefined
          ? Response.json({
              ok: true,
              deliveries: [
                {
                  deviceId: "phone",
                  kind: "push_notification",
                  ok: true,
                  queued: true,
                  apnsStatus: null,
                  apnsReason: null,
                  apnsId: null,
                },
                {
                  deviceId: "droid",
                  kind: "push_notification",
                  ok: true,
                  queued: true,
                  apnsStatus: null,
                  apnsReason: null,
                  apnsId: null,
                },
              ],
            })
          : Response.json(
              {
                _tag: "RelayInternalError",
                code: "internal_error",
                reason: "internal_error",
                traceId: "t",
              },
              { status: input.status },
            ),
      );
    }),
  );
  const layer = InfinitusAlertRelayLive.pipe(
    Layer.provide(
      Layer.mergeAll(
        Layer.succeed(ServerSecretStore.ServerSecretStore, secrets),
        Layer.succeed(ServerEnvironment, {
          getEnvironmentId: Effect.succeed(environmentId),
          getDescriptor: Effect.die("unused"),
        }),
        Layer.succeed(HttpClient.HttpClient, http),
      ),
    ),
    Layer.provideMerge(NodeServices.layer),
  );
  return { requests, secrets, layer };
}

const publish = Effect.gen(function* () {
  const relay = yield* InfinitusAlertRelay;
  return yield* relay.publish({ title: "Infinitus", body: "switched to account 2 (work)" });
});

describe("InfinitusAlertRelayLive (#1375)", () => {
  it.effect("signs the alert with the link key and posts it to the relay's alert route", () => {
    const h = harness({ linked: true });
    return Effect.gen(function* () {
      expect(yield* publish).toEqual({ deliveries: 2 });
      expect(h.requests).toHaveLength(1);
      const request = h.requests[0]!;
      expect(request.url).toBe("https://relay.example.test/v1/environments/env-1/alerts");
      expect(request.authorization).toBe("Bearer env-credential");
      const body = request.body as { alert: unknown; proof: string };
      expect(body.alert).toEqual({
        title: "Infinitus",
        body: "switched to account 2 (work)",
        deepLink: INFINITUS_ALERT_DEEP_LINK,
      });
      // The proof verifies with the key the store now holds and binds the alert.
      const keyPair = yield* getOrCreateEnvironmentKeyPairFromSecretStore(h.secrets);
      const now = yield* DateTime.now;
      const proof = yield* verifyRelayJwt({
        publicKey: keyPair.publicKey,
        token: body.proof,
        typ: RELAY_INFINITUS_ALERT_TYP,
        issuer: "t3-env:env-1",
        audience: "https://relay.example.test",
        nowEpochSeconds: Math.floor(now.epochMilliseconds / 1_000),
      }).pipe(Effect.flatMap(decodeProof));
      expect(proof.environmentId).toBe("env-1");
      expect(proof.sub).toBe("env-1");
      expect(proof.alert).toEqual(body.alert);
      expect(proof.exp - proof.iat).toBe(300);
    }).pipe(Effect.provide(h.layer));
  });

  it.effect("answers unlinked without touching the relay when no link is stored", () => {
    const h = harness({ linked: false });
    return Effect.gen(function* () {
      const error = yield* Effect.flip(publish);
      expect(error._tag).toBe("InfinitusAlertRelayUnlinked");
      expect(h.requests).toHaveLength(0);
    }).pipe(Effect.provide(h.layer));
  });

  it.effect("reports a relay refusal as a publish failure", () => {
    const h = harness({ linked: true, status: 500 });
    return Effect.gen(function* () {
      const error = yield* Effect.flip(publish);
      expect(error._tag).toBe("InfinitusAlertRelayFailed");
      if (error._tag === "InfinitusAlertRelayFailed") expect(error.stage).toBe("publish");
    }).pipe(Effect.provide(h.layer));
  });
});
