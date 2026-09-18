import type { InfinitusEngineKey } from "@infinitus/contracts/infinitus";
import { assert, describe, it } from "@effect/vitest";

import { type EngineSpawner, makeEngineSupervisor } from "./InfinitusEngineSupervisor.ts";

const HOME = "/Users/me";
const NINE_ROUTER_BINARY = "/opt/homebrew/bin/9router";
const CLIPROXY_PLIST = `${HOME}/Library/LaunchAgents/homebrew.mxcl.cliproxyapi.plist`;

interface SpawnedProcess {
  readonly binary: string;
  readonly args: ReadonlyArray<string>;
  readonly exit: (code: number | null, signal?: string | null) => void;
  readonly fail: (message: string) => void;
  killed: boolean;
}

/** A spawner that records rather than spawns, with time and timers in hand so
    backoff is asserted rather than waited on. */
function fakeSpawner() {
  const spawned: Array<SpawnedProcess> = [];
  const pending: Array<{ seconds: number; run: () => void }> = [];
  let clock = 0;
  const spawner: EngineSpawner = {
    spawn: (binary, args, handlers) => {
      const process: SpawnedProcess = {
        binary,
        args,
        killed: false,
        exit: (code, signal = null) => handlers.onExit(code, signal),
        fail: (message) => handlers.onError(message),
      };
      spawned.push(process);
      return {
        pid: 1000 + spawned.length,
        kill: () => {
          process.killed = true;
          handlers.onExit(null, "SIGTERM");
        },
      };
    },
    delay: (seconds, run) => {
      const entry = { seconds, run };
      pending.push(entry);
      return () => {
        const index = pending.indexOf(entry);
        if (index >= 0) pending.splice(index, 1);
      };
    },
    now: () => clock,
  };
  return {
    spawner,
    spawned,
    pending,
    advance: (seconds: number) => {
      clock += seconds * 1_000;
    },
    /** Fire every scheduled retry, as the clock reaching them would. */
    flush: () => {
      const due = [...pending];
      pending.length = 0;
      for (const entry of due) entry.run();
    },
    get last() {
      return spawned.at(-1);
    },
  };
}

const supervisorWith = (
  settings: Array<{ key: InfinitusEngineKey; managed: boolean; command: string | null }>,
  options: { executables?: ReadonlyArray<string>; files?: ReadonlyArray<string> } = {},
) => {
  const fake = fakeSpawner();
  const supervisor = makeEngineSupervisor({
    spawner: fake.spawner,
    detection: {
      homeDirectory: HOME,
      isExecutable: (path) => (options.executables ?? [NINE_ROUTER_BINARY]).includes(path),
      fileExists: (path) => (options.files ?? []).includes(path),
      listDirectory: () => [],
    },
    settings: () => settings,
  });
  return { fake, supervisor };
};

const stateOf = (supervisor: ReturnType<typeof makeEngineSupervisor>, key: InfinitusEngineKey) =>
  supervisor.snapshot().engines.find((entry) => entry.key === key)!;

describe("engine supervisor", () => {
  it("starts nothing until an engine is managed", () => {
    const { fake, supervisor } = supervisorWith([]);
    supervisor.reconcile();
    assert.lengthOf(fake.spawned, 0);
    assert.strictEqual(stateOf(supervisor, "9router").state, "stopped");
  });

  it("runs a managed engine and reports it", () => {
    const { fake, supervisor } = supervisorWith([{ key: "9router", managed: true, command: null }]);
    supervisor.reconcile();
    assert.lengthOf(fake.spawned, 1);
    assert.strictEqual(fake.last!.binary, NINE_ROUTER_BINARY);
    assert.deepStrictEqual(fake.last!.args, ["-t", "-n", "-H", "127.0.0.1"]);
    const state = stateOf(supervisor, "9router");
    assert.strictEqual(state.state, "running");
    assert.strictEqual(state.pid, 1001);
  });

  it("restarts a managed engine that dies, backing off further each time", () => {
    const { fake, supervisor } = supervisorWith([{ key: "9router", managed: true, command: null }]);
    supervisor.reconcile();

    fake.last!.exit(1);
    assert.strictEqual(stateOf(supervisor, "9router").state, "backing-off");
    assert.deepStrictEqual(
      fake.pending.map((entry) => entry.seconds),
      [1],
    );
    fake.flush();
    assert.lengthOf(fake.spawned, 2);

    fake.last!.exit(1);
    assert.deepStrictEqual(
      fake.pending.map((entry) => entry.seconds),
      [2],
    );
  });

  it("starts the backoff over after a run that lasted", () => {
    const { fake, supervisor } = supervisorWith([{ key: "9router", managed: true, command: null }]);
    supervisor.reconcile();
    fake.last!.exit(1);
    fake.flush();
    fake.advance(600);
    fake.last!.exit(1);
    assert.deepStrictEqual(
      fake.pending.map((entry) => entry.seconds),
      [1],
    );
  });

  it("never respawns after a stop we asked for", () => {
    const { fake, supervisor } = supervisorWith([{ key: "9router", managed: true, command: null }]);
    supervisor.reconcile();
    supervisor.control({ key: "9router", action: "stop" });
    assert.isTrue(fake.last!.killed);
    assert.lengthOf(fake.pending, 0);
    assert.strictEqual(stateOf(supervisor, "9router").state, "stopped");
    fake.flush();
    assert.lengthOf(fake.spawned, 1);
  });

  it("restarts on demand", () => {
    const { fake, supervisor } = supervisorWith([{ key: "9router", managed: true, command: null }]);
    supervisor.reconcile();
    supervisor.control({ key: "9router", action: "restart" });
    assert.lengthOf(fake.spawned, 2);
    assert.strictEqual(stateOf(supervisor, "9router").state, "running");
  });

  it("leaves a service-managed engine alone even when asked to run it", () => {
    const { fake, supervisor } = supervisorWith(
      [{ key: "cliproxy", managed: true, command: null }],
      { files: [CLIPROXY_PLIST], executables: ["/opt/homebrew/bin/brew"] },
    );
    supervisor.reconcile();
    assert.lengthOf(fake.spawned, 0);
    const state = stateOf(supervisor, "cliproxy");
    assert.strictEqual(state.mode, "service");
    // Nothing failed — launchd owns it, and the page says so rather than
    // showing an error.
    assert.strictEqual(state.error, null);
  });

  it("reports a command it cannot run instead of spawning it", () => {
    const { fake, supervisor } = supervisorWith([
      { key: "9router", managed: true, command: "9router -n" },
    ]);
    supervisor.reconcile();
    assert.lengthOf(fake.spawned, 0);
    const state = stateOf(supervisor, "9router");
    assert.strictEqual(state.state, "failed");
    assert.include(state.error ?? "", "full path");
  });

  it("carries a spawn failure's own words", () => {
    const { fake, supervisor } = supervisorWith([{ key: "9router", managed: true, command: null }]);
    supervisor.reconcile();
    fake.last!.fail("spawn ENOENT");
    const state = stateOf(supervisor, "9router");
    assert.strictEqual(state.state, "failed");
    assert.strictEqual(state.error, "spawn ENOENT");
  });

  it("takes every child down with the app and cancels pending retries", () => {
    const { fake, supervisor } = supervisorWith([{ key: "9router", managed: true, command: null }]);
    supervisor.reconcile();
    supervisor.shutdown();
    assert.isTrue(fake.spawned[0]!.killed);
    assert.lengthOf(fake.pending, 0);
    assert.strictEqual(stateOf(supervisor, "9router").state, "stopped");
  });

  it("stops an engine that stops being managed", () => {
    const settings = [{ key: "9router" as const, managed: true, command: null }];
    const { fake, supervisor } = supervisorWith(settings);
    supervisor.reconcile();
    settings[0]!.managed = false;
    supervisor.reconcile();
    assert.isTrue(fake.spawned[0]!.killed);
    assert.strictEqual(stateOf(supervisor, "9router").state, "stopped");
  });
});
