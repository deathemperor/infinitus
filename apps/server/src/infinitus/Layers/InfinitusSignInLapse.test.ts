import { ThreadId, type OrchestrationV2DomainEvent } from "@infinitus/contracts";
import {
  InfinitusCommandFailed,
  type InfinitusCommandInput,
  type InfinitusManifestCommand,
  type InfinitusSnapshot,
} from "@infinitus/contracts/infinitus";
import { it as effectIt } from "@effect/vitest";
import * as Duration from "effect/Duration";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as PubSub from "effect/PubSub";
import * as Ref from "effect/Ref";
import * as Stream from "effect/Stream";
import * as TestClock from "effect/testing/TestClock";
import { describe, expect } from "vite-plus/test";

import * as Orchestrator from "../../orchestration-v2/Orchestrator.ts";
import { ProcessRunner, type ProcessRunInput } from "../../processRunner.ts";
import { InfinitusService } from "../Services/Infinitus.ts";
import { InfinitusAlertRelay } from "../Services/InfinitusAlertRelay.ts";
import { InfinitusControlClient } from "../Services/InfinitusControlClient.ts";
import { InfinitusSignInLapseLive } from "./InfinitusSignInLapse.ts";

const one = ThreadId.make("thread-1");
const two = ThreadId.make("thread-2");

const SSO_EXPIRED = "Error when retrieving token from sso: Token has expired and refresh failed\n";
const GCLOUD_ADC =
  "google.auth.exceptions.DefaultCredentialsError: Your default credentials were not found.\n";

let counter = 0;
/** A `command_execution` turn item stored by the orchestrator, as its
    `turn-item.updated` domain event. */
const commandItem = (
  threadId: ThreadId,
  input: string,
  extra: { readonly status: "running" | "completed" | "failed"; readonly output?: string },
  itemId = `item-${(counter += 1)}`,
): OrchestrationV2DomainEvent =>
  ({
    type: "turn-item.updated",
    id: `evt-${(counter += 1)}`,
    threadId,
    occurredAt: "2026-10-10T00:00:00Z",
    payload: {
      id: itemId,
      threadId,
      type: "command_execution",
      input,
      ...extra,
    },
  }) as never;

/** A finished Bash command and what it printed. */
const toolResult = (
  threadId: ThreadId,
  output: string,
  command = "aws sts get-caller-identity",
): OrchestrationV2DomainEvent => commandItem(threadId, command, { status: "failed", output });

/** A Bash command's start: running, no output yet. */
const toolStart = (threadId: ThreadId, command: string, itemId?: string) =>
  commandItem(threadId, command, { status: "running" }, itemId);

const command = (name: string): InfinitusManifestCommand => ({
  name,
  args: ["<profile>"],
  options: [],
  effect: "human",
  summary: "",
  replyShape: "",
});
const manifest = (...names: ReadonlyArray<string>): InfinitusSnapshot => ({
  available: true,
  fleets: [],
  commands: names.map(command),
});
const withLogin = (phase: string, profile = "default"): InfinitusSnapshot => ({
  ...manifest("aws-login", "gcloud-login"),
  awsLogins: [
    {
      profile,
      flow: "local",
      state: { profile, flow: "local", phase, startedAt: 0 },
    },
  ],
});
const notPolled: InfinitusSnapshot = {
  available: false,
  unavailableReason: "not polled",
  fleets: [],
  commands: [],
};

const makeHarness = (input: {
  readonly snapshot?: InfinitusSnapshot;
  readonly polled?: InfinitusSnapshot;
  readonly reply?: Effect.Effect<unknown, InfinitusCommandFailed>;
  /** The Mac login's phases `--status` answers in turn, the last one repeating. */
  readonly phases?: ReadonlyArray<string>;
  /** What `ps` prints. */
  readonly ps?: string;
}) =>
  Effect.gen(function* () {
    const events = yield* PubSub.unbounded<OrchestrationV2DomainEvent>();
    const requests = yield* Ref.make<ReadonlyArray<InfinitusCommandInput>>([]);
    const alerts = yield* Ref.make<
      ReadonlyArray<{ title: string; body: string; deepLink?: string }>
    >([]);
    const statuses = yield* Ref.make<ReadonlyArray<string>>([]);
    const phases = yield* Ref.make(input.phases ?? []);
    const runs = yield* Ref.make<ReadonlyArray<ProcessRunInput>>([]);
    const current = yield* Ref.make(input.snapshot ?? manifest("aws-login", "gcloud-login"));
    const layer = InfinitusSignInLapseLive.pipe(
      Layer.provide(
        Layer.mergeAll(
          Layer.mock(Orchestrator.OrchestratorV2)({
            get streamDomainEvents() {
              return Stream.fromPubSub(events);
            },
          }),
          Layer.mock(InfinitusAlertRelay)({
            publish: (alert) =>
              Ref.update(alerts, (list) => [...list, alert]).pipe(Effect.as({ deliveries: 1 })),
          }),
          Layer.mock(InfinitusControlClient)({
            socketPath: "/tmp/infinitus.sock",
            request: (request) =>
              Effect.gen(function* () {
                yield* Ref.update(statuses, (list) => [...list, (request.args ?? []).join(" ")]);
                const left = yield* Ref.get(phases);
                const phase = left[0];
                if (left.length > 1) yield* Ref.set(phases, left.slice(1));
                return phase === undefined
                  ? yield* new InfinitusCommandFailed({
                      command: request.command,
                      error: "no login in flight",
                      restarting: false,
                    })
                  : { state: { profile: request.args?.[0], phase } };
              }),
          }),
          Layer.mock(ProcessRunner)({
            run: (run) =>
              Ref.update(runs, (list) => [...list, run]).pipe(
                Effect.as({
                  stdout: run.command === "ps" ? (input.ps ?? "") : "",
                  stderr: "",
                  code: 0 as never,
                  timedOut: false,
                  stdoutTruncated: false,
                  stderrTruncated: false,
                  stdoutInvalidUtf8: false,
                  stderrInvalidUtf8: false,
                }),
              ),
          }),
          Layer.mock(InfinitusService)({
            snapshot: Ref.get(current),
            refresh: Ref.set(current, input.polled ?? manifest("aws-login", "gcloud-login")),
            changes: () => Stream.empty,
            observed: Stream.empty,
            command: (request) =>
              Ref.update(requests, (list) => [...list, request]).pipe(
                Effect.andThen(input.reply ?? Effect.succeed({ state: {} })),
              ),
          }),
        ),
      ),
    );
    yield* Layer.build(layer);
    // The forked stream subscribes on its first step.
    for (let i = 0; i < 20; i += 1) yield* Effect.yieldNow;
    const settle = Effect.gen(function* () {
      for (let i = 0; i < 50; i += 1) yield* Effect.yieldNow;
    });
    return {
      emit: (event: OrchestrationV2DomainEvent) =>
        PubSub.publish(events, event).pipe(Effect.andThen(settle)),
      logins: Ref.get(requests).pipe(
        Effect.map((list) => list.map((request) => [request.command, ...request.args])),
      ),
      alerts: Ref.get(alerts),
      statuses: Ref.get(statuses),
      kills: Ref.get(runs).pipe(
        Effect.map((list) => list.filter((run) => run.command === "kill").map((run) => run.args)),
      ),
    };
  });

describe("InfinitusSignInLapseLive (#1076, #1627)", () => {
  effectIt.effect("a lapsed AWS sign-in starts the Mac's login and rings the phones", () =>
    Effect.gen(function* () {
      const h = yield* makeHarness({});
      yield* h.emit(toolResult(one, "all good\n"));
      expect(yield* h.logins).toEqual([]);
      yield* h.emit(toolResult(one, SSO_EXPIRED, "aws s3 ls --profile papaya"));
      expect(yield* h.logins).toEqual([["aws-login", "papaya"]]);
      // The phones hear about it once, deep-linked to the home screen's cards.
      expect(yield* h.alerts).toEqual([
        {
          title: "AWS sign-in needed",
          body: "papaya has expired credentials. Open Infinitus to sign in from this phone.",
          deepLink: "/",
        },
      ]);
    }),
  );

  effectIt.effect("only the shell tools' items are read", () =>
    Effect.gen(function* () {
      const h = yield* makeHarness({});
      yield* h.emit({
        type: "turn-item.updated",
        id: "evt-x",
        threadId: one,
        occurredAt: "2026-10-10T00:00:00Z",
        payload: {
          id: "item-x",
          threadId: one,
          type: "file_change",
          fileName: "notes.md",
          diffStr: SSO_EXPIRED,
          status: "completed",
        },
      } as never);
      yield* h.emit({
        type: "message.updated",
        id: "evt-y",
        threadId: one,
        occurredAt: "2026-10-10T00:00:00Z",
        payload: { text: SSO_EXPIRED },
      } as never);
      expect(yield* h.logins).toEqual([]);
      expect(yield* h.alerts).toEqual([]);
    }),
  );

  effectIt.effect("gcloud's Application Default Credentials take the gcloud verb", () =>
    Effect.gen(function* () {
      const h = yield* makeHarness({});
      yield* h.emit(toolResult(one, GCLOUD_ADC, "gcloud storage ls"));
      expect(yield* h.logins).toEqual([["gcloud-login", "application-default"]]);
      expect((yield* h.alerts).map((alert) => alert.title)).toEqual(["gcloud sign-in needed"]);
    }),
  );

  effectIt.effect("once per thread per profile an hour; another thread is its own need", () =>
    Effect.gen(function* () {
      const h = yield* makeHarness({});
      yield* h.emit(toolResult(one, SSO_EXPIRED));
      yield* h.emit(toolResult(one, SSO_EXPIRED));
      yield* h.emit(toolResult(one, GCLOUD_ADC));
      yield* h.emit(toolResult(two, SSO_EXPIRED));
      expect(yield* h.logins).toEqual([
        ["aws-login", "default"],
        ["gcloud-login", "application-default"],
        ["aws-login", "default"],
      ]);
      yield* TestClock.adjust(Duration.minutes(59));
      yield* h.emit(toolResult(one, SSO_EXPIRED));
      expect((yield* h.logins).length).toBe(3);
      yield* TestClock.adjust(Duration.minutes(1));
      yield* h.emit(toolResult(one, SSO_EXPIRED));
      expect((yield* h.logins).length).toBe(4);
      expect((yield* h.alerts).length).toBe(4);
    }),
  );

  effectIt.effect("a second profile lapsing in the same hour is its own need", () =>
    Effect.gen(function* () {
      const h = yield* makeHarness({});
      yield* h.emit(toolResult(one, SSO_EXPIRED, "aws s3 ls --profile papaya"));
      yield* h.emit(toolResult(one, SSO_EXPIRED, "aws s3 ls --profile banyan"));
      yield* h.emit(toolResult(one, SSO_EXPIRED, "aws s3 ls --profile papaya"));
      expect(yield* h.logins).toEqual([
        ["aws-login", "papaya"],
        ["aws-login", "banyan"],
      ]);
    }),
  );

  effectIt.effect("an app without the verb gets the push and no request", () =>
    Effect.gen(function* () {
      const h = yield* makeHarness({ snapshot: manifest("status") });
      yield* h.emit(toolResult(one, SSO_EXPIRED));
      expect(yield* h.logins).toEqual([]);
      expect((yield* h.alerts).length).toBe(1);
    }),
  );

  effectIt.effect("a login already waiting on a person is left alone", () =>
    Effect.gen(function* () {
      const h = yield* makeHarness({ snapshot: withLogin("waitingForBrowser") });
      yield* h.emit(toolResult(one, SSO_EXPIRED));
      expect(yield* h.logins).toEqual([]);
      expect((yield* h.alerts).length).toBe(1);
    }),
  );

  effectIt.effect("a login that finished or failed does not block the next one", () =>
    Effect.gen(function* () {
      const done = yield* makeHarness({ snapshot: withLogin("done") });
      yield* done.emit(toolResult(one, SSO_EXPIRED));
      expect(yield* done.logins).toEqual([["aws-login", "default"]]);
      const other = yield* makeHarness({ snapshot: withLogin("starting", "banyan") });
      yield* other.emit(toolResult(one, SSO_EXPIRED));
      expect(yield* other.logins).toEqual([["aws-login", "default"]]);
    }),
  );

  effectIt.effect("an unpolled snapshot is polled once for the manifest", () =>
    Effect.gen(function* () {
      const h = yield* makeHarness({ snapshot: notPolled });
      yield* h.emit(toolResult(one, SSO_EXPIRED));
      expect(yield* h.logins).toEqual([["aws-login", "default"]]);
    }),
  );

  effectIt.effect("a refused login is logged; the next need still goes through", () =>
    Effect.gen(function* () {
      const h = yield* makeHarness({
        reply: Effect.fail(
          new InfinitusCommandFailed({ command: "aws-login", error: "busy", restarting: false }),
        ),
      });
      yield* h.emit(toolResult(one, SSO_EXPIRED));
      yield* h.emit(toolResult(two, SSO_EXPIRED));
      expect(yield* h.logins).toEqual([
        ["aws-login", "default"],
        ["aws-login", "default"],
      ]);
      expect((yield* h.alerts).length).toBe(2);
    }),
  );

  const agentGcloud = (pid: number) =>
    [
      `  ${pid - 1} ${process.pid} /bin/zsh -c bun scripts/agent-login.ts gcp`,
      `  ${pid} ${pid - 1} /Library/Frameworks/Python -S /sdk/lib/gcloud.py auth login`,
    ].join("\n");

  effectIt.effect("the Mac's login landing ends the agent's own, under this server only", () =>
    Effect.gen(function* () {
      const h = yield* makeHarness({
        phases: ["waitingForBrowser", "waitingForBrowser", "done"],
        ps: `${agentGcloud(501)}\n  900 1 /Library/Frameworks/Python /sdk/lib/gcloud.py auth login`,
      });
      yield* h.emit(toolStart(one, "bun scripts/agent-login.ts gcp 2>&1 | tail -5"));
      expect(yield* h.logins).toEqual([["gcloud-login", "default"]]);
      expect(yield* h.kills).toEqual([]);
      yield* TestClock.adjust(Duration.seconds(3));
      expect(yield* h.kills).toEqual([]);
      yield* TestClock.adjust(Duration.seconds(3));
      expect(yield* h.kills).toEqual([["-TERM", "501"]]);
      // Over: no more reads.
      const reads = (yield* h.statuses).length;
      yield* TestClock.adjust(Duration.seconds(30));
      expect((yield* h.statuses).length).toBe(reads);
    }),
  );

  effectIt.effect("a failed or unknown Mac login leaves the agent's to its timeout", () =>
    Effect.gen(function* () {
      const failed = yield* makeHarness({
        phases: ["waitingForBrowser", "failed"],
        ps: agentGcloud(501),
      });
      yield* failed.emit(toolStart(one, "gcloud auth login"));
      yield* TestClock.adjust(Duration.seconds(30));
      expect(yield* failed.kills).toEqual([]);
      // Already done at the first read: an earlier outcome, not this login's.
      const earlier = yield* makeHarness({ phases: ["done"], ps: agentGcloud(501) });
      yield* earlier.emit(toolStart(one, "gcloud auth login"));
      yield* TestClock.adjust(Duration.seconds(30));
      expect(yield* earlier.kills).toEqual([]);
    }),
  );

  effectIt.effect("a login the agent runs inside the hour raises the Mac's login again", () =>
    Effect.gen(function* () {
      const h = yield* makeHarness({});
      yield* h.emit(toolResult(one, SSO_EXPIRED, "aws s3 ls --profile papaya-login"));
      const run = "printf 'y\\n' | aws login --profile papaya-login 2>&1 | tail -5";
      yield* TestClock.adjust(Duration.minutes(20));
      yield* h.emit(toolStart(one, run, "item-run"));
      // The same item stored again as its presentation fills in is still one run.
      yield* h.emit(toolStart(one, run, "item-run"));
      expect(yield* h.logins).toEqual([
        ["aws-login", "papaya-login"],
        ["aws-login", "papaya-login"],
      ]);
      expect((yield* h.alerts).length).toBe(2);
    }),
  );

  effectIt.effect("a login's finish with nothing printed is not a second start", () =>
    Effect.gen(function* () {
      const h = yield* makeHarness({ phases: ["done"] });
      yield* h.emit(toolStart(one, "aws login --profile papaya-login", "item-run"));
      yield* h.emit(
        commandItem(one, "aws login --profile papaya-login", { status: "completed" }, "item-run"),
      );
      expect((yield* h.logins).length).toBe(1);
    }),
  );

  effectIt.effect("a lapse in a tool result starts no watch", () =>
    Effect.gen(function* () {
      const h = yield* makeHarness({ phases: ["done"] });
      yield* h.emit(toolResult(one, SSO_EXPIRED));
      expect(yield* h.statuses).toEqual([]);
    }),
  );
});
