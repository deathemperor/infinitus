import {
  ApprovalRequestId,
  CommandId,
  MessageId,
  QueueId,
  ThreadId,
  type ModelSelection,
  type OrchestrationEvent,
  type OrchestrationThreadShell,
  type ProviderRuntimeEvent,
} from "@t3tools/contracts";
import { buildTemporaryWorktreeBranchName } from "@t3tools/shared/git";
import { resolveProjectSettings } from "@t3tools/shared/projectSettings";
import { fromJsonStringPretty } from "@t3tools/shared/schemaJson";
import * as Crypto from "effect/Crypto";
import * as DateTime from "effect/DateTime";
import * as Duration from "effect/Duration";
import * as Deferred from "effect/Deferred";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";
import * as Path from "effect/Path";
import * as Schema from "effect/Schema";
import * as Semaphore from "effect/Semaphore";
import * as Stream from "effect/Stream";

import { writeFileStringAtomically } from "../../atomicWrite.ts";
import { ServerConfig } from "../../config.ts";
import { GitWorkflowService } from "../../git/GitWorkflowService.ts";
import { OrchestrationEngineService } from "../../orchestration/Services/OrchestrationEngine.ts";
import { ProjectionSnapshotQuery } from "../../orchestration/Services/ProjectionSnapshotQuery.ts";
import {
  WORKTREE_CAP_SUGGESTIONS,
  worktreeCapRefusal,
} from "../../orchestration/worktreeCap.logic.ts";
import { ProjectSetupScriptRunner } from "../../project/ProjectSetupScriptRunner.ts";
import { ProviderService } from "../../provider/Services/ProviderService.ts";
import { forkParked } from "../../serverActivation.ts";
import { ServerSettingsService } from "../../serverSettings.ts";
import { VcsStatusBroadcaster } from "../../vcs/VcsStatusBroadcaster.ts";
import {
  SlackClient,
  type SlackInbound,
  type SlackPost,
} from "../Services/InfinitusSlackClient.ts";
import { OFFLINE_TEXT } from "./infinitusSlackSocket.logic.ts";
import {
  activityLine,
  approvalMessage,
  doneText,
  MAX_SLACK_BINDINGS,
  parseAction,
  parseMention,
  projectsReply,
  questionMessage,
  replyCommand,
  resolveSlackProject,
  slackThreadKey,
  SlackThreadBindings,
  threadTitle,
  type SlackThreadBinding,
} from "./infinitusSlack.logic.ts";

/**
 * Slack bridge (#574): the reactor. A mention of the app starts a thread on
 * the named project and answers in the message's Slack thread; replies
 * there steer it (queued while a turn runs), `stop` interrupts, `babysit`
 * turns babysit on; approval and question buttons answer the provider's
 * requests. Inert until the setting is on, both tokens exist and at least
 * one user is allowed; anyone else gets no reply. A thread starts where
 * the project's settings say (#957, ws.ts's bootstrap): in a worktree off
 * the checkout's current branch — the worktree limit (#269 H) checked
 * first, its refusal posted to Slack; a git failure deletes the thread
 * and posts the error — or on the checkout itself when the mode is local,
 * the project is no repo, or its HEAD is detached. The setup script runs
 * best-effort. Message text never reaches a log, only its length.
 */

const BindingsJson = fromJsonStringPretty(SlackThreadBindings);
const decodeBindings = Schema.decodeUnknownEffect(BindingsJson);
const encodeBindings = Schema.encodeEffect(BindingsJson);

export const InfinitusSlackLive = Layer.effectDiscard(
  Effect.gen(function* () {
    const settings = yield* ServerSettingsService;
    const orchestrationEngine = yield* OrchestrationEngineService;
    const projectionSnapshotQuery = yield* ProjectionSnapshotQuery;
    const providerService = yield* ProviderService;
    const gitWorkflow = yield* GitWorkflowService;
    const vcsStatusBroadcaster = yield* VcsStatusBroadcaster;
    const projectSetupScriptRunner = yield* ProjectSetupScriptRunner;
    const slack = yield* SlackClient;
    const crypto = yield* Crypto.Crypto;
    const config = yield* ServerConfig;
    const fs = yield* FileSystem.FileSystem;
    const path = yield* Path.Path;

    const bindingsFile = path.join(config.stateDir, "infinitus-slack", "threads.json");
    const byThread = new Map<ThreadId, SlackThreadBinding>();
    const bySlack = new Map<string, SlackThreadBinding>();
    const lock = yield* Semaphore.make(1);
    /** Per thread: what has been posted once (turn ids, PR states, request ids). */
    const posted = new Map<ThreadId, Set<string>>();
    const seenEnvelopes = new Set<string>();
    /** Threads this process started or steered: told when it goes away. */
    const liveThreads = new Set<ThreadId>();

    const oncePer = (threadId: ThreadId, key: string): boolean => {
      const set = posted.get(threadId) ?? new Set<string>();
      if (set.has(key)) return false;
      set.add(key);
      posted.set(threadId, set);
      return true;
    };

    const serverCommandId = (tag: string) =>
      crypto.randomUUIDv4.pipe(Effect.map((uuid) => CommandId.make(`server:slack-${tag}:${uuid}`)));
    const now = DateTime.now.pipe(Effect.map(DateTime.formatIso));

    const loadBindings = Effect.gen(function* () {
      if (!(yield* fs.exists(bindingsFile))) return;
      const rows = yield* decodeBindings(yield* fs.readFileString(bindingsFile));
      for (const row of rows) {
        byThread.set(row.threadId, row);
        bySlack.set(slackThreadKey(row.channel, row.threadTs), row);
      }
    }).pipe(
      Effect.catchCause((cause) =>
        Effect.logWarning("infinitus.slack.bindings-unreadable", { cause }),
      ),
    );

    const saveBindings = lock.withPermits(1)(
      Effect.gen(function* () {
        const rows = [...byThread.values()].slice(-MAX_SLACK_BINDINGS);
        yield* fs.makeDirectory(path.dirname(bindingsFile), { recursive: true });
        yield* writeFileStringAtomically({
          filePath: bindingsFile,
          contents: yield* encodeBindings(rows),
        });
      }).pipe(
        Effect.catchCause((cause) =>
          Effect.logWarning("infinitus.slack.bindings-unwritable", { cause }),
        ),
      ),
    );

    const bind = (binding: SlackThreadBinding) =>
      Effect.gen(function* () {
        byThread.set(binding.threadId, binding);
        bySlack.set(slackThreadKey(binding.channel, binding.threadTs), binding);
        yield* saveBindings;
      });

    const unbind = (threadId: ThreadId) =>
      Effect.gen(function* () {
        const binding = byThread.get(threadId);
        if (binding === undefined) return;
        byThread.delete(threadId);
        bySlack.delete(slackThreadKey(binding.channel, binding.threadTs));
        posted.delete(threadId);
        yield* saveBindings;
      });

    /** A post that fails is logged; the thread keeps running. */
    const post = (input: SlackPost) =>
      slack.post(input).pipe(
        Effect.asVoid,
        Effect.catchCause((cause) => Effect.logWarning("infinitus.slack.post-failed", { cause })),
      );

    const postTo = (binding: SlackThreadBinding, text: string, blocks?: ReadonlyArray<unknown>) =>
      post({
        channel: binding.channel,
        threadTs: binding.threadTs,
        text,
        ...(blocks ? { blocks } : {}),
      });

    const gate = Effect.gen(function* () {
      const current = yield* settings.getSettings;
      const slackSettings = current.infinitusSlack;
      const armed =
        slackSettings.enabled &&
        slackSettings.appToken.length > 0 &&
        slackSettings.botToken.length > 0 &&
        slackSettings.allowedUserIds.length > 0;
      return {
        armed,
        allowed: new Set(slackSettings.allowedUserIds),
        defaultModelSelection: current.defaultModelSelection,
      };
    });

    const shellOf = (threadId: ThreadId) =>
      projectionSnapshotQuery
        .getThreadShellById(threadId)
        .pipe(Effect.option, Effect.map(Option.flatten));

    /** ws.ts's worktree step: a temporary branch off the base, from origin's copy when asked. */
    const createWorktree = (cwd: string, baseBranch: string, startFromOrigin: boolean) =>
      Effect.gen(function* () {
        let baseRef = baseBranch;
        if (startFromOrigin && (yield* gitWorkflow.remoteExists({ cwd, remoteName: "origin" }))) {
          yield* gitWorkflow.fetchRemote({ cwd, remoteName: "origin" });
          const remoteBaseExists = yield* gitWorkflow.remoteBranchExists({
            cwd,
            refName: baseBranch,
            remoteName: "origin",
          });
          if (remoteBaseExists) {
            const remote = yield* gitWorkflow.resolveRemoteTrackingCommit({
              cwd,
              refName: baseBranch,
              fallbackRemoteName: "origin",
            });
            baseRef = remote.commitSha;
          }
        }
        const bytes = yield* crypto.randomBytes(4);
        const hex = Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
        const worktree = yield* gitWorkflow.createWorktree({
          cwd,
          refName: baseRef,
          newRefName: buildTemporaryWorktreeBranchName(() => hex),
          baseRefName: baseBranch,
          path: null,
        });
        return worktree.worktree;
      });

    const startThread = (
      event: Extract<SlackInbound, { kind: "mention" }>,
      defaultModelSelection: ModelSelection | null,
    ) =>
      Effect.gen(function* () {
        const mention = parseMention(event.text);
        const snapshot = yield* projectionSnapshotQuery.getShellSnapshot();
        if (mention === null) {
          return yield* post({
            channel: event.channel,
            threadTs: event.threadTs,
            text: projectsReply(snapshot.projects),
          });
        }
        const project = resolveSlackProject(snapshot.projects, mention.projectHandle);
        if (project === null) {
          return yield* post({
            channel: event.channel,
            threadTs: event.threadTs,
            text: projectsReply(snapshot.projects),
          });
        }
        const modelSelection = project.defaultModelSelection ?? defaultModelSelection;
        if (modelSelection === null) {
          return yield* post({
            channel: event.channel,
            threadTs: event.threadTs,
            text: "No default model: set one in Infinitus › Settings first.",
          });
        }
        const current = yield* settings.getSettings;
        const resolved = resolveProjectSettings(current, project.id, project).settings;
        // The base branch: null keeps the thread on the checkout.
        let baseBranch: string | null = null;
        if (resolved.defaultThreadEnvMode === "worktree") {
          const status = yield* vcsStatusBroadcaster
            .getStatus({ cwd: project.workspaceRoot })
            .pipe(Effect.option);
          baseBranch = status._tag === "Some" && status.value.isRepo ? status.value.refName : null;
          if (baseBranch !== null && current.worktreeMaxCount > 0) {
            const holders =
              yield* projectionSnapshotQuery.getWorktreeHolders(WORKTREE_CAP_SUGGESTIONS);
            const refusal = worktreeCapRefusal(holders, current.worktreeMaxCount);
            if (refusal !== null) {
              return yield* post({
                channel: event.channel,
                threadTs: event.threadTs,
                text: refusal,
              });
            }
          }
        }
        const threadId = ThreadId.make(yield* crypto.randomUUIDv4);
        const createdAt = yield* now;
        yield* orchestrationEngine.dispatch({
          type: "thread.create",
          commandId: yield* serverCommandId("create"),
          threadId,
          projectId: project.id,
          title: threadTitle(mention.task),
          modelSelection,
          runtimeMode: mention.runtimeMode,
          interactionMode: "default",
          branch: null,
          worktreePath: null,
          createdAt,
        });
        let branch: string | null = null;
        if (baseBranch !== null) {
          const worktree = yield* createWorktree(
            project.workspaceRoot,
            baseBranch,
            resolved.newWorktreesStartFromOrigin,
          ).pipe(
            Effect.catch((error) =>
              Effect.gen(function* () {
                yield* orchestrationEngine.dispatch({
                  type: "thread.delete",
                  commandId: yield* serverCommandId("delete"),
                  threadId,
                });
                yield* Effect.logWarning("infinitus.slack.worktree-failed", {
                  threadId,
                  projectId: project.id,
                  error: error.message,
                });
                yield* post({
                  channel: event.channel,
                  threadTs: event.threadTs,
                  text: `Could not create a worktree for ${project.title}: ${error.message}`,
                });
                return null;
              }),
            ),
          );
          if (worktree === null) return;
          branch = worktree.refName;
          yield* orchestrationEngine.dispatch({
            type: "thread.meta.update",
            commandId: yield* serverCommandId("meta"),
            threadId,
            branch: worktree.refName,
            worktreePath: worktree.path,
          });
          yield* vcsStatusBroadcaster
            .refreshStatus(worktree.path)
            .pipe(Effect.ignoreCause({ log: true }), Effect.forkDetach);
          yield* projectSetupScriptRunner
            .runForThread({
              threadId,
              projectId: project.id,
              projectCwd: project.workspaceRoot,
              worktreePath: worktree.path,
            })
            .pipe(
              Effect.catchCause((cause) =>
                Effect.logWarning("infinitus.slack.setup-script-failed", { threadId, cause }),
              ),
            );
        }
        yield* bind({
          channel: event.channel,
          threadTs: event.threadTs,
          threadId,
          projectId: project.id,
          runtimeMode: mention.runtimeMode,
          createdAt,
        });
        yield* orchestrationEngine.dispatch({
          type: "thread.turn.start",
          commandId: yield* serverCommandId("start"),
          threadId,
          message: {
            messageId: MessageId.make(yield* crypto.randomUUIDv4),
            role: "user",
            text: mention.task,
            attachments: [],
          },
          runtimeMode: mention.runtimeMode,
          interactionMode: "default",
          createdAt,
        });
        liveThreads.add(threadId);
        yield* Effect.logInfo("infinitus.slack.started", {
          threadId,
          projectId: project.id,
          runtimeMode: mention.runtimeMode,
          textLength: mention.task.length,
        });
        yield* post({
          channel: event.channel,
          threadTs: event.threadTs,
          text: `Started in ${project.title}${branch === null ? "" : ` on ${branch}`} (${mention.runtimeMode === "auto-accept-edits" ? "build" : "approval required"}).`,
        });
      });

    const runningTurn = (shell: OrchestrationThreadShell | undefined): boolean =>
      shell?.session?.activeTurnId != null ||
      shell?.session?.status === "running" ||
      shell?.session?.status === "starting";

    const handleReply = (
      binding: SlackThreadBinding,
      event: Extract<SlackInbound, { kind: "reply" }>,
    ) =>
      Effect.gen(function* () {
        const command = replyCommand(event.text);
        if (command === null) return;
        liveThreads.add(binding.threadId);
        const shell = Option.getOrUndefined(yield* shellOf(binding.threadId));
        if (shell === undefined || shell.archivedAt !== null) {
          return yield* postTo(binding, "That thread is gone.");
        }
        const createdAt = yield* now;
        switch (command.kind) {
          case "stop":
            yield* orchestrationEngine.dispatch({
              type: "thread.turn.interrupt",
              commandId: yield* serverCommandId("stop"),
              threadId: binding.threadId,
              createdAt,
            });
            return;
          case "babysit":
            yield* orchestrationEngine.dispatch({
              type: "thread.meta.update",
              commandId: yield* serverCommandId("babysit"),
              threadId: binding.threadId,
              babysit: true,
            });
            return yield* postTo(binding, "Babysitting the PR.");
          case "message": {
            const message = {
              messageId: MessageId.make(yield* crypto.randomUUIDv4),
              role: "user" as const,
              text: command.text,
              attachments: [],
            };
            if (runningTurn(shell)) {
              yield* orchestrationEngine.dispatch({
                type: "thread.turn.queue",
                commandId: yield* serverCommandId("queue"),
                threadId: binding.threadId,
                queueId: QueueId.make(yield* crypto.randomUUIDv4),
                message,
                createdAt,
              });
              return yield* postTo(binding, "Queued for after this turn.");
            }
            yield* orchestrationEngine.dispatch({
              type: "thread.turn.start",
              commandId: yield* serverCommandId("send"),
              threadId: binding.threadId,
              message,
              runtimeMode: binding.runtimeMode,
              interactionMode: "default",
              createdAt,
            });
            return;
          }
        }
      });

    const handleAction = (event: Extract<SlackInbound, { kind: "action" }>) =>
      Effect.gen(function* () {
        const action = parseAction(event.actionId, event.value);
        if (action === null || !byThread.has(action.threadId)) return;
        const createdAt = yield* now;
        if (action.kind === "approval") {
          yield* orchestrationEngine.dispatch({
            type: "thread.approval.respond",
            commandId: yield* serverCommandId("approve"),
            threadId: action.threadId,
            requestId: action.requestId,
            decision: action.decision,
            createdAt,
          });
          return;
        }
        yield* orchestrationEngine.dispatch({
          type: "thread.user-input.respond",
          commandId: yield* serverCommandId("answer"),
          threadId: action.threadId,
          requestId: action.requestId,
          answers: { [action.questionId]: action.answer },
          createdAt,
        });
      });

    const handleInbound = (event: SlackInbound) =>
      Effect.gen(function* () {
        // Socket Mode redelivers an envelope it saw no ack for, and a threaded
        // mention arrives twice (`app_mention` and its `message` twin): both drop.
        const keys =
          event.kind === "action"
            ? [event.envelopeId]
            : [event.envelopeId, `${event.channel}:${event.ts}`];
        if (keys.some((key) => seenEnvelopes.has(key))) return;
        for (const key of keys) {
          seenEnvelopes.add(key);
          if (seenEnvelopes.size > 2000) seenEnvelopes.delete(seenEnvelopes.values().next().value!);
        }
        const { armed, allowed, defaultModelSelection } = yield* gate;
        if (!armed) return;
        if (!allowed.has(event.userId)) {
          return yield* Effect.logInfo("infinitus.slack.ignored", { userId: event.userId });
        }
        switch (event.kind) {
          case "mention": {
            const existing = bySlack.get(slackThreadKey(event.channel, event.threadTs));
            if (existing !== undefined)
              return yield* handleReply(existing, { ...event, kind: "reply" });
            return yield* startThread(event, defaultModelSelection);
          }
          case "reply": {
            const binding = bySlack.get(slackThreadKey(event.channel, event.threadTs));
            if (binding === undefined) return;
            return yield* handleReply(binding, event);
          }
          case "action":
            return yield* handleAction(event);
        }
      }).pipe(
        Effect.catchCause((cause) =>
          Effect.logWarning("infinitus.slack.inbound-failed", { cause }),
        ),
      );

    const handleRuntimeEvent = (event: ProviderRuntimeEvent) =>
      Effect.gen(function* () {
        if (event.type !== "request.opened" && event.type !== "user-input.requested") return;
        const binding = byThread.get(event.threadId);
        if (binding === undefined || !event.requestId) return;
        if (!oncePer(binding.threadId, `request:${event.requestId}`)) return;
        const requestId = ApprovalRequestId.make(event.requestId);
        const message =
          event.type === "request.opened"
            ? approvalMessage({
                threadId: binding.threadId,
                requestId,
                requestType: event.payload.requestType,
                detail: event.payload.detail,
              })
            : questionMessage({
                threadId: binding.threadId,
                requestId,
                questions: event.payload.questions,
              });
        yield* postTo(binding, message.text, message.blocks);
      }).pipe(
        Effect.catchCause((cause) => Effect.logWarning("infinitus.slack.event-failed", { cause })),
      );

    const handleDomainEvent = (event: OrchestrationEvent) =>
      Effect.gen(function* () {
        switch (event.type) {
          case "thread.deleted":
          case "thread.archived":
            return yield* unbind(event.payload.threadId);
          case "thread.pull-request-synced": {
            const binding = byThread.get(event.payload.threadId);
            if (binding === undefined) return;
            const state = event.payload.snapshot.state;
            if (state !== "open" && state !== "merged") return;
            const number = event.payload.number;
            if (!oncePer(binding.threadId, `pr:${number}:${state}`)) return;
            const shell = Option.getOrUndefined(yield* shellOf(binding.threadId));
            const url =
              shell?.pullRequests.find((link) => link.number === number)?.url ?? `#${number}`;
            return yield* postTo(
              binding,
              state === "open" ? `PR opened: ${url}` : `PR merged: ${url}`,
            );
          }
          case "thread.activity-appended": {
            const binding = byThread.get(event.payload.threadId);
            if (binding === undefined) return;
            const line = activityLine(event.payload.activity.kind);
            if (line === null) return;
            return yield* postTo(binding, line);
          }
          case "thread.session-set": {
            const binding = byThread.get(event.payload.threadId);
            if (binding === undefined || event.payload.session.activeTurnId !== null) return;
            const shell = Option.getOrUndefined(yield* shellOf(binding.threadId));
            const turn = shell?.latestTurn;
            if (!turn || (turn.state !== "completed" && turn.state !== "error")) return;
            if (!oncePer(binding.threadId, `turn:${turn.turnId}`)) return;
            const detail = Option.getOrUndefined(
              yield* projectionSnapshotQuery
                .getThreadDetailById(binding.threadId)
                .pipe(Effect.option, Effect.map(Option.flatten)),
            );
            const assistantText =
              detail?.messages.find((message) => message.id === turn.assistantMessageId)?.text ??
              null;
            const pullRequestUrl = shell?.pullRequests[0]?.url ?? null;
            return yield* postTo(
              binding,
              doneText({ state: turn.state, assistantText, pullRequestUrl }),
            );
          }
          default:
            return;
        }
      }).pipe(
        Effect.catchCause((cause) => Effect.logWarning("infinitus.slack.event-failed", { cause })),
      );

    // A clean shutdown tells the threads this process was driving; a crash
    // or a closed lid cannot (Socket Mode queues nothing), see the issue.
    // Bounded: a slow Slack must not hold the server's exit.
    yield* Effect.addFinalizer(() =>
      Effect.forEach(
        [...liveThreads],
        (threadId) => {
          const binding = byThread.get(threadId);
          return binding === undefined ? Effect.void : postTo(binding, OFFLINE_TEXT);
        },
        { discard: true },
      ).pipe(Effect.timeout(Duration.seconds(5)), Effect.ignore),
    );

    // Subscribe first so nothing published while the file loads is missed;
    // each handler waits for the load before it reads the maps.
    const loaded = yield* Deferred.make<void>();
    const afterLoad = <A, E, R>(effect: Effect.Effect<A, E, R>) =>
      Deferred.await(loaded).pipe(Effect.andThen(effect));
    yield* forkParked(
      Effect.gen(function* () {
        yield* Effect.forkScoped(
          slack.inbound.pipe(Stream.runForEach((event) => afterLoad(handleInbound(event)))),
        );
        yield* Effect.forkScoped(
          providerService.streamEvents.pipe(
            Stream.runForEach((event) => afterLoad(handleRuntimeEvent(event))),
          ),
        );
        yield* Effect.forkScoped(
          orchestrationEngine.streamDomainEvents.pipe(
            Stream.runForEach((event) => afterLoad(handleDomainEvent(event))),
          ),
        );
        yield* loadBindings;
        yield* Deferred.succeed(loaded, undefined);
      }),
    );
  }),
);
