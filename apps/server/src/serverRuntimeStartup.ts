import {
  CommandId,
  DEFAULT_MODEL,
  DEFAULT_PROVIDER_INTERACTION_MODE,
  DEFAULT_SERVER_SETTINGS,
  type ModelSelection,
  type Project,
  ProjectId,
  ProviderInstanceId,
  ThreadId,
} from "@infinitus/contracts";
import { PRODUCT_NAME } from "@infinitus/shared/productName";
import { resolveProjectSettings } from "@infinitus/shared/projectSettings";
import * as Cause from "effect/Cause";
import * as Console from "effect/Console";
import * as Context from "effect/Context";
import * as Crypto from "effect/Crypto";
import * as DateTime from "effect/DateTime";
import * as Deferred from "effect/Deferred";
import * as Effect from "effect/Effect";
import * as Exit from "effect/Exit";
import * as Fiber from "effect/Fiber";
import * as Layer from "effect/Layer";
import * as Path from "effect/Path";
import * as Queue from "effect/Queue";
import * as Ref from "effect/Ref";
import * as Schema from "effect/Schema";

import * as ServerConfig from "./config.ts";
import * as ServiceLauncherClient from "./cloud/serviceLauncherClient.ts";
import { flushCompileCache } from "./compileCache.ts";
import * as Keybindings from "./keybindings.ts";
import * as ExternalLauncher from "./process/externalLauncher.ts";
<<<<<<< HEAD
import * as OrchestrationEngine from "./orchestration/Services/OrchestrationEngine.ts";
import * as ProjectionSnapshotQuery from "./orchestration/Services/ProjectionSnapshotQuery.ts";
import { TURN_CONTINUATION_PROMPT } from "./provider/turnContinuation.ts";
import * as OrchestrationReactor from "./orchestration/Services/OrchestrationReactor.ts";
=======
import * as EffectWorker from "./orchestration-v2/EffectWorker.ts";
import * as LegacyV1ThreadImporter from "./orchestration-v2/legacy/LegacyV1ThreadImporter.ts";
import * as Orchestrator from "./orchestration-v2/Orchestrator.ts";
import * as ProviderRuntimeRecovery from "./orchestration-v2/ProviderRuntimeRecoveryService.ts";
import * as ProviderSessionManager from "./orchestration-v2/ProviderSessionManager.ts";
import * as ThreadLaunch from "./orchestration-v2/ThreadLaunchService.ts";
import * as ThreadManagement from "./orchestration-v2/ThreadManagementService.ts";
import * as ProjectService from "./project/ProjectService.ts";
import * as GitVcsDriver from "./vcs/GitVcsDriver.ts";
import * as ProjectStore from "./orchestration-v2/ProjectStore.ts";
import * as AgentAwarenessRelay from "./relay/AgentAwarenessRelay.ts";
>>>>>>> upstream-sync-76d3c96fd-upstream-renamed
import * as ServerLifecycleEvents from "./serverLifecycleEvents.ts";
import * as ServerSettings from "./serverSettings.ts";
import { forkParked, forkParkedFiber } from "./serverActivation.ts";
import * as AnalyticsService from "./telemetry/AnalyticsService.ts";
import * as ServerEnvironment from "./environment/ServerEnvironment.ts";
import * as EnvironmentAuth from "./auth/EnvironmentAuth.ts";
<<<<<<< HEAD
import { reconcileBackgroundAgents } from "./infinitus/Layers/BackgroundAgentsReconcile.ts";
import * as ProviderService from "./provider/Services/ProviderService.ts";
import * as ProviderSessionDirectory from "./provider/Services/ProviderSessionDirectory.ts";
import * as ProviderSessionReaper from "./provider/Services/ProviderSessionReaper.ts";
import { TurnStartGate } from "./orchestration/Services/TurnStartGate.ts";
import { forkParked } from "./serverActivation.ts";
import * as ServiceLauncherClient from "./cloud/serviceLauncherClient.ts";
import * as GitVcsDriver from "./vcs/GitVcsDriver.ts";
=======
>>>>>>> upstream-sync-76d3c96fd-upstream-renamed
import {
  formatHeadlessServeOutput,
  formatHostForUrl,
  isWildcardHost,
  issueHeadlessServeAccessInfo,
} from "./startupAccess.ts";

export class ServerRuntimeStartupError extends Schema.TaggedError<ServerRuntimeStartupError>()(
  "ServerRuntimeStartupError",
  {
    mode: ServerConfig.RuntimeMode,
    host: Schema.NullOr(Schema.String),
    port: Schema.Number,
    cause: Schema.Defect(),
  },
) {
  override get message(): string {
    return "Server runtime startup failed before command readiness.";
  }
}

export class ServerRuntimeStartup extends Context.Service<
  ServerRuntimeStartup,
  {
    readonly awaitCommandReady: Effect.Effect<void, ServerRuntimeStartupError>;
    readonly markHttpListening: Effect.Effect<void>;
    readonly enqueueCommand: <A, E>(
      effect: Effect.Effect<A, E>,
    ) => Effect.Effect<A, E | ServerRuntimeStartupError>;
  }
>()("t3/serverRuntimeStartup") {}

interface QueuedCommand {
  readonly run: Effect.Effect<void, never>;
}

type CommandReadinessState = "pending" | "ready" | ServerRuntimeStartupError;

interface CommandGate {
  readonly awaitCommandReady: Effect.Effect<void, ServerRuntimeStartupError>;
  readonly signalCommandReady: Effect.Effect<void>;
  readonly failCommandReady: (error: ServerRuntimeStartupError) => Effect.Effect<void>;
  readonly enqueueCommand: <A, E>(
    effect: Effect.Effect<A, E>,
  ) => Effect.Effect<A, E | ServerRuntimeStartupError>;
}

const settleQueuedCommand = <A, E>(deferred: Deferred.Deferred<A, E>, exit: Exit.Exit<A, E>) =>
  Exit.isSuccess(exit)
    ? Deferred.succeed(deferred, exit.value)
    : Deferred.failCause(deferred, exit.cause);

export const makeCommandGate = Effect.gen(function* () {
  const commandReady = yield* Deferred.make<void, ServerRuntimeStartupError>();
  const commandQueue = yield* Queue.unbounded<QueuedCommand>();
  const commandReadinessState = yield* Ref.make<CommandReadinessState>("pending");

  const commandWorker = Effect.forever(
    Queue.take(commandQueue).pipe(Effect.flatMap((command) => command.run)),
  );
  yield* Effect.forkScoped(commandWorker);

  return {
    awaitCommandReady: Deferred.await(commandReady),
    signalCommandReady: Effect.gen(function* () {
      yield* Ref.set(commandReadinessState, "ready");
      yield* Deferred.succeed(commandReady, undefined).pipe(Effect.orDie);
    }),
    failCommandReady: (error) =>
      Effect.gen(function* () {
        yield* Ref.set(commandReadinessState, error);
        yield* Deferred.fail(commandReady, error).pipe(Effect.orDie);
      }),
    enqueueCommand: <A, E>(effect: Effect.Effect<A, E>) =>
      Effect.gen(function* () {
        const readinessState = yield* Ref.get(commandReadinessState);
        if (readinessState === "ready") {
          return yield* effect;
        }
        if (readinessState !== "pending") {
          return yield* readinessState;
        }

        const result = yield* Deferred.make<A, E | ServerRuntimeStartupError>();
        yield* Queue.offer(commandQueue, {
          run: Deferred.await(commandReady).pipe(
            Effect.flatMap(() => effect),
            Effect.exit,
            Effect.flatMap((exit) => settleQueuedCommand(result, exit)),
          ),
        });
        return yield* Deferred.await(result);
      }),
  } satisfies CommandGate;
});

const recordStartupHeartbeat = Effect.gen(function* () {
  const analytics = yield* AnalyticsService.AnalyticsService;
  const projects = yield* ProjectService.ProjectService;
  const threads = yield* ThreadManagement.ThreadManagementService;

  const { threadCount, projectCount } = yield* Effect.all({
    projects: projects.snapshot,
    threads: threads.getShellSnapshot(),
  }).pipe(
    Effect.map(({ projects: projectSnapshot, threads: shellSnapshot }) => ({
      projectCount: projectSnapshot.projects.length,
      threadCount: shellSnapshot.threads.length + shellSnapshot.archivedThreads.length,
    })),
    Effect.catch((cause) =>
      Effect.logWarning("failed to gather V2 startup counts for telemetry", {
        cause,
      }).pipe(
        Effect.as({
          threadCount: 0,
          projectCount: 0,
        }),
      ),
    ),
  );

  yield* analytics.record("server.boot.heartbeat", {
    threadCount,
    projectCount,
  });
});

export const getAutoBootstrapThreadModelSelection = (): ModelSelection => ({
  instanceId: ProviderInstanceId.make("codex"),
  model: DEFAULT_MODEL,
});

<<<<<<< HEAD
export const resolveWelcomeBase = Effect.gen(function* () {
  const serverConfig = yield* ServerConfig.ServerConfig;
  const segments = serverConfig.cwd.split(/[/\\]/).filter(Boolean);
  const projectName = segments[segments.length - 1] ?? "project";

  return {
    cwd: serverConfig.cwd,
    projectName,
  } as const;
});

export const resolveAutoBootstrapWelcomeTargets = Effect.gen(function* () {
  const crypto = yield* Crypto.Crypto;
  const randomUUID = crypto.randomUUIDv4;
  const serverConfig = yield* ServerConfig.ServerConfig;
  const projectionReadModelQuery = yield* ProjectionSnapshotQuery.ProjectionSnapshotQuery;
  const orchestrationEngine = yield* OrchestrationEngine.OrchestrationEngineService;
  const path = yield* Path.Path;

  let bootstrapProjectId: ProjectId | undefined;
  let bootstrapThreadId: ThreadId | undefined;
  let bootstrapProjectCreated = false;
  let bootstrapThreadCreated = false;

  if (serverConfig.autoBootstrapProjectFromCwd) {
    const settings = yield* (yield* ServerSettings.ServerSettingsService).getSettings;
    const defaultModelSelection =
      settings.defaultModelSelection ?? getAutoBootstrapThreadModelSelection();
    yield* Effect.gen(function* () {
      const existingProject = yield* projectionReadModelQuery.getActiveProjectByWorkspaceRoot(
        serverConfig.cwd,
      );
      let nextProjectId: ProjectId;
      let nextThreadModelSelection: ModelSelection;

      if (Option.isNone(existingProject)) {
        const createdAt = DateTime.formatIso(yield* DateTime.now);
        nextProjectId = ProjectId.make(yield* randomUUID);
        const bootstrapProjectTitle = path.basename(serverConfig.cwd) || "project";
        nextThreadModelSelection = defaultModelSelection;
        yield* orchestrationEngine.dispatch({
          type: "project.create",
          commandId: CommandId.make(yield* randomUUID),
          projectId: nextProjectId,
          title: bootstrapProjectTitle,
          workspaceRoot: serverConfig.cwd,
          createdAt,
        });
        bootstrapProjectId = nextProjectId;
        bootstrapProjectCreated = true;
      } else {
        nextProjectId = existingProject.value.id;
        bootstrapProjectId = nextProjectId;
        nextThreadModelSelection =
          resolveProjectSettings(settings, nextProjectId, existingProject.value).settings
            .defaultModelSelection ?? defaultModelSelection;
      }

      yield* Effect.gen(function* () {
        const existingThreadId =
          yield* projectionReadModelQuery.getFirstActiveThreadIdByProjectId(nextProjectId);
        if (Option.isNone(existingThreadId)) {
          const createdAt = DateTime.formatIso(yield* DateTime.now);
          const createdThreadId = ThreadId.make(yield* randomUUID);
          yield* orchestrationEngine.dispatch({
            type: "thread.create",
            commandId: CommandId.make(yield* randomUUID),
            threadId: createdThreadId,
            projectId: nextProjectId,
            title: "New thread",
            modelSelection: nextThreadModelSelection,
            interactionMode: DEFAULT_PROVIDER_INTERACTION_MODE,
            runtimeMode: resolveProjectSettings(settings, nextProjectId).settings
              .defaultRuntimeMode,
            branch: null,
            worktreePath: null,
            createdAt,
          });
          bootstrapThreadId = createdThreadId;
          bootstrapThreadCreated = true;
        } else {
          bootstrapThreadId = existingThreadId.value;
        }
      }).pipe(
        Effect.catchCauseIf(
          (cause) => !Cause.hasInterrupts(cause),
          (cause) =>
            Effect.logWarning("startup thread auto-bootstrap failed", {
              bootstrapProjectId: nextProjectId,
              cause,
            }),
        ),
      );
    });
  }

  return {
    ...(bootstrapProjectId ? { bootstrapProjectId } : {}),
    ...(bootstrapThreadId ? { bootstrapThreadId } : {}),
    ...(bootstrapProjectId ? { bootstrapProjectCreated } : {}),
    ...(bootstrapThreadId ? { bootstrapThreadCreated } : {}),
  } as const;
});

export const completeAutoBootstrapWelcome = <A extends object, E, R>(
  bootstrap: Effect.Effect<A, E, R>,
) =>
  bootstrap.pipe(
    Effect.matchCauseEffect({
      onFailure: (cause) =>
        Cause.hasInterrupts(cause)
          ? Effect.failCause(cause)
          : Effect.logWarning("startup auto-bootstrap failed", { cause }).pipe(
              Effect.as({ bootstrapStatus: "complete" as const }),
            ),
      onSuccess: (targets) =>
        Effect.succeed({
          ...targets,
          bootstrapStatus: "complete" as const,
        }),
    }),
  );

const resolveStartupBrowserTarget = Effect.gen(function* () {
  const serverConfig = yield* ServerConfig.ServerConfig;
  const serverAuth = yield* EnvironmentAuth.EnvironmentAuth;
  const localUrl = `http://localhost:${serverConfig.port}`;
  const bindUrl =
    serverConfig.host && !isWildcardHost(serverConfig.host)
      ? `http://${formatHostForUrl(serverConfig.host)}:${serverConfig.port}`
      : localUrl;
  const baseTarget = serverConfig.devUrl?.toString() ?? bindUrl;
  return serverConfig.mode === "desktop"
    ? baseTarget
    : yield* serverAuth.issueStartupPairingUrl(baseTarget);
});

const maybeOpenBrowser = (target: string) =>
  Effect.gen(function* () {
    const serverConfig = yield* ServerConfig.ServerConfig;
    if (serverConfig.noBrowser) {
      return;
    }
    const externalLauncher = yield* ExternalLauncher.ExternalLauncher;

    yield* externalLauncher.launchBrowser(target).pipe(
      Effect.catch(() =>
        Effect.logInfo("browser auto-open unavailable", {
          hint: `Open ${target} in your browser.`,
        }),
      ),
    );
  });

const runStartupPhase = <A, E, R>(phase: string, effect: Effect.Effect<A, E, R>) =>
  effect.pipe(
    Effect.annotateSpans({ "startup.phase": phase }),
    Effect.withSpan(`server.startup.${phase}`),
  );

const ORPHANED_PROVIDER_SESSION_ERROR =
  "Provider session did not survive a server restart. Send a new message to continue.";
const SERVER_UPDATE_CONTINUATION_KEY = "continueAfterServerUpdate";

class ProviderSessionContinuationError extends Schema.TaggedError<ProviderSessionContinuationError>()(
  "ProviderSessionContinuationError",
  {
    threadId: ThreadId,
  },
) {
  override get message(): string {
    return `Could not continue thread '${this.threadId}': the provider instance is missing.`;
  }
}

export class ServerUpdateThreadContinuationError extends Schema.TaggedError<ServerUpdateThreadContinuationError>()(
  "ServerUpdateThreadContinuationError",
  {
    cause: Schema.Defect(),
  },
) {
  override get message(): string {
    return "Could not prepare running threads to continue after the update.";
  }
}

function hasServerUpdateContinuationMarker(
  runtimePayload: unknown,
): runtimePayload is Record<string, unknown> {
  return (
    runtimePayload !== null &&
    typeof runtimePayload === "object" &&
    !Array.isArray(runtimePayload) &&
    SERVER_UPDATE_CONTINUATION_KEY in runtimePayload
  );
}

function readRuntimePayload(runtimePayload: unknown): Record<string, unknown> {
  return runtimePayload !== null &&
    typeof runtimePayload === "object" &&
    !Array.isArray(runtimePayload)
    ? (runtimePayload as Record<string, unknown>)
    : {};
}

const isServerUpdateThreadContinuationError = Schema.is(ServerUpdateThreadContinuationError);

function readServerUpdateContinuationTurnId(runtimePayload: unknown): TurnId | null {
  if (!hasServerUpdateContinuationMarker(runtimePayload)) {
    return null;
  }
  const value = runtimePayload[SERVER_UPDATE_CONTINUATION_KEY];
  return typeof value === "string" && value.length > 0 ? TurnId.make(value) : null;
}

const toServerUpdateThreadContinuationError = (cause: unknown) =>
  isServerUpdateThreadContinuationError(cause)
    ? cause
    : new ServerUpdateThreadContinuationError({ cause });

export const markRunningProviderSessionsForContinuation = Effect.gen(function* () {
  const directory = yield* ProviderSessionDirectory.ProviderSessionDirectory;
  const query = yield* ProjectionSnapshotQuery.ProjectionSnapshotQuery;
  const { threads } = yield* query.getCommandReadModel();
  const running = threads.filter(
    (thread) =>
      thread.archivedAt === null &&
      thread.deletedAt === null &&
      thread.session?.status === "running" &&
      thread.session.activeTurnId !== null,
  );

  const marked: ThreadId[] = [];
  return yield* Effect.gen(function* () {
    for (const thread of running) {
      const activeTurnId = thread.session?.activeTurnId;
      if (activeTurnId === null || activeTurnId === undefined) {
        continue;
      }
      const binding = yield* directory.getBinding(thread.id);
      if (Option.isNone(binding)) {
        continue;
      }
      if (binding.value.resumeCursor === null || binding.value.resumeCursor === undefined) {
        continue;
      }
      yield* directory.upsert({
        ...binding.value,
        runtimePayload: {
          ...readRuntimePayload(binding.value.runtimePayload),
          [SERVER_UPDATE_CONTINUATION_KEY]: activeTurnId,
          continueAfterServerUpdatePrepared: null,
        },
      });
      marked.push(thread.id);
    }
    return marked;
  }).pipe(
    Effect.catchCause((cause) =>
      clearProviderSessionContinuationMarkers(marked).pipe(Effect.andThen(Effect.failCause(cause))),
    ),
  );
}).pipe(Effect.mapError(toServerUpdateThreadContinuationError));

const clearContinuationMarkers = (
  directory: ProviderSessionDirectory.ProviderSessionDirectory["Service"],
  threadIds: ReadonlyArray<ThreadId>,
) =>
  Effect.forEach(
    threadIds,
    (threadId) =>
      directory.getBinding(threadId).pipe(
        Effect.flatMap(
          Option.match({
            onNone: () => Effect.void,
            onSome: (binding) =>
              directory.upsert({
                ...binding,
                runtimePayload: {
                  ...readRuntimePayload(binding.runtimePayload),
                  [SERVER_UPDATE_CONTINUATION_KEY]: null,
                  continueAfterServerUpdatePrepared: null,
                },
              }),
          }),
        ),
      ),
    { concurrency: "unbounded", discard: true },
  );

const clearProviderSessionContinuationMarkers = (threadIds: ReadonlyArray<ThreadId>) =>
  Effect.gen(function* () {
    const directory = yield* ProviderSessionDirectory.ProviderSessionDirectory;
    yield* clearContinuationMarkers(directory, threadIds);
  }).pipe(Effect.mapError(toServerUpdateThreadContinuationError));

export const reconcileProviderSessions = Effect.gen(function* () {
  const crypto = yield* Crypto.Crypto;
  const directory = yield* ProviderSessionDirectory.ProviderSessionDirectory;
  const orchestrationEngine = yield* OrchestrationEngine.OrchestrationEngineService;
  const providerService = yield* ProviderService.ProviderService;
  const query = yield* ProjectionSnapshotQuery.ProjectionSnapshotQuery;
  const settings = yield* ServerSettings.ServerSettingsService;
  const turnStartGate = yield* TurnStartGate;
  const restartSettings = yield* settings.getSettings.pipe(
    Effect.asSome,
    Effect.catch((cause) =>
      Effect.logWarning("could not read restart continuation preference", { cause }).pipe(
        Effect.as(Option.none()),
      ),
    ),
  );
  const continueAfterRestartFor = (projectId: ProjectId) =>
    Option.isSome(restartSettings)
      ? resolveProjectSettings(restartSettings.value, projectId).settings
          .continueThreadsAfterServerUpdate
      : false;

  const liveThreadIds = new Set(
    (yield* providerService.listSessions()).map((session) => session.threadId),
  );
  const { threads } = yield* query.getCommandReadModel();
  // Provider startup can report ready before the continuation is submitted.
  // Find those markers in one read rather than querying every idle thread.
  const preparedThreadIds = new Set(
    (yield* directory.listBindings().pipe(
      Effect.catch((cause) =>
        Effect.logWarning("failed to read prepared provider continuations", { cause }).pipe(
          Effect.andThen(
            Effect.forEach(
              threads.filter(
                (thread) => thread.session?.status === "ready" && !liveThreadIds.has(thread.id),
              ),
              (thread) =>
                directory.getBinding(thread.id).pipe(Effect.orElseSucceed(() => Option.none())),
            ),
          ),
          Effect.map((bindings) =>
            bindings.flatMap((binding) => (Option.isSome(binding) ? [binding.value] : [])),
          ),
        ),
      ),
    ))
      .filter(
        (binding) =>
          readServerUpdateContinuationTurnId(binding.runtimePayload) !== null &&
          readRuntimePayload(binding.runtimePayload).activeTurnId === null &&
          readRuntimePayload(binding.runtimePayload).continueAfterServerUpdatePrepared === true,
      )
      .map((binding) => binding.threadId),
  );
  const orphanedThreads = threads.filter(
    (thread) =>
      thread.session !== null &&
      (thread.session.status === "starting" ||
        thread.session.status === "running" ||
        thread.session.activeTurnId !== null ||
        (thread.session.status === "ready" && preparedThreadIds.has(thread.id))) &&
      !liveThreadIds.has(thread.id),
  );

  for (const thread of orphanedThreads) {
    const session = thread.session;
    if (session === null) {
      continue;
    }
    const binding = yield* directory.getBinding(thread.id).pipe(
      Effect.catchCauseIf(
        (cause) => !Cause.hasInterrupts(cause),
        (cause) =>
          Effect.logWarning("failed to read orphaned provider session directory binding", {
            threadId: thread.id,
            cause,
          }).pipe(Effect.as(Option.none())),
      ),
    );
    const continuationMarkerPresent =
      Option.isSome(binding) && hasServerUpdateContinuationMarker(binding.value.runtimePayload);
    const continuationTurnId = Option.isSome(binding)
      ? readServerUpdateContinuationTurnId(binding.value.runtimePayload)
      : null;
    const continuationMarked =
      continuationTurnId !== null &&
      (session.activeTurnId === null || continuationTurnId === session.activeTurnId) &&
      Option.isSome(binding) &&
      (session.activeTurnId !== null ||
        readRuntimePayload(binding.value.runtimePayload).activeTurnId == null ||
        readRuntimePayload(binding.value.runtimePayload).activeTurnId === continuationTurnId);
    const preparedWhileReady =
      session.status === "ready" &&
      session.activeTurnId === null &&
      continuationMarked &&
      Option.isSome(binding) &&
      readRuntimePayload(binding.value.runtimePayload).activeTurnId === null &&
      readRuntimePayload(binding.value.runtimePayload).continueAfterServerUpdatePrepared === true;
    // Runtime events advance the projection's turn, but not the directory's
    // last admitted turn. Use the projection to identify interrupted work.
    const interruptedByRestart =
      continueAfterRestartFor(thread.projectId) &&
      session.status === "running" &&
      session.activeTurnId !== null &&
      Option.isSome(binding) &&
      binding.value.status === "running" &&
      binding.value.resumeCursor != null;
    const settleAsError = (lastError: string) =>
      Effect.gen(function* () {
        yield* Effect.gen(function* () {
          if (Option.isSome(binding)) {
            yield* directory.upsert({
              ...binding.value,
              status: "stopped",
              runtimePayload: {
                ...readRuntimePayload(binding.value.runtimePayload),
                activeTurnId: null,
                ...(continuationMarkerPresent || interruptedByRestart
                  ? {
                      [SERVER_UPDATE_CONTINUATION_KEY]: null,
                      continueAfterServerUpdatePrepared: null,
                    }
                  : {}),
              },
            });
          }
        }).pipe(
          Effect.catchCauseIf(
            (cause) => !Cause.hasInterrupts(cause),
            (cause) =>
              Effect.logWarning("failed to reconcile orphaned provider session directory binding", {
                threadId: thread.id,
                cause,
              }),
          ),
        );

        yield* Effect.gen(function* () {
          const reconciledAt = DateTime.formatIso(yield* DateTime.now);
          yield* orchestrationEngine.dispatch({
            type: "thread.session.set",
            commandId: CommandId.make(yield* crypto.randomUUIDv4),
            threadId: thread.id,
            session: {
              ...session,
              status: "error",
              activeTurnId: null,
              lastError,
              updatedAt: reconciledAt,
            },
            createdAt: reconciledAt,
          });
        }).pipe(
          Effect.retry({ times: 1 }),
          Effect.catchCauseIf(
            (cause) => !Cause.hasInterrupts(cause),
            (cause) =>
              Effect.logWarning("failed to settle orphaned provider session projection", {
                threadId: thread.id,
                cause,
              }),
          ),
        );
      });

    if (
      Option.isSome(binding) &&
      (continuationMarked || interruptedByRestart) &&
      (session.status === "running" || session.status === "starting" || preparedWhileReady) &&
      binding.value.resumeCursor != null &&
      thread.archivedAt === null &&
      thread.deletedAt === null
    ) {
      const prepared = yield* Effect.gen(function* () {
        yield* directory.upsert({
          ...binding.value,
          status: "starting",
          runtimePayload: {
            ...readRuntimePayload(binding.value.runtimePayload),
            // Keep recovery durable if this process also exits before sending.
            [SERVER_UPDATE_CONTINUATION_KEY]: session.activeTurnId ?? continuationTurnId,
            continueAfterServerUpdatePrepared: true,
            activeTurnId: null,
          },
        });
        const resumedAt = DateTime.formatIso(yield* DateTime.now);
        yield* orchestrationEngine.dispatch({
          type: "thread.session.set",
          commandId: CommandId.make(yield* crypto.randomUUIDv4),
          threadId: thread.id,
          session: {
            ...session,
            status: "starting",
            activeTurnId: null,
            lastError: null,
            updatedAt: resumedAt,
          },
          createdAt: resumedAt,
        });
      }).pipe(Effect.retry({ times: 1 }), Effect.exit);
      if (Exit.isFailure(prepared)) {
        if (Cause.hasInterrupts(prepared.cause)) {
          return yield* Effect.failCause(prepared.cause);
        }
        yield* Effect.logWarning("failed to prepare provider session continuation", {
          threadId: thread.id,
          cause: prepared.cause,
        });
        yield* settleAsError(ORPHANED_PROVIDER_SESSION_ERROR);
        continue;
      }

      // Fork (#616): the gate may keep a background thread's continuation for
      // headroom; the marker stays prepared until the send runs.
      yield* forkParked(
        turnStartGate.start({
          threadId: thread.id,
          run: Effect.gen(function* () {
            const continuation = Effect.gen(function* () {
              const providerInstanceId = binding.value.providerInstanceId;
              if (providerInstanceId === undefined) {
                return yield* new ProviderSessionContinuationError({
                  threadId: thread.id,
                });
              }
              const capabilities = yield* providerService.getCapabilities(providerInstanceId);
              yield* providerService.sendTurn({
                threadId: thread.id,
                ...(capabilities.promptlessTurnContinuation === true
                  ? { continuation: true }
                  : { input: TURN_CONTINUATION_PROMPT }),
                interactionMode: thread.interactionMode,
              });
            });
            const continuationExit = yield* Effect.exit(continuation);
            if (Exit.isSuccess(continuationExit) || Cause.hasInterrupts(continuationExit.cause)) {
              if (Exit.isSuccess(continuationExit)) {
                yield* clearContinuationMarkers(directory, [thread.id]).pipe(
                  Effect.uninterruptible,
                  Effect.catchCause((cause) =>
                    Effect.logWarning("failed to clear completed provider session continuation", {
                      threadId: thread.id,
                      cause,
                    }),
                  ),
                );
              }
              return;
            }
            yield* Effect.logWarning("failed to continue provider session after server restart", {
              threadId: thread.id,
              cause: continuationExit.cause,
            });
            yield* settleAsError(
              "Could not continue this thread after the server restart. Send a new message to continue.",
            ).pipe(Effect.ignoreCause);
          }),
        }),
      );
      continue;
    }

    yield* settleAsError(ORPHANED_PROVIDER_SESSION_ERROR);
  }
}).pipe(
  Effect.catchCauseIf(
    (cause) => !Cause.hasInterrupts(cause),
    (cause) => Effect.logWarning("provider session startup reconciliation failed", { cause }),
  ),
);

const decodeWorktreeSetupSnapshot = Schema.decodeUnknownOption(WorktreeSetupSnapshot);

/**
 * A worktree bootstrap records its setup snapshot on the thread while it runs
 * and settles it when it finishes. The bootstrap itself lives only in memory,
 * so a process exit mid-setup leaves a `running` record with nobody to finish
 * it. Before the turn started that also strands the persisted user message, so
 * the setup is marked failed and the user is told to send again. After the
 * handoff only an async setup script was still running; its stage is marked
 * failed and the setup settles as done, like any other script failure.
 */
export const reconcileWorktreeSetups = Effect.gen(function* () {
  const crypto = yield* Crypto.Crypto;
  const orchestrationEngine = yield* OrchestrationEngine.OrchestrationEngineService;
  const query = yield* ProjectionSnapshotQuery.ProjectionSnapshotQuery;
  // The command read model carries no activity bodies; read the setup
  // records directly, live threads only.
  const recordedSetups = yield* query.listActivitiesByKind(WORKTREE_SETUP_ACTIVITY_KIND);
  const interruptedAt = DateTime.formatIso(yield* DateTime.now);

  for (const recorded of recordedSetups) {
    const snapshot = decodeWorktreeSetupSnapshot(recorded.payload);
    if (Option.isNone(snapshot) || snapshot.value.phase !== "running") continue;
    if (recorded.id !== worktreeSetupActivityId(snapshot.value.threadId)) continue;
    const threadId = snapshot.value.threadId;

    const turnStarted = snapshot.value.stages.some(
      (stage) => stage.id === "agent" && stage.status === "done",
    );
    const interrupted: WorktreeSetupSnapshot = {
      ...snapshot.value,
      phase: turnStarted ? "done" : "failed",
      endedAt: interruptedAt,
      error: turnStarted
        ? null
        : "The server restarted before the worktree setup finished. Send the message again.",
      stages: snapshot.value.stages.map((stage) =>
        stage.status === "running" || stage.status === "pending"
          ? {
              ...stage,
              status: "failed",
              endedAt: interruptedAt,
              detail: "interrupted by a server restart",
            }
          : stage,
      ),
      sequence: snapshot.value.sequence + 1,
    };
    yield* orchestrationEngine
      .dispatch({
        type: "thread.activity.append",
        commandId: CommandId.make(yield* crypto.randomUUIDv4),
        threadId,
        activity: {
          id: EventId.make(worktreeSetupActivityId(threadId)),
          tone: "error",
          kind: WORKTREE_SETUP_ACTIVITY_KIND,
          summary: turnStarted
            ? "Setup script interrupted by a server restart"
            : "Worktree setup interrupted by a server restart",
          payload: interrupted,
          turnId: null,
          createdAt: snapshot.value.startedAt,
        },
        createdAt: interruptedAt,
      })
      .pipe(
        Effect.catchCauseIf(
          (cause) => !Cause.hasInterrupts(cause),
          (cause) =>
            Effect.logWarning("failed to settle interrupted worktree setup", {
              threadId,
              cause,
            }),
        ),
      );
  }
}).pipe(
  Effect.catchCauseIf(
    (cause) => !Cause.hasInterrupts(cause),
    (cause) => Effect.logWarning("worktree setup startup reconciliation failed", { cause }),
  ),
);

interface StartupOptions {
  readonly activate?: Effect.Effect<void>;
  readonly awaitAuxiliaryParked?: Effect.Effect<void>;
  readonly abort?: (error: ServerRuntimeStartupError) => Effect.Effect<void>;
=======
interface AutoBootstrapWelcomeTargets {
  readonly bootstrapProjectId?: ProjectId;
  readonly bootstrapThreadId?: ThreadId;
>>>>>>> upstream-sync-76d3c96fd-upstream-renamed
}

export const autoPullProjects = Effect.fn("autoPullProjects")(function* (
  projects: ReadonlyArray<Pick<Project, "id" | "workspaceRoot" | "autoPull">>,
  settings = DEFAULT_SERVER_SETTINGS,
) {
  const git = yield* GitVcsDriver.GitVcsDriver;
  const workspaceRoots = [
    ...new Set(
      projects
        .filter((project) => resolveProjectSettings(settings, project.id).settings.defaultAutoPull)
        .map((project) => project.workspaceRoot),
    ),
  ];

  yield* Effect.forEach(
    workspaceRoots,
    (cwd) =>
      Effect.gen(function* () {
        const status = yield* git.statusDetails(cwd);
        if (
          !status.isRepo ||
          !status.isDefaultBranch ||
          !status.hasUpstream ||
          status.hasWorkingTreeChanges ||
          status.aheadCount > 0
        ) {
          yield* Effect.logDebug("Skipped automatic project pull", {
            cwd,
            reason: !status.isRepo
              ? "not-a-repository"
              : !status.isDefaultBranch
                ? "not-on-default-branch"
                : !status.hasUpstream
                  ? "no-upstream"
                  : status.hasWorkingTreeChanges
                    ? "working-tree-changes"
                    : "local-commits",
          });
          return;
        }

        if (status.behindCount <= 0) return;

        const result = yield* git.pullCurrentBranch(cwd);
        yield* Effect.logDebug("Automatic project pull completed", {
          cwd,
          status: result.status,
          refName: result.refName,
        });
      }).pipe(
        Effect.catch((cause) =>
          Effect.logWarning("Automatic project pull failed", {
            cwd,
            cause,
          }),
        ),
      ),
    { concurrency: 4, discard: true },
  );
});

export const resolveWelcomeBase = Effect.gen(function* () {
  const serverConfig = yield* ServerConfig.ServerConfig;
  const segments = serverConfig.cwd.split(/[/\\]/).filter(Boolean);
  const projectName = segments[segments.length - 1] ?? "project";

  return {
    cwd: serverConfig.cwd,
    projectName,
  } as const;
});

const resolveAutoBootstrapWelcomeTargets = Effect.gen(function* () {
  const crypto = yield* Crypto.Crypto;
  const randomUUID = crypto.randomUUIDv4;
  const serverConfig = yield* ServerConfig.ServerConfig;
  const projects = yield* ProjectService.ProjectService;
  const threads = yield* ThreadManagement.ThreadManagementService;
  const threadLaunch = yield* ThreadLaunch.ThreadLaunchService;
  const path = yield* Path.Path;

  let bootstrapProjectId: ProjectId | undefined;
  let bootstrapThreadId: ThreadId | undefined;

  if (serverConfig.autoBootstrapProjectFromCwd) {
    // Project creation has no user model choice; only the bootstrap thread
    // gets an automatic selection, and an explicit project default wins.
    const threadModelSelection = getAutoBootstrapThreadModelSelection();
    const { project } = yield* projects.bootstrap({
      commandId: CommandId.make(yield* randomUUID),
      projectId: ProjectId.make(yield* randomUUID),
      title: path.basename(serverConfig.cwd) || "project",
      workspaceRoot: serverConfig.cwd,
    });
    const shell = yield* threads.getShellSnapshot();
    const existingThread = shell.threads.find(
      (thread) =>
        thread.projectId === project.id && thread.lineage.relationshipToParent !== "subagent",
    );
    if (existingThread === undefined) {
      const serverSettings = yield* ServerSettings.ServerSettingsService;
      const settings = yield* serverSettings.getSettings;
      const launched = yield* threadLaunch.launch({
        commandId: CommandId.make(yield* randomUUID),
        projectId: project.id,
        title: "New thread",
        modelSelection:
          resolveProjectSettings(settings, project.id, project).settings.defaultModelSelection ??
          threadModelSelection,
        interactionMode: DEFAULT_PROVIDER_INTERACTION_MODE,
        runtimeMode: resolveProjectSettings(settings, project.id, project).settings
          .defaultRuntimeMode,
        workspaceStrategy: { type: "root" },
        createdBy: "system",
        creationSource: "server",
      });
      bootstrapProjectId = project.id;
      bootstrapThreadId = launched.threadId;
    } else {
      bootstrapProjectId = project.id;
      bootstrapThreadId = existingThread.id;
    }
  }

  return {
    ...(bootstrapProjectId ? { bootstrapProjectId } : {}),
    ...(bootstrapThreadId ? { bootstrapThreadId } : {}),
  } satisfies AutoBootstrapWelcomeTargets;
});

const resolveStartupBrowserTarget = Effect.gen(function* () {
  const serverConfig = yield* ServerConfig.ServerConfig;
  const serverAuth = yield* EnvironmentAuth.EnvironmentAuth;
  const localUrl = `http://localhost:${serverConfig.port}`;
  const bindUrl =
    serverConfig.host && !isWildcardHost(serverConfig.host)
      ? `http://${formatHostForUrl(serverConfig.host)}:${serverConfig.port}`
      : localUrl;
  const baseTarget = serverConfig.devUrl?.toString() ?? bindUrl;
  return serverConfig.mode === "desktop"
    ? baseTarget
    : yield* serverAuth.issueStartupPairingUrl(baseTarget);
});

const maybeOpenBrowser = (target: string) =>
  Effect.gen(function* () {
    const serverConfig = yield* ServerConfig.ServerConfig;
    if (serverConfig.noBrowser) {
      return;
    }
    const externalLauncher = yield* ExternalLauncher.ExternalLauncher;

    yield* externalLauncher.launchBrowser(target).pipe(
      Effect.catch(() =>
        Effect.logInfo("browser auto-open unavailable", {
          hint: `Open ${target} in your browser.`,
        }),
      ),
    );
  });

const runStartupPhase = <A, E, R>(phase: string, effect: Effect.Effect<A, E, R>) =>
  effect.pipe(
    Effect.annotateSpans({ "startup.phase": phase }),
    Effect.withSpan(`server.startup.${phase}`),
  );

interface StartupOptions {
  readonly activate?: Effect.Effect<void>;
  readonly awaitAuxiliaryParked?: Effect.Effect<void>;
  readonly abort?: (error: ServerRuntimeStartupError) => Effect.Effect<void>;
}

export const startEffectWorkerWithRelay = Effect.fn(
  "ServerRuntimeStartup.startEffectWorkerWithRelay",
)(function* <WorkerContext, RelayContext>(input: {
  readonly runWorker: Effect.Effect<void, never, WorkerContext>;
  readonly startRelay: Effect.Effect<void, never, RelayContext>;
  readonly workerFiberRef: Ref.Ref<Fiber.Fiber<void, never> | null>;
}) {
  const workerFiber = yield* forkParkedFiber(input.runWorker);
  yield* Ref.set(input.workerFiberRef, workerFiber);
  yield* input.startRelay.pipe(
    Effect.onExit((exit) => {
      if (Exit.isSuccess(exit)) {
        return Effect.void;
      }
      return Ref.getAndSet(input.workerFiberRef, null).pipe(
        Effect.flatMap((ownedWorkerFiber) =>
          ownedWorkerFiber === null
            ? Effect.void
            : Fiber.interrupt(ownedWorkerFiber).pipe(Effect.asVoid),
        ),
      );
    }),
  );
});

export function runOrderedV2StartupPhases<
  Import,
  Recovery,
  Bootstrap,
  ImportError,
  RecoveryError,
  DelegationError,
  WorkerError,
  BootstrapError,
  ImportContext,
  RecoveryContext,
  DelegationContext,
  WorkerContext,
  BootstrapContext,
>(input: {
  readonly importLegacyShells: Effect.Effect<Import, ImportError, ImportContext>;
  readonly recover: Effect.Effect<Recovery, RecoveryError, RecoveryContext>;
  /** Settles delegated tasks whose runs recovery just terminalized. */
  readonly recoverDelegatedTasks: Effect.Effect<void, DelegationError, DelegationContext>;
  readonly startEffectWorker: Effect.Effect<void, WorkerError, WorkerContext>;
  readonly autoBootstrap: Effect.Effect<Bootstrap, BootstrapError, BootstrapContext>;
}) {
  return Effect.gen(function* () {
    yield* input.importLegacyShells;
    const recovery = yield* input.recover;
    yield* input.recoverDelegatedTasks;
    yield* input.startEffectWorker;
    const bootstrap = yield* input.autoBootstrap;
    return { recovery, bootstrap } as const;
  });
}

const make = (options?: StartupOptions) =>
  Effect.gen(function* () {
    const serverConfig = yield* ServerConfig.ServerConfig;
    const keybindings = yield* Keybindings.Keybindings;
    const legacyV1ThreadImporter = yield* LegacyV1ThreadImporter.LegacyV1ThreadImporter;
    const providerRuntimeRecovery = yield* ProviderRuntimeRecovery.ProviderRuntimeRecoveryService;
    const orchestrator = yield* Orchestrator.OrchestratorV2;
    const providerSessions = yield* ProviderSessionManager.ProviderSessionManagerV2;
    const agentAwarenessRelay = yield* AgentAwarenessRelay.AgentAwarenessRelay;
    const lifecycleEvents = yield* ServerLifecycleEvents.ServerLifecycleEvents;
    const serverSettings = yield* ServerSettings.ServerSettingsService;
    const serverEnvironment = yield* ServerEnvironment.ServerEnvironment;
    const crypto = yield* Crypto.Crypto;
    const launcher = yield* ServiceLauncherClient.ServiceLauncherClient;

    const commandGate = yield* makeCommandGate;
    const httpListening = yield* Deferred.make<void>();
    const effectWorkerFiber = yield* Ref.make<Fiber.Fiber<void, never> | null>(null);

    yield* Effect.addFinalizer(() =>
      Effect.gen(function* () {
        yield* commandGate.failCommandReady(
          new ServerRuntimeStartupError({
            mode: serverConfig.mode,
            host: serverConfig.host ?? null,
            port: serverConfig.port,
            cause: "Server runtime is shutting down.",
          }),
        );
        const workerFiber = yield* Ref.getAndSet(effectWorkerFiber, null);
        if (workerFiber !== null) {
          yield* Fiber.interrupt(workerFiber).pipe(Effect.ignore);
        }
        yield* providerRuntimeRecovery.prepareForShutdown.pipe(
          Effect.ensuring(providerSessions.shutdown),
        );
        const reconciliation = yield* providerRuntimeRecovery.reconcile("shutdown");
        yield* Effect.logInfo("V2 orchestration shutdown reconciliation completed", reconciliation);
      }).pipe(
        Effect.catchCause((cause) =>
          Effect.logWarning("V2 orchestration shutdown reconciliation failed", {
            cause: Cause.pretty(cause),
          }),
        ),
      ),
    );

    const startup = Effect.gen(function* () {
      yield* Effect.logDebug("startup phase: starting keybindings runtime");
      yield* runStartupPhase(
        "keybindings.start",
        keybindings.start.pipe(
          Effect.catch((error) =>
            Effect.logWarning("failed to start keybindings runtime", {
              path: error.configPath,
              detail: error.detail,
              cause: error.cause,
            }),
          ),
        ),
      );

      yield* Effect.logDebug("startup phase: starting server settings runtime");
      yield* runStartupPhase(
        "settings.start",
        serverSettings.start.pipe(
          Effect.catch((error) =>
            Effect.logWarning("failed to start server settings runtime", {
              path: error.settingsPath,
              operation: error.operation,
              providerInstanceId: error.providerInstanceId,
              environmentVariable: error.environmentVariable,
              cause: error.cause,
            }),
          ),
        ),
      );

<<<<<<< HEAD
      yield* Effect.logDebug("startup phase: parking orchestration roots at activation");
      yield* runStartupPhase(
        "reactors.start",
        Effect.gen(function* () {
          yield* orchestrationReactor.start().pipe(Scope.provide(reactorScope));
          yield* providerSessionReaper.start().pipe(Scope.provide(reactorScope));
        }),
      );

      yield* runStartupPhase("provider-sessions.reconcile", reconcileProviderSessions);
      // Fork (#977): threads a killed server left with background agents live.
      yield* runStartupPhase("background-agents.reconcile", reconcileBackgroundAgents);
      yield* runStartupPhase("worktree-setups.reconcile", reconcileWorktreeSetups);

      yield* Effect.logDebug("startup phase: syncing clean projects");
      yield* runStartupPhase("projects.auto-pull", syncAutoPullProjects);

=======
>>>>>>> upstream-sync-76d3c96fd-upstream-renamed
      const welcomeBase = yield* resolveWelcomeBase;
      const environment = yield* serverEnvironment.getDescriptor;
      const legacyMigrationThreadCount = yield* legacyV1ThreadImporter.pendingThreadCount;
      if (legacyMigrationThreadCount > 0) {
        yield* lifecycleEvents.publish({
          version: 1,
          type: "legacyThreadMigration",
          payload: {
            status: "running",
            totalThreadCount: legacyMigrationThreadCount,
          },
        });
      }
      const { recovery, bootstrap: bootstrapTargets } = yield* runOrderedV2StartupPhases({
        importLegacyShells: runStartupPhase(
          "orchestration-v2.legacy-v1.import-shells",
          legacyV1ThreadImporter.reconcileShells.pipe(
            Effect.tap((summary) =>
              summary.importedThreadCount === 0
                ? Effect.void
                : Effect.logInfo("Imported legacy v1 thread shells", summary),
            ),
          ),
        ),
        recover: runStartupPhase("orchestration-v2.recovery", providerRuntimeRecovery.recover),
        recoverDelegatedTasks: runStartupPhase(
          "orchestration-v2.delegated-tasks.recover",
          orchestrator.recoverDelegatedTasks,
        ),
        startEffectWorker: runStartupPhase(
          "orchestration-v2.effect-worker.start",
          startEffectWorkerWithRelay({
            runWorker: EffectWorker.runDaemon,
            startRelay: agentAwarenessRelay.start(),
            workerFiberRef: effectWorkerFiber,
          }),
        ),
        autoBootstrap: (serverConfig.autoBootstrapProjectFromCwd
          ? runStartupPhase(
              "welcome.autobootstrap",
              resolveAutoBootstrapWelcomeTargets.pipe(Effect.provideService(Crypto.Crypto, crypto)),
            )
          : Effect.succeed({})
        ).pipe(Effect.map((targets): AutoBootstrapWelcomeTargets => targets)),
      });
      yield* Effect.logInfo("V2 orchestration recovery completed", recovery);
      // Runs after activation: the status check fetches every enabled project's
      // remote, and awaiting it here held command readiness for that long.
      yield* runStartupPhase(
        "projects.auto-pull",
        Effect.gen(function* () {
          const projects = yield* (yield* ProjectStore.ProjectStoreV2).listShells();
          const settings = yield* serverSettings.getSettings;
          yield* autoPullProjects(projects, settings);
        }),
      ).pipe(
        Effect.catch((cause) =>
          Effect.logWarning("Failed to load projects for automatic pull", { cause }),
        ),
        forkParked,
      );

      const importPendingTranscripts = legacyV1ThreadImporter.importPendingTranscripts.pipe(
        Effect.tap((summary) =>
          summary.importedThreadCount === 0
            ? Effect.void
            : Effect.logInfo("Hydrated legacy v1 thread transcripts", summary),
        ),
      );
      yield* (
        legacyMigrationThreadCount > 0
          ? importPendingTranscripts.pipe(
              Effect.tap(() =>
                lifecycleEvents.publish({
                  version: 1,
                  type: "legacyThreadMigration",
                  payload: {
                    status: "complete",
                    totalThreadCount: legacyMigrationThreadCount,
                  },
                }),
              ),
            )
          : importPendingTranscripts
      ).pipe(forkParked);

      yield* forkParked(
        Effect.gen(function* () {
          yield* Effect.logDebug("startup phase: recording startup heartbeat");
          yield* recordStartupHeartbeat.pipe(
            Effect.annotateSpans({ "startup.phase": "heartbeat.record" }),
            Effect.withSpan("server.startup.heartbeat.record"),
            Effect.ignoreCause({ log: true }),
          );
          if (serverConfig.startupPresentation === "headless") {
            yield* Effect.logDebug("startup phase: headless access info");
            const accessInfo = yield* issueHeadlessServeAccessInfo();
            yield* runStartupPhase(
              "headless.output",
              Console.log(formatHeadlessServeOutput(accessInfo)),
            );
          } else {
            yield* Effect.logDebug("startup phase: browser open check");
            const startupBrowserTarget = yield* resolveStartupBrowserTarget;
            if (serverConfig.mode !== "desktop") {
              yield* Effect.logInfo(
                `Authentication required. Open ${PRODUCT_NAME} using the pairing URL.`,
              ).pipe(Effect.annotateLogs({ pairingUrl: startupBrowserTarget }));
            }
            yield* runStartupPhase("browser.open", maybeOpenBrowser(startupBrowserTarget));
          }
        }),
      );

      yield* Effect.logDebug("startup phase: waiting for http listener");
      yield* runStartupPhase("http.wait", Deferred.await(httpListening));
      yield* runStartupPhase(
        "auxiliary-roots.parked",
        options?.awaitAuxiliaryParked ?? Effect.void,
      );

      const updateOutcome = yield* launcher.prepareTrial;

      yield* Effect.logDebug("startup phase: publishing welcome event", {
        environmentId: environment.environmentId,
        cwd: welcomeBase.cwd,
        projectName: welcomeBase.projectName,
        bootstrapProjectId: bootstrapTargets.bootstrapProjectId,
        bootstrapThreadId: bootstrapTargets.bootstrapThreadId,
      });
      yield* runStartupPhase(
        "welcome.publish",
        lifecycleEvents.publish({
          version: 1,
          type: "welcome",
          payload: {
            environment,
            ...welcomeBase,
            ...bootstrapTargets,
          },
        }),
      );

      yield* options?.activate ?? Effect.void;
      yield* Effect.logDebug("Accepting commands");
      yield* commandGate.signalCommandReady;
      yield* Effect.logDebug("startup phase: publishing ready event");
      yield* runStartupPhase(
        "ready.publish",
        lifecycleEvents.publish({
          version: 1,
          type: "ready",
          payload: {
            at: DateTime.formatIso(yield* DateTime.now),
            environment,
            ...(updateOutcome === undefined ? {} : { updateOutcome }),
          },
        }),
      );
      yield* Effect.logDebug("startup phase: complete");
      yield* flushCompileCache;
    }).pipe(
      Effect.annotateSpans({
        "server.mode": serverConfig.mode,
        "server.port": serverConfig.port,
        "server.host": serverConfig.host ?? "default",
      }),
      Effect.withSpan("server.startup", { kind: "server", root: true }),
    );

    yield* Effect.forkScoped(
      Effect.exit(startup).pipe(
        Effect.flatMap((startupExit) => {
          if (Exit.isSuccess(startupExit)) return Effect.void;
          const error = new ServerRuntimeStartupError({
            mode: serverConfig.mode,
            host: serverConfig.host ?? null,
            port: serverConfig.port,
            cause: startupExit.cause,
          });
          return Effect.logError("server runtime startup failed", {
            cause: Cause.pretty(startupExit.cause),
          }).pipe(
            Effect.andThen(commandGate.failCommandReady(error)),
            Effect.andThen(options?.abort?.(error) ?? Effect.void),
          );
        }),
      ),
    );

    return {
      awaitCommandReady: commandGate.awaitCommandReady,
      markHttpListening: Deferred.succeed(httpListening, undefined),
      enqueueCommand: commandGate.enqueueCommand,
    } satisfies ServerRuntimeStartup["Service"];
  });

export const layerWithOptions = (options?: StartupOptions) =>
  Layer.effect(ServerRuntimeStartup, make(options));

const layer = layerWithOptions();
