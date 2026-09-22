import * as NodeCrypto from "node:crypto";
import * as NodeServices from "@effect/platform-node/NodeServices";
import type { RelayDeliveryResult } from "@infinitus/contracts/relay";
import {
  RELAY_INFINITUS_ALERT_TYP,
  type RelayInfinitusAlert,
  type RelayInfinitusAlertProofPayload,
  type RelayInfinitusAlertRequest,
} from "@infinitus/contracts/relayInfinitusAlert";
import { describe, expect, it } from "@effect/vitest";
import * as DateTime from "effect/DateTime";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Redacted from "effect/Redacted";

import * as ApnsDeliveryQueue from "../agentActivity/ApnsDeliveryQueue.ts";
import * as FcmDeliveryQueueSender from "../agentActivity/FcmDeliveryQueueSender.ts";
import type { FcmDeliveryJob } from "../agentActivity/FcmDeliveries.ts";
import * as LiveActivities from "../agentActivity/LiveActivities.ts";
import * as DpopProofs from "../auth/DpopProofs.ts";
import * as RelayConfiguration from "../Config.ts";
import * as EnvironmentLinks from "../environments/EnvironmentLinks.ts";
import * as InfinitusAlertPublisher from "./InfinitusAlertPublisher.ts";

const keyPair = NodeCrypto.generateKeyPairSync("ed25519", {
  privateKeyEncoding: { format: "pem", type: "pkcs8" },
  publicKeyEncoding: { format: "pem", type: "spki" },
});
const config = RelayConfiguration.RelayConfiguration.of({
  relayIssuer: "https://relay.example.test",
  apns: {
    environment: "sandbox",
    teamId: "team-id",
    keyId: "key-id",
    privateKey: Redacted.make("private-key"),
    bundleId: "run.infinitus.mobile",
  },
  fcmServiceAccount: Redacted.make("configured"),
  apnsDeliveryJobSigningSecret: Redacted.make("job-secret"),
  clerkSecretKey: Redacted.make("clerk-secret"),
  clerkPublishableKey: "pk_test_test",
  clerkJwtAudience: "infinitus-relay",
  cloudMintPrivateKey: Redacted.make(keyPair.privateKey),
  cloudMintPublicKey: keyPair.publicKey,
  managedEndpointBaseDomain: undefined,
  managedEndpointNamespace: undefined,
});
const environmentId = "env-1";
const alert: RelayInfinitusAlert = {
  title: "Infinitus",
  body: "switched to account 2 (work)",
  deepLink: "/settings/accounts",
};

function signTestJwt(payload: object, privateKey: string): string {
  const header = Buffer.from(
    JSON.stringify({ alg: "EdDSA", typ: RELAY_INFINITUS_ALERT_TYP }),
  ).toString("base64url");
  const encodedPayload = Buffer.from(JSON.stringify(payload)).toString("base64url");
  const signingInput = `${header}.${encodedPayload}`;
  return `${signingInput}.${NodeCrypto.sign(null, Buffer.from(signingInput), privateKey).toString("base64url")}`;
}

const request = (overrides: Partial<RelayInfinitusAlertProofPayload> = {}) =>
  Effect.gen(function* () {
    const now = yield* DateTime.now;
    const payload = {
      iss: `t3-env:${environmentId}`,
      aud: "https://relay.example.test",
      sub: environmentId,
      jti: "alert-jti",
      iat: Math.floor(now.epochMilliseconds / 1_000),
      exp: Math.floor(DateTime.add(now, { minutes: 5 }).epochMilliseconds / 1_000),
      environmentId: environmentId as RelayInfinitusAlertProofPayload["environmentId"],
      alert,
      ...overrides,
    } satisfies RelayInfinitusAlertProofPayload;
    return {
      alert,
      proof: signTestJwt(payload, keyPair.privateKey),
    } satisfies RelayInfinitusAlertRequest;
  });

function target(input: {
  readonly deviceId: string;
  readonly platform: "ios" | "android";
  readonly pushToken: string | null;
  readonly userId?: string;
}): LiveActivities.TargetRow {
  return {
    user_id: input.userId ?? "user:one",
    device_id: input.deviceId,
    platform: input.platform,
    ios_major_version: input.platform === "ios" ? 18 : null,
    app_version: "1.0.0",
    bundle_id: "run.infinitus.mobile",
    aps_environment: "sandbox",
    push_token: input.pushToken,
    push_to_start_token: null,
    preferences_json: "{}",
    activity_push_token: null,
    remote_start_queued_at: null,
    remote_started_at: null,
    ended_at: null,
    last_aggregate_json: null,
    last_live_activity_delivery_at: null,
  };
}

function harness(input?: {
  readonly users?: ReadonlyArray<EnvironmentLinks.AgentAwarenessDeliveryUserRecord>;
  readonly targets?: Record<string, ReadonlyArray<LiveActivities.TargetRow>>;
  readonly consume?: DpopProofs.DpopProofReplay["Service"]["consume"];
}) {
  const apns: Array<
    Parameters<ApnsDeliveryQueue.ApnsDeliveryQueue["Service"]["enqueuePushNotification"]>[0]
  > = [];
  const fcm: FcmDeliveryJob[] = [];
  const consumed: Array<{ thumbprint: string; jti: string }> = [];
  const users = input?.users ?? [
    { userId: "user:one", notificationsEnabled: true, liveActivitiesEnabled: true },
  ];
  const targets = input?.targets ?? {
    "user:one": [
      target({ deviceId: "phone", platform: "ios", pushToken: "apns-token" }),
      target({ deviceId: "droid", platform: "android", pushToken: "fcm-token" }),
      target({ deviceId: "watch", platform: "ios", pushToken: null }),
    ],
  };
  const layer = InfinitusAlertPublisher.layer.pipe(
    Layer.provide(
      Layer.mergeAll(
        RelayConfiguration.layer(config),
        Layer.succeed(DpopProofs.DpopProofReplay, {
          verifyAndConsume: () => Effect.die("unexpected DPoP proof verification"),
          consume:
            input?.consume ??
            ((row) =>
              Effect.sync(() => {
                consumed.push({ thumbprint: row.thumbprint, jti: row.jti });
                return true;
              })),
          pruneExpired: Effect.void,
        }),
        Layer.succeed(EnvironmentLinks.EnvironmentLinks, {
          upsert: () => Effect.die("unused upsert"),
          listDeliveryUsersForEnvironment: () => Effect.succeed(users),
          listForUser: () => Effect.die("unused listForUser"),
          getForUser: () => Effect.die("unused getForUser"),
          revokeForUser: () => Effect.die("unused revokeForUser"),
        }),
        Layer.succeed(LiveActivities.LiveActivities, {
          register: () => Effect.void,
          listTargets: ({ userId }) => Effect.succeed(targets[userId] ?? []),
          markDelivery: () => Effect.void,
          markStartQueued: () => Effect.void,
          clearStartQueued: () => Effect.void,
          invalidateDeliveryToken: () => Effect.void,
        }),
        Layer.succeed(ApnsDeliveryQueue.ApnsDeliveryQueue, {
          enqueueLiveActivity: () => Effect.die("unused enqueueLiveActivity"),
          enqueuePushNotification: (row) =>
            Effect.sync((): RelayDeliveryResult => {
              apns.push(row);
              return {
                deviceId: row.deviceId,
                kind: "push_notification",
                ok: true,
                queued: true,
                apnsStatus: null,
                apnsReason: null,
                apnsId: null,
              };
            }),
        }),
        Layer.succeed(FcmDeliveryQueueSender.FcmDeliveryQueueSender, {
          send: (job) =>
            Effect.sync(() => {
              fcm.push(job);
            }),
        }),
      ),
    ),
    Layer.provideMerge(NodeServices.layer),
  );
  return { apns, fcm, consumed, layer };
}

const publish = (request: RelayInfinitusAlertRequest, overrides?: { environmentId?: string }) =>
  Effect.gen(function* () {
    const publisher = yield* InfinitusAlertPublisher.InfinitusAlertPublisher;
    return yield* publisher.publish({
      environmentId: overrides?.environmentId ?? environmentId,
      environmentPublicKey: keyPair.publicKey,
      request,
    });
  });

describe("InfinitusAlertPublisher", () => {
  it.effect("fans a verified alert out to every phone with a token, on either platform", () => {
    const h = harness();
    return Effect.gen(function* () {
      const response = yield* publish(yield* request());
      expect(response.ok).toBe(true);
      expect(response.deliveries.map((row) => row.deviceId).sort()).toEqual(["droid", "phone"]);
      expect(h.apns).toHaveLength(1);
      expect(h.apns[0]?.notification).toEqual({
        title: "Infinitus",
        body: "switched to account 2 (work)",
        environmentId,
        deepLink: "/settings/accounts",
      });
      expect(h.apns[0]?.notification).not.toHaveProperty("threadId");
      expect(h.fcm).toHaveLength(1);
      expect(h.fcm[0]).toMatchObject({
        deviceId: "droid",
        token: "fcm-token",
        state: null,
        alert: {
          alert_id: "alert-jti",
          alert_title: "Infinitus",
          alert_body: "switched to account 2 (work)",
          alert_path: "/settings/accounts",
        },
      });
      expect(h.consumed).toEqual([
        { thumbprint: expect.stringMatching(/^infinitus-alert:/), jti: "alert-jti" },
      ]);
    }).pipe(Effect.provide(h.layer));
  });

  it.effect("skips users whose link has notifications off", () => {
    const h = harness({
      users: [
        { userId: "user:one", notificationsEnabled: false, liveActivitiesEnabled: true },
        { userId: "user:two", notificationsEnabled: true, liveActivitiesEnabled: false },
      ],
      targets: {
        "user:one": [target({ deviceId: "muted", platform: "ios", pushToken: "t1" })],
        "user:two": [
          target({ deviceId: "loud", platform: "ios", pushToken: "t2", userId: "user:two" }),
        ],
      },
    });
    return Effect.gen(function* () {
      const response = yield* publish(yield* request());
      expect(response.deliveries.map((row) => row.deviceId)).toEqual(["loud"]);
    }).pipe(Effect.provide(h.layer));
  });

  it.effect("rejects a proof whose alert differs from the request body", () => {
    const h = harness();
    return Effect.gen(function* () {
      const signed = yield* request({ alert: { ...alert, body: "something else" } });
      const error = yield* Effect.flip(publish(signed));
      expect(error._tag).toBe("InfinitusAlertProofInvalid");
      expect(h.apns).toHaveLength(0);
      expect(h.fcm).toHaveLength(0);
    }).pipe(Effect.provide(h.layer));
  });

  it.effect("rejects a proof for another environment", () => {
    const h = harness();
    return Effect.gen(function* () {
      const error = yield* Effect.flip(publish(yield* request(), { environmentId: "env-2" }));
      expect(error._tag).toBe("InfinitusAlertProofInvalid");
    }).pipe(Effect.provide(h.layer));
  });

  it.effect("rejects an expired proof before touching the replay table", () => {
    const h = harness();
    return Effect.gen(function* () {
      const now = yield* DateTime.now;
      const past = Math.floor(now.epochMilliseconds / 1_000) - 60;
      const error = yield* Effect.flip(publish(yield* request({ iat: past - 300, exp: past })));
      expect(error._tag).toBe("InfinitusAlertProofExpired");
      expect(h.consumed).toHaveLength(0);
    }).pipe(Effect.provide(h.layer));
  });

  it.effect("rejects a replayed nonce", () => {
    const h = harness({ consume: () => Effect.succeed(false) });
    return Effect.gen(function* () {
      const error = yield* Effect.flip(publish(yield* request()));
      expect(error._tag).toBe("InfinitusAlertProofInvalid");
      if (error._tag === "InfinitusAlertProofInvalid") expect(error.stage).toBe("consume_nonce");
      expect(h.apns).toHaveLength(0);
    }).pipe(Effect.provide(h.layer));
  });
});
