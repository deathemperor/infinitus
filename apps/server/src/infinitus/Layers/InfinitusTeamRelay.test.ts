import * as NodeServices from "@effect/platform-node/NodeServices";
import { describe, expect, it } from "@effect/vitest";
import type {
  OrchestrationCommand,
  OrchestrationShellSnapshot,
  OrchestrationThreadShell,
} from "@infinitus/contracts";
import { EnvironmentId } from "@infinitus/contracts";
import type { InfinitusSnapshot } from "@infinitus/contracts/infinitus";
import type {
  TeamEnvironmentMembership,
  TeamGrant,
  TeamQueuedCommand,
} from "@infinitus/contracts/relayInfinitusTeam";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";
import * as Schema from "effect/Schema";
import { HttpClient, HttpClientResponse } from "effect/unstable/http";

import * as ServerSecretStore from "../../auth/ServerSecretStore.ts";
import {
  CLOUD_LINKED_USER_ID,
  RELAY_ENVIRONMENT_CREDENTIAL_SECRET,
  RELAY_URL_SECRET,
} from "../../cloud/config.ts";
import { ServerEnvironment } from "../../environment/ServerEnvironment.ts";
import { OrchestrationEngineService } from "../../orchestration/Services/OrchestrationEngine.ts";
import { ProjectionSnapshotQuery } from "../../orchestration/Services/ProjectionSnapshotQuery.ts";
import { InfinitusService } from "../Services/Infinitus.ts";
import { InfinitusTeamRelay } from "../Services/InfinitusTeamRelay.ts";
import { InfinitusTeamRelayLive } from "./InfinitusTeamRelay.ts";

const environmentId = EnvironmentId.make("env-1");
const decodeBody = Schema.decodeUnknownSync(Schema.fromJsonString(Schema.Unknown));

const thread = (
  id: string,
  input: { running?: boolean; updatedAt?: string; projectId?: string } = {},
) =>
  ({
    id,
    projectId: input.projectId ?? "p-1",
    title: `Thread ${id}`,
    createdAt: "2026-09-25T06:00:00.000Z",
    updatedAt: input.updatedAt ?? "2026-09-25T07:00:00.000Z",
    archivedAt: null,
    latestTurn:
      input.running === true
        ? {
            turnId: "turn-1",
            state: "running",
            requestedAt: "2026-09-25T06:59:00.000Z",
            startedAt: "2026-09-25T06:59:30.000Z",
            completedAt: null,
            assistantMessageId: null,
          }
        : null,
    session: null,
    hasPendingApprovals: false,
    hasPendingUserInput: false,
  }) as unknown as OrchestrationThreadShell;

const shell = (threads: ReadonlyArray<OrchestrationThreadShell>): OrchestrationShellSnapshot =>
  ({
    snapshotSequence: 1,
    updatedAt: "2026-09-25T07:00:00.000Z",
    projects: [
      {
        id: "p-1",
        title: "Limitless",
        workspaceRoot: "/Users/loc/death/limitless",
        defaultModelSelection: { provider: "claude", model: "opus" },
      },
      {
        id: "p-2",
        title: "Secret",
        workspaceRoot: "/Users/loc/secret",
        defaultModelSelection: null,
      },
    ],
    threads,
  }) as never;

const grant: TeamGrant = {
  grantId: "g-1",
  environmentId,
  audience: "team",
  threads: "all",
  capabilities: ["view", "send", "interrupt", "new"],
  preauthorized: [],
  expiresAt: null,
};

const membership = (input: Partial<TeamEnvironmentMembership> = {}): TeamEnvironmentMembership =>
  ({
    teamId: "team-1",
    shares: { now: "team", fleet: "team", threads: "team", stats: "team", transcripts: "team" },
    grants: [],
    transcripts: [],
    ...input,
  }) as never;

function memorySecretStore(seed: Record<string, string>) {
  const values = new Map<string, Uint8Array>(
    Object.entries(seed).map(([name, value]) => [name, new TextEncoder().encode(value)]),
  );
  const store: ServerSecretStore.ServerSecretStore["Service"] = {
    get: (name) => Effect.sync(() => Option.fromNullishOr(values.get(name))),
    set: (name, value) => Effect.sync(() => void values.set(name, Uint8Array.from(value))),
    create: (name, value) => Effect.sync(() => void values.set(name, Uint8Array.from(value))),
    getOrCreateRandom: (name, bytes) =>
      Effect.sync(() => values.get(name) ?? new Uint8Array(bytes)),
    remove: (name) => Effect.sync(() => void values.delete(name)),
  };
  return store;
}

interface Recorded {
  readonly method: string;
  readonly path: string;
  readonly user: string | undefined;
  readonly body: unknown;
}

function harness(input: {
  readonly linked?: boolean;
  readonly teams: ReadonlyArray<TeamEnvironmentMembership>;
  readonly threads?: ReadonlyArray<OrchestrationThreadShell>;
  readonly messages?: Record<string, ReadonlyArray<{ role: string; text: string }>>;
  readonly mac?: InfinitusSnapshot | null;
  readonly days?: Record<string, unknown>;
  readonly exclusions?: ReadonlyArray<string>;
  readonly queued?: ReadonlyArray<TeamQueuedCommand>;
}) {
  const requests: Array<Recorded> = [];
  const secrets = memorySecretStore(
    input.linked === false
      ? {}
      : {
          [RELAY_URL_SECRET]: "https://relay.example.test",
          [RELAY_ENVIRONMENT_CREDENTIAL_SECRET]: "env-credential",
          [CLOUD_LINKED_USER_ID]: "user-1",
        },
  );
  const http = HttpClient.make((request) =>
    Effect.sync(() => {
      const path = new URL(request.url).pathname;
      const body =
        request.body._tag === "Uint8Array"
          ? decodeBody(new TextDecoder().decode(request.body.body))
          : null;
      requests.push({
        method: request.method,
        path,
        user: request.headers["x-infinitus-user"],
        body,
      });
      const json = path.endsWith("/infinitus-team")
        ? { userId: "user-1", teams: input.teams }
        : path.endsWith("/infinitus-team/commands")
          ? (input.queued ?? [])
          : { ok: true };
      return HttpClientResponse.fromWeb(request, Response.json(json));
    }),
  );
  const dispatched: Array<OrchestrationCommand> = [];
  const mac: InfinitusSnapshot =
    input.mac === undefined
      ? ({
          available: true,
          fleets: [],
          commands: [
            {
              name: "team-days",
              args: [],
              options: [],
              effect: "read",
              summary: "",
              replyShape: "",
            },
          ],
        } as never)
      : input.mac === null
        ? ({ available: false, unavailableReason: "away", fleets: [], commands: [] } as never)
        : input.mac;
  const layer = InfinitusTeamRelayLive.pipe(
    Layer.provide(
      Layer.mergeAll(
        Layer.succeed(ServerSecretStore.ServerSecretStore, secrets),
        Layer.succeed(ServerEnvironment, {
          getEnvironmentId: Effect.succeed(environmentId),
          getDescriptor: Effect.die("unused"),
        }),
        Layer.succeed(HttpClient.HttpClient, http),
        Layer.mock(OrchestrationEngineService)({
          dispatch: (command) =>
            Effect.sync(() => {
              dispatched.push(command);
              return { sequence: dispatched.length };
            }),
        }),
        Layer.mock(ProjectionSnapshotQuery)({
          getShellSnapshot: () => Effect.succeed(shell(input.threads ?? [])),
          getThreadDetailSnapshot: (threadId) =>
            Effect.succeed(
              input.messages?.[threadId] === undefined
                ? Option.none()
                : Option.some({
                    snapshotSequence: 1,
                    thread: {
                      messages: input.messages[threadId].map((message, i) => ({
                        id: `m-${i}`,
                        turnId: null,
                        streaming: false,
                        createdAt: "2026-09-25T07:00:00.000Z",
                        updatedAt: "2026-09-25T07:00:00.000Z",
                        ...message,
                      })),
                    },
                  } as never),
            ),
        }),
        Layer.mock(InfinitusService)({
          snapshot: Effect.succeed(mac),
          command: () =>
            Effect.succeed({
              days: input.days ?? {},
              exclusions: input.exclusions ?? [],
              generation: 1,
            }),
        }),
      ),
    ),
    Layer.provideMerge(NodeServices.layer),
  );
  return { requests, dispatched, layer };
}

const documentsOf = (requests: ReadonlyArray<Recorded>) =>
  requests
    .filter((request) => request.path.endsWith("/documents"))
    .flatMap(
      (request) =>
        (request.body as { documents: Array<{ kind: string; key: string; body: unknown }> })
          .documents,
    );

describe("InfinitusTeamRelay publishes", () => {
  it.effect("skips the kinds shared off and publishes the rest", () =>
    Effect.gen(function* () {
      const h = harness({
        teams: [
          membership({
            shares: {
              now: "team",
              fleet: "off",
              threads: "leaders",
              stats: "off",
              transcripts: "off",
            },
          }),
        ],
        threads: [thread("t-1", { running: true })],
      });
      const relay = yield* InfinitusTeamRelay.pipe(Effect.provide(h.layer));
      yield* relay.publishAll;
      const documents = documentsOf(h.requests);
      expect(documents.map((document) => document.kind)).toEqual(["now", "threads"]);
      expect(documents[0]?.body).toMatchObject({ live: [{ id: "t-1" }] });
      expect(h.requests[0]).toMatchObject({
        path: "/v1/environments/env-1/infinitus-team",
        user: "user-1",
      });
      expect(h.requests.some((request) => request.path.endsWith("/transcripts"))).toBe(false);
    }),
  );

  it.effect("an unlinked server publishes nothing", () =>
    Effect.gen(function* () {
      const h = harness({ linked: false, teams: [membership()] });
      const relay = yield* InfinitusTeamRelay.pipe(Effect.provide(h.layer));
      yield* relay.publishAll;
      yield* relay.publishNow;
      yield* relay.pollCommands;
      expect(h.requests).toEqual([]);
    }),
  );

  it.effect("stats publish only the days whose digest changed", () =>
    Effect.gen(function* () {
      const h = harness({
        teams: [membership()],
        days: { "2026-09-24": { turns: 3, cost: 1 }, "2026-09-25": { turns: 1, cost: 0 } },
      });
      const relay = yield* InfinitusTeamRelay.pipe(Effect.provide(h.layer));
      yield* relay.publishAll;
      const first = documentsOf(h.requests).filter((document) => document.kind === "stats");
      expect(first.map((document) => document.key)).toEqual(["2026-09-24", "2026-09-25"]);
      h.requests.length = 0;
      yield* relay.publishAll;
      expect(documentsOf(h.requests).filter((document) => document.kind === "stats")).toEqual([]);
    }),
  );

  it.effect(
    "transcripts resume after the relay's cursor, redacted, and skip an excluded project",
    () =>
      Effect.gen(function* () {
        const h = harness({
          teams: [membership({ transcripts: [{ threadId: "t-1", rows: 1, nextSeq: 3 }] })],
          threads: [thread("t-1"), thread("t-2", { projectId: "p-2" })],
          messages: {
            "t-1": [
              { role: "user", text: "already there" },
              { role: "assistant", text: "cd /Users/loc/x with sk-abcdefghijklmnopqrstuvwxyz" },
            ],
            "t-2": [{ role: "user", text: "private" }],
          },
          exclusions: ["secret"],
        });
        const relay = yield* InfinitusTeamRelay.pipe(Effect.provide(h.layer));
        yield* relay.publishAll;
        const chunks = h.requests.filter((request) => request.path.endsWith("/transcripts"));
        expect(chunks.map((chunk) => chunk.body)).toEqual([
          {
            userId: "user-1",
            threadId: "t-1",
            seq: 3,
            rows: 1,
            lines: '{"role":"assistant","text":"cd ~/x with [redacted-key]","at":1790319600}\n',
          },
        ]);
        const index = documentsOf(h.requests).find((document) => document.kind === "threads");
        expect(index?.body).toMatchObject({ threads: [{ id: "t-1" }] });
        h.requests.length = 0;
        yield* relay.publishAll;
        expect(h.requests.some((request) => request.path.endsWith("/transcripts"))).toBe(false);
      }),
  );

  it.effect("a Mac that is away still publishes now with empty fleets and no stats", () =>
    Effect.gen(function* () {
      const h = harness({ teams: [membership()], mac: null, days: { "2026-09-25": {} } });
      const relay = yield* InfinitusTeamRelay.pipe(Effect.provide(h.layer));
      yield* relay.publishNow;
      expect(documentsOf(h.requests)).toMatchObject([
        { kind: "now", body: { desktop: true, fleets: [], blockers: [] } },
      ]);
      h.requests.length = 0;
      yield* relay.publishAll;
      expect(documentsOf(h.requests).map((document) => document.kind)).toEqual(["now", "threads"]);
    }),
  );
});

const queued = (input: Partial<TeamQueuedCommand>): TeamQueuedCommand =>
  ({
    commandId: "c-1",
    teamId: "team-1",
    fromUserId: "user-2",
    threadId: "t-1",
    action: "send",
    text: "hello from Bo",
    expiresAt: "2026-09-25T08:00:00.000Z",
    grant,
    ...input,
  }) as never;

const acksOf = (requests: ReadonlyArray<Recorded>) =>
  requests.filter((request) => request.path.endsWith("/ack")).map((request) => request.body);

describe("InfinitusTeamRelay runs commands", () => {
  it.effect("runs a send through the engine and acks done", () =>
    Effect.gen(function* () {
      const h = harness({
        teams: [membership({ grants: [grant] })],
        threads: [thread("t-1", { running: true })],
        queued: [queued({})],
      });
      const relay = yield* InfinitusTeamRelay.pipe(Effect.provide(h.layer));
      yield* relay.publishNow;
      yield* relay.pollCommands;
      expect(h.dispatched.map((command) => command.type)).toEqual(["thread.turn.start"]);
      expect(h.dispatched[0]).toMatchObject({
        threadId: "t-1",
        message: { text: "hello from Bo" },
      });
      expect(acksOf(h.requests)).toEqual([{ userId: "user-1", outcome: "done" }]);
    }),
  );

  it.effect("pending is acked and not run; a revoked grant is refused", () =>
    Effect.gen(function* () {
      const h = harness({
        teams: [membership({ grants: [grant] })],
        threads: [thread("t-1", { running: true })],
        queued: [
          queued({ commandId: "c-int", action: "interrupt" }),
          queued({ commandId: "c-gone", grant: { ...grant, grantId: "g-old" } }),
          queued({ commandId: "c-view", action: "view" }),
        ],
        messages: {
          "t-1": [{ role: "assistant", text: "token ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ1234" }],
        },
      });
      const relay = yield* InfinitusTeamRelay.pipe(Effect.provide(h.layer));
      yield* relay.publishNow;
      yield* relay.pollCommands;
      expect(h.dispatched).toEqual([]);
      expect(acksOf(h.requests)).toEqual([
        { userId: "user-1", outcome: "pending", detail: "Waiting for their tap." },
        { userId: "user-1", outcome: "refused", detail: "That grant was revoked." },
        { userId: "user-1", outcome: "done", result: { text: "assistant: token [redacted-key]" } },
      ]);
    }),
  );

  it.effect("polls nothing while no grant names this machine", () =>
    Effect.gen(function* () {
      const h = harness({ teams: [membership()], queued: [queued({})] });
      const relay = yield* InfinitusTeamRelay.pipe(Effect.provide(h.layer));
      yield* relay.publishNow;
      yield* relay.pollCommands;
      expect(h.requests.some((request) => request.path.endsWith("/commands"))).toBe(false);
    }),
  );
});
