import { EnvironmentId, ProjectId, WS_METHODS } from "@t3tools/contracts";
import type { CaptureList, CapturesApplyInput } from "@t3tools/contracts/captures";
import { describe, expect, it } from "@effect/vitest";
import * as DateTime from "effect/DateTime";
import * as Effect from "effect/Effect";
import * as Latch from "effect/Latch";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";
import * as Queue from "effect/Queue";
import * as Ref from "effect/Ref";
import * as Stream from "effect/Stream";
import * as SubscriptionRef from "effect/SubscriptionRef";
import { AsyncResult, Atom, AtomRegistry } from "effect/unstable/reactivity";

import {
  AVAILABLE_CONNECTION_STATE,
  PrimaryConnectionTarget,
  type PreparedConnection,
  type SupervisorConnectionState,
} from "../connection/model.ts";
import * as EnvironmentRegistry from "../connection/registry.ts";
import * as EnvironmentSupervisor from "../connection/supervisor.ts";
import type { WsRpcProtocolClient } from "../rpc/protocol.ts";
import type { RpcSession } from "../rpc/session.ts";

import { createCaptureAtoms } from "./captures.ts";

const TARGET = new PrimaryConnectionTarget({
  environmentId: EnvironmentId.make("environment-1"),
  label: "Test environment",
  httpBaseUrl: "https://environment.example.test",
  wsBaseUrl: "wss://environment.example.test",
});
const PROJECT = ProjectId.make("project-1");

const ITEM: CaptureList[number] = {
  id: "cap-1" as CaptureList[number]["id"],
  text: "buy milk",
  createdAt: DateTime.makeUnsafe("2026-09-11T10:00:00Z"),
  doneAt: null,
};

function session(client: WsRpcProtocolClient): RpcSession {
  return {
    client,
    initialConfig: Effect.never,
    subscribeServerConfig: (input) => client.subscribeServerConfig(input),
    ready: Effect.void,
    probe: Effect.void,
    closed: Effect.never,
  };
}

const CONNECTED_CONNECTION_STATE: SupervisorConnectionState = {
  ...AVAILABLE_CONNECTION_STATE,
  desired: true,
  network: "online",
  phase: "connected",
  attempt: 1,
  generation: 1,
};

const makeTestRuntime = Effect.fn("makeTestRuntime")(function* (client: WsRpcProtocolClient) {
  const supervisor = EnvironmentSupervisor.EnvironmentSupervisor.of({
    target: TARGET,
    state: yield* SubscriptionRef.make(CONNECTED_CONNECTION_STATE),
    session: yield* SubscriptionRef.make(Option.some(session(client))),
    prepared: yield* SubscriptionRef.make(Option.none<PreparedConnection>()),
    connect: Effect.void,
    disconnect: Effect.void,
    retryNow: Effect.void,
  } satisfies EnvironmentSupervisor.EnvironmentSupervisor["Service"]);
  const environmentRegistry = EnvironmentRegistry.EnvironmentRegistry.of({
    run: (_environmentId, effect) =>
      Effect.provideService(effect, EnvironmentSupervisor.EnvironmentSupervisor, supervisor),
    runStream: (_environmentId, stream) =>
      Stream.provideService(stream, EnvironmentSupervisor.EnvironmentSupervisor, supervisor),
    followStream: (_environmentId, stream) =>
      Stream.provideService(stream, EnvironmentSupervisor.EnvironmentSupervisor, supervisor),
  } as EnvironmentRegistry.EnvironmentRegistry["Service"]);
  const runtime = Atom.runtime(
    Layer.succeed(EnvironmentRegistry.EnvironmentRegistry, environmentRegistry),
  );
  const atoms = createCaptureAtoms(runtime);
  const registry = yield* Effect.acquireRelease(Effect.sync(AtomRegistry.make), (registry) =>
    Effect.sync(() => registry.dispose()),
  );
  return { atoms, registry };
});

describe("capture atoms", () => {
  it.effect("holds the project's latest list and asks the server for that project", () =>
    Effect.scoped(
      Effect.gen(function* () {
        const lists = yield* Queue.unbounded<CaptureList>();
        const asked = yield* Ref.make<ReadonlyArray<unknown>>([]);
        const client = {
          [WS_METHODS.subscribeCaptures]: (input: unknown) =>
            Stream.fromQueue(lists).pipe(
              Stream.tap(() => Ref.update(asked, (all) => (all.length === 0 ? [input] : all))),
            ),
        } as unknown as WsRpcProtocolClient;
        const { atoms, registry } = yield* makeTestRuntime(client);
        const atom = atoms.list({
          environmentId: TARGET.environmentId,
          input: { projectId: PROJECT },
        });

        const observed: Array<CaptureList> = [];
        const seeded = Latch.makeUnsafe();
        const added = Latch.makeUnsafe();
        const unmount = registry.mount(atom);
        const stop = registry.subscribe(atom, (result) => {
          if (!AsyncResult.isSuccess(result)) return;
          observed.push(result.value);
          if (result.value.length === 0) seeded.openUnsafe();
          else added.openUnsafe();
        });
        yield* Effect.addFinalizer(() =>
          Effect.sync(() => {
            stop();
            unmount();
          }),
        );

        yield* Queue.offer(lists, []);
        yield* seeded.await;
        yield* Queue.offer(lists, [ITEM]);
        yield* added.await;
        expect(observed).toEqual([[], [ITEM]]);
        expect(yield* AtomRegistry.getResult(registry, atom)).toEqual([ITEM]);
        expect(yield* Ref.get(asked)).toEqual([{ projectId: PROJECT }]);
      }),
    ),
  );

  it.effect("forwards a change and settles with the empty result", () =>
    Effect.scoped(
      Effect.gen(function* () {
        const calls = yield* Ref.make<ReadonlyArray<CapturesApplyInput>>([]);
        const client = {
          [WS_METHODS.capturesApply]: (input: CapturesApplyInput) =>
            Ref.update(calls, (current) => [...current, input]).pipe(Effect.as({})),
        } as unknown as WsRpcProtocolClient;
        const { atoms, registry } = yield* makeTestRuntime(client);

        const result = yield* Effect.promise(() =>
          atoms.apply.run(registry, {
            environmentId: TARGET.environmentId,
            input: { projectId: PROJECT, command: { type: "add", text: "buy milk" } },
          }),
        );

        expect(result).toMatchObject({ _tag: "Success", value: {} });
        expect(yield* Ref.get(calls)).toEqual([
          { projectId: PROJECT, command: { type: "add", text: "buy milk" } },
        ]);
      }),
    ),
  );
});
