import {
  AuthOrchestrationOperateScope,
  CommandId,
  EnvironmentId,
  MessageId,
  ProjectId,
  ProviderInstanceId,
  ThreadId,
} from "@infinitus/contracts";
import * as Cause from "effect/Cause";
import { AsyncResult, type Atom } from "effect/reactivity";
import { afterEach, beforeEach, describe, expect, it, vi } from "vite-plus/test";
import type { QueuedThreadMessage } from "./thread-outbox-model";

const state = vi.hoisted(() => ({
  grantedEnvironments: new Set<string>(),
  draftText: "Keep this draft separate",
  cleanups: [] as Array<() => void>,
  start: vi.fn(),
  metadata: vi.fn(),
  runtime: vi.fn(),
  interaction: vi.fn(),
  prepare: vi.fn(),
  storageRemove: vi.fn(async (_message: QueuedThreadMessage) => {}),
  checkout: vi.fn(),
  manager: null as unknown as ReturnType<
    typeof import("./thread-outbox-manager").createThreadOutboxManager
  >,
  thread: {
    environmentId: "secondary",
    id: "thread",
    modelSelection: { instanceId: "codex", model: "gpt-5.4" },
    runtimeMode: "full-access",
    interactionMode: "default",
    session: null,
  },
  config: {
    providers: [{ instanceId: "codex", driver: "codex" }],
    environment: { capabilities: {} },
  },
}));
vi.mock("react", () => ({
  useCallback: <A>(callback: A) => callback,
  useEffect: (effect: () => void | (() => void)) => {
    const cleanup = effect();
    if (cleanup) state.cleanups.push(cleanup);
  },
  useRef: <A>(value: A) => ({ current: value }),
  useState: <A>(initial: A) => [initial, vi.fn()],
}));
vi.mock("react-native", () => ({ Alert: { alert: vi.fn() } }));
vi.mock("@effect/atom-react", async () => {
  const { appAtomRegistry } = await import("./atom-registry");
  return { useAtomValue: <A>(atom: Atom.Atom<A>) => appAtomRegistry.get(atom) };
});
vi.mock("./session", () => ({
  readEnvironmentScope: (environmentId: string, scope: string) =>
    scope === AuthOrchestrationOperateScope && state.grantedEnvironments.has(environmentId),
  useEnvironmentsWithScope: () => state.grantedEnvironments,
}));
vi.mock("./entities", () => ({
  useProjects: () => [],
  useThreadShells: () => [state.thread],
  useServerConfigs: () => new Map([["secondary", state.config]]),
}));
vi.mock("./server", async () => {
  const { Atom } = await import("effect/reactivity");
  return {
    serverEnvironment: { configValueAtom: Atom.family((_id: string) => Atom.make(state.config)) },
  };
});
vi.mock("./threads", async () => {
  const { Atom } = await import("effect/reactivity");
  return {
    threadEnvironment: {
      startTurn: state.start,
      updateMetadata: state.metadata,
      setRuntimeMode: state.runtime,
      setInteractionMode: state.interaction,
    },
    environmentThreadShells: { threadShellsAtom: Atom.make([state.thread]) },
  };
});
vi.mock("./use-atom-command", () => ({ useAtomCommand: <A>(command: A) => command }));
vi.mock("./git", () => ({ gitEnvironment: { preparePullRequestThread: state.checkout } }));
vi.mock("../lib/modelOptions", () => ({ isModelSelectionUnavailable: () => false }));
vi.mock("../lib/uuid", () => ({ uuidv4: () => "uuid", randomHex: () => "abcd" }));
vi.mock("../lib/attachmentUpload", () => ({ prepareTurnAttachments: state.prepare }));
// Infinitus (fork, #742): the drain pins a created thread; its hook reaches
// preferences storage, which loads `expo` and needs a React Native global.
vi.mock("../features/infinitus/pinAtCreation", () => ({
  usePinAtCreation: () => async () => undefined,
}));
vi.mock("./use-remote-environment-registry", () => ({
  setPendingConnectionError: vi.fn(),
  useRemoteConnectionStatus: () => ({
    connectedEnvironments: [{ environmentId: "secondary", connectionState: "connected" }],
  }),
}));
vi.mock("./thread-outbox", async () => {
  const { createThreadOutboxManager } = await import("./thread-outbox-manager");
  const { appAtomRegistry } = await import("./atom-registry");
  state.manager = createThreadOutboxManager({
    registry: appAtomRegistry,
    storage: {
      load: async () => ({ messages: [], errors: [] }),
      write: async () => {},
      remove: (message) => state.storageRemove(message),
    },
  });
  return {
    threadOutboxManager: state.manager,
    threadOutboxRevision: (id: MessageId) => state.manager.revisionOf(id),
    confirmThreadOutboxMessageQueued: (message: QueuedThreadMessage) =>
      state.manager.confirmQueued(message),
    updateThreadOutboxMessage: (message: QueuedThreadMessage, revision?: number) =>
      state.manager.update(message, revision),
  };
});
vi.mock("./thread-outbox-removal", () => ({
  removeThreadOutboxMessage: (message: QueuedThreadMessage, revision?: number) =>
    state.manager.remove(message, revision),
}));
vi.mock("./use-thread-outbox", async () => {
  const { Atom } = await import("effect/reactivity");
  const { appAtomRegistry } = await import("./atom-registry");
  await import("./thread-outbox");
  const editingQueuedMessageIdsAtom = Atom.make<Record<string, boolean>>({}).pipe(Atom.keepAlive);
  return {
    editingQueuedMessageIdsAtom,
    holdEditingQueuedMessage: (messageId: string) => {
      appAtomRegistry.set(editingQueuedMessageIdsAtom, {
        ...appAtomRegistry.get(editingQueuedMessageIdsAtom),
        [messageId]: true,
      });
    },
    releaseEditingQueuedMessage: (messageId: string) => {
      const { [messageId]: _released, ...rest } = appAtomRegistry.get(editingQueuedMessageIdsAtom);
      appAtomRegistry.set(editingQueuedMessageIdsAtom, rest);
    },
    useThreadOutboxMessages: () => appAtomRegistry.get(state.manager.queuedMessagesByThreadKeyAtom),
    useThreadOutboxShellStatuses: () => new Map([["secondary", "live"]]),
  };
});
vi.mock("./use-composer-drafts", async () => {
  const { Atom } = await import("effect/reactivity");
  return {
    composerDraftsAtom: Atom.make({}),
    removeDeliveredCloudQueuedMessage: async () => {},
    appendComposerDraftAttachments: vi.fn(),
    flushComposerDrafts: vi.fn(),
    getComposerDraftSnapshot: vi.fn(() => ({ text: state.draftText, attachments: [] })),
    mergeComposerDraftContent: vi.fn(async (_key: string, input: { text: string }) => {
      state.draftText += `\n${input.text}`;
    }),
    replaceComposerDraftAttachments: vi.fn(),
    undoComposerDraftMerge: vi.fn(),
    updateComposerDraftSettings: vi.fn(),
    waitForComposerDraftsLoaded: vi.fn(),
  };
});

import { appAtomRegistry } from "./atom-registry";
import { deletePendingThreadMessage } from "./delete-pending-thread-message";
import { dispatchingQueuedMessageAtom } from "./queued-message-dispatch";
import { useThreadOutboxDrain } from "./use-thread-outbox-drain";

const message = (overrides: Partial<QueuedThreadMessage> = {}): QueuedThreadMessage => ({
  environmentId: EnvironmentId.make("secondary"),
  threadId: ThreadId.make("thread"),
  commandId: CommandId.make("command"),
  messageId: MessageId.make("message"),
  text: "Keep this queued",
  attachments: [],
  createdAt: "2026-09-05T00:00:00.000Z",
  ...overrides,
});
const remaining = () =>
  Object.values(appAtomRegistry.get(state.manager.queuedMessagesByThreadKeyAtom)).flat();

function runDrain() {
  const settled = Promise.withResolvers<void>();
  const release = appAtomRegistry.subscribe(dispatchingQueuedMessageAtom, (dispatching) => {
    if (dispatching === null) settled.resolve();
  });
  useThreadOutboxDrain();
  return settled.promise.finally(release);
}

beforeEach(() => {
  state.grantedEnvironments = new Set(["primary"]);
  state.draftText = "Keep this draft separate";
  appAtomRegistry.set(state.manager.queuedMessagesByThreadKeyAtom, {});
  appAtomRegistry.set(dispatchingQueuedMessageAtom, null);
  for (const command of [
    state.start,
    state.metadata,
    state.runtime,
    state.interaction,
    state.checkout,
  ]) {
    command.mockReset().mockResolvedValue(AsyncResult.success(undefined));
  }
  state.prepare.mockReset().mockImplementation(async ({ attachments }) => ({
    status: "ready",
    attachments: [],
    draftAttachments: attachments,
    pendingAttachmentIds: [],
  }));
  state.storageRemove.mockReset().mockResolvedValue(undefined);
});

describe("queued PR checkout", () => {
  const queuedPullRequest = () =>
    message({
      threadId: ThreadId.make("new-pr-thread"),
      modelSelection: { instanceId: ProviderInstanceId.make("codex"), model: "gpt-5.4" },
      creation: {
        projectId: ProjectId.make("project"),
        projectCwd: "/repo",
        workspaceMode: "worktree",
        branch: "fork/feature",
        worktreePath: null,
        pullRequestReference: "https://github.com/acme/repo/pull/123",
      },
    });
  const preparedCheckout = {
    branch: "pr-123",
    worktreePath: "/repo/.t3/worktrees/pr-123",
    isOnPullRequestHead: true,
  };

  it("waits for the provider's PR checkout and launches in that worktree", async () => {
    state.grantedEnvironments.add("secondary");
    await state.manager.enqueue(queuedPullRequest());
    const started = Promise.withResolvers<void>();
    const checkout =
      Promise.withResolvers<AsyncResult.AsyncResult<typeof preparedCheckout, Error>>();
    state.checkout.mockImplementationOnce(() => {
      started.resolve();
      return checkout.promise;
    });
    const drained = runDrain();
    await started.promise;
    expect(state.start).not.toHaveBeenCalled();
    expect(state.checkout).toHaveBeenCalledWith({
      environmentId: "secondary",
      input: { cwd: "/repo", reference: "https://github.com/acme/repo/pull/123", mode: "worktree" },
    });
    checkout.resolve(AsyncResult.success(preparedCheckout));
    await drained;
    expect(state.start).toHaveBeenCalledOnce();
    const bootstrap = state.start.mock.calls[0]?.[0].input.bootstrap;
    expect(bootstrap.createThread).toMatchObject({
      branch: "pr-123",
      worktreePath: preparedCheckout.worktreePath,
    });
    expect(bootstrap.prepareWorktree).toBeUndefined();
    expect(remaining()).toEqual([]);
  });

  it("keeps the PR source queued on a transport failure without starting the agent", async () => {
    state.grantedEnvironments.add("secondary");
    const queued = queuedPullRequest();
    await state.manager.enqueue(queued);
    state.checkout.mockResolvedValueOnce(
      AsyncResult.failure(Cause.fail(new Error("Socket is not connected"))),
    );
    await runDrain();
    expect(state.start).not.toHaveBeenCalled();
    expect(remaining()).toEqual([queued]);
  });

  it("restores the PR draft when the reused worktree cannot reach the PR head", async () => {
    state.grantedEnvironments.add("secondary");
    await state.manager.enqueue(queuedPullRequest());
    state.checkout.mockResolvedValueOnce(
      AsyncResult.success({ ...preparedCheckout, isOnPullRequestHead: false }),
    );
    await runDrain();
    expect(state.start).not.toHaveBeenCalled();
    expect(remaining()).toEqual([]);
    const { updateComposerDraftSettings } = await import("./use-composer-drafts");
    expect(updateComposerDraftSettings).toHaveBeenCalledWith(
      expect.any(String),
      expect.objectContaining({
        workspaceSelection: expect.objectContaining({
          pullRequestReference: queuedPullRequest().creation?.pullRequestReference,
        }),
      }),
    );
  });

  it("stops launch if operation access is revoked while checking out the PR", async () => {
    state.grantedEnvironments.add("secondary");
    const queued = queuedPullRequest();
    await state.manager.enqueue(queued);
    state.checkout.mockImplementationOnce(async () => {
      state.grantedEnvironments.delete("secondary");
      return AsyncResult.success(preparedCheckout);
    });
    await runDrain();
    expect(state.start).not.toHaveBeenCalled();
    expect(remaining()).toEqual([queued]);
  });

  it("does not launch a stale task edited while the PR checkout was running", async () => {
    state.grantedEnvironments.add("secondary");
    const queued = queuedPullRequest();
    await state.manager.enqueue(queued);
    const edited = { ...queued, text: "Updated instructions" };
    state.checkout.mockImplementationOnce(async () => {
      await state.manager.update(edited);
      return AsyncResult.success(preparedCheckout);
    });
    await runDrain();
    expect(state.start).not.toHaveBeenCalled();
    expect(remaining()).toEqual([edited]);
  });
});
afterEach(() => {
  state.cleanups.splice(0).forEach((cleanup) => cleanup());
});

describe("queued task operation access", () => {
  it("parks a connected read-only target, then delivers its unchanged queue after a grant", async () => {
    const queued = message();
    await state.manager.enqueue(queued);
    useThreadOutboxDrain();
    expect(state.start).not.toHaveBeenCalled();
    expect(state.prepare).not.toHaveBeenCalled();
    expect(remaining()).toEqual([queued]);
    state.grantedEnvironments.add("secondary");
    await runDrain();
    expect(state.start).toHaveBeenCalledOnce();
    expect(remaining()).toEqual([]);
  });

  it("stops the remaining settings and turn commands when an earlier update loses access", async () => {
    state.grantedEnvironments.add("secondary");
    const queued = message({
      modelSelection: { instanceId: ProviderInstanceId.make("codex"), model: "different-model" },
      runtimeMode: "approval-required",
      interactionMode: "plan",
    });
    await state.manager.enqueue(queued);
    state.runtime.mockImplementationOnce(async () => {
      state.grantedEnvironments.delete("secondary");
      return AsyncResult.success(undefined);
    });
    await runDrain();
    expect(state.runtime).toHaveBeenCalledOnce();
    expect(state.interaction).not.toHaveBeenCalled();
    expect(state.prepare).not.toHaveBeenCalled();
    expect(state.start).not.toHaveBeenCalled();
    expect(remaining()).toEqual([queued]);
  });

  it.each([
    { isCreation: false, accepted: false },
    { isCreation: true, accepted: false },
    { isCreation: false, accepted: true },
    { isCreation: true, accepted: true },
  ])(
    "preserves a rejected queue but removes an accepted turn after access loss (new task: $isCreation, accepted: $accepted)",
    async ({ isCreation, accepted }) => {
      state.grantedEnvironments.add("secondary");
      const queued = message(
        isCreation
          ? {
              threadId: ThreadId.make("new-thread"),
              modelSelection: { instanceId: ProviderInstanceId.make("codex"), model: "gpt-5.4" },
              creation: {
                projectId: ProjectId.make("project"),
                projectCwd: "/repo",
                workspaceMode: "local",
                branch: null,
                worktreePath: null,
              },
            }
          : {},
      );
      await state.manager.enqueue(queued);
      const started = Promise.withResolvers<void>();
      const delivery = Promise.withResolvers<AsyncResult.AsyncResult<void, Error>>();
      state.start.mockImplementationOnce(() => {
        started.resolve();
        return delivery.promise;
      });
      const drained = runDrain();
      await started.promise;
      state.grantedEnvironments.delete("secondary");
      delivery.resolve(
        accepted
          ? AsyncResult.success(undefined)
          : AsyncResult.failure(Cause.fail(new Error("This connection cannot control this task."))),
      );
      await drained;

      expect(remaining()).toEqual(accepted ? [] : [queued]);
      expect(state.draftText).toBe("Keep this draft separate");
      if (!accepted) {
        state.grantedEnvironments.add("secondary");
        await runDrain();
        expect(state.start).toHaveBeenCalledTimes(2);
        expect(remaining()).toEqual([]);
        expect(state.draftText).toBe("Keep this draft separate");
      }
    },
  );

  it.each([
    { isCreation: false, uploadFails: false },
    { isCreation: true, uploadFails: false },
    { isCreation: false, uploadFails: true },
    { isCreation: true, uploadFails: true },
  ])(
    "keeps the message queued after upload revocation (new task: $isCreation, upload fails: $uploadFails)",
    async ({ isCreation, uploadFails }) => {
      state.grantedEnvironments.add("secondary");
      const queued = message(
        isCreation
          ? {
              threadId: ThreadId.make("new-thread"),
              modelSelection: { instanceId: ProviderInstanceId.make("codex"), model: "gpt-5.4" },
              creation: {
                projectId: ProjectId.make("project"),
                projectCwd: "/repo",
                workspaceMode: "local",
                branch: null,
                worktreePath: null,
              },
            }
          : {},
      );
      await state.manager.enqueue(queued);
      state.prepare.mockImplementationOnce(async ({ attachments }) => {
        state.grantedEnvironments.delete("secondary");
        if (uploadFails) throw new Error("This connection cannot upload attachments.");
        return {
          status: "ready",
          attachments: [],
          draftAttachments: attachments,
          pendingAttachmentIds: [],
        };
      });
      await runDrain();
      expect(state.prepare).toHaveBeenCalledOnce();
      expect(state.start).not.toHaveBeenCalled();
      expect(remaining()).toEqual([queued]);
    },
  );
});

// Infinitus (fork, #1501): deleting a reply mid-upload abandons that attempt
// and the drain moves on to the next queued message.
describe("deleting a queued reply while it uploads", () => {
  it("abandons the upload and sends the next queued message", async () => {
    state.grantedEnvironments.add("secondary");
    const stuck = message({ messageId: MessageId.make("stuck"), text: "stuck upload" });
    const next = message({ messageId: MessageId.make("next"), text: "goes next" });
    await state.manager.enqueue(stuck);
    await state.manager.enqueue(next);
    const uploadStarted = Promise.withResolvers<void>();
    state.prepare.mockImplementationOnce(async ({ signal }) => {
      uploadStarted.resolve();
      await new Promise<void>((resolve) => {
        signal?.addEventListener("abort", () => resolve(), { once: true });
      });
      return { status: "abandoned" };
    });

    const drained = runDrain();
    await uploadStarted.promise;
    await expect(deletePendingThreadMessage(stuck)).resolves.toBe(true);
    await drained;
    expect(state.start).not.toHaveBeenCalled();
    expect(remaining()).toEqual([next]);

    await runDrain();
    expect(state.start).toHaveBeenCalledOnce();
    expect(state.start.mock.calls[0]?.[0]).toMatchObject({
      input: { message: { messageId: next.messageId } },
    });
    expect(remaining()).toEqual([]);
  });

  it("never re-dispatches a deleted reply whose removal is still being written", async () => {
    state.grantedEnvironments.add("secondary");
    const deleted = message({ messageId: MessageId.make("deleted"), text: "no attachments" });
    const next = message({ messageId: MessageId.make("next"), text: "goes next" });
    await state.manager.enqueue(deleted);
    await state.manager.enqueue(next);
    // The drain is mid-flight: past the pick, before startTurn.
    const dispatchReached = Promise.withResolvers<void>();
    const dispatchBarrier = Promise.withResolvers<void>();
    state.prepare.mockImplementationOnce(async ({ attachments }) => {
      dispatchReached.resolve();
      await dispatchBarrier.promise;
      return {
        status: "ready",
        attachments: [],
        draftAttachments: attachments,
        pendingAttachmentIds: [],
      };
    });
    const removalBarrier = Promise.withResolvers<void>();
    state.storageRemove.mockImplementationOnce(() => removalBarrier.promise);

    const drained = runDrain();
    await dispatchReached.promise;
    const deletion = deletePendingThreadMessage(deleted);
    dispatchBarrier.resolve();
    await drained;
    // The abandoned attempt released the drain while the row still sits at
    // the head of the queue; this pass must leave it alone.
    expect(remaining()).toEqual([deleted, next]);
    useThreadOutboxDrain();
    expect(state.start).not.toHaveBeenCalled();

    removalBarrier.resolve();
    await expect(deletion).resolves.toBe(true);
    expect(remaining()).toEqual([next]);
    await runDrain();
    expect(state.start).toHaveBeenCalledOnce();
    expect(state.start.mock.calls[0]?.[0]).toMatchObject({
      input: { message: { messageId: next.messageId } },
    });
    expect(remaining()).toEqual([]);
  });
});
