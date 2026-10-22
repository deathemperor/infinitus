import {
  ServerSelfUpdateError,
  type ServerSelfUpdateCapability,
  type ServerSelfUpdateInput,
  type ServerSelfUpdateProgressEvent,
  type ServerSelfUpdateProgressStage,
  type ServerRunningTurn,
  type ServerSelfUpdateResult,
  type ServerUpdateRunningTurnsPolicy,
  type ThreadId,
} from "@infinitus/contracts";
import { PRODUCT_NAME } from "@infinitus/shared/productName";
import * as HostProcess from "@infinitus/shared/HostProcess";
import * as Cause from "effect/Cause";
import * as Config from "effect/Config";
import * as Context from "effect/Context";
import * as Duration from "effect/Duration";
import * as Effect from "effect/Effect";
import * as HashSet from "effect/HashSet";
import * as Option from "effect/Option";
import * as Ref from "effect/Ref";
import * as FileSystem from "effect/FileSystem";
import * as Layer from "effect/Layer";
import * as Path from "effect/Path";
import * as Queue from "effect/Queue";
import * as Stream from "effect/Stream";
import { HttpClient } from "effect/http";

import { CLI_RELEASE_BASE_URL_ENV } from "@infinitus/shared/cliRelease";

import packageJson from "../../package.json" with { type: "json" };
import * as ServerConfig from "../config.ts";
import * as DesktopAppUpdate from "../desktopUpdate/DesktopAppUpdate.ts";
import { InfinitusRunningTurns } from "../infinitus/Services/InfinitusRunningTurns.ts";
import * as ProcessRunner from "../processRunner.ts";
import {
  ensurePinnedRuntimeInstalled,
  pinnedRuntimeCommand,
  PinnedRuntimeInstallError,
  pinnedRuntimePaths,
  PinnedRuntimePreflightBlockedError,
  prunePinnedRuntimes,
} from "./pinnedRuntime.ts";
import { decodeServicePreflightResult } from "./servicePreflight.ts";
import * as ServiceLauncherClient from "./serviceLauncherClient.ts";
import { isExactServiceVersion, SERVICE_LAUNCHER_PROTOCOL } from "./serviceProtocol.ts";

const PREFLIGHT_TIMEOUT = Duration.seconds(30);

export function resolveServerSelfUpdateCapability(input: {
  readonly desktopManaged: boolean;
  readonly launcherManaged: boolean;
}): ServerSelfUpdateCapability | null {
  if (input.desktopManaged) return "desktop-managed" as const;
  return input.launcherManaged ? ("boot-service" as const) : null;
}

export class ServerSelfUpdate extends Context.Service<
  ServerSelfUpdate,
  {
    readonly update: (
      input: ServerSelfUpdateInput,
      reportProgress?: (
        stage: ServerSelfUpdateProgressStage,
        runningTurns?: number,
      ) => Effect.Effect<void, ServerSelfUpdateError>,
      onHandoffAccepted?: () => Effect.Effect<void>,
    ) => Effect.Effect<ServerSelfUpdateResult, ServerSelfUpdateError>;
    readonly commitDesktopUpdate: (
      requestId: string,
      onHandoffAccepted?: () => Effect.Effect<void>,
    ) => Effect.Effect<never, ServerSelfUpdateError>;
  }
>()("t3/cloud/selfUpdate/ServerSelfUpdate") {}

/** How often a `wait` update re-reads the running turns (#829). */
export const RUNNING_TURNS_POLL = Duration.seconds(5);

function runningTurnsRefusal(count: number): string {
  return `${count} ${count === 1 ? "thread is" : "threads are"} running; updating now would interrupt ${count === 1 ? "it" : "them"}. Update when they finish, or stop them first.`;
}

/**
 * Fork (#829): the update idle gate, over the service that does the update.
 * `interrupt` passes, `refuse` fails naming the turns, `wait` polls until
 * none runs, reporting each change of count. An update refuses at its entry
 * (nothing downloaded for nothing) and waits at the install hook, after the
 * download; in desktop mode the install is the commit, which
 * `commitDesktopUpdate` gates under the policy the preparation used (an
 * unknown token = `refuse`; the desktop app's own update run is bounded by
 * a timeout, so no wait happens inside it).
 */
export const withUpdateIdleGate = (input: {
  readonly mode: ServerConfig.RuntimeMode;
  readonly selfUpdate: ServerSelfUpdate["Service"];
  /** The server's own running turns, read at the request and again right
      before the install, since a turn may start in between. */
  readonly runningTurns: Effect.Effect<ReadonlyArray<ServerRunningTurn>>;
}): ServerSelfUpdate["Service"] => {
  const desktopPolicies = new Map<string, ServerUpdateRunningTurnsPolicy>();

  const awaitIdle = Effect.fn("selfUpdate.awaitIdle")(function* (
    policy: ServerUpdateRunningTurnsPolicy,
    reportProgress: (
      stage: ServerSelfUpdateProgressStage,
      runningTurns?: number,
    ) => Effect.Effect<void, ServerSelfUpdateError>,
  ): Effect.fn.Return<void, ServerSelfUpdateError> {
    if (policy === "interrupt") return;
    let announced = -1;
    while (true) {
      const running = yield* input.runningTurns;
      if (running.length === 0) return;
      if (policy === "refuse") {
        return yield* Effect.fail(
          new ServerSelfUpdateError({
            reason: runningTurnsRefusal(running.length),
            runningTurns: running,
          }),
        );
      }
      if (running.length !== announced) {
        announced = running.length;
        yield* reportProgress("waiting", running.length);
      }
      yield* Effect.sleep(RUNNING_TURNS_POLL);
    }
  });

  return ServerSelfUpdate.of({
    update: (request, reportProgress = () => Effect.void, onHandoffAccepted) => {
      const policy = request.runningTurns ?? "refuse";
      return (policy === "refuse" ? awaitIdle(policy, reportProgress) : Effect.void).pipe(
        Effect.andThen(
          input.selfUpdate.update(
            request,
            (stage, runningTurns) =>
              (stage === "installing" && input.mode !== "desktop"
                ? awaitIdle(policy, reportProgress)
                : Effect.void
              ).pipe(Effect.andThen(reportProgress(stage, runningTurns))),
            onHandoffAccepted,
          ),
        ),
        Effect.tap((result) =>
          Effect.sync(() => {
            if (result.method === "desktop-app" && result.desktopUpdateToken !== undefined) {
              desktopPolicies.set(result.desktopUpdateToken, policy);
            }
          }),
        ),
      );
    },
    // The gate again: this is the quit.
    commitDesktopUpdate: (requestId, onHandoffAccepted) =>
      awaitIdle(desktopPolicies.get(requestId) ?? "refuse", () => Effect.void).pipe(
        Effect.andThen(Effect.sync(() => desktopPolicies.delete(requestId))),
        Effect.andThen(input.selfUpdate.commitDesktopUpdate(requestId, onHandoffAccepted)),
      ),
  });
};

export const withRunningThreadContinuation = Effect.fn(
  "cloud.server_self_update.withRunningThreadContinuation",
)(function* (input: {
  readonly mode: ServerConfig.RuntimeMode;
  readonly selfUpdate: ServerSelfUpdate["Service"];
  readonly prepare: Effect.Effect<ReadonlyArray<ThreadId>, ServerSelfUpdateError>;
  readonly clear: (
    threadIds: ReadonlyArray<ThreadId>,
  ) => Effect.Effect<void, ServerSelfUpdateError>;
}) {
  const desktopContinuationTokens = yield* Ref.make(HashSet.empty<string>());
  const clearOnError = <A>(
    effect: Effect.Effect<A, ServerSelfUpdateError>,
    threadIds: () => ReadonlyArray<ThreadId>,
    handoffAccepted: () => boolean,
  ): Effect.Effect<A, ServerSelfUpdateError> =>
    effect.pipe(
      Effect.catchCause((cause) =>
        (handoffAccepted() && Cause.hasInterruptsOnly(cause)
          ? Effect.void
          : input.clear(threadIds())
        ).pipe(Effect.andThen(Effect.failCause(cause))),
      ),
    );

  const update: ServerSelfUpdate["Service"]["update"] = (
    request,
    reportProgress = () => Effect.void,
  ) => {
    let prepared = false;
    let handoffAccepted = false;
    let continuationThreadIds: ReadonlyArray<ThreadId> = [];
    return clearOnError(
      input.selfUpdate
        .update(
          request,
          (stage) =>
            (request.continueRunningThreads === true &&
            input.mode !== "desktop" &&
            stage === "installing" &&
            !prepared
              ? input.prepare.pipe(
                  Effect.tap((threadIds) =>
                    Effect.sync(() => {
                      prepared = true;
                      continuationThreadIds = threadIds;
                    }),
                  ),
                  Effect.asVoid,
                )
              : Effect.void
            ).pipe(Effect.andThen(reportProgress(stage))),
          () =>
            Effect.sync(() => {
              handoffAccepted = true;
            }),
        )
        .pipe(
          Effect.tap((result) => {
            if (
              result.method === "desktop-app" &&
              result.desktopUpdateToken !== undefined &&
              request.continueRunningThreads === true
            ) {
              return Ref.update(desktopContinuationTokens, HashSet.add(result.desktopUpdateToken));
            }
            return Effect.void;
          }),
        ),
      () => continuationThreadIds,
      () => handoffAccepted,
    );
  };

  return ServerSelfUpdate.of({
    update,
    commitDesktopUpdate: Effect.fn("selfUpdate.commitDesktopUpdate")(function* (requestId) {
      const shouldContinue = yield* Ref.modify(desktopContinuationTokens, (tokens) => [
        HashSet.has(tokens, requestId),
        HashSet.remove(tokens, requestId),
      ]);
      let handoffAccepted = false;
      let continuationThreadIds: ReadonlyArray<ThreadId> = [];
      return yield* clearOnError(
        Effect.gen(function* () {
          continuationThreadIds = shouldContinue ? yield* input.prepare : [];
          return yield* input.selfUpdate.commitDesktopUpdate(requestId, () =>
            Effect.sync(() => {
              handoffAccepted = true;
            }),
          );
        }),
        () => continuationThreadIds,
        () => handoffAccepted,
      ).pipe(
        Effect.catchCause((cause) =>
          (shouldContinue && !handoffAccepted
            ? Ref.update(desktopContinuationTokens, HashSet.add(requestId))
            : Effect.void
          ).pipe(Effect.andThen(Effect.failCause(cause))),
        ),
      );
    }),
  });
});

/**
 * A server starting from the runtime its launcher settled on means runtimes left by earlier
 * updates can go. The boot service says so through its IPC context. The SSH launcher and the
 * install script's `infinitus` start this home's pinned runtime directly, without one.
 */
export const pruneRuntimesOnStart = Effect.fn("cloud.server_self_update.prune_on_start")(
  function* (input: { readonly baseDir: string; readonly managed: boolean }) {
    const fs = yield* FileSystem.FileSystem;
    const path = yield* Path.Path;
    const platform = yield* HostProcess.Platform;
    const executablePath = yield* HostProcess.ExecutablePath;
    const { entryPath } = pinnedRuntimePaths(path, input.baseDir, packageJson.version, platform);
    // The executable path is resolved, so it names the real path of a symlinked T3 home.
    const realEntryPath = yield* fs.realPath(entryPath).pipe(Effect.orElseSucceed(() => entryPath));
    if (!input.managed && executablePath !== entryPath && executablePath !== realEntryPath) {
      return [];
    }
    const removed = yield* prunePinnedRuntimes({
      baseDir: input.baseDir,
      keep: [packageJson.version],
    });
    if (removed.length > 0) {
      yield* Effect.logInfo("Removed unused infinitus runtimes.", { versions: removed });
    }
    return removed;
  },
);

export const make = Effect.fn("cloud.server_self_update.make")(function* () {
  const serverConfig = yield* ServerConfig.ServerConfig;
  const desktopAppUpdate = yield* DesktopAppUpdate.DesktopAppUpdate;
  const launcher = yield* ServiceLauncherClient.ServiceLauncherClient;
  const runner = yield* ProcessRunner.ProcessRunner;
  const fs = yield* FileSystem.FileSystem;
  const path = yield* Path.Path;
  const platform = yield* HostProcess.Platform;
  const arch = yield* HostProcess.Architecture;
  const httpClient = yield* HttpClient.HttpClient;
  const releaseBaseUrl = Option.getOrUndefined(
    yield* Config.String(CLI_RELEASE_BASE_URL_ENV).pipe(Config.option),
  );
  const inFlight = yield* Ref.make(false);

  yield* pruneRuntimesOnStart({ baseDir: serverConfig.baseDir, managed: launcher.managed }).pipe(
    Effect.forkScoped,
  );

  const capability: ServerSelfUpdateCapability | null =
    serverConfig.mode === "desktop" ? "desktop-managed" : launcher.managed ? "boot-service" : null;
  const failWith = (reason: string, cause?: unknown) =>
    cause === undefined
      ? new ServerSelfUpdateError({ reason })
      : new ServerSelfUpdateError({ reason, cause });

  const update: ServerSelfUpdate["Service"]["update"] = Effect.fn(
    "cloud.server_self_update.update",
  )(function* (input, reportProgress = () => Effect.void, onHandoffAccepted = () => Effect.void) {
    if (capability === "desktop-managed") {
      if (desktopAppUpdate.available) {
        return yield* desktopAppUpdate.run(reportProgress);
      }
      return yield* failWith(
        `This server is managed by the ${PRODUCT_NAME} desktop app on its machine; update the desktop app to update it.`,
      );
    }
    if (capability === null) {
      return yield* failWith(
        `Remote updates require the ${PRODUCT_NAME} background service. Run \`t3 service install\` on the server machine.`,
      );
    }

    const targetVersion = input.targetVersion.trim();
    if (!isExactServiceVersion(targetVersion)) {
      return yield* failWith(`'${targetVersion}' is not an exact t3 version.`);
    }
    if (yield* Ref.getAndSet(inFlight, true)) {
      return yield* failWith("A server update is already in progress.");
    }

    return yield* Effect.gen(function* () {
      yield* reportProgress("downloading");
      const paths = yield* ensurePinnedRuntimeInstalled({
        baseDir: serverConfig.baseDir,
        version: targetVersion,
        fs,
        path,
        runner,
        httpClient,
        platform,
        arch,
        releaseBaseUrl,
        validate: (runtime) =>
          runner
            .run({
              command: pinnedRuntimeCommand(runtime).command,
              args: [
                ...pinnedRuntimeCommand(runtime).args,
                "__service-preflight",
                "--database-path",
                serverConfig.dbPath,
                "--launcher-protocol",
                String(SERVICE_LAUNCHER_PROTOCOL),
              ],
              timeout: PREFLIGHT_TIMEOUT,
            })
            .pipe(
              Effect.mapError(
                (cause) =>
                  new PinnedRuntimeInstallError({
                    step: "running the staged service preflight",
                    cause,
                  }),
              ),
              Effect.flatMap(
                (
                  result,
                ): Effect.Effect<
                  void,
                  PinnedRuntimeInstallError | PinnedRuntimePreflightBlockedError
                > => {
                  if (result.code !== 0) {
                    return Effect.fail(
                      new PinnedRuntimeInstallError({
                        step: "running the staged service preflight",
                        exitCode: Number(result.code),
                        stdoutLength: result.stdout.length,
                        stderrLength: result.stderr.length,
                      }),
                    );
                  }
                  let parsed: unknown;
                  try {
                    parsed = JSON.parse(result.stdout.trim());
                  } catch (cause) {
                    return Effect.fail(
                      new PinnedRuntimeInstallError({
                        step: "decoding the staged service preflight",
                        cause,
                      }),
                    );
                  }
                  const preflight = decodeServicePreflightResult(parsed);
                  if (preflight === undefined || preflight.version !== targetVersion) {
                    return Effect.fail(
                      new PinnedRuntimeInstallError({
                        step: "verifying the staged service preflight",
                      }),
                    );
                  }
                  return preflight.status === "ready"
                    ? Effect.void
                    : Effect.fail(
                        new PinnedRuntimePreflightBlockedError({
                          version: targetVersion,
                          reason: preflight.reason,
                        }),
                      );
                },
              ),
            ),
      }).pipe(
        Effect.mapError((error) =>
          error._tag === "PinnedRuntimePreflightBlockedError"
            ? failWith(error.reason, error)
            : failWith(`Could not prepare t3@${targetVersion}.`, error),
        ),
      );

      yield* reportProgress("installing");
      const updateId = yield* Effect.uninterruptible(
        launcher.requestUpdate({ targetVersion, dbPath: serverConfig.dbPath }).pipe(
          Effect.mapError((error) =>
            failWith(
              error._tag === "ServiceLauncherRejectedError"
                ? error.reason
                : "Could not ask the service launcher to activate the prepared update.",
              error,
            ),
          ),
          Effect.tap(() => onHandoffAccepted()),
        ),
      );

      yield* Effect.logInfo("Server update prepared; handing off to the service launcher.", {
        updateId,
        targetVersion,
        runtimePath: paths.entryPath,
      });
      return { targetVersion, method: "boot-service" as const, updateId };
    }).pipe(Effect.onError(() => Ref.set(inFlight, false)));
  });

  return ServerSelfUpdate.of({
    update,
    commitDesktopUpdate: (requestId, onHandoffAccepted) =>
      desktopAppUpdate.commit(requestId, onHandoffAccepted),
  });
});

export const layer = Layer.effect(
  ServerSelfUpdate,
  Effect.gen(function* () {
    // Fork (#829): the update refuses or waits while a turn runs.
    const serverConfig = yield* ServerConfig.ServerConfig;
    const runningTurns = yield* InfinitusRunningTurns;
    return withUpdateIdleGate({
      mode: serverConfig.mode,
      selfUpdate: yield* make(),
      runningTurns: runningTurns.list,
    });
  }),
).pipe(Layer.provide(ProcessRunner.layer));

// The RPC stream used to own this fiber, so a dropped client socket interrupted
// the download. Offers after the queue shuts down are ignored; the update
// still finishes, and the in-flight guard stays as it was.
export const updateProgressStream = (
  selfUpdate: ServerSelfUpdate["Service"],
  input: ServerSelfUpdateInput,
) =>
  Stream.callback<ServerSelfUpdateProgressEvent, ServerSelfUpdateError>((queue) => {
    const offer = (event: ServerSelfUpdateProgressEvent) =>
      Queue.offer(queue, event).pipe(Effect.ignore);

    return selfUpdate
      .update(input, (stage, runningTurns) =>
        offer({
          type: "progress",
          stage,
          ...(runningTurns !== undefined ? { runningTurns } : {}),
        }),
      )
      .pipe(
        Effect.flatMap((result) => offer({ type: "complete", result })),
        Effect.catchTags({
          ServerSelfUpdateError: (error) => Queue.fail(queue, error).pipe(Effect.ignore),
        }),
        Effect.andThen(Queue.end(queue).pipe(Effect.ignore)),
        Effect.forkDetach,
      );
  });
