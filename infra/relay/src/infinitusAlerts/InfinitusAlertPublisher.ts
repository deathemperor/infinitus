import {
  RELAY_INFINITUS_ALERT_TYP,
  RelayInfinitusAlertProofPayload,
  type RelayInfinitusAlert,
  type RelayInfinitusAlertRequest,
} from "@infinitus/contracts/relayInfinitusAlert";
import type { RelayDeliveryResult, RelayPublishResponse } from "@infinitus/contracts/relay";
import { decodeRelayJwt, normalizeRelayIssuer, verifyRelayJwt } from "@infinitus/shared/relayJwt";
import { stableStringify } from "@infinitus/shared/relaySigning";
import * as Context from "effect/Context";
import * as Crypto from "effect/Crypto";
import * as DateTime from "effect/DateTime";
import * as Effect from "effect/Effect";
import * as Encoding from "effect/Encoding";
import * as Layer from "effect/Layer";
import * as Schema from "effect/Schema";

import * as ApnsDeliveryQueue from "../agentActivity/ApnsDeliveryQueue.ts";
import * as FcmDeliveryQueueSender from "../agentActivity/FcmDeliveryQueueSender.ts";
import * as LiveActivities from "../agentActivity/LiveActivities.ts";
import { sanitizeApnsNotificationPayload } from "../agentActivity/agentActivityPayloads.ts";
import * as DpopProofs from "../auth/DpopProofs.ts";
import * as RelayConfiguration from "../Config.ts";
import * as EnvironmentLinks from "../environments/EnvironmentLinks.ts";

/**
 * An Infinitus environment's account alerts (#1375): the Mac app's limit /
 * switch / revival / AWS-login lines, pushed with the relay's key to every
 * phone of every user linked to the environment with notifications on.
 * Thread-less, so it is its own route and publisher beside the agent
 * activity ones; the proof check is `EnvironmentPublishSignatures.verify`
 * without the thread, and the nonce goes into the same replay table under
 * its own thumbprint prefix. iOS rides the APNs notification queue with no
 * `threadId`; Android rides the FCM queue as an `alert` job the consumer
 * sends over whatever card it is showing.
 */
export class InfinitusAlertProofExpired extends Schema.TaggedError<InfinitusAlertProofExpired>()(
  "InfinitusAlertProofExpired",
  { environmentId: Schema.String },
) {
  override get message(): string {
    return `Environment '${this.environmentId}' alert proof expired`;
  }
}

export class InfinitusAlertProofInvalid extends Schema.TaggedError<InfinitusAlertProofInvalid>()(
  "InfinitusAlertProofInvalid",
  {
    environmentId: Schema.String,
    stage: Schema.Literals([
      "decode_token",
      "verify_proof",
      "validate_claims",
      "validate_expiration",
      "consume_nonce",
    ]),
    cause: Schema.optional(Schema.Defect()),
  },
) {
  override get message(): string {
    return `Environment '${this.environmentId}' alert proof is invalid during ${this.stage}`;
  }
}

export class InfinitusAlertPublishFailed extends Schema.TaggedError<InfinitusAlertPublishFailed>()(
  "InfinitusAlertPublishFailed",
  {
    environmentId: Schema.String,
    stage: Schema.Literals([
      "replay_thumbprint",
      "consume_nonce",
      "list_users",
      "list_targets",
      "enqueue",
    ]),
    cause: Schema.Defect(),
  },
) {
  override get message(): string {
    return `Environment '${this.environmentId}' alert publish failed during ${this.stage}`;
  }
}

export type InfinitusAlertPublishError =
  | InfinitusAlertProofExpired
  | InfinitusAlertProofInvalid
  | InfinitusAlertPublishFailed;

export class InfinitusAlertPublisher extends Context.Service<
  InfinitusAlertPublisher,
  {
    readonly publish: (input: {
      readonly environmentId: string;
      readonly environmentPublicKey: string;
      readonly request: RelayInfinitusAlertRequest;
    }) => Effect.Effect<RelayPublishResponse, InfinitusAlertPublishError>;
  }
>()("infinitus-relay/infinitusAlerts/InfinitusAlertPublisher") {}

const decodeProof = Schema.decodeUnknownEffect(RelayInfinitusAlertProofPayload);

const alertDeliveryResult = (input: {
  readonly deviceId: string;
  readonly ok: boolean;
  readonly reason?: string;
}): RelayDeliveryResult => ({
  deviceId: input.deviceId,
  kind: "push_notification",
  ok: input.ok,
  ...(input.ok ? { queued: true } : {}),
  apnsStatus: null,
  apnsReason: input.reason ?? null,
  apnsId: null,
});

export const make = Effect.gen(function* () {
  const proofReplay = yield* DpopProofs.DpopProofReplay;
  const config = yield* RelayConfiguration.RelayConfiguration;
  const crypto = yield* Crypto.Crypto;
  const links = yield* EnvironmentLinks.EnvironmentLinks;
  const liveActivities = yield* LiveActivities.LiveActivities;
  const apnsQueue = yield* ApnsDeliveryQueue.ApnsDeliveryQueue;
  const fcmSender = yield* FcmDeliveryQueueSender.FcmDeliveryQueueSender;

  /** The verified proof's `jti`, which doubles as the Android alert identity. */
  const verify = Effect.fnUntraced(function* (input: {
    readonly environmentId: string;
    readonly environmentPublicKey: string;
    readonly request: RelayInfinitusAlertRequest;
  }) {
    const invalid = (
      stage: InfinitusAlertProofInvalid["stage"],
      cause?: unknown,
    ): InfinitusAlertProofInvalid =>
      new InfinitusAlertProofInvalid({
        environmentId: input.environmentId,
        stage,
        ...(cause === undefined ? {} : { cause }),
      });
    const now = yield* DateTime.now;
    const nowEpochSeconds = Math.floor(now.epochMilliseconds / 1_000);
    const decoded = yield* Effect.try({
      try: () => decodeRelayJwt(input.request.proof),
      catch: (cause) => invalid("decode_token", cause),
    });
    if (typeof decoded.exp === "number" && decoded.exp <= nowEpochSeconds) {
      return yield* new InfinitusAlertProofExpired({ environmentId: input.environmentId });
    }
    const proof = yield* verifyRelayJwt({
      publicKey: input.environmentPublicKey,
      token: input.request.proof,
      typ: RELAY_INFINITUS_ALERT_TYP,
      issuer: `t3-env:${input.environmentId}`,
      audience: normalizeRelayIssuer(config.relayIssuer),
      nowEpochSeconds,
    }).pipe(
      Effect.flatMap(decodeProof),
      Effect.mapError((cause) => invalid("verify_proof", cause)),
    );
    if (
      proof.environmentId !== input.environmentId ||
      proof.sub !== input.environmentId ||
      stableStringify(proof.alert) !== stableStringify(input.request.alert)
    ) {
      return yield* invalid("validate_claims");
    }
    const expiresAt = DateTime.make(proof.exp * 1_000);
    if (expiresAt._tag === "None") {
      return yield* invalid("validate_expiration");
    }
    const thumbprint = yield* crypto
      .digest(
        "SHA-256",
        new TextEncoder().encode(
          stableStringify({
            environmentId: input.environmentId,
            environmentPublicKey: input.environmentPublicKey,
          }),
        ),
      )
      .pipe(
        Effect.map((digest) => `infinitus-alert:${Encoding.encodeBase64Url(digest)}`),
        Effect.mapError(
          (cause) =>
            new InfinitusAlertPublishFailed({
              environmentId: input.environmentId,
              stage: "replay_thumbprint",
              cause,
            }),
        ),
      );
    const consumed = yield* proofReplay
      .consume({ thumbprint, jti: proof.jti, iat: proof.iat, expiresAt: expiresAt.value })
      .pipe(
        Effect.mapError(
          (cause) =>
            new InfinitusAlertPublishFailed({
              environmentId: input.environmentId,
              stage: "consume_nonce",
              cause,
            }),
        ),
      );
    if (!consumed) {
      return yield* invalid("consume_nonce");
    }
    return proof.jti;
  });

  const deliverToTarget = Effect.fnUntraced(function* (input: {
    readonly environmentId: string;
    readonly target: LiveActivities.TargetRow;
    readonly alert: RelayInfinitusAlert;
    readonly alertId: string;
    readonly nowMs: number;
  }) {
    const { target } = input;
    if (!target.push_token) return null;
    const failed = (cause: unknown) =>
      new InfinitusAlertPublishFailed({
        environmentId: input.environmentId,
        stage: "enqueue",
        cause,
      });
    if (target.platform === "android") {
      if (!config.fcmServiceAccount) {
        return alertDeliveryResult({
          deviceId: target.device_id,
          ok: false,
          reason: "Android notifications are not configured for this relay.",
        });
      }
      yield* fcmSender
        .send({
          userId: target.user_id,
          deviceId: target.device_id,
          token: target.push_token,
          state: null,
          queuedAt: input.nowMs,
          alert: {
            alert_id: input.alertId,
            alert_title: input.alert.title,
            alert_body: input.alert.body,
            alert_path: input.alert.deepLink,
          },
        })
        .pipe(Effect.mapError(failed));
      return alertDeliveryResult({ deviceId: target.device_id, ok: true });
    }
    if (!config.apns) {
      return alertDeliveryResult({
        deviceId: target.device_id,
        ok: false,
        reason: "APNs is disabled for this relay.",
      });
    }
    return yield* apnsQueue
      .enqueuePushNotification({
        userId: target.user_id,
        deviceId: target.device_id,
        token: target.push_token,
        bundleId: target.bundle_id,
        apsEnvironment: target.aps_environment,
        notification: sanitizeApnsNotificationPayload({
          title: input.alert.title,
          body: input.alert.body,
          environmentId: input.environmentId,
          deepLink: input.alert.deepLink,
        }),
      })
      .pipe(Effect.mapError(failed));
  });

  return InfinitusAlertPublisher.of({
    publish: Effect.fn("relay.infinitus_alert_publisher.publish")(function* (input) {
      yield* Effect.annotateCurrentSpan({ "relay.environment_id": input.environmentId });
      const alertId = yield* verify(input);
      const nowMs = (yield* DateTime.now).epochMilliseconds;
      const users = yield* links
        .listDeliveryUsersForEnvironment({
          environmentId: input.environmentId,
          environmentPublicKey: input.environmentPublicKey,
        })
        .pipe(
          Effect.mapError(
            (cause) =>
              new InfinitusAlertPublishFailed({
                environmentId: input.environmentId,
                stage: "list_users",
                cause,
              }),
          ),
        );
      const deliveries = yield* Effect.forEach(
        users.filter((user) => user.notificationsEnabled),
        Effect.fnUntraced(function* (user) {
          const targets = yield* liveActivities.listTargets({ userId: user.userId }).pipe(
            Effect.mapError(
              (cause) =>
                new InfinitusAlertPublishFailed({
                  environmentId: input.environmentId,
                  stage: "list_targets",
                  cause,
                }),
            ),
          );
          return yield* Effect.forEach(
            targets,
            (target) =>
              deliverToTarget({
                environmentId: input.environmentId,
                target,
                alert: input.request.alert,
                alertId,
                nowMs,
              }),
            { concurrency: 4 },
          );
        }),
        { concurrency: 4 },
      );
      const flat = deliveries.flat().filter((row) => row !== null);
      yield* Effect.logInfo("infinitus alert published", {
        environmentId: input.environmentId,
        users: users.length,
        deliveries: flat.length,
      });
      return { ok: flat.every((row) => row.ok), deliveries: flat };
    }),
  });
});

export const layer = Layer.effect(InfinitusAlertPublisher, make);
