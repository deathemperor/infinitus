<<<<<<< HEAD:apps/server/src/provider/Layers/PiProvider.test.ts
// @effect-diagnostics nodeBuiltinImport:off - builds a fake `pi` CLI in a temp dir.
import * as NodeOS from "node:os";
import * as NodePath from "node:path";

import * as NodeServices from "@effect/platform-node/NodeServices";
import { expect, it } from "@effect/vitest";
import { PiSettings } from "@infinitus/contracts";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Schema from "effect/Schema";

import { writeFakeCli } from "../../testUtils/fakeCli.ts";
import { checkPiProviderStatus } from "./PiProvider.ts";

const decodePiSettings = Schema.decodeSync(PiSettings);

/**
 * A `pi` whose `--version` answers but whose `--list-models` behaves as the
 * test asks.
 *
 * There is no "hangs past the probe timeout" case: a timeout and a non-zero
 * exit both leave `modelsOutput` undefined and take the identical branch, and
 * the harness runs on TestClock so the probe's own timeout would never fire.
 */
const makeFakePi = Effect.fn("PiProvider.test.makeFakePi")(function* (
  listModels: "fail" | "empty",
) {
  const fileSystem = yield* FileSystem.FileSystem;
  const directory = yield* fileSystem.makeTempDirectoryScoped({ prefix: "pi-provider-test-" });
  const body =
    listModels === "fail"
      ? 'process.stderr.write("boom\\n"); process.exit(3);'
      : 'process.stdout.write("\\n"); process.exit(0);';
  return writeFakeCli({
    directory,
    name: "pi",
    source: [
      'if (process.argv.includes("--version")) {',
      '  process.stdout.write("0.85.1\\n");',
      "  process.exit(0);",
      "}",
      'if (process.argv.includes("--list-models")) {',
      `  ${body}`,
      "}",
    ].join("\n"),
  });
});

/** A `pi` that writes whatever `PI_CODING_AGENT_DIR` it was given to a file. */
const makeHomeReportingPi = Effect.fn("PiProvider.test.makeHomeReportingPi")(function* () {
  const fileSystem = yield* FileSystem.FileSystem;
  const directory = yield* fileSystem.makeTempDirectoryScoped({ prefix: "pi-provider-home-" });
  const homeLogPath = NodePath.join(directory, "home.txt");
  const binaryPath = writeFakeCli({
    directory,
    name: "pi",
    // The log path rides in the stub's own env sidecar rather than being
    // quoted into its source.
    env: { PI_HOME_LOG_PATH: homeLogPath },
    source: [
      'import { writeFileSync as writeHomeLog } from "node:fs";',
      'writeHomeLog(process.env.PI_HOME_LOG_PATH, process.env.PI_CODING_AGENT_DIR ?? "");',
      'if (process.argv.includes("--version")) {',
      '  process.stdout.write("0.85.1\\n");',
      "  process.exit(0);",
      "}",
      'process.stdout.write("\\n");',
      "process.exit(0);",
    ].join("\n"),
  });
  return { binaryPath, homeLogPath };
});

it.layer(NodeServices.layer)("checkPiProviderStatus", (it) => {
  it.effect("does not claim a signed-in user is signed out when the model probe fails", () =>
    Effect.gen(function* () {
      const binaryPath = yield* makeFakePi("fail");
      const snapshot = yield* checkPiProviderStatus(
        decodePiSettings({ enabled: true, binaryPath }),
      );

      // Pi's catalogue IS the auth signal, so an empty one reads as "signed
      // out" — but only when the listing actually ran. A failed probe says
      // nothing about auth, and telling a signed-in user to sign in because
      // their network was slow sends them round a pointless loop.
      expect(snapshot.installed).toBe(true);
      expect(snapshot.version).toBe("0.85.1");
      expect(snapshot.auth.status).toBe("unknown");
      expect(snapshot.message).not.toMatch(/sign in/i);
    }),
  );

  it.effect("reports unauthenticated only when the listing succeeded and was empty", () =>
    Effect.gen(function* () {
      const binaryPath = yield* makeFakePi("empty");
      const snapshot = yield* checkPiProviderStatus(
        decodePiSettings({ enabled: true, binaryPath }),
      );

      expect(snapshot.auth.status).toBe("unauthenticated");
      expect(snapshot.message).toMatch(/sign in/i);
    }),
  );

  it.effect("lists models offline", () =>
    Effect.gen(function* () {
      // Online, the listing installs any configured package that is missing.
      // The probe's timeout can kill that install mid-rename and leave npm's
      // retire dir behind, after which every Pi launch fails with ENOTEMPTY.
      const fileSystem = yield* FileSystem.FileSystem;
      const directory = yield* fileSystem.makeTempDirectoryScoped({
        prefix: "pi-provider-offline-",
      });
      const binaryPath = writeFakeCli({
        directory,
        name: "pi",
        source: [
          'if (process.argv.includes("--version")) {',
          '  process.stdout.write("0.85.1\\n");',
          "  process.exit(0);",
          "}",
          'if (!process.argv.includes("--offline")) process.exit(3);',
          'process.stdout.write("\\n");',
          "process.exit(0);",
        ].join("\n"),
      });

      const snapshot = yield* checkPiProviderStatus(
        decodePiSettings({ enabled: true, binaryPath }),
      );
      expect(snapshot.auth.status).toBe("unauthenticated");
    }),
  );

  it.effect("probes the instance's own home, never an ambient Oh My Pi one", () =>
    Effect.gen(function* () {
      // The probe has to read the same config the session will. Oh My Pi is a
      // fork of Pi that kept `APP_NAME = "pi"`, so a `PI_CODING_AGENT_DIR` set
      // for `omp` would otherwise have Pi report `omp`'s auth and models.
      const { binaryPath, homeLogPath } = yield* makeHomeReportingPi();
      const fileSystem = yield* FileSystem.FileSystem;

      yield* checkPiProviderStatus(
        decodePiSettings({ enabled: true, binaryPath, homePath: "/pi/home" }),
        { ...process.env, PI_CODING_AGENT_DIR: "/omp/home" },
      );
      expect((yield* fileSystem.readFileString(homeLogPath)).trim()).toBe("/pi/home");

      yield* fileSystem.remove(homeLogPath);
      yield* checkPiProviderStatus(decodePiSettings({ enabled: true, binaryPath }), {
        ...process.env,
        PI_CODING_AGENT_DIR: "/omp/home",
      });
      // No home configured is NOT "inherit whatever is set": it means Pi's own
      // default, which it picks when the variable is absent.
      expect((yield* fileSystem.readFileString(homeLogPath)).trim()).toBe("");
    }),
=======
import * as NodeServices from "@effect/platform-node/NodeServices";
import { assert, describe, it } from "@effect/vitest";
import * as Effect from "effect/Effect";
import * as Sink from "effect/Sink";
import * as Stream from "effect/Stream";
import { ChildProcess, ChildProcessSpawner } from "effect/process";

import { checkPiProviderStatus, MINIMUM_PI_VERSION } from "./PiProvider.ts";

const encoder = new TextEncoder();

function processHandle(input: {
  readonly stdout?: string;
  readonly stderr?: string;
  readonly exitCode?: number;
}) {
  const bytes = (value: string | undefined) =>
    value === undefined || value.length === 0
      ? Stream.empty
      : Stream.succeed(encoder.encode(value));
  return ChildProcessSpawner.makeHandle({
    pid: ChildProcessSpawner.ProcessId(900_000_001),
    exitCode: Effect.succeed(ChildProcessSpawner.ExitCode(input.exitCode ?? 0)),
    isRunning: Effect.succeed(false),
    kill: () => Effect.void,
    unref: Effect.succeed(Effect.void),
    stdin: Sink.drain,
    stdout: bytes(input.stdout),
    stderr: bytes(input.stderr),
    all: Stream.empty,
    getInputFd: () => Sink.drain,
    getOutputFd: () => Stream.empty,
  });
}

function piProbeSpawner(version: string) {
  return ChildProcessSpawner.make((command) => {
    const args = ChildProcess.isStandardCommand(command) ? command.args : [];
    return Effect.succeed(
      args.includes("--version")
        ? processHandle({ stdout: `pi ${version}\n` })
        : processHandle({ stderr: "RPC startup failed", exitCode: 1 }),
    );
  });
}

const settings = {
  enabled: true,
  binaryPath: "pi",
  launchArgs: "",
  customModels: [],
} as const;

describe("PiProvider", () => {
  it.effect("requires the first published Pi version with entries and settlement hooks", () =>
    Effect.gen(function* () {
      const snapshot = yield* checkPiProviderStatus(settings).pipe(
        Effect.provideService(ChildProcessSpawner.ChildProcessSpawner, piProbeSpawner("0.80.3")),
      );
      assert.equal(snapshot.status, "error");
      assert.equal(snapshot.version, "0.80.3");
      assert.include(snapshot.message ?? "", `Pi ${MINIMUM_PI_VERSION} or newer`);
    }).pipe(Effect.provide(NodeServices.layer)),
  );

  it.effect("keeps compatible Pi selectable when optional discovery fails", () =>
    Effect.gen(function* () {
      const snapshot = yield* checkPiProviderStatus(settings).pipe(
        Effect.provideService(ChildProcessSpawner.ChildProcessSpawner, piProbeSpawner("0.84.3")),
      );
      assert.equal(snapshot.status, "ready");
      assert.equal(snapshot.auth.status, "unknown");
      assert.deepEqual(
        snapshot.models.map((model) => model.slug),
        ["default"],
      );
      assert.include(snapshot.message ?? "", "could not refresh its models and commands");
    }).pipe(Effect.provide(NodeServices.layer)),
>>>>>>> upstream-sync-cd41c4ada-upstream-renamed:apps/server/src/provider/PiProvider.test.ts
  );
});
