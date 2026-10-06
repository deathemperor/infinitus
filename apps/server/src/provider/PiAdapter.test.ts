// @effect-diagnostics nodeBuiltinImport:off globalTimers:off - the mock's argv log is polled on a real timer; the harness runs on TestClock and nothing advances it.
import * as NodeFSP from "node:fs/promises";
import * as NodeOS from "node:os";
import * as NodePath from "node:path";
import * as NodeURL from "node:url";

import * as NodeServices from "@effect/platform-node/NodeServices";
import { assert, it } from "@effect/vitest";
import * as Deferred from "effect/Deferred";
import * as Effect from "effect/Effect";
import * as Fiber from "effect/Fiber";
import * as Schema from "effect/Schema";
import * as Stream from "effect/Stream";
import {
  PiSettings,
  ProviderInstanceId,
  ThreadId,
  type ProviderRuntimeEvent,
} from "@infinitus/contracts";
import { createModelSelection } from "@infinitus/shared/model";

import { execScriptSource, writeFakeCli } from "../../testUtils/fakeCli.ts";
import { makePiAdapter } from "./PiAdapter.ts";

const decodePiSettings = Schema.decodeSync(PiSettings);
const __dirname = NodePath.dirname(NodeURL.fileURLToPath(import.meta.url));
const mockAgentPath = NodePath.join(__dirname, "../../../scripts/pi-rpc-mock-agent.ts");
const INSTANCE_ID = ProviderInstanceId.make("pi");

/**
 * Waits for the mock to have logged `expected` argv lines.
 *
 * `startSession` returns as soon as the spawn succeeds, which is before the
 * child has run a line of code, so reading the log straight after it races.
 * The wait is a real timer rather than `Effect.sleep`, because the harness
 * runs on TestClock and nothing here advances it.
 */
const readArgvLog = (filePath: string, expected: number) =>
  Effect.promise(async () => {
    for (let attempt = 0; attempt < 240; attempt += 1) {
      const raw = await NodeFSP.readFile(filePath, "utf8").catch(() => "");
      const lines = raw.split("\n").filter((line) => line.trim().length > 0);
      if (lines.length >= expected) return lines.map((line) => line.split("\t"));
      await new Promise((resolve) => setTimeout(resolve, 25));
    }
    throw new Error(`Timed out waiting for ${expected} argv lines in ${filePath}`);
  });

async function makeMockPi(env?: Record<string, string>, argvLogPath?: string) {
  const directory = await NodeFSP.mkdtemp(NodePath.join(NodeOS.tmpdir(), "pi-rpc-mock-"));
  return writeFakeCli({
    directory,
    name: "pi",
    env: env ?? {},
    source: execScriptSource({
      scriptPath: mockAgentPath,
      ...(argvLogPath === undefined ? {} : { argvLogPath }),
    }),
  });
}

/** Collects runtime events into an array for assertions after the turn. */
const collectEvents = (stream: Stream.Stream<ProviderRuntimeEvent>) =>
  Effect.gen(function* () {
    const events: Array<ProviderRuntimeEvent> = [];
    const fiber = yield* Effect.forkChild(
      Stream.runForEach(stream, (event) => Effect.sync(() => void events.push(event))),
    );
    return { events, fiber };
  });

const startAndPrompt = (input: {
  readonly binaryPath: string;
  readonly cwd: string;
  readonly prompt?: string;
  readonly model?: string;
}) =>
  Effect.gen(function* () {
    const adapter = yield* makePiAdapter(
      decodePiSettings({ enabled: true, binaryPath: input.binaryPath }),
      { instanceId: INSTANCE_ID, environment: process.env },
    );
    const threadId = ThreadId.make("thread-pi-1");
    const collected = yield* collectEvents(adapter.streamEvents);
    yield* adapter.startSession({
      threadId,
      provider: undefined,
      cwd: input.cwd,
      runtimeMode: "full-access",
      ...(input.model ? { modelSelection: createModelSelection(INSTANCE_ID, input.model) } : {}),
    });
    const result = yield* adapter.sendTurn({
      threadId,
      input: input.prompt ?? "hello",
    });
    return { adapter, threadId, result, ...collected };
  });

it.effect(
  "streams assistant text and completes the turn",
  () =>
    Effect.gen(function* () {
      const binaryPath = yield* Effect.promise(() =>
        makeMockPi({ T3_PI_RESPONSE_TEXT: "PONG", T3_PI_EMIT_THINKING: "1" }),
      );
      const { events, fiber, result } = yield* startAndPrompt({
        binaryPath,
        cwd: process.cwd(),
      });
      yield* Fiber.interrupt(fiber);

      const assistantText = events
        .filter(
          (event) =>
            event.type === "content.delta" && event.payload.streamKind === "assistant_text",
        )
        .map((event) => (event.type === "content.delta" ? event.payload.delta : ""))
        .join("");
      const reasoningText = events
        .filter(
          (event) =>
            event.type === "content.delta" && event.payload.streamKind === "reasoning_text",
        )
        .map((event) => (event.type === "content.delta" ? event.payload.delta : ""))
        .join("");

      // The trap this protocol sets: thinking and text arrive as separate
      // streams, and accumulating any `delta` glues the model's private
      // reasoning onto its answer.
      assert.strictEqual(assistantText, "PONG");
      assert.strictEqual(reasoningText, "Considering the request");
      assert.isTrue(events.some((event) => event.type === "turn.started"));
      const completed = events.find((event) => event.type === "turn.completed");
      assert.isDefined(completed);
      assert.strictEqual(
        completed?.type === "turn.completed" && completed.payload.state,
        "completed",
      );
      assert.strictEqual(result.turnId, completed?.turnId);
    }).pipe(Effect.scoped, Effect.provide(NodeServices.layer)),
  { timeout: 30_000 },
);

it.effect(
  "does not settle the turn on the first turn_end of a tool-using prompt",
  () =>
    Effect.gen(function* () {
      const binaryPath = yield* Effect.promise(() =>
        makeMockPi({ T3_PI_EMIT_TOOL_CALL: "1", T3_PI_RESPONSE_TEXT: "WROTE" }),
      );
      const { events, fiber } = yield* startAndPrompt({ binaryPath, cwd: process.cwd() });
      yield* Fiber.interrupt(fiber);

      // A tool-using prompt emits two turn_end events for one turn, so a turn
      // keyed on turn_end (or on agent_end) settles while work is still running
      // and the reply that follows lands outside the turn.
      const assistantText = events
        .filter(
          (event) =>
            event.type === "content.delta" && event.payload.streamKind === "assistant_text",
        )
        .map((event) => (event.type === "content.delta" ? event.payload.delta : ""))
        .join("");
      assert.strictEqual(assistantText, "WROTE");
      assert.lengthOf(
        events.filter((event) => event.type === "turn.completed"),
        1,
      );

      const toolStarted = events.find(
        (event) => event.type === "item.started" && event.payload.itemType === "file_change",
      );
      const toolCompleted = events.find(
        (event) => event.type === "item.completed" && event.payload.itemType === "file_change",
      );
      assert.isDefined(toolStarted);
      assert.isDefined(toolCompleted);
      assert.strictEqual(toolStarted?.itemId, toolCompleted?.itemId);
      assert.strictEqual(
        toolCompleted?.type === "item.completed" && toolCompleted.payload.status,
        "completed",
      );
    }).pipe(Effect.scoped, Effect.provide(NodeServices.layer)),
  { timeout: 30_000 },
);

it.effect(
  "carries a Unicode line separator through the turn intact",
  () =>
    Effect.gen(function* () {
      const binaryPath = yield* Effect.promise(() =>
        makeMockPi({ T3_PI_RESPONSE_TEXT: "HEAD", T3_PI_EMIT_SEPARATOR_TEXT: "1" }),
      );
      const { events, fiber } = yield* startAndPrompt({ binaryPath, cwd: process.cwd() });
      yield* Fiber.interrupt(fiber);

      // U+2028 is legal inside a JSON string. A reader that treats it as a
      // record terminator (Node `readline`, and Effect's own splitLines for
      // CR) truncates the payload here instead.
      const assistantText = events
        .filter(
          (event) =>
            event.type === "content.delta" && event.payload.streamKind === "assistant_text",
        )
        .map((event) => (event.type === "content.delta" ? event.payload.delta : ""))
        .join("");
      assert.strictEqual(assistantText, "HEAD\u2028tail");
    }).pipe(Effect.scoped, Effect.provide(NodeServices.layer)),
  { timeout: 30_000 },
);

it.effect(
  "refuses every runtime mode that implies supervision",
  () =>
    Effect.gen(function* () {
      const binaryPath = yield* Effect.promise(() => makeMockPi());
      const adapter = yield* makePiAdapter(decodePiSettings({ enabled: true, binaryPath }), {
        instanceId: INSTANCE_ID,
        environment: process.env,
      });

      for (const runtimeMode of ["approval-required", "auto-accept-edits", "auto"] as const) {
        const result = yield* Effect.result(
          adapter.startSession({
            threadId: ThreadId.make(`thread-${runtimeMode}`),
            provider: undefined,
            cwd: process.cwd(),
            runtimeMode,
          }),
        );
        // Pi runs every tool ungated, so accepting a supervised mode would
        // hand the user an unsupervised agent while the UI claimed otherwise.
        assert.isTrue(result._tag === "Failure", `${runtimeMode} should be refused`);
        if (result._tag === "Failure") {
          assert.include(result.failure.message, "no permission system");
        }
      }

      // Full access is the one mode Pi can honestly serve.
      const allowed = yield* Effect.result(
        adapter.startSession({
          threadId: ThreadId.make("thread-full-access"),
          provider: undefined,
          cwd: process.cwd(),
          runtimeMode: "full-access",
        }),
      );
      assert.strictEqual(allowed._tag, "Success");
    }).pipe(Effect.scoped, Effect.provide(NodeServices.layer)),
  { timeout: 30_000 },
);

it.effect(
  "fails the turn and retires the session when the Pi process exits mid-prompt",
  () =>
    Effect.gen(function* () {
      const binaryPath = yield* Effect.promise(() =>
        makeMockPi({ T3_PI_EXIT_ON_PROMPT: "1", T3_PI_STDERR_MESSAGE: "boom from pi" }),
      );
      const adapter = yield* makePiAdapter(decodePiSettings({ enabled: true, binaryPath }), {
        instanceId: INSTANCE_ID,
        environment: process.env,
      });
      const threadId = ThreadId.make("thread-exit");
      const { events, fiber } = yield* collectEvents(adapter.streamEvents);
      yield* adapter.startSession({
        threadId,
        provider: undefined,
        cwd: process.cwd(),
        runtimeMode: "full-access",
      });

      // Without an explicit settle on process exit this awaits a deferred that
      // nothing will ever complete, and the turn hangs forever.
      const result = yield* Effect.result(adapter.sendTurn({ threadId, input: "hello" }));
      assert.strictEqual(result._tag, "Failure");
      if (result._tag === "Failure") {
        assert.include(result.failure.message, "Pi process exited");
        assert.include(result.failure.message, "boom from pi");
      }

      // The child is gone, so the session must go with it. Left in the map it
      // would still answer `hasSession` and be handed to the next caller,
      // holding its scope open until the whole adapter is torn down.
      assert.isFalse(yield* adapter.hasSession(threadId));
      assert.deepStrictEqual(yield* adapter.listSessions(), []);

      // The turn settles before the teardown's own events reach the stream,
      // so the exit notice is waited for rather than read straight off.
      const exited = yield* Effect.promise(
        () =>
          new Promise<ProviderRuntimeEvent | undefined>((resolve) => {
            // Bounded by a tick count rather than a deadline: the effect
            // diagnostics reserve wall-clock reads for Effect's own `Clock`,
            // and the enclosing `timeout` is the real backstop anyway.
            let ticksLeft = 500;
            const poll = setInterval(() => {
              const hit = events.find((event) => event.type === "session.exited");
              if (hit || --ticksLeft <= 0) {
                clearInterval(poll);
                resolve(hit);
              }
            }, 20);
          }),
      );
      yield* Fiber.interrupt(fiber);
      assert.isDefined(exited);
      assert.strictEqual(exited?.type === "session.exited" && exited.payload.exitKind, "error");
    }).pipe(Effect.scoped, Effect.provide(NodeServices.layer)),
  { timeout: 30_000 },
);

it.effect(
  "fails the turn when the assistant message ends in an error",
  () =>
    Effect.gen(function* () {
      const binaryPath = yield* Effect.promise(() => makeMockPi({ T3_PI_ERROR_STOP: "1" }));
      const adapter = yield* makePiAdapter(decodePiSettings({ enabled: true, binaryPath }), {
        instanceId: INSTANCE_ID,
        environment: process.env,
      });
      const threadId = ThreadId.make("thread-error-stop");
      const { events } = yield* collectEvents(adapter.streamEvents);
      yield* adapter.startSession({
        threadId,
        provider: undefined,
        cwd: process.cwd(),
        runtimeMode: "full-access",
      });
      const result = yield* Effect.result(adapter.sendTurn({ threadId, input: "hello" }));
      assert.strictEqual(result._tag, "Failure");
      const completed = events.find((event) => event.type === "turn.completed");
      assert.deepStrictEqual(completed?.payload, {
        state: "failed",
        errorMessage: "401 invalid api key",
      });
    }).pipe(Effect.scoped, Effect.provide(NodeServices.layer)),
  { timeout: 30_000 },
);

it.effect(
  "sends an image-only turn with the image beside the text",
  () =>
    Effect.gen(function* () {
      const binaryPath = yield* Effect.promise(() => makeMockPi());
      const attachmentsDir = yield* Effect.promise(() =>
        NodeFSP.mkdtemp(NodePath.join(NodeOS.tmpdir(), "pi-attachments-")),
      );
      yield* Effect.promise(() =>
        NodeFSP.writeFile(NodePath.join(attachmentsDir, "shot-1.png"), "not really a png"),
      );
      const adapter = yield* makePiAdapter(decodePiSettings({ enabled: true, binaryPath }), {
        instanceId: INSTANCE_ID,
        environment: process.env,
        attachmentsDir,
      });
      const threadId = ThreadId.make("thread-image");
      const { events } = yield* collectEvents(adapter.streamEvents);
      yield* adapter.startSession({
        threadId,
        provider: undefined,
        cwd: process.cwd(),
        runtimeMode: "full-access",
      });
      yield* adapter.sendTurn({
        threadId,
        attachments: [
          {
            type: "image",
            id: "shot-1",
            name: "shot.png",
            mimeType: "image/png",
            sizeBytes: 16,
          },
        ],
      });
      const message = events.find(
        (event) =>
          event.type === "item.completed" && event.payload.itemType === "assistant_message",
      );
      assert.strictEqual(
        message?.type === "item.completed" ? message.payload.detail : undefined,
        "IMAGES:1",
      );
    }).pipe(Effect.scoped, Effect.provide(NodeServices.layer)),
  { timeout: 30_000 },
);

it.effect(
  "surfaces a rejected prompt as a turn failure",
  () =>
    Effect.gen(function* () {
      const binaryPath = yield* Effect.promise(() => makeMockPi({ T3_PI_FAIL_PROMPT: "1" }));
      const adapter = yield* makePiAdapter(decodePiSettings({ enabled: true, binaryPath }), {
        instanceId: INSTANCE_ID,
        environment: process.env,
      });
      const threadId = ThreadId.make("thread-reject");
      yield* adapter.startSession({
        threadId,
        provider: undefined,
        cwd: process.cwd(),
        runtimeMode: "full-access",
      });
      const result = yield* Effect.result(adapter.sendTurn({ threadId, input: "hello" }));
      assert.strictEqual(result._tag, "Failure");
    }).pipe(Effect.scoped, Effect.provide(NodeServices.layer)),
  { timeout: 30_000 },
);

it.effect(
  "omits --model for the pi-default sentinel and passes a real slug through",
  () =>
    Effect.gen(function* () {
      const directory = yield* Effect.promise(() =>
        NodeFSP.mkdtemp(NodePath.join(NodeOS.tmpdir(), "pi-argv-")),
      );
      const argvLogPath = NodePath.join(directory, "argv.log");
      const binaryPath = yield* Effect.promise(() => makeMockPi({}, argvLogPath));

      const adapter = yield* makePiAdapter(decodePiSettings({ enabled: true, binaryPath }), {
        instanceId: INSTANCE_ID,
        environment: process.env,
      });
      yield* adapter.startSession({
        threadId: ThreadId.make("thread-default-model"),
        provider: undefined,
        cwd: process.cwd(),
        runtimeMode: "full-access",
        modelSelection: createModelSelection(INSTANCE_ID, "pi-default"),
      });
      yield* adapter.startSession({
        threadId: ThreadId.make("thread-real-model"),
        provider: undefined,
        cwd: process.cwd(),
        runtimeMode: "full-access",
        modelSelection: createModelSelection(INSTANCE_ID, "zai/glm-5.3"),
      });

      const argv = yield* readArgvLog(argvLogPath, 2);

      // The two children write the log independently, so the order they land
      // in is not guaranteed; assert over the set rather than by position.
      assert.lengthOf(argv, 2);
      const withModel = argv.filter((args) => args.includes("--model"));
      const withoutModel = argv.filter((args) => !args.includes("--model"));
      // `pi-default` is our sentinel, not a slug Pi knows: passing it fails the
      // process with `Model "pi-default" not found`.
      assert.lengthOf(withoutModel, 1);
      assert.lengthOf(withModel, 1);
      assert.include(withModel[0]!, "zai/glm-5.3");
      for (const args of argv) assert.include(args, "--mode");
    }).pipe(Effect.scoped, Effect.provide(NodeServices.layer)),
  { timeout: 30_000 },
);

it.effect(
  "reuses the resume cursor's session id so Pi continues the same session",
  () =>
    Effect.gen(function* () {
      const directory = yield* Effect.promise(() =>
        NodeFSP.mkdtemp(NodePath.join(NodeOS.tmpdir(), "pi-resume-")),
      );
      const argvLogPath = NodePath.join(directory, "argv.log");
      const binaryPath = yield* Effect.promise(() => makeMockPi({}, argvLogPath));
      const adapter = yield* makePiAdapter(decodePiSettings({ enabled: true, binaryPath }), {
        instanceId: INSTANCE_ID,
        environment: process.env,
      });

      const first = yield* adapter.startSession({
        threadId: ThreadId.make("thread-resume"),
        provider: undefined,
        cwd: process.cwd(),
        runtimeMode: "full-access",
      });
      // Stopping the session kills the child; without waiting for it to have
      // run, it dies before logging its argv and the assertion has nothing to
      // compare against.
      yield* readArgvLog(argvLogPath, 1);
      yield* adapter.stopSession(ThreadId.make("thread-resume"));
      yield* adapter.startSession({
        threadId: ThreadId.make("thread-resume"),
        provider: undefined,
        cwd: process.cwd(),
        runtimeMode: "full-access",
        resumeCursor: first.resumeCursor,
      });

      const argv = yield* readArgvLog(argvLogPath, 2);
      const sessionIdOf = (args: ReadonlyArray<string>) => args[args.indexOf("--session-id") + 1];

      assert.lengthOf(argv, 2);
      assert.isDefined(sessionIdOf(argv[0]!));
      assert.strictEqual(sessionIdOf(argv[0]!), sessionIdOf(argv[1]!));
    }).pipe(Effect.scoped, Effect.provide(NodeServices.layer)),
  { timeout: 30_000 },
);

it.effect(
  "stopping a session settles a turn that is still waiting",
  () =>
    Effect.gen(function* () {
      const binaryPath = yield* Effect.promise(() => makeMockPi({ T3_PI_HANG_PROMPT: "1" }));
      const adapter = yield* makePiAdapter(decodePiSettings({ enabled: true, binaryPath }), {
        instanceId: INSTANCE_ID,
        environment: process.env,
      });
      const threadId = ThreadId.make("thread-hang");
      yield* adapter.startSession({
        threadId,
        provider: undefined,
        cwd: process.cwd(),
        runtimeMode: "full-access",
      });

      const started = yield* Deferred.make<void>();
      const turnFiber = yield* Effect.forkChild(
        Deferred.succeed(started, undefined).pipe(
          Effect.andThen(Effect.result(adapter.sendTurn({ threadId, input: "hello" }))),
        ),
      );
      yield* Deferred.await(started);

      // A stopped session must release the waiter; otherwise the turn is
      // pinned to a killed child and never returns.
      yield* adapter.stopSession(threadId);
      const outcome = yield* Fiber.await(turnFiber);
      assert.strictEqual(outcome._tag, "Success");
    }).pipe(Effect.scoped, Effect.provide(NodeServices.layer)),
  { timeout: 30_000 },
);

it.effect(
  "interrupts a running turn without waiting for Pi's deferred acknowledgement",
  () =>
    Effect.gen(function* () {
      // The prompt hangs, so the turn ends only because `abort` reaches the
      // child: this covers the whole interrupt path, from the command going
      // out to `turn.aborted` coming back on the event stream.
      const binaryPath = yield* Effect.promise(() => makeMockPi({ T3_PI_HANG_PROMPT: "1" }));
      const adapter = yield* makePiAdapter(decodePiSettings({ enabled: true, binaryPath }), {
        instanceId: INSTANCE_ID,
        environment: process.env,
      });
      const threadId = ThreadId.make("thread-pi-interrupt");
      const { events, fiber } = yield* collectEvents(adapter.streamEvents);
      yield* adapter.startSession({
        threadId,
        provider: undefined,
        cwd: process.cwd(),
        runtimeMode: "full-access",
      });

      // `sendTurn` resolves only once the turn settles, which for a hanging
      // prompt is the abort itself, so it runs on its own fiber.
      const turnFiber = yield* Effect.forkChild(adapter.sendTurn({ threadId, input: "hello" }));
      yield* Effect.promise(() => new Promise((resolve) => setTimeout(resolve, 300)));

      yield* adapter.interruptTurn(threadId);

      const result = yield* Fiber.join(turnFiber);
      yield* Fiber.interrupt(fiber);

      const aborted = events.find((event) => event.type === "turn.aborted");
      assert.isDefined(aborted);
      assert.strictEqual(aborted?.turnId, result.turnId);
    }).pipe(Effect.scoped, Effect.provide(NodeServices.layer)),
  { timeout: 30_000 },
);

it.effect(
  "keeps an aborted turn open until Pi settles, so the next prompt is accepted",
  () =>
    Effect.gen(function* () {
      // Pi refuses a prompt until `agent_settled`, which trails the aborted
      // `message_end`. Settling on the message would send the follow-up early.
      const binaryPath = yield* Effect.promise(() => makeMockPi({ T3_PI_HANG_PROMPT: "1" }));
      const adapter = yield* makePiAdapter(decodePiSettings({ enabled: true, binaryPath }), {
        instanceId: INSTANCE_ID,
        environment: process.env,
      });
      const threadId = ThreadId.make("thread-pi-abort-then-prompt");
      const { events, fiber } = yield* collectEvents(adapter.streamEvents);
      yield* adapter.startSession({
        threadId,
        provider: undefined,
        cwd: process.cwd(),
        runtimeMode: "full-access",
      });
      const turnFiber = yield* Effect.forkChild(adapter.sendTurn({ threadId, input: "hello" }));
      yield* Effect.promise(() => new Promise((resolve) => setTimeout(resolve, 300)));
      yield* adapter.interruptTurn(threadId);
      yield* Fiber.join(turnFiber);

      const second = yield* adapter.sendTurn({ threadId, input: "again" });
      yield* Fiber.interrupt(fiber);

      const completed = events.find(
        (event) => event.type === "turn.completed" && event.turnId === second.turnId,
      );
      assert.deepStrictEqual(completed?.payload, { state: "completed" });
    }).pipe(Effect.scoped, Effect.provide(NodeServices.layer)),
  { timeout: 30_000 },
);

it.effect(
  "does not stamp a settled turn's id onto records that arrive after it",
  () =>
    Effect.gen(function* () {
      const binaryPath = yield* Effect.promise(() =>
        makeMockPi({ T3_PI_RESPONSE_TEXT: "PONG", T3_PI_EMIT_TRAILING_TEXT: "1" }),
      );
      const { events, fiber, result } = yield* startAndPrompt({
        binaryPath,
        cwd: process.cwd(),
      });

      // Pi keeps the session alive between prompts and still emits records on
      // it. A turn id left active after the turn settled attributes that
      // chatter to a turn the orchestrator has already closed.
      yield* Effect.promise(() => new Promise((resolve) => setTimeout(resolve, 200)));
      yield* Fiber.interrupt(fiber);

      const trailing = events.find(
        (event) => event.type === "content.delta" && event.payload.delta === "TRAILING",
      );
      assert.isDefined(trailing);
      assert.isUndefined(trailing?.turnId);

      const inTurn = events.find(
        (event) => event.type === "content.delta" && event.payload.delta === "PONG",
      );
      assert.strictEqual(inTurn?.turnId, result.turnId);
    }).pipe(Effect.scoped, Effect.provide(NodeServices.layer)),
  { timeout: 30_000 },
);
