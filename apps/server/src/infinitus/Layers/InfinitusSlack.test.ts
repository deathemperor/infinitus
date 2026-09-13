import {
  DEFAULT_SERVER_SETTINGS,
  GitCommandError,
  ThreadId,
  type OrchestrationCommand,
  type OrchestrationEvent,
  type OrchestrationProjectShell,
  type OrchestrationThreadShell,
  type ProviderRuntimeEvent,
  type ServerSettings,
} from "@t3tools/contracts";
import { it as effectIt } from "@effect/vitest";
import * as Crypto from "effect/Crypto";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";
import * as Path from "effect/Path";
import * as PubSub from "effect/PubSub";
import * as Ref from "effect/Ref";
import * as Stream from "effect/Stream";
import { describe, expect } from "vite-plus/test";

import { ServerConfig } from "../../config.ts";
import { GitWorkflowService } from "../../git/GitWorkflowService.ts";
import { OrchestrationEngineService } from "../../orchestration/Services/OrchestrationEngine.ts";
import { ProjectionSnapshotQuery } from "../../orchestration/Services/ProjectionSnapshotQuery.ts";
import { ProjectSetupScriptRunner } from "../../project/ProjectSetupScriptRunner.ts";
import { ProviderService } from "../../provider/Services/ProviderService.ts";
import { ServerSettingsService } from "../../serverSettings.ts";
import { VcsStatusBroadcaster } from "../../vcs/VcsStatusBroadcaster.ts";
import {
  SlackClient,
  type SlackInbound,
  type SlackPost,
} from "../Services/InfinitusSlackClient.ts";
import { InfinitusSlackLive } from "./InfinitusSlack.ts";

const model = {
  instanceId: "claude",
  model: "claude-sonnet-5",
} as unknown as ServerSettings["defaultModelSelection"];
const project = {
  id: "p1",
  title: "Limitless",
  workspaceRoot: "/w/limitless",
  defaultModelSelection: null,
} as unknown as OrchestrationProjectShell;

const armed: ServerSettings = {
  ...DEFAULT_SERVER_SETTINGS,
  defaultModelSelection: model,
  infinitusSlack: { enabled: true, allowedUserIds: ["U1"], appToken: "a", botToken: "b" },
};

let uuidCounter = 0;
const testCrypto = Crypto.make({
  randomBytes: (size) => {
    uuidCounter += 1;
    return new Uint8Array(size).fill(uuidCounter % 256);
  },
  digest: (_algorithm, data) => Effect.succeed(data),
});

const reply = (text: string, ts = `r.${++uuidCounter}`): SlackInbound => ({
  kind: "reply",
  envelopeId: `env-${++uuidCounter}`,
  channel: "C1",
  threadTs: "1.1",
  ts,
  userId: "U1",
  text,
});
const mention = (text: string, userId = "U1", ts = `m.${++uuidCounter}`): SlackInbound => ({
  kind: "mention",
  envelopeId: `env-${++uuidCounter}`,
  channel: "C1",
  threadTs: "1.1",
  ts,
  userId,
  text,
});

/** An in-memory FileSystem: every call answers at once, so the yield loop settles it. */
const memoryFs = (files: Map<string, string>) =>
  FileSystem.layerNoop({
    exists: (file) => Effect.succeed(files.has(file)),
    readFileString: (file) => Effect.succeed(files.get(file) ?? ""),
    writeFileString: (file, contents) => Effect.sync(() => void files.set(file, contents)),
    makeDirectory: () => Effect.void,
    makeTempDirectory: () => Effect.succeed("/mem/tmp"),
    makeTempDirectoryScoped: () => Effect.succeed("/mem/tmp"),
    rename: (from, to) =>
      Effect.sync(() => {
        files.set(to, files.get(from) ?? "");
        files.delete(from);
      }),
    remove: () => Effect.void,
  });

interface GitFixture {
  /** The checkout's branch; null is a detached HEAD, undefined no repo. */
  readonly refName?: string | null;
  readonly worktreeHolders?: number;
  readonly createWorktreeFails?: boolean;
}

const makeHarness = (settings: ServerSettings, files: Map<string, string>, git: GitFixture = {}) =>
  Effect.gen(function* () {
    const inbound = yield* PubSub.unbounded<SlackInbound>();
    const runtime = yield* PubSub.unbounded<ProviderRuntimeEvent>();
    const domain = yield* PubSub.unbounded<OrchestrationEvent>();
    const dispatched = yield* Ref.make<ReadonlyArray<OrchestrationCommand>>([]);
    const posts = yield* Ref.make<ReadonlyArray<SlackPost>>([]);
    const shells = yield* Ref.make<ReadonlyMap<ThreadId, OrchestrationThreadShell>>(new Map());
    const layer = InfinitusSlackLive.pipe(
      Layer.provide(
        Layer.mergeAll(
          Layer.mock(OrchestrationEngineService)({
            dispatch: (command) =>
              Ref.update(dispatched, (previous) => [...previous, command]).pipe(
                Effect.as({ sequence: 1 }),
              ),
            get streamDomainEvents() {
              return Stream.fromPubSub(domain);
            },
          }),
          Layer.mock(ProjectionSnapshotQuery)({
            getShellSnapshot: () =>
              Effect.succeed({
                snapshotSequence: 1,
                projects: [project],
                threads: [],
                updatedAt: "",
              } as never),
            getThreadShellById: (threadId) =>
              Ref.get(shells).pipe(Effect.map((map) => Option.fromNullishOr(map.get(threadId)))),
            getWorktreeHolders: () =>
              Effect.succeed({ count: git.worktreeHolders ?? 0, oldestArchived: [] }),
            getThreadDetailById: (threadId) =>
              Ref.get(shells).pipe(
                Effect.map((map) => {
                  const shell = map.get(threadId);
                  return shell === undefined
                    ? Option.none()
                    : Option.some({
                        ...shell,
                        messages: [{ id: "m-a", role: "assistant", text: "All green." }],
                      } as never);
                }),
              ),
          }),
          Layer.mock(ProviderService)({
            get streamEvents() {
              return Stream.fromPubSub(runtime);
            },
          }),
          Layer.mock(ServerSettingsService)({ getSettings: Effect.succeed(settings) }),
          Layer.mock(GitWorkflowService)({
            remoteExists: () => Effect.succeed(false),
            createWorktree: (input) =>
              git.createWorktreeFails === true
                ? Effect.fail(
                    new GitCommandError({
                      operation: "worktree",
                      command: "git worktree add",
                      cwd: input.cwd,
                      detail: "fatal: not a git repository",
                    }),
                  )
                : Effect.succeed({
                    worktree: { path: `${input.cwd}-wt`, refName: input.newRefName },
                  } as never),
          }),
          Layer.mock(VcsStatusBroadcaster)({
            getStatus: () =>
              Effect.succeed({
                isRepo: git.refName !== undefined,
                refName: git.refName ?? null,
              } as never),
            refreshStatus: () => Effect.succeed({} as never),
          }),
          Layer.mock(ProjectSetupScriptRunner)({
            runForThread: () => Effect.succeed({ status: "no-script" } as never),
          }),
          Layer.succeed(SlackClient)({
            inbound: Stream.fromPubSub(inbound),
            post: (post) =>
              Ref.update(posts, (previous) => [...previous, post]).pipe(Effect.as({ ts: "2.2" })),
          }),
          Layer.succeed(Crypto.Crypto, testCrypto),
          Layer.fresh(ServerConfig.layerTest("/mem", { prefix: "slack-" })).pipe(
            Layer.provide(Layer.mergeAll(memoryFs(files), Path.layer)),
          ),
          memoryFs(files),
          Path.layer,
        ),
      ),
    );
    yield* Layer.build(layer);
    const settle = Effect.gen(function* () {
      for (let i = 0; i < 40; i += 1) yield* Effect.yieldNow;
    });
    yield* settle;
    return {
      send: (event: SlackInbound) => PubSub.publish(inbound, event).pipe(Effect.andThen(settle)),
      runtimeEvent: (event: ProviderRuntimeEvent) =>
        PubSub.publish(runtime, event).pipe(Effect.andThen(settle)),
      domainEvent: (event: OrchestrationEvent) =>
        PubSub.publish(domain, event).pipe(Effect.andThen(settle)),
      setShell: (shell: OrchestrationThreadShell) =>
        Ref.update(shells, (map) => new Map(map).set(shell.id, shell)),
      dispatched: Ref.get(dispatched),
      posts: Ref.get(posts),
    };
  });

describe("InfinitusSlack (#574)", () => {
  const worktreeArmed: ServerSettings = {
    ...armed,
    worktreeMaxCount: 1,
    projectSettingsOverrides: { p1: { defaultThreadEnvMode: "worktree" } } as never,
  };

  effectIt.effect(
    "a worktree project gets ws.ts's bootstrap: create, worktree, meta, start (#957)",
    () =>
      Effect.gen(function* () {
        const harness = yield* makeHarness(worktreeArmed, new Map(), { refName: "main" });
        yield* harness.send(mention("<@U0BOT> limitless build fix the flaky test"));
        const commands = yield* harness.dispatched;
        expect(commands.map((command) => command.type)).toEqual([
          "thread.create",
          "thread.meta.update",
          "thread.turn.start",
        ]);
        expect(commands[1]).toMatchObject({
          branch: expect.stringMatching(/^t3code\/[0-9a-f]{8}$/),
          worktreePath: "/w/limitless-wt",
        });
        const posts = yield* harness.posts;
        expect(posts).toHaveLength(1);
        expect(posts[0]!.text).toMatch(/^Started in Limitless on t3code\/[0-9a-f]{8} \(build\)\.$/);
      }),
  );

  effectIt.effect("the worktree limit refuses before anything is created (#957, #269 H)", () =>
    Effect.gen(function* () {
      const harness = yield* makeHarness(worktreeArmed, new Map(), {
        refName: "main",
        worktreeHolders: 1,
      });
      yield* harness.send(mention("<@U0BOT> limitless build fix the flaky test"));
      expect(yield* harness.dispatched).toEqual([]);
      const posts = yield* harness.posts;
      expect(posts).toHaveLength(1);
      expect(posts[0]!.text).toContain("Worktree limit reached: 1 of 1");
    }),
  );

  effectIt.effect("a git failure deletes the created thread and posts the error (#957)", () =>
    Effect.gen(function* () {
      const harness = yield* makeHarness(worktreeArmed, new Map(), {
        refName: "main",
        createWorktreeFails: true,
      });
      yield* harness.send(mention("<@U0BOT> limitless build fix the flaky test"));
      const commands = yield* harness.dispatched;
      expect(commands.map((command) => command.type)).toEqual(["thread.create", "thread.delete"]);
      const posts = yield* harness.posts;
      expect(posts).toHaveLength(1);
      expect(posts[0]!.text).toContain("Could not create a worktree for Limitless");
      // The thread was never bound: a reply in the Slack thread is not a follow-up.
      yield* harness.send(reply("more"));
      expect((yield* harness.dispatched).map((command) => command.type)).toEqual([
        "thread.create",
        "thread.delete",
      ]);
    }),
  );

  effectIt.effect("a detached HEAD or a plain folder keeps the thread on the checkout (#957)", () =>
    Effect.gen(function* () {
      const detached = yield* makeHarness(worktreeArmed, new Map(), { refName: null });
      yield* detached.send(mention("<@U0BOT> limitless build fix the flaky test"));
      expect((yield* detached.dispatched).map((command) => command.type)).toEqual([
        "thread.create",
        "thread.turn.start",
      ]);
      const folder = yield* makeHarness(worktreeArmed, new Map(), {});
      yield* folder.send(mention("<@U0BOT> limitless build fix the flaky test"));
      expect((yield* folder.dispatched).map((command) => command.type)).toEqual([
        "thread.create",
        "thread.turn.start",
      ]);
    }),
  );

  effectIt.effect("an allowed mention creates a thread, starts the turn, binds and posts", () =>
    Effect.gen(function* () {
      const harness = yield* makeHarness(armed, new Map());
      yield* harness.send(mention("<@U0BOT> limitless build fix the flaky test"));
      const commands = yield* harness.dispatched;
      expect(commands.map((command) => command.type)).toEqual([
        "thread.create",
        "thread.turn.start",
      ]);
      const create = commands[0] as Extract<OrchestrationCommand, { type: "thread.create" }>;
      expect(create).toMatchObject({
        projectId: "p1",
        title: "fix the flaky test",
        runtimeMode: "auto-accept-edits",
        interactionMode: "default",
        branch: null,
        worktreePath: null,
      });
      const posts = yield* harness.posts;
      expect(posts).toHaveLength(1);
      expect(posts[0]).toMatchObject({ channel: "C1", threadTs: "1.1" });
      expect(posts[0]!.text).toContain("build");

      // A reply while the turn runs is queued; stop interrupts; babysit turns it on.
      const threadId = create.threadId;
      yield* harness.setShell({
        id: threadId,
        archivedAt: null,
        session: { status: "running", activeTurnId: "turn-1" },
        latestTurn: null,
        pullRequests: [],
      } as unknown as OrchestrationThreadShell);
      yield* harness.send(reply("also add tests"));
      yield* harness.send(reply("stop"));
      yield* harness.send(reply("babysit"));
      // A threaded mention arrives twice (app_mention, then its message twin): one command.
      yield* harness.send(mention("<@U0BOT> and docs", "U1", "9.9"));
      yield* harness.send(reply("<@U0BOT> and docs", "9.9"));
      const later = (yield* harness.dispatched).slice(2);
      expect(later.map((command) => command.type)).toEqual([
        "thread.turn.queue",
        "thread.turn.interrupt",
        "thread.meta.update",
        "thread.turn.queue",
      ]);
      expect(later[2]).toMatchObject({ babysit: true });

      // An approval request posts buttons; the button answers with the request id.
      yield* harness.runtimeEvent({
        type: "request.opened",
        threadId,
        turnId: "turn-1",
        requestId: "req-1",
        payload: { requestType: "command_execution_approval", detail: "pnpm test" },
      } as never);
      const approvalPost = (yield* harness.posts).at(-1)!;
      expect(approvalPost.text).toBe("Approval needed: pnpm test");
      const actions = approvalPost.blocks?.[1] as { elements: Array<{ action_id: string }> };
      yield* harness.send({
        kind: "action",
        envelopeId: "env-act",
        channel: "C1",
        threadTs: "1.1",
        userId: "U1",
        actionId: actions.elements[0]!.action_id,
        value: "accept",
      });
      expect((yield* harness.dispatched).at(-1)).toMatchObject({
        type: "thread.approval.respond",
        requestId: "req-1",
        decision: "accept",
      });

      // The turn finishing posts the last assistant message and the PR once.
      yield* harness.setShell({
        id: threadId,
        archivedAt: null,
        session: { status: "idle", activeTurnId: null },
        latestTurn: { turnId: "turn-1", state: "completed", assistantMessageId: "m-a" },
        pullRequests: [{ url: "https://x/pr/9", number: 9, snapshot: null }],
      } as unknown as OrchestrationThreadShell);
      const sessionSet = {
        type: "thread.session-set",
        payload: { threadId, session: { status: "idle", activeTurnId: null } },
      } as never;
      yield* harness.domainEvent(sessionSet);
      yield* harness.domainEvent(sessionSet);
      const done = (yield* harness.posts).filter((post) => post.text.startsWith("Done."));
      expect(done).toHaveLength(1);
      expect(done[0]!.text).toBe("Done.\nAll green.\nPR: https://x/pr/9");

      // A limit row posts the fixed line, never the summary.
      yield* harness.domainEvent({
        type: "thread.activity-appended",
        payload: {
          threadId,
          activity: {
            kind: "infinitus.thread.limited",
            summary: "Limit hit on someone@example.com",
          },
        },
      } as never);
      const limited = (yield* harness.posts).at(-1)!.text;
      expect(limited).toContain("usage limit");
      expect(limited).not.toContain("example.com");
    }),
  );

  effectIt.effect("outsiders, an unknown project and a disabled bridge start nothing", () =>
    Effect.gen(function* () {
      const harness = yield* makeHarness(armed, new Map());
      yield* harness.send(mention("<@U0BOT> limitless do it", "U9"));
      expect(yield* harness.dispatched).toEqual([]);
      expect(yield* harness.posts).toEqual([]);
      yield* harness.send(mention("<@U0BOT> nowhere do it"));
      expect(yield* harness.dispatched).toEqual([]);
      expect((yield* harness.posts).at(-1)!.text).toBe(
        "Which project? Start with one of: `limitless`.",
      );

      const off = yield* makeHarness(
        { ...armed, infinitusSlack: { ...armed.infinitusSlack, enabled: false } },
        new Map(),
      );
      yield* off.send(mention("<@U0BOT> limitless do it"));
      expect(yield* off.dispatched).toEqual([]);
      expect(yield* off.posts).toEqual([]);
    }),
  );

  effectIt.effect("bindings survive a restart", () =>
    Effect.gen(function* () {
      const files = new Map<string, string>();
      const first = yield* makeHarness(armed, files);
      yield* first.send(mention("<@U0BOT> limitless keep me"));
      const create = (yield* first.dispatched)[0] as Extract<
        OrchestrationCommand,
        { type: "thread.create" }
      >;
      const second = yield* makeHarness(armed, files);
      yield* second.setShell({
        id: create.threadId,
        archivedAt: null,
        session: { status: "idle", activeTurnId: null },
        latestTurn: null,
        pullRequests: [],
      } as unknown as OrchestrationThreadShell);
      yield* second.send(reply("carry on"));
      expect((yield* second.dispatched).map((command) => command.type)).toEqual([
        "thread.turn.start",
      ]);
    }),
  );
});
