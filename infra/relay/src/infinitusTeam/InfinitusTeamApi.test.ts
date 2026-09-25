import * as NodeServices from "@effect/platform-node/NodeServices";
import { describe, expect, it } from "@effect/vitest";
import { EnvironmentId } from "@infinitus/contracts";
import {
  RelayApi,
  RelayClientAuth,
  RelayClientPrincipal,
  RelayEnvironmentAuth,
  RelayEnvironmentPrincipal,
} from "@infinitus/contracts/relay";
import { TEAM_USER_HEADER } from "@infinitus/contracts/relayInfinitusTeam";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as HttpServer from "effect/unstable/http/HttpServer";
import * as HttpRouter from "effect/unstable/http/HttpRouter";
import * as HttpApi from "effect/unstable/httpapi/HttpApi";
import * as HttpApiBuilder from "effect/unstable/httpapi/HttpApiBuilder";

import * as EnvironmentLinks from "../environments/EnvironmentLinks.ts";
import { infinitusTeamApi } from "./InfinitusTeamApi.ts";
import { infinitusTeamEnvironmentApi } from "./InfinitusTeamEnvironmentApi.ts";
import * as InMemory from "./inMemoryStore.ts";
import * as Service from "./InfinitusTeamService.ts";
import * as TranscriptStore from "./InfinitusTeamTranscriptStore.ts";

const KEY = "env-key";
const ENV_1 = EnvironmentId.make("env-1");

/** Both team groups on one web handler: the client auth stub signs requests
    as whoever `as` last named, the environment stub is always env-1. Only
    user-1 is linked to env-1. */
function harness() {
  let userId = "user-1";
  const links = Layer.succeed(EnvironmentLinks.EnvironmentLinks, {
    upsert: () => Effect.die("unused"),
    listDeliveryUsersForEnvironment: () => Effect.die("unused"),
    listForUser: () => Effect.succeed([]),
    getForUser: (input) =>
      Effect.succeed(
        input.userId === "user-1" && input.environmentId === ENV_1
          ? {
              environmentId: ENV_1,
              label: "x",
              endpoint: {
                httpBaseUrl: "https://x",
                wsBaseUrl: "wss://x",
                providerKind: "cloudflare_tunnel" as const,
              },
              linkedAt: "2026-09-25T00:00:00.000Z",
              environmentPublicKey: KEY,
            }
          : null,
      ),
    revokeForUser: () => Effect.die("unused"),
  });
  const service = Service.layer.pipe(
    Layer.provide(
      Layer.mergeAll(InMemory.layer(InMemory.emptyState()), TranscriptStore.inMemoryLayer(), links),
    ),
  );
  const clientAuth = Layer.succeed(RelayClientAuth, {
    clientBearer: (effect) =>
      Effect.suspend(() =>
        Effect.provideService(effect, RelayClientPrincipal, { userId, token: "t" }),
      ),
  });
  const envAuth = Layer.succeed(RelayEnvironmentAuth, {
    environmentBearer: (effect) =>
      Effect.provideService(effect, RelayEnvironmentPrincipal, {
        environmentId: ENV_1,
        environmentPublicKey: KEY,
      }),
  });
  const app = HttpRouter.toWebHandler(
    HttpApiBuilder.layer(
      HttpApi.make("RelayApi").add(
        RelayApi.groups.infinitusTeam,
        RelayApi.groups.infinitusTeamEnvironment,
      ),
    ).pipe(
      Layer.provide(
        Layer.mergeAll(infinitusTeamApi, infinitusTeamEnvironmentApi).pipe(Layer.provide(service)),
      ),
      Layer.provide([clientAuth, envAuth]),
      Layer.provide([HttpServer.layerServices, NodeServices.layer]),
    ),
    { disableLogger: true },
  );
  const call = (
    path: string,
    init?: { method?: string; body?: string; headers?: Record<string, string> },
  ) =>
    Effect.promise(async () => {
      const response = await app.handler(
        new Request(`https://relay.test${path}`, {
          method: init?.method ?? (init?.body === undefined ? "GET" : "POST"),
          headers: {
            authorization: "Bearer t",
            ...(init?.body === undefined ? {} : { "content-type": "application/json" }),
            ...init?.headers,
          },
          ...(init?.body === undefined ? {} : { body: init.body }),
        }),
      );
      return { status: response.status, body: (await response.json()) as Record<string, unknown> };
    });
  return {
    call,
    as: (id: string) => {
      userId = id;
    },
    dispose: Effect.promise(() => app.dispose()),
  };
}

describe("infinitusTeam routes", () => {
  it.effect("creates a team and returns the founder's snapshot", () =>
    Effect.gen(function* () {
      const h = harness();
      const created = yield* h.call("/v1/infinitus/teams", {
        body: '{"name":"Ops","memberName":"Loc"}',
      });
      expect(created.status).toBe(200);
      expect(created.body.name).toBe("Ops");
      expect(created.body.role).toBe("leader");
      expect(created.body.me).toMatchObject({ name: "Loc" });
      const listed = yield* h.call("/v1/infinitus/teams");
      expect(listed.status).toBe(200);
      yield* h.dispose;
    }),
  );

  it.effect("refuses a bad invite token with the sentence as a 409", () =>
    Effect.gen(function* () {
      const h = harness();
      const joined = yield* h.call("/v1/infinitus/team-join", {
        body: '{"token":"nope","memberName":"Bo"}',
      });
      expect(joined.status).toBe(409);
      expect(joined.body).toMatchObject({
        _tag: "RelayInfinitusTeamRefusedError",
        code: "infinitus_team_refused",
      });
      expect(typeof joined.body.reason).toBe("string");
      yield* h.dispose;
    }),
  );

  it.effect("only a leader mints invites", () =>
    Effect.gen(function* () {
      const h = harness();
      const created = yield* h.call("/v1/infinitus/teams", {
        body: '{"name":"Ops","memberName":"Loc"}',
      });
      const teamId = created.body.teamId as string;
      const invite = yield* h.call(`/v1/infinitus/teams/${teamId}/invites`, {
        body: '{"days":7,"oneUse":true}',
      });
      expect(invite.status).toBe(200);
      h.as("user-2");
      const joined = yield* h.call("/v1/infinitus/team-join", {
        body: `{"token":"${invite.body.token as string}","memberName":"Bo"}`,
      });
      expect(joined.status).toBe(200);
      const refused = yield* h.call(`/v1/infinitus/teams/${teamId}/invites`, {
        body: '{"days":7,"oneUse":true}',
      });
      expect(refused.status).toBe(409);
      expect(refused.body.reason).toBe("Only a leader can do that.");
      yield* h.dispose;
    }),
  );
});

describe("infinitusTeamEnvironment routes", () => {
  it.effect("answers memberships for the environment's linked user and refuses another", () =>
    Effect.gen(function* () {
      const h = harness();
      yield* h.call("/v1/infinitus/teams", { body: '{"name":"Ops","memberName":"Loc"}' });
      const mine = yield* h.call("/v1/environments/env-1/infinitus-team", {
        headers: { [TEAM_USER_HEADER]: "user-1" },
      });
      expect(mine.status).toBe(200);
      expect(mine.body.userId).toBe("user-1");
      expect(mine.body.teams).toHaveLength(1);
      const other = yield* h.call("/v1/environments/env-1/infinitus-team", {
        headers: { [TEAM_USER_HEADER]: "user-2" },
      });
      expect(other.status).toBe(409);
      expect(other.body.reason).toBe("This environment is not linked to that user.");
      const wrongEnv = yield* h.call("/v1/environments/env-9/infinitus-team", {
        headers: { [TEAM_USER_HEADER]: "user-1" },
      });
      expect(wrongEnv.status).toBe(401);
      yield* h.dispose;
    }),
  );
});
