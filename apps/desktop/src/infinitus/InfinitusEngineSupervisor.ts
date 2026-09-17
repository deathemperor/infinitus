// @effect-diagnostics nodeBuiltinImport:off -- This platform boundary runs the proxy engines with Node.
// @effect-diagnostics globalTimers:off -- The retry timer and clock are the spawner seam's own, so the supervisor's backoff is asserted against a fake rather than waited on; no Effect fiber is involved.
// @effect-diagnostics globalDate:off -- Same seam: how long a run lasted is measured at the child-process callback boundary.

/**
 * Run the proxy engines for as long as this app does (#1177 follow-up).
 *
 * A thread on a proxied Claude instance fails with `ConnectionRefused` when its
 * engine is not running, and until now the Engines page could only say so. The
 * shell starts the engine instead, restarts it when it dies, and takes it down
 * with the app.
 *
 * Only a `child` engine is ours to run — `infinitusEngines.logic.ts` decides
 * that, and one already owned by launchd through Homebrew is left to it. A
 * child dies with this process: an engine that must outlive the app belongs in
 * a service manager, not in an Electron shell.
 */
import * as NodeChildProcess from "node:child_process";

import type {
  InfinitusEngineControlInput,
  InfinitusEngineKey,
  InfinitusEngineSettingsInput,
  InfinitusEngineSupervision,
  InfinitusEngines,
} from "@infinitus/contracts/infinitus";
import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";

import * as DesktopEnvironment from "../app/DesktopEnvironment.ts";
import { makeComponentLogger } from "../app/DesktopObservability.ts";
import {
  ENGINE_DEFINITIONS,
  type EngineDefinition,
  type EngineDetectionInput,
  engineBackoffSeconds,
  engineExitMessage,
  engineBackoffAttemptFor,
  parseCommandLine,
  resolveEngine,
} from "./infinitusEngines.logic.ts";
import { InfinitusDesktopPrefsService } from "./InfinitusDesktopPrefs.ts";
import { fileExists, isExecutableFile, listDirectoryNames } from "./InfinitusSwapdProcess.ts";

/** A running engine, as the supervisor holds it. */
interface EngineChild {
  readonly pid: number | null;
  readonly kill: () => void;
}

/** The platform seam, so the supervisor is testable without spawning. */
export interface EngineSpawner {
  readonly spawn: (
    binary: string,
    args: ReadonlyArray<string>,
    handlers: {
      /** `detail` is whatever the engine said on stderr before it went, which
          is the only clue a non-zero exit carries. */
      readonly onExit: (code: number | null, signal: string | null, detail?: string) => void;
      readonly onError: (message: string) => void;
    },
  ) => EngineChild;
  /** Schedules a retry; returns a cancel. */
  readonly delay: (seconds: number, run: () => void) => () => void;
  readonly now: () => number;
}

const nodeEngineSpawner: EngineSpawner = {
  spawn: (binary, args, handlers) => {
    const child = NodeChildProcess.spawn(binary, [...args], {
      stdio: ["ignore", "ignore", "pipe"],
      // Its own group, so a stop takes the engine's own children with it.
      detached: false,
    });
    let stderr = "";
    child.stderr?.on("data", (chunk: Buffer) => {
      if (stderr.length < 2_000) stderr += chunk.toString();
    });
    child.once("error", (error) => handlers.onError(error.message));
    child.once("exit", (code, signal) => handlers.onExit(code, signal, stderr.trim()));
    return { pid: child.pid ?? null, kill: () => child.kill() };
  },
  delay: (seconds, run) => {
    const timer = setTimeout(run, seconds * 1_000);
    return () => clearTimeout(timer);
  },
  now: () => Date.now(),
};

/** One engine's mutable supervision state. */
interface EngineRun {
  child: EngineChild | null;
  state: InfinitusEngineSupervision["state"];
  error: string | null;
  attempt: number;
  startedAt: number | null;
  cancelRetry: (() => void) | null;
  /** A stop we asked for never respawns. */
  stopping: boolean;
}

export interface EngineSupervisorDeps {
  readonly spawner: EngineSpawner;
  readonly detection: EngineDetectionInput;
  readonly settings: () => ReadonlyArray<{
    readonly key: InfinitusEngineKey;
    readonly managed: boolean;
    readonly command: string | null;
  }>;
  readonly onChange?: (engines: InfinitusEngines) => void;
  readonly log?: (message: string, fields: Record<string, unknown>) => void;
}

/**
 * The supervisor proper, free of Effect and Electron so its lifecycle is
 * testable: spawn, respawn with backoff, stop, and what the page reads.
 */
export function makeEngineSupervisor(deps: EngineSupervisorDeps) {
  const runs = new Map<InfinitusEngineKey, EngineRun>();
  const log = deps.log ?? (() => undefined);

  const runFor = (key: InfinitusEngineKey): EngineRun => {
    const existing = runs.get(key);
    if (existing !== undefined) return existing;
    const created: EngineRun = {
      child: null,
      state: "stopped",
      error: null,
      attempt: 0,
      startedAt: null,
      cancelRetry: null,
      stopping: false,
    };
    runs.set(key, created);
    return created;
  };

  const settingsFor = (key: InfinitusEngineKey) =>
    deps.settings().find((entry) => entry.key === key) ?? {
      key,
      managed: false,
      command: null,
    };

  const resolutionFor = (definition: EngineDefinition) =>
    resolveEngine(definition, deps.detection, settingsFor(definition.key).command);

  const publish = () => deps.onChange?.(snapshot());

  const snapshot = (): InfinitusEngines => ({
    engines: ENGINE_DEFINITIONS.map((definition) => {
      const resolution = resolutionFor(definition);
      const run = runFor(definition.key);
      return {
        key: definition.key,
        mode: resolution.mode,
        managed: settingsFor(definition.key).managed,
        command: resolution.command,
        detectedCommand: resolution.detectedCommand,
        state: run.state,
        pid: run.child?.pid ?? null,
        error: run.error,
      } satisfies InfinitusEngineSupervision;
    }),
  });

  const clearRetry = (run: EngineRun) => {
    run.cancelRetry?.();
    run.cancelRetry = null;
  };

  const spawn = (definition: EngineDefinition) => {
    const run = runFor(definition.key);
    const resolution = resolutionFor(definition);
    if (resolution.mode !== "child" || resolution.command === null) {
      run.state = "stopped";
      run.error =
        resolution.mode === "service"
          ? null
          : "No command for this engine — set one to run it from here.";
      publish();
      return;
    }
    const parsed = parseCommandLine(resolution.command);
    if (!parsed.ok) {
      run.state = "failed";
      run.error = parsed.error;
      publish();
      return;
    }
    run.stopping = false;
    run.state = "starting";
    run.error = null;
    run.startedAt = deps.spawner.now();
    const child = deps.spawner.spawn(parsed.binary, parsed.args, {
      onExit: (code, signal, detail) => handleExit(definition, code, signal, detail),
      onError: (message) => {
        run.child = null;
        run.state = "failed";
        run.error = message;
        publish();
      },
    });
    run.child = child;
    // A spawn that failed outright already moved the state on; anything else is
    // up as far as this process can tell.
    if (run.state === "starting") run.state = "running";
    log("infinitus.engine.started", { engine: definition.key, pid: child.pid });
    publish();
  };

  const handleExit = (
    definition: EngineDefinition,
    code: number | null,
    signal: string | null,
    detail?: string,
  ) => {
    const run = runFor(definition.key);
    const ranForSeconds = run.startedAt === null ? 0 : (deps.spawner.now() - run.startedAt) / 1_000;
    run.child = null;
    run.startedAt = null;
    if (run.stopping) {
      run.state = "stopped";
      run.error = null;
      publish();
      return;
    }
    if (!settingsFor(definition.key).managed) {
      run.state = "stopped";
      run.error = engineExitMessage(code, signal, detail);
      publish();
      return;
    }
    const attempt = engineBackoffAttemptFor(run.attempt, ranForSeconds);
    const seconds = engineBackoffSeconds(attempt);
    run.attempt = attempt + 1;
    run.state = "backing-off";
    run.error = engineExitMessage(code, signal, detail);
    log("infinitus.engine.exited", {
      engine: definition.key,
      code,
      signal,
      retryInSeconds: seconds,
    });
    clearRetry(run);
    run.cancelRetry = deps.spawner.delay(seconds, () => {
      run.cancelRetry = null;
      if (settingsFor(definition.key).managed) spawn(definition);
    });
    publish();
  };

  const stop = (definition: EngineDefinition) => {
    const run = runFor(definition.key);
    clearRetry(run);
    run.attempt = 0;
    if (run.child === null) {
      run.state = "stopped";
      run.error = null;
      publish();
      return;
    }
    run.stopping = true;
    run.child.kill();
    log("infinitus.engine.stopped", { engine: definition.key });
  };

  const definitionFor = (key: InfinitusEngineKey) =>
    ENGINE_DEFINITIONS.find((definition) => definition.key === key) ?? null;

  return {
    snapshot,
    /** Start every engine whose settings say to. Called once at launch and
        after a settings change. */
    reconcile: () => {
      for (const definition of ENGINE_DEFINITIONS) {
        const run = runFor(definition.key);
        const managed = settingsFor(definition.key).managed;
        if (managed && run.child === null && run.state !== "backing-off") {
          spawn(definition);
        } else if (!managed && run.child !== null) {
          stop(definition);
        }
      }
      publish();
    },
    control: (input: InfinitusEngineControlInput) => {
      const definition = definitionFor(input.key);
      if (definition === null) return;
      if (input.action === "stop") {
        stop(definition);
        return;
      }
      if (input.action === "restart") {
        stop(definition);
      }
      const run = runFor(definition.key);
      run.attempt = 0;
      if (run.child === null) spawn(definition);
    },
    /** Every child down, for the app's own shutdown. */
    shutdown: () => {
      for (const definition of ENGINE_DEFINITIONS) {
        const run = runFor(definition.key);
        clearRetry(run);
        if (run.child !== null) {
          run.stopping = true;
          run.child.kill();
          run.child = null;
        }
        run.state = "stopped";
      }
    },
  };
}

export type EngineSupervisor = ReturnType<typeof makeEngineSupervisor>;

export class InfinitusEngineSupervisorService extends Context.Service<
  InfinitusEngineSupervisorService,
  {
    readonly get: Effect.Effect<InfinitusEngines>;
    readonly setSettings: (change: InfinitusEngineSettingsInput) => Effect.Effect<InfinitusEngines>;
    readonly control: (input: InfinitusEngineControlInput) => Effect.Effect<InfinitusEngines>;
  }
>()("@infinitus/desktop/infinitus/InfinitusEngineSupervisor/InfinitusEngineSupervisorService") {}

const { logInfo } = makeComponentLogger("infinitus-engine-supervisor");

const make = Effect.gen(function* () {
  const environment = yield* DesktopEnvironment.DesktopEnvironment;
  const prefs = yield* InfinitusDesktopPrefsService;
  let settings = (yield* prefs.get).engines;

  const supervisor = makeEngineSupervisor({
    spawner: nodeEngineSpawner,
    detection: {
      homeDirectory: environment.homeDirectory,
      isExecutable: isExecutableFile,
      fileExists,
      listDirectory: listDirectoryNames,
    },
    settings: () => settings,
  });

  yield* Effect.addFinalizer(() => Effect.sync(() => supervisor.shutdown()));
  yield* Effect.sync(() => supervisor.reconcile());
  yield* logInfo("infinitus.engines.reconciled", {
    managed: settings.filter((entry) => entry.managed).length,
  });

  return InfinitusEngineSupervisorService.of({
    get: Effect.sync(() => supervisor.snapshot()),
    setSettings: (change) =>
      Effect.gen(function* () {
        const written = yield* prefs.setEngine(change).pipe(Effect.catch(() => prefs.get));
        settings = written.engines;
        return yield* Effect.sync(() => {
          supervisor.reconcile();
          return supervisor.snapshot();
        });
      }),
    control: (input) =>
      Effect.sync(() => {
        supervisor.control(input);
        return supervisor.snapshot();
      }),
  });
});

export const layer = Layer.effect(InfinitusEngineSupervisorService, make);
