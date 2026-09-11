import { EnvironmentId, WS_METHODS } from "@t3tools/contracts";
import type {
  InfinitusAccount,
  InfinitusCommandInput,
  InfinitusFleet,
  InfinitusSnapshot,
} from "@t3tools/contracts/infinitus";
import type {
  PairingApprovalDecideInput,
  PairingApprovalRequest,
} from "@t3tools/contracts/infinitusPairing";
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

import {
  createInfinitusEnvironmentAtoms,
  infinitusAccountLabel,
  infinitusActiveAccount,
  infinitusFleetByKey,
} from "./infinitus.ts";

const TARGET = new PrimaryConnectionTarget({
  environmentId: EnvironmentId.make("environment-1"),
  label: "Test environment",
  httpBaseUrl: "https://environment.example.test",
  wsBaseUrl: "wss://environment.example.test",
});

function account(overrides: Partial<InfinitusAccount> = {}): InfinitusAccount {
  return {
    number: 1,
    email: "alpha@example.com",
    active: false,
    isOrganization: false,
    usageStatus: "fresh",
    ...overrides,
  };
}

function fleet(overrides: Partial<InfinitusFleet> = {}): InfinitusFleet {
  return {
    key: "claude",
    engineID: "swapd",
    provider: "claude",
    capabilities: ["swap"],
    accounts: [],
    ...overrides,
  };
}

function snapshot(overrides: Partial<InfinitusSnapshot> = {}): InfinitusSnapshot {
  return {
    available: true,
    fleets: [],
    sessions: [],
    commands: [],
    ...overrides,
  };
}

const FIRST_SNAPSHOT = snapshot({ fleets: [fleet({ accounts: [account()] })] });
const SECOND_SNAPSHOT = snapshot({
  fleets: [fleet({ activeNumber: 1, accounts: [account({ active: true })] })],
});

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
  const atoms = createInfinitusEnvironmentAtoms(runtime);
  const registry = yield* Effect.acquireRelease(Effect.sync(AtomRegistry.make), (registry) =>
    Effect.sync(() => registry.dispose()),
  );
  return { atoms, registry };
});

describe("Infinitus environment atoms", () => {
  it.effect("holds the latest snapshot the subscription delivers", () =>
    Effect.scoped(
      Effect.gen(function* () {
        const snapshots = yield* Queue.unbounded<InfinitusSnapshot>();
        const client = {
          [WS_METHODS.subscribeInfinitus]: () => Stream.fromQueue(snapshots),
        } as unknown as WsRpcProtocolClient;
        const { atoms, registry } = yield* makeTestRuntime(client);
        const atom = atoms.snapshot({ environmentId: TARGET.environmentId, input: {} });

        // A live stream keeps every value flagged `waiting`, so observe the
        // atom's changes rather than suspending on a settled result.
        const observed: Array<InfinitusSnapshot> = [];
        const seeded = Latch.makeUnsafe();
        const updated = Latch.makeUnsafe();
        const unmount = registry.mount(atom);
        const stop = registry.subscribe(atom, (result) => {
          if (!AsyncResult.isSuccess(result)) return;
          observed.push(result.value);
          if (result.value.fleets[0]?.activeNumber === 1) updated.openUnsafe();
          else seeded.openUnsafe();
        });
        yield* Effect.addFinalizer(() =>
          Effect.sync(() => {
            stop();
            unmount();
          }),
        );

        yield* Queue.offer(snapshots, FIRST_SNAPSHOT);
        yield* seeded.await;
        expect(observed).toEqual([FIRST_SNAPSHOT]);
        expect(yield* AtomRegistry.getResult(registry, atom)).toEqual(FIRST_SNAPSHOT);

        yield* Queue.offer(snapshots, SECOND_SNAPSHOT);
        yield* updated.await;
        expect(observed).toEqual([FIRST_SNAPSHOT, SECOND_SNAPSHOT]);
        expect(yield* AtomRegistry.getResult(registry, atom)).toEqual(SECOND_SNAPSHOT);
      }),
    ),
  );

  it.effect("forwards a command call and resolves with its result", () =>
    Effect.scoped(
      Effect.gen(function* () {
        const calls = yield* Ref.make<ReadonlyArray<InfinitusCommandInput>>([]);
        const client = {
          [WS_METHODS.infinitusCommand]: (input: InfinitusCommandInput) =>
            Ref.update(calls, (current) => [...current, input]).pipe(
              Effect.as({ result: { swapped: 2 } }),
            ),
        } as unknown as WsRpcProtocolClient;
        const { atoms, registry } = yield* makeTestRuntime(client);

        const result = yield* Effect.promise(() =>
          atoms.command.run(registry, {
            environmentId: TARGET.environmentId,
            input: { command: "swap", args: ["claude", "2"], options: { yes: "true" } },
          }),
        );

        expect(result).toMatchObject({ _tag: "Success", value: { result: { swapped: 2 } } });
        expect(yield* Ref.get(calls)).toEqual([
          { command: "swap", args: ["claude", "2"], options: { yes: "true" } },
        ]);
      }),
    ),
  );
});

describe("Infinitus pairing atoms", () => {
  const request = (id: string): PairingApprovalRequest => ({
    id,
    deviceName: "Titan",
    os: "iOS 26",
    remoteAddress: "192.168.1.20",
    matchCode: "AB12",
    createdAt: DateTime.makeUnsafe("2026-09-11T10:00:00Z"),
    expiresAt: DateTime.makeUnsafe("2026-09-11T10:02:00Z"),
  });

  it.effect("holds the latest pending list the subscription delivers", () =>
    Effect.scoped(
      Effect.gen(function* () {
        const lists = yield* Queue.unbounded<ReadonlyArray<PairingApprovalRequest>>();
        const client = {
          [WS_METHODS.subscribeInfinitusPairing]: () => Stream.fromQueue(lists),
        } as unknown as WsRpcProtocolClient;
        const { atoms, registry } = yield* makeTestRuntime(client);
        const atom = atoms.pairing({ environmentId: TARGET.environmentId, input: {} });

        const observed: Array<ReadonlyArray<PairingApprovalRequest>> = [];
        const seeded = Latch.makeUnsafe();
        const emptied = Latch.makeUnsafe();
        const unmount = registry.mount(atom);
        const stop = registry.subscribe(atom, (result) => {
          if (!AsyncResult.isSuccess(result)) return;
          observed.push(result.value);
          if (result.value.length === 0) emptied.openUnsafe();
          else seeded.openUnsafe();
        });
        yield* Effect.addFinalizer(() =>
          Effect.sync(() => {
            stop();
            unmount();
          }),
        );

        yield* Queue.offer(lists, [request("req-1")]);
        yield* seeded.await;
        expect(yield* AtomRegistry.getResult(registry, atom)).toEqual([request("req-1")]);

        yield* Queue.offer(lists, []);
        yield* emptied.await;
        expect(observed).toEqual([[request("req-1")], []]);
      }),
    ),
  );

  it.effect("forwards a decision and resolves with the server's verdict", () =>
    Effect.scoped(
      Effect.gen(function* () {
        const calls = yield* Ref.make<ReadonlyArray<PairingApprovalDecideInput>>([]);
        const client = {
          [WS_METHODS.infinitusPairingDecide]: (input: PairingApprovalDecideInput) =>
            Ref.update(calls, (current) => [...current, input]).pipe(Effect.as({ decided: true })),
        } as unknown as WsRpcProtocolClient;
        const { atoms, registry } = yield* makeTestRuntime(client);

        const result = yield* Effect.promise(() =>
          atoms.pairingDecide.run(registry, {
            environmentId: TARGET.environmentId,
            input: { id: "req-1", approve: false },
          }),
        );

        expect(result).toMatchObject({ _tag: "Success", value: { decided: true } });
        expect(yield* Ref.get(calls)).toEqual([{ id: "req-1", approve: false }]);
      }),
    ),
  );
});

describe("infinitusAccountLabel", () => {
  it("prefers the alias", () => {
    expect(infinitusAccountLabel(account({ alias: "Work" }))).toBe("Work");
  });

  it("falls back to the email when there is no usable alias", () => {
    expect(infinitusAccountLabel(account({ alias: "" }))).toBe("alpha@example.com");
    expect(infinitusAccountLabel(account())).toBe("alpha@example.com");
  });

  it("falls back to the account number when neither is set", () => {
    expect(infinitusAccountLabel(account({ number: 3, email: "" }))).toBe("#3");
  });
});

describe("infinitusActiveAccount", () => {
  it("matches the fleet's active number", () => {
    const wanted = account({ number: 2 });
    expect(
      infinitusActiveAccount(
        fleet({ activeNumber: 2, accounts: [account({ number: 1, active: true }), wanted] }),
      ),
    ).toEqual(wanted);
  });

  it("falls back to the account flagged active", () => {
    const wanted = account({ number: 2, active: true });
    expect(infinitusActiveAccount(fleet({ accounts: [account({ number: 1 }), wanted] }))).toEqual(
      wanted,
    );
    expect(
      infinitusActiveAccount(
        fleet({ activeNumber: 9, accounts: [account({ number: 1 }), wanted] }),
      ),
    ).toEqual(wanted);
  });

  it("returns null when no account is active", () => {
    expect(infinitusActiveAccount(fleet({ accounts: [account()] }))).toBeNull();
    expect(infinitusActiveAccount(fleet())).toBeNull();
  });
});

describe("infinitusFleetByKey", () => {
  it("finds the fleet by its key", () => {
    const wanted = fleet({ key: "codex" });
    expect(infinitusFleetByKey(snapshot({ fleets: [fleet(), wanted] }), "codex")).toEqual(wanted);
  });

  it("returns null for an unknown key or a missing snapshot", () => {
    expect(infinitusFleetByKey(snapshot({ fleets: [fleet()] }), "codex")).toBeNull();
    expect(infinitusFleetByKey(null, "claude")).toBeNull();
  });
});
