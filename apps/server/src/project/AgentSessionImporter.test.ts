import { expect, it } from "@effect/vitest";
import {
  ProjectId,
  ProviderInstanceId,
  ThreadId,
  type OrchestrationV2DomainEvent,
} from "@infinitus/contracts";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";
import * as Stream from "effect/Stream";

import * as EventSink from "../orchestration-v2/EventSink.ts";
import * as IdAllocator from "@infinitus/provider-core/server/IdAllocator";
import * as Orchestrator from "../orchestration-v2/Orchestrator.ts";
import * as ProviderSessionRuntime from "../persistence/ProviderSessionRuntime.ts";
<<<<<<< HEAD
import { OrchestrationEngineLive } from "../orchestration/Layers/OrchestrationEngine.ts";
import { OrchestrationProjectionPipelineLive } from "../orchestration/Layers/ProjectionPipeline.ts";
import { OrchestrationProjectionSnapshotQueryLive } from "../orchestration/Layers/ProjectionSnapshotQuery.ts";
import { ProviderCommandReactorLive } from "../orchestration/Layers/ProviderCommandReactor.ts";
import { TurnStartGatePassthrough } from "../orchestration/Services/TurnStartGate.ts";
import { OrchestrationCommandInvariantError } from "../orchestration/Errors.ts";
import * as ThreadBackgroundLiveness from "../orchestration/ThreadBackgroundLiveness.ts";
import * as ThreadPlanProgress from "../orchestration/ThreadPlanProgress.ts";
import * as OrchestrationEngine from "../orchestration/Services/OrchestrationEngine.ts";
import * as ProjectionSnapshotQuery from "../orchestration/Services/ProjectionSnapshotQuery.ts";
import { ProviderCommandReactor } from "../orchestration/Services/ProviderCommandReactor.ts";
import { ProviderSessionDirectoryLive } from "../provider/Layers/ProviderSessionDirectory.ts";
import { makeProviderServiceLive } from "../provider/Layers/ProviderService.ts";
import {
  NoOpProviderEventLoggers,
  ProviderEventLoggers,
} from "../provider/Layers/ProviderEventLoggers.ts";
import { ProviderSessionDirectoryPersistenceError } from "../provider/Errors.ts";
import { ProviderAdapterRegistry } from "../provider/Services/ProviderAdapterRegistry.ts";
import { ProviderAuthService } from "../provider/Services/ProviderAuthService.ts";
import * as ProviderSessionDirectory from "../provider/Services/ProviderSessionDirectory.ts";
import { makeAdapterRegistryMock } from "../provider/testUtils/providerAdapterRegistryMock.ts";
import { makeProviderRegistryLayer } from "../provider/testUtils/providerRegistryMock.ts";
import { ServerSettingsService } from "../serverSettings.ts";
import * as AnalyticsService from "../telemetry/AnalyticsService.ts";
import { TextGeneration } from "../textGeneration/TextGeneration.ts";
import { TerminalManager } from "../terminal/Manager.ts";
import { VcsStatusBroadcaster } from "../vcs/VcsStatusBroadcaster.ts";
import * as RepositoryIdentityResolver from "./RepositoryIdentityResolver.ts";
import { importRecentAgentThreads } from "./AgentSessionImporter.ts";
=======
import * as AgentSessionImporter from "./AgentSessionImporter.ts";
>>>>>>> upstream-sync-43f8a8de1-upstream-renamed
import * as AgentSessionScanner from "./AgentSessionScanner.ts";
import * as ProjectService from "./ProjectService.ts";

const projectId = ProjectId.make("agent-session-import-project");
const providerInstanceId = ProviderInstanceId.make("codex");
const providerSessionId = "native-codex-thread";
const threadId = ThreadId.make(`import:${providerInstanceId}:${providerSessionId}`);

<<<<<<< HEAD
const makeThread = (
  source: "codex" | "claudeAgent" | "omp" | "pi",
): AgentSessionScanner.AgentSessionThread => ({
  source,
  providerInstanceId: ProviderInstanceId.make(source),
  providerSessionId:
    source === "codex"
      ? "codex-session"
      : source === "claudeAgent"
        ? CLAUDE_SESSION_ID
        : `${source}-session`,
  title: `Imported ${source} thread`,
  model: null,
  createdAt: "2026-08-24T10:00:00.000Z",
  updatedAt: "2026-08-24T10:01:00.000Z",
  messages: [
    { role: "user", text: "Fix the bug", createdAt: "2026-08-24T10:00:00.000Z" },
    { role: "assistant", text: "Fixed", createdAt: "2026-08-24T10:01:00.000Z" },
  ],
});

const makeThreadOutcome = (thread: AgentSessionScanner.AgentSessionThread) =>
  ({
    _tag: "Importable",
    thread,
    source: {
      provider: thread.source,
      providerInstanceId: thread.providerInstanceId,
      providerSessionId: thread.providerSessionId,
      filePath: `/tmp/transcripts/${thread.providerInstanceId}/${thread.providerSessionId}.jsonl`,
      size: 0,
      mtimeMs: 0,
      device: 0,
      inode: 0,
      birthtimeMs: 0,
    },
  }) satisfies AgentSessionScanner.AgentSessionRecentThread;

const makeProject = (): OrchestrationProjectShell => ({
  id: PROJECT_ID,
  title: "Project",
  workspaceRoot: WORKSPACE_ROOT,
  defaultModelSelection: null,
  scripts: [],
  createdAt: "2026-08-24T09:00:00.000Z",
  updatedAt: "2026-08-24T09:00:00.000Z",
});

const makeProjectedThread = (input: {
  readonly source: "codex" | "claudeAgent";
  readonly projectId?: ProjectId;
  readonly imported?: boolean;
  readonly includeFollowup?: boolean;
}): OrchestrationThread => {
  const sourceThread = makeThread(input.source);
  const threadId = ThreadId.make(
    `import:${sourceThread.providerInstanceId}:${sourceThread.providerSessionId}`,
  );
  return {
    id: threadId,
    projectId: input.projectId ?? PROJECT_ID,
    title: sourceThread.title,
    modelSelection: { instanceId: sourceThread.providerInstanceId, model: "default" },
    runtimeMode: "full-access",
    interactionMode: "default",
    pullRequests: [],
    branch: null,
    worktreePath: null,
    latestTurn: null,
    createdAt: sourceThread.createdAt,
    updatedAt: sourceThread.updatedAt,
    archivedAt: null,
    settledOverride: null,
    settledAt: null,
    deletedAt: null,
    messages: input.imported
      ? [
          {
            id: MessageId.make(`${threadId}:000000`),
            role: "user",
            text: "Fix the bug",
            turnId: null,
            streaming: false,
            createdAt: "2026-08-24T10:00:00.000Z",
            updatedAt: "2026-08-24T10:00:00.000Z",
          },
          ...(input.includeFollowup
            ? [
                {
                  id: MessageId.make("user-followup"),
                  role: "user" as const,
                  text: "Keep going",
                  turnId: null,
                  streaming: false,
                  createdAt: "2026-08-24T10:02:00.000Z",
                  updatedAt: "2026-08-24T10:02:00.000Z",
                },
              ]
            : []),
        ]
      : [],
    proposedPlans: [],
    activities: [],
    checkpoints: [],
    session: null,
  };
};

const makeSnapshotsLayer = (input: {
  readonly project?: OrchestrationProjectShell;
  readonly getThread?: (threadId: ThreadId) => Option.Option<OrchestrationThread>;
}) =>
  Layer.mock(ProjectionSnapshotQuery.ProjectionSnapshotQuery)({
    getProjectShellById: () =>
      Effect.succeed(input.project === undefined ? Option.none() : Option.some(input.project)),
    getImportedAgentSessionSources: () => Effect.succeed([]),
    getThreadDetailById: (threadId) => Effect.succeed(input.getThread?.(threadId) ?? Option.none()),
  });

const runImport = (input: {
  readonly scanner: AgentSessionScanner.AgentSessionScanner["Service"];
  readonly engine: OrchestrationEngine.OrchestrationEngineService["Service"];
  readonly directory: ProviderSessionDirectory.ProviderSessionDirectory["Service"];
  readonly snapshots: ReturnType<typeof makeSnapshotsLayer>;
  readonly expectedWorkspaceRoot?: string;
}) =>
  importRecentAgentThreads({
    projectId: PROJECT_ID,
    ...(input.expectedWorkspaceRoot === undefined
      ? {}
      : { expectedWorkspaceRoot: input.expectedWorkspaceRoot }),
  }).pipe(
    Effect.provideService(AgentSessionScanner.AgentSessionScanner, input.scanner),
    Effect.provideService(OrchestrationEngine.OrchestrationEngineService, input.engine),
    Effect.provideService(ProviderSessionDirectory.ProviderSessionDirectory, input.directory),
    Effect.provide(input.snapshots),
  );

it.layer(NodeServices.layer)("AgentSessionImporter", (it) => {
  describe("importRecentAgentThreads", () => {
    it.effect("uses the project root and stores provider-specific resume cursors", () =>
      Effect.gen(function* () {
        const commands: Array<OrchestrationCommand> = [];
        const bindings: Array<ProviderSessionDirectory.ProviderRuntimeBinding> = [];
        let scannedRoot: string | undefined;
        const scanner = AgentSessionScanner.AgentSessionScanner.of({
          scan: Effect.die("unused"),
          recentThreads: (workspaceRoot) => {
            scannedRoot = workspaceRoot;
            return Stream.concat(
              Stream.succeed(makeThreadOutcome(makeThread("codex"))),
              Stream.fromEffect(
                Effect.sync(() => {
                  expect(bindings).toHaveLength(1);
                  return makeThreadOutcome(makeThread("claudeAgent"));
                }),
              ),
            );
          },
        });
        const engine = OrchestrationEngine.OrchestrationEngineService.of({
          dispatch: (command) => Effect.sync(() => ({ sequence: commands.push(command) })),
          readEvents: () => Stream.empty,
          readThreadEvents: () => Stream.empty,
          getThreadReplayStats: () => Effect.die("unused"),
          streamDomainEvents: Stream.empty,
          subscribeDomainEvents: Effect.succeed(Stream.empty),
          latestSequence: Effect.succeed(0),
        });
        const directory = ProviderSessionDirectory.ProviderSessionDirectory.of({
          upsert: (binding) => Effect.sync(() => void bindings.push(binding)),
          getProvider: () => Effect.die("unused"),
          recordImportedTranscript: () => Effect.void,
          getBinding: () => Effect.succeedNone,
          listThreadIds: () => Effect.die("unused"),
          listBindings: () => Effect.die("unused"),
        });

        const result = yield* runImport({
          scanner,
          engine,
          directory,
          snapshots: makeSnapshotsLayer({ project: makeProject() }),
          expectedWorkspaceRoot: `${WORKSPACE_ROOT}/`,
        });

        expect(result).toEqual({ importedCount: 2, skippedCount: 0 });
        expect(scannedRoot).toBe(WORKSPACE_ROOT);
        expect(commands.map((command) => command.type)).toEqual([
          "thread.create",
          "thread.history.import",
          "thread.create",
          "thread.history.import",
        ]);
        expect(commands.filter((command) => command.type === "thread.create")).toMatchObject([
          { historyImport: true },
          { historyImport: true },
        ]);
        expect(
          commands
            .filter((command) => command.type === "thread.history.import")
            .flatMap((command) => command.messages.map((message) => message.messageId)),
        ).toEqual([
          "import:codex:codex-session:000000",
          "import:codex:codex-session:000001",
          `import:claudeAgent:${CLAUDE_SESSION_ID}:000000`,
          `import:claudeAgent:${CLAUDE_SESSION_ID}:000001`,
        ]);
        expect(bindings).toMatchObject([
          {
            provider: "codex",
            providerInstanceId: "codex",
            resumeCursor: { threadId: "codex-session" },
            runtimePayload: { cwd: WORKSPACE_ROOT },
          },
          {
            provider: "claudeAgent",
            providerInstanceId: "claudeAgent",
            resumeCursor: {
              threadId: `import:claudeAgent:${CLAUDE_SESSION_ID}`,
              resume: CLAUDE_SESSION_ID,
            },
            runtimePayload: { cwd: WORKSPACE_ROOT },
          },
        ]);
      }),
    );

    for (const source of ["omp", "pi"] as const) {
      it.effect(`stores the cursor shape the ${source} adapter resumes from`, () =>
        Effect.gen(function* () {
          const bindings: Array<ProviderSessionDirectory.ProviderRuntimeBinding> = [];
          const scanner = AgentSessionScanner.AgentSessionScanner.of({
            scan: Effect.die("unused"),
            recentThreads: () => Stream.succeed(makeThreadOutcome(makeThread(source))),
          });
          const engine = OrchestrationEngine.OrchestrationEngineService.of({
            dispatch: () => Effect.succeed({ sequence: 1 }),
            readEvents: () => Stream.empty,
            readThreadEvents: () => Stream.empty,
            getThreadReplayStats: () => Effect.die("unused"),
            streamDomainEvents: Stream.empty,
            subscribeDomainEvents: Effect.succeed(Stream.empty),
            latestSequence: Effect.succeed(0),
          });
          const directory = ProviderSessionDirectory.ProviderSessionDirectory.of({
            upsert: (binding) => Effect.sync(() => void bindings.push(binding)),
            getProvider: () => Effect.die("unused"),
            recordImportedTranscript: () => Effect.void,
            getBinding: () => Effect.succeed(Option.none()),
            listThreadIds: () => Effect.die("unused"),
            listBindings: () => Effect.die("unused"),
          });

          yield* runImport({
            scanner,
            engine,
            directory,
            snapshots: makeSnapshotsLayer({ project: makeProject() }),
          });

          expect(bindings).toMatchObject([
            {
              provider: source,
              resumeCursor: { schemaVersion: 1, sessionId: `${source}-session` },
            },
          ]);
          expect(bindings[0]?.resumeCursor).not.toHaveProperty("resume");
        }),
      );
    }

    it.effect("rejects a changed project root before scanning or writing", () =>
      Effect.gen(function* () {
        const recentThreads = vi.fn(() => Stream.empty);
        const error = yield* importRecentAgentThreads({
          projectId: PROJECT_ID,
          expectedWorkspaceRoot: WORKSPACE_ROOT,
        }).pipe(
          Effect.provideService(
            AgentSessionScanner.AgentSessionScanner,
            AgentSessionScanner.AgentSessionScanner.of({
              scan: Effect.die("must not scan a changed project"),
              recentThreads,
            }),
          ),
          Effect.provide(
            Layer.mergeAll(
              Layer.mock(OrchestrationEngine.OrchestrationEngineService)({}),
              Layer.mock(ProviderSessionDirectory.ProviderSessionDirectory)({}),
              makeSnapshotsLayer({
                project: { ...makeProject(), workspaceRoot: "/tmp/project-moved" },
              }),
            ),
          ),
          Effect.flip,
        );

        expect(error).toEqual(new AgentSessionImportProjectChangedError({ projectId: PROJECT_ID }));
        expect(recentThreads).not.toHaveBeenCalled();
      }),
    );

    it.effect("counts scanner skips without writing a thread or binding", () =>
      Effect.gen(function* () {
        const scanner = AgentSessionScanner.AgentSessionScanner.of({
          scan: Effect.die("unused"),
          recentThreads: () => Stream.succeed({ _tag: "Skipped" }),
        });
        const engine = OrchestrationEngine.OrchestrationEngineService.of({
          dispatch: () => Effect.die("must not dispatch for a scanner skip"),
          readEvents: () => Stream.empty,
          readThreadEvents: () => Stream.empty,
          getThreadReplayStats: () => Effect.die("unused"),
          streamDomainEvents: Stream.empty,
          subscribeDomainEvents: Effect.succeed(Stream.empty),
          latestSequence: Effect.succeed(0),
        });
        const directory = ProviderSessionDirectory.ProviderSessionDirectory.of({
          upsert: () => Effect.die("must not bind a scanner skip"),
          getProvider: () => Effect.die("unused"),
          recordImportedTranscript: () => Effect.die("unused"),
          getBinding: () => Effect.die("must not read a scanner skip binding"),
          listThreadIds: () => Effect.die("unused"),
          listBindings: () => Effect.die("unused"),
        });

        const result = yield* runImport({
          scanner,
          engine,
          directory,
          snapshots: makeSnapshotsLayer({ project: makeProject() }),
        });

        expect(result).toEqual({ importedCount: 0, skippedCount: 1 });
      }),
    );

    it.effect("recovers after a rejected history receipt and a failed binding write", () =>
      Effect.gen(function* () {
        let threadCreated = false;
        let historyImported = false;
        let historyAttemptCount = 0;
        let bindingAttemptCount = 0;
        const rejectedCommandIds = new Set<string>();
        const bindings: Array<ProviderSessionDirectory.ProviderRuntimeBinding> = [];
        const scanner = AgentSessionScanner.AgentSessionScanner.of({
          scan: Effect.die("unused"),
          recentThreads: () => Stream.fromIterable([makeThreadOutcome(makeThread("codex"))]),
        });
        const engine = OrchestrationEngine.OrchestrationEngineService.of({
          dispatch: (command) => {
            if (rejectedCommandIds.has(command.commandId)) {
              return Effect.fail(
                new OrchestrationCommandInvariantError({
                  commandType: command.type,
                  detail: "Previously rejected.",
                }),
              );
            }
            if (command.type === "thread.create") threadCreated = true;
            if (command.type === "thread.history.import") {
              historyAttemptCount += 1;
              if (historyAttemptCount === 1) {
                rejectedCommandIds.add(command.commandId);
                return Effect.fail(
                  new OrchestrationCommandInvariantError({
                    commandType: command.type,
                    detail: "Temporary history import failure.",
                  }),
                );
              }
              historyImported = true;
            }
            return Effect.succeed({ sequence: 1 });
          },
          readEvents: () => Stream.empty,
          readThreadEvents: () => Stream.empty,
          getThreadReplayStats: () => Effect.die("unused"),
          streamDomainEvents: Stream.empty,
          subscribeDomainEvents: Effect.succeed(Stream.empty),
          latestSequence: Effect.succeed(0),
        });
        const directory = ProviderSessionDirectory.ProviderSessionDirectory.of({
          upsert: (binding) => {
            bindingAttemptCount += 1;
            if (bindingAttemptCount === 1) {
              return Effect.fail(
                new ProviderSessionDirectoryPersistenceError({
                  operation: "upsert",
                  detail: "Temporary session storage failure.",
                }),
              );
            }
            bindings.push(binding);
            return Effect.void;
          },
          getProvider: () => Effect.die("unused"),
          recordImportedTranscript: () => Effect.void,
          getBinding: () =>
            Effect.succeed(bindings[0] === undefined ? Option.none() : Option.some(bindings[0])),
          listThreadIds: () => Effect.die("unused"),
          listBindings: () => Effect.die("unused"),
        });
        const snapshots = makeSnapshotsLayer({
          project: makeProject(),
          getThread: () =>
            threadCreated
              ? Option.some(makeProjectedThread({ source: "codex", imported: historyImported }))
              : Option.none(),
        });
        const importOnce = () => runImport({ scanner, engine, directory, snapshots });

        expect(yield* importOnce()).toEqual({ importedCount: 0, skippedCount: 1 });
        expect(yield* importOnce()).toEqual({ importedCount: 0, skippedCount: 1 });
        expect(yield* importOnce()).toEqual({ importedCount: 1, skippedCount: 0 });
        const historyAttemptsAfterCompletion = historyAttemptCount;
        expect(yield* importOnce()).toEqual({ importedCount: 1, skippedCount: 0 });
        expect(historyAttemptCount).toBe(historyAttemptsAfterCompletion);
        expect(historyAttemptCount).toBe(2);
        expect(bindings).toHaveLength(1);
      }),
    );

    it.effect("does not replace completed history or an active binding on retry", () =>
      Effect.gen(function* () {
        const scanner = AgentSessionScanner.AgentSessionScanner.of({
          scan: Effect.die("unused"),
          recentThreads: () => Stream.fromIterable([makeThreadOutcome(makeThread("codex"))]),
        });
        const runningBinding: ProviderSessionDirectory.ProviderRuntimeBinding = {
          threadId: ThreadId.make("import:codex:codex-session"),
          provider: ProviderDriverKind.make("codex"),
          providerInstanceId: ProviderInstanceId.make("codex"),
          status: "running",
          resumeCursor: { threadId: "newer-codex-session" },
        };
        const directory = ProviderSessionDirectory.ProviderSessionDirectory.of({
          upsert: () => Effect.die("must not replace an active binding"),
          getProvider: () => Effect.die("unused"),
          recordImportedTranscript: () => Effect.void,
          getBinding: () => Effect.succeedSome(runningBinding),
          listThreadIds: () => Effect.die("unused"),
          listBindings: () => Effect.die("unused"),
        });
        const engine = OrchestrationEngine.OrchestrationEngineService.of({
          dispatch: () => Effect.die("must not replay history or settle active work"),
          readEvents: () => Stream.empty,
          readThreadEvents: () => Stream.empty,
          getThreadReplayStats: () => Effect.die("unused"),
          streamDomainEvents: Stream.empty,
          subscribeDomainEvents: Effect.succeed(Stream.empty),
          latestSequence: Effect.succeed(0),
        });

        const result = yield* runImport({
          scanner,
          engine,
          directory,
          snapshots: makeSnapshotsLayer({
            project: makeProject(),
            getThread: () =>
              Option.some(
                makeProjectedThread({ source: "codex", imported: true, includeFollowup: true }),
              ),
          }),
        });

        expect(result).toEqual({ importedCount: 1, skippedCount: 0 });
      }),
    );

    it.effect("skips malformed Claude ids and wrong-project thread collisions", () =>
      Effect.gen(function* () {
        const scanner = AgentSessionScanner.AgentSessionScanner.of({
          scan: Effect.die("unused"),
          recentThreads: () =>
            Stream.fromIterable([
              makeThreadOutcome({ ...makeThread("claudeAgent"), providerSessionId: "not-a-uuid" }),
              makeThreadOutcome(makeThread("codex")),
            ]),
        });
        const commands: Array<OrchestrationCommand> = [];
        const engine = OrchestrationEngine.OrchestrationEngineService.of({
          dispatch: (command) => Effect.sync(() => ({ sequence: commands.push(command) })),
          readEvents: () => Stream.empty,
          readThreadEvents: () => Stream.empty,
          getThreadReplayStats: () => Effect.die("unused"),
          streamDomainEvents: Stream.empty,
          subscribeDomainEvents: Effect.succeed(Stream.empty),
          latestSequence: Effect.succeed(0),
        });
        const directory = ProviderSessionDirectory.ProviderSessionDirectory.of({
          upsert: () => Effect.die("must not bind malformed or wrong-project sessions"),
          getProvider: () => Effect.die("unused"),
          recordImportedTranscript: () => Effect.die("unused"),
          getBinding: () => Effect.succeedNone,
          listThreadIds: () => Effect.die("unused"),
          listBindings: () => Effect.die("unused"),
        });

        const result = yield* runImport({
          scanner,
          engine,
          directory,
          snapshots: makeSnapshotsLayer({
            project: makeProject(),
            getThread: (threadId) =>
              threadId === "import:codex:codex-session"
                ? Option.some(
                    makeProjectedThread({
                      source: "codex",
                      projectId: ProjectId.make("project-other"),
                    }),
                  )
                : Option.none(),
          }),
        });

        expect(result).toEqual({ importedCount: 0, skippedCount: 2 });
        expect(commands).toHaveLength(0);
      }),
    );
  });
});

const integrationThread = {
  ...makeThread("codex"),
  updatedAt: "2026-08-24T10:00:00.000Z",
  messages: Array.from({ length: 12 }, (_, index) => ({
    role: index % 2 === 0 ? ("user" as const) : ("assistant" as const),
    text: `Message ${index}`,
    createdAt: "2026-08-24T10:00:00.000Z",
  })),
};
const integrationScanner = AgentSessionScanner.AgentSessionScanner.of({
  scan: Effect.die("unused"),
  recentThreads: () => Stream.fromIterable([makeThreadOutcome(integrationThread)]),
});
const integrationServerConfig = ServerConfig.layerTest(process.cwd(), {
  prefix: "t3-agent-session-importer-test-",
});
const integrationRuntimeRepository = ProviderSessionRuntime.layer.pipe(
  Layer.provide(SqlitePersistenceMemory),
);
const integrationLayer = Layer.mergeAll(
  OrchestrationEngineLive.pipe(
    Layer.provide(OrchestrationProjectionSnapshotQueryLive),
    Layer.provide(OrchestrationProjectionPipelineLive),
  ),
  OrchestrationProjectionSnapshotQueryLive,
  integrationRuntimeRepository,
  ProviderSessionDirectoryLive.pipe(Layer.provide(integrationRuntimeRepository)),
  Layer.succeed(AgentSessionScanner.AgentSessionScanner, integrationScanner),
  TurnStartGatePassthrough,
).pipe(
  Layer.provide(ThreadBackgroundLiveness.layer),
  Layer.provide(ThreadPlanProgress.layer),
  Layer.provide(OrchestrationEventStoreLive),
  Layer.provide(OrchestrationCommandReceiptRepositoryLive),
  Layer.provide(RepositoryIdentityResolver.layer),
  Layer.provide(SqlitePersistenceMemory),
  Layer.provideMerge(integrationServerConfig),
  Layer.provideMerge(NodeServices.layer),
);

it.layer(integrationLayer)("AgentSessionImporter integration", (it) => {
  it.effect("imports once after the real engine persists an old rejected receipt", () =>
    Effect.gen(function* () {
      const engine = yield* OrchestrationEngine.OrchestrationEngineService;
      const snapshots = yield* ProjectionSnapshotQuery.ProjectionSnapshotQuery;
      const directory = yield* ProviderSessionDirectory.ProviderSessionDirectory;
      const threadId = ThreadId.make("import:codex:codex-session");

      yield* engine.dispatch({
        type: "project.create",
        commandId: CommandId.make("create-import-integration-project"),
        projectId: PROJECT_ID,
        title: "Project",
        workspaceRoot: WORKSPACE_ROOT,
        defaultModelSelection: null,
        createdAt: "2026-08-24T09:00:00.000Z",
      });
      const rejected = yield* Effect.result(
        engine.dispatch({
          type: "thread.history.import",
          commandId: CommandId.make(`agent-session:history:${threadId}`),
          threadId,
          messages: [
            {
              messageId: MessageId.make(`${threadId}:000000`),
              role: "user",
              text: "Fix the bug",
              createdAt: "2026-08-24T10:00:00.000Z",
            },
          ],
        }),
      );
      expect(rejected._tag).toBe("Failure");

      const result = yield* importRecentAgentThreads({ projectId: PROJECT_ID });
      const importedThread = yield* snapshots.getThreadDetailById(threadId);
      const binding = yield* directory.getBinding(threadId);

      expect(result).toEqual({ importedCount: 1, skippedCount: 0 });
      expect(Option.getOrThrow(importedThread).messages.map((message) => message.text)).toEqual(
        integrationThread.messages.map((message) => message.text),
      );
      expect(Option.getOrThrow(importedThread).settledOverride).toBe("settled");
      expect(Option.getOrThrow(importedThread).updatedAt).toBe("2026-08-24T10:00:00.000Z");
      expect(Option.getOrThrow(binding)).toMatchObject({
        provider: "codex",
        providerInstanceId: "codex",
        resumeCursor: { threadId: "codex-session" },
        runtimePayload: { cwd: WORKSPACE_ROOT },
      });

      yield* engine.dispatch({
        type: "thread.revert.complete",
        commandId: CommandId.make("revert-imported-thread-to-baseline"),
        threadId,
        turnCount: 0,
        createdAt: "2026-08-24T10:05:00.000Z",
      });
      const afterRevert = yield* snapshots.getThreadDetailById(threadId);
      expect(Option.getOrThrow(afterRevert).messages.map((message) => message.text)).toEqual(
        integrationThread.messages.map((message) => message.text),
      );
    }),
  );

  it.effect(
    "retries a bounded import after scanner restart without rereading completed transcripts",
    () =>
      Effect.gen(function* () {
        const engine = yield* OrchestrationEngine.OrchestrationEngineService;
        const snapshots = yield* ProjectionSnapshotQuery.ProjectionSnapshotQuery;
        const directory = yield* ProviderSessionDirectory.ProviderSessionDirectory;
        const fileSystem = yield* FileSystem.FileSystem;
        const path = yield* Path.Path;
        const nowMs = Date.parse("2026-08-24T12:00:00.000Z");
        yield* TestClock.setTime(nowMs);
        const fixtureDir = yield* fileSystem.makeTempDirectoryScoped({
          prefix: "t3-import-retry-",
        });
        const workspaceRoot = path.join(fixtureDir, "workspace");
        const claudeHomePath = path.join(fixtureDir, "claude");
        const codexHomePath = path.join(fixtureDir, "codex");
        const sessionsDir = path.join(codexHomePath, "sessions", "2026", "08", "24");
        yield* fileSystem.makeDirectory(workspaceRoot);
        yield* fileSystem.makeDirectory(claudeHomePath);
        yield* fileSystem.makeDirectory(sessionsDir, { recursive: true });

        const projectId = ProjectId.make("project-bounded-import-retry");
        const transcripts = Array.from({ length: 101 }, (_, index) => {
          const providerSessionId = `bounded-session-${String(index).padStart(3, "0")}`;
          return {
            providerSessionId,
            threadId: ThreadId.make(`import:codex:${providerSessionId}`),
            filePath: path.join(sessionsDir, `rollout-${providerSessionId}.jsonl`),
          };
        });
        for (const [index, transcript] of transcripts.entries()) {
          yield* fileSystem.writeFileString(
            transcript.filePath,
            [
              encodeTranscriptRecord({
                type: "session_meta",
                payload: { id: transcript.providerSessionId, cwd: workspaceRoot },
              }),
              encodeTranscriptRecord({
                type: "event_msg",
                payload: {
                  type: "user_message",
                  message: `Prompt ${transcript.providerSessionId}`,
                },
              }),
            ].join("\n"),
          );
          const seconds = nowMs / 1_000 - index;
          yield* fileSystem.utimes(transcript.filePath, seconds, seconds);
        }
        const legacy = transcripts[0]!;
        const failed = transcripts[1]!;
        const remaining = transcripts[100]!;
        yield* engine.dispatch({
          type: "project.create",
          commandId: CommandId.make("create-bounded-import-project"),
          projectId,
          title: "Bounded import",
          workspaceRoot,
          defaultModelSelection: null,
          createdAt: "2026-08-24T09:00:00.000Z",
        });

        // This completed import predates persisted transcript source metadata.
        yield* directory.upsert({
          threadId: legacy.threadId,
          provider: ProviderDriverKind.make("codex"),
          providerInstanceId: ProviderInstanceId.make("codex"),
          status: "stopped",
          resumeCursor: { threadId: "legacy-current-session" },
          runtimePayload: { cwd: workspaceRoot },
        });
        yield* engine.dispatch({
          type: "thread.create",
          commandId: CommandId.make("create-legacy-bounded-import"),
          threadId: legacy.threadId,
          projectId,
          title: "Legacy import",
          modelSelection: { instanceId: ProviderInstanceId.make("codex"), model: "default" },
          runtimeMode: "full-access",
          interactionMode: "default",
          branch: null,
          worktreePath: null,
          createdAt: "2026-08-24T10:00:00.000Z",
          historyImport: true,
        });
        yield* engine.dispatch({
          type: "thread.history.import",
          commandId: CommandId.make("import-legacy-bounded-history"),
          threadId: legacy.threadId,
          messages: [
            {
              messageId: MessageId.make(`${legacy.threadId}:000000`),
              role: "user",
              text: "Legacy imported history",
              createdAt: "2026-08-24T10:00:00.000Z",
            },
          ],
        });
        expect(yield* snapshots.getImportedAgentSessionSources(projectId)).toEqual([]);

        let failHistory = true;
        const importerEngine = OrchestrationEngine.OrchestrationEngineService.of({
          ...engine,
          dispatch: (command) => {
            if (
              failHistory &&
              command.type === "thread.history.import" &&
              command.threadId === failed.threadId
            ) {
              failHistory = false;
              return Effect.fail(
                new OrchestrationCommandInvariantError({
                  commandType: command.type,
                  detail: "Injected history import failure.",
                }),
              );
            }
            return engine.dispatch(command);
          },
        });
        const settingsLayer = ServerSettingsService.layerTest({
          providers: {
            claudeAgent: { homePath: claudeHomePath },
            codex: { homePath: codexHomePath },
          },
        });
        const transcriptPaths = new Set(transcripts.map((transcript) => transcript.filePath));
        const runAttempt = Effect.fn("runBoundedImportAttempt")(function* (
          completedPaths: ReadonlySet<string>,
        ) {
          const openCounts = new Map<string, number>();
          const fullReads: string[] = [];
          const observedFileSystem = FileSystem.FileSystem.of({
            ...fileSystem,
            open: (filePath, options) =>
              Effect.suspend(() => {
                if (transcriptPaths.has(filePath)) {
                  const count = (openCounts.get(filePath) ?? 0) + 1;
                  openCounts.set(filePath, count);
                  // A fresh scanner first opens each file for project discovery.
                  if (count > 1) {
                    fullReads.push(filePath);
                    if (completedPaths.has(filePath)) {
                      return Effect.die(new Error(`Completed transcript reopened: ${filePath}`));
                    }
                  }
                }
                return fileSystem.open(filePath, options);
              }),
          });
          const result = yield* importRecentAgentThreads({ projectId }).pipe(
            Effect.provide(
              Layer.fresh(AgentSessionScanner.layer).pipe(
                Layer.provide(settingsLayer),
                Layer.provide(Layer.succeed(FileSystem.FileSystem, observedFileSystem)),
              ),
            ),
            Effect.provideService(OrchestrationEngine.OrchestrationEngineService, importerEngine),
          );
          return { result, fullReads, openCounts };
        });

        const first = yield* runAttempt(new Set());
        expect(first.result).toEqual({ importedCount: 99, skippedCount: 2 });
        expect(failHistory).toBe(false);
        expect(first.fullReads).toEqual(transcripts.slice(0, 100).map((entry) => entry.filePath));
        expect(first.openCounts.get(remaining.filePath)).toBe(1);
        const completedSources = yield* snapshots.getImportedAgentSessionSources(projectId);
        expect(completedSources).toHaveLength(99);
        expect(completedSources).toContainEqual({
          threadId: legacy.threadId,
          source: expect.objectContaining({ filePath: legacy.filePath }),
        });
        expect(
          Option.getOrThrow(yield* snapshots.getThreadDetailById(failed.threadId)).messages,
        ).toEqual([]);
        expect(Option.getOrThrow(yield* directory.getBinding(failed.threadId))).toMatchObject({
          status: "stopped",
          resumeCursor: { threadId: failed.providerSessionId },
        });
        expect(Option.isNone(yield* snapshots.getThreadDetailById(remaining.threadId))).toBe(true);

        const completedPaths = new Set(completedSources.map((entry) => entry.source.filePath));
        const second = yield* runAttempt(completedPaths);
        expect(second.result).toEqual({ importedCount: 101, skippedCount: 0 });
        expect(second.fullReads).toEqual([failed.filePath, remaining.filePath]);
        for (const transcript of transcripts) {
          expect(second.openCounts.get(transcript.filePath)).toBe(
            completedPaths.has(transcript.filePath) ? 1 : 2,
          );
        }
        expect(yield* snapshots.getImportedAgentSessionSources(projectId)).toHaveLength(101);
        expect(
          Option.getOrThrow(yield* snapshots.getThreadDetailById(legacy.threadId)).messages.map(
            (message) => message.text,
          ),
        ).toEqual(["Legacy imported history"]);
        expect(
          Option.getOrThrow(yield* directory.getBinding(legacy.threadId)).resumeCursor,
        ).toEqual({
          threadId: "legacy-current-session",
        });
        for (const transcript of [failed, remaining]) {
          expect(
            Option.getOrThrow(
              yield* snapshots.getThreadDetailById(transcript.threadId),
            ).messages.map((message) => message.text),
          ).toEqual([`Prompt ${transcript.providerSessionId}`]);
        }
      }),
  );

  for (const source of ["codex", "claudeAgent"] as const) {
    it.effect(`resumes imported ${source} history only after the first prompt`, () =>
      Effect.gen(function* () {
        const engine = yield* OrchestrationEngine.OrchestrationEngineService;
        const snapshots = yield* ProjectionSnapshotQuery.ProjectionSnapshotQuery;
        const directory = yield* ProviderSessionDirectory.ProviderSessionDirectory;
        const fileSystem = yield* FileSystem.FileSystem;
        const workspaceRoot = yield* fileSystem.makeTempDirectoryScoped();
        const projectId = ProjectId.make(`project-import-resume-${source}`);
        const sourceThread = {
          ...makeThread(source),
          providerSessionId: source === "codex" ? "codex-first-resume" : CLAUDE_SESSION_ID,
        };
        const threadId = ThreadId.make(
          `import:${sourceThread.providerInstanceId}:${sourceThread.providerSessionId}`,
        );
        const resumeCursor =
          source === "codex"
            ? { threadId: sourceThread.providerSessionId }
            : { threadId, resume: sourceThread.providerSessionId };
        const provider = ProviderDriverKind.make(source);
        const harness = yield* makeTestProviderAdapterHarness({ provider });
        const importSettled = yield* Deferred.make<void>();
        const turnSent = yield* Deferred.make<void>();
        const startSession = vi.fn(harness.adapter.startSession);
        const sendTurn = vi.fn((input: ProviderSendTurnInput) =>
          harness.adapter
            .sendTurn(input)
            .pipe(Effect.tap(() => Deferred.succeed(turnSent, undefined))),
        );
        const providerLayer = makeProviderServiceLive().pipe(
          Layer.provide(
            Layer.succeed(
              ProviderAdapterRegistry,
              makeAdapterRegistryMock({
                [provider]: { ...harness.adapter, startSession, sendTurn },
              }),
            ),
          ),
          Layer.provide(
            Layer.succeed(ProviderSessionDirectory.ProviderSessionDirectory, directory),
          ),
          Layer.provide(Layer.succeed(ProviderEventLoggers, NoOpProviderEventLoggers)),
          Layer.provide(AnalyticsService.layerTest),
        );
        const reactorLayer = ProviderCommandReactorLive.pipe(
          Layer.provideMerge(providerLayer),
          Layer.provide(
            Layer.succeed(ProjectionSnapshotQuery.ProjectionSnapshotQuery, {
              ...snapshots,
              // Acknowledge the imported settlement before draining the reactor.
              getThreadShellById: (requestedThreadId) =>
                snapshots
                  .getThreadShellById(requestedThreadId)
                  .pipe(
                    Effect.tap(() =>
                      requestedThreadId === threadId
                        ? Deferred.succeed(importSettled, undefined)
                        : Effect.void,
                    ),
                  ),
            }),
          ),
          Layer.provide(
            Layer.mock(ProviderAuthService)({
              tryHandlePromptCommand: () => Effect.succeed(false),
            }),
          ),
          Layer.provide(makeProviderRegistryLayer()),
          Layer.provide(Layer.mock(GitWorkflowService)({})),
          Layer.provide(Layer.mock(VcsStatusBroadcaster)({})),
          Layer.provide(Layer.mock(TextGeneration)({})),
          Layer.provide(Layer.mock(TerminalManager)({ closeIdle: () => Effect.void })),
          Layer.provide(ServerSettingsService.layerTest()),
        );

        yield* engine.dispatch({
          type: "project.create",
          commandId: CommandId.make(`create-import-resume-project-${source}`),
          projectId,
          title: "Import resume",
          workspaceRoot,
          defaultModelSelection: null,
          createdAt: "2026-08-24T09:00:00.000Z",
        });
        yield* harness.queueTurnResponseForNextSession({ events: [] });

        yield* Effect.gen(function* () {
          const reactor = yield* ProviderCommandReactor;
          yield* reactor.start();
          expect(yield* importRecentAgentThreads({ projectId })).toEqual({
            importedCount: 1,
            skippedCount: 0,
          });
          yield* Deferred.await(importSettled);
          yield* reactor.drain;
          expect(startSession).not.toHaveBeenCalled();
          expect(sendTurn).not.toHaveBeenCalled();
          const importedThread = Option.getOrThrow(yield* snapshots.getThreadDetailById(threadId));
          expect(importedThread.session).toBeNull();
          expect(importedThread.latestTurn).toBeNull();

          yield* engine.dispatch({
            type: "thread.turn.start",
            commandId: CommandId.make(`resume-imported-${source}`),
            threadId,
            message: {
              messageId: MessageId.make(`resume-imported-message-${source}`),
              role: "user",
              text: "Continue this session",
              attachments: [],
            },
            modelSelection: importedThread.modelSelection,
            runtimeMode: importedThread.runtimeMode,
            interactionMode: importedThread.interactionMode,
            createdAt: "2026-08-24T10:02:00.000Z",
          });
          yield* Deferred.await(turnSent);
          yield* reactor.drain;
          expect(startSession).toHaveBeenCalledExactlyOnceWith(
            expect.objectContaining({
              threadId,
              provider,
              providerInstanceId: sourceThread.providerInstanceId,
              resumeCursor,
              cwd: workspaceRoot,
            }),
          );
          expect(sendTurn).toHaveBeenCalledExactlyOnceWith(
            expect.objectContaining({ threadId, input: "Continue this session" }),
          );
          expect(Option.getOrThrow(yield* directory.getBinding(threadId))).toMatchObject({
            provider,
            providerInstanceId: sourceThread.providerInstanceId,
            resumeCursor,
          });
        }).pipe(
          Effect.provide(reactorLayer),
          Effect.provideService(
            AgentSessionScanner.AgentSessionScanner,
            AgentSessionScanner.AgentSessionScanner.of({
              scan: Effect.die("unused"),
              recentThreads: () => Stream.succeed(makeThreadOutcome(sourceThread)),
            }),
          ),
        );
      }),
    );
  }

  it.effect("persists the resume cursor before publishing a new imported thread", () =>
    Effect.gen(function* () {
      const engine = yield* OrchestrationEngine.OrchestrationEngineService;
      const snapshots = yield* ProjectionSnapshotQuery.ProjectionSnapshotQuery;
      const directory = yield* ProviderSessionDirectory.ProviderSessionDirectory;
      const repository = yield* ProviderSessionRuntime.ProviderSessionRuntimeRepository;
      const projectId = ProjectId.make("project-import-binding-race");
      const workspaceRoot = "/tmp/project-import-binding-race";
      const providerSessionId = "codex-binding-race";
      const threadId = ThreadId.make(`import:codex:${providerSessionId}`);
      const scanner = AgentSessionScanner.AgentSessionScanner.of({
        scan: Effect.die("unused"),
        recentThreads: () =>
          Stream.succeed(
            makeThreadOutcome({ ...integrationThread, providerSessionId, title: "Binding race" }),
          ),
      });
      const importerAtBindingWrite = yield* Deferred.make<void>();
      const releaseImporter = yield* Deferred.make<void>();
      const importerRepository = ProviderSessionRuntime.ProviderSessionRuntimeRepository.of({
        ...repository,
        upsert: (runtime, options) =>
          options?.onConflict === "ignore"
            ? Deferred.succeed(importerAtBindingWrite, undefined).pipe(
                Effect.andThen(Deferred.await(releaseImporter)),
                Effect.andThen(repository.upsert(runtime, options)),
              )
            : repository.upsert(runtime, options),
      });
      const importerDirectory = yield* ProviderSessionDirectory.ProviderSessionDirectory.pipe(
        Effect.provide(
          Layer.fresh(ProviderSessionDirectoryLive).pipe(
            Layer.provide(
              Layer.succeed(
                ProviderSessionRuntime.ProviderSessionRuntimeRepository,
                importerRepository,
              ),
            ),
          ),
        ),
      );

      yield* engine.dispatch({
        type: "project.create",
        commandId: CommandId.make("create-import-binding-race-project"),
        projectId,
        title: "Binding race",
        workspaceRoot,
        defaultModelSelection: null,
        createdAt: "2026-08-24T09:00:00.000Z",
      });

      const importFiber = yield* importRecentAgentThreads({ projectId }).pipe(
        Effect.provideService(AgentSessionScanner.AgentSessionScanner, scanner),
        Effect.provideService(ProviderSessionDirectory.ProviderSessionDirectory, importerDirectory),
        Effect.forkChild,
      );

      yield* Effect.raceFirst(
        Deferred.await(importerAtBindingWrite),
        Fiber.join(importFiber).pipe(
          Effect.flatMap((result) =>
            Effect.die(
              new Error(`Import completed before the binding write: ${JSON.stringify(result)}`),
            ),
          ),
        ),
      );
      expect(Option.isNone(yield* snapshots.getThreadDetailById(threadId))).toBe(true);

      yield* directory.upsert({
        threadId,
        provider: ProviderDriverKind.make("codex"),
        providerInstanceId: ProviderInstanceId.make("codex"),
        status: "running",
        resumeCursor: { threadId: "active-client-session" },
        runtimePayload: { cwd: workspaceRoot, activeTurnId: "turn-active" },
      });
      yield* Deferred.succeed(releaseImporter, undefined);

      expect(yield* Fiber.join(importFiber)).toEqual({ importedCount: 1, skippedCount: 0 });
      expect(
        Option.getOrThrow(yield* snapshots.getThreadDetailById(threadId)).messages.map(
          (message) => message.text,
        ),
      ).toEqual(integrationThread.messages.map((message) => message.text));
      expect(Option.getOrThrow(yield* directory.getBinding(threadId))).toMatchObject({
        status: "running",
        resumeCursor: { threadId: "active-client-session" },
        runtimePayload: { cwd: workspaceRoot, activeTurnId: "turn-active" },
      });
    }),
  );

  it.effect("does not import history over a turn started on a partial thread", () =>
    Effect.gen(function* () {
      const engine = yield* OrchestrationEngine.OrchestrationEngineService;
      const snapshots = yield* ProjectionSnapshotQuery.ProjectionSnapshotQuery;
      const directory = yield* ProviderSessionDirectory.ProviderSessionDirectory;
      const repository = yield* ProviderSessionRuntime.ProviderSessionRuntimeRepository;
      const projectId = ProjectId.make("project-import-turn-race");
      const workspaceRoot = "/tmp/project-import-turn-race";
      const providerSessionId = "codex-turn-race";
      const threadId = ThreadId.make(`import:codex:${providerSessionId}`);
      const scanner = AgentSessionScanner.AgentSessionScanner.of({
        scan: Effect.die("unused"),
        recentThreads: () =>
          Stream.succeed(
            makeThreadOutcome({ ...integrationThread, providerSessionId, title: "Turn race" }),
          ),
      });
      const importerAtBindingWrite = yield* Deferred.make<void>();
      const releaseImporter = yield* Deferred.make<void>();
      const importerRepository = ProviderSessionRuntime.ProviderSessionRuntimeRepository.of({
        ...repository,
        upsert: (runtime, options) =>
          options?.onConflict === "ignore"
            ? Deferred.succeed(importerAtBindingWrite, undefined).pipe(
                Effect.andThen(Deferred.await(releaseImporter)),
                Effect.andThen(repository.upsert(runtime, options)),
              )
            : repository.upsert(runtime, options),
      });
      const importerDirectory = yield* ProviderSessionDirectory.ProviderSessionDirectory.pipe(
        Effect.provide(
          Layer.fresh(ProviderSessionDirectoryLive).pipe(
            Layer.provide(
              Layer.succeed(
                ProviderSessionRuntime.ProviderSessionRuntimeRepository,
                importerRepository,
              ),
            ),
          ),
        ),
      );

      yield* engine.dispatch({
        type: "project.create",
        commandId: CommandId.make("create-import-turn-race-project"),
        projectId,
        title: "Turn race",
        workspaceRoot,
        defaultModelSelection: null,
        createdAt: "2026-08-24T09:00:00.000Z",
      });
      yield* engine.dispatch({
        type: "thread.create",
        commandId: CommandId.make("create-import-turn-race-thread"),
        threadId,
        projectId,
        title: "Turn race",
        modelSelection: { instanceId: ProviderInstanceId.make("codex"), model: "default" },
        runtimeMode: "full-access",
        interactionMode: "default",
        branch: null,
        worktreePath: null,
        createdAt: "2026-08-24T10:00:00.000Z",
      });

      const importFiber = yield* importRecentAgentThreads({ projectId }).pipe(
        Effect.provideService(AgentSessionScanner.AgentSessionScanner, scanner),
        Effect.provideService(ProviderSessionDirectory.ProviderSessionDirectory, importerDirectory),
        Effect.forkChild,
      );
      yield* Deferred.await(importerAtBindingWrite);

      yield* directory.upsert({
        threadId,
        provider: ProviderDriverKind.make("codex"),
        providerInstanceId: ProviderInstanceId.make("codex"),
        status: "running",
        resumeCursor: { threadId: "active-client-session" },
        runtimePayload: { cwd: workspaceRoot, activeTurnId: "turn-active" },
      });
      yield* engine.dispatch({
        type: "thread.turn.start",
        commandId: CommandId.make("start-turn-during-import"),
        threadId,
        message: {
          messageId: MessageId.make("message-during-import"),
          role: "user",
          text: "Continue while import waits",
          attachments: [],
=======
it.effect("imports messages once and preserves the provider native resume binding", () => {
  const writes: Array<ReadonlyArray<OrchestrationV2DomainEvent>> = [];
  const upserts: Array<unknown> = [];
  const recorded: Array<unknown> = [];
  let imported = false;
  const scanner = AgentSessionScanner.AgentSessionScanner.of({
    scan: Effect.die("unused"),
    recentThreads: () =>
      Stream.succeed({
        _tag: "Importable",
        source: {
          provider: "codex",
          providerInstanceId,
          providerSessionId,
          filePath: "/tmp/native-codex-thread.jsonl",
          size: 100,
          mtimeMs: 2,
          device: 3,
          inode: 4,
          birthtimeMs: 1,
>>>>>>> upstream-sync-43f8a8de1-upstream-renamed
        },
        thread: {
          source: "codex",
          providerInstanceId,
          providerSessionId,
          title: "Imported thread",
          model: "gpt-5.4",
          createdAt: "2026-09-01T10:00:00.000Z",
          updatedAt: "2026-09-01T10:01:00.000Z",
          messages: [
            { role: "user", text: "Fix it", createdAt: "2026-09-01T10:00:00.000Z" },
            { role: "assistant", text: "Fixed", createdAt: "2026-09-01T10:01:00.000Z" },
          ],
        },
      }),
  });
  const layerTest = AgentSessionImporter.layer.pipe(
    Layer.provide(
      Layer.mergeAll(
        Layer.succeed(AgentSessionScanner.AgentSessionScanner, scanner),
        Layer.mock(ProjectService.ProjectService)({
          getById: () =>
            Effect.succeed(
              Option.some({ id: projectId, workspaceRoot: "/workspace/project" } as never),
            ),
        }),
        Layer.mock(Orchestrator.OrchestratorV2)({
          getThreadRecords: () =>
            imported
              ? Effect.succeed({
                  thread: { id: threadId, projectId, historyOrigin: "v1_import" },
                } as never)
              : Effect.fail(new Orchestrator.OrchestratorProjectionError({ threadId })),
        }),
        Layer.mock(EventSink.EventSinkV2)({
          write: (input) =>
            Effect.sync(() => {
              writes.push(input.events);
              imported = true;
              return [];
            }),
        }),
        Layer.mock(ProviderSessionRuntime.ProviderSessionRuntimeRepository)({
          list: () => Effect.succeed([]),
          upsert: (input) => Effect.sync(() => void upserts.push(input)),
          recordImportedTranscript: (input) => Effect.sync(() => void recorded.push(input)),
        }),
        IdAllocator.layer,
      ),
    ),
  );

  return Effect.gen(function* () {
    const importer = yield* AgentSessionImporter.AgentSessionImporter;
    expect(yield* importer.importRecentAgentThreads({ projectId })).toEqual({
      importedCount: 1,
      skippedCount: 0,
    });
    expect(yield* importer.importRecentAgentThreads({ projectId })).toEqual({
      importedCount: 1,
      skippedCount: 0,
    });

    expect(writes).toHaveLength(1);
    expect(writes[0]?.map((event) => event.type)).toEqual([
      "thread.created",
      "message.updated",
      "turn-item.updated",
      "message.updated",
      "turn-item.updated",
      "provider-thread.updated",
    ]);
    const created = writes[0]?.find((event) => event.type === "thread.created");
    const providerThread = writes[0]?.find((event) => event.type === "provider-thread.updated");
    expect(created?.payload).toMatchObject({
      id: threadId,
      activeProviderThreadId: providerThread?.payload.id,
      historyOrigin: "v1_import",
    });
    expect(providerThread?.payload).toMatchObject({
      appThreadId: threadId,
      nativeThreadRef: {
        driver: "codex",
        nativeId: providerSessionId,
        strength: "strong",
      },
    });
    expect(
      writes[0]
        ?.filter((event) => event.type === "message.updated")
        .map((event) => event.payload.text),
    ).toEqual(["Fix it", "Fixed"]);
    expect(upserts).toEqual([
      expect.objectContaining({
        threadId,
        providerInstanceId,
        resumeCursor: { threadId: providerSessionId },
      }),
    ]);
    expect(recorded).toHaveLength(2);
  }).pipe(Effect.provide(layerTest));
});
