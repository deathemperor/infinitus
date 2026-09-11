import * as NodeHttpServer from "@effect/platform-node/NodeHttpServer";
import {
  type AuthEnvironmentScope,
  AuthSessionId,
  EnvironmentAuthenticatedAuth,
  EnvironmentAuthenticatedPrincipal,
  EnvironmentHttpApi,
  type InfinitusHoldRow,
  ThreadId,
} from "@t3tools/contracts";
import type { InfinitusHeldThread } from "@t3tools/contracts/infinitus";
import { it as effectIt } from "@effect/vitest";
import type * as Context from "effect/Context";
import * as DateTime from "effect/DateTime";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Stream from "effect/Stream";
import { HttpApiTest } from "effect/unstable/httpapi";
import { describe, expect } from "vite-plus/test";

import { InfinitusLimitStops } from "../Services/InfinitusLimitStops.ts";
import { InfinitusSessionHold } from "../Services/InfinitusSessionHold.ts";
import { InfinitusSessionInterrupt } from "../Services/InfinitusSessionInterrupt.ts";
import { infinitusHttpApiLayer } from "./InfinitusHttp.ts";

/** A WS-stream row (`held` / `limited`); the paused row exists only on the HTTP read. */
const row = (
  threadId: string,
  kind: NonNullable<InfinitusHeldThread["kind"]>,
): InfinitusHeldThread => ({
  threadId: ThreadId.make(threadId),
  since: "2026-09-12T00:00:00.000Z",
  summary: `${kind} for the test`,
  kind,
});

const pausedRow = (threadId: string): InfinitusHoldRow => ({
  ...row(threadId, "held"),
  kind: "paused",
});

const HELD = ThreadId.make("t-held");
const PAUSED = ThreadId.make("t-paused");

const services = Layer.mergeAll(
  Layer.mock(InfinitusSessionHold)({
    held: Stream.succeed([row("t-held", "held")]),
    release: (threadId) =>
      Effect.succeed(
        threadId === HELD ? { released: true } : { released: false, reason: "nothing is held" },
      ),
  }),
  Layer.mock(InfinitusLimitStops)({ stopped: Stream.succeed([row("t-limited", "limited")]) }),
  Layer.mock(InfinitusSessionInterrupt)({
    paused: Effect.succeed([pausedRow("t-paused")]),
    resume: (threadId) =>
      Effect.succeed(
        threadId === PAUSED ? { released: true } : { released: false, reason: "nothing is paused" },
      ),
  }),
);

/** The middleware the routes carry, with a principal holding `scopes`. */
const authenticatedAuth =
  (
    scopes: ReadonlyArray<AuthEnvironmentScope>,
  ): Context.Service.Shape<typeof EnvironmentAuthenticatedAuth> =>
  (httpEffect) =>
    httpEffect.pipe(
      Effect.provideService(EnvironmentAuthenticatedPrincipal, {
        sessionId: AuthSessionId.make("cli-session"),
        subject: "infinitusctl",
        method: "bearer-access-token",
        scopes: new Set(scopes),
        expiresAt: DateTime.makeUnsafe("2026-12-10T00:00:00.000Z"),
      }),
    );

/** The typed client the CLI uses, against only the `infinitus` group. */
const setup = HttpApiTest.groups(EnvironmentHttpApi, ["infinitus"]);

const withClient = <A, E>(
  scopes: ReadonlyArray<AuthEnvironmentScope>,
  body: (client: Effect.Success<typeof setup>) => Effect.Effect<A, E>,
) =>
  setup.pipe(
    Effect.flatMap(body),
    Effect.provide([NodeHttpServer.layerHttpServices, infinitusHttpApiLayer]),
    Effect.provideService(EnvironmentAuthenticatedAuth, authenticatedAuth(scopes)),
    Effect.provide(services),
    Effect.scoped,
  );

const OPERATE: ReadonlyArray<AuthEnvironmentScope> = [
  "orchestration:read",
  "orchestration:operate",
];

describe("infinitusHttpApiLayer (#822)", () => {
  effectIt.effect("one read lists the held, limit-stopped and paused threads", () =>
    withClient(OPERATE, (client) =>
      Effect.gen(function* () {
        const holds = yield* client.infinitus.holds({ headers: {} });
        expect(holds.map((entry) => [entry.threadId, entry.kind])).toEqual([
          ["t-held", "held"],
          ["t-limited", "limited"],
          ["t-paused", "paused"],
        ]);
      }),
    ),
  );

  effectIt.effect("release runs a held start, else continues a paused turn, else says so", () =>
    withClient(OPERATE, (client) =>
      Effect.gen(function* () {
        expect(
          yield* client.infinitus.releaseThread({ headers: {}, payload: { threadId: HELD } }),
        ).toEqual({
          released: true,
        });
        expect(
          yield* client.infinitus.releaseThread({ headers: {}, payload: { threadId: PAUSED } }),
        ).toEqual({
          released: true,
        });
        expect(
          yield* client.infinitus.releaseThread({
            headers: {},
            payload: { threadId: ThreadId.make("t-idle") },
          }),
        ).toEqual({ released: false, reason: "nothing is held or paused" });
      }),
    ),
  );

  effectIt.effect("a session without the operate scope is refused", () =>
    withClient(["orchestration:read"], (client) =>
      Effect.gen(function* () {
        const refused = yield* client.infinitus.holds({ headers: {} }).pipe(Effect.flip);
        expect(refused).toMatchObject({ _tag: "EnvironmentScopeRequiredError" });
        const refusedRelease = yield* client.infinitus
          .releaseThread({ headers: {}, payload: { threadId: HELD } })
          .pipe(Effect.flip);
        expect(refusedRelease).toMatchObject({ _tag: "EnvironmentScopeRequiredError" });
      }),
    ),
  );
});
