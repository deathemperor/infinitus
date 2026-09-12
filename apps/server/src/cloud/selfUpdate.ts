import {
  ServerSelfUpdateError,
  type ServerSelfUpdateCapability,
  type ServerSelfUpdateInput,
  type ServerSelfUpdateProgressStage,
  type ServerRunningTurn,
  type ServerSelfUpdateResult,
  type ServerUpdateRunningTurnsPolicy,
  type ThreadId,
} from "@t3tools/contracts";
import { HostProcessExecutablePath } from "@t3tools/shared/hostProcess";
import { PRODUCT_NAME } from "@t3tools/shared/productName";
import * as Cause from "effect/Cause";
import * as Context from "effect/Context";
import * as Duration from "effect/Duration";
import * as Effect from "effect/Effect";
import * as HashSet from "effect/HashSet";
import * as Ref from "effect/Ref";
import * as FileSystem from "effect/FileSystem";
import * as Layer from "effect/Layer";
import * as Path from "effect/Path";

import * as ServerConfig from "../config.ts";
import * as DesktopAppUpdate from "../desktopUpdate/DesktopAppUpdate.ts";
import * as ProcessRunner from "../processRunner.ts";
import {
  ensurePinnedRuntimeInstalled,
  PinnedRuntimeInstallError,
  PinnedRuntimePreflightBlockedError,
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
export const RUNNING_TURNS_POLL = Duration.seconds(2);

export function runningTurnsRefusal(count: number): string {
  return `${count} ${count === 1 ? "thread is" : "threads are"} running; updating now would interrupt ${count === 1 ? "it" : "them"}. Update when they finish, or stop them first.`;
}

export const withRunningThreadContinuation = Effect.fn(
  "cloud.server_self_update.withRunningThreadContinuation",
)(function* (input: {
  readonly mode: ServerConfig.RuntimeMode;
  readonly selfUpdate: ServerSelfUpdate["Service"];
  readonly prepare: Effect.Effect<ReadonlyArray<ThreadId>, ServerSelfUpdateError>;
  readonly clear: (
    threadIds: ReadonlyArray<ThreadId>,
  ) => Effect.Effect<void, ServerSelfUpdateError>;
  /** The server's own running turns (#829), read at the request and again
      right before the install, since a turn may start in between. */
  readonly runningTurns: Effect.Effect<ReadonlyArray<ServerRunningTurn>>;
}) {
  const desktopContinuationTokens = yield* Ref.make(HashSet.empty<string>());
  // The policy a desktop preparation was made under, keyed by its token: the
  // quit happens at the commit, so the gate applies there too.
  const desktopPolicies = new Map<string, ServerUpdateRunningTurnsPolicy>();

  /** The gate (#829): `interrupt` passes, `refuse` fails naming the turns,
      `wait` polls until none runs, reporting each change of count. */
  const awaitIdle = (
    policy: ServerUpdateRunningTurnsPolicy,
    reportProgress: (
      stage: ServerSelfUpdateProgressStage,
      runningTurns?: number,
    ) => Effect.Effect<void, ServerSelfUpdateError>,
  ): Effect.Effect<void, ServerSelfUpdateError> =>
    Effect.gen(function* () {
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
    const policy = request.runningTurns ?? "refuse";
    let prepared = false;
    let handoffAccepted = false;
    let continuationThreadIds: ReadonlyArray<ThreadId> = [];
    return clearOnError(
      awaitIdle(policy, reportProgress).pipe(
        Effect.andThen(
          input.selfUpdate.update(
            request,
            (stage) =>
              (stage === "installing" ? awaitIdle(policy, reportProgress) : Effect.void).pipe(
                Effect.andThen(
                  request.continueRunningThreads === true &&
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
                    : Effect.void,
                ),
                Effect.andThen(reportProgress(stage)),
              ),
            () =>
              Effect.sync(() => {
                handoffAccepted = true;
              }),
          ),
        ),
        Effect.tap((result) => {
          if (result.method === "desktop-app" && result.desktopUpdateToken !== undefined) {
            desktopPolicies.set(result.desktopUpdateToken, policy);
            if (request.continueRunningThreads === true) {
              return Ref.update(desktopContinuationTokens, HashSet.add(result.desktopUpdateToken));
            }
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
    commitDesktopUpdate: (requestId) =>
      Effect.gen(function* () {
        const shouldContinue = yield* Ref.modify(desktopContinuationTokens, (tokens) => [
          HashSet.has(tokens, requestId),
          HashSet.remove(tokens, requestId),
        ]);
        let handoffAccepted = false;
        let continuationThreadIds: ReadonlyArray<ThreadId> = [];
        return yield* clearOnError(
          Effect.gen(function* () {
            // The gate again (#829): this is the quit. A token this server
            // did not prepare is treated as `refuse`.
            yield* awaitIdle(desktopPolicies.get(requestId) ?? "refuse", () => Effect.void);
            desktopPolicies.delete(requestId);
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

export const make = Effect.fn("cloud.server_self_update.make")(function* () {
  const serverConfig = yield* ServerConfig.ServerConfig;
  const desktopAppUpdate = yield* DesktopAppUpdate.DesktopAppUpdate;
  const launcher = yield* ServiceLauncherClient.ServiceLauncherClient;
  const runner = yield* ProcessRunner.ProcessRunner;
  const fs = yield* FileSystem.FileSystem;
  const path = yield* Path.Path;
  const execPath = yield* HostProcessExecutablePath;
  const inFlight = yield* Ref.make(false);

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
      // input.targetVersion is meaningless here: the desktop app's own
      // update feed decides what it downloads, and the result carries what
      // it actually got.
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
        validate: (runtime) =>
          runner
            .run({
              command: execPath,
              args: [
                runtime.entryPath,
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

export const layer = Layer.effect(ServerSelfUpdate, make()).pipe(
  Layer.provide(ProcessRunner.layer),
);
