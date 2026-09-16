import * as NodeHttpServer from "@effect/platform-node/NodeHttpServer";
import {
  AuthSessionId,
  type AuthEnvironmentScope,
  EnvironmentAuthenticatedAuth,
  EnvironmentAuthenticatedPrincipal,
  EnvironmentHttpApi,
} from "@infinitus/contracts";
import { InfinitusUnavailable } from "@infinitus/contracts/infinitus";
import { it as effectIt } from "@effect/vitest";
import type * as Context from "effect/Context";
import * as DateTime from "effect/DateTime";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Ref from "effect/Ref";
import * as Schema from "effect/Schema";
import { HttpApiTest } from "effect/unstable/httpapi";
import { describe, expect } from "vite-plus/test";

import {
  InfinitusControlClient,
  type InfinitusControlRequestInput,
} from "../Services/InfinitusControlClient.ts";
import { infinitusTeamControlHttpApiLayer } from "./InfinitusTeamControlHttp.ts";

/** The api's other groups carry this middleware; the team route does not, so
    the principal it would provide is never read. */
const authenticatedAuth: Context.Service.Shape<typeof EnvironmentAuthenticatedAuth> = (
  httpEffect,
) =>
  httpEffect.pipe(
    Effect.provideService(EnvironmentAuthenticatedPrincipal, {
      sessionId: AuthSessionId.make("test-session"),
      subject: "test-client",
      method: "browser-session-cookie",
      scopes: new Set<AuthEnvironmentScope>(),
      expiresAt: DateTime.makeUnsafe("2026-09-15T12:00:00.000Z"),
    }),
  );

const setup = Effect.gen(function* () {
  const requests = yield* Ref.make<ReadonlyArray<InfinitusControlRequestInput>>([]);
  const answer = yield* Ref.make<unknown>({ ack: "c2VhbGVk" });
  const control = Layer.mock(InfinitusControlClient)({
    socketPath: "/tmp/test.sock",
    request: (request) =>
      Ref.update(requests, (list) => [...list, request]).pipe(
        Effect.andThen(Ref.get(answer)),
        Effect.flatMap((reply) =>
          Schema.is(InfinitusUnavailable)(reply) ? Effect.fail(reply) : Effect.succeed(reply),
        ),
      ),
  });
  const client = yield* HttpApiTest.groups(EnvironmentHttpApi, ["infinitusTeamControl"]).pipe(
    Effect.provide([NodeHttpServer.layerHttpServices, infinitusTeamControlHttpApiLayer]),
    Effect.provide(control),
  );
  return { client, requests, answer };
});

const withClient = <A, E>(body: (input: Effect.Success<typeof setup>) => Effect.Effect<A, E>) =>
  setup.pipe(
    Effect.flatMap(body),
    Effect.provideService(EnvironmentAuthenticatedAuth, authenticatedAuth),
    Effect.scoped,
  );

describe("infinitusTeamControlHttpApiLayer", () => {
  effectIt.effect("hands the envelope to team-inbox on the secret field and answers the ack", () =>
    withClient(({ client, requests }) =>
      Effect.gen(function* () {
        const reply = yield* client.infinitusTeamControl.teamCommand({
          payload: { envelope: "ZW52ZWxvcGU=" },
        });
        expect(reply).toEqual({ ack: "c2VhbGVk" });
        expect(yield* Ref.get(requests)).toEqual([
          { command: "team-inbox", secret: "ZW52ZWxvcGU=" },
        ]);
      }),
    ),
  );

  effectIt.effect("a Mac with nobody to answer is {ack: null}; a Mac that is down is 503", () =>
    withClient(({ client, answer }) =>
      Effect.gen(function* () {
        yield* Ref.set(answer, { ack: null });
        expect(
          yield* client.infinitusTeamControl.teamCommand({ payload: { envelope: "eA==" } }),
        ).toEqual({ ack: null });
        yield* Ref.set(
          answer,
          new InfinitusUnavailable({ path: "/tmp/test.sock", cause: "ECONNREFUSED" }),
        );
        const down = yield* client.infinitusTeamControl
          .teamCommand({ payload: { envelope: "eA==" } })
          .pipe(Effect.flip);
        expect(down._tag).toBe("TeamControlUnavailable");
      }),
    ),
  );

  effectIt.effect("an empty or oversized envelope never reaches the Mac", () =>
    withClient(({ client, requests }) =>
      Effect.gen(function* () {
        const empty = yield* client.infinitusTeamControl
          .teamCommand({ payload: { envelope: "" } })
          .pipe(Effect.flip);
        expect(empty._tag).not.toBe("TeamControlUnavailable");
        const huge = yield* client.infinitusTeamControl
          .teamCommand({ payload: { envelope: "x".repeat(64 * 1024 + 1) } })
          .pipe(Effect.flip);
        expect(huge._tag).not.toBe("TeamControlUnavailable");
        expect(yield* Ref.get(requests)).toEqual([]);
      }),
    ),
  );
});
