// @effect-diagnostics nodeBuiltinImport:off - the suite seeds and grows real
// The fork's UsageService cases (#779 account attribution, #659 the Stats
// fold), beside upstream's `UsageService.test.ts` so that file stays theirs.
// The fixture helpers are copies of that file's: a test file cannot import
// another test file's helpers without registering its suite too.
import * as NodeFSP from "node:fs/promises";
import * as NodeOS from "node:os";
import * as NodePath from "node:path";

import { assert, describe, it } from "@effect/vitest";
import * as NodeServices from "@effect/platform-node/NodeServices";
import * as HostProcess from "@infinitus/shared/HostProcess";
import {
  ProviderDriverKind,
  ProviderInstanceId,
  UsageDay,
  type UsageSummaryInput,
} from "@infinitus/contracts";
import * as Deferred from "effect/Deferred";
import * as Effect from "effect/Effect";
import * as Fiber from "effect/Fiber";
import * as Layer from "effect/Layer";
import * as Schema from "effect/Schema";
import * as ChildProcessSpawner from "effect/process/ChildProcessSpawner";
import { HttpClient, HttpClientResponse } from "effect/http";

import * as ServerConfig from "../config.ts";
import { ProcessRunner } from "../processRunner.ts";
import * as ServerSettings from "../serverSettings.ts";
import * as CursorAccountReader from "@infinitus/provider-cursor/server/CursorAccountReader";
import * as CursorKeychain from "@infinitus/provider-cursor/server/CursorKeychain";
import * as CursorUsageAccounts from "@infinitus/provider-cursor/server/CursorUsageAccounts";
import { MuseUsageHome } from "@infinitus/provider-muse/server";
import * as ServerSecretStore from "../auth/ServerSecretStore.ts";
import * as BackgroundPolicy from "../background/BackgroundPolicy.ts";
import * as AntigravityUsage from "../provider/Drivers/AntigravityUsage.ts";
import * as ProviderHostLive from "../provider/ProviderHostLive.ts";
import { UsageAttribution } from "../infinitus/Services/UsageAttribution.ts";
import * as Sqlite from "../persistence/Sqlite.ts";
import * as CodexUsageHistory from "./CodexUsageHistory.ts";
import * as UsageService from "./UsageService.ts";

const encodeUnknownJsonString = Schema.encodeSync(Schema.fromJsonString(Schema.Unknown));

function claudeLine(id: number, outputTokens: number, model = "claude-fable-5"): string {
  return `${JSON.stringify({
    type: "assistant",
    timestamp: "2026-08-01T10:00:00Z",
    requestId: `req_${id}`,
    sessionId: "session-1",
    message: {
      id: `msg_${id}`,
      model,
      usage: { input_tokens: 10, output_tokens: outputTokens },
    },
  })}\n`;
}

const WINDOW: UsageSummaryInput = {
  timeZone: "UTC",
  sinceDay: UsageDay.make("2026-07-31"),
  untilDay: UsageDay.make("2026-08-02"),
};

const setup = Effect.gen(function* () {
  // The service canonicalises the transcript roots (macOS keeps its temp
  // directory behind a symlink), so the fixture paths compare against theirs.
  const home = yield* Effect.promise(() =>
    NodeFSP.mkdtemp(NodePath.join(NodeOS.tmpdir(), "usage-service-test-")).then((dir) =>
      NodeFSP.realpath(dir),
    ),
  );
  yield* Effect.addFinalizer(() =>
    Effect.promise(() => NodeFSP.rm(home, { recursive: true, force: true })),
  );
  const transcriptDir = NodePath.join(home, "claude", "projects", "proj");
  yield* Effect.promise(() => NodeFSP.mkdir(transcriptDir, { recursive: true }));
  return {
    home,
    transcript: NodePath.join(transcriptDir, "session.jsonl"),
    settings: {
      providerInstances: {
        [ProviderInstanceId.make("claudeAgent")]: {
          driver: ProviderDriverKind.make("claudeAgent"),
          config: { homePath: NodePath.join(home, "claude") },
        },
        [ProviderInstanceId.make("codex")]: {
          driver: ProviderDriverKind.make("codex"),
          config: { homePath: NodePath.join(home, "codex") },
        },
      },
    },
  };
});

const layerService = (input: {
  readonly prefix: string;
  readonly home: string;
  readonly settings: Parameters<typeof ServerSettings.layerTest>[0];
  readonly onRatesFetch?: () => void;
  /** Defaults to an unparsable document so every scan retries the fetch. */
  readonly ratesDocument?: unknown;
  readonly environment?: NodeJS.ProcessEnv;
  readonly platform?: NodeJS.Platform;
}) =>
  Layer.fresh(CursorUsageAccounts.layer).pipe(
    Layer.provide(CursorAccountReader.layer.pipe(Layer.provide(CursorKeychain.layer))),
    Layer.provideMerge(AntigravityUsage.layer),
    Layer.provideMerge(MuseUsageHome.layer),
    Layer.provideMerge(ProviderHostLive.layer),
    Layer.provideMerge(CodexUsageHistory.layer.pipe(Layer.provideMerge(Sqlite.layerMemory))),
    Layer.provideMerge(Layer.mock(BackgroundPolicy.BackgroundPolicy)({})),
    Layer.provideMerge(Layer.mock(ServerSecretStore.ServerSecretStore)({})),
    Layer.provideMerge(
      ServerConfig.layerTest(process.cwd(), NodePath.join(input.home, input.prefix)),
    ),
    Layer.provideMerge(NodeServices.layer),
    Layer.provideMerge(Layer.succeed(HostProcess.Platform, input.platform ?? "linux")),
    Layer.provideMerge(ServerSettings.layerTest(input.settings)),
    Layer.provideMerge(
      Layer.succeed(
        HttpClient.HttpClient,
        HttpClient.make((request) =>
          Effect.sync(() => {
            input.onRatesFetch?.();
            // Unparsable rates: every scan retries the fetch, which makes the
            // fetch count a boundary-level observation of how many scans ran.
            return HttpClientResponse.fromWeb(request, Response.json(input.ratesDocument ?? {}));
          }),
        ),
      ),
    ),
    Layer.provideMerge(
      Layer.succeed(HostProcess.Environment, {
        HOME: input.home,
        GROK_HOME: NodePath.join(input.home, "grok"),
        PI_CODING_AGENT_DIR: NodePath.join(input.home, "pi"),
        OPENCODE_DATA_DIR: NodePath.join(input.home, "opencode"),
        ANTIGRAVITY_DATA_DIR: NodePath.join(input.home, "antigravity"),
        XDG_CONFIG_HOME: NodePath.join(input.home, "config"),
        APPDATA: NodePath.join(input.home, "config"),
        ...input.environment,
      }),
    ),
  );

function totalOutputTokens(summary: { buckets: readonly { totals: { outputTokens: number } }[] }) {
  return summary.buckets.reduce((sum, bucket) => sum + bucket.totals.outputTokens, 0);
}

describe("UsageService account attribution (#779)", () => {
  it.live("attributes Claude records to the account the timeline names (#779)", () =>
    Effect.gen(function* () {
      const { transcript, settings, home } = yield* setup;
      yield* Effect.promise(() => NodeFSP.writeFile(transcript, claudeLine(1, 5, "example-model")));

      yield* Effect.gen(function* () {
        const service = yield* UsageService.make;
        const summary = yield* service.readSummary(WINDOW);

        assert.deepStrictEqual(summary.accounts?.lines, [
          {
            email: "one@example.invalid",
            label: "work",
            number: 1,
            totals: summary.buckets[0]!.totals,
            costUsd: 0,
            records: 1,
          },
        ]);
        assert.strictEqual(summary.accounts?.unattributed.records, 0);
        assert.strictEqual(summary.accounts?.notClaude.records, 0);
        assert.strictEqual(summary.accounts?.switchesInWindow, 1);
        assert.strictEqual(summary.accounts?.basis, "test history");
      }).pipe(
        // Scoped inside the state directory, so pending cache writes land
        // before it is removed.
        Effect.scoped,
        Effect.provide(
          Layer.mergeAll(
            Layer.succeed(UsageAttribution, {
              resolve: Effect.succeed({
                accountAt: (timestampMs: number) =>
                  timestampMs >= Date.parse("2026-08-01T09:00:00Z") ? "one@example.invalid" : null,
                describe: () => ({ label: "work", number: 1 }),
                switchesAtMs: [
                  Date.parse("2026-07-01T09:00:00Z"),
                  Date.parse("2026-08-01T09:00:00Z"),
                  Date.parse("2026-09-15T09:00:00Z"),
                ],
                basis: "test history",
              }),
            }),
            layerService({ prefix: "usage-service-attribution-test", home, settings }),
          ),
        ),
      );
    }).pipe(Effect.scoped),
  );

  it.live("carries no accounts without a timeline", () =>
    Effect.gen(function* () {
      const { transcript, settings, home } = yield* setup;
      yield* Effect.promise(() => NodeFSP.writeFile(transcript, claudeLine(1, 5, "example-model")));

      yield* Effect.gen(function* () {
        const service = yield* UsageService.make;
        const summary = yield* service.readSummary(WINDOW);
        assert.strictEqual(summary.accounts, undefined);
      }).pipe(
        Effect.scoped,
        Effect.provide(
          layerService({ prefix: "usage-service-no-attribution-test", home, settings }),
        ),
      );
    }).pipe(Effect.scoped),
  );
});

describe("portable Stats service", () => {
  it.live.each(["claude", "codex"] as const)(
    "counts an unterminated %s activity event once across cache, restart, and append",
    (provider) =>
      Effect.gen(function* () {
        const { transcript, settings, home } = yield* setup;
        const codexDir = NodePath.join(home, "codex", "sessions");
        yield* Effect.promise(() => NodeFSP.mkdir(codexDir, { recursive: true }));
        const file = provider === "claude" ? transcript : NodePath.join(codexDir, "rollout.jsonl");
        const event = (type: string, payload: unknown) =>
          encodeUnknownJsonString({
            type,
            payload,
            timestamp: "2026-08-01T10:00:00Z",
          }) + "\n";
        const prefix =
          provider === "claude"
            ? claudeLine(1, 5)
            : event("session_meta", { id: "tail-session" }) +
              event("turn_context", { model: "gpt-test" }) +
              event("event_msg", {
                type: "token_count",
                info: { last_token_usage: { input_tokens: 10, output_tokens: 5 } },
              });
        const user = (second: number) =>
          encodeUnknownJsonString(
            provider === "claude"
              ? {
                  type: "user",
                  sessionId: "session-1",
                  timestamp: `2026-08-01T10:00:0${second}Z`,
                  message: { content: "hello" },
                }
              : {
                  type: "event_msg",
                  timestamp: `2026-08-01T10:00:0${second}Z`,
                  payload: { type: "user_message", message: "hello" },
                },
          );
        yield* Effect.promise(() => NodeFSP.writeFile(file, prefix + user(1)));
        yield* Effect.gen(function* () {
          const service = yield* UsageService.make;
          const request = {
            period: "week" as const,
            today: UsageDay.make("2026-08-01"),
            timeZone: "UTC",
          };
          yield* service.readSummary(WINDOW);
          const first = yield* service.readStats(request);
          assert.strictEqual(first.sessions[0]?.days[0]?.day.humanMessages, 1);
          assert.strictEqual(first.sessions[0]?.days[0]?.day.outputTokens, 5);
          assert.deepStrictEqual((yield* service.readStats(request)).sessions, first.sessions);
          yield* service.awaitPersisted;
          const restarted = yield* UsageService.make;
          assert.deepStrictEqual((yield* restarted.readStats(request)).sessions, first.sessions);
          yield* Effect.promise(() => NodeFSP.appendFile(file, "\n" + user(2) + "\n"));
          // Usage can be the first reader of the grown file with cached activity.
          yield* restarted.readSummary(WINDOW);
          const grown = yield* restarted.readStats(request);
          assert.strictEqual(grown.sessions[0]?.days[0]?.day.humanMessages, 2);
          assert.strictEqual(grown.sessions[0]?.days[0]?.day.outputTokens, 5);
        }).pipe(Effect.provide(layerService({ prefix: `stats-tail-${provider}`, home, settings })));
      }).pipe(Effect.scoped),
  );

  it.live("a future reporting date cannot prune retained usage after transcript cleanup", () =>
    Effect.gen(function* () {
      const { transcript, settings, home } = yield* setup;
      yield* Effect.promise(() => NodeFSP.writeFile(transcript, claudeLine(1, 5)));
      yield* Effect.gen(function* () {
        const service = yield* UsageService.make;
        assert.strictEqual(totalOutputTokens(yield* service.readSummary(WINDOW)), 5);
        yield* Effect.promise(() => NodeFSP.unlink(transcript));
        yield* service.readStats({
          period: "week",
          today: UsageDay.make("2035-01-01"),
          timeZone: "UTC",
        });
        // Restart so neither the summary memo nor the in-memory cache can hide data loss.
        yield* service.awaitPersisted;
        const restarted = yield* UsageService.make;
        assert.strictEqual(totalOutputTokens(yield* restarted.readSummary(WINDOW)), 5);
      }).pipe(Effect.provide(layerService({ prefix: "stats-retention", home, settings })));
    }).pipe(Effect.scoped),
  );

  it.live("Usage reads finish while a Stats repository command is blocked", () =>
    Effect.gen(function* () {
      const { transcript, settings, home } = yield* setup;
      yield* Effect.promise(() =>
        NodeFSP.writeFile(
          transcript,
          encodeUnknownJsonString({
            type: "user",
            sessionId: "session-1",
            cwd: home,
            timestamp: "2026-08-01T09:59:00Z",
            message: { content: "hello" },
          }) +
            "\n" +
            claudeLine(1, 5),
        ),
      );
      const repositoryStarted = yield* Deferred.make<void>();
      const releaseRepository = yield* Deferred.make<void>();
      const runner = ProcessRunner.of({
        run: () =>
          Effect.gen(function* () {
            yield* Deferred.succeed(repositoryStarted, undefined);
            yield* Deferred.await(releaseRepository);
            return {
              stdout: "",
              stderr: "",
              code: ChildProcessSpawner.ExitCode(1),
              timedOut: false,
              stdoutTruncated: false,
              stderrTruncated: false,
              stdoutInvalidUtf8: false,
              stderrInvalidUtf8: false,
            };
          }),
      });
      yield* Effect.gen(function* () {
        const service = yield* UsageService.make;
        const stats = yield* service
          .readStats({
            period: "week",
            today: UsageDay.make("2026-08-01"),
            timeZone: "UTC",
          })
          .pipe(Effect.forkChild);
        yield* Deferred.await(repositoryStarted);
        yield* Effect.gen(function* () {
          assert.strictEqual(totalOutputTokens(yield* service.readSummary(WINDOW)), 5);
        }).pipe(Effect.ensuring(Deferred.succeed(releaseRepository, undefined)));
        yield* Fiber.join(stats);
      }).pipe(
        Effect.provideService(ProcessRunner, runner),
        Effect.provide(layerService({ prefix: "stats-concurrency", home, settings })),
      );
    }).pipe(Effect.scoped),
  );

  it.live("backfills a Usage cache, resumes activity, and reprices historical Codex usage", () =>
    Effect.gen(function* () {
      const { home, settings } = yield* setup;
      const dir = NodePath.join(home, "codex", "sessions");
      yield* Effect.promise(() => NodeFSP.mkdir(dir, { recursive: true }));
      const file = NodePath.join(dir, "rollout.jsonl");
      const line = (type: string, payload: unknown, second = 0) =>
        JSON.stringify({
          type,
          payload,
          timestamp: `2026-08-01T10:00:${String(second).padStart(2, "0")}Z`,
        }) + "\n";
      const first =
        line("session_meta", { id: "stats-codex" }) +
        line("turn_context", { model: "gpt-test", effort: "high" }) +
        line("event_msg", { type: "user_message", message: "hello" }) +
        line(
          "event_msg",
          {
            type: "token_count",
            info: {
              last_token_usage: {
                input_tokens: 1000,
                cached_input_tokens: 600,
                output_tokens: 200,
                reasoning_output_tokens: 100,
              },
            },
          },
          1,
        ) +
        line("event_msg", { type: "task_complete" }, 2);
      yield* Effect.promise(() => NodeFSP.writeFile(file, first));
      yield* Effect.gen(function* () {
        const service = yield* UsageService.make;
        const request = {
          period: "month" as const,
          today: UsageDay.make("2026-08-01"),
          timeZone: "UTC",
        };
        yield* service.readSummary(WINDOW);
        const initial = yield* service.readStats(request);
        assert.strictEqual(initial.sessions.length, 1);
        assert.strictEqual(initial.sessions[0]!.days[0]!.day.unpricedRecords, 1);
        const settingsService = yield* ServerSettings.ServerSettingsService;
        yield* settingsService.updateSettings({
          usagePriceOverrides: {
            "gpt-test": {
              inputCostPerMillionTokens: 2,
              outputCostPerMillionTokens: 10,
              cacheReadCostPerMillionTokens: 0.5,
            },
          },
        });
        const priced = yield* service.readStats(request);
        assert.closeTo(priced.sessions[0]!.days[0]!.day.usd!, 0.0031, 1e-9);
        assert.strictEqual(priced.sessions[0]!.days[0]!.day.humanMessages, 1);
        yield* Effect.promise(() =>
          NodeFSP.appendFile(
            file,
            line("event_msg", { type: "user_message", message: "again" }, 3) +
              line(
                "response_item",
                {
                  type: "function_call",
                  name: "exec_command",
                  call_id: "c1",
                  arguments: '{"cmd":"pwd"}',
                },
                4,
              ),
          ),
        );
        const grown = yield* service.readStats(request);
        assert.strictEqual(grown.sessions[0]!.days[0]!.day.humanMessages, 2);
        assert.strictEqual(grown.sessions[0]!.days[0]!.day.toolCalls?.exec_command, 1);
        assert.strictEqual(grown.sessions[0]!.days[0]!.day.outputTokens, 200);
        yield* service.awaitPersisted;
        const restarted = yield* UsageService.make;
        assert.deepStrictEqual((yield* restarted.readStats(request)).sessions, grown.sessions);
        yield* Effect.promise(() => NodeFSP.copyFile(file, NodePath.join(dir, "moved-copy.jsonl")));
        const copied = yield* service.readStats(request);
        assert.strictEqual(copied.sessions.length, 1);
        assert.strictEqual(copied.sessions[0]!.days[0]!.day.outputTokens, 200);
        yield* Effect.promise(() => NodeFSP.writeFile(file, first));
        yield* Effect.promise(() => NodeFSP.unlink(NodePath.join(dir, "moved-copy.jsonl")));
        // Retained copies are still deduplicated after cleanup.
        assert.strictEqual((yield* service.readStats(request)).sessions.length, 1);
      }).pipe(
        Effect.scoped,
        Effect.provide(layerService({ prefix: "portable-stats", home, settings })),
      );
    }).pipe(Effect.scoped),
  );
});

// Fork (#834): the transcript read the usage backfill makes, by session id.
describe("UsageService session read (#834)", () => {
  it.live("reads one session's transcript by name, deduped and priced (#834 backfill)", () =>
    Effect.gen(function* () {
      const { transcript, settings, home } = yield* setup;
      const dir = NodePath.dirname(transcript);
      yield* Effect.promise(() =>
        NodeFSP.writeFile(
          NodePath.join(dir, "abc-123.jsonl"),
          claudeLine(1, 5) + claudeLine(2, 7) + claudeLine(1, 5),
        ),
      );
      yield* Effect.promise(() => NodeFSP.writeFile(transcript, claudeLine(3, 100)));

      yield* Effect.gen(function* () {
        const service = yield* UsageService.make;
        const found = yield* service.readSessionUsage({
          sessionIds: ["abc-123", "missing", "../abc-123", "session"],
        });
        assert.deepStrictEqual([...found.keys()].sort(), ["abc-123", "session"]);
        const one = found.get("abc-123");
        assert.deepStrictEqual(one?.totals, {
          uncachedInputTokens: 20,
          cachedInputTokens: 0,
          cacheCreationTokens: 0,
          outputTokens: 12,
          reasoningTokens: 0,
        });
        assert.closeTo(one?.costUsd ?? -1, 20 * 1e-5 + 12 * 5e-5, 1e-12);
        assert.deepStrictEqual(one?.models, ["claude-fable-5"]);
        assert.strictEqual(one?.lastAt, "2026-08-01T10:00:00.000Z");
        assert.strictEqual(found.get("session")?.totals.outputTokens, 100);
      }).pipe(
        Effect.scoped,
        Effect.provide(
          layerService({
            prefix: "usage-service-session-test",
            home,
            settings,
            ratesDocument: {
              "claude-fable-5": { input_cost_per_token: 1e-5, output_cost_per_token: 5e-5 },
            },
          }),
        ),
      );
    }).pipe(Effect.scoped),
  );
});
