import * as NodeHttpServer from "@effect/platform-node/NodeHttpServer";
import * as NodeServices from "@effect/platform-node/NodeServices";
import {
  AuthAdministrativeScopes,
  type AuthEnvironmentScope,
  AuthSessionId,
  EnvironmentAuthenticatedAuth,
  EnvironmentAuthenticatedPrincipal,
  EnvironmentHttpApi,
} from "@t3tools/contracts";
import { it as effectIt } from "@effect/vitest";
import type * as Context from "effect/Context";
import * as DateTime from "effect/DateTime";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";
import * as Stream from "effect/Stream";
import { HttpApiTest } from "effect/unstable/httpapi";
import { describe, expect } from "vite-plus/test";

import * as EnvironmentAuth from "../../auth/EnvironmentAuth.ts";
import { InfinitusPairing } from "../Services/InfinitusPairing.ts";
import { InfinitusPairingLive } from "./InfinitusPairing.ts";
import { infinitusPairingHttpApiLayer } from "./InfinitusPairingHttp.ts";

const SECRET = "phone-secret-0123456789abcdef";

const authLayer = Layer.mock(EnvironmentAuth.EnvironmentAuth)({
  issuePairingCredential: (input) =>
    Effect.succeed({
      id: "link-1",
      credential: "one-time-credential",
      ...(input?.label !== undefined ? { label: input.label } : {}),
      expiresAt: DateTime.makeUnsafe("2026-09-11T12:00:00.000Z"),
    }),
  revokePairingLink: () => Effect.succeed(true),
});

const pairingLayer = InfinitusPairingLive.pipe(
  Layer.provide(authLayer),
  Layer.provide(NodeServices.layer),
);

/** The api's other groups carry this middleware; the two pairing routes do
    not, so the principal it would provide is never read. */
const authenticatedAuth: Context.Service.Shape<typeof EnvironmentAuthenticatedAuth> = (
  httpEffect,
) =>
  httpEffect.pipe(
    Effect.provideService(EnvironmentAuthenticatedPrincipal, {
      sessionId: AuthSessionId.make("test-session"),
      subject: "test-client",
      method: "browser-session-cookie",
      scopes: new Set<AuthEnvironmentScope>(),
      expiresAt: DateTime.makeUnsafe("2026-09-11T12:00:00.000Z"),
    }),
  );

/** The typed client the phone uses, against only the pairing group, served
    by the real store. */
const setup = Effect.gen(function* () {
  const client = yield* HttpApiTest.groups(EnvironmentHttpApi, ["infinitusPairing"]);
  const pairing = yield* InfinitusPairing;
  return { client, pairing };
});

const withClient = <A, E>(body: (input: Effect.Success<typeof setup>) => Effect.Effect<A, E>) =>
  setup.pipe(
    Effect.flatMap(body),
    Effect.provide([NodeHttpServer.layerHttpServices, infinitusPairingHttpApiLayer]),
    Effect.provideService(EnvironmentAuthenticatedAuth, authenticatedAuth),
    Effect.provide(pairingLayer),
    Effect.scoped,
  );

describe("infinitusPairingHttpApiLayer", () => {
  effectIt.effect("the phone asks, polls, and collects the credential once approved", () =>
    withClient(({ client, pairing }) =>
      Effect.gen(function* () {
        const created = yield* client.infinitusPairing.pairingApprovalCreate({
          payload: { deviceName: "Loc's iPhone", os: "ios", secret: SECRET },
        });
        expect(created.matchCode).toHaveLength(4);
        expect(
          yield* client.infinitusPairing.pairingApprovalPoll({
            payload: { id: created.id, secret: SECRET },
          }),
        ).toEqual({ state: "pending" });

        const listed = yield* Stream.runHead(pairing.pending).pipe(
          Effect.map(Option.getOrElse(() => [])),
        );
        expect(listed.map((row) => [row.deviceName, row.os, row.matchCode])).toEqual([
          ["Loc's iPhone", "ios", created.matchCode],
        ]);

        yield* pairing.decide({
          id: created.id,
          approve: true,
          approverScopes: AuthAdministrativeScopes,
        });
        const polled = yield* client.infinitusPairing.pairingApprovalPoll({
          payload: { id: created.id, secret: SECRET },
        });
        expect(polled).toMatchObject({ state: "approved", credential: "one-time-credential" });
      }),
    ),
  );

  effectIt.effect("a wrong secret is 404, a body the schema rejects never reaches the store", () =>
    withClient(({ client }) =>
      Effect.gen(function* () {
        const created = yield* client.infinitusPairing.pairingApprovalCreate({
          payload: { deviceName: "iPhone", secret: SECRET },
        });
        const notFound = yield* client.infinitusPairing
          .pairingApprovalPoll({ payload: { id: created.id, secret: "wrong-secret-0123456789" } })
          .pipe(Effect.flip);
        expect(notFound._tag).toBe("PairingApprovalNotFound");
        const tooShort = yield* client.infinitusPairing
          .pairingApprovalCreate({ payload: { deviceName: "iPhone", secret: "short" } })
          .pipe(Effect.flip);
        expect(tooShort._tag).not.toBe("PairingApprovalRefused");
      }),
    ),
  );

  effectIt.effect("the sixth undecided request is refused with 429", () =>
    withClient(({ client }) =>
      Effect.gen(function* () {
        for (let index = 0; index < 5; index += 1) {
          yield* client.infinitusPairing.pairingApprovalCreate({
            payload: { deviceName: `phone ${index}`, secret: SECRET },
          });
        }
        const refused = yield* client.infinitusPairing
          .pairingApprovalCreate({ payload: { deviceName: "phone 5", secret: SECRET } })
          .pipe(Effect.flip);
        expect(refused).toMatchObject({ _tag: "PairingApprovalRefused" });
      }),
    ),
  );
});
