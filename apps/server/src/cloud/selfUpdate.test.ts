import * as NodeServices from "@effect/platform-node/NodeServices";
import { expect, it } from "@effect/vitest";
<<<<<<< HEAD
import { RunId, ServerSelfUpdateError, ThreadId } from "@infinitus/contracts";
=======
>>>>>>> upstream-sync-32ecd7172-upstream-renamed
import * as HostProcess from "@infinitus/shared/HostProcess";
import * as Deferred from "effect/Deferred";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Fiber from "effect/Fiber";
import * as Path from "effect/Path";
import * as Stream from "effect/Stream";
import * as TestClock from "effect/testing/TestClock";
import { HttpClient, HttpClientResponse } from "effect/http";
import * as ChildProcessSpawner from "effect/process/ChildProcessSpawner";

import packageJson from "../../package.json" with { type: "json" };
import * as ServerConfig from "../config.ts";
import * as DesktopAppUpdate from "../desktopUpdate/DesktopAppUpdate.ts";
import * as ProcessRunner from "../processRunner.ts";
import * as ServiceLauncherClient from "./serviceLauncherClient.ts";
import { SERVICE_LAUNCHER_PROTOCOL } from "./serviceProtocol.ts";
import * as ServerSelfUpdate from "./selfUpdate.ts";

interface HarnessOptions {
  readonly mode?: "web" | "desktop";
  readonly managed?: boolean;
  readonly preflight?: "ready" | "blocked";
  readonly beforeDownload?: Effect.Effect<void>;
  readonly requestUpdate?: ServiceLauncherClient.ServiceLauncherClient["Service"]["requestUpdate"];
  readonly desktopAppUpdate?: DesktopAppUpdate.DesktopAppUpdate["Service"];
}

const archiveBytes = new TextEncoder().encode("not really a tarball");
const releaseHttpClient = (order: string[], beforeDownload?: Effect.Effect<void>) =>
  HttpClient.make((request) =>
    Effect.gen(function* () {
      if (request.url.endsWith("/SHA256SUMS")) {
        const digest = yield* Effect.promise(() => crypto.subtle.digest("SHA-256", archiveBytes));
        const hex = Array.from(new Uint8Array(digest), (byte) =>
          byte.toString(16).padStart(2, "0"),
        ).join("");
        return HttpClientResponse.fromWeb(
          request,
          new Response(`${hex}  infinitus-1.1.0-linux-x64.tar.gz\n`),
        );
      }
      if (beforeDownload) yield* beforeDownload;
      order.push("download");
      return HttpClientResponse.fromWeb(request, new Response(archiveBytes));
    }),
  );

const makeHarness = Effect.fn("test.make_self_update_harness")(function* (
  options: HarnessOptions = {},
) {
  const fs = yield* FileSystem.FileSystem;
  const path = yield* Path.Path;
  const baseDir = yield* fs.makeTempDirectoryScoped({ prefix: "t3-self-update-test-" });
  const order: string[] = [];
  const runner = ProcessRunner.ProcessRunner.of({
    run: (input) =>
      Effect.gen(function* () {
        if (input.command === "tar") {
          order.push("extract");
          const stagingDir = input.args[input.args.indexOf("-C") + 1];
          if (stagingDir === undefined) return yield* Effect.die("missing tar target");
          yield* fs
            .writeFileString(path.join(stagingDir, "infinitus"), "#!/bin/sh\n")
            .pipe(Effect.orDie);
          return {
            stdout: "",
            stderr: "",
            code: ChildProcessSpawner.ExitCode(0),
            timedOut: false,
            stdoutTruncated: false,
            stderrTruncated: false,
            stdoutInvalidUtf8: false,
            stderrInvalidUtf8: false,
          };
        }
        order.push("preflight");
        const result =
          options.preflight === "blocked"
            ? { status: "blocked", version: "1.1.0", reason: "local update required" }
            : {
                status: "ready",
                version: "1.1.0",
                launcherProtocol: SERVICE_LAUNCHER_PROTOCOL,
              };
        return {
          stdout: JSON.stringify(result),
          stderr: "",
          code: ChildProcessSpawner.ExitCode(0),
          timedOut: false,
          stdoutTruncated: false,
          stderrTruncated: false,
          stdoutInvalidUtf8: false,
          stderrInvalidUtf8: false,
        };
      }),
  });
  const launcher = ServiceLauncherClient.ServiceLauncherClient.of({
    managed: options.managed ?? true,
    requestUpdate:
      options.requestUpdate ??
      (() =>
        Effect.sync(() => {
          order.push("accept");
          return "launcher-id";
        })),
    prepareTrial: Effect.undefined,
  });
  const config = yield* ServerConfig.ServerConfig.pipe(
    Effect.provide(ServerConfig.layerTest(process.cwd(), baseDir)),
  );
  const selfUpdate = yield* ServerSelfUpdate.make().pipe(
    Effect.provideService(ProcessRunner.ProcessRunner, runner),
    Effect.provideService(ServiceLauncherClient.ServiceLauncherClient, launcher),
    Effect.provideService(
      DesktopAppUpdate.DesktopAppUpdate,
      options.desktopAppUpdate ?? {
        available: false,
        run: () => Effect.die("unexpected desktop app update run"),
      },
    ),
    Effect.provideService(HttpClient.HttpClient, releaseHttpClient(order, options.beforeDownload)),
    Effect.provideService(HostProcess.Platform, "linux"),
    Effect.provideService(HostProcess.Architecture, "x64"),
    Effect.provide(ServerConfig.layer({ ...config, mode: options.mode ?? "web" })),
  );
  return { selfUpdate, order };
});

it.layer(NodeServices.layer)("server self update", (it) => {
<<<<<<< HEAD
  it.effect("refuses an update while a turn runs, naming the turns (#829)", () =>
    Effect.gen(function* () {
      const running = [{ threadId: ThreadId.make("thread-running"), turnId: RunId.make("run-1") }];
      const { selfUpdate: base, order } = yield* makeHarness();
      const selfUpdate = ServerSelfUpdate.withUpdateIdleGate({
        mode: "web",
        selfUpdate: base,
        runningTurns: Effect.succeed(running),
      });

      const error = yield* selfUpdate.update({ targetVersion: "1.1.0" }).pipe(Effect.flip);

      expect(error).toBeInstanceOf(ServerSelfUpdateError);
      expect(error.runningTurns).toEqual(running);
      expect(error.reason).toBe(
        "1 thread is running; updating now would interrupt it. Update when they finish, or stop them first.",
      );
      // Refused at the entry: nothing downloaded for nothing.
      expect(order).toEqual([]);
    }),
  );

  it.effect("interrupt passes the running turns and installs at once (#829)", () =>
    Effect.gen(function* () {
      const stages: string[] = [];
      const { selfUpdate: base, order } = yield* makeHarness();
      const selfUpdate = ServerSelfUpdate.withUpdateIdleGate({
        mode: "web",
        selfUpdate: base,
        runningTurns: Effect.succeed([
          { threadId: ThreadId.make("thread-running"), turnId: RunId.make("run-1") },
        ]),
      });

      const result = yield* selfUpdate.update(
        { targetVersion: "1.1.0", runningTurns: "interrupt" },
        (stage) => Effect.sync(() => void stages.push(stage)),
      );

      expect(result.method).toBe("boot-service");
      expect(stages).toEqual(["downloading", "installing"]);
      expect(order).toEqual(["download", "extract", "preflight", "accept"]);
    }),
  );

  it.effect(
    "waits for the running turns, reporting each change of count, and gates the install again (#829)",
    () =>
      Effect.gen(function* () {
        const events: string[] = [];
        let reads = 0;
        const turn = { threadId: ThreadId.make("thread-running"), turnId: RunId.make("run-1") };
        // After the download: two turns, still two, then one, then idle.
        const runningTurns = Effect.sync(() => {
          reads += 1;
          return reads <= 2
            ? [turn, { ...turn, turnId: RunId.make("run-2") }]
            : reads === 3
              ? [turn]
              : [];
        });
        const selfUpdate = ServerSelfUpdate.withUpdateIdleGate({
          mode: "web",
          selfUpdate: {
            update: (_input, reportProgress = () => Effect.void) =>
              reportProgress("downloading").pipe(
                Effect.andThen(reportProgress("installing")),
                Effect.as({ targetVersion: "1.1.0", method: "boot-service" as const }),
              ),
            commitDesktopUpdate: () => Effect.never,
          },
          runningTurns,
        });

        const fiber = yield* selfUpdate
          .update({ targetVersion: "1.1.0", runningTurns: "wait" }, (stage, count) =>
            Effect.sync(() => void events.push(count === undefined ? stage : `${stage}:${count}`)),
          )
          .pipe(Effect.forkChild);
        yield* TestClock.adjust(ServerSelfUpdate.RUNNING_TURNS_POLL);
        yield* TestClock.adjust(ServerSelfUpdate.RUNNING_TURNS_POLL);
        yield* TestClock.adjust(ServerSelfUpdate.RUNNING_TURNS_POLL);
        yield* Fiber.join(fiber);

        expect(events).toEqual(["downloading", "waiting:2", "waiting:1", "installing"]);
      }),
  );

  it.effect("gates the desktop commit under the policy its preparation used (#829)", () =>
    Effect.gen(function* () {
      let running: ReadonlyArray<{ threadId: ThreadId; turnId: RunId }> = [];
      const committed: string[] = [];
      const selfUpdate = ServerSelfUpdate.withUpdateIdleGate({
        mode: "desktop",
        selfUpdate: {
          update: () =>
            Effect.succeed({
              targetVersion: "1.1.0",
              method: "desktop-app" as const,
              desktopUpdateToken: "token-1",
            }),
          commitDesktopUpdate: (requestId) =>
            Effect.sync(() => void committed.push(requestId)).pipe(Effect.andThen(Effect.never)),
        },
        runningTurns: Effect.sync(() => running),
      });

      // The desktop run itself never waits (its own timeout bounds it): a
      // turn that starts after the download is met at the commit.
      yield* selfUpdate.update({ targetVersion: "1.1.0" });
      running = [{ threadId: ThreadId.make("thread-running"), turnId: RunId.make("run-1") }];
      const refused = yield* selfUpdate.commitDesktopUpdate("token-1").pipe(Effect.flip);
      expect(refused.runningTurns).toEqual(running);
      expect(committed).toEqual([]);

      const unknown = yield* selfUpdate.commitDesktopUpdate("token-unknown").pipe(Effect.flip);
      expect(unknown.runningTurns).toEqual(running);

      running = [];
      const fiber = yield* selfUpdate.commitDesktopUpdate("token-1").pipe(Effect.forkChild);
      yield* Effect.yieldNow;
      yield* Effect.yieldNow;
      expect(committed).toEqual(["token-1"]);
      yield* Fiber.interrupt(fiber);
    }),
  );

  it.effect("marks running threads at the boot-service handoff", () =>
    Effect.gen(function* () {
      const events: string[] = [];
      const selfUpdate = yield* ServerSelfUpdate.withRunningThreadContinuation({
        mode: "web",
        selfUpdate: {
          update: (_input, reportProgress = () => Effect.void) =>
            reportProgress("downloading").pipe(
              Effect.andThen(reportProgress("installing")),
              Effect.as({
                targetVersion: "1.1.0",
                method: "boot-service" as const,
                updateId: "update-id",
              }),
            ),
          commitDesktopUpdate: () => Effect.never,
        },
        prepare: Effect.sync(() => {
          events.push("prepare");
          return [ThreadId.make("thread-running")];
        }),
        clear: () => Effect.sync(() => void events.push("clear")),
      });

      yield* selfUpdate.update({ targetVersion: "1.1.0", continueRunningThreads: true }, (stage) =>
        Effect.sync(() => void events.push(stage)),
      );

      expect(events).toEqual(["downloading", "prepare", "installing"]);
    }),
  );

  it.effect("marks desktop threads only when the prepared update commits", () =>
    Effect.gen(function* () {
      const threadId = ThreadId.make("thread-running-desktop");
      const events: string[] = [];
      const commitError = new ServerSelfUpdateError({ reason: "install failed" });
      const selfUpdate = yield* ServerSelfUpdate.withRunningThreadContinuation({
        mode: "desktop",
        selfUpdate: {
          update: (_input, reportProgress = () => Effect.void) =>
            reportProgress("installing").pipe(
              Effect.as({
                targetVersion: "1.2.0",
                method: "desktop-app" as const,
                desktopUpdateToken: "desktop-token",
              }),
            ),
          commitDesktopUpdate: () =>
            Effect.sync(() => events.push("commit")).pipe(Effect.andThen(Effect.fail(commitError))),
        },
        prepare: Effect.sync(() => {
          events.push("prepare");
          return [threadId];
        }),
        clear: (threadIds) => Effect.sync(() => void events.push(`clear:${threadIds.join(",")}`)),
      });

      yield* selfUpdate.update({ targetVersion: "1.2.0", continueRunningThreads: true }, (stage) =>
        Effect.sync(() => void events.push(stage)),
      );
      expect(events).toEqual(["installing"]);
      expect(yield* selfUpdate.commitDesktopUpdate("desktop-token").pipe(Effect.flip)).toBe(
        commitError,
      );
      expect(events).toEqual(["installing", "prepare", "commit", `clear:${threadId}`]);
      expect(yield* selfUpdate.commitDesktopUpdate("desktop-token").pipe(Effect.flip)).toBe(
        commitError,
      );
      expect(events).toEqual([
        "installing",
        "prepare",
        "commit",
        `clear:${threadId}`,
        "prepare",
        "commit",
        `clear:${threadId}`,
      ]);
    }),
  );

  it.effect("keeps continuation markers after the boot-service handoff is accepted", () =>
    Effect.gen(function* () {
      const events: string[] = [];
      const selfUpdate = yield* ServerSelfUpdate.withRunningThreadContinuation({
        mode: "web",
        selfUpdate: {
          update: (
            _input,
            reportProgress = () => Effect.void,
            onHandoffAccepted = () => Effect.void,
          ) =>
            reportProgress("installing").pipe(
              Effect.andThen(onHandoffAccepted()),
              Effect.andThen(Effect.interrupt),
            ),
          commitDesktopUpdate: () => Effect.never,
        },
        prepare: Effect.sync(() => {
          events.push("prepare");
          return [ThreadId.make("thread-accepted-boot-handoff")];
        }),
        clear: () => Effect.sync(() => void events.push("clear")),
      });

      const exit = yield* selfUpdate
        .update({ targetVersion: "1.1.0", continueRunningThreads: true })
        .pipe(Effect.exit);

      expect(exit._tag).toBe("Failure");
      expect(events).toEqual(["prepare"]);
    }),
  );

  it.effect("clears continuation markers for mixed failure and interrupt causes", () =>
    Effect.gen(function* () {
      const events: string[] = [];
      const commitError = new ServerSelfUpdateError({ reason: "install failed" });
      const selfUpdate = yield* ServerSelfUpdate.withRunningThreadContinuation({
        mode: "desktop",
        selfUpdate: {
          update: () =>
            Effect.succeed({
              targetVersion: "1.2.0",
              method: "desktop-app" as const,
              desktopUpdateToken: "failed-desktop-token",
            }),
          commitDesktopUpdate: (_requestId, onHandoffAccepted = () => Effect.void) =>
            onHandoffAccepted().pipe(
              Effect.andThen(
                Effect.failCause(
                  Cause.fromReasons([
                    Cause.makeFailReason(commitError),
                    Cause.makeInterruptReason(),
                  ]),
                ),
              ),
            ),
        },
        prepare: Effect.sync(() => [ThreadId.make("thread-failed-desktop-install")]),
        clear: () => Effect.sync(() => void events.push("clear")),
      });

      yield* selfUpdate.update({
        targetVersion: "1.2.0",
        continueRunningThreads: true,
      });
      const exit = yield* selfUpdate.commitDesktopUpdate("failed-desktop-token").pipe(Effect.exit);
      expect(exit._tag).toBe("Failure");
      if (exit._tag === "Failure") {
        expect(Cause.hasInterrupts(exit.cause)).toBe(true);
        expect(Cause.hasInterruptsOnly(exit.cause)).toBe(false);
      }
      expect(events).toEqual(["clear"]);
    }),
  );

=======
>>>>>>> upstream-sync-32ecd7172-upstream-renamed
  // regression: #5181 make remote updates rollback-safe
  it.effect("rejects invalid versions and desktop-managed servers before staging", () =>
    Effect.gen(function* () {
      const web = yield* makeHarness();
      expect(
        (yield* web.selfUpdate.update({ targetVersion: "latest" }).pipe(Effect.flip)).reason,
      ).toBe("'latest' is not an exact t3 version.");
      const desktop = yield* makeHarness({ mode: "desktop" });
      expect(
        (yield* desktop.selfUpdate.update({ targetVersion: "1.1.0" }).pipe(Effect.flip)).reason,
      ).toContain("desktop app");
      expect([...web.order, ...desktop.order]).toEqual([]);
    }),
  );

  it.effect("delegates desktop-managed updates to the desktop app when available", () =>
    Effect.gen(function* () {
      const stages: string[] = [];
      const { selfUpdate, order } = yield* makeHarness({
        mode: "desktop",
        desktopAppUpdate: {
          available: true,
          run: (reportProgress) =>
            reportProgress("downloading").pipe(
              Effect.andThen(reportProgress("installing")),
              Effect.as({ targetVersion: "1.2.0", method: "desktop-app" as const }),
            ),
          commit: () => Effect.never,
        },
      });
      const result = yield* selfUpdate.update({ targetVersion: "1.1.0" }, (stage) =>
        Effect.sync(() => void stages.push(stage)),
      );
      expect(result).toEqual({ targetVersion: "1.2.0", method: "desktop-app" });
      expect(stages).toEqual(["downloading", "installing"]);
      expect(order).toEqual([]);
    }),
  );

  it.effect("allows only one update at a time", () =>
    Effect.gen(function* () {
      const requested = yield* Deferred.make<void>();
      const accepted = yield* Deferred.make<string>();
      const { selfUpdate } = yield* makeHarness({
        requestUpdate: () =>
          Deferred.succeed(requested, undefined).pipe(Effect.andThen(Deferred.await(accepted))),
      });
      const first = yield* Effect.forkChild(selfUpdate.update({ targetVersion: "1.1.0" }), {
        startImmediately: true,
      });
      yield* Deferred.await(requested);
      expect((yield* selfUpdate.update({ targetVersion: "1.1.1" }).pipe(Effect.flip)).reason).toBe(
        "A server update is already in progress.",
      );
      yield* Deferred.succeed(accepted, "launcher-id");
      expect((yield* Fiber.join(first)).updateId).toBe("launcher-id");
    }),
  );

  it.effect("keeps preparing after the progress stream closes", () =>
    Effect.gen(function* () {
      const releaseDownload = yield* Deferred.make<void>();
      const sawDownloading = yield* Deferred.make<void>();
      const accepted = yield* Deferred.make<void>();
      const { selfUpdate, order } = yield* makeHarness({
        beforeDownload: Deferred.await(releaseDownload),
        requestUpdate: () =>
          Effect.sync(() => {
            order.push("accept");
          }).pipe(Effect.andThen(Deferred.succeed(accepted, undefined)), Effect.as("launcher-id")),
      });

      const consumed = yield* ServerSelfUpdate.updateProgressStream(selfUpdate, {
        targetVersion: "1.1.0",
      }).pipe(
        Stream.tap((event) =>
          event.type === "progress" && event.stage === "downloading"
            ? Deferred.succeed(sawDownloading, undefined)
            : Effect.void,
        ),
        Stream.runDrain,
        Effect.forkChild,
      );

      yield* Deferred.await(sawDownloading);
      yield* Fiber.interrupt(consumed);
      expect((yield* selfUpdate.update({ targetVersion: "1.2.0" }).pipe(Effect.flip)).reason).toBe(
        "A server update is already in progress.",
      );

      yield* Deferred.succeed(releaseDownload, undefined);
      yield* Deferred.await(accepted);
      expect(order).toEqual(["download", "extract", "preflight", "accept"]);
      expect((yield* selfUpdate.update({ targetVersion: "1.1.0" }).pipe(Effect.flip)).reason).toBe(
        "A server update is already in progress.",
      );
    }),
  );
});

it.layer(NodeServices.layer)("pruning runtimes on start", (it) => {
  const staleVersion = "0.0.1";
  const otherProcesses = ProcessRunner.ProcessRunner.of({
    run: () =>
      Effect.succeed({
        stdout: "p42\nftxt\nn/bin/sh\n",
        stderr: "",
        code: ChildProcessSpawner.ExitCode(0),
        timedOut: false,
        stdoutTruncated: false,
        stderrTruncated: false,
        stdoutInvalidUtf8: false,
        stderrInvalidUtf8: false,
      }),
  });

  const pruneOnStart = Effect.fn("test.prune_on_start")(function* (input: {
    readonly executable: "own runtime" | "elsewhere";
    readonly managed?: boolean;
    readonly symlinkedHome?: boolean;
  }) {
    const fs = yield* FileSystem.FileSystem;
    const path = yield* Path.Path;
    const tempDir = yield* fs.makeTempDirectoryScoped({ prefix: "t3-prune-on-start-" });
    const realHome = path.join(tempDir, "home");
    const baseDir = input.symlinkedHome ? path.join(tempDir, "linked-home") : realHome;
    const versionsDir = path.join(baseDir, "runtime", "versions");
    yield* TestClock.setTime(24 * 60 * 60 * 1000);
    for (const version of [staleVersion, packageJson.version]) {
      const directory = path.join(realHome, "runtime", "versions", version);
      yield* fs.makeDirectory(directory, { recursive: true });
      yield* fs.writeFileString(path.join(directory, "infinitus"), "");
      const sentinel = path.join(directory, ".install-complete");
      yield* fs.writeFileString(sentinel, `${version}\n`);
      yield* fs.utimes(sentinel, 0, 0);
    }
    if (input.symlinkedHome) yield* fs.symlink(realHome, baseDir);
    // Like `process.execPath`, the running runtime is reported by its real path.
    const executablePath =
      input.executable === "own runtime"
        ? yield* fs.realPath(path.join(versionsDir, packageJson.version, "infinitus"))
        : "/usr/local/bin/node";
    const removed = yield* ServerSelfUpdate.pruneRuntimesOnStart({
      baseDir,
      managed: input.managed ?? false,
    }).pipe(
      Effect.provideService(HostProcess.ExecutablePath, executablePath),
      Effect.provideService(HostProcess.Platform, "darwin"),
      Effect.provideService(HostProcess.Environment, {}),
      Effect.provideService(ProcessRunner.ProcessRunner, otherProcesses),
    );
    return { removed, remaining: (yield* fs.readDirectory(versionsDir)).toSorted() };
  });

  // The SSH launcher runs `infinitus serve` straight from the pinned runtime, with no boot service.
  it.effect("prunes for a server started from its home's pinned runtime", () =>
    Effect.gen(function* () {
      const { removed, remaining } = yield* pruneOnStart({ executable: "own runtime" });
      expect(removed).toEqual([staleVersion]);
      expect(remaining).toEqual([packageJson.version]);
    }),
  );

  it.effect("recognizes its runtime through a symlinked T3 home", () =>
    Effect.gen(function* () {
      const { removed } = yield* pruneOnStart({ executable: "own runtime", symlinkedHome: true });
      expect(removed).toEqual([staleVersion]);
    }),
  );

  it.effect("prunes for a boot-service server wherever it runs from", () =>
    Effect.gen(function* () {
      const { removed } = yield* pruneOnStart({ executable: "elsewhere", managed: true });
      expect(removed).toEqual([staleVersion]);
    }),
  );

  it.effect("leaves runtimes alone for an unmanaged server started elsewhere", () =>
    Effect.gen(function* () {
      const { removed, remaining } = yield* pruneOnStart({ executable: "elsewhere" });
      expect(removed).toEqual([]);
      expect(remaining).toEqual([staleVersion, packageJson.version].toSorted());
    }),
  );
});

it("a host crosses tracks only to a release that knows its whole database", () => {
  const cross = (
    serverVersion: string,
    targetVersion: string,
    targetDatabaseMigration: number | undefined,
    databaseMigration = 72,
  ) =>
    ServerSelfUpdate.trackSwitchBlockReason({
      serverVersion,
      targetVersion,
      targetDatabaseMigration,
      databaseMigration: () => databaseMigration,
    });
  const nightly = "0.1.4-nightly.20261027.3796";

  expect(cross(nightly, "0.1.4", 72)).toBeNull();
  // Another client moved this host to a newer Nightly after the switch was planned.
  expect(cross(nightly, "0.1.4", 72, 73)).toContain("does not support yet");
  expect(cross(nightly, "0.1.4", undefined)).toContain("Cannot confirm");
  // A Stable tag can carry a migration the latest Nightly lacks.
  expect(cross("0.1.4", nightly, 72, 73)).toContain("does not support yet");
  expect(cross("0.1.3", "0.1.4", undefined)).toBeNull();
  // A database that exists but cannot be read proves nothing.
  expect(
    ServerSelfUpdate.trackSwitchBlockReason({
      serverVersion: nightly,
      targetVersion: "0.1.4",
      targetDatabaseMigration: 72,
      databaseMigration: () => undefined,
    }),
  ).toContain("Cannot confirm");
});
