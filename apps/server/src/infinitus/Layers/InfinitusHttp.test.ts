import * as NodeHttpServer from "@effect/platform-node/NodeHttpServer";
import {
  type AuthEnvironmentScope,
  AuthSessionId,
  DEFAULT_SERVER_SETTINGS,
  EnvironmentAuthenticatedAuth,
  EnvironmentAuthenticatedPrincipal,
  EnvironmentHttpApi,
  type InfinitusHoldRow,
  ProjectId,
  ProviderDriverKind,
  ProviderInstanceId,
  ThreadId,
  TurnId,
} from "@t3tools/contracts";
import type { InfinitusHeldThread } from "@t3tools/contracts/infinitus";
import { it as effectIt } from "@effect/vitest";
import type * as Context from "effect/Context";
import * as DateTime from "effect/DateTime";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";
import * as Stream from "effect/Stream";
import { HttpApiTest } from "effect/unstable/httpapi";
import { describe, expect } from "vite-plus/test";

import { ProjectionSnapshotQuery } from "../../orchestration/Services/ProjectionSnapshotQuery.ts";
import { ServerSettingsService } from "../../serverSettings.ts";
import {
  InfinitusAlertRelay,
  InfinitusAlertRelayUnlinked,
} from "../Services/InfinitusAlertRelay.ts";
import { InfinitusLimitStops } from "../Services/InfinitusLimitStops.ts";
import { InfinitusRunningTurns } from "../Services/InfinitusRunningTurns.ts";
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

const CLAUDE = ProviderInstanceId.make("claudeAgent");
const CODEX = ProviderInstanceId.make("codex");
const ENV_DEFAULT = { instanceId: CLAUDE, model: "opus" };
const OVERRIDE = { instanceId: CLAUDE, model: "sonnet" };
const ROW_DEFAULT = { instanceId: CODEX, model: "gpt-5" };
const P_OVERRIDE = ProjectId.make("p-override");
const P_ROW = ProjectId.make("p-row");

/** #1315: the environment default the server settings carry, or none, with
    one project's override in `projectSettingsOverrides`; the projection
    knows one project whose row carries its own (pre-fold) default. */
const settingsWith = (defaultModelSelection: typeof ENV_DEFAULT | null) =>
  Layer.mergeAll(
    Layer.mock(ServerSettingsService)({
      getSettings: Effect.succeed({
        ...DEFAULT_SERVER_SETTINGS,
        defaultModelSelection,
        // The resolver drops an override on a disabled instance, so both are on.
        providerInstances: {
          [CLAUDE]: { driver: ProviderDriverKind.make("claudeAgent"), config: {} },
          [CODEX]: { driver: ProviderDriverKind.make("codex"), config: {} },
        },
        projectSettingsOverrides: { [P_OVERRIDE]: { defaultModelSelection: OVERRIDE } },
      }),
    }),
    Layer.mock(ProjectionSnapshotQuery)({
      getProjectShellById: (projectId) =>
        Effect.succeed(
          projectId === P_ROW
            ? Option.some({
                id: P_ROW,
                title: "Row",
                workspaceRoot: "/w/row",
                defaultModelSelection: ROW_DEFAULT,
                scripts: [],
                createdAt: "2026-09-12T00:00:00.000Z",
                updatedAt: "2026-09-12T00:00:00.000Z",
              })
            : Option.none(),
        ),
    }),
  );

/** #1375: the relay publisher, linked unless the alert body says otherwise. */
const alerts: Array<{ title: string; body: string }> = [];
const services = Layer.mergeAll(
  Layer.mock(InfinitusAlertRelay)({
    publish: (input) =>
      input.body === "unlinked"
        ? Effect.fail(new InfinitusAlertRelayUnlinked())
        : Effect.sync(() => {
            alerts.push(input);
            return { deliveries: 2 };
          }),
  }),
  Layer.mock(InfinitusSessionHold)({
    held: Stream.succeed([row("t-held", "held")]),
    release: (threadId) =>
      Effect.succeed(
        threadId === HELD ? { released: true } : { released: false, reason: "nothing is held" },
      ),
  }),
  Layer.mock(InfinitusLimitStops)({ stopped: Stream.succeed([row("t-limited", "limited")]) }),
  Layer.mock(InfinitusRunningTurns)({
    list: Effect.succeed([{ threadId: ThreadId.make("t-running"), turnId: TurnId.make("turn-1") }]),
  }),
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
  envDefault: typeof ENV_DEFAULT | null = ENV_DEFAULT,
) =>
  setup.pipe(
    Effect.flatMap(body),
    Effect.provide([NodeHttpServer.layerHttpServices, infinitusHttpApiLayer]),
    Effect.provideService(EnvironmentAuthenticatedAuth, authenticatedAuth(scopes)),
    Effect.provide(Layer.mergeAll(services, settingsWith(envDefault))),
    Effect.scoped,
  );

const OPERATE: ReadonlyArray<AuthEnvironmentScope> = [
  "orchestration:read",
  "orchestration:operate",
];

describe("infinitusHttpApiLayer (#822)", () => {
  effectIt.effect(
    "forwards the Mac's account alert to the relay on the operate scope (#1375)",
    () =>
      withClient(OPERATE, (client) =>
        Effect.gen(function* () {
          const alert = { title: "Infinitus", body: "switched to account 2 (work)" };
          expect(yield* client.infinitus.alert({ headers: {}, payload: alert })).toEqual({
            deliveries: 2,
          });
          expect(alerts).toEqual([alert]);
          const unlinked = yield* Effect.flip(
            client.infinitus.alert({ headers: {}, payload: { ...alert, body: "unlinked" } }),
          );
          expect(unlinked._tag).toBe("InfinitusAlertRelayUnlinked");
        }),
      ).pipe(
        Effect.andThen(
          withClient(["orchestration:read"], (client) =>
            Effect.gen(function* () {
              const denied = yield* Effect.flip(
                client.infinitus.alert({ headers: {}, payload: { title: "Infinitus", body: "x" } }),
              );
              expect(denied._tag).toBe("EnvironmentScopeRequiredError");
            }),
          ),
        ),
      ),
  );

  effectIt.effect("lists the running turns an update would cut off (#829)", () =>
    withClient(["orchestration:read"], (client) =>
      Effect.gen(function* () {
        expect(yield* client.infinitus.runningTurns({ headers: {} })).toEqual([
          { threadId: "t-running", turnId: "turn-1" },
        ]);
      }),
    ),
  );

  effectIt.effect(
    "thread defaults resolve the project's override, the row's default, then the environment's (#1315)",
    () =>
      Effect.gen(function* () {
        const read = (projectId?: ProjectId, envDefault: typeof ENV_DEFAULT | null = ENV_DEFAULT) =>
          withClient(
            ["orchestration:read"],
            (client) =>
              client.infinitus.threadDefaults({
                headers: {},
                query: projectId === undefined ? {} : { projectId },
              }),
            envDefault,
          );
        expect(yield* read()).toEqual({ defaultModelSelection: ENV_DEFAULT });
        expect(yield* read(P_OVERRIDE)).toEqual({ defaultModelSelection: OVERRIDE });
        expect(yield* read(P_ROW)).toEqual({ defaultModelSelection: ROW_DEFAULT });
        expect(yield* read(ProjectId.make("p-plain"))).toEqual({
          defaultModelSelection: ENV_DEFAULT,
        });
        expect(yield* read(ProjectId.make("p-plain"), null)).toEqual({
          defaultModelSelection: null,
        });
      }),
  );

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
