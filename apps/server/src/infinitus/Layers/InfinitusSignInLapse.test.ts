import {
  ThreadId,
  TurnId,
  type OrchestrationCommand,
  type ProviderRuntimeEvent,
} from "@infinitus/contracts";
import {
  InfinitusCommandFailed,
  type InfinitusCommandInput,
  type InfinitusManifestCommand,
  type InfinitusSnapshot,
} from "@infinitus/contracts/infinitus";
import { it as effectIt } from "@effect/vitest";
import * as Crypto from "effect/Crypto";
import * as Duration from "effect/Duration";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as PubSub from "effect/PubSub";
import * as Ref from "effect/Ref";
import * as Stream from "effect/Stream";
import * as TestClock from "effect/testing/TestClock";
import { describe, expect } from "vite-plus/test";

import { OrchestrationEngineService } from "../../orchestration/Services/OrchestrationEngine.ts";
import { ProviderService } from "../../provider/Services/ProviderService.ts";
import { InfinitusService } from "../Services/Infinitus.ts";
import { InfinitusAlertRelay } from "../Services/InfinitusAlertRelay.ts";
import { InfinitusSignInLapseLive } from "./InfinitusSignInLapse.ts";
import { SIGN_IN_MARKER_KIND } from "./infinitusSignInLapse.logic.ts";

const testCrypto = Crypto.make({
  randomBytes: (size) => new Uint8Array(size).fill(1),
  digest: (_algorithm, data) => Effect.succeed(data),
});

const one = ThreadId.make("thread-1");
const two = ThreadId.make("thread-2");
const turnId = TurnId.make("turn-1");

const SSO_EXPIRED = "Error when retrieving token from sso: Token has expired and refresh failed\n";
const GCLOUD_ADC =
  "google.auth.exceptions.DefaultCredentialsError: Your default credentials were not found.\n";

let counter = 0;
const toolResult = (
  threadId: ThreadId,
  text: string,
  command = "aws sts get-caller-identity",
): ProviderRuntimeEvent =>
  ({
    type: "item.updated",
    eventId: `evt-${(counter += 1)}`,
    provider: "claude",
    createdAt: "2026-09-13T00:00:00Z",
    threadId,
    turnId,
    itemId: `item-${counter}`,
    payload: {
      itemType: "tool",
      status: "failed",
      data: {
        toolName: "Bash",
        input: { command },
        result: {
          type: "tool_result",
          tool_use_id: `tu-${counter}`,
          content: text,
          is_error: true,
        },
      },
    },
  }) as never;

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
}) =>
  Effect.gen(function* () {
    const events = yield* PubSub.unbounded<ProviderRuntimeEvent>();
    const dispatched = yield* Ref.make<ReadonlyArray<OrchestrationCommand>>([]);
    const requests = yield* Ref.make<ReadonlyArray<InfinitusCommandInput>>([]);
    const alerts = yield* Ref.make<
      ReadonlyArray<{ title: string; body: string; threadId?: string }>
    >([]);
    const current = yield* Ref.make(input.snapshot ?? manifest("aws-login", "gcloud-login"));
    const layer = InfinitusSignInLapseLive.pipe(
      Layer.provide(
        Layer.mergeAll(
          Layer.succeed(Crypto.Crypto, testCrypto),
          Layer.mock(ProviderService)({
            get streamEvents() {
              return Stream.fromPubSub(events);
            },
          }),
          Layer.mock(OrchestrationEngineService)({
            dispatch: (command) =>
              Ref.update(dispatched, (previous) => [...previous, command]).pipe(
                Effect.as({ sequence: 1 }),
              ),
          }),
          Layer.mock(InfinitusAlertRelay)({
            publish: (alert) =>
              Ref.update(alerts, (list) => [...list, alert]).pipe(Effect.as({ deliveries: 1 })),
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
      emit: (event: ProviderRuntimeEvent) =>
        PubSub.publish(events, event).pipe(Effect.andThen(settle)),
      rows: Ref.get(dispatched).pipe(
        Effect.map((list) =>
          list.flatMap((command) =>
            command.type === "thread.activity.append" &&
            command.activity.kind === SIGN_IN_MARKER_KIND
              ? [
                  {
                    threadId: command.threadId,
                    summary: command.activity.summary,
                    payload: command.activity.payload,
                    turnId: command.activity.turnId,
                  },
                ]
              : [],
          ),
        ),
      ),
      logins: Ref.get(requests).pipe(
        Effect.map((list) => list.map((request) => [request.command, ...request.args])),
      ),
      alerts: Ref.get(alerts),
    };
  });

describe("InfinitusSignInLapseLive (#1076)", () => {
  effectIt.effect("a lapsed AWS sign-in leaves a row and starts the Mac's login", () =>
    Effect.gen(function* () {
      const h = yield* makeHarness({});
      yield* h.emit(toolResult(one, "all good\n"));
      expect(yield* h.rows).toEqual([]);
      yield* h.emit(toolResult(one, SSO_EXPIRED, "aws s3 ls --profile papaya"));
      expect(yield* h.rows).toEqual([
        {
          threadId: one,
          summary: "AWS sign-in needed on papaya",
          payload: { provider: "aws", profile: "papaya", turnId },
          turnId,
        },
      ]);
      expect(yield* h.logins).toEqual([["aws-login", "papaya"]]);
      // The phones hear about it once, deep-linked to the thread.
      expect(yield* h.alerts).toEqual([
        {
          title: "AWS sign-in needed",
          body: "papaya has expired credentials. Open Infinitus to sign in from this phone.",
          threadId: one,
        },
      ]);
    }),
  );

  effectIt.effect("gcloud's Application Default Credentials take the gcloud verb", () =>
    Effect.gen(function* () {
      const h = yield* makeHarness({});
      yield* h.emit(toolResult(one, GCLOUD_ADC, "gcloud storage ls"));
      expect((yield* h.rows).map((row) => row.summary)).toEqual([
        "gcloud sign-in needed on application-default",
      ]);
      expect(yield* h.logins).toEqual([["gcloud-login", "application-default"]]);
    }),
  );

  effectIt.effect("once per thread per profile an hour; another thread is its own need", () =>
    Effect.gen(function* () {
      const h = yield* makeHarness({});
      yield* h.emit(toolResult(one, SSO_EXPIRED));
      yield* h.emit(toolResult(one, SSO_EXPIRED));
      yield* h.emit(toolResult(one, GCLOUD_ADC));
      yield* h.emit(toolResult(two, SSO_EXPIRED));
      expect((yield* h.rows).map((row) => [row.threadId, row.summary])).toEqual([
        [one, "AWS sign-in needed on default"],
        [one, "gcloud sign-in needed on application-default"],
        [two, "AWS sign-in needed on default"],
      ]);
      yield* TestClock.adjust(Duration.minutes(59));
      yield* h.emit(toolResult(one, SSO_EXPIRED));
      expect((yield* h.rows).length).toBe(3);
      yield* TestClock.adjust(Duration.minutes(1));
      yield* h.emit(toolResult(one, SSO_EXPIRED));
      expect((yield* h.rows).length).toBe(4);
      expect((yield* h.logins).length).toBe(4);
    }),
  );

  effectIt.effect("a second profile lapsing in the same hour is its own need", () =>
    Effect.gen(function* () {
      const h = yield* makeHarness({});
      yield* h.emit(toolResult(one, SSO_EXPIRED, "aws s3 ls --profile papaya"));
      yield* h.emit(toolResult(one, SSO_EXPIRED, "aws s3 ls --profile banyan"));
      yield* h.emit(toolResult(one, SSO_EXPIRED, "aws s3 ls --profile papaya"));
      expect((yield* h.rows).map((row) => row.summary)).toEqual([
        "AWS sign-in needed on papaya",
        "AWS sign-in needed on banyan",
      ]);
      expect(yield* h.logins).toEqual([
        ["aws-login", "papaya"],
        ["aws-login", "banyan"],
      ]);
    }),
  );

  effectIt.effect("an app without the verb gets the row and no request", () =>
    Effect.gen(function* () {
      const h = yield* makeHarness({ snapshot: manifest("status") });
      yield* h.emit(toolResult(one, SSO_EXPIRED));
      expect((yield* h.rows).length).toBe(1);
      expect(yield* h.logins).toEqual([]);
    }),
  );

  effectIt.effect("a login already waiting on a person is left alone", () =>
    Effect.gen(function* () {
      const h = yield* makeHarness({ snapshot: withLogin("waitingForBrowser") });
      yield* h.emit(toolResult(one, SSO_EXPIRED));
      expect((yield* h.rows).length).toBe(1);
      expect(yield* h.logins).toEqual([]);
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
      expect((yield* h.rows).length).toBe(2);
      expect(yield* h.logins).toEqual([
        ["aws-login", "default"],
        ["aws-login", "default"],
      ]);
    }),
  );
});
