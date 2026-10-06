// @effect-diagnostics nodeBuiltinImport:off preferSchemaOverJson:off
import * as NodePath from "node:path";
import * as NodeOS from "node:os";
import * as NodeFSP from "node:fs/promises";
import * as NodeURL from "node:url";

import * as NodeServices from "@effect/platform-node/NodeServices";
import { assert, it } from "@effect/vitest";
import * as Context from "effect/Context";
import * as Deferred from "effect/Deferred";
import * as Effect from "effect/Effect";
import * as Fiber from "effect/Fiber";
import * as Layer from "effect/Layer";
import * as Schema from "effect/Schema";
import * as Stream from "effect/Stream";

import {
  ApprovalRequestId,
  OmpSettings,
  ProviderDriverKind,
  type ProviderRuntimeEvent,
  ThreadId,
  ProviderInstanceId,
} from "@infinitus/contracts";

import { ServerConfig } from "../../config.ts";
import { ServerSettingsService } from "../../serverSettings.ts";
import type { OmpAdapterShape } from "../Services/OmpAdapter.ts";
import { makeOmpAdapter } from "./OmpAdapter.ts";
import { execScriptSource, writeFakeCli } from "../../testUtils/fakeCli.ts";

const decodeOmpSettings = Schema.decodeSync(OmpSettings);

class OmpAdapter extends Context.Service<OmpAdapter, OmpAdapterShape>()(
  "t3/provider/Layers/OmpAdapter.test/OmpAdapter",
) {}

const __dirname = NodePath.dirname(NodeURL.fileURLToPath(import.meta.url));
const mockAgentPath = NodePath.join(__dirname, "../../../scripts/acp-mock-agent.ts");

async function makeMockAgentWrapper(extraEnv?: Record<string, string>) {
  const dir = await NodeFSP.mkdtemp(NodePath.join(NodeOS.tmpdir(), "omp-acp-mock-"));
  return writeFakeCli({
    directory: dir,
    name: "fake-omp",
    env: { T3_ACP_OMP: "1", ...extraEnv },
    source: execScriptSource({ scriptPath: mockAgentPath }),
  });
}

async function makeProbeWrapper(requestLogPath: string, extraEnv?: Record<string, string>) {
  const dir = await NodeFSP.mkdtemp(NodePath.join(NodeOS.tmpdir(), "omp-acp-probe-"));
  return writeFakeCli({
    directory: dir,
    name: "fake-omp",
    env: { T3_ACP_OMP: "1", T3_ACP_REQUEST_LOG_PATH: requestLogPath, ...extraEnv },
    source: execScriptSource({ scriptPath: mockAgentPath }),
  });
}

async function readJsonLines(filePath: string) {
  const raw = await NodeFSP.readFile(filePath, "utf8");
  return raw
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line.length > 0)
    .map((line) => JSON.parse(line) as Record<string, unknown>);
}

function waitForJsonLogMatch(
  filePath: string,
  predicate: (entry: Record<string, unknown>) => boolean,
  attempts = 40,
) {
  return Effect.gen(function* () {
    for (let attempt = 0; attempt < attempts; attempt += 1) {
      const requests = yield* Effect.promise(() => readJsonLines(filePath));
      if (requests.some(predicate)) {
        return requests;
      }
      yield* Effect.yieldNow;
    }
    return yield* Effect.promise(() => readJsonLines(filePath));
  });
}

const isSelectedOutcome = (optionId: string) => (entry: Record<string, unknown>) =>
  !("method" in entry) &&
  typeof entry.result === "object" &&
  entry.result !== null &&
  "outcome" in entry.result &&
  typeof entry.result.outcome === "object" &&
  entry.result.outcome !== null &&
  "outcome" in entry.result.outcome &&
  entry.result.outcome.outcome === "selected" &&
  "optionId" in entry.result.outcome &&
  entry.result.outcome.optionId === optionId;

const makeResolveOmpSettings = Effect.gen(function* () {
  const serverSettings = yield* ServerSettingsService;
  return yield* Effect.succeed(
    serverSettings.getSettings.pipe(
      Effect.map((snapshot) => snapshot.providers.omp),
      Effect.orDie,
    ),
  );
});

const ompAdapterTestLayer = it.layer(
  Layer.effect(
    OmpAdapter,
    Effect.gen(function* () {
      const ompConfig = decodeOmpSettings({});
      const resolveSettings = yield* makeResolveOmpSettings;
      return yield* makeOmpAdapter(ompConfig, { resolveSettings });
    }),
  ).pipe(
    Layer.provideMerge(ServerSettingsService.layerTest()),
    Layer.provideMerge(
      ServerConfig.layerTest(process.cwd(), {
        prefix: "t3code-omp-adapter-test-",
      }),
    ),
    Layer.provideMerge(NodeServices.layer),
  ),
);

ompAdapterTestLayer("OmpAdapterLive", (it) => {
  it.effect("startSession emits session.started and thread.started, then sendTurn completes", () =>
    Effect.gen(function* () {
      const adapter = yield* OmpAdapter;
      const settings = yield* ServerSettingsService;
      const threadId = ThreadId.make("omp-mock-thread");
      const wrapperPath = yield* Effect.promise(() => makeMockAgentWrapper());
      yield* settings.updateSettings({ providers: { omp: { binaryPath: wrapperPath } } });

      const runtimeEvents: Array<ProviderRuntimeEvent> = [];
      const turnCompleted = yield* Deferred.make<void>();
      const runtimeEventsFiber = yield* Stream.runForEach(adapter.streamEvents, (event) =>
        Effect.sync(() => {
          runtimeEvents.push(event);
        }).pipe(
          Effect.andThen(
            event.type === "turn.completed"
              ? Deferred.succeed(turnCompleted, undefined)
              : Effect.void,
          ),
        ),
      ).pipe(Effect.forkChild);

      const session = yield* adapter.startSession({
        threadId,
        provider: ProviderDriverKind.make("omp"),
        cwd: process.cwd(),
        runtimeMode: "full-access",
        modelSelection: { instanceId: ProviderInstanceId.make("omp"), model: "omp-default" },
      });

      assert.equal(session.provider, "omp");
      assert.deepStrictEqual(session.resumeCursor, {
        schemaVersion: 1,
        sessionId: "mock-session-1",
      });

      yield* adapter.sendTurn({
        threadId,
        input: "hello omp",
        attachments: [],
      });

      yield* Deferred.await(turnCompleted);
      yield* Fiber.interrupt(runtimeEventsFiber);
      const types = runtimeEvents.map((event) => event.type);

      assert.includeMembers(types, [
        "session.started",
        "session.state.changed",
        "thread.started",
        "turn.started",
        "content.delta",
        "turn.completed",
      ]);

      const delta = runtimeEvents.find((event) => event.type === "content.delta");
      assert.isDefined(delta);
      if (delta?.type === "content.delta") {
        assert.equal(delta.payload.delta, "hello from mock");
      }

      yield* adapter.stopSession(threadId);
    }),
  );

  it.effect("maps accept / acceptForSession / reject onto omp permission option ids", () =>
    Effect.gen(function* () {
      const adapter = yield* OmpAdapter;
      const settings = yield* ServerSettingsService;
      const cases = [
        { decision: "accept" as const, optionId: "allow_once", threadId: "omp-accept-once" },
        {
          decision: "acceptForSession" as const,
          optionId: "allow_always",
          threadId: "omp-accept-always",
        },
        { decision: "decline" as const, optionId: "reject_once", threadId: "omp-reject-once" },
      ];

      for (const testCase of cases) {
        const threadId = ThreadId.make(testCase.threadId);
        const tempDir = yield* Effect.promise(() =>
          NodeFSP.mkdtemp(NodePath.join(NodeOS.tmpdir(), "omp-acp-")),
        );
        const requestLogPath = NodePath.join(tempDir, "requests.ndjson");
        yield* Effect.promise(() => NodeFSP.writeFile(requestLogPath, "", "utf8"));
        const wrapperPath = yield* Effect.promise(() =>
          makeProbeWrapper(requestLogPath, { T3_ACP_EMIT_TOOL_CALLS: "1" }),
        );
        yield* settings.updateSettings({ providers: { omp: { binaryPath: wrapperPath } } });

        const requestOpened = yield* Deferred.make<void>();
        const turnCompleted = yield* Deferred.make<void>();
        const runtimeEventsFiber = yield* Stream.runForEach(adapter.streamEvents, (event) =>
          Effect.gen(function* () {
            if (String(event.threadId) !== String(threadId)) {
              return;
            }
            if (event.type === "request.opened" && event.requestId) {
              yield* adapter.respondToRequest(
                threadId,
                ApprovalRequestId.make(String(event.requestId)),
                testCase.decision,
              );
              yield* Deferred.succeed(requestOpened, undefined).pipe(Effect.ignore);
            }
            if (event.type === "turn.completed") {
              yield* Deferred.succeed(turnCompleted, undefined).pipe(Effect.ignore);
            }
          }),
        ).pipe(Effect.forkChild);

        yield* adapter.startSession({
          threadId,
          provider: ProviderDriverKind.make("omp"),
          cwd: process.cwd(),
          runtimeMode: "approval-required",
        });
        yield* adapter.sendTurn({ threadId, input: "approve this", attachments: [] });
        yield* Deferred.await(requestOpened);
        yield* Deferred.await(turnCompleted);

        const requests = yield* waitForJsonLogMatch(
          requestLogPath,
          isSelectedOutcome(testCase.optionId),
        );
        assert.isTrue(
          requests.some(isSelectedOutcome(testCase.optionId)),
          `expected optionId ${testCase.optionId}`,
        );

        yield* Fiber.interrupt(runtimeEventsFiber);
        yield* adapter.stopSession(threadId);
      }
    }),
  );

  it.effect("auto-approves permissions in full-access without request.opened", () =>
    Effect.gen(function* () {
      const adapter = yield* OmpAdapter;
      const settings = yield* ServerSettingsService;
      const threadId = ThreadId.make("omp-full-access-auto-approve");
      const runtimeEvents: Array<ProviderRuntimeEvent> = [];
      const turnCompleted = yield* Deferred.make<void>();
      const tempDir = yield* Effect.promise(() =>
        NodeFSP.mkdtemp(NodePath.join(NodeOS.tmpdir(), "omp-acp-")),
      );
      const requestLogPath = NodePath.join(tempDir, "requests.ndjson");
      yield* Effect.promise(() => NodeFSP.writeFile(requestLogPath, "", "utf8"));
      const wrapperPath = yield* Effect.promise(() =>
        makeProbeWrapper(requestLogPath, { T3_ACP_EMIT_TOOL_CALLS: "1" }),
      );
      yield* settings.updateSettings({ providers: { omp: { binaryPath: wrapperPath } } });

      const runtimeEventsFiber = yield* Stream.runForEach(adapter.streamEvents, (event) =>
        Effect.gen(function* () {
          runtimeEvents.push(event);
          if (String(event.threadId) === String(threadId) && event.type === "turn.completed") {
            yield* Deferred.succeed(turnCompleted, undefined).pipe(Effect.orDie);
          }
        }),
      ).pipe(Effect.forkChild);

      yield* adapter.startSession({
        threadId,
        provider: ProviderDriverKind.make("omp"),
        cwd: process.cwd(),
        runtimeMode: "full-access",
      });
      yield* adapter.sendTurn({ threadId, input: "run a tool call", attachments: [] });
      yield* Deferred.await(turnCompleted);
      yield* Fiber.interrupt(runtimeEventsFiber);

      assert.notInclude(
        runtimeEvents
          .filter((event) => String(event.threadId) === String(threadId))
          .map((event) => event.type),
        "request.opened",
      );

      const requests = yield* waitForJsonLogMatch(
        requestLogPath,
        isSelectedOutcome("allow_always"),
      );
      assert.isTrue(requests.some(isSelectedOutcome("allow_always")));

      yield* adapter.stopSession(threadId);
    }),
  );

  it.effect("interruptTurn cancels the in-flight prompt", () =>
    Effect.gen(function* () {
      const adapter = yield* OmpAdapter;
      const settings = yield* ServerSettingsService;
      const threadId = ThreadId.make("omp-interrupt");
      const tempDir = yield* Effect.promise(() =>
        NodeFSP.mkdtemp(NodePath.join(NodeOS.tmpdir(), "omp-acp-")),
      );
      const requestLogPath = NodePath.join(tempDir, "requests.ndjson");
      yield* Effect.promise(() => NodeFSP.writeFile(requestLogPath, "", "utf8"));
      const wrapperPath = yield* Effect.promise(() =>
        makeProbeWrapper(requestLogPath, { T3_ACP_EMIT_TOOL_CALLS: "1" }),
      );
      yield* settings.updateSettings({ providers: { omp: { binaryPath: wrapperPath } } });

      const requestOpened = yield* Deferred.make<void>();
      const turnCompleted = yield* Deferred.make<ProviderRuntimeEvent>();
      const runtimeEventsFiber = yield* Stream.runForEach(adapter.streamEvents, (event) =>
        Effect.gen(function* () {
          if (String(event.threadId) !== String(threadId)) {
            return;
          }
          if (event.type === "request.opened") {
            yield* adapter.interruptTurn(threadId);
            yield* Deferred.succeed(requestOpened, undefined).pipe(Effect.ignore);
          }
          if (event.type === "turn.completed") {
            yield* Deferred.succeed(turnCompleted, event).pipe(Effect.ignore);
          }
        }),
      ).pipe(Effect.forkChild);

      yield* adapter.startSession({
        threadId,
        provider: ProviderDriverKind.make("omp"),
        cwd: process.cwd(),
        runtimeMode: "approval-required",
      });

      const sendTurnFiber = yield* adapter
        .sendTurn({ threadId, input: "cancel this turn", attachments: [] })
        .pipe(Effect.forkChild);

      yield* Deferred.await(requestOpened);
      const completed = yield* Deferred.await(turnCompleted);
      yield* Fiber.join(sendTurnFiber);
      yield* Fiber.interrupt(runtimeEventsFiber);

      assert.equal(completed.type, "turn.completed");
      if (completed.type === "turn.completed") {
        assert.equal(completed.payload.state, "cancelled");
      }

      const requests = yield* waitForJsonLogMatch(
        requestLogPath,
        (entry) => entry.method === "session/cancel",
      );
      assert.isTrue(requests.some((entry) => entry.method === "session/cancel"));

      yield* adapter.stopSession(threadId);
    }),
  );
  // Oh My Pi concatenates a prompt's text blocks with a blank line and hands
  // the whole string to its slash-command parser, which reads everything after
  // the command name as that command's arguments. A runtime-instructions block
  // appended to `/compact` would therefore become the compaction's focus text.
  it.effect("sends a bare slash command without the runtime instructions block", () =>
    Effect.gen(function* () {
      const adapter = yield* OmpAdapter;
      const settings = yield* ServerSettingsService;
      const threadId = ThreadId.make("omp-slash-command-prompt");
      const turnCompleted = yield* Deferred.make<void>();
      const tempDir = yield* Effect.promise(() =>
        NodeFSP.mkdtemp(NodePath.join(NodeOS.tmpdir(), "omp-acp-")),
      );
      const requestLogPath = NodePath.join(tempDir, "requests.ndjson");
      yield* Effect.promise(() => NodeFSP.writeFile(requestLogPath, "", "utf8"));
      const wrapperPath = yield* Effect.promise(() => makeProbeWrapper(requestLogPath));
      yield* settings.updateSettings({ providers: { omp: { binaryPath: wrapperPath } } });

      const runtimeEventsFiber = yield* Stream.runForEach(adapter.streamEvents, (event) =>
        Effect.gen(function* () {
          if (String(event.threadId) === String(threadId) && event.type === "turn.completed") {
            yield* Deferred.succeed(turnCompleted, undefined).pipe(Effect.ignore);
          }
        }),
      ).pipe(Effect.forkChild);

      yield* adapter.startSession({
        threadId,
        provider: ProviderDriverKind.make("omp"),
        cwd: process.cwd(),
        runtimeMode: "full-access",
      });
      yield* adapter.sendTurn({ threadId, input: "/compact", attachments: [] });
      yield* Deferred.await(turnCompleted);

      const isPrompt = (entry: Record<string, unknown>) => entry.method === "session/prompt";
      const requests = yield* waitForJsonLogMatch(requestLogPath, isPrompt);
      const prompt = requests.find(isPrompt);
      assert.isDefined(prompt, "expected a session/prompt request");
      const blocks = (prompt?.params as { prompt?: ReadonlyArray<{ text?: string }> } | undefined)
        ?.prompt;
      assert.isArray(blocks);
      assert.deepStrictEqual(
        blocks?.map((block) => block.text),
        ["/compact"],
        "a slash-command turn carries exactly one text block",
      );

      yield* Fiber.interrupt(runtimeEventsFiber);
      yield* adapter.stopSession(threadId);
    }),
  );
});
